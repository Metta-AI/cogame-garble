"""Garble decisions through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import math
import os
import urllib.request
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


def choose(turn: dict, generator, slot: int) -> tuple[dict, str]:
    rules_file = Path(os.environ.get("GARBLE_RULES_FILE",
                          Path(__file__).resolve().parents[2] / "docs" / "rules.md"))
    turn["system"] = "Play Garble. Submit one complete decision as JSON.\n\n" + rules_file.read_text()
    turn["user"] = json.dumps(turn["view"], separators=(",", ":"),
                              ensure_ascii=False) + "\n" + \
        os.environ.get("PLAYER_PROMPT", "")
    candidates = [{"id": name, "action": baseline_action(turn["view"], shark)}
                  for name, shark in (("quoter", False), ("shark", True))]
    if generator:
        completion = generator([
            {"role": "system", "content": turn["system"]},
            {"role": "user", "content": turn["user"]},
        ])
        action = json.loads(completion)
        if not isinstance(action, dict):
            raise ValueError("trained Garble decision must be a JSON object")
        return action, "trained"
    if os.environ.get("POC_JEV") != "1":
        return candidates[0]["action"], "canned"
    sidecar = os.environ.get("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "").strip()
    capture = os.environ.get("METTA_CAPTURE_URL", "").strip()
    if sidecar:
        endpoint, model, key = sidecar, "typesafe/jev-1.13", ""
    elif capture:
        endpoint = capture
        model = os.environ.get("METTA_CAPTURE_MODEL", "jev-latest")
        key = os.environ["METTA_CAPTURE_KEY"]
    else:
        endpoint = os.environ.get("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
        model = os.environ.get("TYPESAFE_DEFAULT_MODEL", "jev-latest")
        key = os.environ["TYPESAFE_API_KEY"]
    criteria = {str(index): json.dumps(candidate["action"], sort_keys=True)
                for index, candidate in enumerate(candidates)}
    body = json.dumps({
        "model": model,
        "state": {"policy": turn["system"], "summary": turn["user"]},
        "questions": {"action": {"type": "choice",
                                 "instructions": "Choose one complete Garble decision.",
                                 "criteria": criteria}},
    }).encode()
    headers = {"Content-Type": "application/json",
               "X-Coworld-Player-Slot": str(slot)}
    if key:
        headers["Authorization"] = "Bearer " + key
    request = urllib.request.Request(endpoint.rstrip("/") + "/v1/systemone",
                                     body, headers, method="POST")
    with urllib.request.urlopen(request, timeout=10) as response:
        answer = json.load(response)["answers"]["action"]
    if answer["type"] != "choice" or len(answer["probabilities"]) != len(candidates):
        raise ValueError("Jev returned the wrong Garble decision catalog")
    probabilities = [answer["probabilities"][str(i)] for i in range(len(candidates))]
    if (any(not isinstance(p, (int, float)) or not math.isfinite(p) or p < 0 or p > 1
            for p in probabilities)
            or abs(sum(probabilities) - 1) > len(candidates) * 0.005 + 1e-6):
        raise ValueError("Jev returned invalid Garble decision probabilities")
    return candidates[max(range(len(candidates)), key=probabilities.__getitem__)]["action"], "jev"


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("POC_ADAPTER_DIR")
    if adapter and os.environ.get("POC_JEV") == "1":
        raise ValueError("select one Garble policy backend")
    generator = None
    if adapter:
        from pathlib import Path

        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    backend = "trained" if adapter else "jev" if os.environ.get("POC_JEV") == "1" else "canned"
    artifact = Capture(slot, backend) if os.environ.get("POC_CAPTURE_TRAINING") == "1" else None
    socket = websocket.create_connection(url, timeout=60)
    socket.settimeout(None)
    calls = 0
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
            action, source = choose(frame, generator, slot)
            if source == "jev":
                calls += 1
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
    print(f"Garble ordinary player finished: slot={slot} backend={backend} Jev calls={calls}",
          flush=True)


if __name__ == "__main__":
    main()
