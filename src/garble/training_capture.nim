## Optional private telemetry. Socket identity and the native sim own execution;
## caller metadata is untrusted until an external authenticated receipt audit.
import std/[base64, json, math, options, os, parsejson, streams, strutils, tables, unicode]
import crunchy, curly
import bitworld/runtime
import ./decision_trajectory, ./sim
export decision_trajectory, options

const
  CaptureProtocol* = "garble.private-attempt.v1"
  MaxEvidenceBytes* = 49_152
  MaxRequestBytes = 16_384
  MaxResponseBytes = 16_384
  MaxHeaderBytes = 4_096
  MaxCapturedFrames = 4
  MaxCaptureTurns = 24

type
  PrivateCapture* = ref object
    evidence*: JsonNode
  CapturedFrame = ref object
    diagnostic: JsonNode
    attempt: Option[DecisionAttempt]
  CapturedDecision = ref object
    observation, actual: JsonNode
    frames: seq[CapturedFrame]
    selected: int
    fallback: bool
  RuntimeCapture* = ref object
    trajectory: DecisionTrajectory
    turns: Table[int, seq[CapturedDecision]]
    physical: JsonNode

proc strictRawObject(text: string): JsonNode =
  ## Independent admission parser: the gameplay decoder remains unchanged.
  if text.validateUtf8() != -1: raise newException(ValueError, "raw JSON is not UTF-8")
  let first = text.find('{')
  let last = text.rfind('}')
  if first < 0 or last < first: raise newException(ValueError, "no raw JSON object")
  let source = text[first .. last]
  var quoted = false
  var index = 0
  while index < source.len:
    let character = source[index]
    if quoted:
      if character == '\\':
        inc index
        if index >= source.len or source[index] notin {'"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u'}:
          raise newException(ValueError, "non-JSON string escape")
        if source[index] == 'u':
          for offset in 1 .. 4:
            if index + offset >= source.len or source[index + offset] notin {'0'..'9', 'a'..'f', 'A'..'F'}:
              raise newException(ValueError, "invalid Unicode escape")
          index += 4
      elif character == '"': quoted = false
      elif ord(character) < 32: raise newException(ValueError, "unescaped control character")
    elif character == '"': quoted = true
    elif character == '/': raise newException(ValueError, "JSON comments are forbidden")
    inc index
  if quoted: raise newException(ValueError, "unterminated JSON string")
  var parser: JsonParser
  parser.open(newStringStream(source), "private raw action")
  defer: parser.close()
  discard parser.getTok()
  proc value(parser: var JsonParser, depth: int): JsonNode =
    if depth > 32: raise newException(ValueError, "raw JSON depth bound exceeded")
    case parser.tok
    of tkCurlyLe:
      result = newJObject()
      discard parser.getTok()
      if parser.tok == tkCurlyRi:
        discard parser.getTok()
        return
      while true:
        if parser.tok != tkString: raise newException(ValueError, "JSON object key required")
        let key = parser.a
        if result.hasKey(key): raise newException(ValueError, "duplicate JSON key: " & key)
        discard parser.getTok()
        parser.eat(tkColon)
        result[key] = value(parser, depth + 1)
        if parser.tok == tkCurlyRi:
          discard parser.getTok()
          break
        parser.eat(tkComma)
    of tkBracketLe:
      result = newJArray()
      discard parser.getTok()
      if parser.tok == tkBracketRi:
        discard parser.getTok()
        return
      while true:
        result.add(value(parser, depth + 1))
        if parser.tok == tkBracketRi:
          discard parser.getTok()
          break
        parser.eat(tkComma)
    of tkString:
      result = %parser.a
      discard parser.getTok()
    of tkInt, tkFloat:
      let token = parser.a
      # Enforce JSON number spelling independently of Nim's permissive lexer.
      var cursor = 0
      if token[cursor] == '-': inc cursor
      if cursor >= token.len: raise newException(ValueError, "invalid JSON number")
      if token[cursor] == '0': inc cursor
      elif token[cursor] in {'1'..'9'}:
        while cursor < token.len and token[cursor] in {'0'..'9'}: inc cursor
      else: raise newException(ValueError, "invalid JSON number")
      if cursor < token.len and token[cursor] == '.':
        inc cursor
        let start = cursor
        while cursor < token.len and token[cursor] in {'0'..'9'}: inc cursor
        if cursor == start: raise newException(ValueError, "invalid JSON fraction")
      if cursor < token.len and token[cursor] in {'e', 'E'}:
        inc cursor
        if cursor < token.len and token[cursor] in {'+', '-'}: inc cursor
        let start = cursor
        while cursor < token.len and token[cursor] in {'0'..'9'}: inc cursor
        if cursor == start: raise newException(ValueError, "invalid JSON exponent")
      if cursor != token.len: raise newException(ValueError, "invalid JSON number")
      if parser.tok == tkInt: result = %parseBiggestInt(token)
      else:
        let number = parseFloat(token)
        if number.classify in {fcNan, fcInf, fcNegInf}:
          raise newException(ValueError, "non-finite raw JSON number")
        result = %number
      discard parser.getTok()
    of tkTrue, tkFalse:
      result = %(parser.tok == tkTrue)
      discard parser.getTok()
    of tkNull:
      result = newJNull()
      discard parser.getTok()
    else: raise newException(ValueError, "invalid raw JSON value")
  result = value(parser, 0)
  if parser.tok != tkEof or result.kind != JObject:
    raise newException(ValueError, "one raw JSON object required")

