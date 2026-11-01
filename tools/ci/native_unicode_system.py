"""Partial real native HTTP/v3-WS/game/private-writer proof; synthetic localhost only."""

import argparse
import base64
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import UUID, uuid4

from native_capture_smoke import BASE, ROOT, baseline_action, port


def scalar_json(value):
    if isinstance(value, str):
        value.encode("utf8")
    elif isinstance(value, dict):
        for key, item in value.items():
            scalar_json(key)
            scalar_json(item)
    elif isinstance(value, list):
        for item in value:
            scalar_json(item)


def verify_forensics(rows, records):
    wire = {call["call_id"]: call for call in records}
    joined = set()
    for row in rows[:-1]:
        observation = row["observation"]
        if "invalid_native_evidence_json_b64" in observation:
            original = json.loads(
                base64.b64decode(
                    observation["invalid_native_evidence_json_b64"], validate=True
                ).decode("utf8", errors="surrogateescape")
            )
            attempts = original["attempts"]
            for frame in original["observation"]["telemetry_frames"]:
                packet = frame.get("invalid_private_envelope", {})
                if "invalid_native_evidence_json_b64" in packet:
                    caller = json.loads(
                        base64.b64decode(
                            packet["invalid_native_evidence_json_b64"], validate=True
                        ).decode("utf8", errors="surrogateescape")
                    )
                    attempt = caller["attempt"]
                    call = wire[attempt["platform_call_id"]]
                    assert caller["request_body_b64"] == call["request_b64"]
                    attempts.append(attempt)
            if row["decision_id"] == "0-0":
                call = next(
                    call for call in records if (call["turn"], call["seat"]) == (0, 0)
                )
                assert original["executed_action"] == json.loads(
                    base64.b64decode(call["raw_action_json_b64"])
                )
                assert not original["actual_scripted"]
        else:
            attempts = row["attempts"]
        for attempt in attempts:
            identity = attempt.get("platform_call_id")
            if identity is not None:
                UUID(identity)
                assert attempt["response_body_b64"] == wire[identity]["response_b64"]
                joined.add(identity)
    assert joined == set(wire), "missing original HTTP evidence is a gap"


