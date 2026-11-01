#!/usr/bin/env python3
"""Bounded native HTTP/socket capture proof; synthetic loopback IDs are not receipts.

One complete game per invocation. Keep the output directory as failure evidence.
Ordinary mode preserves all clocks; other cases explicitly shorten presentation
pacing and deadlines to exercise failure paths without invoking any live provider.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "players/ordinary"))
from player import baseline_action  # noqa: E402
import websocket  # noqa: E402

BASE = {
    "HOME": str(Path.home()),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
    "LANG": "en_US.UTF-8",
    "LC_ALL": "en_US.UTF-8",
    "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
}


def port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def strict_object(text):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result

    def bad(value):
        raise ValueError("non-finite JSON: " + value)

    # Match the unchanged native brace extraction, retaining the original text.
    return json.loads(
        text[text.index("{") : text.rindex("}") + 1],
        object_pairs_hook=pairs,
        parse_constant=bad,
    )


def supplied_equal(raw, actual):
    if type(raw) is not type(actual):
        return False
    if isinstance(raw, dict):
        return all(k in actual and supplied_equal(v, actual[k]) for k, v in raw.items())
    if isinstance(raw, list):
        return len(raw) == len(actual) and all(
            supplied_equal(a, b) for a, b in zip(raw, actual)
        )
    return raw == actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--case",
        choices=[
            "ordinary",
            "positive",
            "normalization",
            "http429",
            "malformed",
            "timeout",
            "adversarial",
            "legacy",
            "large",
            "boundary",
        ],
        default="positive",
    )
    parser.add_argument("--capture-disabled", action="store_true")
    parser.add_argument("--expect-no-capture", action="store_true")
    parser.add_argument("--seed", type=int, default=11)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    assert Path(args.game).is_file() and Path(args.player).is_file()
    assert not any(
        k in BASE
        for k in (
            "ANTHROPIC_API_KEY",
            "COWORLD_LLM_ENDPOINT",
            "AWS_ACCESS_KEY_ID",
            "HTTP_PROXY",
        )
    )
    started = time.monotonic()
    limit = started + 180
    records, failures, processes, handles, public = [], [], [], [], []
    condition = threading.Condition()
    arrivals = {}
    native_count = (
        4 if args.case == "adversarial" else 1 if args.case == "legacy" else 5
    )

    class Stub(BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                body = json.loads(raw)
                assert self.path == "/v1/messages"
                assert body["model"] == "anthropic/claude-haiku-4.5"
                seat = int(self.headers["X-Coworld-Player-Slot"])
                view, _ = json.JSONDecoder().raw_decode(body["messages"][0]["content"])
                turn = view["turn"]
                assert "private_capture" not in body["messages"][0]["content"]
                with condition:
                    assert seat not in arrivals.setdefault(turn, set())
                    arrivals[turn].add(seat)
                    condition.notify_all()
                    assert condition.wait_for(
                        lambda: len(arrivals[turn]) == native_count, timeout=5
                    )
                action = baseline_action(view, False)
                if args.case == "normalization":
                    if seat == 0:
                        if turn == 0:
                            action["text"] = "  " + action["text"] + "\n  "
                        if turn == 1:
                            action["channel"] = view["alias"]
                        if turn == 2:
                            action["notes"] = "x" * 401
                        if turn == 3:
                            action["notes"] = ""
                        if turn == 4:
                            action["confirm"] = {
                                "ticket": "999",
                                "side": "buy",
                                "commodity": "ore",
                                "qty": "1",
                                "price": "1",
                            }
                        if turn == 5:
                            action["text"] = "word " * 40
                    if seat == 1:
                        action["text"] = "X" * 159
                    if seat == 4 and turn == 4:
                        action["confirm"] = {
                            "ticket": 999,
                            "side": "BUY",
                            "commodity": "ORE",
                            "qty": 1,
                            "price": 1,
                        }
                call = str(
                    uuid.uuid5(
                        uuid.NAMESPACE_URL,
                        f"LOCAL-SYNTHETIC-GARBLE-NOT-AUTHENTICATED:{turn}:{seat}",
                    )
                )
                if args.case == "boundary" and turn == 0 and seat == 0:
                    action["unknown_padding"] = ""
                    frame = {
                        "type": "decision",
                        "turn": turn,
                        "source": "player",
                        "action": action,
                    }
                    compact = json.dumps(
                        frame, ensure_ascii=False, separators=(",", ":")
                    )
                    action["unknown_padding"] = "x" * (65500 - len(compact.encode()))
                raw_action = json.dumps(action, ensure_ascii=False)
                if args.case == "normalization" and seat == 3:
                    if turn == 0:
                        raw_action = (
                            raw_action[:-1]
                            + ', "notes": "duplicate retained original"}'
                        )
                    if turn == 1:
                        raw_action = raw_action[:-1] + ', "unknown_nonfinite": NaN}'
                text = "```json\n" + raw_action + "\n```"
                if args.case == "large":
                    # A large original completion with native legal fields; padding
                    # stays outside the JSON object under the unchanged decoder.
                    # 900 Haiku tokens have no universal byte ceiling; this is an
                    # explicit 8KiB response-size stress, not a tokenizer claim.
                    text = ("analysis " * 850) + text
                payload = {
                    "model": body["model"],
                    "content": [{"type": "text", "text": text}],
                    "stop_reason": "end_turn",
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                }
                code = 200
                if turn == 0 and seat == 0:
                    if args.case == "http429":
                        code = 429
                        payload = {"error": "local synthetic rate limit"}
                    if args.case == "malformed":
                        payload["content"][0]["text"] = "not JSON"
                response = json.dumps(payload, ensure_ascii=False).encode()
                headers = {
                    "Content-Type": "application/json",
                    "Content-Length": str(len(response)),
                    "X-Softmax-Llm-Call-Id": call,
                    "request-id": "local-synthetic-" + call,
                }
                record = {
                    "slot": seat,
                    "turn": turn,
                    "request_body_b64": base64.b64encode(raw).decode(),
                    "request": body,
                    "response_body_b64": base64.b64encode(response).decode(),
                    "response_headers": headers,
                    "status": code,
                    "response_text": payload.get("content", [{}])[0].get("text"),
                    "action": action,
                    "synthetic_only": True,
                }
                with condition:
                    records.append(record)
                    (out / "sentinel-calls.json").write_text(
                        json.dumps(records, indent=2) + "\n"
                    )
                if args.case == "timeout" and turn == 0 and seat == 0:
                    time.sleep(10)
                self.send_response(code)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(response)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except BaseException as error:
                failures.append(repr(error))
                raise

        def log_message(self, *_args):
            pass

    model = ThreadingHTTPServer(("127.0.0.1", port()), Stub)
    threading.Thread(target=model.serve_forever, daemon=True).start()
    gameport = port()
    config = {
        "tokens": [f"local-token-{i}" for i in range(5)],
        "players": [{"name": f"Local native {i}"} for i in range(5)],
        "seed": args.seed,
        "turns": 12 if args.case == "ordinary" else 6,
    }
    if args.case != "ordinary":
        config.update(
            sampled=True,
            turnDelayMs=0,
            turnSpacingMs=0,
            actionTimeoutSeconds=8,
            player_connect_timeout_seconds=8,
        )
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    env = {
        **BASE,
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(gameport),
        "COGAME_CONFIG_URI": (out / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (out / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (out / "replay.json").as_uri(),
        "COWORLD_EPISODE_ID": "local-synthetic-garble-capture",
        "COWORLD_GAME_VERSION": "local-proof-only",
        "COWORLD_SOURCE_REVISION": "local-uncommitted-proof",
    }
    if not args.capture_disabled:
        env["COGAME_SAVE_TRAJECTORY_URI"] = (out / "trajectory.jsonl").as_uri()
    (out / "environment.json").write_text(
        json.dumps(
            {
                "game_env_keys": sorted(env),
                "player_base_env_keys": sorted(BASE),
                "credentials_inherited": False,
                "only_model_endpoint": "127.0.0.1",
                "case": args.case,
                "all_children_whitelisted": True,
            },
            indent=2,
        )
        + "\n"
    )

    sent_frames = []

    def custom_send(ws, payload):
        encoded = json.dumps(payload)
        sent_frames.append(
            {
                "frame_b64": base64.b64encode(encoded.encode()).decode(),
                "wire_bytes": len(encoded.encode()),
            }
        )
        (out / "custom-sent-frames.json").write_text(
            json.dumps(sent_frames, indent=2) + "\n"
        )
        ws.send(encoded)

    def custom_player():
        try:
            ws = websocket.create_connection(
                f"ws://127.0.0.1:{gameport}/player?slot=0&token=local-token-0",
                timeout=30,
                http_proxy_host=None,
            )
            while True:
                frame = json.loads(ws.recv())
                if frame["type"] == "final":
                    break
                if frame["type"] != "turn":
                    continue
                turn, view = frame["turn"], frame["view"]
                action = baseline_action(view, False)
                reply = {
                    "type": "decision",
                    "turn": turn,
                    "action": action,
                    "source": "player",
                    "seat": 4,
                }
                if args.case == "adversarial":
                    if turn == 0:
                        reply["private_attempt"] = {
                            "schema": "wrong-version",
                            "attempt": {"origin": "teacher"},
                        }
                    if turn == 1:
                        reply["private_attempt"] = {
                            "schema": "garble.private-attempt.v1",
                            "pad": "x" * 49153,
                        }
                    if turn == 2:
                        custom_send(
                            ws,
                            {
                                "type": "private_attempt",
                                "turn": turn,
                                "private_attempt": {"schema": "bad"},
                            },
                        )
                    if turn == 4:
                        custom_send(
                            ws,
                            {
                                **reply,
                                "turn": turn - 1,
                                "private_attempt": {"schema": "late"},
                            },
                        )
                    if turn == 5:
                        reply["private_attempt"] = {
                            "schema": "garble.private-attempt.v1",
                            "attempt": {"accepted": True, "seat": 4},
                        }
                custom_send(ws, reply)
                if args.case == "adversarial" and turn == 3:
                    custom_send(
                        ws, {**reply, "action": {"text": "DUPLICATE MUST NOT APPLY"}}
                    )
            ws.close()
        except BaseException as error:
            failures.append("custom player: " + repr(error))

    def spectator():
        try:
            ws = websocket.create_connection(
                f"ws://127.0.0.1:{gameport}/global", timeout=30, http_proxy_host=None
            )
            while True:
                frame = json.loads(ws.recv())
                public.append(frame)
                if frame.get("done"):
                    break
            ws.close()
        except BaseException as error:
            failures.append("spectator: " + repr(error))

    try:
        handle = (out / "game.log").open("x")
        handles.append(handle)
        game = subprocess.Popen(
            [str(args.game.resolve())],
            cwd=ROOT,
            env=env,
            stdout=handle,
            stderr=subprocess.STDOUT,
        )
        processes.append(game)
        for _ in range(100):
            assert game.poll() is None, "game ended before listen"
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", gameport)) == 0:
                    break
            time.sleep(0.05)
        else:
            raise AssertionError("game did not listen")
        observer = threading.Thread(target=spectator, daemon=True)
        observer.start()
        if args.case == "adversarial":
            threading.Thread(target=custom_player, daemon=True).start()
        for seat in range(5):
            if args.case == "adversarial" and seat == 0:
                continue
            playerenv = {
                **BASE,
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{gameport}/player?slot={seat}&token=local-token-{seat}",
                "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{model.server_port}",
                "COWORLD_LLM_MODEL": "anthropic/claude-haiku-4.5",
            }
            command = [str(args.player.resolve())]
            if args.case == "legacy":
                if seat == 0:
                    command = [sys.executable, str(ROOT / "players/ordinary/player.py")]
                    playerenv.update(
                        POC_CAPTURE_TRAINING="1",
                        POC_SOURCE_REVISION="local-fixture",
                        COWORLD_PLAYER_ARTIFACT_UPLOAD_URL=(
                            out / "ordinary-v1-artifact.zip"
                        ).as_uri(),
                    )
                elif seat >= 2:
                    playerenv["PLAYER_SCRIPTED"] = "shark" if seat == 3 else "quoter"
            handle = (out / f"player-{seat}.log").open("x")
            handles.append(handle)
            processes.append(
                subprocess.Popen(
                    command,
                    cwd=ROOT,
                    env=playerenv,
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                )
            )
        assert game.wait(timeout=max(1, limit - time.monotonic())) == 0
        for process in processes[1:]:
            assert process.wait(timeout=max(1, min(5, limit - time.monotonic()))) == 0
        observer.join(timeout=2)
        assert not failures, failures
        results = json.loads((out / "results.json").read_text())
        replay = json.loads((out / "replay.json").read_text())
        says = [event for event in replay["events"] if event["kind"] == "say"]
        assert results["reason"] == "complete" and len(says) == config["turns"] * 5
        assert len(records) == config["turns"] * native_count
        assert all(len(seats) == native_count for seats in arrivals.values())
        serialized = json.dumps([replay, public])
        assert (
            "private_attempt" not in serialized
            and "platform_call_id" not in serialized
            and "telemetry_frames" not in serialized
        )
        for record in records:
            assert record["response_headers"]["X-Softmax-Llm-Call-Id"] not in serialized
            assert record["request"]["system"] not in serialized
        counts = {
            "decisions": 0,
            "attempts": 0,
            "strict_equal": 0,
            "normalization_excluded": 0,
            "fallback": 0,
            "invalid_telemetry": 0,
            "source_accepted_model_actions": 0,
        }
        if not args.capture_disabled and not args.expect_no_capture:
            rows = [
                json.loads(line)
                for line in (out / "trajectory.jsonl").read_text().splitlines()
            ]
            assert (
                rows[-1]["event_type"] == "episode"
                and rows[-1]["status"] == "completed"
            )
            assert (out / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
            by_call = {
                r["response_headers"]["X-Softmax-Llm-Call-Id"]: r for r in records
            }
            for row in rows[:-1]:
                counts["decisions"] += 1
                counts["fallback"] += row["action_status"] == "fallback"
                for frame in row["observation"]["telemetry_frames"]:
                    counts["invalid_telemetry"] += (
                        frame.get("telemetry_error") is not None
                    )
                    if frame.get("request_body_b64"):
                        call = next(
                            (
                                a["platform_call_id"]
                                for a in row["attempts"]
                                if a["attempt_id"].endswith(
                                    "-"
                                    + str(
                                        row["observation"]["telemetry_frames"].index(
                                            frame
                                        )
                                    )
                                )
                            ),
                            None,
                        )
                        if call:
                            assert (
                                frame["request_body_b64"]
                                == by_call[call]["request_body_b64"]
                            )
                for attempt in row["attempts"]:
                    assert attempt["origin"] != "teacher"
                    if attempt["origin"] == "fallback":
                        continue
                    counts["attempts"] += 1
                    call = attempt["platform_call_id"]
                    if call is not None:
                        recorded = by_call[call]
                        assert (
                            attempt["response_body_b64"]
                            == recorded["response_body_b64"]
                        )
                        assert attempt["request"] == recorded["request"]
                        assert attempt["raw_response"].encode() == base64.b64decode(
                            recorded["response_body_b64"]
                        )
                        assert str(recorded["slot"]) == row["seat"]
                        assert recorded["turn"] == int(row["decision_id"].split("-")[0])
                        for key, value in recorded["response_headers"].items():
                            actual_headers = {
                                k.lower(): v
                                for k, v in attempt["response_headers"].items()
                            }
                            assert actual_headers[key.lower()] == value
                    if attempt["response"] is not None:
                        try:
                            raw = strict_object(attempt["response"])
                        except ValueError:
                            assert not attempt["accepted"], (
                                "invalid raw JSON was source-selected"
                            )
                            counts["normalization_excluded"] += 1
                            continue
                        equal = supplied_equal(raw, row["executed_action"])
                        if attempt["accepted"]:
                            assert equal, (
                                "source accepted a normalized/type-coerced/unknown-field target"
                            )
                            counts["source_accepted_model_actions"] += 1
                        if equal:
                            counts["strict_equal"] += 1
                        else:
                            assert not attempt["accepted"], (
                                "source accepted unequal raw supplied fields"
                            )
                            counts["normalization_excluded"] += 1
            assert counts["decisions"] == config["turns"] * 5
            if args.case == "normalization":
                assert counts["normalization_excluded"] >= 6
                void_row = next(r for r in rows[:-1] if r["decision_id"] == "4-4")
                assert void_row["executed_action"]["confirm"] == {
                    "ticket": 999,
                    "side": "BUY",
                    "commodity": "ORE",
                    "qty": 1,
                    "price": 1,
                }
                assert any(
                    e["kind"] == "void" and e["reason"] == "no-ticket"
                    for e in void_row["observation"]["native_events"]
                )
                assert void_row["action_status"] == "accepted", (
                    "legal void was filtered by outcome"
                )
            if args.case in ("http429", "malformed", "timeout"):
                assert counts["fallback"] == 1
            if args.case == "adversarial":
                assert counts["invalid_telemetry"] >= 5
                assert counts["fallback"] == 0
                assert all(e["text"] != "DUPLICATE MUST NOT APPLY" for e in says)
            if args.case == "boundary":
                assert counts["fallback"] == 0
                assert (
                    counts["source_accepted_model_actions"] == config["turns"] * 5 - 1
                )
                assert "telemetry omitted" in (out / "player-0.log").read_text()
                boundary_row = next(r for r in rows[:-1] if r["decision_id"] == "0-0")
                assert boundary_row["action_status"] == "rejected"
                assert boundary_row["observation"]["telemetry_frames"][0][
                    "proposal_gap"
                ]
            if args.case == "large":
                assert counts["source_accepted_model_actions"] == config["turns"] * 5
                assert (
                    min(len(base64.b64decode(r["response_body_b64"])) for r in records)
                    >= 7500
                )
        else:
            assert not (out / "trajectory.jsonl").exists()
        summary = {
            "case": args.case,
            "completed_native_games": 1,
            "turns": config["turns"],
            "native_says": len(says),
            "loopback_http_calls": len(records),
            "simultaneous_all_native_seats_each_turn": True,
            "elapsed_seconds": time.monotonic() - started,
            "wall_bound_seconds": 180,
            "ordinary_clocks": args.case == "ordinary",
            "capture_disabled": args.capture_disabled,
            "counts": counts,
            "public_privacy_pass": True,
            "synthetic_only": True,
            "authenticated_receipts": 0,
            "admitted_training_targets": 0,
            "results": results,
            "binary_sha256": {
                "game": hashlib.sha256(args.game.read_bytes()).hexdigest(),
                "player": hashlib.sha256(args.player.read_bytes()).hexdigest(),
            },
            "working_source_files_sha256": {
                str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (
                    ROOT / "src/garble/llm.nim",
                    ROOT / "src/garble/server.nim",
                    ROOT / "src/garble_player.nim",
                )
            },
        }
        (out / "proof.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
    except BaseException as error:
        (out / "failure.json").write_text(
            json.dumps(
                {
                    "error": repr(error),
                    "elapsed_seconds": time.monotonic() - started,
                    "evidence_preserved": True,
                    "fixture_errors": failures,
                },
                indent=2,
            )
            + "\n"
        )
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for handle in handles:
            handle.close()
        model.shutdown()


if __name__ == "__main__":
    main()
