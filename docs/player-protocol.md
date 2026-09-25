# Garble player protocol v3

Connect to `COWORLD_PLAYER_WS_URL` with the assigned slot and token. All frames are JSON text.

The game sends `welcome` with the seat's anonymous alias, then redacted `state` frames after events. Each turn it sends:

```json
{"type":"turn","turn":0,"timeout_ms":25000,"view":{"alias":"Sprocket","prices":[10,11,12,13],"tickets":[]}}
```

`view` is the ordinary seat observation. It contains the seat's alias, turn, prices, forecast, private holdings and contract, cash, airtime, notes, public settled deals, and only the traffic this seat heard. `tickets` contains every confirmable ticket with this listener's heard text. `heard` is null when the text does not parse; otherwise it includes parsed terms and possible near-neighbour values. It never contains another seat's private holdings, contract, notes, or ungarbled transmission.

Every player sends one complete action before `timeout_ms` expires:

```json
{"type":"decision","turn":0,"source":"player","action":{"channel":"RADIO","text":"SELL 5 ORE AT 12","notes":"","confirm":null}}
```

`channel` is `RADIO` or another seat's alias. `confirm` is null or an object with `ticket`, `side` (`SELL` or `BUY`), `commodity` (`ORE`, `OAT`, `TIN`, `TAR`), `qty`, and `price`. The game validates actions, applies all transmissions in seat order, then applies all confirms in seat order. Only the first valid frame for the pending turn is considered. Invalid or missing actions use the game-owned quoter fallback.

`source` is `player`, `scripted`, or `fallback`; it annotates replay decisions. After the turn, the game sends `decision_result` with `accepted`. A legal confirm that later voids is still accepted. The game ends with `final` scores and portfolio values.
