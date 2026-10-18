"""Published Garble episodes with real players and a closed inference endpoint."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import zipfile
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
    wordings = ("canonical", "plain", "numbered", "questions", "reordered")
    cases = [("standard", wordings[index % 5], index + 1) for index in range(10)]
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for variant, wording, seed in cases:
        work = args.output / f"{variant}-{wording}-{seed}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        seats = config["num_agents"]
        config.update(
            seed=seed,
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
                player_env.update(
                    POC_CAPTURE_TRAINING="1",
                    POC_SOURCE_REVISION="uncommitted-garble-validation",
                    COWORLD_PLAYER_ARTIFACT_UPLOAD_URL=(work / f"policy_artifact_{seat}.zip").as_uri(),
                )
                processes.append(
                    subprocess.Popen(
                        [sys.executable, str(root / "players/ordinary/player.py")],
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
            assert results["reason"] == "complete", results
            records = [json.loads(line) for line in (work / "execution/execution.jsonl").read_text().splitlines()]
            assert len(records) == config["turns"]
            replay = json.loads((work / "episode.replay").read_text())
            for seat in range(seats):
                artifact = work / f"policy_artifact_{seat}.zip"
                assert artifact.stat().st_mode & 0o777 == 0o600
                with zipfile.ZipFile(artifact) as archive:
                    trajectory = json.loads(archive.read("trajectory.json"))
                assert trajectory["schema_version"] == 2 and trajectory["complete"]
                assert trajectory["scores"] == results["scores"]
                assert len(trajectory["decisions"]) == config["turns"]
                for turn, row in enumerate(trajectory["decisions"]):
                    assert row["turn"] == turn and row["source"] == "canned"
                    assert row["observation"] == records[turn]["actions"][seat]["private_view"]
                    execution = row["execution"]
                    assert execution["accepted"] and not execution["scripted"]
                    assert execution["executed_action"] == records[turn]["actions"][seat]["executed_action"]
                    assert json.loads(row["raw_response"]) == execution["executed_action"]
                    for message in row["prompt"]:
                        assert (
                            hashlib.sha256(message["content"].encode()).hexdigest()
                            == row["prompt_template"][message["role"] + "_sha256"]
                        )
                    assert row["prompt_template"]["variant"] == wording
                    if wording == "canonical":
                        assert (
                            row["prompt"][0]["content"]
                            == "Play Garble. Submit one complete decision as JSON.\n\n"
                            + (root / "docs/rules.md").read_text()
                        )
                    assert all(
                        f"PRIVATE-STRATEGY-{other}" not in row["prompt"][1]["content"]
                        for other in range(seats)
                        if other != seat
                    )
            assert all(event in replay["events"] for record in records for event in record["events"])
            print(work.name, "five ordinary players; complete capture and host execution joins PASS", flush=True)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()
            closed_endpoint.close()
    subprocess.run(
        [
            sys.executable,
            str(root / "players/ordinary/export.py"),
            str(args.output / "candidates"),
            *[str(args.output / f"{variant}-{wording}-{seed}") for variant, wording, seed in cases],
            "--source-revision",
            "uncommitted-garble-validation",
        ],
        check=True,
    )
    assert not (args.output / "candidates/train.jsonl").exists()
    rows = [json.loads(line) for line in (args.output / "candidates/trajectories.jsonl").read_text().splitlines()]
    assert len(rows) == 610
    assert len({row["seed_family"] for row in rows if row["event_type"] == "episode"}) == 10
    print(
        "Ten full ordinary games; 600 candidate decisions; ten source families; no automatic training labels PASS",
        flush=True,
    )


if __name__ == "__main__":
    main()