proc suppliedFieldsEqual(raw, actual: JsonNode): bool =
  if raw == nil or actual == nil or raw.kind != actual.kind: return false
  if raw.kind == JObject:
    for key, value in raw:
      if not actual.hasKey(key) or not suppliedFieldsEqual(value, actual[key]): return false
    return true # Native omitted defaults are allowed; supplied fields never normalize.
  if raw.kind == JArray:
    if raw.len != actual.len: return false
    for index in 0 ..< raw.len:
      if not suppliedFieldsEqual(raw[index], actual[index]): return false
    return true
  raw == actual

proc physicalSetup*(sim: Sim): JsonNode =
  ## Delivery noise has its own seed-derived stream, beyond the visible paths.
  %*{"delivery_seed": sim.config.seed, "turns": sim.config.turns,
    "noise_scale": sim.config.noiseScale, "prices": sim.prices,
    "surplus": sim.sur, "demand": sim.dem, "premium": sim.premium,
    "quota": sim.quota, "curve": sim.curve, "interference": sim.interference,
    "burst": sim.burst, "burst_fraction": sim.burstFrac,
    "burst_length": sim.burstLen, "cash": sim.startCash, "units": sim.startUnits,
    "airtime": AirtimeBudget, "confirm_airtime": ConfirmAirtime,
    "ticket_life": TicketLife, "max_words": MaxWords,
    "max_text_runes": MaxTextRunes, "max_notes_runes": MaxNotesRunes,
    "max_qty": MaxQty, "max_price": MaxPrice, "line_noise_factor": LineNoiseFactor,
    "heard_window": HeardWindow, "action_timeout_seconds": sim.config.actionTimeoutSeconds,
    "turn_spacing_ms": sim.config.turnSpacingMs, "turn_delay_ms": sim.config.turnDelayMs,
    "connect_timeout_seconds": sim.config.playerConnectTimeoutSeconds,
    "episode_timeout_seconds": sim.config.episodeTimeoutSeconds,
    "hosted_timeout_override": getEnv("COWORLD_TIMEOUT_SECONDS")}

proc physicalFamily*(sim: Sim): string =
  ## Conservatively group every wording/rule variant of a root noise world.
  "garble-root-noise-v1-" & sha256($ %*{"seed": sim.config.seed}).toHex.toLowerAscii()

