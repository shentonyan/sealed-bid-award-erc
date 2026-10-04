# Proofs

`VickreyTruthful.lean` proves, in core Lean 4 with no Mathlib, that under the ERC's
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

## Model

The proof takes one bidder's view. Other bids are split into those committed before and
after that bidder, which is how the ERC's tie rule ("ties go to the earlier commit")
enters. Under a stable ascending sort the bidder is first exactly when its bid is within the
reserve, strictly below every earlier bid and at most every later bid; the price is the
lowest other bid capped at the reserve. That is what `VickreyAward.sol` computes. The
link between the Solidity code and this model is checked by `test/mechanisms.test.js` on a
finite grid; the theorem here holds for all inputs.

`truthful_dominant` depends only on Lean's standard axioms (`propext`, `Classical.choice`,
`Quot.sound`); `wins_of_le` depends on none.

## Check it

Any Lean 4 toolchain, no project setup needed. Tested on v4.34.0.

```
lean proofs/VickreyTruthful.lean
```

No output means every theorem checked. To list the axioms used, add
`#print axioms VickreyAward.truthful_dominant` at the end of a copy of the file and check
that copy.

Windows PowerShell (with `ELAN_HOME` set and any HTTP proxy variables unset):

```powershell
lean .\proofs\VickreyTruthful.lean
```
