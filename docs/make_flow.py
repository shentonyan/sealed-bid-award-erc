"""Generate the README header diagram in light and dark variants (docs/flow-light.svg, docs/flow-dark.svg)."""
from pathlib import Path

THEMES = {
    "light": dict(ink="#1f2328", ink2="#59636e", line="#d1d9e0", card="#ffffff", soft="#f6f8fa",
                  accent="#2a78d6", accentSoft="#e8f1fc", accentInk="#1c5cab", warn="#b35900"),
    "dark": dict(ink="#f0f6fc", ink2="#9198a1", line="#3d444d", card="#151b23", soft="#0d1117",
                 accent="#3987e5", accentSoft="#13233a", accentInk="#86b6ef", warn="#e0a35c"),
}

W, H = 1000, 430
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI','Noto Sans',Helvetica,Arial,sans-serif"
MONO = "ui-monospace,SFMono-Regular,'SF Mono',Menlo,Consolas,monospace"


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size=13, fill="ink", weight=400, anchor="start", mono=False, c=None):
    fam = MONO if mono else FONT
    return (f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" font-weight="{weight}" '
            f'fill="{c[fill]}" text-anchor="{anchor}">{esc(s)}</text>')


def step(x, y, w, h, n, title, lines, c):
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{c["card"]}" stroke="{c["accent"]}" stroke-width="1.5"/>',
           f'<circle cx="{x + 20}" cy="{y + 22}" r="11" fill="{c["accent"]}"/>',
           text(x + 20, y + 26.5, str(n), 12, "card", 700, "middle", c=c),
           text(x + 38, y + 27, title, 14, "ink", 600, c=c)]
    for i, (s, mono) in enumerate(lines):
        out.append(text(x + 14, y + 52 + i * 19, s, 12.5, "ink2", 400, mono=mono, c=c))
    return "\n".join(out)


def arrow(x1, y1, x2, y2, c, dashed=False, color="accent"):
    dash = ' stroke-dasharray="5 4"' if dashed else ""
    return (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{c[color]}" stroke-width="1.6"{dash} '
            f'marker-end="url(#arrow-{color})"/>')


def target(x, y, w, h, name, lines, c):
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{c["soft"]}" stroke="{c["line"]}" stroke-width="1.2"/>',
           text(x + 14, y + 24, name, 13.5, "ink", 600, c=c)]
    for i, s in enumerate(lines):
        out.append(text(x + 14, y + 44 + i * 17, s, 12, "ink2", c=c))
    return "\n".join(out)


