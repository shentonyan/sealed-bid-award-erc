/-
  Vickrey award: truthful bidding is a weakly dominant strategy.

  Formalises `award.vickrey` from the draft ERC "Sealed-Bid Award Mechanism for Task
  Tenders" (single unit, procurement form: lowest bid wins, paid the lower of the
  second-lowest bid and the reserve) and proves, for any number of bidders, any costs,
  any reserve and any deviation, that a bidder never gains by bidding anything other
  than its true cost.

  Checked with core Lean 4 (v4.34.0). No Mathlib.

  ## Model

  We take the view of one bidder, `i`. Everything the rule needs from the other bidders
  is their revealed amounts, split by commit order:

  * `before` : amounts of bidders who committed before `i`
  * `after`  : amounts of bidders who committed after `i`

  This split is how the ERC's tie rule ("ties go to the earlier commit") enters. With a
  stable ascending sort over bids in commit order, `i` is first — that is, `i` wins —
  exactly when its bid `b` is within the reserve, strictly below every earlier bid, and
  at most every later bid. When `i` wins, the second element of the sorted list is the
  minimum of all other bids, so the price is `min(that, reserve)`, or the reserve if
  there are no other bids. `(before ++ after).foldr min r` is precisely that number.

  The same definitions are what `VickreyAward.sol` computes; the brute-force tests in
  `test/mechanisms.test.js` check the contract against them on a finite grid. This file
  removes the grid.
-/

namespace VickreyAward

/-- The price a winner is paid: the lowest other bid, capped at the reserve `r`.
    With no other bids this is `r`. It does not depend on the winner's own bid. -/
def price (r : Nat) (before after : List Nat) : Nat :=
  (before ++ after).foldr min r

/-- Bidder `i`, bidding `b`, wins the award. -/
def wins (r : Nat) (before after : List Nat) (b : Nat) : Prop :=
  b ≤ r ∧ (∀ x ∈ before, b < x) ∧ (∀ x ∈ after, b ≤ x)

instance (r : Nat) (before after : List Nat) (b : Nat) : Decidable (wins r before after b) := by
  unfold wins; exact inferInstance

/-- Payoff to a bidder with true cost `c` who bids `b`: price minus cost if it wins, else 0. -/
def utility (r : Nat) (before after : List Nat) (c b : Nat) : Int :=
  if wins r before after b then (price r before after : Int) - c else 0

/-! ### Three facts about `foldr min` -/

theorem foldr_min_le_init (r : Nat) : ∀ l : List Nat, l.foldr min r ≤ r
  | [] => Nat.le_refl r
  | x :: l => by
      simp only [List.foldr_cons]
      have := foldr_min_le_init r l
      omega

theorem foldr_min_le_mem (r : Nat) : ∀ (l : List Nat) (x : Nat), x ∈ l → l.foldr min r ≤ x
  | [], _, h => absurd h (List.not_mem_nil)
  | y :: l, x, h => by
      simp only [List.foldr_cons]
      rcases List.mem_cons.mp h with rfl | h
      · omega
      · have := foldr_min_le_mem r l x h
        omega

theorem le_foldr_min (r c : Nat) (hr : c ≤ r) :
    ∀ l : List Nat, (∀ x ∈ l, c ≤ x) → c ≤ l.foldr min r
  | [], _ => hr
  | y :: l, h => by
      simp only [List.foldr_cons]
      have hy := h y (List.mem_cons_self ..)
      have ih := le_foldr_min r c hr l (fun x hx => h x (List.mem_cons_of_mem _ hx))
      omega

/-! ### The two inequalities the dominance argument needs -/

/-- If the true cost would win, the price covers it. -/
theorem cost_le_price_of_wins {r c : Nat} {before after : List Nat}
    (h : wins r before after c) : c ≤ price r before after := by
  obtain ⟨hr, hb, ha⟩ := h
  apply le_foldr_min r c hr
  intro x hx
  rcases List.mem_append.mp hx with hx | hx
  · exact Nat.le_of_lt (hb x hx)
  · exact ha x hx

