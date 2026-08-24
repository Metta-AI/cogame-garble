## Grid harness for the scripted baselines.
##
## `quoter` and `shark` are the no-credentials fallback, the per-seat
## fallback after a bad model reply, and two fieldable policies, so their
## five tunables (`BaselineParams`) decide whether the table trades at all.
## This sweeps them over a grid and scores every point against the four
## properties the design note asks the baselines to hold:
##
##   1. every seed settles at least one deal, and the median seed >= 3
##      (without this the smoke replay has no `deal` beats);
##   2. a shark-heavy table mishears MORE than an all-quoter table — the
##      redundancy shield has to be load-bearing;
##   3. an all-quoter table scores better in the quiet (noiseScale 0.5) than
##      in the storm (1.5) — talking has to be worth airtime;
##   4. the mean quoter score stays above 1.0, i.e. trading beats holding.
##
## Points that hold all four are ranked by the objective the baselines exist
## to serve — SHIELD LEGIBILITY, the number of extra misheard deals a
## shark-heavy table extracts over an honest one, since every candidate
## clears the deal gate with room to spare — with the median deal count as
## the tie-break. Run it offline; CI never needs it:
##
##     nim r -d:release --path:src scripts/tune_baselines.nim [seeds]
##
## The table it printed for the shipped values is committed at
## `docs/tuning/baseline-grid.md`.

import std/[algorithm, os, strformat, strutils]
import garble/[llm, sim]

proc fixture(seed: int, turns = 12, noiseScale = 1.0): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.turns = turns
  result.noiseScale = noiseScale
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig, kinds: seq[ScriptKind],
    params: BaselineParams): Sim =
  result = initSim(config)
  while not result.done:
    result.beginTurn()
    var decisions: seq[Decision]
    for seat in 0 ..< Seats:
      decisions.add(scriptedAction(result, seat, kinds[seat], params))
    for seat in 0 ..< Seats:
      result.applySay(seat, decisions[seat].channel, decisions[seat].text,
        decisions[seat].notes, scripted = true)
    for seat in 0 ..< Seats:
      if decisions[seat].hasConfirm:
        result.applyConfirm(seat, decisions[seat].ticket, decisions[seat].side,
          decisions[seat].qty, decisions[seat].commodity,
          decisions[seat].price, scripted = true)
    result.endTurn()

proc mixOf(mask: int): seq[ScriptKind] =
  for seat in 0 ..< Seats:
    result.add(if ((mask shr seat) and 1) == 1: skShark else: skQuoter)

proc dealsIn(sim: Sim): int =
  for event in sim.events:
    if event.kind == evDeal:
      inc result

proc mishearsIn(sim: Sim): int =
  for event in sim.events:
    if event.kind == evDeal and event.misheard:
      inc result

type Row = object
  params: BaselineParams
  minDeals: int
  medianDeals: int
  meanScore: float
  mishearGap: int
  quietGap: float
  ok: bool

proc evaluate(params: BaselineParams, seeds: int): Row =
  result.params = params
  var deals: seq[int]
  var scoreTotal = 0.0
  var sharkMishears = 0
  var quoterMishears = 0
  var quiet = 0.0
  var storm = 0.0
  let allQuoter = mixOf(0)
  let sharkHeavy = mixOf(0b00111)
  for seed in 0 ..< seeds:
    let table = playScripted(fixture(seed), allQuoter, params)
    deals.add(dealsIn(table))
    quoterMishears += mishearsIn(table)
    sharkMishears += mishearsIn(playScripted(fixture(seed), sharkHeavy, params))
    let calm = playScripted(fixture(seed, noiseScale = 0.5), allQuoter, params)
    let loud = playScripted(fixture(seed, noiseScale = 1.5), allQuoter, params)
    for seat in 0 ..< Seats:
      scoreTotal += table.score(seat)
      quiet += calm.score(seat)
      storm += loud.score(seat)
  deals.sort()
  result.minDeals = deals[0]
  result.medianDeals = deals[deals.len div 2]
  result.meanScore = scoreTotal / float(seeds * Seats)
  result.mishearGap = sharkMishears - quoterMishears
  result.quietGap = (quiet - storm) / float(seeds * Seats)
  ## `quoter` is by definition the honest REPEATER (design note, Scripted
  ## baselines), so a loud band the meter can never reach is a control row,
  ## not a candidate.
  result.ok = result.minDeals >= 1 and result.medianDeals >= 3 and
    result.mishearGap > 0 and result.quietGap > 0.0 and
    result.meanScore > 1.0 and params.loudBand <= 0.95

proc label(params: BaselineParams): string =
  fmt"floor {params.airtimeFloor:>3}  loud {params.loudBand:>4.2f}  " &
    fmt"sell +{params.sellMarkup}  buy +{params.buyMarkup}  " &
    fmt"lot {params.maxLot}"

when isMainModule:
  let seeds = if paramCount() >= 1: parseInt(paramStr(1)) else: 30
  var rows: seq[Row]
  for airtimeFloor in [0, 30, 60, 120]:
    ## 9.9 is "never repeat" — the meter never reaches it.
    for loudBand in [0.25, 0.5, 0.75, 9.9]:
      for sellMarkup in [1, 2, 3, 5]:
        for buyMarkup in [0, 1, 2]:
          for maxLot in [3, 5, 8]:
            rows.add(evaluate(BaselineParams(airtimeFloor: airtimeFloor,
              loudBand: loudBand, sellMarkup: sellMarkup,
              buyMarkup: buyMarkup, maxLot: maxLot), seeds))
  rows.sort(proc (a, b: Row): int =
    if a.ok != b.ok:
      return (if a.ok: -1 else: 1)
    if abs(a.meanScore - b.meanScore) > 1e-9:
      return (if a.meanScore > b.meanScore: -1 else: 1)
    b.medianDeals - a.medianDeals)
  echo "seeds per point: ", seeds, "   grid points: ", rows.len
  echo "| parameters | min deals | median deals | mean score | " &
    "mishear gap | quiet-storm | holds |"
  echo "|---|---|---|---|---|---|---|"
  for row in rows:
    echo fmt"| {label(row.params)} | {row.minDeals} | {row.medianDeals} | " &
      fmt"{row.meanScore:.4f} | {row.mishearGap} | {row.quietGap:.4f} | " &
      (if row.ok: "yes" else: "no") & " |"
  echo ""
  echo "best candidate: ", label(rows[0].params)
  echo "shipped (DefaultBaseline): ", label(DefaultBaseline)
  for rank, row in rows:
    if row.params == DefaultBaseline:
      echo fmt"shipped rank: {rank + 1} of {rows.len}  " &
        fmt"(median deals {row.medianDeals}, mishear gap {row.mishearGap}, " &
        fmt"quiet-storm {row.quietGap:.4f})"
