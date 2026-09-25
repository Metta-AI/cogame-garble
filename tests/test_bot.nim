## The scripted baselines: bounded, legal, and load-bearing. They are the
## no-credentials fallback (offline certification and docker-smoke), the
## per-seat fallback after a bad model reply, and two fieldable policies in
## their own right — so a whole episode of them must complete without ever
## proposing an illegal move, and the table must actually trade.

import std/[algorithm, json, monotimes, os, strutils, times, unicode, unittest]
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

proc checkLegal(decision: Decision) =
  doAssert decision.text.runeLen <= MaxTextRunes, decision.text
  doAssert strutils.splitWhitespace(decision.text).len <= MaxWords
  doAssert decision.notes.len == 0, "a baseline never writes notes"
  doAssert decision.channel == Radio or decision.channel in 0 ..< Seats
  if decision.hasConfirm:
    doAssert decision.ticket >= 1
    doAssert decision.qty in 0 .. MaxQty
    doAssert decision.price in 0 .. MaxPrice
    doAssert decision.commodity in 0 ..< CommodityCount

proc playScripted(config: GameConfig, kinds: seq[ScriptKind]): Sim =
  ## Decisions are simultaneous: every seat decides from the same snapshot,
  ## then the transmissions land, then the confirms.
  result = initSim(config)
  while not result.done:
    result.beginTurn()
    var decisions: seq[Decision]
    for seat in 0 ..< Seats:
      decisions.add(scriptedAction(result, seat, kinds[seat]))
      checkLegal(decisions[seat])
    for seat in 0 ..< Seats:
      result.applySay(seat, decisions[seat].channel, decisions[seat].text,
        decisions[seat].notes, scripted = true)
    for seat in 0 ..< Seats:
      let decision = decisions[seat]
      if decision.hasConfirm:
        result.applyConfirm(seat, decision.ticket, decision.side,
          decision.qty, decision.commodity, decision.price, scripted = true)
    for seat in 0 ..< Seats:
      doAssert result.airtime[seat] >= 0
      doAssert result.airtime[seat] <= AirtimeBudget
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

suite "legality and boundedness":
  test "every mix of quoter and shark plays a whole legal episode":
    for seed in [1, 11, 42, 1234]:
      for mask in 0 ..< (1 shl Seats):
        let started = getMonoTime()
        let sim = playScripted(fixture(seed), mixOf(mask))
        let elapsed = (getMonoTime() - started).inMilliseconds
        check sim.done
        check sim.reason == "complete"
        check sim.turnsPlayed == 12
        check elapsed < 2000
        let results = sim.resultsJson()
        for value in results["airtimeUsed"]:
          check value.getInt() in 0 .. AirtimeBudget
        for seat in 0 ..< Seats:
          check sim.notes[seat].len == 0

suite "the game actually happens":
  test "an all-quoter table settles deals on every seed":
    var totals: seq[int]
    for seed in 0 ..< 50:
      let sim = playScripted(fixture(seed), mixOf(0))
      let deals = dealsIn(sim)
      check deals >= 1
      totals.add(deals)
    totals.sort()
    let median = totals[totals.len div 2]
    echo "all-quoter deals: median ", median, " min ", totals[0], " max ",
      totals[^1]
    check median >= 3

suite "the shield is load-bearing":
  test "sharks produce more mishearings than an honest table":
    var sharkMishears = 0
    var quoterMishears = 0
    for seed in 0 ..< 200:
      ## 3 sharks (seats 0, 1, 2) and 2 quoters
      sharkMishears += mishearsIn(playScripted(fixture(seed), mixOf(0b00111)))
      quoterMishears += mishearsIn(playScripted(fixture(seed), mixOf(0)))
    echo "misheard deals: shark-heavy ", sharkMishears, " all-quoter ",
      quoterMishears
    check sharkMishears > quoterMishears

  test "an honest table does better in the quiet than in the storm":
    var quiet = 0.0
    var storm = 0.0
    for seed in 0 ..< 200:
      let calm = playScripted(fixture(seed, noiseScale = 0.5), mixOf(0))
      let loud = playScripted(fixture(seed, noiseScale = 1.5), mixOf(0))
      for seat in 0 ..< Seats:
        quiet += calm.score(seat)
        storm += loud.score(seat)
    quiet = quiet / float(200 * Seats)
    storm = storm / float(200 * Seats)
    echo "mean quoter score: quiet ", formatFloat(quiet, ffDecimal, 4),
      " storm ", formatFloat(storm, ffDecimal, 4)
    check quiet > storm

