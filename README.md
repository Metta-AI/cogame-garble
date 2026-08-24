# Garble

A **noisy-channel trading game** for the Softmax Coworld platform, forked
from [cogame-babel](https://github.com/Metta-AI/cogame-babel) (the
parley-lineage template for turn-based talk games). Five cogs trade four
commodities — **ORE, OAT, TIN, TAR** — over one shared radio and pairwise
private lines, and **every channel is noisy**. Each cog starts holding a
pile of one commodity it does not need and a private contract that pays a
premium for a different one, so there are real gains from trade and no two
cogs want the same thing. The only way to trade is to talk.

Each turn a cog transmits **one line**, on the **radio** (all four others
hear it) or on a **private line** to one named cog (cleaner channel, one
listener). Every transmission passes through the channel: words drop, swap
for published near-neighbours (`5` → `50`, `5` → `4`, `ORE` → `OAT`,
`FIVE` → `NINE`), or vanish under a static burst — and **each recipient
gets its own independent garbling**, with intensity riding a public
interference meter that swells and fades through the episode.

The exchange scans terms out of the words — `SELL` or `BUY`, then `AT`,
taking the *most repeated* number and commodity before `AT` as quantity and
commodity and the *most repeated* number after `AT` as price — and opens a
**ticket**. A deal executes when another cog **confirms** that ticket, and
**the confirmed terms are what the exchange enforces**, not the terms that
were spoken: a misheard `SELL 5 ORE AT 12` can settle as
`SELL 50 ORE AT 1`. The offerer's only defence is the **redundancy
shield** — a field said twice binds exactly, a field said once can be
confirmed as any of its published near-neighbours — and repeating costs
**airtime**, metered in characters, 900 per episode with a flat 40 per
confirm. So the whole game is the tradeoff between protocol robustness and
speed, plus strategic mishearing: you may confirm the version that favours
you, and your counterparty's only defence is a tighter protocol.

**The game is LLM-driven and a policy is just a prompt.** Every turn the
game server sends each seat's policy prompt plus its inventory, its private
contract, the interference forecast, its own heard traffic, the tickets it
may confirm (with the ready-made confirm JSON for each) and the public deal
tape to Claude — all five seats in **one parallel batch** — and Claude
answers with a transmission, an optional confirm, and new private notes.
Player containers exist only to deliver their prompt over the websocket.
Two built-in **scripted baselines** — `quoter`, the honest repeater, and
`shark`, the terse opportunist — play any seat that registers as scripted,
and every seat when no LLM credentials are available, so episodes (and
offline certification) always complete.

Seats play under **anonymous cog aliases** (Sprocket, Gizmo, …): policy
display names never reach the agents' prompts. The spectator and replay
viewers map the aliases back to policy names; results are reported under
policy names.

**Scoring:** `score = portfolio / hold` — final portfolio value (cash, plus
units marked at the last turn's prices, plus the contract premium on demand
units up to quota) divided by what the seat would have been worth had it
never traded. **Higher is better**, `1.00` means traded to no effect, and
the ratio is *not* zero-sum: a good trade lifts both sides. The episode
ends `complete` after `turns` turns (default 12, max 24) or `deadline` when
the episode clock stops play between turns.

**The replay shows what nobody in the game can see.** Every transmission
draws SAID over HEARD, word for word, with garbled words burning red under
an optional WebAudio static crackle; the interference meter swells on
screen like weather; and when a deal settles on a mishearing the trade
ticket stamps both versions. The heard text is never stored — it is
re-derived from the seed by the same Nim module the server ran, so the
bytes carry the truth and the viewer computes the lie.

## Layout

- `src/garble.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/garble/wire.nim` — the channel, pure and auditable: normalisation, the
  lexicon, the seven-step scanner, the neighbour table, the delivery model,
  the redundancy shield
- `src/garble/sim.nim` — pure rules: seeded setup, tickets, confirms,
  settlement, airtime, scoring, endings, replay derivation; shared by
  server, tests, and the wasm viewer
- `src/garble/llm.nim` — Claude client (one parallel batch per turn) plus the
  `quoter` and `shark` scripted baselines
- `src/garble/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/garble_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — the inherited broadcast chrome (`chrome_common.js`,
  `chrome.css`) plus the Garble stage renderer and the global/player/replay
  pages
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `tools/ci/` — docker smoke, headless viewer smoke, release policy set
- `data/` — the five cog sprites and the arena floor
- `scripts/art/` — the nano-banana source sheet and the split script that
  produced `data/cog_*_front.png`
- `docs/plans/` — the design note this game was built from

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the
# paths are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_wire.nim            # the channel in isolation
nim r --path:src tests/test_sim.nim             # rules tests
nim r -d:release --path:src tests/test_bot.nim  # scripted-baseline tests
nim c -d:release -o:bin/garble src/garble.nim
nim c -d:release -o:bin/garble-player src/garble_player.nim
nim c --hints:off -d:emscripten replay-viewer/garble_replay.nim  # wasm viewer
# Export ANTHROPIC_API_KEY for real Claude play; omit it and every seat
# plays the scripted baselines with no network call at all.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put garble anthropic_api_key <keyfile>   # hosted Claude
```

## Fielding a policy

```bash
uv run coworld upload-policy <garble image> --name my-garble \
  --run /bin/garble-player \
  --secret-env PLAYER_PROMPT="Your Garble strategy here."
```

Or field a scripted baseline: same image,
`--env PLAYER_SCRIPTED=quoter` (the honest repeater) or
`--env PLAYER_SCRIPTED=shark` (the terse opportunist).
