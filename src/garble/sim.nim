## Pure game rules for Garble. No IO, no networking, no LLM — the server,
## the tests and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded aliases, the whole price path,
## the interference curve with its burst table, every seat's private
## endowment and contract, the live tickets, the settled tape, each seat's
## airtime meter and private notes, and the append-only event log.
## Everything random is drawn from the seed at `initSim`, and every garble
## depends only on `(seed, turn, from, to)`, so a replay re-derives the whole
## episode — heard text included — from the recorded say / confirm events.

import std/[json, math, options, random, strutils, unicode], types, wire

export types, wire

const
  Seats* = 5
  CommodityCount* = 4
  ## An episode's whole model-call allowance (one call per seat per turn).
  ## A hosted episode is killed if it outlives the platform's artifact
  ## timeout, so `turns` is capped to this at sample time.
  EpisodeCallBudget* = 120
  CallsPerTurn* = 5
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 60_000
  MaxTextRunes* = 160
  MaxNotesRunes* = 400
  MaxChannelRunes* = 16
  AirtimeBudget* = 900
  ConfirmAirtime* = 40
  ## A ticket opened on turn t may be confirmed on t+1 and t+2.
  TicketLife* = 2
  MaxQty* = 99
  MaxPrice* = 99
  ## A private line is cleaner than the radio but reaches one ear.
  LineNoiseFactor* = 0.6
  ## Turns of heard traffic printed in full before summarising.
  HeardWindow* = 3
  Radio* = -1
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  Phase* = enum
    phOpen = "open"
    phWire = "wire"
    phSettle = "settle"
    phBetween = "between"
    phDone = "done"

  Ticket* = object
    id*: int
    offerer*: int
    turn*: int
    expiry*: int
    channel*: int      ## -1 radio, else the addressed seat
    terms*: Terms
    said*: string
    settled*: bool

  Deal* = object
    ticket*: int
    turn*: int
    seller*: int
    buyer*: int
    commodity*: int
    qty*: int          ## asked
    fill*: int
    price*: int
    saidQty*: int
    saidCommodity*: int
    saidPrice*: int
    partial*: bool
    misheard*: bool
    cash*: int

  Sim* = object
    config*: GameConfig
    names*: seq[string]              ## anonymous table aliases per seat
    sur*: seq[int]                   ## the commodity the seat is long
    dem*: seq[int]                   ## the commodity its contract pays for
    premium*: seq[int]
    quota*: seq[int]
    prices*: seq[array[CommodityCount, int]] ## the whole path, drawn at init
    curve*: seq[float]               ## published interference base per turn
    interference*: seq[float]        ## the live value per turn (bursts in)
    burst*: seq[bool]
    burstFrac*: seq[float]
    burstLen*: seq[int]
    cash*: seq[int]
    units*: seq[array[CommodityCount, int]]
    airtime*: seq[int]
    notes*: seq[string]
    startCash*: seq[int]
    startUnits*: seq[array[CommodityCount, int]]
    tickets*: seq[Ticket]
    deals*: seq[Deal]
    said*: seq[bool]                 ## live turn: this seat has transmitted
    dealCount*: seq[int]
    mishearCount*: seq[int]
    voidCount*: seq[int]
    turn*: int                       ## the turn in progress; -1 before the first
    turnsPlayed*: int
    nextTicket*: int
    phase*: Phase
    done*: bool
    reason*: string                  ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog alias, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the turn count into one episode's call budget. Idempotent: a
  ## config that already carries the cap (a replay being re-read) is
  ## untouched.
  result = config
  if result.sampled:
    return
  result.turns =
    max(min(config.turns, EpisodeCallBudget div CallsPerTurn), MinTurns)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.turns, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, turn: -1, seat: -1, channel: Radio, ticket: -1,
    commodity: -1, saidCommodity: -1, seller: -1, buyer: -1)