/-- If the true cost would not win, the price does not exceed it. -/
theorem price_le_cost_of_not_wins {r c : Nat} {before after : List Nat}
    (h : ¬ wins r before after c) : price r before after ≤ c := by
  unfold wins at h
  unfold price
  by_cases hr : c ≤ r
  · by_cases hb : ∀ x ∈ before, c < x
    · -- some later bidder bid strictly below c
      have : ¬ ∀ x ∈ after, c ≤ x := fun ha => h ⟨hr, hb, ha⟩
      obtain ⟨x, hx, hlt⟩ : ∃ x ∈ after, ¬ c ≤ x := by
        apply Classical.byContradiction
        intro hne
        exact this (fun x hx => Classical.byContradiction (fun hn => hne ⟨x, hx, hn⟩))
      have := foldr_min_le_mem r (before ++ after) x (List.mem_append_right _ hx)
      omega
    · -- some earlier bidder bid at or below c
      obtain ⟨x, hx, hle⟩ : ∃ x ∈ before, ¬ c < x := by
        apply Classical.byContradiction
        intro hne
        exact hb (fun x hx => Classical.byContradiction (fun hn => hne ⟨x, hx, hn⟩))
      have := foldr_min_le_mem r (before ++ after) x (List.mem_append_left _ hx)
      omega
  · -- the cost is above the reserve, and the price never is
    have := foldr_min_le_init r (before ++ after)
    omega

/-! ### Main result -/

/-- **Truthful bidding is weakly dominant under `award.vickrey`.**
    For every reserve, every profile of other bids (any number, any commit order),
    every true cost `c` and every alternative bid `b`, bidding `c` pays at least as
    much as bidding `b`. -/
theorem truthful_dominant (r : Nat) (before after : List Nat) (c b : Nat) :
    utility r before after c b ≤ utility r before after c c := by
  unfold utility
  by_cases hc : wins r before after c <;> by_cases hb : wins r before after b <;>
    simp only [hc, hb, ite_true, ite_false]
  · exact Int.le_refl _
  · have := cost_le_price_of_wins hc
    omega
  · have := price_le_cost_of_not_wins hc
    omega
  · exact Int.le_refl _

/-! ### Supporting properties stated in the ERC -/

/-- Condition 5 (monotonicity): lowering a winning bid keeps it winning. -/
theorem wins_of_le {r : Nat} {before after : List Nat} {b b' : Nat}
    (h : wins r before after b) (hle : b' ≤ b) : wins r before after b' := by
  obtain ⟨hr, hb, ha⟩ := h
  exact ⟨Nat.le_trans hle hr,
         fun x hx => Nat.lt_of_le_of_lt hle (hb x hx),
         fun x hx => Nat.le_trans hle (ha x hx)⟩

/-- Condition 3: the price never exceeds the reserve. -/
theorem price_le_reserve (r : Nat) (before after : List Nat) : price r before after ≤ r :=
  foldr_min_le_init r _

/-- A winner is never paid less than its own bid (individual rationality at the true cost). -/
theorem bid_le_price_of_wins {r b : Nat} {before after : List Nat}
    (h : wins r before after b) : b ≤ price r before after :=
  cost_le_price_of_wins h

/-- Truthful bidding never yields a negative payoff. -/
theorem truthful_nonneg (r : Nat) (before after : List Nat) (c : Nat) :
    0 ≤ utility r before after c c := by
  unfold utility
  by_cases hc : wins r before after c <;> simp only [hc, ite_true, ite_false]
  · have := cost_le_price_of_wins hc
    omega
  · exact Int.le_refl _

/-! ### Control: first-price is not truthful

Under first-price the winner is paid its own bid. A bidder with cost 40 facing a single
other bid of 80 (reserve 100) gains by shading up to 79. This is the same control check
as in `test/mechanisms.test.js`; it shows the dominance property is not vacuous. -/

def firstPriceUtility (r : Nat) (before after : List Nat) (c b : Nat) : Int :=
  if wins r before after b then (b : Int) - c else 0

example : firstPriceUtility 100 [] [80] 40 79 > firstPriceUtility 100 [] [80] 40 40 := by
  decide

end VickreyAward