proc newRuntimeCapture*(sim: Sim): RuntimeCapture =
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0: return nil
  let privateUri = getEnv(CogameSaveTrajectoryUriEnv)
  for publicUri in [getEnv("COGAME_RESULTS_URI"), getEnv("COGAME_SAVE_REPLAY_URI")]:
    if publicUri.len == 0: continue
    if privateUri == publicUri or (not privateUri.isHttpCogameUri() and
        not publicUri.isHttpCogameUri() and
        absolutePath(pathFromCogameUri(privateUri, CogameSaveTrajectoryUriEnv)).normalizedPath ==
        absolutePath(pathFromCogameUri(publicUri, "public artifact")).normalizedPath):
      raise newException(ValueError, "private trajectory URI collides with public artifact")
  let physical = sim.physicalSetup()
  RuntimeCapture(trajectory: newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
    sim.physicalFamily(), "garble", getEnv("COWORLD_GAME_VERSION"),
    getEnv("COWORLD_SOURCE_REVISION")), physical: %*{
      "setup": physical, "setup_sha256": sha256($physical).toHex.toLowerAscii(),
      "split_group": sim.physicalFamily()},
    turns: initTable[int, seq[CapturedDecision]]())

proc beginCaptureTurn*(capture: RuntimeCapture, sim: Sim) =
  if capture == nil: return
  if capture.turns.len >= MaxCaptureTurns:
    raise newException(ValueError, "private capture turn bound exceeded")
  var decisions: seq[CapturedDecision]
  for seat in 0 ..< Seats:
    decisions.add(CapturedDecision(observation: %*{
      "view": sim.seatDecisionView(seat), "physical_family": capture.physical,
      "telemetry_frames": [], "omitted_frames": 0,
      "receipt_authority": "external authenticated platform receipt required"},
      actual: newJNull(), selected: -1))
  capture.turns[sim.turn] = decisions

proc claim(payload: JsonNode, key: string): JsonNode =
  if payload.hasKey(key) and payload[key] != nil: copy(payload[key])
  else: newJNull()