proc round3(value: float): float =
  round(value * 1000.0) / 1000.0

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(GarbleError,
      "garble needs exactly " & $Seats & " players")
  if config.turns < MinTurns:
    raise newException(GarbleError, "turns must be at least " & $MinTurns)
  if config.noiseScale < 0.0 or config.noiseScale > 2.0:
    raise newException(GarbleError, "noiseScale must be 0.0 .. 2.0")
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything else the seed decides, in this order: prices,
  ## the surplus/demand deal, premiums, quotas, the interference phase, and
  ## the burst table. (The aliases come from `tableNames`' own seeded
  ## stream, as in the starter.)
  var rng = initRand(int64(config.seed) * 7919 + 17)

  var row: array[CommodityCount, int]
  for c in 0 ..< CommodityCount:
    row[c] = 8 + rng.rand(6)          ## 8..14
  result.prices.add(row)
  for t in 1 ..< config.turns:
    var next = result.prices[t - 1]
    for c in 0 ..< CommodityCount:
      next[c] = clamp(next[c] + (rng.rand(2) - 1), 3, 30)
    result.prices.add(next)

  var deal = @[0, 1, 2, 3]
  rng.shuffle(deal)
  result.sur = newSeq[int](Seats)
  result.dem = newSeq[int](Seats)
  for seat in 0 ..< Seats:
    result.sur[seat] = deal[seat mod CommodityCount]
    var demand = result.sur[seat]
    for attempt in 0 .. 15:
      demand = deal[(seat + 1 + rng.rand(2)) mod CommodityCount]
      if demand != result.sur[seat]:
        break
    result.dem[seat] = demand
  for seat in 0 ..< Seats:
    result.premium.add(6 + rng.rand(3))    ## 6..9
  for seat in 0 ..< Seats:
    result.quota.add(12 + rng.rand(7))     ## 12..19

  let period = max(6, config.turns div 2)
  let phi = rng.rand(period - 1)
  for t in 0 ..< config.turns:
    result.burst.add(rng.rand(1.0) < 0.12)
    result.burstFrac.add(rng.rand(1.0))
    result.burstLen.add(2 + rng.rand(2))
  for t in 0 ..< config.turns:
    let base = 0.15 + 0.60 *
      (0.5 - 0.5 * cos(2.0 * PI * float(t + phi) / float(period)))
    result.curve.add(round3(clamp(base * config.noiseScale, 0.05, 0.95)))
    let raw = (base + (if result.burst[t]: 0.35 else: 0.0)) * config.noiseScale
    result.interference.add(round3(clamp(raw, 0.05, 0.95)))

  result.cash = newSeq[int](Seats)
  result.units = newSeq[array[CommodityCount, int]](Seats)
  result.airtime = newSeq[int](Seats)
  result.notes = newSeq[string](Seats)
  result.said = newSeq[bool](Seats)
  result.dealCount = newSeq[int](Seats)
  result.mishearCount = newSeq[int](Seats)
  result.voidCount = newSeq[int](Seats)
  for seat in 0 ..< Seats:
    result.cash[seat] = 120
    result.units[seat][result.sur[seat]] = 20
    result.airtime[seat] = AirtimeBudget
  result.startCash = result.cash
  result.startUnits = result.units
  result.turn = -1
  result.nextTicket = 1
  result.phase = phBetween
  result.addEvent(blankEvent(evStart))

# ---- Queries ----------------------------------------------------------------

proc priceRow*(sim: Sim, turn: int): array[CommodityCount, int] =
  sim.prices[clamp(turn, 0, sim.prices.high)]

proc livePrices*(sim: Sim): array[CommodityCount, int] =
  ## The prices the table is marked at: the turn in progress, or the last
  ## turn actually opened once the episode has settled.
  sim.priceRow(if sim.turn < 0: 0 else: sim.turn)

proc finalPrices*(sim: Sim): array[CommodityCount, int] =
  sim.priceRow(max(0, sim.turnsPlayed - 1))

proc liveInterference*(sim: Sim): float =
  if sim.turn < 0: sim.interference[0]
  else: sim.interference[clamp(sim.turn, 0, sim.interference.high)]

proc bandOf*(value: float): string =
  if value < 0.25: "CLEAR"
  elif value < 0.50: "HAZY"
  elif value < 0.75: "ROUGH"
  else: "STORM"

proc valueAt(cash: int, units: array[CommodityCount, int],
    prices: array[CommodityCount, int], demand, premium, quota: int): int =
  result = cash
  for c in 0 ..< CommodityCount:
    result += units[c] * prices[c]
  result += premium * min(units[demand], quota)

proc portfolioAt*(sim: Sim, seat: int,
    prices: array[CommodityCount, int]): int =
  valueAt(sim.cash[seat], sim.units[seat], prices, sim.dem[seat],
    sim.premium[seat], sim.quota[seat])

proc portfolio*(sim: Sim, seat: int): int =
  ## Marked at the last opened turn's prices — the horizon.
  sim.portfolioAt(seat, sim.finalPrices())

