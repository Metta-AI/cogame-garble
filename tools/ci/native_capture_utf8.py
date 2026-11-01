#!/usr/bin/env python3
"""Native player HTTP+WS malformed-response proofs; no full game or provider."""

import argparse
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from websockets.sync.server import serve


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("player", type=Path)
    parser.add_argument("reconstructor", type=Path)
    parser.add_argument("ordinary_run", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--case",
        choices=[
            "utf8",
            "usage-absent",
            "usage-null",
            "usage-scalar",
            "usage-invalidtokens",
            "json-vtab",
        ],
        default="utf8",
    )
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False, mode=0o700)
    rows = [
        json.loads(line)
        for line in (args.ordinary_run / "trajectory.jsonl").read_text().splitlines()
    ]
    view = next(
        row["observation"]["view"] for row in rows if row.get("decision_id") == "0-0"
    )
    action = {
        "channel": "RADIO",
        "text": "SELL 5 ORE AT 12",
        "notes": "",
        "confirm": None,
    }
    text = ("INVALID_UTF8_PREFIX\n" if args.case == "utf8" else "") + json.dumps(action)
    if args.case == "json-vtab":
        text = text.replace(",", ",\v", 1)
        try:
            json.loads(text)
        except json.JSONDecodeError:
            pass
        else:
            raise AssertionError("fixture must violate strict JSON whitespace")
    payload = {
        "model": "anthropic/claude-haiku-4.5",
        "content": [{"type": "text", "text": text}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 0, "output_tokens": 0},
    }
    if args.case == "usage-absent":
        del payload["usage"]
    elif args.case == "usage-null":
        payload["usage"] = None
    elif args.case == "usage-scalar":
        payload["usage"] = 7
    elif args.case == "usage-invalidtokens":
        payload["usage"] = {"input_tokens": "7", "output_tokens": -1}
    body = json.dumps(payload).encode()
    if args.case == "utf8":
        body = body.replace(b"INVALID_UTF8_PREFIX", b"\xff")
        assert b"\xff" in body
    call = str(
        uuid.uuid5(
            uuid.NAMESPACE_URL,
            "LOCAL-SYNTHETIC-GARBLE-COMPONENT-NOT-AUTHENTICATED:" + args.case,
        )
    )
    (out / "actual-response.bin").write_bytes(body)
    errors, emitted = [], []
    done = threading.Event()

    class Stub(BaseHTTPRequestHandler):
        def do_POST(self):
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            request = json.loads(raw)
            assert self.path == "/v1/messages"
            assert self.headers["X-Coworld-Player-Slot"] == "0"
            assert request["max_tokens"] == 900
            assert request["model"] == "anthropic/claude-haiku-4.5"
            (out / "actual-request.json").write_text(
                json.dumps(
                    {"body": request, "body_b64": base64.b64encode(raw).decode()},
                    indent=2,
                )
                + "\n"
            )
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Softmax-Llm-Call-Id", call)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    def handler(connection):
        try:
            assert connection.request.path == "/player?slot=0&token=local-only"
            connection.send(
                json.dumps(
                    {
                        "type": "welcome",
                        "protocol": "garble.player.v3",
                        "slot": 0,
                        "name": view["alias"],
                        "turns": 12,
                    }
                )
            )
            connection.send(
                json.dumps(
                    {
                        "type": "turn",
                        "turn": 0,
                        "timeout_ms": 25000,
                        "prompt_config": {
                            "promptVariant": "canonical",
                            "promptSeed": 0,
                        },
                        "private_capture": "garble.private-attempt.v1",
                        "view": view,
                    }
                )
            )
            wire = connection.recv(timeout=25)
            assert isinstance(wire, str)  # WS decoder has validated received UTF-8.
            frame = json.loads(wire)
            (out / "native-emitted-frame.json").write_text(
                json.dumps(frame, indent=2) + "\n"
            )
            (out / "native-emitted-frame.bin").write_bytes(wire.encode())
            assert frame["source"] == "player"
            if args.case == "json-vtab":
                # The unchanged native parser rejects this before an action is
                # emitted. Preserve its actual attempt-only frame, not a
                # fabricated decision carrying the intended object.
                assert frame["type"] == "private_attempt" and "action" not in frame
            else:
                assert frame["type"] == "decision" and frame["action"] == action
            attempt = frame["private_attempt"]["attempt"]
            assert (
                attempt["raw_response"] is None
            )  # Exact bytes restore this at the server.
            if args.case == "utf8":
                assert attempt["response"] is None
            else:
                assert attempt["response"] == text
                if args.case.startswith("usage-"):
                    assert (
                        attempt["input_tokens"] is None
                        and attempt["output_tokens"] is None
                    )
                else:
                    assert (
                        attempt["input_tokens"] == 0 and attempt["output_tokens"] == 0
                    )
            assert base64.b64decode(attempt["response_body_b64"]) == body
            if args.case == "utf8":
                assert "invalid UTF-8 model text" in attempt["rejection_reason"]
            emitted.append(frame)
            connection.send(json.dumps({"type": "final", "scores": [0, 0, 0, 0, 0]}))
        except BaseException:
            errors.append(traceback.format_exc())
        finally:
            done.set()

    base = {
        "HOME": str(Path.home()),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    }
    model = ThreadingHTTPServer(("127.0.0.1", free_port()), Stub)
    threading.Thread(target=model.serve_forever, daemon=True).start()
    with serve(handler, "127.0.0.1", free_port()) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = {
            **base,
            "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{server.socket.getsockname()[1]}/player?slot=0&token=local-only",
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{model.server_port}",
            "COWORLD_LLM_MODEL": "anthropic/claude-haiku-4.5",
        }
        (out / "env-keys.json").write_text(
            json.dumps(
                {
                    "player_keys": sorted(env),
                    "reconstructor_keys": sorted(base),
                    "whitelisted": True,
                    "provider_credentials_absent": True,
                },
                indent=2,
            )
            + "\n"
        )
        with (out / "player.log").open("x") as log:
            player = subprocess.Popen(
                [str(args.player.resolve())],
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            try:
                assert done.wait(30), "native protocol fixture timed out"
                assert not errors, errors
                assert player.wait(timeout=5) == 0
            finally:
                if player.poll() is None:
                    player.terminate()
                    player.wait(timeout=5)
        server.shutdown()
    model.shutdown()
    assert len(emitted) == 1
    with (
        (out / "server-capture-check.json").open("x") as proof,
        (out / "server-capture-check.log").open("x") as log,
    ):
        subprocess.run(
            [
                str(args.reconstructor.resolve()),
                str(args.ordinary_run.resolve()),
                str(out / "native-emitted-frame.json"),
                str(out / "truncated-capture.jsonl"),
            ],
            env=base,
            stdout=proof,
            stderr=log,
            timeout=15,
            check=True,
        )
    capture = [
        json.loads(line)
        for line in (out / "truncated-capture.jsonl").read_text().splitlines()
    ]
    assert capture[-1]["status"] == "truncated"
    row = next(row for row in capture[:-1] if row["seat"] == "0")
    attempt = row["attempts"][0]
    if args.case == "utf8":
        assert row["action_status"] == "rejected" and row["selected_attempt_id"] is None
        assert attempt["response"] is None and attempt["raw_response"] is None
        assert not attempt["accepted"]
    else:
        if args.case == "json-vtab":
            assert row["action_status"] == "fallback" and not attempt["accepted"]
            selected = next(
                item
                for item in row["attempts"]
                if item["attempt_id"] == row["selected_attempt_id"]
            )
            assert selected["origin"] == "fallback"
            assert attempt["rejection_reason"]
        else:
            assert row["action_status"] == "accepted" and attempt["accepted"]
            assert attempt["input_tokens"] is None and attempt["output_tokens"] is None
        assert attempt["response"] == text and attempt["raw_response"].encode() == body
    assert base64.b64decode(attempt["response_body_b64"]) == body
    (out / "proof.json").write_text(
        json.dumps(
            {
                "native_player_normal_exit": True,
                "actual_received_body_b64": base64.b64encode(body).decode(),
                "native_action_unchanged": args.case != "json-vtab",
                "native_parser_rejection_without_action": args.case == "json-vtab",
                "emitted_ws_valid_utf8": True,
                "native_text_or_explicit_gap_and_exact_bytes_retained": True,
                "case": args.case,
                "actual_server_capture_unselectable": args.case
                in {"utf8", "json-vtab"},
                "invalid_usage_unknown_without_changing_action": args.case.startswith(
                    "usage-"
                ),
                "full_game_invocations": 0,
                "synthetic_http_calls": 1,
                "authenticated_receipts": 0,
                "admitted_targets": 0,
                "no_live_provider": True,
            },
            indent=2,
        )
        + "\n"
    )
    print("Native HTTP+WS " + args.case + " authoritative capture proof PASS")


if __name__ == "__main__":
    main()
