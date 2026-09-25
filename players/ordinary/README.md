# Ordinary Garble player

This player receives each seat's private Garble view and sends a complete decision through `garble.player.v3`. The game validates the decision, applies transmissions and confirmations, and records the replay. The player derives its own `quoter` and `shark` decisions from that view. The default policy uses `quoter`. `POC_JEV=1` asks Jev System One to choose between those complete actions. `POC_ADAPTER_DIR` loads a Metta post-training adapter that generates action JSON. Prompt and scripted players remain fieldable.

Build the local game and player images, then run a mixed roster with a manifest built from `coworld_manifest_template.json`:

```bash
docker build --platform linux/amd64 -t garble-game:local .
docker build --platform linux/amd64 -f Dockerfile.ordinary-player -t garble-player:local .
uv run coworld run-episode /path/to/coworld_manifest.json --timeout-seconds 120 -o /tmp/garble-ordinary
```

For local Jev verification, set `POC_JEV=1` and `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` on the ordinary player. That endpoint uses pinned `typesafe/jev-1.13`. A local mock can return a System One choice response; no production model call is needed for protocol testing.

Set `POC_CAPTURE_TRAINING=1` and `POC_SOURCE_REVISION=<policy commit>` to upload accepted player decisions through the standard Coworld artifact URL. Capture whole games with different seeds. Export them with:

```bash
python players/ordinary/export.py /tmp/garble-dataset /tmp/garble-runs --source-revision <policy-commit>
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/garble-dataset --output /tmp/garble-adapter --model /path/to/base-model \
  --device cpu --max-steps 100 --max-length 4096 --max-eval-examples 128
```

The existing `tools/export_posttrain.nim` also exports complete scripted games without containers. The artifact exporter admits only completed games, accepted actions, a matching policy revision, and separate seed splits. Review Jev actions before using `--source jev` as training data.

Package the saved base and adapter into a player image:

```bash
docker build --platform linux/amd64 -f Dockerfile.ordinary-model \
  --build-context base=/path/to/base-model --build-context adapter=/tmp/garble-adapter \
  -t garble-model:local .
```

The loader checks the base model hash against Metta's training manifest. Evaluate saved policies on held-out games before fielding them.