proc receivedFrame*(capture: RuntimeCapture, turn, seat: int, payload: JsonNode,
    disposition: string): int =
  result = -1
  if capture == nil: return
  if not capture.turns.hasKey(turn):
    echo "garble capture: telemetry for unopened turn ignored: ", turn
    return
  let decision = capture.turns[turn][seat]
  if decision.frames.len >= MaxCapturedFrames:
    decision.observation["omitted_frames"] = %(decision.observation["omitted_frames"].getInt() + 1)
    return
  let frame = CapturedFrame(diagnostic: %*{"disposition": disposition,
    "source_claim": claim(payload, "source"), "seat_claim": claim(payload, "seat"), "telemetry_error": "missing private telemetry"})
  if payload.hasKey("action"):
    let encoded = $payload["action"]
    if encoded.len <= MaxEvidenceBytes: frame.diagnostic["raw_proposal"] = copy(payload["action"])
    else: frame.diagnostic["proposal_gap"] = %"proposal exceeds capture byte bound"
  if payload.hasKey("private_attempt"):
    let envelope = payload["private_attempt"]
    let encoded = $envelope
    if encoded.len > MaxEvidenceBytes:
      frame.diagnostic["telemetry_error"] = %"private telemetry exceeds 49152 bytes"
      frame.diagnostic["oversized_sha256"] = %sha256(encoded).toHex.toLowerAscii()
      frame.diagnostic["oversized_bytes"] = %encoded.len
    else:
      try:
        if envelope.kind != JObject or envelope{"schema"}.getStr() != CaptureProtocol:
          raise newException(ValueError, "unknown private telemetry schema")
        for key in envelope.keys:
          if key notin ["schema", "attempt", "request_body_b64", "telemetry_error"]:
            raise newException(ValueError, "unknown private telemetry field: " & key)
        if envelope.hasKey("telemetry_error"):
          raise newException(ValueError, envelope["telemetry_error"].getStr())
        if not envelope.hasKey("attempt") or envelope["attempt"] == nil or envelope["attempt"].kind != JObject:
          raise newException(ValueError, "private telemetry attempt object is required")
        let bytes = envelope["request_body_b64"].getStr()
        let requestBytes = decode(bytes)
        if encode(requestBytes) != bytes or requestBytes.len > MaxRequestBytes:
          raise newException(ValueError, "invalid or oversized request bytes")
        let request = parseJson(requestBytes)
        var restored = copy(envelope["attempt"])
        if request != restored["request"]:
          raise newException(ValueError, "request bytes differ from request object")
        if request["system"].kind != JString or request["messages"].kind != JArray or
            request["messages"].len != 1 or request["messages"][0]["role"].getStr() != "user" or
            request["messages"][0]["content"].kind != JString:
          raise newException(ValueError, "native system/user request shape required")
        let actualPrompt = %*[{"role": "system", "content": request["system"]},
          {"role": "user", "content": request["messages"][0]["content"]}]
        if restored["prompt"].kind != JNull and restored["prompt"] != actualPrompt:
          raise newException(ValueError, "prompt differs from exact request bytes")
        restored["prompt"] = actualPrompt
        if restored.hasKey("response_body_b64") and restored["response_body_b64"].kind != JNull:
          if restored["response_body_b64"].kind != JString:
            raise newException(ValueError, "response body base64 must be a string")
          let encodedBody = restored["response_body_b64"].getStr()
          let body = decode(encodedBody)
          if encode(body) != encodedBody or body.len > MaxResponseBytes:
            raise newException(ValueError, "invalid or oversized response bytes")
          if body.validateUtf8() == -1:
            if restored["raw_response"].kind != JNull and restored["raw_response"].getStr() != body:
              raise newException(ValueError, "raw response differs from received bytes")
            restored["raw_response"] = %body
          elif restored["raw_response"].kind != JNull:
            raise newException(ValueError, "invalid UTF-8 response must retain bytes with null raw response")
        var headerBytes = 0
        if restored["response_headers"].kind == JObject:
          for name, value in restored["response_headers"]:
            headerBytes += name.len + value.getStr().len
          if headerBytes > MaxHeaderBytes:
            raise newException(ValueError, "response headers exceed private byte bound")
        # Validate the restored raw response with the unchanged strict reader.
        var attempt = readAttemptEvidence(restored)
        frame.diagnostic["client_identity_claims"] = %*{
          "attempt_id": attempt.attemptId, "policy": attempt.policy,
          "origin": envelope["attempt"]["origin"]}
        # Ignore all caller identity, origin and acceptance claims.
        attempt.attemptId = $turn & "-" & $seat & "-" & $decision.frames.len
        attempt.policy = "socket-player"
        attempt.origin = aoUnknown
        if payload{"source"}.getStr("player") == "player": attempt.origin = aoModel
        frame.diagnostic["request_body_b64"] = %bytes
        frame.diagnostic["telemetry_error"] = newJNull()
        frame.attempt = some(attempt)
      except CatchableError as error:
        frame.diagnostic["telemetry_error"] = %error.msg
        frame.diagnostic["invalid_private_envelope"] = copy(envelope)
        echo "garble capture: invalid private telemetry seat ", seat, ": ", error.msg
  decision.frames.add(frame)
  result = decision.frames.high

proc selectedFrame*(capture: RuntimeCapture, turn, seat, index: int,
    parsed: JsonNode) =
  if capture == nil or index < 0: return
  let decision = capture.turns[turn][seat]
  decision.selected = index
  decision.frames[index].diagnostic["disposition"] = %"installed native parsed action"
  decision.frames[index].diagnostic["native_parsed_action"] = copy(parsed)
  if decision.frames[index].attempt.isSome:
    var attempt = decision.frames[index].attempt.get()
    attempt.parsedAction = copy(parsed)
    decision.frames[index].attempt = some(attempt)

proc rejectedFrame*(capture: RuntimeCapture, turn, seat, index: int, reason: string) =
  if capture == nil or index < 0: return
  capture.turns[turn][seat].frames[index].diagnostic["disposition"] = %reason

