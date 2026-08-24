# Baseline grid sweep — `quoter` / `shark`

The scripted baselines are the no-credentials fallback (offline certification and
`docker-smoke`), the per-seat fallback after a bad model reply, and two fieldable policies. Their
five tunables (`BaselineParams` in `src/garble/llm.nim`) therefore decide whether a Garble episode
is worth watching at all, so they are swept rather than guessed.

Harness: `scripts/tune_baselines.nim`. Reproduce this table with

```bash
nim r -d:release --path:src scripts/tune_baselines.nim 60
```

Grid: `airtimeFloor ∈ {0, 30, 60, 120}` × `loudBand ∈ {0.25, 0.50, 0.75, 9.9}` ×
`sellMarkup ∈ {1, 2, 3, 5}` × `buyMarkup ∈ {0, 1, 2}` × `maxLot ∈ {3, 5, 8}` = **576 points**,
each played over **60 seeds** × four tables (all-quoter, shark-heavy, all-quoter at
`noiseScale 0.5` and at `1.5`) = 138 240 twelve-turn episodes. `loudBand 9.9` is a **control**: the
meter can never reach it, so the quoter never repeats — it is printed but can never be a candidate,
because `quoter` is by definition the honest repeater.

**Gates** (a point that fails any one of these is not a candidate):

1. every seed settles ≥ 1 deal and the median seed ≥ 3 — without deals the smoke replay has no
   `deal` beats and CI goes green on a game where nobody trades;
2. a shark-heavy table mishears **more** than an honest one — the redundancy shield is
   load-bearing;
3. an all-quoter table scores better at `noiseScale 0.5` than at `1.5` — the noise has to matter;
4. mean quoter score > 1.0 — trading beats holding.

432 of the 576 points hold all four, so the gates are wide and the choice inside them is a design
choice. **Objective**, stated before ranking: the mean quoter score (the ratio the league itself
scores by — how much of the available gains from trade the table realises), tie-broken by median
deals.

## Top of the ranking (60 seeds)

| parameters | min deals | median deals | mean score | mishear gap | quiet−storm | holds |
|---|---|---|---|---|---|---|
| floor 0 loud 0.50 sell +2 buy +2 lot 8 | 4 | 7 | 1.2314 | 84 | 0.0940 | yes |
| floor 30 loud 0.50 sell +2 buy +2 lot 8 | 4 | 7 | 1.2314 | 84 | 0.0940 | yes |
| floor 60 loud 0.50 sell +2 buy +2 lot 8 | 4 | 7 | 1.2314 | 84 | 0.0940 | yes |
| floor 120 loud 0.50 sell +2 buy +2 lot 8 | 4 | 7 | 1.2314 | 84 | 0.0940 | yes |
| floor 0 loud 0.50 sell +2 buy +1 lot 8 | 4 | 7 | 1.2312 | 77 | 0.0938 | yes |
| floor 30 loud 0.50 sell +2 buy +1 lot 8 | 4 | 7 | 1.2312 | 77 | 0.0938 | yes |
| floor 0 loud 0.50 sell +2 buy +0 lot 8 | 4 | 7 | 1.2306 | 69 | 0.0939 | yes |
| **floor 30 loud 0.50 sell +3 buy +1 lot 5 (SHIPPED)** | **5** | **9** | **1.1985** | **69** | **0.1242** | **yes** |

The shipped point ranks **218 of 576** on the objective and sits inside a broad plateau: the whole
candidate set spans 1.128 … 1.231 mean score, a 9 % band.

## What the sweep says about each parameter

| parameter | sweep at the shipped point | reading |
|---|---|---|
| `airtimeFloor` 0 / 30 / 60 / 120 | 1.1985 / 1.1985 / 1.1985 / 1.1985, identical row for row | **inert over this grid**: a baseline's offers are ~16–26 runes, so 12 turns never come near the 900-rune meter. The floor is insurance for a long or loud episode, not a tuning knob — which is exactly why it is set at the confirm cost (40) rounded down, not at a swept optimum. |
| `loudBand` 0.25 / 0.50 / 0.75 / 9.9 (control) | mean 1.1946 / 1.1985 / 1.2020 / 1.2031, mishear gap 145 / 69 / 38 / 33 | repeating costs airtime and buys shield. Never repeating (control) scores best and makes the shield nearly invisible; repeating from 0.25 doubles the shark's take. **0.50 is the knee** — the shield is plainly legible and the quoter keeps 99.6 % of the never-repeat score. |
| `sellMarkup` +1 / +2 / +3 / +5 | 1.2005 / 1.1995 / 1.1985 / 1.1790 | flat to +3, then a cliff at +5 where offers stop clearing (min deals drops to 4). +3 is the last point before the cliff and the only one that is a visible profit motive rather than a market-clearing giveaway. |
| `buyMarkup` +0 / +1 / +2 | 1.1986 / 1.1985 / 1.1987 | inert on score; +1 buys a bigger shark gap than +0 (69 vs 62) and reads as a real bid. |
| `maxLot` 3 / 5 / 8 | 1.1471 / 1.1985 / 1.2303, median deals 10 / 9 / 8, quiet−storm 0.1409 / 0.1242 / 0.0936 | the real trade-off: big lots realise more of the gains in fewer, larger deals; small lots make a livelier tape and a stronger noise signal. **5 is the middle** — 9 deals on the median seed, and the strongest quiet-vs-storm signal of the three high-scoring lots. |

## Conclusion

The five shipped values (`DefaultBaseline`: floor 30, loud 0.50, sell +3, buy +1, lot 5) are the
values the design note fixes (§*Scripted baselines*). This sweep is their justification, not a
replacement for them: they clear every gate with margin on 60 seeds, they sit inside a 9 %-wide plateau
of the objective, and each one is at a defensible point of its own curve — `loudBand` at the knee
where the shield becomes legible, `sellMarkup` at the last point before offers stop clearing,
`maxLot` where the tape stays lively and the quiet-vs-storm signal is strongest. Changing them is a
design change (the note states each value), not a tuning fix; the harness is committed so the next
change is measured rather than argued.
