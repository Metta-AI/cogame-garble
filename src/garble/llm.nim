## Claude-backed decision making for Garble. Each seat's policy is just a
## prompt: the game server composes the seat's view (its private inventory
## and contract, the public prices and interference forecast, its OWN heard
## traffic, the tickets it may confirm with their ready-made confirm JSON,
## and the public tape) plus that seat's prompt, and asks Claude what it
## transmits and what it confirms.
##
## Decisions within a turn are SIMULTANEOUS by rule, so all five requests go
## out as ONE parallel batch (curly.makeRequests); an ill-formed reply is
## retried once as a smaller batch carrying a hint, and anything still open
## falls back to the `quoter` scripted baseline.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, math, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  ScriptKind* = enum
    skNone = "none"
    skQuoter = "quoter"
    skShark = "shark"

  Decision* = object
    channel*: int        ## -1 radio, else the addressed seat
    text*: string
    notes*: string       ## "" when the reply carried none
    hasConfirm*: bool
    ticket*: int
    side*: Side
    qty*: int
    commodity*: int
    price*: int

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string              ## anthropic transport
    bedrockEndpoint: string     ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string               ## direct-Anthropic transport only
    maxOutputTokens: int
    timeoutSeconds*: int
    disabled*: bool             ## true once credentials are known-unavailable
    callsIssued*: int           ## requests the last decideAll actually sent
    decidedScripted*: seq[bool] ## per position in the last decideAll's seats:
                                ## true when that seat's move came from a
                                ## baseline rather than from a model reply

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"quoter" play the honest
  ## quoter, "shark" the strategic mishearer, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "quoter": skQuoter
  of "shark": skShark
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "garble llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "garble llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "garble llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel], ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "garble llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "garble llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

const
  ## Below this the baselines stop transmitting and keep the meter for
  ## confirms.
  ScriptedAirtimeFloor = 30
  ## The meter above which `quoter` repeats every field once.
  LoudBand = 0.5

proc numberWord(value: int): string =
  $value

proc offerText(verb: string, qty: int, commodity: int, price: int,
    repeat: bool): string =
  ## `SELL 5 ORE AT 12`, or `SELL 5 5 ORE ORE AT 12 12` when the meter is
  ## loud — the redundancy shield applied by rule.
  var parts = @[verb]
  parts.add(numberWord(qty))
  if repeat: parts.add(numberWord(qty))
  parts.add(Commodities[commodity])
  if repeat: parts.add(Commodities[commodity])
  parts.add(Pivot)
  parts.add(numberWord(price))
  if repeat: parts.add(numberWord(price))
  parts.join(" ")

proc scriptedOffer(sim: Sim, seat: int, repeat: bool): string =
  ## Quote out of the surplus first, then bid for the contract commodity.
  let prices = sim.livePrices()
  let surplus = sim.sur[seat]
  let demand = sim.dem[seat]
  if sim.units[seat][surplus] >= 3:
    let qty = min(5, sim.units[seat][surplus])
    let price = clamp(prices[surplus] + 3, 1, MaxPrice)
    return offerText("SELL", qty, surplus, price, repeat)
  if sim.units[seat][demand] < sim.quota[seat]:
    let qty = min(5, sim.quota[seat] - sim.units[seat][demand])
    let price = clamp(prices[demand] + 1, 1, MaxPrice)
    if qty > 0:
      return offerText("BUY", qty, demand, price, repeat)
  ""

proc improvingTicket(sim: Sim, seat: int):
    tuple[found: bool, ticket: Ticket, terms: Terms] =
  ## The first (lowest id) open ticket whose HEARD reading parses and would
  ## improve this seat's portfolio. The baselines cannot see the said text —
  ## nobody can but the offerer.
  let prices = sim.livePrices()
  for ticket in sim.openTicketsFor(seat):
    let heard = sim.heardTermsFor(seat, ticket)
    if heard.isNone:
      continue
    let terms = heard.get()
    if terms.side == sdSell:
      ## The offerer sells; this seat would buy.
      if terms.commodity != sim.dem[seat]:
        continue
      if sim.units[seat][terms.commodity] >= sim.quota[seat]:
        continue
      if terms.price > prices[sim.dem[seat]] + sim.premium[seat] - 1:
        continue
      if terms.price > 0 and sim.cash[seat] < terms.price:
        continue
    else:
      ## The offerer buys; this seat would sell.
      if terms.commodity != sim.sur[seat]:
        continue
      if terms.price < prices[sim.sur[seat]] + 1:
        continue
      if sim.units[seat][terms.commodity] <= 0:
        continue
    return (true, ticket, terms)
  (false, Ticket(), Terms())

