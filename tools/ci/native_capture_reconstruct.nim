## Independent production-sim reconstruction of retained native socket/HTTP runs.
## Usage: native_capture_reconstruct RUN_DIRECTORY
import std/[json, os, strutils]
import garble/[sim, llm, training_capture]

let directory = paramStr(1)
var config = defaultGameConfig()
config.update(readFile(directory / "config.json"))
config = sampleEpisode(config)
let replay = parseFile(directory / "replay.json")
var events: seq[GameEvent]
for node in replay["events"]: events.add(eventFromJson(node))
let frames = replayMatch(config, events)
doAssert frames[^1].resultsJson() == parseFile(directory / "results.json")
var rows: seq[JsonNode]
for line in readFile(directory / "trajectory.jsonl").splitLines():
  if line.len > 0:
    let row = parseJson(line)
    if row["event_type"].getStr() == "decision": rows.add(row)
var checkedViews = 0
for index, event in events:
  if event.kind != evTurn: continue
  let simultaneous = frames[index + 1]
  for seat in 0 ..< Seats:
    var found = false
    for row in rows:
      if row["decision_id"].getStr() != $event.turn & "-" & $seat: continue
      doAssert row["observation"]["view"] == simultaneous.seatDecisionView(seat)
      doAssert row["observation"]["physical_family"]["split_group"].getStr() ==
        initSim(config).physicalFamily()
      for native in row["observation"]["native_events"]:
        doAssert native["turn"].getInt() == event.turn
        doAssert native["seat"].getInt() == seat
        var matched = false
        for recorded in replay["events"]:
          if recorded == native: matched = true
        doAssert matched
      inc checkedViews
      found = true
    doAssert found
doAssert checkedViews == rows.len

# Same root noise world cannot become a separate split through rule/config or
# policy-name changes. Exact setup identity remains sensitive to physical rules.
var familyConfig = defaultGameConfig()
for seat in 0 ..< Seats: familyConfig.players.add(PlayerConfig(name: "fixture"))
familyConfig.seed = 0
let train = initSim(familyConfig)
familyConfig.seed = 1
let validation = initSim(familyConfig)
doAssert train.physicalFamily() != validation.physicalFamily()
doAssert train.physicalSetup() != validation.physicalSetup()
familyConfig.seed = 0
familyConfig.noiseScale = 1.5
let storm = initSim(familyConfig)
doAssert train.physicalFamily() == storm.physicalFamily()
doAssert train.physicalSetup() != storm.physicalSetup()
familyConfig.noiseScale = 1.0
familyConfig.turns = 18
let longer = initSim(familyConfig)
doAssert train.physicalFamily() == longer.physicalFamily()
doAssert train.physicalSetup() != longer.physicalSetup()
familyConfig.turns = 12
for seat in 0 ..< Seats: familyConfig.players[seat].name = "different policy"
let renamed = initSim(familyConfig)
doAssert train.physicalFamily() == renamed.physicalFamily()
doAssert train.physicalSetup() == renamed.physicalSetup()

# Public/private artifact URI collision fails capture initialization, never game
# parsing. No artifact is written by these rejected initialization attempts.
putEnv("COWORLD_EPISODE_ID", "local-family-proof")
putEnv("COWORLD_GAME_VERSION", "local-proof")
putEnv("COWORLD_SOURCE_REVISION", "local-proof")
putEnv("COGAME_RESULTS_URI", "file:///tmp/garble-no-write-collision.json")
putEnv("COGAME_SAVE_REPLAY_URI", "file:///tmp/garble-no-write-replay.json")
for uri in ["file:///tmp/garble-no-write-collision.json", "file:///tmp/./garble-no-write-collision.json", "file:///tmp/./garble-no-write-replay.json"]:
  putEnv("COGAME_SAVE_TRAJECTORY_URI", uri)
  var rejected = false
  try: discard newRuntimeCapture(train)
  except ValueError: rejected = true
  doAssert rejected

if paramCount() == 3:
  # Exercise the maintained authoritative capture path with a frame emitted by
  # the real native HTTP+WS caller. One scored truncated turn, not a full game.
  let supplied = parseFile(paramStr(2))
  putEnv("COGAME_SAVE_TRAJECTORY_URI", "file://" & absolutePath(paramStr(3)))
  putEnv("COGAME_RESULTS_URI", "")
  putEnv("COGAME_SAVE_REPLAY_URI", "")
  var native = initSim(config)
  native.beginTurn()
  let capture = newRuntimeCapture(native)
  capture.beginCaptureTurn(native)
  let index = capture.receivedFrame(0, 0, supplied, "received action")
  let chosen = parseDecision(native, 0, supplied["action"])
  capture.selectedFrame(0, 0, index, native.decisionJson(chosen))
  var decisions: seq[Decision]
  for seat in 0 ..< Seats:
    decisions.add(if seat == 0: chosen else: scriptedAction(native, seat, skQuoter))
  for seat in 0 ..< Seats:
    let decision = decisions[seat]
    native.applySay(seat, decision.channel, decision.text, decision.notes, seat != 0)
  for seat in 0 ..< Seats:
    let decision = decisions[seat]
    if decision.hasConfirm:
      native.applyConfirm(seat, decision.ticket, decision.side, decision.qty,
        decision.commodity, decision.price, seat != 0)
  capture.appliedCaptureTurn(native, newSeq[bool](Seats), newSeq[bool](Seats))
  native.endTurn()
  native.endEarly()
  capture.finishCapture(native.resultsJson())

echo $(%*{"views_reconstructed_from_production_sim": checkedViews,
  "replay_and_terminal_results_match": true, "native_event_joins": true,
  "prospective_train_seed": 0, "prospective_train_family": train.physicalFamily(),
  "prospective_validation_seed": 1, "prospective_validation_family": validation.physicalFamily(),
  "same_root_group_across_noise_and_rule_variants": true,
  "policy_names_not_physical_identity": true, "private_public_uri_collision_rejected": true,
  "prospective_train_setup": train.physicalSetup(), "prospective_validation_setup": validation.physicalSetup(),
  "qualification": "local synthetic system proof; no authenticated labels or learning claim"})
