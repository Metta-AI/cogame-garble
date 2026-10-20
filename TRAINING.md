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
