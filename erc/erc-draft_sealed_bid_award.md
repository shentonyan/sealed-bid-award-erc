---
title: Sealed-Bid Award Mechanism for Task Tenders
description: A commit-reveal award interface with pluggable pricing rules for competitive task tenders between agents
author: Shenton Yan (@shentonyan)
discussions-to: https://ethereum-magicians.org/t/sealed-bid-award-mechanism-for-task-tenders-companion-to-erc-8183-8195-8414/29814
status: Draft
type: Standards Track
category: ERC
created: 2026-10-01
requires: 165
---

## Abstract

This ERC defines how a task posted for competitive fulfilment is awarded: which bidder wins and at what price. It specifies a sealed-bid procedure (commit, reveal, award), a stateless mechanism interface that computes the award from revealed bids, and three normative pricing rules: first-price, second-price (Vickrey), and uniform-price for multiple identical units. The contract that runs the procedure holds only bidder bonds; it never holds the task reward, judges a deliverable, or records reputation. It returns an award that an existing task-escrow standard such as [ERC-8183](./eip-8183.md), [ERC-8195](./eip-8195.md), or [ERC-8414](./eip-8414.md) can consume.

## Motivation

Three standards now describe how an agent posts a task, escrows the reward, and settles on delivery. None of them says how the task is awarded when more than one agent wants it. [ERC-8183](./eip-8183.md) runs bidding through an off-chain hook and receives only the outcome through `setProvider`. [ERC-8195](./eip-8195.md) has an Auction mode whose bids are relayed off-chain and whose rule is fixed to lowest-bid-wins. [ERC-8414](./eip-8414.md) states that bidding is a companion extension outside its kernel. Each market therefore writes its own award logic, the same agent bids under three incompatible rules, and no indexer can say what an award meant or whether the price was fair.

This ERC fills that gap with the smallest interface that makes an award auditable: bids are committed before they are seen, revealed together, and resolved by a pure function whose code anyone can read. The interface is deliberately narrow so that it composes with all three escrow standards instead of competing with them.

The design follows optimal auction theory.[^1] The revelation principle says that any feasible auction is equivalent to a direct mechanism in which each bidder reports a type and the mechanism computes an allocation and a payment; the on-chain interface here is exactly that pair of functions, and commit–reveal is what makes a sealed report credible on a public ledger. Revenue equivalence says that the requester's expected payment is fixed once the allocation rule and the reserve are fixed, so a standard only needs to pin down those two things and can leave the pricing rule to a plugin. In the symmetric regular case the optimal procurement mechanism is a second-price auction with a reserve, and its payment rule contains no distributional parameters, which is why second-price is the recommended default for autonomous bidders who cannot be assumed to share a prior about each other's costs.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### Terms

- **Requester**: the party that opens a tender and will pay the award.
- **Bidder**: an address that commits and reveals a bid. A bid is the price the bidder asks for performing the task.
- **Reserve**: the highest price the requester will pay. No bid above it may win.
- **Unit**: one identical instance of the task. A tender for a single task has one unit.
- **Mechanism**: a contract implementing `IAwardMechanism` that maps revealed bids to an award.
- **Award**: the set of winning bidders and the price each is paid.
- **Target**: the task, job, or tender in another standard that this tender is run for. The companion produces an award for the target; it never acts on the target.

### Target reference

Every tender names its target by a single canonical commitment:

```solidity
targetRef = keccak256(abi.encode(chainId, targetContract, targetId));
```

where `chainId` is the chain on which `targetContract` is deployed and `targetId` is the target's identifier normalised to `bytes32`: an identifier that is already `bytes32` (such as an [ERC-8183](./eip-8183.md) `jobId` or an [ERC-8195](./eip-8195.md) `taskId`) is used as is; a `uint256` identifier (such as an [ERC-8414](./eip-8414.md) `tokenId`) is left-padded with zero bytes. Implementations MUST compute `targetRef` with `abi.encode`, not `abi.encodePacked`.

### Award mechanism interface

A mechanism contract MUST implement the following interface and MUST return `true` from `supportsInterface(type(IAwardMechanism).interfaceId)` per [ERC-165](./eip-165.md).

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

interface IAwardMechanism {
    struct Bid {
        address bidder;
        uint256 amount;   // price asked, in the tender's unit of account
    }

    struct Award {
        address winner;
        uint256 price;    // price paid to this winner
    }