proc appliedCaptureTurn*(capture: RuntimeCapture, sim: Sim,
    fallback, mixedOrigins: seq[bool]) =
  if capture == nil: return
  for seat in 0 ..< Seats:
    let decision = capture.turns[sim.turn][seat]
    decision.fallback = fallback[seat]
    decision.observation["execution_origin"] = %(
      if mixedOrigins[seat]: "mixed native-quoter transmission and original confirmation"
      elif fallback[seat]: "native-quoter fallback"
      else: "installed socket action")
    var actual = %*{"channel": "RADIO", "text": "", "notes": sim.notes[seat], "confirm": nil}
    var events = newJArray()
    for event in sim.events:
      if event.turn != sim.turn or event.seat != seat: continue
      if event.kind == evSay:
        actual["channel"] = %(if event.channel == Radio: "RADIO" else: sim.names[event.channel])
        actual["text"] = %event.text
        actual["notes"] = %event.notes
      if event.kind == evConfirm:
        actual["confirm"] = %*{"ticket": event.ticket, "side": $event.side,
          "commodity": Commodities[event.commodity], "qty": event.qty, "price": event.price}
      events.add(event.eventToJson())
    decision.actual = actual
    decision.observation["native_events"] = events

proc finishCapture*(capture: RuntimeCapture, outcome: JsonNode) =
  if capture == nil: return
  for turn in 0 ..< MaxCaptureTurns:
    if not capture.turns.hasKey(turn): continue
    for seat, decision in capture.turns[turn]:
      if decision.actual.kind == JNull: continue # interrupted open turn is a gap
      var attempts: seq[DecisionAttempt]
      var selected = none(string)
      var status = asRejected
      for index, frame in decision.frames:
        decision.observation["telemetry_frames"].add(frame.diagnostic)
        if frame.attempt.isNone: continue
        var attempt = frame.attempt.get()
        attempt.accepted = false
        if index == decision.selected and not decision.fallback and
            attempt.origin == aoModel and attempt.responseComplete == some(true) and
            attempt.httpStatus == some(200) and attempt.response.kind == JString and
            attempt.platformCallId.isSome:
          try:
            let raw = strictRawObject(attempt.response.getStr())
            if not suppliedFieldsEqual(raw, decision.actual):
              raise newException(ValueError, "raw supplied action fields/types differ from native applied action")
            if not frame.diagnostic.hasKey("raw_proposal") or raw != frame.diagnostic["raw_proposal"]:
              raise newException(ValueError, "raw model object differs from supplied socket action")
            attempt.accepted = true
            # Installed defaults are canonicalized only after all supplied raw
            # fields passed strict equality. The original text stays untouched.
            attempt.parsedAction = copy(decision.actual)
          except CatchableError as error:
            attempt.rejectionReason = some(error.msg)
        if attempt.accepted:
          selected = some(attempt.attemptId)
          status = asAccepted
        attempts.add(attempt)
      if decision.fallback:
        var actual = newDecisionAttempt($turn & "-" & $seat & "-fallback", "engine-fallback-or-mixed", aoFallback)
        actual.parsedAction = copy(decision.actual)
        actual.accepted = true
        attempts.add(actual)
        selected = some(actual.attemptId)
        status = asFallback
      decision.observation["strict_raw_fields_enforced"] = %true
      decision.observation["authenticated_receipt_audit_required"] = %true
      capture.trajectory.recordDecision($turn & "-" & $seat, $seat,
        decision.observation, attempts, selected, decision.actual, status,
        fallbackOrigin = (if decision.fallback: some("engine-fallback-or-mixed") else: none(string)))
  capture.trajectory.finish(if outcome{"reason"}.getStr() == "complete": esCompleted else: esTruncated,
    outcome, outcome{"scores"})
  capture.trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))

