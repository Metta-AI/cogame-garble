## Player-side Claude decisions and scripted baselines for Garble. The game
## sends a private general observation to every seat and accepts one complete
## action. The player owns prompts, model calls, and candidate construction.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## Without a model credential the bundled prompt player sends a quoter
## fallback. Quoter and shark are also fieldable scripted player policies.

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
    disabled*: bool             ## true once credentials are known-unavailable

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

proc newLlmClient*(maxOutputTokens: int, model: string): LlmClient =
  result = LlmClient(
    model: model,
    maxOutputTokens: maxOutputTokens
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

type
  BaselineParams* = object
    ## The scripted baselines' five tunables, in one object so they can be
    ## swept. `DefaultBaseline` is what ships; the grid those values were
    ## picked from is `scripts/tune_baselines.nim`, recorded in
    ## `docs/tuning/baseline-grid.md`.
    airtimeFloor*: int   ## below this the baseline keeps the meter for confirms
    loudBand*: float     ## the meter at which `quoter` repeats every field
    sellMarkup*: int     ## ask over the market price for the surplus
    buyMarkup*: int      ## bid over the market price for the contract good
    maxLot*: int         ## units per offer

const DefaultBaseline* = BaselineParams(airtimeFloor: 30, loudBand: 0.5,
  sellMarkup: 3, buyMarkup: 1, maxLot: 5)

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

proc scriptedOffer(sim: Sim, seat: int, repeat: bool,
    params: BaselineParams): string =
  ## Quote out of the surplus first, then bid for the contract commodity.
  let prices = sim.livePrices()
  let surplus = sim.sur[seat]
  let demand = sim.dem[seat]
  if sim.units[seat][surplus] >= 3:
    let qty = min(params.maxLot, sim.units[seat][surplus])
    let price = clamp(prices[surplus] + params.sellMarkup, 1, MaxPrice)
    return offerText("SELL", qty, surplus, price, repeat)
  if sim.units[seat][demand] < sim.quota[seat]:
    let qty = min(params.maxLot, sim.quota[seat] - sim.units[seat][demand])
    let price = clamp(prices[demand] + params.buyMarkup, 1, MaxPrice)
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

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind,
    params = DefaultBaseline): Decision =
  ## Rule-based baseline for `seat`. Always legal by construction: bounded
  ## quantities and prices, bounded text, never raises, never writes notes.
  let repeat = kind == skQuoter and sim.liveInterference() >= params.loudBand
  result.channel = Radio
  if sim.airtime[seat] >= params.airtimeFloor:
    result.text = scriptedOffer(sim, seat, repeat, params)
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

proc decisionJson*(sim: Sim, decision: Decision): JsonNode =
  ## Serialize a complete normal player action, including its optional confirm.
  result = %*{
    "channel": (if decision.channel == Radio: "RADIO"
      else: sim.names[decision.channel]),
    "text": decision.text,
    "notes": decision.notes,
    "confirm": newJNull()
  }
  if decision.hasConfirm:
    result["confirm"] = %*{
      "ticket": decision.ticket,
      "side": $decision.side,
      "commodity": Commodities[decision.commodity],
      "qty": decision.qty,
      "price": decision.price
    }

proc scriptedDecisionFromView*(view: JsonNode, kind: ScriptKind): JsonNode =
  ## The fieldable player derives its own baseline action from its private
  ## observation, using the same published parameters as the offline oracle.
  let surplus = view["surplus"].getInt()
  let demand = view["demand"].getInt()
  let units = view["units"]
  let prices = view["prices"]
  let repeat = kind == skQuoter and
    view["interference"].getFloat() >= DefaultBaseline.loudBand
  var text = ""
  if view["airtime"].getInt() >= DefaultBaseline.airtimeFloor:
    if units[surplus].getInt() >= 3:
      text = offerText("SELL",
        min(DefaultBaseline.maxLot, units[surplus].getInt()), surplus,
        clamp(prices[surplus].getInt() + DefaultBaseline.sellMarkup, 1,
          MaxPrice), repeat)
    elif units[demand].getInt() < view["quota"].getInt():
      text = offerText("BUY",
        min(DefaultBaseline.maxLot,
          view["quota"].getInt() - units[demand].getInt()), demand,
        clamp(prices[demand].getInt() + DefaultBaseline.buyMarkup, 1,
          MaxPrice), repeat)
  result = %*{"channel": "RADIO", "text": text, "notes": "",
    "confirm": newJNull()}
  for ticket in view["tickets"]:
    let heard = ticket["heard"]
    if heard.kind == JNull:
      continue
    let commodity = heard["commodity"].getInt()
    let price = heard["price"].getInt()
    let buying = heard["side"].getStr() == "SELL"
    if buying:
      if commodity != demand or units[commodity].getInt() >=
          view["quota"].getInt() or
          price > prices[demand].getInt() + view["premium"].getInt() - 1 or
          (price > 0 and view["cash"].getInt() < price):
        continue
    elif commodity != surplus or price < prices[surplus].getInt() + 1 or
        units[commodity].getInt() <= 0:
      continue
    var qty = heard["qty"].getInt()
    var chosenPrice = price
    if kind == skShark:
      for neighbor in heard["qty_neighbors"]:
        let value = neighbor.getInt()
        if value >= 1:
          qty = if buying: max(qty, value) else: min(qty, value)
      for neighbor in heard["price_neighbors"]:
        let value = neighbor.getInt()
        if value >= 0:
          chosenPrice = if buying: min(chosenPrice, value)
            else: max(chosenPrice, value)
    result["confirm"] = %*{
      "ticket": ticket["id"].getInt(),
      "side": heard["side"].getStr(),
      "commodity": Commodities[commodity],
      "qty": clamp(qty, 0, MaxQty),
      "price": clamp(chosenPrice, 0, MaxPrice)
    }
    break

# ---- Prompt building --------------------------------------------------------

proc systemPrompt*(alias: string): string =
  "You are " & alias &
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

# ---- Ordinary player inference ---------------------------------------------

proc choosePromptAction*(client: LlmClient, view: JsonNode, prompt: string,
    timeoutSeconds, slot: int): JsonNode =
  let system = systemPrompt(view["alias"].getStr())
  let user = $view & "\n\n" & operatorBlock(prompt) &
    "Reply with ONLY a JSON object containing channel, text, confirm " &
    "(an object or null), and notes."
  var request = client.requestFor(system, user)
  if client.transport == ltBedrock:
    request.headers["x-coworld-player-slot"] = $slot
  let response = client.curl.post(request.url, request.headers, request.body,
    timeoutSeconds)
  result = extractJsonObject(client.textOf(response, "", request.url))
  if result.kind != JObject:
    raise newException(GarbleError, "model decision must be an object")
