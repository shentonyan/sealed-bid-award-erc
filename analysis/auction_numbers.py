"""
Quantitative companion to the ethresear.ch post.

Model: procurement, n bidders, i.i.d. costs c ~ U[0,1], requester value v0 = 1.
Virtual cost psi(c) = c + F(c)/f(c) = 2c, so the optimal reserve is psi^{-1}(1) = 1/2.

All expectations are computed by numerical integration over the order statistics
(no Monte Carlo), except a Monte Carlo cross-check of revenue equivalence.
"""
import json
import numpy as np
from scipy import integrate

V0 = 1.0
GRID = 4001  # quadrature points


# ── First-price symmetric equilibrium with reserve r (procurement) ─────────────
def beta(c, n, r):
    """Equilibrium bid of a bidder with cost c <= r when it believes there are n bidders."""
    c = np.asarray(c, dtype=float)
    num = (1 - c) ** n - (1 - r) ** n
    den = n * (1 - c) ** (n - 1)
    return np.where(c <= r, c + num / den, np.inf)


def min_other_density(x, n_others):
    """Density of the minimum of n_others i.i.d. U[0,1] costs."""
    return n_others * (1 - x) ** (n_others - 1)


# ── 1. Value of the reserve ─────────────────────────────────────────────────────
def surplus_second_price(n, r):
    """E[(v0 - price) 1{award}] under second-price with reserve r.
    By revenue equivalence = E[(v0 - psi(c_(1))) 1{c_(1) <= r}]."""
    f = lambda c: (V0 - 2 * c) * n * (1 - c) ** (n - 1)
    return integrate.quad(f, 0, r)[0]


def mc_check(n, r, trials=400_000, seed=1):
    rng = np.random.default_rng(seed)
    c = rng.random((trials, n))
    s = np.sort(c, axis=1)
    award = s[:, 0] <= r
    sp_price = np.minimum(s[:, 1] if n > 1 else np.full(trials, r), r)
    fp_price = beta(s[:, 0], n, r)
    sp = np.where(award, V0 - sp_price, 0).mean()
    fp = np.where(award, V0 - fp_price, 0).mean()
    return sp, fp


# ── 2. The last-reveal ladder under first-price ────────────────────────────────
def ladder_gross(c, n, r, k):
    """Deviant with cost c holds k commitments at bids equally spaced from beta(c) to r,
    reveals last, sees m = min of the other n-1 revealed bids, and reveals the highest rung
    below m. Returns expected gross payoff (before forfeited bonds)."""
    b0 = float(beta(c, n, r))
    rungs = np.array([b0]) if k == 1 else b0 + (r - b0) * np.arange(k) / (k - 1)
    x = np.linspace(0, 1, GRID)
    dens = min_other_density(x, n - 1)
    m = beta(x, n, r)  # inf where the cheapest other bidder is above the reserve
    # best rung strictly below m (all rungs are <= r)
    idx = np.searchsorted(rungs, m, side="left") - 1
    pay = np.where(idx >= 0, rungs[np.clip(idx, 0, None)] - c, 0.0)
    pay = np.maximum(pay, 0.0)
    return np.trapezoid(pay * dens, x)


def ladder_analysis(n, r, ks=(1, 2, 3, 4, 6, 8, 12, 16, 32, 64)):
    cs = np.linspace(0, r, 101)[:-1]
    out = {"k": list(ks), "gain_vs_sealed": [], "bond_to_deter": None}
    best_ratio = 0.0
    gains_by_k = []
    for k in ks:
        g = np.array([ladder_gross(c, n, r, k) - ladder_gross(c, n, r, 1) for c in cs])
        gains_by_k.append(g)
        out["gain_vs_sealed"].append(float(g.max()))
        if k > 1:
            best_ratio = max(best_ratio, float((g / (k - 1)).max()))
    out["bond_to_deter"] = best_ratio
    # limiting gain of the option (k large), as a share of the bidder's sealed payoff
    sealed = np.array([ladder_gross(c, n, r, 1) for c in cs])
    lim = gains_by_k[-1]
    with np.errstate(divide="ignore", invalid="ignore"):
        rel = np.where(sealed > 1e-9, lim / sealed, np.nan)
    out["max_relative_gain"] = float(np.nanmax(rel))
    out["ex_ante_gain"] = float(np.trapezoid(lim * 1.0, cs) / 1.0)  # integral over c in [0,r] of gain (density 1)
    return out


