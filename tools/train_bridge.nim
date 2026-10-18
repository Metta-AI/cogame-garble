## Complete language games through the ordinary-player prompt and action interface.
import std/[json, os]
import garble/[llm, sim, prompts]

const OperatorPrompt = "Choose legal transmissions and confirmations to maximize your score over the complete game."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value: hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc observation(game: Sim, seat, id: int, selection: PromptSelection): JsonNode =
  let view = game.seatDecisionView(seat)
  let system = selection.ordinarySystemPrompt()
  let user = $view & "\n" & OperatorPrompt
  view["prompt_template"] = selection.promptMetadata(system, user)
  %*{"kind": "decision", "game": "garble", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.turn,
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    "speech_messages": [], "typed_question": newJNull(),
    "action_schema": {"type": "object", "properties": {
      "channel": {"type": "string"}, "text": {"type": "string"},
      "notes": {"type": "string"}, "confirm": {"type": ["object", "null"]}}}}

when isMainModule:
  let args = commandLineParams()
  doAssert args.len == 2, "usage: garble-train-bridge MANIFEST VARIANT"
  let manifest = parseFile(args[0])
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == args[1]: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  var game: Sim
  var selection: PromptSelection
  var decisions: array[Seats, Decision]
  var seat, id: int
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      selection = promptSelection(request)
      if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference} and
          request.hasKey("split") and request["split"].getStr() == "train":
        raise newException(ValueError, "held-out wording cannot be used for training")
      let runtime = copy(variantConfig)
      runtime["seed"] = %seedOf(request["seed"].getStr())
      runtime["tokens"] = newJArray()
      for slot in 0 ..< Seats: runtime["tokens"].add(%("t" & $slot))
      var config = defaultGameConfig()
      config.update($runtime)
      config = sampleEpisode(config)
      game = initSim(config)
      game.beginTurn()
      seat = 0
      id = 0
      response = game.observation(seat, id, selection)
    of "teacher":
      doAssert not game.done
      let action = scriptedDecisionFromView(game.seatDecisionView(seat),
        if seat mod 2 == 0: skQuoter else: skShark)
      response = %*{"response": $action}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      decisions[seat] = parseDecision(game, seat, action)
      let installed = decisionJson(game, decisions[seat])
      inc id
      var next: JsonNode
      if seat == Seats - 1:
        for slot, decision in decisions:
          game.applySay(slot, decision.channel, decision.text, decision.notes, scripted = true)
        for slot, decision in decisions:
          if decision.hasConfirm:
            game.applyConfirm(slot, decision.ticket, decision.side, decision.qty,
              decision.commodity, decision.price, scripted = true)
        game.endTurn()
        if game.done:
          let results = game.resultsJson()
          var scores = newJObject()
          for slot in 0 ..< Seats: scores[$slot] = results["scores"][slot]
          next = %*{"kind": "terminal", "scores": scores}
        else:
          game.beginTurn()
          seat = 0
          next = game.observation(seat, id, selection)
      else:
        inc seat
        next = game.observation(seat, id, selection)
      response = %*{"kind": "accepted", "action": installed, "observation": next}
    else: raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
