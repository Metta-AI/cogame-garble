## Sim unit tests: the seeded setup, the airtime meter, tickets, settlement,
## the redundancy shield end to end, scoring, legality, rune truncation,
## replay derivation, endings, the results shape, and the two name spaces.

import std/[json, math, random, sets, strutils, unicode, unittest]
import garble/[llm, sim]

proc fixtureConfig(turns = 12, seed = 0, noiseScale = 1.0): GameConfig =
  result = defaultGameConfig()
  result.turns = turns
  result.seed = seed
  result.noiseScale = noiseScale
  result.turnDelayMs = 0
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc sayAll(sim: var Sim, texts: seq[string]) =
  for seat in 0 ..< Seats:
    sim.applySay(seat, Radio, texts[seat], "", scripted = true)

proc quietTexts(): seq[string] =
  for seat in 0 ..< Seats:
    result.add("")

suite "seeded setup":
  test "everything the seed decides is in range and reproduces":
    for seed in [0, 1, 11, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      check sim.names.len == Seats
      check toHashSet(sim.names).len == Seats
      var surpluses: HashSet[int]
      for seat in 0 ..< Seats:
        check sim.sur[seat] != sim.dem[seat]
        check sim.premium[seat] in 6 .. 9
        check sim.quota[seat] in 12 .. 19
        surpluses.incl(sim.sur[seat])
      check surpluses.len == CommodityCount
      for turn in 0 ..< 12:
        for c in 0 ..< CommodityCount:
          check sim.prices[turn][c] in 3 .. 30
          if turn > 0:
            check abs(sim.prices[turn][c] - sim.prices[turn - 1][c]) <= 1
        check sim.interference[turn] >= 0.05
        check sim.interference[turn] <= 0.95
      let again = initSim(fixtureConfig(seed = seed))
      check again.prices == sim.prices
      check again.interference == sim.interference
      check again.names == sim.names
      check again.sur == sim.sur and again.dem == sim.dem
    let a = initSim(fixtureConfig(seed = 1))
    let b = initSim(fixtureConfig(seed = 2))
    check a.prices != b.prices

  test "the interference curve swells AND fades":
    for seed in [0, 1, 11, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var rises = false
      var falls = false
      for turn in 1 ..< sim.curve.len:
        if sim.curve[turn] > sim.curve[turn - 1]: rises = true
        if sim.curve[turn] < sim.curve[turn - 1]: falls = true
      check rises
      check falls

  test "noiseScale clamps at both ends":
    let loud = initSim(fixtureConfig(seed = 5, noiseScale = 2.0))
    var sawCeiling = false
    for value in loud.interference:
      check value <= 0.95
      if value == 0.95: sawCeiling = true
    check sawCeiling
    let silent = initSim(fixtureConfig(seed = 5, noiseScale = 0.0))
    for value in silent.interference:
      check value == 0.05

  test "the table is seeded in one place":
    let sim = initSim(fixtureConfig(seed = 11))
    for seat in 0 ..< Seats:
      check sim.cash[seat] == 120
      check sim.units[seat][sim.sur[seat]] == 20
      check sim.airtime[seat] == AirtimeBudget
      var total = 0
      for c in 0 ..< CommodityCount:
        total += sim.units[seat][c]
      check total == 20

suite "seat count":
  test "garble is a five-player game, exactly":
    for count in [4, 6]:
      var config = fixtureConfig()
      config.players = @[]
      config.tokens = @[]
      for index in 0 ..< count:
        config.players.add(PlayerConfig(name: "P" & $index))
        config.tokens.add("t" & $index)
      expect GarbleError:
        discard initSim(config)
    check initSim(fixtureConfig()).names.len == Seats

  test "turns below the floor are rejected":
    expect GarbleError:
      discard initSim(fixtureConfig(turns = MinTurns - 1))

suite "airtime":
  test "a transmission costs its length in runes":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    let line = repeat("A", MaxTextRunes)
    sim.applySay(0, Radio, line, "", scripted = true)
    check sim.airtime[0] == AirtimeBudget - MaxTextRunes
    check sim.events[^1].cost == MaxTextRunes
    check not sim.events[^1].clipped

  test "an over-long multi-byte text truncates on a RUNE boundary":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    sim.applySay(0, Radio, repeat("\u97F3", 300), "", scripted = true)
    let event = sim.events[^1]
    check event.text.runeLen == MaxTextRunes
    check event.text.validateUtf8() == -1
    check event.cost == MaxTextRunes

  test "a text that outruns the meter is clipped and flagged":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    sim.airtime[0] = 30
    sim.applySay(0, Radio, repeat("\u97F3", 100), "", scripted = true)
    let event = sim.events[^1]
    check event.clipped
    check event.text.runeLen == 30
    check event.text.validateUtf8() == -1
    check sim.airtime[0] == 0

  test "an empty meter silences the seat and opens no ticket":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    sim.airtime[0] = 0
    sim.applySay(0, Radio, "SELL 5 ORE AT 12", "", scripted = true)
    let event = sim.events[^1]
    check event.silent
    check event.text.len == 0
    check event.ticket == -1
    check sim.tickets.len == 0
    check sim.airtime[0] == 0
    ## An empty meter is silent whatever the seat offered — including
    ## nothing at all — so the flag re-derives from the meter on replay.
    sim.applySay(1, Radio, "", "", scripted = true)
    check not sim.events[^1].silent
    sim.airtime[2] = 0
    sim.applySay(2, Radio, "", "", scripted = true)
    check sim.events[^1].silent
    check sim.events[^1].text.len == 0

  test "a confirm always costs 40 and is never blocked":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.airtime[2] = 10
    sim.applyConfirm(2, 999, sdSell, 5, 0, 12, scripted = true)
    check sim.airtime[2] == 0
    check sim.events[^1].kind == evVoid
    check sim.events[^1].reason == "no-ticket"

suite "tickets":
  test "a parsing say opens exactly one ticket, chatter opens none":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    sim.applySay(0, Radio, "SELL 5 ORE AT 12", "", scripted = true)
    sim.applySay(1, Radio, "nothing here at all", "", scripted = true)
    check sim.tickets.len == 1
    check sim.tickets[0].id == 1
    check sim.events[^1].ticket == -1

  test "life is two turns and then the ticket is dead":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    sim.sayAll(@["SELL 5 " & Commodities[sim.sur[0]] & " AT 4", "", "", "", ""])
    let ticket = sim.tickets[0]
    check ticket.expiry == ticket.turn + TicketLife + 1
    ## not confirmable on its own turn
    check not sim.mayConfirm(1, ticket)
    for turn in 1 .. 2:
      sim.endTurn()
      sim.beginTurn()
      sim.sayAll(quietTexts())
      check sim.mayConfirm(1, sim.tickets[0])
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    check not sim.mayConfirm(1, sim.tickets[0])
    sim.applyConfirm(1, 1, sdSell, 5, sim.sur[0], 4, scripted = true)
    check sim.events[^1].reason == "expired"

  test "a line ticket is only for the addressee, and never for the offerer":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    sim.applySay(0, 2, "SELL 5 " & Commodities[sim.sur[0]] & " AT 4", "",
      scripted = true)
    for seat in 1 ..< Seats:
      sim.applySay(seat, Radio, "", "", scripted = true)
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.applyConfirm(1, 1, sdSell, 5, sim.sur[0], 4, scripted = true)
    check sim.events[^1].reason == "not-addressed"
    sim.applyConfirm(0, 1, sdSell, 5, sim.sur[0], 4, scripted = true)
    check sim.events[^1].reason == "own-ticket"
    sim.applyConfirm(2, 1, sdSell, 5, sim.sur[0], 4, scripted = true)
    check sim.events[^1].kind == evDeal

  test "two confirms of one ticket settle once, in seat order":
    var sim = initSim(fixtureConfig(seed = 3))
    let commodity = sim.sur[0]
    sim.beginTurn()
    sim.sayAll(@["SELL 5 " & Commodities[commodity] & " AT 4", "", "", "", ""])
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.applyConfirm(1, 1, sdSell, 5, commodity, 4, scripted = true)
    check sim.events[^1].kind == evDeal
    check sim.events[^1].buyer == 1
    sim.applyConfirm(2, 1, sdSell, 5, commodity, 4, scripted = true)
    check sim.events[^1].kind == evVoid
    check sim.events[^1].reason == "already-settled"

suite "settlement":
  test "a clean confirm moves goods and cash exactly":
    var sim = initSim(fixtureConfig(seed = 3))
    let commodity = sim.sur[0]
    sim.beginTurn()
    sim.sayAll(@["SELL 5 " & Commodities[commodity] & " AT 4", "", "", "", ""])
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    let sellerCash = sim.cash[0]
    let buyerCash = sim.cash[1]
    sim.applyConfirm(1, 1, sdSell, 5, commodity, 4, scripted = true)
    check sim.units[0][commodity] == 15
    check sim.units[1][commodity] == 5
    check sim.cash[0] == sellerCash + 20
    check sim.cash[1] == buyerCash - 20
    let deal = sim.events[^1]
    check deal.fill == 5
    check not deal.partial
    check not deal.misheard
    check deal.cash == 20

  test "a BUY ticket reverses the roles":
    var sim = initSim(fixtureConfig(seed = 3))
    let commodity = sim.sur[1]
    sim.beginTurn()
    sim.sayAll(@["", "BUY 5 " & Commodities[commodity] & " AT 4", "", "", ""])
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    ## seat 1 is the buyer even though it opened the ticket; only a seat
    ## that holds the goods can settle it.
    sim.applyConfirm(0, 1, sdBuy, 5, commodity, 4, scripted = true)
    if sim.sur[0] == commodity:
      check sim.events[^1].kind == evDeal
      check sim.events[^1].seller == 0
      check sim.events[^1].buyer == 1
    else:
      check sim.events[^1].reason == "uncovered"

  test "coverage clamps the fill and can void it entirely":
    var sim = initSim(fixtureConfig(seed = 3))
    let commodity = sim.sur[0]
    sim.beginTurn()
    sim.sayAll(@["SELL 99 " & Commodities[commodity] & " AT 3", "", "", "",
      ""])
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.applyConfirm(1, 1, sdSell, 99, commodity, 3, scripted = true)
    let deal = sim.events[^1]
    check deal.kind == evDeal
    check deal.fill == 20          ## the seller's whole holding
    check deal.partial
    check sim.units[0][commodity] == 0
    ## the seller has nothing left, so the next confirm is uncovered
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(@["SELL 5 " & Commodities[commodity] & " AT 3", "", "", "", ""])
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.applyConfirm(2, 2, sdSell, 5, commodity, 3, scripted = true)
    check sim.events[^1].reason == "uncovered"

  test "a buyer with too little cash fills to cash div price":
    var sim = initSim(fixtureConfig(seed = 3))
    let commodity = sim.sur[0]
    sim.beginTurn()
    sim.sayAll(@["SELL 20 " & Commodities[commodity] & " AT 90", "", "", "",
      ""])
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.applyConfirm(1, 1, sdSell, 20, commodity, 90, scripted = true)
    check sim.events[^1].kind == evDeal
    check sim.events[^1].fill == 120 div 90
    check sim.cash[1] == 120 - 90

  test "price zero skips the cash constraint":
    var sim = initSim(fixtureConfig(seed = 3))
    let commodity = sim.sur[0]
    sim.beginTurn()
    sim.sayAll(@["SELL 5 " & Commodities[commodity] & " AT 1", "", "", "", ""])
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    ## 1 -> 0 is a legal near-neighbour of a field said once
    sim.applyConfirm(1, 1, sdSell, 5, commodity, 0, scripted = true)
    check sim.events[^1].kind == evDeal
    check sim.events[^1].fill == 5
    check sim.cash[1] == 120

  test "cash and units never go negative over random confirm traffic":
    var rng = initRand(4242)
    for episode in 0 ..< 20:
      var sim = initSim(fixtureConfig(seed = episode))
      for turn in 0 ..< 12:
        sim.beginTurn()
        var texts: seq[string]
        for seat in 0 ..< Seats:
          texts.add((if rng.rand(1) == 0: "SELL " else: "BUY ") &
            $(1 + rng.rand(20)) & " " & Commodities[rng.rand(3)] & " AT " &
            $(1 + rng.rand(20)))
        sim.sayAll(texts)
        for seat in 0 ..< Seats:
          if rng.rand(2) == 0:
            continue
          let id = 1 + rng.rand(max(sim.tickets.high, 0))
          sim.applyConfirm(seat, id,
            (if rng.rand(1) == 0: sdSell else: sdBuy),
            rng.rand(99), rng.rand(3), rng.rand(99), scripted = true)
        for seat in 0 ..< Seats:
          check sim.cash[seat] >= 0
          for c in 0 ..< CommodityCount:
            check sim.units[seat][c] >= 0
        sim.endTurn()
      check sim.done
      check sim.reason == "complete"

suite "the shield end to end":
  test "a terse offer can be robbed; one repeat makes it a void":
    var sim = initSim(fixtureConfig(seed = 3))
    let commodity = sim.sur[0]
    let name = Commodities[commodity]
    sim.beginTurn()
    sim.sayAll(@["SELL 5 " & name & " AT 12", "", "", "", ""])
    check sim.tickets[0].terms.kQty == 1
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.applyConfirm(1, 1, sdSell, 50, commodity, 1, scripted = true)
    let deal = sim.events[^1]
    check deal.kind == evDeal
    check deal.fill == 20
    check deal.misheard
    check deal.partial
    check deal.saidQty == 5
    check deal.saidPrice == 12

    var shielded = initSim(fixtureConfig(seed = 3))
    shielded.beginTurn()
    shielded.sayAll(@["SELL 5 5 " & name & " " & name & " AT 12 12", "", "",
      "", ""])
    check shielded.tickets[0].terms.kQty == 2
    shielded.endTurn()
    shielded.beginTurn()
    shielded.sayAll(quietTexts())
    shielded.applyConfirm(1, 1, sdSell, 50, commodity, 1, scripted = true)
    check shielded.events[^1].kind == evVoid
    check shielded.events[^1].reason == "inadmissible"

suite "scoring":
  test "a seat that never trades scores exactly 1.0":
    for seed in [0, 7, 11, 99]:
      var sim = initSim(fixtureConfig(seed = seed))
      for turn in 0 ..< 12:
        sim.beginTurn()
        sim.sayAll(quietTexts())
        sim.endTurn()
      for seat in 0 ..< Seats:
        check sim.score(seat) == 1.0
        check sim.holdValue(seat) >= 180
        check sim.portfolio(seat) >= 0

  test "score is portfolio over hold, and the premium stops at the quota":
    var sim = initSim(fixtureConfig(seed = 3))
    let seat = 0
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.units[seat][sim.dem[seat]] = sim.quota[seat] + 10
    let prices = sim.finalPrices()
    var expected = sim.cash[seat]
    for c in 0 ..< CommodityCount:
      expected += sim.units[seat][c] * prices[c]
    expected += sim.premium[seat] * sim.quota[seat]
    check sim.portfolio(seat) == expected
    check abs(sim.score(seat) -
      sim.portfolio(seat).float / sim.holdValue(seat).float) < 1e-9

  test "buying the contract commodity cheaply lifts the score above 1.0":
    var sim = initSim(fixtureConfig(seed = 3))
    ## seat 1 buys the commodity its contract pays for, for one credit
    let commodity = sim.dem[1]
    var seller = -1
    for seat in 0 ..< Seats:
      if seat != 1 and sim.sur[seat] == commodity:
        seller = seat
    check seller >= 0
    sim.beginTurn()
    var texts = quietTexts()
    texts[seller] = "SELL 5 " & Commodities[commodity] & " AT 1"
    sim.sayAll(texts)
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.applyConfirm(1, 1, sdSell, 5, commodity, 1, scripted = true)
    check sim.events[^1].kind == evDeal
    sim.endTurn()
    check sim.score(1) > 1.0

suite "legality":
  test "illegal operations raise and leave the sim unchanged":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    sim.applySay(0, Radio, "SELL 5 ORE AT 12", "", scripted = true)
    var before = sim
    expect GarbleError:
      sim.applySay(0, Radio, "SELL 6 ORE AT 12", "", scripted = true)
    check sim == before
    expect GarbleError:
      sim.applyConfirm(1, 1, sdSell, 5, 0, 12, scripted = true)
    check sim == before
    for seat in 1 ..< Seats:
      sim.applySay(seat, Radio, "", "", scripted = true)
    before = sim
    expect GarbleError:
      sim.applyConfirm(1, 1, sdSell, 100, 0, 12, scripted = true)
    check sim == before
    expect GarbleError:
      sim.applyConfirm(1, 1, sdSell, 5, 0, -1, scripted = true)
    check sim == before
    expect GarbleError:
      sim.applyConfirm(1, 1, sdSell, 5, 9, 12, scripted = true)
    check sim == before
    ## an inadmissible confirm is a legal move: it voids, it does not raise
    sim.endTurn()
    sim.beginTurn()
    sim.sayAll(quietTexts())
    sim.applyConfirm(1, 1, sdSell, 93, 0, 12, scripted = true)
    check sim.events[^1].kind == evVoid
    check sim.events[^1].reason == "inadmissible"

  test "nothing may be applied after the episode is done":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.endEarly()
    check sim.done
    expect GarbleError:
      sim.applySay(0, Radio, "SELL 5 ORE AT 12", "", scripted = true)
    expect GarbleError:
      sim.applyConfirm(0, 1, sdSell, 5, 0, 12, scripted = true)
    expect GarbleError:
      sim.beginTurn()

suite "rune truncation":
  test "text and notes cut on rune boundaries and round-trip as UTF-8":
    var sim = initSim(fixtureConfig(seed = 3))
    sim.beginTurn()
    sim.applySay(0, Radio, repeat("\u97F3", 400), repeat("\u00e9", 900),
      scripted = true)
    let event = sim.events[^1]
    check event.text.runeLen <= MaxTextRunes
    check event.notes.runeLen <= MaxNotesRunes
    let node = event.eventToJson()
    check ($node).validateUtf8() == -1
    let back = eventFromJson(parseJson($node))
    check back.text == event.text
    check back.notes == event.notes

suite "replay derivation":
  proc playEpisode(seed: int, turns = 12): Sim =
    var rng = initRand(seed * 31 + 7)
    result = initSim(fixtureConfig(turns = turns, seed = seed))
    for turn in 0 ..< turns:
      result.beginTurn()
      var texts: seq[string]
      for seat in 0 ..< Seats:
        texts.add(
          (if rng.rand(1) == 0: "SELL " else: "BUY ") & $(1 + rng.rand(9)) &
          " " & Commodities[result.sur[seat]] & " AT " & $(1 + rng.rand(15)))
      for seat in 0 ..< Seats:
        result.applySay(seat, (if rng.rand(2) == 0: Radio else:
          (seat + 1) mod Seats), texts[seat], "note " & $turn,
          scripted = true)
      for seat in 0 ..< Seats:
        let open = result.openTicketsFor(seat)
        if open.len == 0 or rng.rand(1) == 0:
          continue
        let ticket = open[rng.rand(open.high)]
        let heard = result.heardTermsFor(seat, ticket)
        if heard.isNone:
          continue
        let terms = heard.get()
        result.applyConfirm(seat, ticket.id, terms.side, terms.qty,
          terms.commodity, terms.price, scripted = true)
      result.endTurn()

  test "the recorded log re-derives frame for frame":
    let live = playEpisode(11)
    check live.done
    let frames = replayMatch(live.config, live.events)
    check frames.len == live.events.len + 1
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check $frames[^1].resultsJson() == $live.resultsJson()

  test "every heard delivery re-derives identically":
    let live = playEpisode(42)
    let frames = replayMatch(live.config, live.events)
    let replayed = frames[^1]
    var deliveries = 0
    for event in live.events:
      if event.kind != evSay:
        continue
      for listener in 0 ..< Seats:
        let mine = live.heardFor(listener, event)
        check mine == replayed.heardFor(listener, event)
        deliveries += mine.len
    check deliveries > 0

  test "every event kind round-trips through JSON":
    let live = playEpisode(11)
    var seen: HashSet[EventKind]
    for event in live.events:
      seen.incl(event.kind)
      check eventFromJson(parseJson($event.eventToJson())) == event
    for kind in EventKind:
      check kind in seen

  test "a tampered deal or turn event raises":
    let live = playEpisode(11)
    for kind in [evDeal, evTurn]:
      var tampered = live.events
      var touched = false
      for index in 0 ..< tampered.len:
        if tampered[index].kind != kind or touched:
          continue
        touched = true
        if kind == evDeal:
          tampered[index].fill += 1
        else:
          tampered[index].prices[0] += 1
      check touched
      expect GarbleError:
        discard replayMatch(live.config, tampered)

  test "a deadline ending settles the replayed sim":
    var live = initSim(fixtureConfig(seed = 8))
    for turn in 0 ..< 4:
      live.beginTurn()
      live.sayAll(quietTexts())
      live.endTurn()
    live.endEarly()
    check live.reason == "deadline"
    let frames = replayMatch(live.config, live.events)
    check frames[^1].done
    check frames[^1].reason == "deadline"
    check frames[^1].turnsPlayed == 4

suite "endings":
  test "reason is exactly one of complete or deadline":
    var sim = initSim(fixtureConfig(seed = 9))
    check sim.reason == ""
    for turn in 0 ..< 12:
      sim.beginTurn()
      sim.sayAll(quietTexts())
      sim.endTurn()
    check sim.done
    check sim.reason == "complete"
    check sim.turnsPlayed == 12
    check sim.resultsJson()["reason"].getStr() in ["complete", "deadline"]

  test "endEarly scores what was played and is idempotent":
    var sim = initSim(fixtureConfig(seed = 9))
    for turn in 0 ..< 5:
      sim.beginTurn()
      sim.sayAll(quietTexts())
      sim.endTurn()
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    check sim.turnsPlayed == 5
    let events = sim.events.len
    sim.endEarly()
    check sim.events.len == events
    check sim.finalPrices() == sim.prices[4]

suite "results shape":
  test "every array is five long and bounded":
    var sim = initSim(fixtureConfig(seed = 11))
    for turn in 0 ..< 12:
      sim.beginTurn()
      sim.sayAll(quietTexts())
      sim.endTurn()
    let results = sim.resultsJson()
    for key in ["names", "scores", "portfolio", "hold", "cash", "units",
        "deals", "misheard", "voids", "airtimeUsed"]:
      check results[key].len == Seats
    for row in results["units"]:
      check row.len == CommodityCount
    for value in results["scores"]:
      check value.getFloat() >= 0.0
      check value.getFloat() <= 10.0
    for value in results["airtimeUsed"]:
      check value.getInt() <= AirtimeBudget
    check results["turns"].getInt() <= results["maxTurns"].getInt()

suite "name spaces":
  test "a prompt carries the seat's alias and no policy display name":
    var sim = initSim(fixtureConfig(seed = 11))
    sim.beginTurn()
    sim.sayAll(@["SELL 5 ORE AT 12", "BUY 3 TIN AT 9", "", "", ""])
    sim.endTurn()
    sim.beginTurn()
    for seat in 0 ..< Seats:
      let system = systemPrompt(sim, seat)
      let user = userPrompt(sim, seat, "be brief")
      check sim.names[seat] in system
      check sim.names[seat] in user
      for other in 0 ..< Seats:
        check sim.config.players[other].name notin system
        check sim.config.players[other].name notin user

  test "a seat never sees another seat's said text, cash or contract":
    var sim = initSim(fixtureConfig(seed = 11))
    sim.beginTurn()
    let secret = "SELL 7 " & Commodities[sim.sur[1]] & " AT 13"
    sim.applySay(1, 2, secret, "seat one private note", scripted = true)
    for seat in 0 ..< Seats:
      if seat != 1:
        sim.applySay(seat, Radio, "", "", scripted = true)
    sim.endTurn()
    sim.beginTurn()
    for seat in 0 ..< Seats:
      if seat == 1:
        continue
      let user = userPrompt(sim, seat, "")
      check "seat one private note" notin user
      check ("+" & $sim.premium[1] & " credits per " &
        Commodities[sim.dem[1]]) notin user or sim.dem[seat] == sim.dem[1]
      if seat != 2:
        check secret notin user

  test "tableNames is deterministic in the seed":
    var players: seq[PlayerConfig]
    for index in 0 ..< Seats:
      players.add(PlayerConfig(name: "P" & $index))
    check tableNames(players, 5) == tableNames(players, 5)
    check tableNames(players, 5) != tableNames(players, 6)