# ── 3. Phantom commitments under first-price ───────────────────────────────────
def phantom(n_real, d, r):
    """Real bidders see n_real + d commitments and bid beta(., n_real + d, r).
    Returns requester's expected payment conditional on award, and P(award)."""
    n_seen = n_real + d
    x = np.linspace(0, r, GRID)
    dens = n_real * (1 - x) ** (n_real - 1)  # density of the real minimum cost
    pay = beta(x, n_seen, r)
    p_award = 1 - (1 - r) ** n_real
    e_pay = np.trapezoid(pay * dens, x)  # E[price 1{award}]
    return float(e_pay), float(p_award)


def main():
    res = {}

    # 1. reserve
    ns = [2, 3, 5, 10]
    rs = np.linspace(0.05, 1.0, 96)
    res["reserve_curve"] = {"r": rs.tolist(), "by_n": {}}
    table = []
    for n in ns:
        curve = [surplus_second_price(n, r) for r in rs]
        res["reserve_curve"]["by_n"][str(n)] = curve
        s_opt, s_budget = surplus_second_price(n, 0.5), surplus_second_price(n, 1.0)
        sp_mc, fp_mc = mc_check(n, 0.5)
        table.append({
            "n": n, "surplus_r_half": s_opt, "surplus_r_one": s_budget,
            "gain_pct": 100 * (s_opt / s_budget - 1),
            "mc_second_price": sp_mc, "mc_first_price": fp_mc,
        })
    res["reserve_table"] = table

    # 2. ladder
    res["ladder"] = {str(n): ladder_analysis(n, 0.5) for n in ns}

    # 3. phantom commitments, n_real = 3, r = 0.5
    base_pay, _ = phantom(3, 0, 0.5)
    ph = []
    for d in range(0, 11):
        pay, p = phantom(3, d, 0.5)
        ph.append({"d": d, "e_payment": pay, "saving": base_pay - pay})
    res["phantom"] = {"n_real": 3, "r": 0.5, "rows": ph}

    # Second-price is unaffected by d: the expected payment is the same for every d.
    sp_pay = 0.5 - surplus_second_price(3, 0.5) + 0  # placeholder, replaced below
    # E[price 1{award}] under second-price = P(award)*v0 - surplus
    p_award = 1 - 0.5 ** 3
    res["phantom"]["second_price_payment"] = p_award * V0 - surplus_second_price(3, 0.5)

    json.dump(res, open("results.json", "w"), indent=1)

    # print a compact summary
    print("== Reserve (U[0,1], v0=1) ==")
    for t in table:
        print(f"n={t['n']:>2}  S(r=.5)={t['surplus_r_half']:.4f}  S(r=1)={t['surplus_r_one']:.4f}  "
              f"gain={t['gain_pct']:5.1f}%   MC sp={t['mc_second_price']:.4f} fp={t['mc_first_price']:.4f}")
    print("\n== Ladder under first-price, r=0.5 ==")
    for n, L in res["ladder"].items():
        print(f"n={n:>2}  max gain k=64: {L['gain_vs_sealed'][-1]:.4f}  "
              f"rel gain up to {100*L['max_relative_gain']:.0f}% of sealed payoff  "
              f"bond to deter: {L['bond_to_deter']:.4f} ({100*L['bond_to_deter']/0.5:.1f}% of reserve)")
        print("       gain by k:", [round(g, 4) for g in L["gain_vs_sealed"]])
    print("\n== Phantom commitments, 3 real bidders, r=0.5 ==")
    print(f"second-price E[payment] (any d): {res['phantom']['second_price_payment']:.4f}")
    for row in ph:
        print(f"d={row['d']:>2}  first-price E[payment]={row['e_payment']:.4f}  saving={row['saving']:.4f}")


if __name__ == "__main__":
    main()
