// End-to-end: price-binding, committed integration with ERC-8414 through AwardThenMint.
// The requester escrows the reserve; settlement is permissionless; the token is minted with
// rewardPerCompletion = Award.price, so the Vickrey price is what the winner is actually paid.
const assert = require("assert");
const { makeVM, DEPLOYER, keccak256, coder } = require("./harness");
const { toUtf8Bytes, hexlify } = require("ethers");

const A = (i) => "0x" + (0x8000 + i).toString(16).padStart(40, "0");
const SINK = "0x000000000000000000000000000000000000dEaD";
const BOND = 10n ** 18n;
const RESERVE = 100n;
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
  const atm = await h.deploy("AwardThenMint", [tender.address], ["address"]);
  const inner = await h.deploy("MockHashlockVerifier", [keccak256(ANSWER)], ["bytes32"]);
  const task = await h.deploy("MockTaskToken");
  const resultFor = (who) => keccak256(coder.encode(["bytes", "address"], [ANSWER, who]));
  const PRICE_BINDING = keccak256(toUtf8Bytes("profile.price-binding")).slice(0, 10);

  const TASK_HASH = keccak256(toUtf8Bytes("task package v1"));
  const TOKEN = BigInt(TASK_HASH);
  const T0 = h.now();
  const openArgs = (hash) => [task.address, hash, inner.address, vickrey.address, T0 + 100n, T0 + 200n, BOND, SINK, 16n];

  // ── Requester A1 opens and escrows the reserve ────────────────────────────────
  const opened = await h.call(atm, "open", openArgs(TASK_HASH), { from: A(1), value: RESERVE });
  const tenderId = opened.out[0];
  ok((await h.balance(atm.address)) === RESERVE, "reserve escrowed in the adapter");
  const terms = (await h.call(tender, "termsOf", [tenderId])).out[0];
  ok(terms.integrationProfile === PRICE_BINDING, "tender is price-binding");
  ok(terms.reserve === RESERVE, "reserve equals the escrow");
  ok(terms.targetRef === keccak256(coder.encode(["uint256", "address", "bytes32"], [1n, task.address, TASK_HASH])), "targetRef names the task before it is minted");
  await rejects(h.call(atm, "open", openArgs(TASK_HASH), { from: A(1), value: RESERVE }), /already tendered/, "one tender per task");
  await rejects(h.call(atm, "open", openArgs(keccak256(toUtf8Bytes("other"))), { from: A(1) }), /escrow the reserve/, "no escrow, no tender");

  // ── Bids: A2 asks 60, A3 asks 40 → A3 wins at the second price, 60 ─────────────
  await h.call(tender, "commitBid", [tenderId, commitment(tenderId, A(2), 60n, salt(2))], { from: A(2), value: BOND });
  await h.call(tender, "commitBid", [tenderId, commitment(tenderId, A(3), 40n, salt(3))], { from: A(3), value: BOND });
  h.warp(T0 + 150n);
  await h.call(tender, "revealBid", [tenderId, 60n, salt(2)], { from: A(2) });
  await h.call(tender, "revealBid", [tenderId, 40n, salt(3)], { from: A(3) });
  await rejects(h.call(atm, "settle", [tenderId], { from: A(3) }), /reveal window still open/, "cannot settle during reveals");

  // ── Settlement is permissionless: the winner forces execution ───────────────────
  h.warp(T0 + 201n);
  const settled = await h.call(atm, "settle", [tenderId], { from: A(3) });
  const ev = settled.logs.find((l) => l.name === "JobSettled").args;
  ok(ev.winner.toLowerCase() === A(3) && ev.price === 60n && ev.refund === 40n, "settled: A3 at 60, 40 back to the requester");
  ok((await h.call(task, "updateAuthorityOf", [TOKEN])).out[0].toLowerCase() === A(1), "token minted, requester is its update authority");
  ok((await h.call(task, "acceptanceAuthorityOf", [TOKEN])).out[0].toLowerCase() === atm.address.toLowerCase(), "adapter is the acceptance authority");
  ok((await h.call(task, "tenderTermsOf", [TOKEN])).out[0].rewardPerCompletion === 60n, "rewardPerCompletion = Award.price");
  ok((await h.call(task, "escrowBalanceOf", [TOKEN])).out[0] === 60n, "vault funded with the price");
  await rejects(h.call(atm, "settle", [tenderId]), /already settled/, "settle once");

  // ── Only the winner's verified work is payable, at the award price ─────────────
  const loser = (await h.call(task, "submitFulfillment", [TOKEN, resultFor(A(2))], { from: A(2) })).logs[0].args.submissionId;
  await rejects(h.call(task, "settleFulfillment", [TOKEN, loser, ANSWER]), /proof does not establish/, "loser's correct work is not payable");
  const win = (await h.call(task, "submitFulfillment", [TOKEN, resultFor(A(3))], { from: A(3) })).logs[0].args.submissionId;
  await rejects(h.call(task, "settleFulfillment", [TOKEN, win, hexlify(toUtf8Bytes("wrong"))]), /proof does not establish/, "winner with wrong proof");
  const before = await h.balance(A(3));
  const paid = await h.call(task, "settleFulfillment", [TOKEN, win, ANSWER], { from: A(9) });
  ok(paid.logs.find((l) => l.name === "FulfillmentAccepted").args.reward === 60n, "winner paid the Vickrey price, 60");
  ok((await h.balance(A(3))) === before + 60n, "winner received 60");

  // ── The requester claims the unused escrow ────────────────────────────────────
  const r1 = await h.balance(A(1));
  await h.call(atm, "claimRefund", [], { from: A(1) });
  ok((await h.balance(A(1))) === r1 + 40n, "requester refunded reserve minus price");
  await rejects(h.call(atm, "claimRefund", [], { from: A(1) }), /nothing to claim/, "refund once");

  // ── Void tender: nothing minted, full refund ──────────────────────────────────
  const HASH2 = keccak256(toUtf8Bytes("task package v2"));
  const T1 = h.now();
  const id2 = (await h.call(atm, "open", [task.address, HASH2, inner.address, vickrey.address, T1 + 100n, T1 + 200n, BOND, SINK, 16n], { from: A(1), value: 30n })).out[0];
  await h.call(tender, "commitBid", [id2, commitment(id2, A(2), 50n, salt(2))], { from: A(2), value: BOND });
  h.warp(T1 + 150n);
  await h.call(tender, "revealBid", [id2, 50n, salt(2)], { from: A(2) });
  h.warp(T1 + 201n);
  const v = (await h.call(atm, "settle", [id2], { from: A(9) })).logs.find((l) => l.name === "JobSettled").args;
  ok(v.price === 0n && v.refund === 30n, "void: full refund credited");
  ok((await h.call(task, "updateAuthorityOf", [BigInt(HASH2)])).out[0] === "0x" + "0".repeat(40), "void: no token minted");

  // ── The adapter only answers the task contract itself ─────────────────────────
  const direct = await h.call(atm, "verifyFulfillment", [task.address, TOKEN, win, A(3), resultFor(A(3)), ANSWER], { from: A(9) });
  ok(direct.out[0] === false, "verifyFulfillment from a non-task caller returns false");

  console.log(`award-then-mint: ${passed} assertions passed`);
}

main().catch((e) => { console.error("FAIL:", e.message); process.exit(1); });
