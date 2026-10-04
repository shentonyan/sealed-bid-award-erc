// End-to-end test: a sealed-bid tender gating eligibility on an ERC-8414-style task token.
const assert = require("assert");
const { makeVM, DEPLOYER, keccak256, coder } = require("./harness");
const { toUtf8Bytes, hexlify } = require("ethers");

const A = (i) => "0x" + (0x7000 + i).toString(16).padStart(40, "0");
const ZERO = "0x" + "0".repeat(40);
const SINK = "0x4000000000000000000000000000000000000004";
const BOND = 10n ** 18n;
const REWARD = 100n;
const TOKEN = 7n;
const salt = (i) => "0x" + (0x5000 + i).toString(16).padStart(64, "0");
const commitment = (id, who, amt, s) =>
  keccak256(coder.encode(["bytes32", "address", "uint256", "bytes32"], [id, who, amt, s]));

async function main() {
  const h = await makeVM();
  for (const who of [DEPLOYER, A(1), A(2), A(3), A(9)]) await h.fund(who);
  let passed = 0;
  const ok = (c, m) => { assert(c, m); passed++; };
  const rejects = async (p, re, m) => { await assert.rejects(p, re, m); passed++; };

  const ANSWER = hexlify(toUtf8Bytes("forty-two"));
  const vickrey = await h.deploy("VickreyAward");
  const tender = await h.deploy("SealedBidTender");
  const adapter = await h.deploy("AwardGatedVerifier");
  const inner = await h.deploy("MockHashlockVerifier", [keccak256(ANSWER)], ["bytes32"]);
  const task = await h.deploy("MockTaskToken");
  const resultFor = (who) => keccak256(coder.encode(["bytes", "address"], [ANSWER, who]));

  ok((await h.call(adapter, "supportsInterface", ["0x9977db15"])).out[0] === true, "adapter declares ITaskVerifier (8414 id)");

  // Requester A1 mints the task: reward 100, one completion, adapter in the judgment slot.
  await h.call(task, "mint", [TOKEN, A(1), adapter.address, REWARD, 1n], { from: A(1), value: REWARD });
  const targetRef = (await h.call(adapter, "targetRefFor", [task.address, TOKEN])).out[0];
  ok(targetRef === keccak256(coder.encode(["uint256", "address", "bytes32"], [1n, task.address, "0x" + TOKEN.toString(16).padStart(64, "0")])), "targetRef = keccak(chainid, task, bytes32(tokenId))");

  const T0 = h.now();
  const terms = (over = {}) => {
    const t = { targetRef, mechanism: vickrey.address, reserve: REWARD, units: 1n,
      commitDeadline: T0 + 100n, revealDeadline: T0 + 200n, bond: BOND, bondAsset: ZERO, slashRecipient: SINK, ...over };
    return [t.targetRef, t.mechanism, t.reserve, t.units, t.commitDeadline, t.revealDeadline, t.bond, t.bondAsset, t.slashRecipient];
  };
  const open = async (t, from) => (await h.call(tender, "openTender", [t], { from })).logs[0].args.tenderId;

  const good = await open(terms(), A(1));
  const wrongTarget = await open(terms({ targetRef: "0x" + "11".repeat(32) }), A(1));
  const wrongReserve = await open(terms({ reserve: 90n }), A(1));
  const rigged = await open(terms(), A(9)); // same target, opened by an outsider

  // ── Binding rules ─────────────────────────────────────────────────────────────
  await rejects(h.call(adapter, "bind", [task.address, TOKEN, tender.address, good, inner.address], { from: A(9) }), /only update authority/, "outsider cannot bind");
  await rejects(h.call(adapter, "bind", [task.address, TOKEN, tender.address, wrongTarget, inner.address], { from: A(1) }), /targets another task/, "tender for another target");
  await rejects(h.call(adapter, "bind", [task.address, TOKEN, tender.address, rigged, inner.address], { from: A(1) }), /not opened by task authority/, "tender opened by someone else");
  await rejects(h.call(adapter, "bind", [task.address, TOKEN, tender.address, wrongReserve, inner.address], { from: A(1) }), /reserve must equal reward/, "reserve differs from reward");
  const bound = await h.call(adapter, "bind", [task.address, TOKEN, tender.address, good, inner.address], { from: A(1) });
  ok(bound.logs.some((l) => l.name === "Bound"), "bind succeeds for the authority's own tender");
  await rejects(h.call(adapter, "bind", [task.address, TOKEN, tender.address, good, inner.address], { from: A(1) }), /already bound/, "binding is once only");

  // ── Tender: A2 bids 60, A3 bids 40 → A3 wins ────────────────────────────────────
  await h.call(tender, "commitBid", [good, commitment(good, A(2), 60n, salt(2))], { from: A(2), value: BOND });
  await h.call(tender, "commitBid", [good, commitment(good, A(3), 40n, salt(3))], { from: A(3), value: BOND });

  // Work submitted before the award: settlement fails, but the submission is not rejected.
  const early = (await h.call(task, "submitFulfillment", [TOKEN, resultFor(A(3))], { from: A(3) })).logs[0].args.submissionId;
  await rejects(h.call(task, "settleFulfillment", [TOKEN, early, ANSWER]), /proof does not establish/, "no settlement before award");

  h.warp(T0 + 150n);
  await h.call(tender, "revealBid", [good, 60n, salt(2)], { from: A(2) });
  await h.call(tender, "revealBid", [good, 40n, salt(3)], { from: A(3) });
  h.warp(T0 + 201n);
  const fin = await h.call(tender, "finalize", [good]);
  const aw = fin.logs.find((l) => l.name === "TenderAwarded").args;
  ok(aw.winner.toLowerCase() === A(3) && aw.price === 60n, "A3 wins; Vickrey price 60");
  ok((await h.call(adapter, "isWinner", [task.address, TOKEN, A(3)])).out[0] === true, "isWinner(A3)");
  ok((await h.call(adapter, "isWinner", [task.address, TOKEN, A(2)])).out[0] === false, "not isWinner(A2)");

  // ── Settlement after the award ─────────────────────────────────────────────────
  // The loser does correct work: still not eligible.
  const loser = (await h.call(task, "submitFulfillment", [TOKEN, resultFor(A(2))], { from: A(2) })).logs[0].args.submissionId;
  await rejects(h.call(task, "settleFulfillment", [TOKEN, loser, ANSWER]), /proof does not establish/, "loser's correct work is not payable");
  // The winner with a wrong proof: not payable.
  await rejects(h.call(task, "settleFulfillment", [TOKEN, early, hexlify(toUtf8Bytes("wrong"))]), /proof does not establish/, "winner with wrong proof");
  // Someone else replays the winner's submission's proof against their own submission: resultHash binds the fulfiller.
  const copy = (await h.call(task, "submitFulfillment", [TOKEN, resultFor(A(3))], { from: A(9) })).logs[0].args.submissionId;
  await rejects(h.call(task, "settleFulfillment", [TOKEN, copy, ANSWER]), /proof does not establish/, "copied resultHash by a non-winner");

  // The early submission, which waited, now settles: anyone may call it.
  const before = await h.balance(A(3));
  const settled = await h.call(task, "settleFulfillment", [TOKEN, early, ANSWER], { from: A(9) });
  const paid = settled.logs.find((l) => l.name === "FulfillmentAccepted").args.reward;
  ok(paid === REWARD, "paid the task's fixed reward (100), not the Vickrey price (60)");
  ok((await h.balance(A(3))) === before + REWARD, "winner received the reward");

  // ── The adapter refuses to be driven by anyone but the task itself ──────────────
  const direct = await h.call(adapter, "verifyFulfillment", [task.address, TOKEN, early, A(3), resultFor(A(3)), ANSWER], { from: A(9) });
  ok(direct.out[0] === false, "verifyFulfillment from a non-task caller returns false");

  console.log(`8414 adapter: ${passed} assertions passed`);
}

main().catch((e) => { console.error("FAIL:", e.message); process.exit(1); });