proc favourable(value: int, word: string, wantHigh: bool, floorAt: int): int =
  ## The most favourable value in {heard} ∪ neighboursOf(heard word). The
  ## exchange only accepts it when the offerer said that field once — which
  ## is exactly why `shark` voids against a repeater and robs a terse cog.
  result = value
  for candidate in valueNeighbors(word):
    if candidate < floorAt:
      continue
    if (wantHigh and candidate > result) or
        (not wantHigh and candidate < result):
      result = candidate

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`. Always legal by construction: bounded
  ## quantities and prices, bounded text, never raises, never writes notes.
  let repeat = kind == skQuoter and sim.liveInterference() >= LoudBand
  result.channel = Radio
  if sim.airtime[seat] >= ScriptedAirtimeFloor:
    result.text = scriptedOffer(sim, seat, repeat)
  let pick = improvingTicket(sim, seat)
  if not pick.found:
    return
  result.hasConfirm = true
  result.ticket = pick.ticket.id
  result.side = pick.terms.side
  result.commodity = pick.terms.commodity
  if kind == skShark:
    ## As the buyer: the lowest price and the highest quantity. As the
    ## seller: the reverse.
    let buying = pick.terms.side == sdSell
    result.qty = favourable(pick.terms.qty, pick.terms.qtyWord,
      wantHigh = buying, floorAt = 1)
    result.price = favourable(pick.terms.price, pick.terms.priceWord,
      wantHigh = not buying, floorAt = 0)
  else:
    result.qty = pick.terms.qty
    result.price = pick.terms.price
  result.qty = clamp(result.qty, 0, MaxQty)
  result.price = clamp(result.price, 0, MaxPrice)

# ---- Prompt building --------------------------------------------------------

proc channelLabel(sim: Sim, channel: int): string =
  if channel == Radio: "RADIO" else: "LINE to " & sim.names[channel]

proc percent(value: float): string =
  $int(round(value * 100.0)) & "%"

proc money(value: int): string =
  $value

proc contractLine(sim: Sim, seat: int): string =
  "YOUR CONTRACT: +" & $sim.premium[seat] & " credits per " &
    Commodities[sim.dem[seat]] & " you hold at the end, up to " &
    $sim.quota[seat] & " units."

proc holdingLine(sim: Sim, seat: int): string =
  var parts: seq[string]
  for c in 0 ..< CommodityCount:
    parts.add(Commodities[c] & " " & $sim.units[seat][c])
  parts.join(", ")

proc forecastBlock(sim: Sim): string =
  var parts: seq[string]
  for t in 0 ..< sim.curve.len:
    parts.add("t" & $t & " " & percent(sim.curve[t]) &
      (if t == sim.turn: " \u2190 now" else: ""))
  "  " & parts.join("  ")

proc priceBlock(sim: Sim): string =
  let now = sim.livePrices()
  let was = sim.priceRow(max(0, sim.turn - 1))
  var parts: seq[string]
  for c in 0 ..< CommodityCount:
    parts.add(Commodities[c] & " " & $now[c] &
      (if sim.turn <= 0 or was[c] == now[c]: " (=)" else: " (was " & $was[c] &
        ")"))
  "PRICES: " & parts.join("  ")

proc termsText(terms: Terms): string =
  $terms.side & " " & $terms.qty & " " & Commodities[terms.commodity] &
    " AT " & $terms.price

proc confirmSkeleton(id: int, terms: Terms): string =
  "{\"ticket\":" & $id & ",\"side\":\"" & $terms.side & "\",\"qty\":" &
    $terms.qty & ",\"commodity\":\"" & Commodities[terms.commodity] &
    "\",\"price\":" & $terms.price & "}"

proc ticketBlock(sim: Sim, seat: int): string =
  ## The legal choice set, precomputed by the SAME code that validates a
  ## confirm — a formal-output game that makes the model derive the skeleton
  ## falls back to scripted on a large share of turns.
  var lines: seq[string]
  for ticket in sim.openTicketsFor(seat):
    let event = sim.sayEventFor(ticket)
    let heard = sim.heardFor(seat, event)
    lines.add("  #" & $ticket.id & " from " & sim.names[ticket.offerer] &
      " on " & (if ticket.channel == Radio: "RADIO" else: "a LINE to you") &
      " (opened turn " & $ticket.turn & ", expires turn " & $ticket.expiry &
      ")")
    lines.add("     you heard: \"" & heardText(heard) & "\"")
    let reading = scanTerms(heardWords(heard))
    if reading.isSome:
      lines.add("     your reading: " & termsText(reading.get()))
      lines.add("     to confirm: " & confirmSkeleton(ticket.id, reading.get()))
    else:
      lines.add("     your reading: unparsed \u2014 no terms")
      lines.add("     to confirm you must supply side, qty, commodity and " &
        "price yourself.")
  if lines.len == 0:
    return "TICKETS YOU MAY CONFIRM:\n  (none)\n\n"
  "TICKETS YOU MAY CONFIRM:\n" & lines.join("\n") & "\n\n"

proc heardBlock(sim: Sim, seat: int): string =
  ## The last `HeardWindow` turns in full, earlier turns summarised — which
  ## bounds the prompt at roughly 3 000 runes on a twelve-turn episode.
  var lines: seq[string]
  for event in sim.events:
    if event.kind != evSay or event.seat == seat or event.silent:
      continue
    let words = sim.heardFor(seat, event)
    if words.len == 0 and event.text.len > 0:
      continue
    let full = heardText(words)
    let label = "  turn " & $event.turn & "  " & sim.names[event.seat] &
      " \u2192 " & (if event.channel == Radio: "RADIO" else: "LINE") & ": "
    if event.turn >= sim.turn - HeardWindow:
      lines.add(label & "\"" & full & "\"")
    else:
      lines.add(label & "\"" &
        (if full.runeLen > 40: full.runeSubStr(0, 40) & "\u2026" else: full) &
        "\"")
  if lines.len == 0:
    return "WHAT YOU HEARD (last " & $HeardWindow &
      " turns in full; earlier turns summarised):\n  (nothing yet)\n\n"
  "WHAT YOU HEARD (last " & $HeardWindow &
    " turns in full; earlier turns summarised):\n" & lines.join("\n") & "\n\n"

proc tapeBlock(sim: Sim): string =
  var lines: seq[string]
  for deal in sim.deals:
    let said = $deal.saidQty & " " & Commodities[deal.saidCommodity] &
      " at " & $deal.saidPrice
    lines.add("  #" & $deal.ticket & " turn " & $deal.turn & " \u2014 " &
      sim.names[deal.seller] & " sold " & $deal.fill & " " &
      Commodities[deal.commodity] & " to " & sim.names[deal.buyer] & " at " &
      $deal.price & " (said " & said & ")" &
      (if deal.misheard: " \u2014 MISHEARD" else: " \u2014 clean") &
      (if deal.partial: " \u2014 partial " & $deal.fill & "/" & $deal.qty
       else: ""))
  if lines.len == 0:
    return "PUBLIC TAPE (every settled deal, both versions):\n  (empty)\n\n"
  "PUBLIC TAPE (every settled deal, both versions):\n" & lines.join("\n") &
    "\n\n"

proc systemPrompt*(sim: Sim, seat: int): string =
  "You are " & sim.names[seat] &
    ", a cog trading commodities with four other cogs over a NOISY " &
    "exchange." & """

Rules:
- Four commodities: ORE, OAT, TIN, TAR. Prices are public and move every
  turn.
- You hold a surplus of one commodity and a private contract that pays you a
  premium for each unit of a DIFFERENT commodity you hold at the end, up to
  your quota. Your score is your final portfolio value divided by what you
  would have been worth if you never traded. Above 1.00 means you traded
  well. Nobody else's score is the mirror of yours: good trades lift both
  sides.
- Each turn you transmit ONE line, on the RADIO (all four others hear it) or
  on a PRIVATE LINE to one named cog (cleaner channel, one listener).
- EVERY channel is noisy. Words drop, swap for near-neighbours, or vanish
  under static bursts. The interference meter is public and is printed every
  turn. Each listener hears its OWN garbling - what you said is not what
  anyone heard.
- The exchange reads terms out of your words: it finds SELL or BUY, then AT,
  then takes the most frequently repeated number before AT as the quantity,
  the most frequently repeated commodity before AT as the commodity, and the
  most frequently repeated number after AT as the price. `SELL 5 ORE AT 12`
  is a valid offer. So is `SELL 5 5 ORE ORE AT 12 12`, which survives one
  garble per field.
- A deal executes when you CONFIRM someone's ticket. THE TERMS YOU CONFIRM
  ARE WHAT THE EXCHANGE ENFORCES, not the terms they spoke. You may confirm
  a value you did not hear - but the exchange only accepts a value that the
  channel could have produced: it must equal what they said, or be a
  near-neighbour of it AND they must have said that field exactly once. If
  they repeated a field, only the exact value binds and anything else voids
  your confirm and wastes your turn.
- Near-neighbours are fixed and public. A digit string's neighbours are:
  append a 0 (5 -> 50), drop the last digit (50 -> 5), and change the last
  digit by one (5 -> 4, 5 -> 6). Spelled numbers have at most one neighbour
  (FIVE <-> NINE, FIFTY <-> FIFTEEN, SIXTY <-> SIXTEEN, SEVENTY <->
  SEVENTEEN, EIGHTY <-> EIGHTEEN, NINETY <-> NINETEEN, FORTY <-> FOURTEEN,
  THIRTY <-> THIRTEEN, TWENTY <-> TWELVE, TEN <-> TWO, THREE <-> SIX; ZERO,
  ONE, FOUR, SEVEN, EIGHT and ELEVEN have none). ORE <-> OAT and TIN <->
  TAR. SELL, BUY and AT never swap - they only vanish.
- AIRTIME is metered in characters. You have a fixed budget for the whole
  episode; a transmission costs its length, a confirm costs a flat 40. Run
  out and your transmissions stop going out, though you can always still
  confirm. Repeat-backs, spelled numbers and redundant phrasing all cost
  airtime while the market moves.
- Every settled deal is public and stamps BOTH the spoken terms and the
  confirmed terms. Everyone sees who was robbed.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis,
no explanation, no markdown fences, no text before or after the object. Your
reply must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let live = sim.liveInterference()
  let portfolio = sim.portfolioAt(seat, sim.livePrices())
  let hold = sim.holdValue(seat)
  result.add("Turn " & $sim.turn & " of " & $sim.config.turns & ".\n\n")
  result.add("INTERFERENCE NOW: " & percent(live) & " (" & bandOf(live) &
    ").  FORECAST (base, bursts not shown):\n" & sim.forecastBlock() & "\n")
  result.add(sim.priceBlock() & "\n\n")
  result.add("YOU: " & sim.names[seat] & ", seat " & $seat & ".  CASH " &
    money(sim.cash[seat]) & ".  HOLDING: " & sim.holdingLine(seat) & ".\n")
  result.add(sim.contractLine(seat) & "\n")
  result.add("AIRTIME LEFT: " & $sim.airtime[seat] & " of " &
    $AirtimeBudget & " characters.\n")
  result.add("PORTFOLIO NOW " & money(portfolio) &
    " (hold-and-do-nothing " & money(hold) & ", score " &
    formatFloat(portfolio.float / max(hold, 1).float, ffDecimal, 2) &
    ")\n\n")
  result.add(sim.ticketBlock(seat))
  result.add(sim.heardBlock(seat))
  result.add(sim.tapeBlock())
  result.add("YOUR NOTES FROM EARLIER TURNS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  var others: seq[string]
  for other in 0 ..< Seats:
    if other != seat:
      others.add(sim.names[other])
  result.add("Reply with ONLY {\"channel\":\"radio\",\"text\":\"\u2026\"," &
    "\"confirm\":{\u2026} or null,\"notes\":\"\u2026\"} \u2014 channel is " &
    "\"radio\" or one of " & others.join(", ") & "; text at most " &
    $MaxTextRunes & " characters; notes at most " & $MaxNotesRunes &
    " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model sent
    ## instead of JSON (prose, a refusal, a cut-off analysis...).
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(GarbleError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a GarbleError describing why there is
  ## none. Auth failures disable the client for the rest of the episode;
  ## model-access and throttle failures rotate the Bedrock model for the
  ## next batch.
  if error.len > 0:
    raise newException(GarbleError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(GarbleError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(GarbleError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(GarbleError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(GarbleError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(GarbleError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(GarbleError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A
  ## string cut on a byte boundary mid-UTF-8 renders in a browser but fails
  ## a strict JSON parser, and every string here lands in the replay.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "\u2026"

# ---- Reply parsing ----------------------------------------------------------

proc parseChannel(sim: Sim, seat: int, node: JsonNode): int =
  ## Lenient by design: an unknown value — including this seat's own alias —
  ## is the radio, never an error.
  if node.isNil or node.kind != JString:
    return Radio
  let text = cleanText(node.getStr(), MaxChannelRunes).strip()
  if text.len == 0 or text.toLowerAscii() == "radio":
    return Radio
  for other in 0 ..< Seats:
    if other != seat and cmpIgnoreCase(sim.names[other], text) == 0:
      return other
  Radio

proc parseNumber(node: JsonNode, field: string, limit: int): int =
  ## An integer, a numeric string, a float (rounded), or a spelled number
  ## word. Out of range is ILL-FORMED, which is retried once and then falls
  ## back — unlike an inadmissible confirm, which is a legal move.
  if node.isNil:
    raise newException(GarbleError, "confirm is missing " & field)
  var value = -1
  case node.kind
  of JInt:
    value = node.getInt()
  of JFloat:
    value = int(round(node.getFloat()))
  of JString:
    let text = node.getStr().strip()
    let spelled = wordValue(text.toUpperAscii())
    if spelled >= 0:
      value = spelled
    else:
      try:
        value = int(round(parseFloat(text)))
      except ValueError:
        raise newException(GarbleError, field & " is not a number: " & text)
  else:
    raise newException(GarbleError, field & " must be a number: " & $node)
  if value < 0 or value > limit:
    raise newException(GarbleError,
      field & " must be 0.." & $limit & ": " & $value)
  value

proc parseDecision*(sim: Sim, seat: int, payload: JsonNode): Decision =
  result.channel = parseChannel(sim, seat, payload{"channel"})
  result.text = cleanText(payload{"text"}.getStr(), MaxTextRunes)
    .replace("\n", " ")
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesRunes)
  let confirm = payload{"confirm"}
  if confirm.isNil or confirm.kind == JNull:
    return
  if confirm.kind != JObject:
    raise newException(GarbleError, "confirm must be an object or null")
  let ticket = confirm{"ticket"}
  if ticket.isNil:
    raise newException(GarbleError, "confirm is missing ticket")
  var id = -1
  case ticket.kind
  of JInt: id = ticket.getInt()
  of JFloat: id = int(round(ticket.getFloat()))
  of JString:
    try:
      id = int(round(parseFloat(ticket.getStr().strip())))
    except ValueError:
      raise newException(GarbleError, "ticket is not a number")
  else:
    raise newException(GarbleError, "ticket must be a number")
  if id < 1:
    raise newException(GarbleError, "ticket must be at least 1: " & $id)
  let sideText = confirm{"side"}.getStr().strip().toUpperAscii()
  if sideText != $sdSell and sideText != $sdBuy:
    raise newException(GarbleError, "side must be SELL or BUY: " & sideText)
  let commodityText = confirm{"commodity"}.getStr().strip().toUpperAscii()
  let commodity = commodityIndex(commodityText)
  if commodity < 0:
    raise newException(GarbleError,
      "commodity must be ORE, OAT, TIN or TAR: " & commodityText)
  result.hasConfirm = true
  result.ticket = id
  result.side = if sideText == $sdSell: sdSell else: sdBuy
  result.commodity = commodity
  result.qty = parseNumber(confirm{"qty"}, "qty", MaxQty)
  result.price = parseNumber(confirm{"price"}, "price", MaxPrice)

# ---- One parallel batch per turn --------------------------------------------

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind],
  timeoutSeconds: int
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Never raises: any failure
  ## falls back to the `quoter` baseline so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  ##
  ## Garble is a simultaneous-decision game, so every open seat's request
  ## goes out in ONE batch. Sequential seats are exactly how an LLM coworld
  ## blows its play budget.
  result = newSeq[Decision](seats.len)
  client.callsIssued = 0
  client.decidedScripted = newSeq[bool](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skQuoter else: kind))
      client.decidedScripted[index] = true
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object: \"channel\" a string, \"text\" a string, " &
          "\"confirm\" either null or an object with \"ticket\" (an integer " &
          "at least 1), \"side\" (SELL or BUY), \"commodity\" (ORE, OAT, " &
          "TIN or TAR), \"qty\" and \"price\" (integers 0..99).")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    client.callsIssued += open.len
    let responses = client.curl.makeRequests(batch, timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        let decision = parseDecision(sim, seat, extractJsonObject(text))
        ## Reject illegal replies here so the retry carries the hint. An
        ## INADMISSIBLE confirm is not illegal — it is a legal move whose
        ## outcome is a void — so it is never probed and never retried.
        var probe = sim
        probe.applySay(seat, decision.channel, decision.text, decision.notes,
          false)
        result[index] = decision
      except CatchableError as error:
        echo "garble llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "garble llm: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skQuoter)
    client.decidedScripted[index] = true