proc holdValue*(sim: Sim, seat: int): int =
  ## What the seat would be worth had it never traded, at the same prices.
  ## Never below 180 (120 cash plus 20 units at the price floor of 3), so
  ## the score division is total.
  valueAt(sim.startCash[seat], sim.startUnits[seat], sim.finalPrices(),
    sim.dem[seat], sim.premium[seat], sim.quota[seat])

proc score*(sim: Sim, seat: int): float =
  ## Portfolio over hold-and-do-nothing. 1.0 means traded to no effect;
  ## higher is better. Bounded to the results schema's 0..10.
  let hold = sim.holdValue(seat)
  if hold <= 0:
    return 0.0
  clamp(sim.portfolio(seat).float / hold.float, 0.0, 10.0)

proc ticketById*(sim: Sim, id: int): int =
  for index, ticket in sim.tickets:
    if ticket.id == id:
      return index
  -1

proc recipientsOf*(sim: Sim, fromSeat, channel: int): seq[int] =
  if channel == Radio:
    for seat in 0 ..< Seats:
      if seat != fromSeat:
        result.add(seat)
  elif channel >= 0 and channel < Seats and channel != fromSeat:
    result.add(channel)

proc noiseFor*(sim: Sim, turn, channel: int): float =
  sim.interference[clamp(turn, 0, sim.interference.high)] *
    (if channel == Radio: 1.0 else: LineNoiseFactor)

proc heardFor*(sim: Sim, seat: int, event: GameEvent): seq[HeardWord] =
  ## Re-derives what `seat` heard of a recorded transmission. The heard text
  ## is NEVER recorded: the bytes carry the truth and the viewer computes
  ## the lie.
  if event.kind != evSay or event.silent or event.seat == seat:
    return @[]
  if seat notin sim.recipientsOf(event.seat, event.channel):
    return @[]
  let turn = event.turn
  garble(normaliseWords(event.text), sim.config.seed, turn, event.seat, seat,
    sim.noiseFor(turn, event.channel), sim.burst[clamp(turn, 0,
      sim.burst.high)], sim.burstFrac[clamp(turn, 0, sim.burstFrac.high)],
    sim.burstLen[clamp(turn, 0, sim.burstLen.high)])

proc sayEventFor*(sim: Sim, ticket: Ticket): GameEvent =
  ## The transmission that opened a ticket.
  result = blankEvent(evSay)
  for event in sim.events:
    if event.kind == evSay and event.ticket == ticket.id:
      return event

proc heardTermsFor*(sim: Sim, seat: int, ticket: Ticket): Option[Terms] =
  ## What `seat` reads out of a ticket's transmission — its own garbling,
  ## its own parse. Nobody but the offerer ever sees the said terms.
  let event = sim.sayEventFor(ticket)
  if event.kind != evSay:
    return none(Terms)
  scanTerms(heardWords(sim.heardFor(seat, event)))

proc mayConfirm*(sim: Sim, seat: int, ticket: Ticket): bool =
  if ticket.settled or ticket.offerer == seat:
    return false
  if sim.turn <= ticket.turn or sim.turn >= ticket.expiry:
    return false
  if ticket.channel == Radio:
    true
  else:
    ticket.channel == seat

proc openTicketsFor*(sim: Sim, seat: int): seq[Ticket] =
  for ticket in sim.tickets:
    if sim.mayConfirm(seat, ticket):
      result.add(ticket)

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.turn = sim.turnsPlayed
  event.text = reason
  for c in 0 ..< CommodityCount:
    event.prices.add(sim.finalPrices()[c])
  for seat in 0 ..< Seats:
    event.portfolios.add(sim.portfolio(seat))
    event.scores.add(sim.score(seat))
  sim.addEvent(event)

proc closeTurn(sim: var Sim) =
  if sim.phase in {phBetween, phDone}:
    return
  inc sim.turnsPlayed
  sim.phase = phBetween

proc beginTurn*(sim: var Sim) =
  ## Opens the next turn: expires stale tickets, marks the table at this
  ## turn's prices, and logs the interference the whole table is playing
  ## into.
  if sim.done:
    raise newException(GarbleError, "the episode is over")
  sim.closeTurn()
  if sim.turnsPlayed >= sim.config.turns:
    raise newException(GarbleError, "every turn has been played")
  sim.turn = sim.turnsPlayed
  sim.phase = phWire
  ## Tickets expire by arithmetic: `expiry <= turn` is dead, which is why
  ## nothing has to be swept here beyond resetting the turn's transmissions.
  for seat in 0 ..< Seats:
    sim.said[seat] = false
  var event = blankEvent(evTurn)
  event.turn = sim.turn
  event.interference = sim.interference[sim.turn]
  event.burst = sim.burst[sim.turn]
  let prices = sim.priceRow(sim.turn)
  for c in 0 ..< CommodityCount:
    event.prices.add(prices[c])
  for seat in 0 ..< Seats:
    event.portfolios.add(sim.portfolioAt(seat, prices))
    event.airtime.add(sim.airtime[seat])
  sim.addEvent(event)

