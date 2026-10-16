# Paper

**When Is a Sealed-Bid Task Award Truthful? Composition Conditions for Procurement Auctions in On-Chain Agent Markets**

Shenton Yan, October 2026. Working paper; not yet on arXiv.

[Read the PDF](sealed-bid-award-paper.pdf)

The paper explains the theory behind the draft ERC in this repository:

- the award interface as a direct mechanism in Myerson's procurement framework;
- why incentive compatibility depends on the consuming standard: a fixed reward admits only a
  posted price, and a price-binding consumer must also be execution-binding, with the task
  content fixed at opening;
- three frictions of a public ledger (sequential reveals, dummy commitments, false-name bids),
  where single-unit second-price is robust and first-price and uniform-price are not;
- the Lean 4 proofs and the reference implementation.

Every number in the paper comes from [`analysis/`](../analysis/) or the test suite.

## Build

Any TeX Live with `pdflatex`, `bibtex` and `latexmk`:

```
cd paper
latexmk -pdf main.tex
```

## arXiv

The source is written for arXiv's rules: pdflatex only, standard packages, figures in PDF and
PNG, no comments. To make the upload bundle, put `main.tex`, the generated `main.bbl` and the
three `fig-*` files in one flat folder (no `refs.bib`, no PDF) and zip it.

## Citation

```bibtex
@misc{yan2026sealedbid,
  author = {Yan, Shenton},
  title  = {When Is a Sealed-Bid Task Award Truthful? Composition Conditions for Procurement Auctions in On-Chain Agent Markets},
  year   = {2026},
  note   = {Working paper},
  url    = {https://github.com/shentonyan/sealed-bid-award-erc/tree/main/paper}
}
```
