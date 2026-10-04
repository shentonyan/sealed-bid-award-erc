# Analysis

Numbers and figures for the ethresear.ch post on commit–reveal procurement auctions.
Model: procurement, costs i.i.d. U[0,1], requester value 1, so the optimal reserve is 0.5.
Expectations are exact numerical integrals over order statistics; revenue equivalence is
cross-checked by Monte Carlo.

```
pip install numpy scipy matplotlib
python auction_numbers.py   # prints the tables, writes results.json
python figures.py           # writes fig1_reserve.png, fig2_ladder.png, fig3_phantom.png
```

| Figure | What it shows |
| --- | --- |
| `fig1_reserve.png` | Requester surplus against the reserve, for 2, 3, 5 and 10 bidders |
| `fig2_ladder.png` | Gain from holding k commitments and revealing last, under first-price |
| `fig3_phantom.png` | Requester's expected payment against dummy commitments, first- vs second-price |

The ladder places rungs evenly between the bidder's equilibrium bid and the reserve; a
better-placed ladder gains more, so the bond figures derived from it are lower bounds.
The phantom-commitment model assumes bidders take the visible commitment count at face value.