proc endTurn*(sim: var Sim) =
  ## Closes the live turn once every transmission and confirm has landed.
  ## Settles the episode when the last turn is done.
  if sim.done:
    return
  sim.closeTurn()
  if sim.turnsPlayed >= sim.config.turns:
    sim.settle("complete")

proc clipRunes(text: string, limit: int): string =
  ## Every truncation in Garble is on a RUNE boundary and MARKS the cut with
  ## `…`: a string cut mid UTF-8 renders in a browser but fails a strict JSON
  ## parser, and every string here lands in the replay. The marker costs one
  ## rune OF the limit, so a clipped string is never longer than the caller
  ## allowed — which is what keeps an airtime clip inside the meter.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  if limit == 1:
    return "\u2026"
  text.runeSubStr(0, limit - 1) & "\u2026"

proc normaliseChannel*(sim: Sim, seat, channel: int): int =
  ## Lenient: anything that is not another seat is the radio.
  if channel >= 0 and channel < Seats and channel != seat: channel else: Radio

proc applySay*(sim: var Sim, seat, channel: int, text, notes: string,
    scripted: bool) =
  ## One seat's transmission. Charges airtime, opens a ticket when the SAID
  ## text parses, and records the said text (never the heard text).
  if sim.done:
    raise newException(GarbleError, "the episode is over")
  if sim.phase != phWire:
    raise newException(GarbleError, "no transmission is due")
  if seat < 0 or seat >= Seats:
    raise newException(GarbleError, "bad seat: " & $seat)
  if sim.said[seat]:
    raise newException(GarbleError,
      "seat " & $seat & " has already transmitted this turn")

  var line = clipRunes(text, MaxTextRunes).replace("\n", " ")
    .replace("\r", " ")
  block wordCap:
    let parts = strutils.splitWhitespace(line)
    if parts.len > MaxWords:
      line = parts[0 ..< MaxWords].join(" ")
  var silent = false
  var clipped = false
  if sim.airtime[seat] <= 0:
    ## The meter is empty: nothing goes out at all, whatever was offered.
    ## The flag is a property of the METER, not of the text, so it is
    ## re-derivable on replay, where the recorded text is already "".
    silent = true
    line = ""
  elif line.runeLen > sim.airtime[seat]:
    line = clipRunes(line, sim.airtime[seat])
    clipped = true
  let cost = line.runeLen
  sim.airtime[seat] = max(0, sim.airtime[seat] - cost)
  if notes.len > 0:
    sim.notes[seat] = clipRunes(notes, MaxNotesRunes)

  var event = blankEvent(evSay)
  event.turn = sim.turn
  event.seat = seat
  event.channel = sim.normaliseChannel(seat, channel)
  event.text = line
  event.cost = cost
  event.airtimeLeft = sim.airtime[seat]
  event.silent = silent
  event.clipped = clipped
  event.scripted = scripted
  event.notes = sim.notes[seat]
  event.ticket = -1

  let terms = scanTerms(normaliseWords(line))
  if terms.isSome:
    let value = terms.get()
    event.hasTerms = true
    event.side = value.side
    event.qty = value.qty
    event.commodity = value.commodity
    event.price = value.price
    event.kQty = value.kQty
    event.kCom = value.kCom
    event.kPrice = value.kPrice
    event.ticket = sim.nextTicket
    sim.tickets.add(Ticket(id: sim.nextTicket, offerer: seat, turn: sim.turn,
      expiry: sim.turn + TicketLife + 1, channel: event.channel,
      terms: value, said: line, settled: false))
    inc sim.nextTicket
  sim.said[seat] = true
  sim.addEvent(event)

proc addVoid(sim: var Sim, seat, ticket: int, reason: string) =
  var event = blankEvent(evVoid)
  event.turn = sim.turn
  event.seat = seat
  event.ticket = ticket
  event.reason = reason
  inc sim.voidCount[seat]
  sim.addEvent(event)