    /// @notice Canonical identifier of the rule, e.g. bytes4(keccak256("award.vickrey")).
    function mechanismId() external pure returns (bytes4);

    /// @notice Compute the award from revealed bids.
    /// @dev MUST be pure. Bids are passed in commit order. An empty return means no award.
    /// @param bids    Revealed bids in commit order.
    /// @param reserve Highest acceptable price. MUST be > 0.
    /// @param units   Number of identical units to award. MUST be >= 1.
    function award(Bid[] calldata bids, uint256 reserve, uint256 units)
        external pure returns (Award[] memory);
}
```

`award` MUST satisfy all of the following:

1. It MUST be deterministic and MUST NOT read state.
2. No returned `winner` MAY have bid an `amount` greater than `reserve`.
3. No returned `price` MAY exceed `reserve`.
4. Each returned `winner` MUST appear at most once, and the number of awards MUST NOT exceed `units`.
5. Lowering one bidder's `amount` while holding all other inputs fixed MUST NOT remove that bidder from the award. This is the monotonicity condition that incentive compatibility requires.
6. Ties on `amount` MUST be broken in favour of the bid that appears earlier in `bids`.

### Normative mechanisms

Let the revealed amounts sorted ascending be b(1) ≤ b(2) ≤ … ≤ b(n), and let r be the reserve.

| `mechanismId` string | Winners | Price per winner | Award condition |
| --- | --- | --- | --- |
| `award.first-price` | lowest `units` bids | each winner's own bid | bid ≤ r |
| `award.vickrey` | lowest bid (units = 1) | min(b(2), r); r if n = 1 | b(1) ≤ r |
| `award.uniform-price` | lowest `units` bids | min(b(units+1), r); r if n ≤ units | bid ≤ r |

`award.vickrey` MUST revert if `units != 1`. `award.first-price` and `award.uniform-price` accept any `units >= 1`.

A mechanism contract MAY implement a rule not listed here. Its `mechanismId` MUST be `bytes4(keccak256(<canonical string>))` for a string that is not one of the three above.

### Tender interface

A tender contract MUST implement the following interface and MUST return `true` from `supportsInterface(type(ISealedBidTender).interfaceId)`.

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "./IAwardMechanism.sol";

interface ISealedBidTender {
    enum Phase { None, Commit, Reveal, Awarded, Void }

    struct TenderTerms {
        bytes32 targetRef;       // canonical target commitment, see "Target reference"
        address mechanism;       // IAwardMechanism
        uint256 reserve;         // MUST be > 0
        uint256 units;           // MUST be >= 1
        uint64  commitDeadline;  // commits accepted while block.timestamp <= commitDeadline
        uint64  revealDeadline;  // reveals accepted while commitDeadline < block.timestamp <= revealDeadline
        uint256 bond;            // amount escrowed per commit
        address bondAsset;       // address(0) for the chain's native asset, else an ERC-20
        address slashRecipient;  // where slashed bonds go; MUST be non-zero when bond > 0
    }

    event TenderOpened(
        bytes32 indexed tenderId,
        bytes32 indexed targetRef,
        address indexed requester,
        address mechanism,
        uint256 reserve,
        uint256 units,
        uint64 commitDeadline,
        uint64 revealDeadline
    );
    event BidCommitted(bytes32 indexed tenderId, address indexed bidder, bytes32 commitment);
    event BidRevealed(bytes32 indexed tenderId, address indexed bidder, uint256 amount);
    event BidSlashed(bytes32 indexed tenderId, address indexed bidder, uint256 bond);
    event TenderAwarded(bytes32 indexed tenderId, address indexed winner, uint256 price, bytes4 mechanismId);
    event TenderVoid(bytes32 indexed tenderId);

    function openTender(TenderTerms calldata terms) external returns (bytes32 tenderId);
    function commitBid(bytes32 tenderId, bytes32 commitment) external payable;
    function revealBid(bytes32 tenderId, uint256 amount, bytes32 salt) external;
    function finalize(bytes32 tenderId) external returns (IAwardMechanism.Award[] memory);

    function termsOf(bytes32 tenderId) external view returns (TenderTerms memory);
    function requesterOf(bytes32 tenderId) external view returns (address);
    function phaseOf(bytes32 tenderId) external view returns (Phase);
    function awardOf(bytes32 tenderId) external view returns (IAwardMechanism.Award[] memory);
}
```

### Tender lifecycle

