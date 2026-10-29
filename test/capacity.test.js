// Composition regression from ted0x, ERC-8469 discussion post #21.
const assert = require("assert");
const { makeVM, DEPLOYER, coder, keccak256 } = require("./harness");
const { toUtf8Bytes, hexlify } = require("ethers");
const A = (i) => "0x" + (0x9000 + i).toString(16).padStart(40, "0");
const ZERO32 = "0x" + "00".repeat(32);
const salt = (n) => "0x" + n.toString(16).padStart(64, "0");
const commitment = (id, bidder, amount, n) => keccak256(coder.encode(
  ["bytes32", "address", "uint256", "bytes32"], [id, bidder, amount, salt(n)]
));

async function main() {
  const h = await makeVM();
  for (const who of [DEPLOYER, A(1), A(2), A(3), A(9)]) await h.fund(who);
  let passed = 0;
  const ok = (condition, message) => { assert(condition, message); passed++; };
  const rejects = async (promise, reason, message) => { await assert.rejects(promise, reason, message); passed++; };
  const answer = hexlify(toUtf8Bytes("capacity example work"));
  const workHash = keccak256(toUtf8Bytes("one exclusive slot, overlapping service requests"));
  const mechanism = await h.deploy("VickreyAward");
  const inner = await h.deploy("MockHashlockVerifier", [keccak256(answer)], ["bytes32"]);
  const adapterFor = (tender) => h.deploy("AwardThenMint", [tender.address], ["address"]);
  async function open(adapter, task, commitAt, revealAt) {
    const token = (await h.call(adapter, "nextTokenId")).out[0];
    const id = (await h.call(adapter, "open", [task.address, workHash, inner.address,
      mechanism.address, commitAt, revealAt, 0n, A(9), 16n], {from:A(1), value:100n})).out[0];
    return {id, token};
  }

  // Negative control: independently valid awards, but a late availability check
  // makes one unexecutable. Funds and reserved mint identifiers alone do not fix it.
  const naiveTender = await h.deploy("SealedBidTender");
  const naiveAdapter = await adapterFor(naiveTender);
  const late = await h.deploy("LateCapacityTask");
  const T0 = h.now();
  const n1 = await open(naiveAdapter, late, T0+100n, T0+200n);
  const n2 = await open(naiveAdapter, late, T0+100n, T0+200n);
  for (const [n, job] of [[1,n1],[2,n2]]) {
    await h.call(naiveTender, "commitBid", [job.id, commitment(job.id,A(2),40n,n)], {from:A(2)});
  }
  h.warp(T0+150n);
  for (const [n, job] of [[1,n1],[2,n2]]) {
    await h.call(naiveTender, "revealBid", [job.id,40n,salt(n)], {from:A(2)});
  }
  h.warp(T0+201n);
  for (const job of [n1,n2]) await h.call(naiveTender, "finalize", [job.id]);
  await h.call(naiveAdapter, "settle", [n1.id]);
  await rejects(h.call(naiveAdapter,"settle",[n2.id]), /capacity unavailable at execution/, "second final award cannot execute under late checking");
  ok((await h.call(naiveTender,"awardOf",[n2.id])).out[0][0].winner.toLowerCase()===A(2), "failed execution leaves the second final award intact");
  ok(!(await h.call(naiveAdapter,"jobOf",[n2.id])).out[0].settled, "failed execution rolls back adapter settlement");
  ok((await h.call(late,"updateAuthorityOf",[n2.token])).out[0]==="0x"+"00".repeat(20), "no second task minted");

  // Positive control: admission at the actual commit entry point, not just the target.
  const tender = await h.deploy("CapacityAdmittedTender");
  const adapter = await adapterFor(tender);
  const provider = await h.deploy("CapacityProvider",[tender.address,A(2)],["address","address"]);
  const rival = await h.deploy("CapacityProvider",[tender.address,A(3)],["address","address"]);
  await h.call(tender,"admit",[provider.address]);
  await h.call(tender,"admit",[rival.address]);
  const target = await h.deploy("ReservedCapacityTask",[[provider.address,rival.address]],["address[]"]);
  const T1 = h.now();
  const s1 = await open(adapter,target,T1+100n,T1+200n);
  const s2 = await open(adapter,target,T1+1000n,T1+2000n);
  await rejects(h.call(tender,"commitBid",[s1.id,commitment(s1.id,A(9),1n,3)],{from:A(9)}), /provider not admitted/, "EOA cannot bypass admission by using the core entry point");
  await rejects(h.call(provider,"commit",[s1.id,commitment(s1.id,provider.address,40n,3)],{from:A(9)}), /only controller/, "outsider cannot consume provider capacity");
  await h.call(provider,"commit",[s1.id,commitment(s1.id,provider.address,40n,3)],{from:A(2)});
  const terms = (await h.call(tender,"termsOf",[s1.id])).out[0];
  ok((await h.call(provider,"targetRef")).out[0]===terms.targetRef, "reservation bound to canonical target");
  ok((await h.call(provider,"contentHash")).out[0]===terms.contentHash, "reservation bound to content descriptor");
  await rejects(h.call(provider,"commit",[s2.id,commitment(s2.id,provider.address,40n,4)],{from:A(2)}), /capacity reserved/, "overlapping second admission fails before any second commitment");
  await rejects(h.call(provider,"releaseUnawarded"), /not final/, "capacity cannot be released while outcome can change");
  await rejects(h.call(provider,"consume",[s1.id,s1.token,terms.contentHash],{from:A(9)}), /wrong target/, "reservation cannot be consumed by another target");
  await rejects(h.call(provider,"consume",[s1.id,s1.token,ZERO32],{from:target.address}), /wrong content/, "reservation cannot be consumed for different work");
  await rejects(h.call(provider,"consume",[s1.id,s1.token,terms.contentHash],{from:target.address}), /not winner/, "target cannot consume a reservation before a final award");
  h.warp(T1+150n);
  await h.call(provider,"reveal",[s1.id,40n,salt(3)],{from:A(2)});
  h.warp(T1+201n);
  await h.call(tender,"finalize",[s1.id]);
  await rejects(h.call(provider,"releaseUnawarded"), /winner retains capacity/, "final winner cannot release before handoff");
  await h.call(adapter,"settle",[s1.id],{from:A(9)});
  ok((await h.call(provider,"consumed")).out[0], "settlement atomically hands the existing reservation to the task");
  ok((await h.call(provider,"activeTarget")).out[0].toLowerCase()===target.address.toLowerCase(), "reservation tracks the executing target");
  await rejects(h.call(provider,"consume",[s1.id,s1.token,terms.contentHash],{from:target.address}), /wrong reservation/, "reservation cannot be replayed");
  await rejects(h.call(provider,"releaseCompleted"), /work not complete/, "minting alone does not free the service slot");
  await rejects(h.call(provider,"commit",[s2.id,commitment(s2.id,provider.address,40n,4)],{from:A(2)}), /capacity reserved/, "capacity remains exclusive during fulfillment");
  const result = keccak256(coder.encode(["bytes","address"],[answer,provider.address]));
  const submission = (await h.call(provider,"submit",[result],{from:A(2)})).out[0];
  await h.call(target,"settleFulfillment",[s1.token,submission,answer],{from:A(9)});
  await h.call(provider,"releaseCompleted",[],{from:A(9)});
  ok((await h.call(provider,"reservedTender")).out[0]===ZERO32, "completed work releases the slot permissionlessly");

  // The earlier rejected attempt left no hidden commitment: admission now succeeds.
  await h.call(provider,"commit",[s2.id,commitment(s2.id,provider.address,150n,4)],{from:A(2)});
  ok((await h.call(provider,"reservedTender")).out[0]===s2.id, "second tender can use capacity after completion");
  h.warp(T1+1100n);
  await h.call(provider,"reveal",[s2.id,150n,salt(4)],{from:A(2)});
  h.warp(T1+2001n);
  await rejects(h.call(provider,"releaseUnawarded"), /not final/, "deadline passage alone does not release a reservation");
  await h.call(tender,"finalize",[s2.id]);
  await h.call(provider,"releaseUnawarded");
  ok((await h.call(provider,"reservedTender")).out[0]===ZERO32, "void tender releases capacity after finalization");
  await rejects(h.call(provider,"commit",[s2.id,commitment(s2.id,provider.address,40n,8)],{from:A(2)}), /not in commit phase/, "a finalized tender rejects a new commitment");
  ok((await h.call(provider,"reservedTender")).out[0]===ZERO32, "failed core commitment rolls back its capacity reservation");

  const T2 = h.now();
  const s3 = await open(adapter,target,T2+100n,T2+200n);
  const s4 = await open(adapter,target,T2+1000n,T2+2000n);
  await h.call(provider,"commit",[s3.id,commitment(s3.id,provider.address,80n,5)],{from:A(2)});
  await h.call(rival,"commit",[s3.id,commitment(s3.id,rival.address,40n,6)],{from:A(3)});
  h.warp(T2+150n);
  await h.call(provider,"reveal",[s3.id,80n,salt(5)],{from:A(2)});
  await h.call(rival,"reveal",[s3.id,40n,salt(6)],{from:A(3)});
  h.warp(T2+201n);
  await h.call(tender,"finalize",[s3.id]);
  await h.call(provider,"releaseUnawarded",[],{from:A(9)});
  ok((await h.call(provider,"reservedTender")).out[0]===ZERO32, "loser releases its own reservation without releasing the winner's");
  await rejects(h.call(rival,"releaseUnawarded"), /winner retains capacity/, "winner keeps its reservation after loser release");
  await h.call(adapter,"settle",[s3.id]);
  await h.call(provider,"commit",[s4.id,commitment(s4.id,provider.address,40n,7)],{from:A(2)});
  ok((await h.call(provider,"reservedTender")).out[0]===s4.id, "losing provider can enter another tender");
  ok((await h.call(rival,"consumed")).out[0], "winning provider remains reserved for its task");
  console.log(`capacity composition: ${passed} assertions passed`);
}

main().catch((e)=>{console.error("FAIL:",e.message);process.exit(1);});
