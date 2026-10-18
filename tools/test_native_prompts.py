"""Published Garble episodes with real players and a closed inference endpoint."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from pathlib import Path


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    cases = [(name, "canonical") for name in variants]
    cases += [
        ("standard", wording)
        for wording in (
            "plain",
            "numbered",
            "questions",
            "reordered",
            "heldout-briefing",
            "heldout-reference",
            "mixed",
        )
    ]
    if args.smoke:
        cases = [("standard", "canonical"), ("storm", "canonical")]
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for variant, wording in cases:
        work = args.output / f"{variant}-{wording}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        seats = config["num_agents"]
        config.update(
            seed=7,
            promptVariant=wording,
            promptSeed=4,
            tokens=[f"t{seat}" for seat in range(seats)],
            players=[{"name": f"policy-{seat}"} for seat in range(seats)],
        )
        (work / "config.json").write_text(json.dumps(config))
        closed_endpoint = socket.socket()
        closed_endpoint.bind(("127.0.0.1", 0))
        closed_port = closed_endpoint.getsockname()[1]
        port = free_port()
        env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_BEARER_TOKEN_BEDROCK",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "PLAYER_SCRIPTED",
        ):
            env.pop(key, None)
        env.update(
            COGAME_HOST="127.0.0.1",
            COGAME_PORT=str(port),
            COGAME_CONFIG_URI=(work / "config.json").as_uri(),
            COGAME_RESULTS_URI=(work / "results.json").as_uri(),
            COGAME_SAVE_REPLAY_URI=(work / "episode.replay").as_uri(),
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_port}",
            GARBLE_EXECUTION_TRACE_DIR=str(work / "execution"),
            GARBLE_ATTEMPT_TRACE_DIR=str(work / "attempts"),
            GARBLE_SOURCE_REVISION="uncommitted-garble-validation",
        )
        processes, logs = [], []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen(
                [str(args.game)],
                cwd=root,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            processes.append(game)
            for _ in range(200):
                assert game.poll() is None, work
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"host did not start: {work}")
            for seat in range(seats):
                player_env = dict(
                    env,
                    COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    PLAYER_PROMPT=(
                        f"PRIVATE-STRATEGY-{seat}: Cooperate using only the information available to your role."
                    ),
                )
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen(
                        [str(args.player)],
                        cwd=root,
                        env=player_env,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                )
            assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
            for player in processes[1:]:
                assert player.wait(timeout=15) == 0
            results = json.loads((work / "results.json").read_text())
            replay = json.loads((work / "episode.replay").read_text())
            assert results["reason"] == "complete", results
            turns = config["turns"]
            records = [json.loads(line) for line in (work / "execution/execution.jsonl").read_text().splitlines()]
            assert len(records) == turns
            attempts = list((work / "attempts").glob("*.jsonl"))
            assert len(attempts) == turns * seats
            starts = {}
            for path in attempts:
                assert path.stat().st_mode & 0o777 == 0o600
                start, finish = [json.loads(line) for line in path.read_text().splitlines()]
                assert start["attempt_id"] == finish["attempt_id"]
                assert not finish["completed"] and finish["phase"] == "request"
                assert finish["raw_response"] is None and finish["parsed_action"] is None
                assert finish["platform_call_id"] is None and finish["behavior_logprobs"] is None
                starts[start["attempt_id"]] = start
                system, user = (message["content"] for message in start["prompt"])
                seat = start["seat"]
                assert f"PRIVATE-STRATEGY-{seat}" in user
                assert all(f"PRIVATE-STRATEGY-{other}" not in user for other in range(seats) if other != seat)
                body = start["request"]["body"]
                assert body["system"] == system and body["messages"] == start["prompt"][1:]
                assert start["request"]["model"] == body["model"]
                metadata = start["prompt_template"]
                assert metadata["variant"] == ("reordered" if wording == "mixed" else wording)
                for role, text in (("system", system), ("user", user)):
                    assert metadata[f"{role}_sha256"].lower() == hashlib.sha256(text.encode()).hexdigest()
            for index, row in enumerate(records):
                assert row["turn"] == index and row["proposals"] == []
                assert len(row["actions"]) == seats
                for seat, action in enumerate(row["actions"]):
                    assert action["seat"] == seat and not action["accepted"] and action["scripted"]
                    assert action["parsed_action"] == action["executed_action"]
                    start = starts[f"{index}-{seat}"]
                    view, _ = json.JSONDecoder().raw_decode(start["prompt"][1]["content"])
                    assert view == action["private_view"]
                    events = [event for event in row["events"] if event["kind"] == "say" and event["seat"] == seat]
                    assert len(events) == 1 and events[0]["scripted"]
                    assert events[0]["text"] == action["executed_action"]["text"]
                assert all(event in replay["events"] for event in row["events"])
            public = (work / "episode.replay").read_text()
            assert "PRIVATE-STRATEGY-" not in public and "prompt_selection" not in public
            assert (work / "execution/execution.jsonl").stat().st_mode & 0o777 == 0o600
            print(
                work.name,
                turns,
                "turns;",
                turns * seats,
                "actual failed attempts and installed fallbacks; five real players PASS",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()
            closed_endpoint.close()


if __name__ == "__main__":
    main()