suite "the fallback path":
  test "player-side baselines match the game fallback without a model":
    for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "AWS_BEARER_TOKEN_BEDROCK"]:
      delEnv(name)
    let client = newLlmClient(900, "claude-sonnet-5")
    check client.disabled
    for seed in [1, 11, 42]:
      var sim = initSim(fixture(seed))
      while not sim.done:
        sim.beginTurn()
        var decisions: seq[Decision]
        for seat in 0 ..< Seats:
          let view = sim.seatDecisionView(seat)
          let kind = if seat mod 2 == 0: skQuoter else: skShark
          for candidate in [skQuoter, skShark]:
            let action = scriptedDecisionFromView(view, candidate)
            let decision = parseDecision(sim, seat, action)
            check decision == scriptedAction(sim, seat, candidate)
            checkLegal(decision)
          decisions.add(scriptedAction(sim, seat, kind))
        for seat, decision in decisions:
          sim.applySay(seat, decision.channel, decision.text,
            decision.notes, scripted = true)
        for seat, decision in decisions:
          if decision.hasConfirm:
            sim.applyConfirm(seat, decision.ticket, decision.side,
              decision.qty, decision.commodity, decision.price,
              scripted = true)
        sim.endTurn()

suite "reply parsing":
  proc sample(): Sim =
    var sim = initSim(fixture(11))
    sim.beginTurn()
    sim

  proc decide(sim: Sim, body: string): Decision =
    parseDecision(sim, 0, extractJsonObject(body))

  test "a well-formed reply parses":
    let sim = sample()
    let decision = sim.decide("""{"channel":"radio",
      "text":"SELL 5 5 ORE ORE AT 12 12",
      "confirm":{"ticket":7,"side":"SELL","qty":5,"commodity":"TIN",
      "price":50},"notes":"Gizmo repeats prices."}""")
    check decision.channel == Radio
    check decision.text == "SELL 5 5 ORE ORE AT 12 12"
    check decision.hasConfirm
    check decision.ticket == 7
    check decision.side == sdSell
    check decision.qty == 5
    check decision.commodity == 2
    check decision.price == 50
    check decision.notes == "Gizmo repeats prices."

  test "a missing or null confirm is a legal silent settle":
    let sim = sample()
    check not sim.decide("""{"text":"hello"}""").hasConfirm
    check not sim.decide("""{"text":"hello","confirm":null}""").hasConfirm
    check sim.decide("""{"confirm":null}""").text.len == 0

  test "numbers arrive as ints, strings, floats and spelled words":
    let sim = sample()
    for body in ["""{"confirm":{"ticket":1,"side":"sell","commodity":"ore",
        "qty":5,"price":12}}""",
        """{"confirm":{"ticket":"1","side":"SELL","commodity":"ORE",
        "qty":"5","price":"12"}}""",
        """{"confirm":{"ticket":1,"side":"Sell","commodity":"Ore",
        "qty":5.0,"price":12.4}}""",
        """{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE",
        "qty":"five","price":"twelve"}}"""]:
      let decision = sim.decide(body)
      check decision.hasConfirm
      check decision.qty == 5
      check decision.price == 12
      check decision.commodity == 0
      check decision.side == sdSell

  test "an unknown channel and this seat's own alias both become the radio":
    let sim = sample()
    check sim.decide("""{"channel":"Nobody","text":"x"}""").channel == Radio
    check sim.decide("{\"channel\":\"" & sim.names[0] & "\"}").channel ==
      Radio
    check sim.decide("{\"channel\":\"" & sim.names[3].toLowerAscii() &
      "\"}").channel == 3

  test "trailing prose after the closing brace is tolerated":
    let sim = sample()
    let decision = sim.decide(
      """Here you go: {"text":"SELL 5 ORE AT 12"} — hope that helps.""")
    check decision.text == "SELL 5 ORE AT 12"

  test "ill-formed confirms are rejected":
    let sim = sample()
    for body in ["""{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE",
        "qty":100,"price":12}}""",
        """{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE",
        "qty":5,"price":-1}}""",
        """{"confirm":{"side":"SELL","commodity":"ORE","qty":5,"price":12}}""",
        """{"confirm":{"ticket":0,"side":"SELL","commodity":"ORE","qty":5,
        "price":12}}""",
        """{"confirm":{"ticket":1,"side":"SELL","commodity":"COAL","qty":5,
        "price":12}}""",
        """{"confirm":{"ticket":1,"side":"HOLD","commodity":"ORE","qty":5,
        "price":12}}""",
        """{"confirm":7}"""]:
      expect GarbleError:
        discard sim.decide(body)

  test "text, notes and channel are capped on rune boundaries":
    let sim = sample()
    let decision = sim.decide("""{"channel":"""" & repeat("\u97F3", 40) &
      """","text":"""" & repeat("\u97F3", 400) & """","notes":"""" &
      repeat("\u97F3", 900) & """"}""")
    check decision.text.runeLen == MaxTextRunes
    check decision.notes.runeLen == MaxNotesRunes
    check decision.text.validateUtf8() == -1
    check decision.notes.validateUtf8() == -1
    check decision.channel == Radio
