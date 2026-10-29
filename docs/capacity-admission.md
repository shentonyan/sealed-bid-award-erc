# Capacity-dependent execution

Review source: [ted0x, ERC-8469 discussion post 21](https://ethereum-magicians.org/t/erc-8469-sealed-bid-award-mechanism-for-task-tenders/29814/21).

## Boundary

Execution-binding concerns making the award effective on its target. It does not
guarantee that a provider will deliver. A capacity limit matters to execution-binding
when the target consults it and can reject an otherwise final award. If both awards
execute and one provider later fails to deliver, that is a separate fulfillment risk.

The generic `AwardThenMint` example reserves money and a mint identifier, binds the
task content and verifier, and makes settlement permissionless. It does not reserve
service capacity. A target with another scarce execution precondition needs a
separate admission/reservation extension; declaring price-binding is not proof of it.

## Reservation lifecycle

1. Before accepting a commitment, reserve the required capacity and verify admission
   on the actual tender entry point. An unreserved address must not be able to bypass
   that entry point, win, and make the target reject the final award.
2. Bind the reservation to the tender, provider, target, content, resource, quantity
   and service interval. Conflicting tenders use the same accounting authority.
3. Hold it while the outcome can change. After finalization, losers and void tenders
   can release their reservations.
4. A winner hands its existing reservation to the target atomically with execution.
   This is a consumption of secured capacity, not a new availability check.
5. Keep capacity allocated while the work needs it, releasing it at completion or
   another release condition already defined by the target lifecycle. Do not let a
   pre-execution expiry or revocation make an admissible award unexecutable.

These are requirements on a capacity-constrained integration, not a new ERC-8469
admission API or a third `integrationProfile` value. A registry cannot infer physical
capacity or operator uniqueness from addresses. Cross-chain accounting and identity
attestation require additional mechanisms. Capacity reservation alone does not prove
truthfulness for joint strategies across tenders with coupled costs or opportunities.

## Executable example and regression

Run `npm test`, or after compilation run `node test/capacity.test.js`.

The test-only contracts in `test/mocks/CapacityExamples.sol` demonstrate:

- `LateCapacityTask`: one provider wins two tenders. Both awards finalize, the first
  executes, and the second execution reverts on a late availability check. The second
  award remains final and the failed adapter transaction rolls back.
- `CapacityProvider`: a contract bidder with one globally exclusive slot. Every
  request in this deliberately conservative example conflicts, regardless of time;
  it does not implement a schedule of non-overlapping intervals.
- `CapacityAdmittedTender`: covers the actual commit entry point and checks the
  existing target/content-bound reservation before forwarding to the core. Its
  trusted identity list is append-only; an identity cannot be revoked after bidding.
- `ReservedCapacityTask`: accepts only admitted contract identities and consumes
  the reservation atomically during mint. The provider remains reserved until the
  target records work completion. Losers and void tenders can release separately.

The 29 assertions cover bypass attempts, repeated admissions, target/content binding,
premature release, replay, winning handoff, work completion, losing release and void
release, and reservation rollback when the core rejects a commitment. These mocks
are not production capacity registries or an ERC-8414 kernel.
They assume trusted resource identities and a truthful, unchanging target completion
record; they do not prove physical capacity, Sybil resistance or multi-tender IC.

The reference `commitBid` implementation is now `public virtual` to support an
admission subclass. Its ABI and default core semantics remain unchanged. The source
and submitted reference contract are kept identical. The compiler uses canonical
forward-slash source paths so cross-directory mock imports work on Windows and Linux.
