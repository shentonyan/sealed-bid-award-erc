/-
  Integration profiles: what the truthfulness result does and does not cover.

  `VickreyTruthful.lean` proves that truthful bidding is dominant when the winner is paid
  the award price. This file records the two facts that scope it, for the draft ERC
  "Sealed-Bid Award Mechanism for Task Tenders":

  1. If the target ranks by bid but pays a fixed reward (an allocation-only integration),
     truthful bidding is not dominant. The counterexample is the one SergeevDmitry gave on
     the Ethereum Magicians thread: reward 100, true cost 60, another bid of 50.

  2. Under `award.posted-price`, where every bid at or below the reserve is an acceptance and
     the earliest acceptance wins at the reserve, accepting exactly when cost ≤ reserve is a
     weakly dominant strategy, at any commit position.

  Checked with core Lean 4 (v4.34.0). No Mathlib.
-/

namespace IntegrationProfiles

/-! ### 1. Fixed reward with bid ranking is not truthful -/

/-- Bidder `i` wins a bid-ranked award (same rule as `VickreyAward.wins`): within the
    reserve, strictly below every earlier bid, at most every later bid. -/
def ranks (r : Nat) (before after : List Nat) (b : Nat) : Prop :=
  b ≤ r ∧ (∀ x ∈ before, b < x) ∧ (∀ x ∈ after, b ≤ x)

instance (r : Nat) (before after : List Nat) (b : Nat) : Decidable (ranks r before after b) := by
  unfold ranks; exact inferInstance

/-- Payoff when the target ignores the award price and pays a fixed `reward`. -/
def fixedRewardUtility (reward r : Nat) (before after : List Nat) (c b : Nat) : Int :=
  if ranks r before after b then (reward : Int) - c else 0

/-- SergeevDmitry's example: reward 100, reserve 100, cost 60, one earlier bid of 50.
    Bidding the true cost loses; bidding 40 wins and earns 40. -/
theorem fixed_reward_not_truthful :
    fixedRewardUtility 100 100 [50] [] 60 40 > fixedRewardUtility 100 100 [50] [] 60 60 := by
  decide

/-- More generally: with a fixed reward, any bidder whose cost is below the reward weakly
    prefers the lowest possible bid to its true cost. Bidding lower never loses a win. -/
theorem fixed_reward_lowest_bid_weakly_better (reward r : Nat) (before after : List Nat) (c : Nat)
    (hc : c ≤ reward) :
    fixedRewardUtility reward r before after c c ≤ fixedRewardUtility reward r before after c 0 := by
  unfold fixedRewardUtility
  by_cases hw : ranks r before after c
  · have h0 : ranks r before after 0 := by
      obtain ⟨hr, hb, ha⟩ := hw
      exact ⟨Nat.zero_le _, fun x hx => Nat.lt_of_le_of_lt (Nat.zero_le _) (hb x hx),
             fun x _ => Nat.zero_le x⟩
    simp only [hw, h0, ite_true]
    exact Int.le_refl _
  · simp only [hw, ite_false]
    by_cases h0 : ranks r before after 0
    · simp only [h0, ite_true]; omega
    · simp only [h0, ite_false]; exact Int.le_refl _

/-! ### 2. Posted price: accepting iff cost ≤ reserve is dominant -/

/-- Under `award.posted-price` with one unit, bidder `i` wins iff its bid is an acceptance
    (at most the reserve) and no earlier committer accepted. Whether an earlier committer
    accepted depends only on the others' bids, never on `i`'s amount. -/
def postedWins (r : Nat) (earlierAccepted : Bool) (b : Nat) : Prop :=
  b ≤ r ∧ earlierAccepted = false

instance (r : Nat) (e : Bool) (b : Nat) : Decidable (postedWins r e b) := by
  unfold postedWins; exact inferInstance

/-- The winner is paid the reserve. -/
def postedUtility (r : Nat) (e : Bool) (c b : Nat) : Int :=
  if postedWins r e b then (r : Int) - c else 0

/-- The truthful action: accept (bid the reserve) iff cost ≤ reserve, otherwise decline. -/
def accept (r c : Nat) : Nat := if c ≤ r then r else r + 1

/-- **Accepting iff cost ≤ reserve is weakly dominant under `award.posted-price`,** for every
    reserve, cost, alternative bid, and every outcome of the earlier commitments. -/
theorem posted_price_acceptance_dominant (r : Nat) (e : Bool) (c b : Nat) :
    postedUtility r e c b ≤ postedUtility r e c (accept r c) := by
  unfold postedUtility accept postedWins
  cases e <;> by_cases hc : c ≤ r <;> by_cases hb : b ≤ r <;> simp [hc, hb] <;> omega

end IntegrationProfiles
