// Mechanism tests: golden vectors + property checks from the ERC's Specification.
//   (1) determinism  (2) no winner above reserve  (3) no price above reserve
//   (4) unique winners, count <= units  (5) monotonicity  (6) ties to earlier commit
// Plus, for Vickrey: truthful bidding is a dominant strategy (checked by brute force).
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const { makeVM, DEPLOYER } = require("./harness");

const A = (i) => "0x" + (0x2000 + i).toString(16).padStart(40, "0");
const R = 100n; // reserve used throughout unless a vector says otherwise
const norm = (out) => out[0].map(([w, p]) => ({ winner: w.toLowerCase(), price: BigInt(p) }));

async function main() {
  const h = await makeVM();
  await h.fund(DEPLOYER);
  const mech = {
    "award.first-price": await h.deploy("FirstPriceAward"),
    "award.vickrey": await h.deploy("VickreyAward"),
    "award.uniform-price": await h.deploy("UniformPriceAward"),
    "award.posted-price": await h.deploy("PostedPriceAward"),
  };
  const award = async (m, bids, reserve = R, units = 1n) =>
    norm((await h.call(mech[m], "award", [bids.map(([b, a]) => [b, a]), reserve, units])).out);

  let passed = 0;
  const ok = (cond, msg) => {
    assert(cond, msg);
    passed++;
  };

  // ── mechanismId + ERC-165 ───────────────────────────────────────────────────
  const { keccak256, toUtf8Bytes } = require("ethers");
  for (const [name, c] of Object.entries(mech)) {
    const id = (await h.call(c, "mechanismId")).out[0];
    ok(id === keccak256(toUtf8Bytes(name)).slice(0, 10), `${name}: mechanismId`);
    const iface = (await h.call(c, "supportsInterface", ["0x01ffc9a7"])).out[0];
    ok(iface === true, `${name}: ERC-165`);
  }

  // ── Golden vectors ──────────────────────────────────────────────────────────
  // Each vector: bids in commit order, reserve, units, expected award per mechanism.
  const vectors = [
    {
      name: "three bidders, all under reserve",
      bids: [[A(1), 70n], [A(2), 40n], [A(3), 55n]], reserve: 100n, units: 1n,
      expect: {
        "award.first-price": [{ winner: A(2), price: 40n }],
        "award.vickrey": [{ winner: A(2), price: 55n }],
        "award.uniform-price": [{ winner: A(2), price: 55n }],
        "award.posted-price": [{ winner: A(1), price: 100n }],
      },
    },
    {
      name: "single bidder pays the reserve under Vickrey and uniform",
      bids: [[A(1), 60n]], reserve: 100n, units: 1n,
      expect: {
        "award.first-price": [{ winner: A(1), price: 60n }],
        "award.vickrey": [{ winner: A(1), price: 100n }],
        "award.uniform-price": [{ winner: A(1), price: 100n }],
        "award.posted-price": [{ winner: A(1), price: 100n }],
      },
    },
    {
      name: "lowest bid above reserve: no award",
      bids: [[A(1), 120n], [A(2), 150n]], reserve: 100n, units: 1n,
      expect: { "award.first-price": [], "award.vickrey": [], "award.uniform-price": [], "award.posted-price": [] },
    },
    {
      name: "second-lowest above reserve: Vickrey price capped at reserve",
      bids: [[A(1), 130n], [A(2), 80n]], reserve: 100n, units: 1n,
      expect: {
        "award.first-price": [{ winner: A(2), price: 80n }],
        "award.vickrey": [{ winner: A(2), price: 100n }],
        "award.uniform-price": [{ winner: A(2), price: 100n }],
        "award.posted-price": [{ winner: A(2), price: 100n }],
      },
    },
    {
      name: "tie goes to the earlier commit",
      bids: [[A(1), 50n], [A(2), 50n], [A(3), 50n]], reserve: 100n, units: 1n,
      expect: {
        "award.first-price": [{ winner: A(1), price: 50n }],
        "award.vickrey": [{ winner: A(1), price: 50n }],
        "award.uniform-price": [{ winner: A(1), price: 50n }],
        "award.posted-price": [{ winner: A(1), price: 100n }],
      },
    },
    {
      name: "no bids at all",
      bids: [], reserve: 100n, units: 1n,
      expect: { "award.first-price": [], "award.vickrey": [], "award.uniform-price": [], "award.posted-price": [] },
    },
    {
      name: "three units, five bidders, clearing price is the fourth bid",
      bids: [[A(1), 90n], [A(2), 30n], [A(3), 60n], [A(4), 45n], [A(5), 75n]], reserve: 100n, units: 3n,
      expect: {
        "award.first-price": [{ winner: A(2), price: 30n }, { winner: A(4), price: 45n }, { winner: A(3), price: 60n }],
        "award.uniform-price": [{ winner: A(2), price: 75n }, { winner: A(4), price: 75n }, { winner: A(3), price: 75n }],
        "award.posted-price": [{ winner: A(1), price: 100n }, { winner: A(2), price: 100n }, { winner: A(3), price: 100n }],
      },
    },
    {
      name: "three units, only two bidders under reserve: two awards, uniform price is the reserve",
      bids: [[A(1), 30n], [A(2), 45n], [A(3), 140n]], reserve: 100n, units: 3n,
      expect: {
        "award.first-price": [{ winner: A(1), price: 30n }, { winner: A(2), price: 45n }],
        "award.uniform-price": [{ winner: A(1), price: 100n }, { winner: A(2), price: 100n }],
        "award.posted-price": [{ winner: A(1), price: 100n }, { winner: A(2), price: 100n }],
      },
    },
    {
      name: "two units, exactly two bidders: uniform price is the reserve",
      bids: [[A(1), 30n], [A(2), 45n]], reserve: 100n, units: 2n,
      expect: {
        "award.first-price": [{ winner: A(1), price: 30n }, { winner: A(2), price: 45n }],
        "award.uniform-price": [{ winner: A(1), price: 100n }, { winner: A(2), price: 100n }],
        "award.posted-price": [{ winner: A(1), price: 100n }, { winner: A(2), price: 100n }],
      },
    },
  ];

  const golden = [];
  for (const v of vectors) {
    const record = { name: v.name, reserve: v.reserve.toString(), units: v.units.toString(), bids: v.bids.map(([b, a]) => ({ bidder: b, amount: a.toString() })), expected: {} };
    for (const [m, exp] of Object.entries(v.expect)) {
      const got = await award(m, v.bids, v.reserve, v.units);
      assert.deepStrictEqual(got, exp.map((e) => ({ winner: e.winner.toLowerCase(), price: e.price })), `${m}: ${v.name}`);
      passed++;
      record.expected[m] = exp.map((e) => ({ winner: e.winner, price: e.price.toString() }));
    }
    golden.push(record);
  }
  fs.writeFileSync(path.join(__dirname, "..", "vectors", "award-vectors.json"), JSON.stringify(golden, null, 2));

  // Vickrey must refuse units != 1
  await assert.rejects(h.call(mech["award.vickrey"], "award", [[[A(1), 10n]], R, 2n]), /units must be 1/);
  passed++;

  // ── Property checks over a small exhaustive grid ────────────────────────────
  // Amounts in {20,40,60,80,120}, 3 bidders → 125 profiles; units in {1,2}.
  const grid = [20n, 40n, 60n, 80n, 120n];
  const profiles = [];
  for (const a of grid) for (const b of grid) for (const c of grid) profiles.push([a, b, c]);

  for (const [m, c] of Object.entries(mech)) {
    const unitsList = m === "award.vickrey" ? [1n] : [1n, 2n];
    for (const units of unitsList) {
      for (const p of profiles) {
        const bids = p.map((amt, i) => [A(i + 1), amt]);
        const out = await award(m, bids, R, units);
        const again = await award(m, bids, R, units);
        assert.deepStrictEqual(out, again, `${m}: deterministic`);
        assert(out.length <= Number(units), `${m}: count <= units`);
        const seen = new Set();
        for (const w of out) {
          assert(!seen.has(w.winner), `${m}: duplicate winner`);
          seen.add(w.winner);
          const bid = bids.find(([b]) => b.toLowerCase() === w.winner)[1];
          assert(bid <= R, `${m}: winner above reserve`);
          assert(w.price <= R, `${m}: price above reserve`);
          if (m === "award.first-price") assert(w.price === bid, "first-price pays own bid");
          if (m === "award.posted-price") assert(w.price === R, "posted-price pays the reserve");
          else assert(w.price >= bid, `${m}: winner never paid less than own bid`);
        }
        // Monotonicity: lowering any one bid must not remove that bidder from the award.
        for (let i = 0; i < 3; i++) {
          if (!out.some((w) => w.winner === A(i + 1).toLowerCase())) continue;
          for (const lower of grid.filter((x) => x < p[i])) {
            const bids2 = bids.map(([b, amt], j) => (j === i ? [b, lower] : [b, amt]));
            const out2 = await award(m, bids2, R, units);
            assert(out2.some((w) => w.winner === A(i + 1).toLowerCase()), `${m}: monotonicity violated`);
          }
        }
        passed++;
      }
    }
  }

  // ── Vickrey: truthful bidding is dominant ───────────────────────────────────
  // For each profile of true costs and each bidder, utility from bidding truthfully
  // must be >= utility from any deviation, holding others fixed.
  // utility = price - cost if winner, else 0.
  const util = (out, who, cost) => {
    const w = out.find((x) => x.winner === who.toLowerCase());
    return w ? w.price - cost : 0n;
  };
  let checks = 0;
  for (const costs of profiles) {
    for (let i = 0; i < 3; i++) {
      const truthful = costs.map((c, j) => [A(j + 1), c]);
      const uT = util(await award("award.vickrey", truthful), A(i + 1), costs[i]);
      for (const dev of grid) {
        if (dev === costs[i]) continue;
        const bids = truthful.map(([b, c], j) => (j === i ? [b, dev] : [b, c]));
        const uD = util(await award("award.vickrey", bids), A(i + 1), costs[i]);
        assert(uT >= uD, `vickrey not truthful: costs=${costs} i=${i} dev=${dev} uT=${uT} uD=${uD}`);
        checks++;
      }
    }
  }
  passed++;
  console.log(`vickrey dominant-strategy checks: ${checks}`);

  // ── First-price is NOT truthful (sanity: the property really discriminates) ──
  {
    const truthful = [[A(1), 40n], [A(2), 80n], [A(3), 90n]];
    const uT = util(await award("award.first-price", truthful), A(1), 40n);
    const uD = util(await award("award.first-price", [[A(1), 79n], [A(2), 80n], [A(3), 90n]]), A(1), 40n);
    ok(uD > uT, "first-price rewards shading (control check)");
  }

  // ── Posted price: accepting iff cost <= reserve is dominant ───────────────────
  // Under award.posted-price a bid is an acceptance. The truthful action is to accept (bid R)
  // when cost <= R and decline (bid above R) otherwise. No deviation, at any commit position,
  // can do better.
  let pchecks = 0;
  const DECLINE = 120n;
  for (const costs of profiles) {
    for (let i = 0; i < 3; i++) {
      const others = costs.map((c, j) => [A(j + 1), c <= R ? R : DECLINE]); // others play truthfully
      const truthfulBid = costs[i] <= R ? R : DECLINE;
      const play = (b) => others.map(([a, x], j) => (j === i ? [a, b] : [a, x]));
      const uT = util(await award("award.posted-price", play(truthfulBid)), A(i + 1), costs[i]);
      for (const dev of grid) {
        const uD = util(await award("award.posted-price", play(dev)), A(i + 1), costs[i]);
        assert(uT >= uD, `posted-price acceptance not dominant: costs=${costs} i=${i} dev=${dev}`);
        pchecks++;
      }
    }
  }
  passed++;
  console.log(`posted-price dominance checks: ${pchecks}`);

  // ── Fixed reward + bid ranking is not truthful (SergeevDmitry's example) ───────
  // Ranking by bid but paying a fixed reward of 100: cost 60 against a bid of 50.
  {
    const fixedUtil = (out, who, cost) => (out.some((x) => x.winner === who.toLowerCase()) ? 100n - cost : 0n);
    const truthful = await award("award.first-price", [[A(1), 60n], [A(2), 50n]]);
    const shaded = await award("award.first-price", [[A(1), 40n], [A(2), 50n]]);
    ok(fixedUtil(truthful, A(1), 60n) === 0n && fixedUtil(shaded, A(1), 60n) === 40n,
      "fixed reward with bid ranking rewards underbidding (counterexample)");
  }

  console.log(`mechanisms: ${passed} assertions passed`);
}

main().catch((e) => {
  console.error("FAIL:", e.message);
  process.exit(1);
});
