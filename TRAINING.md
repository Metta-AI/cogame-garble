# Metta post-training data

The native simulator and published `quoter` and `shark` policies export
supervised examples for all three certified Garble variants:

```sh
nimby sync nimby.lock
for variant in standard storm long-session; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/garble-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
games without spectator delays. At each simultaneous turn, it records every
seat's hosted system and user prompts and a scripted decision accepted by the
game's reply parser. Parsed transmissions and confirmations resolve in the
same order as the hosted server. Even seats use `quoter`; odd seats use
`shark`. Whole games stay in one split. The output manifest records source
revision, variant, scores, turns, and row counts. Existing output directories
are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/garble-standard \
  --output /tmp/garble-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete games per variant yielded 480 training and 120 validation
examples for Standard and Storm, and 720 and 180 for Long Session. All 2,100
examples fit the Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum
was 3,823. These examples distill scripted teachers; they do not establish
stronger league play.
One CPU optimizer step per variant with a local tiny model included every
example and reduced heldout loss, verifying the Metta post-training path.