def main():
    allowed = {
        k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ
    }
    if set(os.environ) - set(allowed) - {"LC_CTYPE", "__CF_USER_TEXT_ENCODING"}:
        os.execve(sys.executable, [sys.executable, *sys.argv], allowed)
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--expect", choices=("original", "guarded"), default="guarded")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    records, errors = [], []
    started = time.monotonic()

    class Sentinel(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def do_POST(self):
            try:
                assert self.path == "/v1/messages"
                body = self.rfile.read(int(self.headers["Content-Length"]))
                request = json.loads(body.decode("utf8", errors="surrogateescape"))
                assert (
                    request["model"] == "anthropic/claude-haiku-4.5"
                    and request["max_tokens"] == 900
                )
                view, _ = json.JSONDecoder().raw_decode(
                    request["messages"][0]["content"]
                )
                turn, seat = view["turn"], int(self.headers["X-Coworld-Player-Slot"])
                assert 0 <= turn < 3 and 0 <= seat < 5
                action = baseline_action(view, False)
                action["notes"] = "safe"
                invalid = None
                if turn == 0:
                    if seat == 1:
                        action["notes"] = "café"
                    elif seat == 2:
                        action["notes"] = "😀"
                    elif seat == 3:
                        action["notes"] = "\udc00"
                    elif seat == 4:
                        action["\udc00"] = 1
                elif turn == 1:
                    invalid = {0: b"\x80", 1: b"\xf4\x90\x80\x80", 2: b"\xc0\x80"}.get(
                        seat
                    )
                    if seat == 3:
                        action["notes"] = "clear"
                    elif seat == 4:
                        action["notes"] = "\ud800"
                else:
                    action["notes"] = "clear"
                    invalid = {3: b"\xe2\x28\xa1", 4: b"\xe2\x82"}.get(seat)
                if invalid is not None:
                    action["notes"] = "INVALID_BYTES"
                text = json.dumps(action, ensure_ascii=True)
                payload = {
                    "model": "bad\udc00"
                    if (turn, seat) == (0, 0)
                    else request["model"],
                    "content": [{"type": "text", "text": text}],
                    "stop_reason": "end_turn",
                    "usage": {"input_tokens": 1, "output_tokens": 1},
                }
                response = json.dumps(payload).encode()
                if invalid is not None:
                    response = response.replace(b"INVALID_BYTES", invalid)
                call = {
                    "turn": turn,
                    "seat": seat,
                    "call_id": str(uuid4()),
                    "request_b64": base64.b64encode(body).decode(),
                    "response_b64": base64.b64encode(response).decode(),
                    "raw_action_json_b64": base64.b64encode(text.encode()).decode(),
                    "elapsed_seconds": time.monotonic() - started,
                }
                records.append(call)
                assert len(records) <= 20
                with (out / "wire.jsonl").open("a") as stream:
                    stream.write(json.dumps(call) + "\n")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.send_header("X-Softmax-Llm-Call-Id", call["call_id"])
                if (turn, seat) == (0, 0):
                    self.send_header("X-Local-Invalid", "\x80")
                self.end_headers()
                self.wfile.write(response)
            except BaseException as error:
                errors.append(repr(error))
                raise

    server = ThreadingHTTPServer(("127.0.0.1", 0), Sentinel)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    gameport = port()
    config = {
        "tokens": [f"local-{s}" for s in range(5)],
        "players": [{"name": f"Local native {s}"} for s in range(5)],
        "seed": 11,
        "turns": 12,
        "episodeTimeoutSeconds": 40,
    }
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    game_env = BASE | {
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(gameport),
        "COGAME_CONFIG_URI": (out / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (out / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (out / "replay.json").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": (out / "trajectory.jsonl").as_uri(),
        "COWORLD_EPISODE_ID": "local-garble-unicode-partial",
        "COWORLD_GAME_VERSION": "local-component",
        "COWORLD_SOURCE_REVISION": "local-working-tree-see-source-hashes",
    }
    audits = {
        "parent_keys": sorted(os.environ),
        "game_keys": sorted(game_env),
        "player_keys": [],
    }
    processes, handles = [], []
    (out / "env-key-audit.json").write_text(json.dumps(audits, indent=2) + "\n")
    try:
        handle = (out / "game.log").open("w")
        handles.append(handle)
        game = subprocess.Popen(
            [str(args.game.resolve())],
            cwd=ROOT,
            env=game_env,
            stdout=handle,
            stderr=subprocess.STDOUT,
        )
        processes.append(game)
        import socket

        for _ in range(100):
            assert game.poll() is None, "game exited before listen"
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", gameport)) == 0:
                    break
            time.sleep(0.05)
        else:
            raise AssertionError("game did not listen")
        for seat in range(5):
            env = BASE | {
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{gameport}/player?slot={seat}&token=local-{seat}",
                "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
                "COWORLD_LLM_MODEL": "anthropic/claude-haiku-4.5",
            }
            audits["player_keys"].append(sorted(env))
            (out / "env-key-audit.json").write_text(json.dumps(audits, indent=2) + "\n")
            handle = (out / f"player-{seat}.log").open("w")
            handles.append(handle)
            processes.append(
                subprocess.Popen(
                    [str(args.player.resolve())],
                    cwd=ROOT,
                    env=env,
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                )
            )
        (out / "env-key-audit.json").write_text(json.dumps(audits, indent=2) + "\n")
        while any(process.poll() is None for process in processes):
            size = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
            assert time.monotonic() - started < 60 and size < 8 * 1024**2
            import shutil

            assert shutil.disk_usage(out).free >= 2 * 1024**3
            with (out / "metrics.jsonl").open("a") as stream:
                stream.write(
                    json.dumps(
                        {
                            "elapsed_seconds": time.monotonic() - started,
                            "http_calls": len(records),
                            "artifact_bytes": size,
                        }
                    )
                    + "\n"
                )
            time.sleep(0.1)
        assert all(process.returncode == 0 for process in processes) and not errors
        result = json.loads(
            (out / "results.json").read_bytes().decode("utf8", errors="surrogateescape")
        )
        assert result["reason"] == "deadline"
        replay_raw = (out / "replay.json").read_bytes()
        replay = json.loads(replay_raw.decode("utf8", errors="surrogateescape"))
        raw = (out / "trajectory.jsonl").read_bytes()
        try:
            rows = [json.loads(line) for line in raw.decode("utf8").splitlines()]
            scalar_json(rows)
            scalar = True
        except (UnicodeError, json.JSONDecodeError):
            scalar = False
        if args.expect == "original":
            assert not scalar, (
                "original source did not reproduce unsafe private serialization"
            )
        else:
            assert scalar
            assert rows[-1]["status"] == "failed"
            decisions = [row for row in rows if row["event_type"] == "decision"]
            assert len(decisions) == 15
            forensic = [
                row
                for row in decisions
                if "invalid_native_evidence_json_b64" in row["observation"]
            ]
            assert forensic
            verify_forensics(rows, records)
            for row in forensic:
                assert (
                    row["selected_attempt_id"] is None
                    and row["executed_action"] is None
                    and row["attempts"] == []
                )
                assert row["action_status"] in ("rejected", "fallback")
            for seat, text in (("1", "café"), ("2", "😀")):
                row = next(
                    row for row in decisions if row["decision_id"] == "0-" + seat
                )
                assert (
                    row["action_status"] == "accepted"
                    and row["executed_action"]["notes"] == text
                )
        card = {
            "expected": args.expect,
            "partial": True,
            "configured_turns": 12,
            "native_reason": result["reason"],
            "native_turn_events": sum(e["kind"] == "turn" for e in replay["events"]),
            "fixture_http_calls": len(records),
            "strict_scalar_private_json": scalar,
            "public_bytes_untouched_permissive_inspection_only": True,
            "full_games": 0,
            "provider_calls": 0,
            "synthetic_usage_not_provider_tokens": True,
            "seconds": time.monotonic() - started,
        }
        (out / "proof.json").write_text(json.dumps(card, indent=2) + "\n")
        print(json.dumps(card))
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        for handle in handles:
            handle.close()
        server.shutdown()


if __name__ == "__main__":
    main()
