# Ordinary Garble player

This player receives each seat's private Garble view and sends a complete decision through `garble.player.v3`. The game
validates the decision, applies transmissions and confirmations, and records the replay. The player derives its own
`quoter` and `shark` decisions from that view. The default policy uses `quoter`. `POC_ADAPTER_DIR` loads a Metta
post-training adapter that generates action JSON. Prompt and scripted players remain fieldable.

Build the local game and player images, then run a mixed roster with a manifest built from
`coworld_manifest_template.json`:

```bash
docker build --platform linux/amd64 -t garble-game:local .
docker build --platform linux/amd64 -f Dockerfile.ordinary-player -t garble-player:local .
uv run coworld run-episode /path/to/coworld_manifest.json --timeout-seconds 120 -o /tmp/garble-ordinary
```

Set `POC_CAPTURE_TRAINING=1` and `POC_SOURCE_REVISION=<qualified commit>` to retain every attempt and host execution
acknowledgement. Complete episodes upload a version-2 artifact. Failed generation retains a private local journal; it
does not create a completed episode.

Capture at least ten complete seeds with all five seats. Export private candidates for independent review:

```bash
python players/ordinary/export.py /tmp/garble-candidates /tmp/garble-runs --source-revision QUALIFIED_COMMIT
```

The exporter validates completion, exact prompt hashes, source identity, and host acknowledgements. It creates no
train/validation labels. Source-generated candidates are also available through `tools/export_posttrain.nim`. See
[prompt selection, evidence, review, and evaluation](../../TRAINING.md) before training.

Package the saved base and adapter into a player image:

```bash
docker build --platform linux/amd64 -f Dockerfile.ordinary-model \
  --build-context base=/path/to/base-model --build-context adapter=/tmp/garble-adapter \
  -t garble-model:local .
```

The loader checks the base model hash against Metta's training manifest. Evaluate saved policies on held-out games
before fielding them.
