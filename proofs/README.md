# Proofs

Two files, both in core Lean 4 with no Mathlib.

## `VickreyTruthful.lean`

It proves, that under the ERC's
`award.vickrey` rule truthful bidding is a weakly dominant strategy: for any reserve, any
number of other bidders in any commit order, any true cost and any alternative bid, bidding
the true cost pays at least as much.

| Theorem | Statement |
| --- | --- |
| `truthful_dominant` | `utility r before after c b ≤ utility r before after c c` for all `r before after c b` |
| `truthful_nonneg` | Truthful bidding never yields a negative payoff |
| `wins_of_le` | Lowering a winning bid keeps it winning (the ERC's condition 5) |
| `price_le_reserve` | The price never exceeds the reserve (condition 3) |
| `bid_le_price_of_wins` | A winner is never paid less than its own bid |

A final `example` checks by `decide` that first-price is not truthful (cost 40, other bid 80,
reserve 100: bidding 79 beats bidding 40), so the dominance property is not vacuous.

### Model

The proof takes one bidder's view. Other bids are split into those committed before and
after that bidder, which is how the ERC's tie rule ("ties go to the earlier commit")
enters. Under a stable ascending sort the bidder is first exactly when its bid is within the
reserve, strictly below every earlier bid and at most every later bid; the price is the
lowest other bid capped at the reserve. That is what `VickreyAward.sol` computes. The
link between the Solidity code and this model is checked by `test/mechanisms.test.js` on a
finite grid; the theorem here holds for all inputs.

`truthful_dominant` depends only on Lean's standard axioms (`propext`, `Classical.choice`,
`Quot.sound`); `wins_of_le` depends on none.

## `IntegrationProfiles.lean`

This file states the scope of the result above. Truthfulness is a property of the award
together with what the target does with it, not of the award alone.

| Theorem | Statement |
| --- | --- |
| `fixed_reward_not_truthful` | With a fixed reward of 100, a cost of 60 and an earlier bid of 50, bidding 40 earns 40 and bidding 60 earns 0 (checked by `decide`) |
| `fixed_reward_lowest_bid_weakly_better` | With a fixed reward, any bidder whose cost is at most the reward does at least as well bidding 0 as bidding its cost |
| `posted_price_acceptance_dominant` | Under `award.posted-price`, accepting exactly when cost ≤ reserve is weakly dominant, whatever earlier committers did and whatever the alternative bid |

The posted-price model reduces the other bidders to one fact: whether someone earlier in
commit order accepted. That fact does not depend on the bidder's own amount, which is why
the amount carries no information beyond "accept". These theorems use `propext` and
`Quot.sound` only.

## Check it

Any Lean 4 toolchain, no project setup needed. Tested on v4.34.0.

```
lean proofs/VickreyTruthful.lean
lean proofs/IntegrationProfiles.lean
```

No output means every theorem checked. To list the axioms used, add
`#print axioms VickreyAward.truthful_dominant` at the end of a copy of the file and check
that copy.

Windows PowerShell (with `ELAN_HOME` set and any HTTP proxy variables unset):

```powershell
lean .\proofs\VickreyTruthful.lean
lean .\proofs\IntegrationProfiles.lean
```