proc requestAttempt*(body: string): DecisionAttempt =
  if body.len > MaxRequestBytes:
    raise newException(ValueError, "request exceeds private capture 16384 byte bound; bytes unavailable")
  result = newDecisionAttempt("caller-untrusted", "socket-player", aoModel)
  result.request = parseJson(body)
  result.model = some(result.request{"model"}.getStr())
  result.prompt = %*[{"role": "system", "content": result.request["system"]},
    {"role": "user", "content": result.request["messages"][0]["content"]}]
  result.decoder = %*{"max_tokens": result.request["max_tokens"]}
  for key in ["temperature", "top_p", "top_k", "output_config"]:
    if result.request.hasKey(key): result.decoder[key] = result.request[key]

proc receivedResponse*(attempt: var DecisionAttempt, response: Response, latencyMs: float) =
  attempt.latencyMs = some(latencyMs)
  if response.body.len > MaxResponseBytes:
    attempt.rejectionReason = some("response exceeds private capture 16384 byte bound; bytes unavailable; sha256=" &
      sha256(response.body).toHex.toLowerAscii())
    return
  attempt.responseBodyB64 = some(encode(response.body))
  if response.body.validateUtf8() == -1: attempt.rawResponse = %response.body
  attempt.responseComplete = some(true)
  attempt.responseReaderJoined = some(true)
  attempt.httpStatus = some(response.code)
  var headers = initTable[string, string]()
  var headerBytes = 0
  for (key, value) in response.headers:
    headerBytes += key.len + value.len
    if headerBytes > MaxHeaderBytes:
      attempt.rejectionReason = some("response headers exceed private capture 4096 byte bound; headers unavailable")
      return
    headers[key] = value
  attempt.responseHeaders = some(headers) # Curly exposes normalized headers, not wire header bytes.
  if response.headers.contains("X-Softmax-Llm-Call-Id"):
    attempt.platformCallId = some(response.headers["X-Softmax-Llm-Call-Id"])
  for key in ["request-id", "x-request-id"]:
    if response.headers.contains(key):
      attempt.providerRequestId = some(response.headers[key])
      break
  try:
    let payload = parseJson(response.body)
    if payload{"model"}.getStr().len > 0: attempt.model = some(payload["model"].getStr())
    if payload{"stop_reason"}.getStr().len > 0: attempt.stopReason = some(payload["stop_reason"].getStr())
    if payload.hasKey("usage"):
      for key in ["input_tokens", "output_tokens"]:
        if payload["usage"].hasKey(key):
          if key == "input_tokens": attempt.inputTokens = some(payload["usage"][key].getInt())
          else: attempt.outputTokens = some(payload["usage"][key].getInt())
  except CatchableError: discard

proc privateEnvelope*(attempt: DecisionAttempt, body: string): JsonNode =
  result = %*{"schema": CaptureProtocol, "request_body_b64": encode(body),
    "attempt": attemptEvidenceJson(attempt)}
  # Exact body bytes already carry these copies. Restore only from validated
  # bytes in the game, before applying the strict evidence reader.
  result["attempt"]["prompt"] = newJNull()
  result["attempt"]["raw_response"] = newJNull()
  if ($result).len > MaxEvidenceBytes:
    result = %*{"schema": CaptureProtocol,
      "telemetry_error": "caller telemetry exceeds 49152 bytes; bytes unavailable"}

proc decisionFrame*(turn: JsonNode, source: string, action: JsonNode,
    capture: PrivateCapture): JsonNode =
  ## The original native transport limit is 64 KiB. Optional telemetry cannot
  ## make a previously valid action exceed it, even near the wire boundary.
  result = %*{"type": "decision", "turn": turn, "source": source, "action": action}
  if capture == nil or capture.evidence == nil: return
  let original = $result
  if original.len > 65_536:
    echo "garble capture: original action already exceeds native64KiB transport; telemetry omitted"
    return # Preserve the existing action/transport behavior.
  result["private_attempt"] = capture.evidence
  if ($result).len <= 65_536: return
  echo "garble capture: private telemetry omitted to preserve native64KiB decision frame"
  result["private_attempt"] = %*{"schema": CaptureProtocol,
    "telemetry_error": "private evidence would exceed native64KiB decision frame; bytes unavailable"}
  if ($result).len > 65_536:
    result.delete("private_attempt") # Send exactly the original valid action.
