# Prompt diversity and training

Bank `garble-rules-v2` offers five training wordings and two evaluation-only
wordings. Native inference and the ordinary player share alternate explanations
of confirmation, binding terms, and the redundancy shield. Ordinary prompts also
vary complete section order. Scanner rules, neighbour tables, worked examples,
private views, action grammar, and canonical messages remain unchanged.

Use `promptVariant`: `canonical` (default), `plain`, `numbered`, `questions`,
`reordered`, or `mixed`. Mixed requires a nonnegative `promptSeed`; modulo five
selects one training wording, fixed for the episode without consuming game randomness.
`heldout-briefing` and `heldout-reference` are evaluation-only. Training resets and
both exporters reject them.

The game sends the selected full ordinary system prompt and native prompt configuration
to players. Deploy the game and reference players together. Rules are owned by the
game; player Docker images no longer carry a separate rules-file override.

## Collection and exports

```sh
nim c -d:release --path:src -o:/tmp/garble-bridge tools/train_bridge.nim
/tmp/garble-bridge coworld_manifest_template.json standard
nim c -d:release --path:src -o:/tmp/garble-export tools/export_posttrain.nim
/tmp/garble-export /tmp/garble-data 10 1 standard mixed 0
```

The bridge accepts the complete language action, including confirmations and
private notes. It freezes all five decisions before applying transmissions and
confirmations. Teacher exports retain `train.jsonl`, `validation.jsonl`, and
`manifest.json`. Mixed exports cycle through training wordings separately within
each split and record each selection and rendered-message hashes. Episode IDs
include requested selection, resolved wording, and prompt seed to distinguish matched collections. Keep each `garble-SEED` family together
across rule variants and wordings.

The ordinary player retains its original version-1 accepted-decision artifact,
with wording metadata added to new rows. Its exporter continues reading stored
version-1 rows without that metadata. New artifacts carry hashes and selection
into exported examples. Capture/export usage remains in
[the ordinary player guide](players/ordinary/README.md).

## Native private telemetry

Setting `COGAME_SAVE_TRAJECTORY_URI` opts the game into private decision-trajectory
capture. `COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and
`COWORLD_SOURCE_REVISION` must identify the run. The ordinary v3 turn frame then
carries an optional `private_capture` flag outside the model view. Native Nim
players attach `garble.private-attempt.v1` evidence to their decision, or send an
attempt-only frame after a failed call. Legacy clients can ignore this extension.
Game rules, prompts, parsers, simultaneous dispatch, deadlines, and retries are
unchanged. No new telemetry is emitted to public replay or spectator state.

Private records retain the actual request body, received response bytes, normalized
response headers, original model text and action proposal, authenticated socket
seat/turn, and actual say/confirm events with installed notes. Curly does not expose
original header-wire bytes. Failed transports may expose no partial response;
late, missing, malformed, and oversized evidence remains a gap. Bounds are 16 KiB
request, 16 KiB response, 4 KiB headers, 48 KiB envelope, and four retained frames
per seat/turn; excess frame counts and invalid telemetry reasons remain visible.
The private wire sends each request/response body once as base64 plus the request
object and original target text. The game restores prompt messages and valid UTF-8
response text only from verified lossless bytes before the strict evidence reader;
invalid UTF-8 retains bytes with a null text field. Invalid telemetry inside the existing wire limit never rejects an otherwise valid
game action. The native player checks its full serialized decision against the
existing 64 KiB WebSocket limit and replaces or omits private metadata when needed;
it sends the original action and logs the gap. Frames already over the native wire
limit retain their existing transport failure behavior.

Capture alone authenticates neither a caller's policy/model claims nor its call
ID. Admission requires external authenticated receipt/source/image/participant
joins, strict JSON validation (including duplicate keys and non-finite numbers),
and typed equality of every raw supplied action field with the applied action.
Preserve original fenced responses and all normalization exclusions. Parsed-action
installation, a legal void confirmation, and profitable play are separate facts;
scripted/fallback actions are never approved teacher labels by this capture path.

The split family conservatively groups the root world/noise seed across all
wordings and rule variants. A separate exact setup hash retains generated market,
contracts, endowments, delivery seed, noise/bursts, and consequential configuration.
Policy names and wording choices cannot create independent families. Existing
bridge/script exports and ordinary v1 artifacts retain their original formats and
remain separate from authenticated native model targets.

Run the bounded native proof against already built game/player binaries:

```sh
uv run --no-project --with websocket-client==1.9.2 python tools/ci/native_capture_smoke.py bin/garble bin/garble-player /tmp/garble-capture-positive --case positive
nim c -d:release --path:src -o:/tmp/garble-capture-reconstruct tools/ci/native_capture_reconstruct.nim
/tmp/garble-capture-reconstruct /tmp/garble-capture-positive
```

The isolated invalid-UTF8 caller proof additionally uses `websockets==17.2`:

```sh
uv run --no-project --with websocket-client==1.9.2 --with websockets==17.2 python tools/ci/native_capture_utf8.py bin/garble-player /tmp/garble-capture-reconstruct /tmp/garble-capture-positive /tmp/garble-capture-utf8
```

The same component proof accepts `--case usage-absent`, `usage-null`,
`usage-scalar`, and `usage-invalidtokens` to exercise malformed optional usage
without changing the native action. `--case json-vtab` preserves the native
parser's attempt-only rejection and reconstructs the native quoter fallback;
the original invalid model text remains unselected. Each component finalizes the
real player without running another full game.

Each full-game invocation retains one complete game and its failures, uses whitelisted
subprocess environments and loopback-only synthetic HTTP replies, and has a
180-second wall limit. Other cases exercise normalization, 429, malformed replies,
timeout, invalid telemetry, legacy clients, large responses, and the native frame
boundary. `--case ordinary` preserves the full twelve-turn/default-clock game;
other cases explicitly shorten pacing and deadlines. These fixtures produce zero
authenticated training targets. Use a new output directory for every invocation.

## Checks and experiments

`tools/test_prompt_games.py BRIDGE` runs 30 complete wording and normalization games.
`tools/test_export_posttrain.py EXPORTER` checks 30 complete mixed exports.
The existing `tools/ci/player_policy_smoke.py GAME PLAYER` runs two six-turn fixtures
to check native HTTP prompts, ordinary captured prompts, and zero fallback across
a real mixed roster, then exports the ordinary artifacts into separate families.
These fixtures use local inference stubs.

For training comparisons, match seeds, opponents, seats, and inference settings.
Measure score, invalid-action rate, fallback rate, request counts, and completion
on familiar and held-out wording. Local checks do not establish learned robustness.
