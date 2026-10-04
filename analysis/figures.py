"""Figures for the ethresear.ch post. Reads results.json from auction_numbers.py."""
import json
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

R = json.load(open("results.json"))

SURFACE = "#fcfcfb"
INK = "#1f1f1e"       # primary text
INK2 = "#5c5b55"      # secondary text
GRIDC = "#e4e3dc"
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]  # validated, fixed order
MARKERS = ["o", "s", "^", "D"]

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "font.family": "DejaVu Sans", "font.size": 11,
    "axes.edgecolor": GRIDC, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRIDC, "grid.linewidth": 0.8,
    "axes.titlesize": 13, "axes.titleweight": "bold", "axes.titlecolor": INK, "axes.titlelocation": "left",
})


def finish(fig, ax, title, subtitle, path):
    ax.set_title(title, pad=40)
    ax.text(0, 1.02, subtitle, transform=ax.transAxes, color=INK2, fontsize=10, va="bottom")
    fig.tight_layout()
    fig.savefig(path, dpi=200)
    plt.close(fig)


# ── Figure 1: requester surplus vs reserve ─────────────────────────────────────
fig, ax = plt.subplots(figsize=(8, 4.8))
r = np.array(R["reserve_curve"]["r"])
for i, (n, ys) in enumerate(R["reserve_curve"]["by_n"].items()):
    ys = np.array(ys)
    ax.plot(r, ys, color=SERIES[i], lw=2, label=f"n = {n}")
    j = int(np.argmin(abs(r - 0.5)))
    ax.plot([0.5], [ys[j]], marker=MARKERS[i], color=SERIES[i], ms=8, mec=SURFACE, mew=2, zorder=3)
    ax.text(1.01, ys[-1], f"n = {n}", color=INK, va="center", fontsize=10, transform=ax.get_yaxis_transform())
ax.axvline(0.5, color=INK2, lw=1, ls=(0, (4, 3)))
ax.text(0.51, 0.04, "optimal reserve ψ⁻¹(1) = 0.5\nfor every n", color=INK2, fontsize=9.5, va="bottom")
ax.set_xlim(0, 1)
ax.set_ylim(0, 0.9)
ax.set_xlabel("reserve r (requester value = 1)")
ax.set_ylabel("requester expected surplus")
ax.legend(frameon=False, loc="lower right", fontsize=9.5)
finish(fig, ax, "A tight reserve matters with few bidders",
       "Second-price procurement, costs i.i.d. U[0,1]. Surplus gain from r = 0.5 over r = 1:\n"
       "25% (n = 2), 6.2% (n = 3), 0.8% (n = 5), under 0.1% (n = 10).",
       "fig1_reserve.png")

# ── Figure 2: ladder gain under first-price ────────────────────────────────────
fig, ax = plt.subplots(figsize=(8, 4.8))
for i, (n, L) in enumerate(R["ladder"].items()):
    k = np.array(L["k"])
    g = 100 * np.array(L["gain_vs_sealed"]) / 0.5  # % of reserve
    ax.plot(k, g, color=SERIES[i], lw=2, marker=MARKERS[i], ms=7, mec=SURFACE, mew=1.5, label=f"n = {n}")
    nudge = {"3": 0.9, "5": -0.9}.get(n, 0.0)
    ax.text(k[-1] * 1.12, g[-1] + nudge, f"n = {n}", color=INK, va="center", fontsize=10)
ax.set_xscale("log", base=2)
ax.set_xticks([1, 2, 4, 8, 16, 32, 64])
ax.set_xticklabels(["1", "2", "4", "8", "16", "32", "64"])
ax.set_xlim(0.9, 110)
ax.set_ylim(0, 30)
ax.set_xlabel("commitments held by the last revealer, k (k = 1 is the sealed bid)")
ax.set_ylabel("best-case gain over sealed bid, % of reserve")
ax.legend(frameon=False, loc="upper left", fontsize=9.5)
finish(fig, ax, "Under first-price, revealing last is worth a lot",
       "Rivals play the sealed first-price equilibrium, r = 0.5. Gain before forfeited bonds,\n"
       "maximised over the revealer's cost. Under second-price the gain is zero for every k.",
       "fig2_ladder.png")

# ── Figure 3: phantom commitments ──────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(8, 4.8))
rows = R["phantom"]["rows"]
d = np.array([x["d"] for x in rows])
fp = np.array([x["e_payment"] for x in rows])
sp = R["phantom"]["second_price_payment"]
ax.plot(d, np.full_like(fp, sp), color=SERIES[0], lw=2, marker=MARKERS[0], ms=7, mec=SURFACE, mew=1.5,
        label="second-price")
ax.plot(d, fp, color=SERIES[1], lw=2, marker=MARKERS[1], ms=7, mec=SURFACE, mew=1.5, label="first-price")
ax.text(10.3, sp, "second-price", color=INK, va="center", fontsize=10)
ax.text(10.3, fp[-1], "first-price", color=INK, va="center", fontsize=10)
ax.annotate(f"−{100 * (1 - fp[3] / fp[0]):.0f}% at d = 3", xy=(3, fp[3]), xytext=(4.2, 0.30),
            color=INK2, fontsize=9.5, arrowprops=dict(arrowstyle="-", color=INK2, lw=0.8))
ax.set_xlim(-0.3, 12)
ax.set_ylim(0.15, 0.38)
ax.set_xticks(range(0, 11))
ax.set_xlabel("dummy commitments posted by the requester, d (3 real bidders)")
ax.set_ylabel("requester expected payment")
ax.legend(frameon=False, loc="lower left", fontsize=9.5)
finish(fig, ax, "Phantom commitments move first-price, not second-price",
       "Real bidders count visible commitments and play the first-price equilibrium for that count.\n"
       "Reserve r = 0.5, costs i.i.d. U[0,1].",
       "fig3_phantom.png")
print("ok")
