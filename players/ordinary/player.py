"""Garble decisions through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture

COMMODITIES = ("ORE", "OAT", "TIN", "TAR")


def baseline_action(view: dict, shark: bool) -> dict:
    surplus = view["surplus"]
    demand = view["demand"]
    units = view["units"]
    prices = view["prices"]
    repeat = not shark and view["interference"] >= 0.5
    text = ""
    if view["airtime"] >= 30:
        if units[surplus] >= 3:
            fields = ("SELL", min(5, units[surplus]), COMMODITIES[surplus],
                      min(99, prices[surplus] + 3))
        elif units[demand] < view["quota"]:
            fields = ("BUY", min(5, view["quota"] - units[demand]),
                      COMMODITIES[demand], min(99, prices[demand] + 1))
        else:
            fields = None
        if fields:
            verb, qty, commodity, price = fields
            text = " ".join([verb, str(qty), *([str(qty)] if repeat else []),
                             commodity, *([commodity] if repeat else []),
                             "AT", str(price), *([str(price)] if repeat else [])])
    confirm = None
    for ticket in view["tickets"]:
        heard = ticket["heard"]
        if heard is None:
            continue
        commodity = heard["commodity"]
        price = heard["price"]
        if heard["side"] == "SELL":
            if (commodity != demand or units[commodity] >= view["quota"]
                    or price > prices[demand] + view["premium"] - 1
                    or (price > 0 and view["cash"] < price)):
                continue
        elif (commodity != surplus or price < prices[surplus] + 1
              or units[commodity] <= 0):
            continue
        qty = heard["qty"]
        if shark:
            buying = heard["side"] == "SELL"
            quantities = [qty, *(v for v in heard["qty_neighbors"] if v >= 1)]
            prices_possible = [price, *(v for v in heard["price_neighbors"] if v >= 0)]
            qty = max(quantities) if buying else min(quantities)
            price = min(prices_possible) if buying else max(prices_possible)
        confirm = {"ticket": ticket["id"], "side": heard["side"],
                   "commodity": COMMODITIES[commodity], "qty": min(99, qty),
                   "price": min(99, price)}
        break
    return {"channel": "RADIO", "text": text, "notes": "", "confirm": confirm}


def choose(turn: dict, generator) -> tuple[dict, str]:
    rules_file = Path(os.environ.get("GARBLE_RULES_FILE",
                          Path(__file__).resolve().parents[2] / "docs" / "rules.md"))
    turn["system"] = "Play Garble. Submit one complete decision as JSON.\n\n" + rules_file.read_text()
    turn["user"] = json.dumps(turn["view"], separators=(",", ":"),
                              ensure_ascii=False) + "\n" + \
        os.environ.get("PLAYER_PROMPT", "")
    if generator:
        completion = generator([
            {"role": "system", "content": turn["system"]},
            {"role": "user", "content": turn["user"]},
        ])
        action = json.loads(completion)
        if not isinstance(action, dict):
            raise ValueError("trained Garble decision must be a JSON object")
        return action, "trained"
    return baseline_action(turn["view"], False), "canned"


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("POC_ADAPTER_DIR")
    generator = None
    if adapter:
        from pathlib import Path

        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    backend = "trained" if adapter else "canned"
    artifact = Capture(slot, backend) if os.environ.get("POC_CAPTURE_TRAINING") == "1" else None
    socket = websocket.create_connection(url, timeout=60)
    socket.settimeout(None)
    pending: dict[int, tuple[dict, dict, str]] = {}
    while True:
        opcode, data = socket.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise RuntimeError("Garble closed before the final frame")
        if opcode != websocket.ABNF.OPCODE_TEXT:
            continue
        frame = json.loads(data)
        kind = frame["type"]
        if kind == "turn":
            action, source = choose(frame, generator)
            pending[frame["turn"]] = (frame, action, source)
            socket.send(json.dumps({"type": "decision", "turn": frame["turn"],
                                    "source": "player", "action": action}))
        elif kind == "decision_result":
            turn, action, source = pending.pop(frame["turn"])
            if artifact and frame["accepted"]:
                artifact.record(turn["system"], turn["user"], action, source,
                                frame["turn"])
        elif kind == "final":
            if pending:
                raise RuntimeError("Garble ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["scores"])
            break
    socket.close()
    print(f"Garble ordinary player finished: slot={slot} backend={backend}",
          flush=True)


if __name__ == "__main__":
    main()