proc applyConfirm*(sim: var Sim, seat, ticket: int, side: Side,
    qty, commodity, price: int, scripted: bool) =
  ## A confirm asserts four fields and the exchange enforces THOSE — not
  ## what the offerer said. It is charged a flat 40 runes of airtime and is
  ## never blocked by an empty meter: a seat can always settle.
  if sim.done:
    raise newException(GarbleError, "the episode is over")
  if sim.phase notin {phWire, phSettle}:
    raise newException(GarbleError, "no confirm is due")
  if seat < 0 or seat >= Seats:
    raise newException(GarbleError, "bad seat: " & $seat)
  for other in 0 ..< Seats:
    if not sim.said[other]:
      raise newException(GarbleError,
        "every transmission of the turn must land before any confirm")
  if qty < 0 or qty > MaxQty:
    raise newException(GarbleError, "qty must be 0.." & $MaxQty & ": " & $qty)
  if price < 0 or price > MaxPrice:
    raise newException(GarbleError,
      "price must be 0.." & $MaxPrice & ": " & $price)
  if commodity < 0 or commodity >= CommodityCount:
    raise newException(GarbleError, "unknown commodity: " & $commodity)
  sim.phase = phSettle
  sim.airtime[seat] = max(0, sim.airtime[seat] - ConfirmAirtime)

  var event = blankEvent(evConfirm)
  event.turn = sim.turn
  event.seat = seat
  event.ticket = ticket
  event.side = side
  event.qty = qty
  event.commodity = commodity
  event.price = price
  event.scripted = scripted
  sim.addEvent(event)

  let index = sim.ticketById(ticket)
  if index < 0:
    sim.addVoid(seat, ticket, "no-ticket")
    return
  let open = sim.tickets[index]
  if open.expiry <= sim.turn:
    sim.addVoid(seat, ticket, "expired")
    return
  if open.settled:
    sim.addVoid(seat, ticket, "already-settled")
    return
  if open.offerer == seat:
    sim.addVoid(seat, ticket, "own-ticket")
    return
  if open.turn >= sim.turn:
    ## Decisions are simultaneous: a ticket cannot be confirmed on the turn
    ## it opened, and no listener knows its id before then.
    sim.addVoid(seat, ticket, "no-ticket")
    return
  if open.channel != Radio and open.channel != seat:
    sim.addVoid(seat, ticket, "not-addressed")
    return
  let asserted = Terms(side: side, qty: qty, commodity: commodity,
    price: price, kQty: 1, kCom: 1, kPrice: 1)
  if open.terms.side != side:
    sim.addVoid(seat, ticket, "side")
    return
  if not admissible(open.terms, asserted):
    sim.addVoid(seat, ticket, "inadmissible")
    return

  let seller = if side == sdSell: open.offerer else: seat
  let buyer = if side == sdSell: seat else: open.offerer
  let affordable =
    if price > 0: sim.cash[buyer] div price else: qty
  let fill = min(qty, min(sim.units[seller][commodity], affordable))
  if fill <= 0:
    sim.addVoid(seat, ticket, "uncovered")
    return

  sim.units[seller][commodity] -= fill
  sim.units[buyer][commodity] += fill
  sim.cash[buyer] -= fill * price
  sim.cash[seller] += fill * price
  sim.tickets[index].settled = true

  let misheard = qty != open.terms.qty or commodity != open.terms.commodity or
    price != open.terms.price
  var event2 = blankEvent(evDeal)
  event2.turn = sim.turn
  event2.ticket = ticket
  event2.seller = seller
  event2.buyer = buyer
  event2.commodity = commodity
  event2.qty = qty
  event2.fill = fill
  event2.price = price
  event2.saidQty = open.terms.qty
  event2.saidCommodity = open.terms.commodity
  event2.saidPrice = open.terms.price
  event2.partial = fill < qty
  event2.misheard = misheard
  event2.cash = fill * price
  inc sim.dealCount[seller]
  inc sim.dealCount[buyer]
  if misheard:
    inc sim.mishearCount[seller]
    inc sim.mishearCount[buyer]
  sim.deals.add(Deal(ticket: ticket, turn: sim.turn, seller: seller,
    buyer: buyer, commodity: commodity, qty: qty, fill: fill, price: price,
    saidQty: open.terms.qty, saidCommodity: open.terms.commodity,
    saidPrice: open.terms.price, partial: fill < qty, misheard: misheard,
    cash: fill * price))
  sim.addEvent(event2)