def build(theme):
    c = THEMES[theme]
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
             f'aria-label="Sealed-bid award lifecycle: open, commit, reveal, finalize; the award crosses an authority '
             f'boundary to ERC-8183, ERC-8195 and ERC-8414, each of which decides what the award may change.">',
             "<defs>"]
    for col in ("accent", "ink2"):
        parts.append(f'<marker id="arrow-{col}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
                     f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c[col]}"/></marker>')
    parts.append("</defs>")

    # Companion-standard container
    cx, cy, cw, ch = 16, 16, 640, 398
    parts.append(f'<rect x="{cx}" y="{cy}" width="{cw}" height="{ch}" rx="14" fill="{c["accentSoft"]}" stroke="none"/>')
    parts.append(text(cx + 18, cy + 30, "This ERC: produces an award, holds only bidder bonds", 14, "accentInk", 600, c=c))

    # Four steps in a 2x2 snake: 1 → 2 on top, 3 → 4 below (4 sits under 2 so it can feed the boundary)
    sw, sh = 290, 128
    x1, x2 = cx + 18, cx + 18 + sw + 24
    y1, y2 = cy + 48, cy + 48 + sh + 30
    parts.append(step(x1, y1, sw, sh, 1, "Open", [("reserve r · units · bond B", False),
                                                    ("maxBidders · slashRecipient", False),
                                                    ("targetRef = H(chainId, contract, id)", True)], c))
    parts.append(step(x2, y1, sw, sh, 2, "Commit", [("post H(tenderId, bidder, bid, salt)", True),
                                                      ("lock bond B", False),
                                                      ("at most maxBidders commitments", False)], c))
    parts.append(step(x1, y2, sw, sh, 3, "Reveal", [("open (bid, salt) after commits close", False),
                                                      ("bond returned on a valid reveal", False),
                                                      ("reveals are public, one by one", False)], c))
    parts.append(step(x2, y2, sw, sh, 4, "Finalize", [("award(bids, r, units) → (winner, price)", True),
                                                        ("re-check: price ≤ r, unique winners", False),
                                                        ("unrevealed bonds credited for slashing", False)], c))
    parts.append(arrow(x1 + sw, y1 + sh / 2, x2 - 4, y1 + sh / 2, c))
    # 2 → 3: down from 2's bottom-left area to 3's top-right area
    parts.append(f'<path d="M{x2 + 40} {y1 + sh} C {x2 + 40} {y1 + sh + 22}, {x1 + sw - 40} {y2 - 22}, {x1 + sw - 40} {y2 - 4}" '
                 f'fill="none" stroke="{c["accent"]}" stroke-width="1.6" marker-end="url(#arrow-accent)"/>')
    parts.append(arrow(x1 + sw, y2 + sh / 2, x2 - 4, y2 + sh / 2, c))

    # Mechanism strip
    my = y2 + sh + 14
    parts.append(text(x1, my + 12, "Pricing rule: a swappable pure contract", 12.5, "ink2", c=c))
    parts.append(text(x1, my + 31, "award.first-price · award.vickrey (recommended) · award.uniform-price",
                      12, "accentInk", 500, mono=True, c=c))

    # Authority boundary
    bx = cx + cw + 28
    parts.append(f'<line x1="{bx}" y1="22" x2="{bx}" y2="{H - 22}" stroke="{c["warn"]}" stroke-width="1.6" stroke-dasharray="6 5"/>')
    ly = 130
    parts.append(f'<text x="{bx - 9}" y="{ly}" font-family="{FONT}" font-size="12" font-weight="600" fill="{c["warn"]}" '
                 f'text-anchor="middle" transform="rotate(-90 {bx - 9} {ly})">authority boundary</text>')
    fy = y2 + sh / 2
    parts.append(f'<line x1="{x2 + sw}" y1="{fy}" x2="{bx}" y2="{fy}" stroke="{c["ink2"]}" stroke-width="1.6"/>')
    parts.append(f'<circle cx="{bx}" cy="{fy}" r="3.5" fill="{c["ink2"]}"/>')

    # Targets
    tx, tw, th = bx + 26, W - (bx + 26) - 16, 102
    parts.append(text(tx, 36, "Targets decide what it changes", 12.5, "ink2", 600, c=c))
    ty0 = 50
    gap = (H - 16 - ty0 - 3 * th) / 2
    targets = [
        ("ERC-8183  job escrow", ["client calls setProvider / setBudget", "a hook only checks them against", "the stored award"]),
        ("ERC-8195  task market", ["Auction-mode selection reads", "awardOf instead of a fixed", "lowest-bid rule"]),
        ("ERC-8414  task tender", ["award gates eligibility only;", "rewardPerCompletion stays fixed", "(AwardGatedVerifier)"]),
    ]
    for i, (name, lines) in enumerate(targets):
        ty = ty0 + i * (th + gap)
        parts.append(f'<path d="M{bx} {fy} C {bx + 14} {fy}, {tx - 16} {ty + th / 2}, {tx - 4} {ty + th / 2}" fill="none" '
                     f'stroke="{c["ink2"]}" stroke-width="1.4" marker-end="url(#arrow-ink2)"/>')
        parts.append(target(tx, ty, tw, th, name, lines, c))

    parts.append("</svg>")
    return "\n".join(parts)


if __name__ == "__main__":
    out = Path(__file__).resolve().parent
    for theme in THEMES:
        (out / f"flow-{theme}.svg").write_text(build(theme), encoding="utf-8")
    print("ok")
