# Prompt diversity and post-training candidates

Garble has two prompt surfaces. Native players use the noisy-exchange role instructions. Ordinary Python players use
`docs/rules.md`. Canonical selection preserves each surface's original wording.

The `garble-rules-v1` bank contains five training introductions: `canonical`, `plain`, `numbered`, `questions`, and
`reordered`. The `heldout-briefing` and `heldout-reference` introductions are evaluation-only. Rules, private
observations, action schemas, noise, and episode budgets remain unchanged.

Set `promptVariant` in game configuration. `mixed` additionally requires nonnegative `promptSeed`; it selects one of the
five training wordings for the whole episode. This seed never consumes simulation randomness. The host sends the same
selection to native and ordinary players.

## Source candidates

Commit qualified source before exporting. The exporter runs complete manifest variants with the original quoter/shark
teachers and simultaneous transmission/confirmation ordering:

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/garble-export tools/export_posttrain.nim
/tmp/garble-export /tmp/garble-candidates 10 1 standard mixed 4
```

Output contains private `trajectories.jsonl`, `execution.jsonl`, and a manifest. It records exact prompts and hashes,
proposals, parsed actions, actual events, before/after states, outcomes, source revision, and wording. There are no
automatic training labels. Independent review in Metta controls admission. All variants and wordings of a simulation
seed share the `garble-SEED` family and must stay in one data split.

## Native execution evidence

Set `GARBLE_SOURCE_REVISION` to the qualified source revision. Set `GARBLE_ATTEMPT_TRACE_DIR` on native players and
`GARBLE_EXECUTION_TRACE_DIR` on the host to separate private output directories. Files are exclusively created with mode
`0600`. Player capture records requests before transport, raw responses, parsing outcomes, and exact prompt hashes. Host
capture records proposals, parsed/executed actions, private observations, fallback status, events, and state
transitions. Existing retries, timeouts, and fallbacks are preserved.

These files contain private game information and operator instructions. Keep them out of public replays. Missing call
IDs or behavior log probabilities remain null; capture does not invent provider evidence.

## Ordinary Python players

Set `POC_CAPTURE_TRAINING=1` and `POC_SOURCE_REVISION` to capture every attempt, including rejected decisions. A private
local journal survives generation or parsing failure. Complete episodes upload a version-2 player artifact with raw
responses and host execution acknowledgements. `GARBLE_RULES_FILE` and `PLAYER_PROMPT` still affect actual prompts and
their hashes.

Export ten or more complete seed families, with all five seat artifacts:

```sh
python players/ordinary/export.py /tmp/garble-candidates /tmp/garble-runs \
  --source-revision QUALIFIED_COMMIT --source canned
```

This produces candidates for independent review, not `train.jsonl` or `validation.jsonl`. Host rejection or
normalization cannot become a successful imitation label. Held-out wording is rejected by both candidate exporters.
Retain the host execution directory alongside captured artifacts for review against actual game events.

## Evaluation

Use `tools/test_prompt_games.py` for complete language-bridge games and canonical comparisons.
`tools/test_export_posttrain.py` compares source candidates against the original exporter.
`tools/test_native_prompts.py` exercises real native players against a closed inference endpoint using published game
budgets. `tools/test_ordinary_capture.py` exercises ten full ordinary-player episodes through capture and candidate
export.

Measure canonical equality, wording coverage, private-view isolation, action normalization, fallback rate, prompt
hashes, and event/outcome joins. Closed-endpoint checks exercise transport failure; they do not measure model skill.
Compare trained policies on matched held-out seeds and wordings before claiming reduced collapse or better play. No
learning improvement is established by these checks.
