# Sealed-Bid Award Mechanism for Task Tenders

A draft ERC and reference implementation. The proposal defines how a task posted for
competitive fulfilment is awarded — which bidder wins and at what price — as a companion
to [ERC-8183](https://eips.ethereum.org/EIPS/eip-8183),
[ERC-8195](https://ethereum-magicians.org/t/erc-8195-task-market-protocol/27935) and
[ERC-8414](https://ethereum-magicians.org/t/erc-8414-token-bound-task-tenders/29597).

- **Status:** pre-ERC community draft. The ERC number is assigned by the EIP editors at
  PR time; this repository does not claim one.
- **Normative text:** the PR to [ethereum/ERCs](https://github.com/ethereum/ERCs) is
  authoritative once opened. `erc/erc-draft_sealed_bid_award.md` is a mirror.
- **Discussion:** [Ethereum Magicians thread](https://ethereum-magicians.org/t/sealed-bid-award-mechanism-for-task-tenders-companion-to-erc-8183-8195-8414/29814).

## What it specifies

1. A sealed-bid procedure: commit, reveal, award, with a bond returned on reveal and
   slashed on silence.
2. A stateless mechanism interface, `award(bids, reserve, units) → (winner, price)`.
3. Three normative pricing rules: `award.first-price`, `award.vickrey` (recommended),
   `award.uniform-price`.
4. A canonical target reference, `keccak256(abi.encode(chainId, targetContract, targetId))`,
   and an authority boundary: an award is a fact about bids, not a permission on the
   target. The target standard's own authorised party decides what the award changes.

The design follows Myerson (1981), *Optimal Auction Design*, read as a procurement
problem: the revelation principle fixes the interface shape, revenue equivalence says a
standard only needs to fix allocation and reserve, and the distribution-free payment rule
of the second-price auction is why Vickrey is the recommended default.

## Layout

| Path | What it is |
| --- | --- |
| `erc/erc-draft_sealed_bid_award.md` | The draft ERC text (mirror of the PR) |
| `assets/erc-draft_sealed_bid_award/` | Exactly what goes into the ERCs PR: interfaces, reference contracts, test vectors |
| `src/` | The same contracts, as the working source for this repository |
| `vectors/award-vectors.json` | Golden vectors: bids in commit order, reserve, units, expected award per mechanism |
| `src/adapters/AwardGatedVerifier.sol` | Informative: ERC-8414 verifier that settles only when the work verifies *and* the fulfiller won the bound tender |
| `proofs/VickreyTruthful.lean` | Machine-checked proof that truthful bidding is weakly dominant under `award.vickrey`, for all inputs |
| `test/SealedBidTender.t.sol` | Foundry suite, including fuzzed monotonicity and Vickrey truthfulness |
| `test/*.test.js` | Same coverage on an in-process EVM, no Foundry needed, plus the ERC-8414 adapter end to end |
| `test/mocks/` | Test-only stand-ins: a minimal ERC-8414 settlement path and a hashlock work verifier |

## Run without Foundry

```
npm install
npm test
```

`npm test` compiles every contract with solc 0.8.24, checks the golden vectors, checks the
six conditions the ERC places on `award` over an exhaustive 3-bidder grid, checks
Vickrey's dominant-strategy property by brute force (1,500 deviation checks), and walks the
full tender lifecycle: open, commit, reveal, finalize, bond return, slashing, void, and
every timing and validation revert.

Windows PowerShell:

```powershell
npm install
npm test
```

## Run with Foundry

```
forge install foundry-rs/forge-std
forge test
```

## What the contracts do and do not do

`SealedBidTender` holds bidder bonds only. It never holds the task reward, judges a
deliverable, writes reputation, or acts on the target. On `finalize` it calls the tender's
mechanism, re-checks the returned award against the ERC's conditions, stores it, and
slashes anyone who committed but did not reveal. Slashed bonds go to the tender's
`slashRecipient` term.

Mechanism contracts are pure. Bids reach them in commit order, and the sort inside
`BaseAwardMechanism` is stable, which is what makes "ties go to the earlier commit" hold.

## ERC-8414 adapter

`AwardGatedVerifier` sits in an ERC-8414 task's acceptance-authority slot. It settles a
submission only when an inner work verifier accepts it *and* the fulfiller of record is a
winner of the tender bound to that task. The payout stays the task's immutable
`rewardPerCompletion`; the award decides who may be paid, not how much. Each task token is
bound once, by its own update authority, to a tender whose `targetRef` names that token,
which that same authority opened, and whose reserve equals the reward. The end-to-end test
covers: a loser's correct work is not payable, a winner's wrong proof is not payable, a
copied result by a non-winner is not payable, a submission made before the award waits and
then settles, and the paid amount is the reward rather than the Vickrey price.

## Proof

`proofs/VickreyTruthful.lean` proves in core Lean 4 (no Mathlib) that under `award.vickrey`
bidding one's true cost is weakly dominant, for any reserve, any number of other bidders in
any commit order, and any deviation. The brute-force test checks the contract on a grid;
the proof removes the grid. Check it with `lean proofs/VickreyTruthful.lean`. See
`proofs/README.md`.

## License

Everything in this repository is released under CC0 1.0 (see `LICENSE.md`), matching the
ERC process.
