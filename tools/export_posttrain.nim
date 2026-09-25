## Export complete Garble games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import garble/[llm, sim]

const OperatorPrompt = "Choose legal transmissions and confirmations to maximize your score over the complete game."
const Variants = ["standard", "storm", "long-session"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    runtimeConfig["turnDelayMs"] = %0
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      sim.beginTurn()
      var decisions: seq[Decision]
      for seat in 0 ..< Seats:
        let teacher = scriptedAction(sim, seat,
          if seat mod 2 == 0: skQuoter else: skShark)
        let completion = decisionJson(sim, teacher)
        let parsed = parseDecision(sim, seat, completion)
        doAssert parsed == teacher
        decisions.add(parsed)
        rows.add($(%*{
          "episode_id": "garble-" & variant & "-" & $seed,
          "seed": "garble-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(sim, seat)},
            {"role": "user", "content": userPrompt(sim, seat,
              OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "garble",
          "action_schema_revision": "garble-decision-v1"
        }))
      for seat, decision in decisions:
        sim.applySay(seat, decision.channel, decision.text,
          decision.notes, scripted = true)
      for seat, decision in decisions:
        if decision.hasConfirm:
          sim.applyConfirm(seat, decision.ticket, decision.side,
            decision.qty, decision.commodity, decision.price,
            scripted = true)
      sim.endTurn()
    doAssert sim.reason == "complete" and rows.len > 0
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "turns_played": sim.turnsPlayed})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "garble",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-quoter-and-shark",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
