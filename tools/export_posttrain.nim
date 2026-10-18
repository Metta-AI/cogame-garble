## Stream complete private candidates; shared review owns training admission.
import std/[json, os, osproc, strutils]
import garble/[llm, sim, prompts, evidence]

const OperatorPrompt = "Choose legal transmissions and confirmations to maximize your score over the complete game."

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "standard"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert games >= 10 and firstSeed >= 1
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  writePrivate(output / "execution.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let execution = open(output / "execution.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + games:
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = newJArray()
      for seat in 0 ..< Seats: runtimeConfig["tokens"].add(%("t" & $seat))
      runtimeConfig["seed"] = %seed
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      var sim = initSim(config)
      let family = "garble-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var count = 0
      while not sim.done:
        sim.beginTurn()
        let turn = sim.turn
        let eventStart = sim.events.len
        let before = sim.tableStateJson()
        let snapshot = sim
        var decisions: array[Seats, Decision]
        var records: array[Seats, JsonNode]
        for seat in 0 ..< Seats:
          let system = selection.ordinarySystemPrompt()
          let user = $snapshot.seatDecisionView(seat) & "\n" & OperatorPrompt
          let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
          var view = snapshot.seatDecisionView(seat)
          view["prompt_template"] = selection.promptMetadata(system, user)
          let kind = if seat mod 2 == 0: skQuoter else: skShark
          let proposal = scriptedDecisionFromView(snapshot.seatDecisionView(seat), kind)
          let parsed = parseDecision(snapshot, seat, proposal)
          decisions[seat] = parsed
          let installed = decisionJson(snapshot, parsed)
          let accepted = proposal == installed
          let id = count + seat
          let attemptId = $id & "-teacher"
          let attempt = %*{
            "attempt_id": attemptId, "policy": "scripted-" & $kind, "origin": "teacher",
            "inference_mode": "text_action", "prompt": messages,
            "response": $proposal, "parsed_action": proposal, "accepted": accepted,
            "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
            "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")
          }
          records[seat] = %*{
            "schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $id, "decision_index": id,
            "game": "garble", "game_version": "source-" & revision,
            "source_revision": revision, "seat": $seat, "visibility": "private",
            "observation": view, "prompt": (if accepted: messages else: newJNull()),
            "attempts": [attempt], "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
            "executed_action": installed, "action_status": (if accepted: "accepted" else: "fallback"),
            "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
            "terminal": false
          }
        for seat, decision in decisions:
          sim.applySay(seat, decision.channel, decision.text, decision.notes, scripted = true)
        for seat, decision in decisions:
          if decision.hasConfirm:
            sim.applyConfirm(seat, decision.ticket, decision.side, decision.qty,
              decision.commodity, decision.price, scripted = true)
        sim.endTurn()
        var events, decisionIds = newJArray()
        for index in eventStart ..< sim.events.len: events.add(eventToJson(sim.events[index]))
        for seat in 0 ..< Seats:
          decisionIds.add(%($(count + seat)))
          records[seat]["terminal"] = %(sim.done and seat == Seats - 1)
        execution.writeLine($(%*{
          "schema_version": 1, "event_type": "turn_execution", "episode_id": episode,
          "decision_ids": decisionIds, "source_revision": revision,
          "visibility": "private", "turn": turn, "before": before, "after": sim.tableStateJson(),
          "event_start": eventStart, "event_end": sim.events.len, "events": events,
          "terminal": sim.done}))
        for record in records: stream.writeLine($record)
        count += Seats
      doAssert sim.reason == "complete"
      let outcome = sim.resultsJson()
      var participants = newJObject()
      for seat in 0 ..< Seats: participants[$seat] = %*{"score": outcome["scores"][seat]}
      stream.writeLine($(%*{
        "schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "garble", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed", "outcome": outcome,
        "participant_outcomes": participants
      }))
      runs.add(%*{"seed": seed, "decisions": count, "scores": outcome["scores"],
        "turns_played": sim.turnsPlayed})
  finally:
    execution.close()
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "garble", "variant": variant,
    "source_revision": revision, "teacher": "scripted-quoter-and-shark",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "execution_evidence": "execution.jsonl", "runs": runs}) & "\n")
  echo "complete games=", games