**Opening.** `openTender` MUST revert unless `reserve > 0`, `units >= 1`, `commitDeadline > block.timestamp`, `revealDeadline > commitDeadline`, `mechanism` reports `IAwardMechanism` through ERC-165, and either `bond == 0` or `slashRecipient != address(0)`. `slashRecipient` MUST NOT be the requester. The caller is recorded as the requester. `tenderId` MUST be `keccak256(abi.encode(block.chainid, address(this), msg.sender, nonce))` where `nonce` is a per-requester counter incremented on each call. The contract MUST emit `TenderOpened` and set the phase to `Commit`.

**Committing.** `commitBid` MUST revert unless the phase is `Commit` and `block.timestamp <= commitDeadline`. The commitment MUST be `keccak256(abi.encode(tenderId, msg.sender, amount, salt))`; implementations MUST use `abi.encode`, not `abi.encodePacked`. An address MUST NOT commit more than once per tender. The contract MUST take `bond` in `bondAsset` from the caller (for a native-asset bond, `msg.value` MUST equal `bond`; for an ERC-20 bond, `msg.value` MUST be zero and the contract MUST pull exactly `bond` by `transferFrom`) and MUST emit `BidCommitted`.

**Revealing.** `revealBid` MUST revert unless `commitDeadline < block.timestamp <= revealDeadline`, the caller has an unrevealed commitment for this tender, and `keccak256(abi.encode(tenderId, msg.sender, amount, salt))` equals that commitment. On success the contract MUST record the bid, MUST emit `BidRevealed`, and MUST return the caller's bond. The phase becomes `Reveal` on the first valid reveal or, if none arrives, remains `Commit` until finalization.

**Finalizing.** `finalize` is permissionless and MUST revert unless `block.timestamp > revealDeadline` and the phase is `Commit` or `Reveal`. The contract MUST call `mechanism.award(bids, reserve, units)` with the revealed bids in commit order, and MUST then check the result against conditions 2 to 4 of the award mechanism interface (no price above `reserve`, no duplicate winner, no more awards than `units`), reverting if any fails. The mechanism is a third-party contract and the tender contract is the last check before an award reaches a target. If the result is non-empty the contract MUST store it, set the phase to `Awarded`, and emit one `TenderAwarded` per winner. If the result is empty the contract MUST set the phase to `Void` and emit `TenderVoid`. In either case the contract MUST slash the bond of every committed bidder who did not reveal, emitting `BidSlashed` for each, and MUST transfer the total slashed amount to `slashRecipient`. `slashRecipient` MUST NOT be an address from which the requester can recover funds, directly or through the target. In particular it MUST NOT be the target's escrow or vault where, as under [ERC-8414](./eip-8414.md), funds sent there offset the requester's own contribution or return to the target's owner. The RECOMMENDED `slashRecipient` is a burn address.

**Views.** All view functions MUST revert for a `tenderId` that does not exist. `awardOf` MUST return an empty array unless the phase is `Awarded`.

### Authority boundary

A valid award confers no authority over its target. The companion's output is a replay-safe, target-bound `Award`; whether and how that award changes the target is decided by the target standard's own authority model. Code that carries an award into a target (an adapter) MUST NOT act with authority the target standard does not already grant it. In particular an adapter MUST NOT set a provider, change a budget, or change a reward on the target's behalf; it MAY verify that a transition the target's authorised party makes is consistent with the stored award.

### Composition with escrow standards (informative)

This ERC does not specify adapters. The following patterns are consistent with the authority boundary:

- With [ERC-8183](./eip-8183.md), the client opens the tender, and after `finalize` the client calls `setProvider(jobId, winner)` and `setBudget(jobId, price)` itself. A hook on those actions reads `awardOf(tenderId)` and reverts if the values differ from the award. The hook checks; it does not act.
- With [ERC-8195](./eip-8195.md), an Auction-mode implementation reads `awardOf` inside its own selection transition in place of a fixed lowest-bid rule. The transition remains the 8195 contract's.
- With [ERC-8414](./eip-8414.md), the award supplies eligibility only: the committed eligibility policy admits a submission whose fulfiller of record is a winner. `price` does not rewrite `rewardPerCompletion`, which is an immutable tender term there. A requester who wants a sealed-bid round on such a tender SHOULD set `reserve` equal to `rewardPerCompletion`, so that any bid above the fixed reward is non-award and the allocation remains incentive compatible; price discovery on that target happens when the vault is priced, not at award.

