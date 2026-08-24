## Garble game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - the game stage renderer
##   GET /client/chrome_common.js    - the inherited broadcast chrome
##   GET /client/chrome.css          - the inherited broadcast styling
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (garble.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...,"turns":int}
##                   {"type":"state",...} after every event, redacted to the
##                   seat's own tallies (Garble has real hidden information)
##                   {"type":"final","scores":[...],"portfolio":[...]}
##   player -> game: {"type":"prompt","prompt":"...","scripted":bool,
##                    "baseline":"quoter"|"shark"} (prompt max 4000 runes)

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptRunes = 4000
  ReplayVersion = 1
  ## Seconds /healthz and /global keep answering after the artifacts are
  ## written. The platform's collectors are still reading when the episode
  ## settles, and a process that exits the same millisecond loses them.
  ShutdownGraceSeconds = 20
  ## Rate limiting: the hosted Bedrock sidecar caps 30 requests per minute
  ## per episode, so a batch of N calls must be followed by at least
  ## N * 2400 ms before the next batch starts.
  MsPerCall = 2400

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous cog aliases; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"garble"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Garble has real hidden information (every other seat's inventory,
  ## contract, notes and said text, and every other listener's garbling), so
  ## a player frame carries only that seat's own public tallies. Decisions
  ## are server-side, so nothing is lost.
  var units = newJArray()
  for c in 0 ..< CommodityCount:
    units.add(%gs.sim.units[slot][c])
  var prices = newJArray()
  for c in 0 ..< CommodityCount:
    prices.add(%gs.sim.livePrices()[c])
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "seat": {
      "portfolio": gs.sim.portfolio(slot),
      "hold": gs.sim.holdValue(slot),
      "score": gs.sim.score(slot),
      "cash": gs.sim.cash[slot],
      "units": units,
      "airtime": gs.sim.airtime[slot],
      "deals": gs.sim.dealCount[slot],
      "misheard": gs.sim.mishearCount[slot]
    },
    "turn": gs.sim.turn,
    "turns": gs.config.turns,
    "turnsPlayed": gs.sim.turnsPlayed,
    "interference": gs.sim.liveInterference(),
    "prices": prices,
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get the
  ## redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayConfigJson(gs: GameState): JsonNode =
  var commodities = newJArray()
  for name in Commodities:
    commodities.add(%name)
  %*{
    "turns": gs.config.turns,
    "seed": gs.config.seed,
    "noiseScale": gs.config.noiseScale,
    "sampled": true,
    "commodities": commodities,
    "airtimeBudget": AirtimeBudget
  }

proc replayPayload(gs: GameState, results: JsonNode): string =
  ## The bytes are self-sufficient: aliases, policy names, the whole config,
  ## the seed, every decision event and the results. Prices, contracts,
  ## interference, bursts and every garble are re-derived from the seed by
  ## the same Nim module the server ran.
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "garble.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": gs.replayConfigJson(),
    "events": events,
    "results": results
  }

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.turns = payload["config"]{"turns"}.getInt(12)
  result.seed = payload["config"]{"seed"}.getInt(0)
  result.noiseScale = payload["config"]{"noiseScale"}.getFloat(1.0)
  ## The replay carries the episode's fitted cap; never re-fit it.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection. Results carry POLICY
    ## names for the platform; the final frame goes to the player sockets —
    ## hand them the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "portfolio": results["portfolio"],
      "names": aliasNames,
      "turns": results["turns"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "garble: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## Keep /healthz and /global answering for a bounded grace while the
  ## platform's collectors finish, then exit.
  echo "garble: artifacts written; ", ShutdownGraceSeconds,
    "s shutdown grace"
  sleep(ShutdownGraceSeconds * 1000)
  echo "garble: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc sayLine(sim: Sim, seat: int, decision: Decision): string =
  sim.names[seat] & " \u25b8 " &
    (if decision.channel == Radio: "RADIO"
     else: "LINE\u2192" & sim.names[decision.channel]) &
    ": \"" & decision.text & "\""

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "garble: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. Play
    ## inside a fraction of it so results and the replay are written with
    ## room to spare. The hosted dispatcher hands the timeout only to its own
    ## worker sidecar, NOT to the game container, so when the env is silent
    ## assume the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "garble: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    var seats: seq[int]
    for seat in 0 ..< Seats:
      seats.add(seat)
    var callsLastTurn = 0
    var lastBatchStart = 0.0

    while true:
      ## Step 0: the deadline check happens BEFORE the turn opens, so a
      ## deadline ending is a clean, scored, replayed episode rather than a
      ## discarded one.
      var simCopy: Sim
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      var stop = false
      withLock stateLock:
        if state.sim.done:
          stop = true
        elif playDeadline > 0.0 and epochTime() > playDeadline:
          echo "garble: episode deadline reached after ",
            state.sim.turnsPlayed, "/", config.turns, " turns; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          stop = true
        else:
          state.sim.beginTurn()
          echo "garble: turn ", state.sim.turn, " of ", config.turns,
            " interference ", state.sim.liveInterference(),
            (if state.sim.burst[state.sim.turn]: " BURST" else: ""),
            " at ", (epochTime() - gameStart).int, "s"
          state.broadcastLocked()
          simCopy = state.sim
          prompts = state.prompts
          scripted = state.scripted
      if stop:
        break

      ## Rate limiting: batch starts are floored so an episode never exceeds
      ## the hosted sidecar's 30 requests/minute.
      if lastBatchStart > 0.0:
        let spacingMs = max(config.minTurnSpacingMs, callsLastTurn * MsPerCall)
        let waitMs = int(float(spacingMs) -
          (epochTime() - lastBatchStart) * 1000.0)
        if waitMs > 0:
          sleep(min(waitMs, spacingMs))
      lastBatchStart = epochTime()

      ## Every wait is bounded, and the batch timeout is additionally
      ## clamped to whatever is left of the play budget.
      var effective = config.llmTimeoutSeconds
      if playDeadline > 0.0:
        effective = min(effective, max(5, int(playDeadline - epochTime())))
      let decisions = client.decideAll(simCopy, seats, prompts, scripted,
        effective)
      callsLastTurn = client.callsIssued

      withLock stateLock:
        ## Transmit, in seat order.
        for seat in 0 ..< Seats:
          let decision = decisions[seat]
          let wasScripted = scripted[seat] != skNone or client.disabled or
            client.decidedScripted[seat]
          echo "garble: ", sayLine(state.sim, seat, decision)
          try:
            state.sim.applySay(seat, decision.channel, decision.text,
              decision.notes, wasScripted)
          except GarbleError as error:
            echo "garble: transmission rejected (", error.msg,
              "); using the scripted fallback"
            let fallback = scriptedAction(state.sim, seat, skQuoter)
            state.sim.applySay(seat, fallback.channel, fallback.text, "", true)
          state.broadcastLocked()
        ## Confirms, in seat order, after every transmission has landed.
        for seat in 0 ..< Seats:
          let decision = decisions[seat]
          if not decision.hasConfirm:
            continue
          let wasScripted = scripted[seat] != skNone or client.disabled or
            client.decidedScripted[seat]
          try:
            state.sim.applyConfirm(seat, decision.ticket, decision.side,
              decision.qty, decision.commodity, decision.price, wasScripted)
          except GarbleError as error:
            ## An inadmissible confirm is a legal move that voids; only a
            ## malformed one lands here, and it costs the seat its confirm.
            echo "garble: confirm rejected (", error.msg, ")"
          state.broadcastLocked()
        state.sim.endTurn()
        state.broadcastLocked()

      ## Pace so a spectator can read the turn that just landed.
      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8")

proc chromeCommonHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome_common.js",
      "application/javascript; charset=utf-8")

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "garble: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "garble.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "turns": state.config.turns
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.runeLen > MaxPromptRunes:
            prompt = prompt.runeSubStr(0, MaxPromptRunes)
          var kind = skNone
          if payload{"scripted"}.getBool(false):
            kind = parseScriptKind(payload{"baseline"}.getStr("quoter"))
            if kind == skNone:
              kind = skQuoter
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = kind
          echo "garble: slot ", slot, " delivered a prompt (",
            prompt.runeLen, " runes",
            (if kind != skNone: ", scripted " & $kind else: ""), ")"
      except CatchableError as error:
        echo "garble: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay_broadcast.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome_common.js", chromeCommonHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("garble.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "garble: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(GarbleError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "garble: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