proc endEarly*(sim: var Sim) =
  ## Stop now. The hosted platform kills an episode that outlives its
  ## timeout and keeps NOTHING, so a short honest episode always beats a
  ## long one that never lands. Scores use the turns actually played, at the
  ## last opened turn's prices.
  if sim.done:
    return
  sim.closeTurn()
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var portfolios = newJArray()
  var holds = newJArray()
  var cash = newJArray()
  var units = newJArray()
  var deals = newJArray()
  var misheard = newJArray()
  var voids = newJArray()
  var airtimeUsed = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    portfolios.add(%sim.portfolio(seat))
    holds.add(%sim.holdValue(seat))
    cash.add(%sim.cash[seat])
    var row = newJArray()
    for c in 0 ..< CommodityCount:
      row.add(%sim.units[seat][c])
    units.add(row)
    deals.add(%sim.dealCount[seat])
    misheard.add(%sim.mishearCount[seat])
    voids.add(%sim.voidCount[seat])
    airtimeUsed.add(%(AirtimeBudget - sim.airtime[seat]))
  %*{
    "names": names,
    "scores": scores,
    "portfolio": portfolios,
    "hold": holds,
    "cash": cash,
    "units": units,
    "deals": deals,
    "misheard": misheard,
    "voids": voids,
    "airtimeUsed": airtimeUsed,
    "turns": sim.turnsPlayed,
    "maxTurns": sim.config.turns,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc termsJson(terms: Terms): JsonNode =
  %*{
    "side": $terms.side,
    "qty": terms.qty,
    "commodity": terms.commodity,
    "price": terms.price,
    "kQty": terms.kQty,
    "kCom": terms.kCom,
    "kPrice": terms.kPrice
  }

proc wireTurn(sim: Sim): int =
  ## The turn the stage is drawing: the live one, or the last one that
  ## carried transmissions once the episode is between turns or done.
  result = sim.turn
  if sim.phase in {phBetween, phDone}:
    for event in sim.events:
      if event.kind == evSay:
        result = max(result, event.turn)

proc wireJson(sim: Sim): JsonNode =
  result = newJArray()
  if sim.turn < 0:
    return
  let turn = sim.wireTurn()
  for event in sim.events:
    if event.kind != evSay or event.turn != turn:
      continue
    var heard = newJArray()
    for listener in sim.recipientsOf(event.seat, event.channel):
      var words = newJArray()
      for word in sim.heardFor(listener, event):
        words.add(%*{"said": word.said, "heard": word.heard,
          "flag": $word.flag})
      heard.add(%*{"to": listener, "words": words})
    result.add(%*{
      "seat": event.seat,
      "channel": event.channel,
      "said": event.text,
      "silent": event.silent,
      "clipped": event.clipped,
      "ticket": event.ticket,
      "scripted": event.scripted,
      "heard": heard
    })

proc tableStateJson*(sim: Sim): JsonNode =
  let prices = sim.livePrices()
  let shown = sim.wireTurn()
  let previous = sim.priceRow(max(0, (if sim.turn <= 0: 0 else: sim.turn - 1)))
  var seats = newJArray()
  for seat in 0 ..< Seats:
    var units = newJArray()
    for c in 0 ..< CommodityCount:
      units.add(%sim.units[seat][c])
    var channel = Radio
    var silent = false
    for event in sim.events:
      if event.kind == evSay and event.turn == shown and event.seat == seat:
        channel = event.channel
        silent = event.silent
    seats.add(%*{
      "name": sim.names[seat],
      "portfolio": sim.portfolioAt(seat, prices),
      "hold": sim.holdValue(seat),
      "score": sim.score(seat),
      "cash": sim.cash[seat],
      "units": units,
      "surplus": sim.sur[seat],
      "demand": sim.dem[seat],
      "airtime": sim.airtime[seat],
      "silent": silent,
      "deals": sim.dealCount[seat],
      "misheard": sim.mishearCount[seat],
      "channel": channel,
      "notes": sim.notes[seat]
    })
  var curve = newJArray()
  for value in sim.curve:
    curve.add(%value)
  var priceArray = newJArray()
  var prevArray = newJArray()
  var names = newJArray()
  for c in 0 ..< CommodityCount:
    priceArray.add(%prices[c])
    prevArray.add(%previous[c])
    names.add(%Commodities[c])
  var tickets = newJArray()
  for ticket in sim.tickets:
    if ticket.settled or ticket.expiry <= sim.turn:
      continue
    var node = termsJson(ticket.terms)
    node["id"] = %ticket.id
    node["offerer"] = %ticket.offerer
    node["channel"] = %ticket.channel
    node["turn"] = %ticket.turn
    node["expiry"] = %ticket.expiry
    node["settled"] = %ticket.settled
    tickets.add(node)
  var tape = newJArray()
  for deal in sim.deals:
    tape.add(%*{
      "ticket": deal.ticket, "turn": deal.turn, "seller": deal.seller,
      "buyer": deal.buyer, "commodity": deal.commodity, "qty": deal.qty,
      "fill": deal.fill, "price": deal.price, "saidQty": deal.saidQty,
      "saidCommodity": deal.saidCommodity, "saidPrice": deal.saidPrice,
      "partial": deal.partial, "misheard": deal.misheard
    })
  let live = sim.liveInterference()
  %*{
    "seats": seats,
    "turn": sim.turn,
    "turns": sim.config.turns,
    "turnsPlayed": sim.turnsPlayed,
    "interference": live,
    "burst": (if sim.turn >= 0: sim.burst[sim.turn] else: false),
    "band": bandOf(live),
    "curve": curve,
    "prices": priceArray,
    "prevPrices": prevArray,
    "commodities": names,
    "wire": sim.wireJson(),
    "tickets": tickets,
    "tape": tape,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.turn >= 0:
    result["turn"] = %event.turn
  case event.kind
  of evStart:
    discard
  of evTurn:
    result["interference"] = %event.interference
    result["burst"] = %event.burst
    result["prices"] = %event.prices
    result["portfolios"] = %event.portfolios
    result["airtime"] = %event.airtime
  of evSay:
    result["seat"] = %event.seat
    result["channel"] = %event.channel
    result["text"] = %event.text
    result["cost"] = %event.cost
    result["airtimeLeft"] = %event.airtimeLeft
    result["silent"] = %event.silent
    result["clipped"] = %event.clipped
    result["ticket"] = %event.ticket
    result["scripted"] = %event.scripted
    if event.hasTerms:
      result["terms"] = %*{
        "side": $event.side, "qty": event.qty,
        "commodity": event.commodity, "price": event.price,
        "kQty": event.kQty, "kCom": event.kCom, "kPrice": event.kPrice
      }
    if event.notes.len > 0:
      result["notes"] = %event.notes
  of evConfirm:
    result["seat"] = %event.seat
    result["ticket"] = %event.ticket
    result["side"] = %($event.side)
    result["qty"] = %event.qty
    result["commodity"] = %event.commodity
    result["price"] = %event.price
    result["scripted"] = %event.scripted
  of evDeal:
    result["ticket"] = %event.ticket
    result["seller"] = %event.seller
    result["buyer"] = %event.buyer
    result["commodity"] = %event.commodity
    result["qty"] = %event.qty
    result["fill"] = %event.fill
    result["price"] = %event.price
    result["saidQty"] = %event.saidQty
    result["saidCommodity"] = %event.saidCommodity
    result["saidPrice"] = %event.saidPrice
    result["partial"] = %event.partial
    result["misheard"] = %event.misheard
    result["cash"] = %event.cash
  of evVoid:
    result["seat"] = %event.seat
    result["ticket"] = %event.ticket
    result["reason"] = %event.reason
  of evEnd:
    result["text"] = %event.text
    result["prices"] = %event.prices
    result["portfolios"] = %event.portfolios
    result["scores"] = %event.scores

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    turn: node{"turn"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    channel: node{"channel"}.getInt(Radio),
    text: node{"text"}.getStr(""),
    cost: node{"cost"}.getInt(0),
    airtimeLeft: node{"airtimeLeft"}.getInt(0),
    silent: node{"silent"}.getBool(false),
    clipped: node{"clipped"}.getBool(false),
    ticket: node{"ticket"}.getInt(-1),
    scripted: node{"scripted"}.getBool(false),
    notes: node{"notes"}.getStr(""),
    interference: node{"interference"}.getFloat(0.0),
    burst: node{"burst"}.getBool(false),
    seller: node{"seller"}.getInt(-1),
    buyer: node{"buyer"}.getInt(-1),
    fill: node{"fill"}.getInt(0),
    saidQty: node{"saidQty"}.getInt(0),
    saidCommodity: node{"saidCommodity"}.getInt(-1),
    saidPrice: node{"saidPrice"}.getInt(0),
    partial: node{"partial"}.getBool(false),
    misheard: node{"misheard"}.getBool(false),
    cash: node{"cash"}.getInt(0),
    reason: node{"reason"}.getStr(""),
    commodity: node{"commodity"}.getInt(-1),
    qty: node{"qty"}.getInt(0),
    price: node{"price"}.getInt(0)
  )
  if node.hasKey("side"):
    result.side = parseEnum[Side](node["side"].getStr())
  if node.hasKey("terms"):
    let terms = node["terms"]
    result.hasTerms = true
    result.side = parseEnum[Side](terms{"side"}.getStr("SELL"))
    result.qty = terms{"qty"}.getInt(0)
    result.commodity = terms{"commodity"}.getInt(-1)
    result.price = terms{"price"}.getInt(0)
    result.kQty = terms{"kQty"}.getInt(0)
    result.kCom = terms{"kCom"}.getInt(0)
    result.kPrice = terms{"kPrice"}.getInt(0)
  if node.hasKey("prices"):
    for value in node["prices"]:
      result.prices.add(value.getInt())
  if node.hasKey("portfolios"):
    for value in node["portfolios"]:
      result.portfolios.add(value.getInt())
  if node.hasKey("airtime"):
    for value in node["airtime"]:
      result.airtime.add(value.getInt())
  if node.hasKey("scores"):
    for value in node["scores"]:
      result.scores.add(value.getFloat())

# ---- Replay -----------------------------------------------------------------

const LegalReasons = ["complete", "deadline"]

proc sameFloats(a, b: seq[float]): bool =
  if a.len != b.len:
    return false
  for index in 0 ..< a.len:
    if abs(a[index] - b[index]) >= 1e-9:
      return false
  true

proc sameEvent(a, b: GameEvent): bool =
  ## EVERY field a derived event (turn, deal, void, end) records is compared:
  ## a recorded field the replay does not check is a field a tampered replay
  ## can lie about while the viewer draws it.
  a.kind == b.kind and a.turn == b.turn and a.seat == b.seat and
    a.ticket == b.ticket and a.qty == b.qty and a.price == b.price and
    a.commodity == b.commodity and a.fill == b.fill and
    a.seller == b.seller and a.buyer == b.buyer and
    a.saidQty == b.saidQty and a.saidPrice == b.saidPrice and
    a.saidCommodity == b.saidCommodity and a.partial == b.partial and
    a.misheard == b.misheard and a.reason == b.reason and
    a.cash == b.cash and a.text == b.text and
    a.prices == b.prices and a.portfolios == b.portfolios and
    a.airtime == b.airtime and sameFloats(a.scores, b.scores) and
    abs(a.interference - b.interference) < 1e-9 and a.burst == b.burst

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the say / confirm decisions through the rules. Every DERIVED event
  ## (turn, deal, void, end) is re-derived and checked against the record,
  ## so a tampered replay raises rather than rendering a lie.
  ## frames[i] = state after events[0 ..< i].
  var sim = initSim(config)
  ## initSim already logged the start event; the recorded log's first event
  ## is that same start.
  sim.events = @[]
  result.add(sim)
  var pending = 0     ## derived events the last decision appended
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evTurn:
      sim.beginTurn()
      if not sameEvent(event, sim.events[^1]):
        raise newException(GarbleError,
          "turn " & $event.turn & " does not match the seeded episode")
    of evSay:
      sim.applySay(event.seat, event.channel, event.text, event.notes,
        event.scripted)
      let logged = sim.events[^1]
      if logged.ticket != event.ticket or logged.cost != event.cost or
          logged.hasTerms != event.hasTerms:
        raise newException(GarbleError,
          "say by seat " & $event.seat & " does not match the rules")
      pending = 0
    of evConfirm:
      sim.applyConfirm(event.seat, event.ticket, event.side, event.qty,
        event.commodity, event.price, event.scripted)
      pending = 1     ## the deal or void the rules just derived
    of evDeal, evVoid:
      if pending <= 0 or sim.events.len < 1:
        raise newException(GarbleError,
          "a " & $event.kind & " event with no confirm before it")
      if not sameEvent(event, sim.events[^1]):
        raise newException(GarbleError,
          "settlement of ticket " & $event.ticket &
          " does not match the rules")
      pending = 0
    of evEnd:
      if event.text notin LegalReasons:
        raise newException(GarbleError,
          "illegal ending reason '" & event.text & "'")
      if not sim.done:
        sim.endTurn()
      if not sim.done:
        ## A deadline stop is not derivable from the decisions alone.
        sim.settle(event.text)
      if sim.reason != event.text:
        raise newException(GarbleError,
          "recorded ending '" & event.text & "' does not match '" &
          sim.reason & "'")
      if not sameEvent(event, sim.events[^1]):
        raise newException(GarbleError,
          "the recorded ending does not match the re-derived one")
    result.add(sim)