## Rationale

**The mechanism contract is stateless.** The revelation principle reduces every feasible auction to a pair of outcome functions on reported types. A pure `award` function is that pair, and nothing else. Because it reads no state, a mechanism can be verified against the feasibility conditions by exhaustive test vectors, and its bytecode can be pinned by anyone opening a tender.

**The standard fixes reserve and allocation, not the pricing rule.** Revenue equivalence says two mechanisms with the same allocation rule and the same worst-type utility yield the same expected payment. Requiring one pricing rule would add no interoperability, only a constraint on implementers.

**Second-price is the recommended default.** In the symmetric regular case it is the optimal procurement mechanism once a reserve is set, and its payment rule does not depend on the bidders' cost distributions. It therefore stays incentive compatible when the requester's beliefs about agent costs are wrong. First-price requires each bidder to know the others' cost distribution to bid well, and autonomous agents from different operators have no shared prior.

**Reserve is a field of its own.** The optimal reserve is strictly tighter than the requester's outside value, and the mechanism must be allowed to return no award. Folding reserve into a budget field hides that decision.

**Uniform-price is limited to one unit per bidder.** With several units and bidders who want more than one, uniform-price invites demand reduction and is not truthful. Deployments that need multi-unit demand should use a Vickrey-Clarke-Groves rule as a plugin.

**Asymmetric and correlated-type mechanisms are out of scope.** Rules that discriminate between bidders need per-bidder beliefs about cost distributions. Full-surplus extraction under correlated types needs the requester to pay losing bidders, which the escrow standards forbid. Both remain expressible as plugins; neither is normative.

**Commit–reveal over encrypted bids.** It needs no off-chain committee and no new cryptography. The cost it adds, one extra transaction and a bond, is the least that makes a sealed report credible on a public ledger.

**Ties break by commit order.** Any deterministic tie-break is compatible with the theory. Commit order is observable on-chain, needs no randomness, and rewards early commitment, which shortens commit windows in practice.

**Bonds return on reveal, not on award.** A bidder who reveals has done what the procedure asked. Holding the bond until award would penalise honest losers and give the requester a lever to delay.

**The award holds no authority.** An award is a fact about bids, not a permission on the target. Letting an adapter act on the target would make the mechanism contract, which is third-party and pluggable, an authority over escrowed funds; keeping the target's own party as the only actor limits a bad mechanism to producing a bad award that the party can decline to act on. It also lets one companion serve three standards with three different authority models without taking a dependency on any of them.

**One canonical target reference.** The three escrow standards use different identifier domains. Committing to `(chainId, targetContract, targetId)` under one hash makes an award bind to exactly one target, so a tender cannot be replayed against a different job that happens to share an identifier, and indexers can join awards to targets without per-standard rules.

**Slashed value is a tender term.** Where slashed bonds go changes bidders' incentives, so it belongs in the terms every bidder sees before committing, not in an adapter or a deployment setting.

## Backwards Compatibility

This ERC introduces new interfaces and does not change any existing one. Contracts implementing [ERC-8183](./eip-8183.md), [ERC-8195](./eip-8195.md), or [ERC-8414](./eip-8414.md) are unaffected unless they choose to consume an award.

## Test Cases

Test vectors are provided in `../assets/erc-draft_sealed_bid_award/vectors/award-vectors.json`. Each vector supplies a list of bids in commit order, a reserve, a unit count, and the expected award for each normative mechanism. The set covers: all bids under the reserve; a single bid, which pays the reserve under `award.vickrey` and `award.uniform-price`; no bid under the reserve; a second-lowest bid above the reserve, which caps the Vickrey price at the reserve; ties, which go to the earlier commit; an empty bid list; and multi-unit cases where the clearing price is the first excluded bid or, when there is none, the reserve.

The following must hold for every vector and for any further input an implementation is tested on, since they restate conditions 1 to 6 of the specification: the same input gives the same output; no winner bid above the reserve; no price exceeds the reserve; no winner appears twice and there are no more awards than units; lowering a winner's bid keeps it a winner; and equal bids resolve to the earlier commit. For `award.vickrey`, in addition, a bidder's payoff from bidding its true cost is never less than its payoff from any other bid, holding other bids fixed.

## Reference Implementation

