// Tender lifecycle tests: open → commit → reveal → finalize, bonds, slashing, timing, void.
const assert = require("assert");
const { makeVM, DEPLOYER, keccak256, coder } = require("./harness");

const A = (i) => "0x" + (0x3000 + i).toString(16).padStart(40, "0");
const SINK = "0x4000000000000000000000000000000000000004";
const TARGET_CONTRACT = "0x6000000000000000000000000000000000000006";
const TARGET_ID = "0x" + "ab".repeat(32);
const TARGET = keccak256(coder.encode(["uint256", "address", "bytes32"], [1n, TARGET_CONTRACT, TARGET_ID]));
const BOND = 10n ** 18n;
const salt = (i) => "0x" + (0x5000 + i).toString(16).padStart(64, "0");
const commitment = (tenderId, bidder, amount, s) =>
  keccak256(coder.encode(["bytes32", "address", "uint256", "bytes32"], [tenderId, bidder, amount, s]));

async function main() {
  const h = await makeVM();
  for (const who of [DEPLOYER, A(1), A(2), A(3), A(4)]) await h.fund(who);
  const vickrey = await h.deploy("VickreyAward");
  const tender = await h.deploy("SealedBidTender");
  let passed = 0;
  const ok = (c, m) => { assert(c, m); passed++; };
  const rejects = async (p, re, m) => { await assert.rejects(p, re, m); passed++; };

  const T0 = h.now();
  const terms = (over = {}) => ({
    targetRef: TARGET, mechanism: vickrey.address, reserve: 100n, units: 1n,
    commitDeadline: T0 + 100n, revealDeadline: T0 + 200n, bond: BOND, bondAsset: "0x" + "0".repeat(40),
    slashRecipient: SINK,
    ...over,
  });
  const asTuple = (t) => [t.targetRef, t.mechanism, t.reserve, t.units, t.commitDeadline, t.revealDeadline, t.bond, t.bondAsset, t.slashRecipient];

  // ── openTender validation ───────────────────────────────────────────────────
  await rejects(h.call(tender, "openTender", [asTuple(terms({ reserve: 0n }))]), /reserve/, "reserve 0");
  await rejects(h.call(tender, "openTender", [asTuple(terms({ units: 0n }))]), /units/, "units 0");
  await rejects(h.call(tender, "openTender", [asTuple(terms({ revealDeadline: T0 + 100n }))]), /reveal must follow/, "reveal <= commit");
  await rejects(h.call(tender, "openTender", [asTuple(terms({ commitDeadline: T0 }))]), /commit deadline passed/, "commit in past");
  await rejects(h.call(tender, "openTender", [asTuple(terms({ mechanism: SINK }))]), /./, "mechanism not ERC-165");
  await rejects(h.call(tender, "openTender", [asTuple(terms({ slashRecipient: "0x" + "0".repeat(40) }))]), /slash recipient required/, "no slash recipient with bond");
  await rejects(h.call(tender, "openTender", [asTuple(terms({ slashRecipient: A(1) }))], { from: A(1) }), /requester cannot receive/, "requester as slash recipient");
  ok((await h.call(tender, "openTender", [asTuple(terms({ bond: 0n, slashRecipient: "0x" + "0".repeat(40) }))], { from: A(1) })).logs.length === 1, "zero bond needs no slash recipient");
  // targetRefOf matches the spec formula
  ok((await h.call(tender, "targetRefOf", [1n, TARGET_CONTRACT, TARGET_ID])).out[0] === TARGET, "targetRefOf = keccak(abi.encode(chainId, contract, id))");

  // ── Happy path ──────────────────────────────────────────────────────────────
  const opened = await h.call(tender, "openTender", [asTuple(terms())], { from: A(1) });
  const tenderId = opened.logs.find((l) => l.name === "TenderOpened").args.tenderId;
  ok(opened.logs[0].args.requester.toLowerCase() === A(1), "requester recorded");
  ok(opened.logs[0].args.targetRef === TARGET, "targetRef in event");
  ok((await h.call(tender, "phaseOf", [tenderId])).out[0] === 1n, "phase Commit");
  ok((await h.call(tender, "requesterOf", [tenderId])).out[0].toLowerCase() === A(1), "requesterOf");

  // tenderId is deterministic per spec
  const expectedId = keccak256(coder.encode(["uint256", "address", "address", "uint256"], [1n, tender.address, A(1), 1n]));
  ok(tenderId === expectedId, "tenderId = keccak(chainid, this, requester, nonce)");

  // Bidders 2,3,4 commit; bidder 2 bids 60, bidder 3 bids 40, bidder 4 will never reveal.
  const bids = { [A(2)]: 60n, [A(3)]: 40n, [A(4)]: 70n };
  for (const [who, amt] of Object.entries(bids)) {
    const i = parseInt(who.slice(-1));
    const r = await h.call(tender, "commitBid", [tenderId, commitment(tenderId, who, amt, salt(i))], { from: who, value: BOND });
    ok(r.logs.some((l) => l.name === "BidCommitted"), `commit by ${who}`);
  }
  ok((await h.balance(tender.address)) === 3n * BOND, "three bonds held");

  await rejects(h.call(tender, "commitBid", [tenderId, commitment(tenderId, A(2), 1n, salt(9))], { from: A(2), value: BOND }), /already committed/, "double commit");
  await rejects(h.call(tender, "commitBid", [tenderId, commitment(tenderId, A(1), 1n, salt(9))], { from: A(1), value: BOND - 1n }), /wrong bond/, "short bond");
  await rejects(h.call(tender, "revealBid", [tenderId, 60n, salt(2)], { from: A(2) }), /commit window still open/, "reveal too early");

  // Move into the reveal window
  h.warp(T0 + 150n);
  await rejects(h.call(tender, "commitBid", [tenderId, commitment(tenderId, A(1), 1n, salt(9))], { from: A(1), value: BOND }), /commit window closed/, "commit too late");
  await rejects(h.call(tender, "revealBid", [tenderId, 61n, salt(2)], { from: A(2) }), /commitment mismatch/, "wrong amount");
  await rejects(h.call(tender, "revealBid", [tenderId, 60n, salt(3)], { from: A(2) }), /commitment mismatch/, "wrong salt");
  await rejects(h.call(tender, "revealBid", [tenderId, 60n, salt(2)], { from: A(1) }), /no commitment/, "reveal without commit");
  await rejects(h.call(tender, "finalize", [tenderId]), /reveal window still open/, "finalize too early");

  const bal2Before = await h.balance(A(2));
  const r2 = await h.call(tender, "revealBid", [tenderId, 60n, salt(2)], { from: A(2) });
  ok(r2.logs.some((l) => l.name === "BidRevealed" && l.args.amount === 60n), "reveal event");
  ok((await h.balance(A(2))) === bal2Before + BOND, "bond returned on reveal");
  ok((await h.call(tender, "phaseOf", [tenderId])).out[0] === 2n, "phase Reveal after first reveal");
  await rejects(h.call(tender, "revealBid", [tenderId, 60n, salt(2)], { from: A(2) }), /already revealed/, "double reveal");
  await h.call(tender, "revealBid", [tenderId, 40n, salt(3)], { from: A(3) });
  passed++;

  ok((await h.call(tender, "awardOf", [tenderId])).out[0].length === 0, "awardOf empty before finalize");

  // Finalize after the reveal window
  h.warp(T0 + 201n);
  await rejects(h.call(tender, "revealBid", [tenderId, 70n, salt(4)], { from: A(4) }), /reveal window closed/, "reveal too late");
  const sinkBefore = await h.balance(SINK);
  const fin = await h.call(tender, "finalize", [tenderId], { from: A(9) });
  const awarded = fin.logs.filter((l) => l.name === "TenderAwarded");
  ok(awarded.length === 1, "one award");
  ok(awarded[0].args.winner.toLowerCase() === A(3) && awarded[0].args.price === 60n, "bidder 3 wins at second price 60");
  ok(awarded[0].args.mechanismId === (await h.call(vickrey, "mechanismId")).out[0], "mechanismId in event");
  const slashed = fin.logs.filter((l) => l.name === "BidSlashed");
  ok(slashed.length === 1 && slashed[0].args.bidder.toLowerCase() === A(4), "non-revealer slashed");
  ok((await h.balance(SINK)) === sinkBefore + BOND, "slashed bond went to slashRecipient");
  ok((await h.balance(tender.address)) === 0n, "contract holds nothing after finalize");
  ok((await h.call(tender, "phaseOf", [tenderId])).out[0] === 3n, "phase Awarded");
  const stored = (await h.call(tender, "awardOf", [tenderId])).out[0];
  ok(stored.length === 1 && stored[0][0].toLowerCase() === A(3) && stored[0][1] === 60n, "awardOf stored");
  await rejects(h.call(tender, "finalize", [tenderId]), /already finalized/, "double finalize");

  // ── Void path: nobody under reserve ─────────────────────────────────────────
  const t2 = terms({ commitDeadline: h.now() + 100n, revealDeadline: h.now() + 200n, reserve: 50n });
  const o2 = await h.call(tender, "openTender", [asTuple(t2)], { from: A(1) });
  const id2 = o2.logs[0].args.tenderId;
  await h.call(tender, "commitBid", [id2, commitment(id2, A(2), 80n, salt(2))], { from: A(2), value: BOND });
  h.warp(t2.commitDeadline + 1n);
  await h.call(tender, "revealBid", [id2, 80n, salt(2)], { from: A(2) });
  h.warp(t2.revealDeadline + 1n);
  const fin2 = await h.call(tender, "finalize", [id2]);
  ok(fin2.logs.some((l) => l.name === "TenderVoid"), "void event");
  ok((await h.call(tender, "phaseOf", [id2])).out[0] === 4n, "phase Void");
  ok((await h.call(tender, "awardOf", [id2])).out[0].length === 0, "awardOf empty when void");

  // ── Void path: nobody revealed at all (finalize from Commit phase) ──────────
  const t3 = terms({ commitDeadline: h.now() + 100n, revealDeadline: h.now() + 200n });
  const o3 = await h.call(tender, "openTender", [asTuple(t3)], { from: A(1) });
  const id3 = o3.logs[0].args.tenderId;
  await h.call(tender, "commitBid", [id3, commitment(id3, A(2), 10n, salt(2))], { from: A(2), value: BOND });
  h.warp(t3.revealDeadline + 1n);
  const fin3 = await h.call(tender, "finalize", [id3]);
  ok(fin3.logs.some((l) => l.name === "TenderVoid") && fin3.logs.some((l) => l.name === "BidSlashed"), "void + slash with zero reveals");

  // ── Zero-bond tender accepts no value ───────────────────────────────────────
  const t4 = terms({ commitDeadline: h.now() + 100n, revealDeadline: h.now() + 200n, bond: 0n });
  const o4 = await h.call(tender, "openTender", [asTuple(t4)], { from: A(1) });
  const id4 = o4.logs[0].args.tenderId;
  await rejects(h.call(tender, "commitBid", [id4, commitment(id4, A(2), 10n, salt(2))], { from: A(2), value: 1n }), /no bond expected/, "value with zero bond");
  await h.call(tender, "commitBid", [id4, commitment(id4, A(2), 10n, salt(2))], { from: A(2) });
  passed++;

  // ── Views revert on unknown id ──────────────────────────────────────────────
  await rejects(h.call(tender, "phaseOf", ["0x" + "00".repeat(32)]), /no such tender/, "unknown id");

  console.log(`tender: ${passed} assertions passed`);
}

main().catch((e) => {
  console.error("FAIL:", e.message);
  process.exit(1);
});
