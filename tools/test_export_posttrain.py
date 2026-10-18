"""Complete candidate games, execution evidence, and original canonical exports."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
COMPARE_ORIGINAL = len(sys.argv) == 3
OUTPUT = Path(tempfile.mkdtemp(prefix="garble-source-export-"))
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
for variant in ("standard", "storm", "long-session"):
    if COMPARE_ORIGINAL:
        ORIGINAL = Path(sys.argv[2]).resolve()
        original = OUTPUT / ("original-" + variant)
        subprocess.run([str(ORIGINAL), str(original), "10", "1", variant], cwd=ROOT, check=True, timeout=600)
        reference = {}
        for split in ("train", "validation"):
            for line in (original / (split + ".jsonl")).read_text().splitlines():
                row = json.loads(line)
                reference[row["episode_id"], row["decision_id"]] = row
    output = OUTPUT / variant
    subprocess.run([str(EXPORTER), str(output), "10", "1", variant], cwd=ROOT, check=True, timeout=600)
    episodes, decisions, execution = {}, {}, {}
    for name in ("manifest.json", "trajectories.jsonl", "execution.jsonl"):
        assert (output / name).stat().st_mode & 0o777 == 0o600
    assert not (output / "train.jsonl").exists() and not (output / "validation.jsonl").exists()
    for line in (output / "trajectories.jsonl").open():
        row = json.loads(line)
        assert row["source_revision"] == revision
        episode = row["episode_id"]
        if row["event_type"] == "episode":
            episodes[episode] = row
            continue
        decisions.setdefault(episode, []).append(row)
        assert row["action_status"] == "accepted"
        (attempt,) = row["attempts"]
        assert attempt["accepted"] and attempt["origin"] == "teacher"
        assert attempt["request"] is None and attempt["platform_call_id"] is None
        assert row["selected_attempt_id"] == attempt["attempt_id"]
        assert row["executed_action"] == attempt["parsed_action"] == json.loads(attempt["response"])
        metadata = row["observation"]["prompt_template"]
        assert metadata["bank"] == "garble-rules-v1" and metadata["variant"] == "canonical"
        for message in attempt["prompt"]:
            assert (
                metadata[message["role"] + "_sha256"].lower() == hashlib.sha256(message["content"].encode()).hexdigest()
            )
    for line in (output / "execution.jsonl").open():
        row = json.loads(line)
        execution.setdefault(row["episode_id"], []).append(row)
    assert len(episodes) == 10 and episodes.keys() == decisions.keys() == execution.keys()
    for identity, episode in episodes.items():
        assert episode["status"] == "completed" and episode["outcome"]["reason"] == "complete"
        seed = int(episode["seed_family"].removeprefix("garble-"))
        turns = 18 if variant == "long-session" else 12
        rows = decisions[identity]
        assert len(rows) == turns * 5 and len(execution[identity]) == turns
        if COMPARE_ORIGINAL:
            for index, row in enumerate(rows):
                old = reference[f"garble-{variant}-{seed}", index]
                assert row["attempts"][0]["prompt"] == old["prompt"]
                assert row["executed_action"] == json.loads(old["completion"][0]["content"])
        for index, turn in enumerate(execution[identity]):
            batch = rows[index * 5 : (index + 1) * 5]
            assert turn["decision_ids"] == [row["decision_id"] for row in batch]
            assert turn["turn"] == index and turn["terminal"] == (index == turns - 1)
            assert turn["event_end"] - turn["event_start"] == len(turn["events"])
            says = [event for event in turn["events"] if event["kind"] == "say"]
            assert len(says) == 5
            for seat, (decision, event) in enumerate(zip(batch, says, strict=True)):
                assert event["seat"] == seat and event["text"] == decision["executed_action"]["text"]
            if index:
                assert turn["event_start"] > execution[identity][index - 1]["event_end"] - 1
        assert sum(row["terminal"] for row in rows) == 1 and rows[-1]["terminal"]
        assert [episode["participant_outcomes"][str(seat)]["score"] for seat in range(5)] == episode["outcome"][
            "scores"
        ]
    assert {episode["seed_family"] for episode in episodes.values()} == {f"garble-{seed}" for seed in range(1, 11)}
    print(
        variant,
        "10 candidate games; hashes, execution and family metadata PASS; original comparison:",
        COMPARE_ORIGINAL,
        flush=True,
    )
print("Evidence:", OUTPUT)