A reference `SealedBidTender` contract and the three normative mechanism contracts are provided in `../assets/erc-draft_sealed_bid_award/`. The tender contract holds bonds only, re-checks each award against the specification before storing it, and routes slashed bonds to the tender's `slashRecipient`. The mechanism contracts are pure; a stable sort over bids in commit order is what makes the tie rule hold.

## Security Considerations

**Unrevealed commitments.** Without a bond, a bidder can commit and abandon at no cost, or commit from many addresses to probe the mechanism. `bond` MUST be non-zero for tenders open to unrestricted participation, and implementations SHOULD size it against the reserve.

**Public reveals.** Bids become public at reveal. In a second-price rule the second-lowest reveal sets the price, so two colluding bidders can arrange their reveal order to expose the winner's margin. The award is unchanged, but implementations SHOULD NOT attach any meaning to reveal order.

**Collusion and correlated costs.** Agents built on the same model API have strongly correlated costs, and a bidding ring can hold the second price at the reserve. Requesters SHOULD derive the reserve from their own outside option rather than from observed past prices. Reputation layers SHOULD index `TenderAwarded` events to detect rings.

**Shill bidding by the requester.** A requester can commit a bid at the reserve to push a second price toward it. Because the reserve is the requester's own declared limit, this does no harm under first-price or second-price. Uniform-price is more exposed, and implementations MAY exclude the requester's address from bidding.

**Timestamp manipulation.** Deadlines are block timestamps and can shift by a few seconds. Commit and reveal windows shorter than a few minutes SHOULD NOT be used.

**Mechanism trust.** A malicious mechanism can award arbitrarily. Because `award` is pure, its behaviour can be checked offline and its bytecode pinned. Requesters SHOULD reference only audited mechanism addresses.

**Bond asset handling.** Fee-on-transfer and rebasing assets make slashed amounts ambiguous. Implementations SHOULD reject them as `bondAsset`.

**Re-tendering.** If a tender is void and the requester opens another for the same `targetRef`, the revealed bids of the first round inform the second. Implementations MAY enforce a minimum interval or refuse to reuse a `targetRef`.

**Slash recipient as an incentive.** If slashed bonds reach the requester, directly or indirectly, two things go wrong. The requester gains from bidders failing to reveal and may try to induce that, for instance by congesting the reveal window. And the requester can post commitments it never intends to reveal at almost no cost. Under a first-price rule such phantom commitments inflate the number of apparent competitors and lower bids; in the uniform-cost case with three real bidders, three phantom commitments reduce the requester's expected payment by about 19%. Sending slashed bonds to the target's vault looks neutral but is not: under [ERC-8414](./eip-8414.md), funds sent to the vault are spent on the reward before the requester's own funds, and any residual returns to the token owner. Hence the requirement that `slashRecipient` be an address the requester cannot recover funds from. Implementations SHOULD also reject a `slashRecipient` that is a bidder of the same tender if one can be identified at commit time.

**Commit–reveal is not sealed.** Reveals are public transactions, so a bidder who reveals late has seen earlier reveals, and anyone watching a public mempool sees pending ones. A bidder can also hold several commitments and open only the one that does best against what it has seen. Under `award.vickrey` this is worthless: truthful bidding is dominant for every profile of other bids, so information about them has no value, and each abandoned commitment forfeits a bond. Under `award.first-price` it is valuable: a last revealer with a fine ladder of commitments is paid close to the lowest rival bid while rivals shade as in a sealed first-price auction. In the uniform-cost case the gain reaches about 27% of the reserve, and deterring even a two-commitment ladder needs a bond of 10 to 12% of the reserve when there are three or fewer bidders. Deployments that use `award.first-price` SHOULD make reveals simultaneous, for example through threshold encryption, rather than rely on the bond.

**Adapters that act.** An adapter that holds a key or an approval on the target and calls its mutating functions re-creates the authority problem this ERC avoids. Target standards SHOULD treat such adapters as privileged actors and audit them as such.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).

[^1]:
    ```csl-json
    {
      "type": "article-journal",
      "id": 1,
      "author": [
        {
          "family": "Myerson",
          "given": "Roger B."
        }
      ],
      "DOI": "10.1287/moor.6.1.58",
      "title": "Optimal Auction Design",
      "container-title": "Mathematics of Operations Research",
      "volume": "6",
      "issue": "1",
      "page": "58-73",
      "original-date": {
        "date-parts": [
          [1981, 2, 1]
        ]
      },
      "URL": "https://doi.org/10.1287/moor.6.1.58"
    }
    ```
