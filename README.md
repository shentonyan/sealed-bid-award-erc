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
| `test/SealedBidTender.t.sol` | Foundry suite, including fuzzed monotonicity and Vickrey truthfulness |
| `test/*.test.js` | Same coverage on an in-process EVM, no Foundry needed |

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

## License

Everything in this repository is released under CC0 1.0 (see `LICENSE.md`), matching the
ERC process.
