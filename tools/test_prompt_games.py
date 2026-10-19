"""Complete ordinary-interface games across matched wording and private views."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(sys.argv[1]).resolve()
VARIANTS = ("standard", "storm", "long-session")
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(variant, seed, wording="canonical", prompt_seed=0, notes=False):
    with subprocess.Popen(
        [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": 5,
                "seed": str(seed),
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace = []
        system = None
        while observation["kind"] == "decision":
            index, seat = observation["decision_id"], observation["seat"]
            assert index == len(trace) and seat == index % 5
            view = observation["semantic_view"].copy()
            metadata = view.pop("prompt_template")
            messages = observation["messages"]
            if system is None:
                system = messages[0]["content"]
            assert messages[0]["content"] == system
            assert (
                metadata["bank"],
                metadata["variant"],
                metadata["selection"],
                metadata["seed"],
            ) == (
                "garble-rules-v2",
                WORDINGS[prompt_seed % 5] if wording == "mixed" else wording,
                wording,
                prompt_seed,
            )
            for message in messages:
                assert (
                    metadata[message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            if wording == "canonical":
                assert (
                    system
                    == "Play Garble. Submit one complete decision as JSON.\n\n"
                    + (ROOT / "docs/rules.md").read_text()
                )
            assert messages[1]["content"].startswith(
                json.dumps(view, separators=(",", ":"), ensure_ascii=False)
            )
            action = json.loads(request({"kind": "teacher"})["response"])
            expected = json.loads(json.dumps(action))
            if notes:
                action["notes"] = expected["notes"] = f"PRIVATE-SEAT-{seat}"
                for other in range(5):
                    if other != seat:
                        assert f"PRIVATE-SEAT-{other}" not in messages[1]["content"]
                if action["confirm"] is not None:
                    action["confirm"]["qty"] = str(action["confirm"]["qty"])
                    action["confirm"]["price"] = str(action["confirm"]["price"])
                    action["confirm"]["side"] = action["confirm"]["side"].lower()
            trace.append((view, messages[1]["content"], expected))
            response = request(
                {"kind": "step", "decision_id": index, "response": json.dumps(action)}
            )
            assert response["kind"] == "accepted" and response["action"] == expected
            observation = response["observation"]
        assert len(trace) == (90 if variant == "long-session" else 60)
        assert len(observation["scores"]) == 5
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        return trace, observation, system


for variant in VARIANTS:
    canonical = play(variant, 17)
    systems = []
    for wording, seed in [(wording, 0) for wording in WORDINGS] + [("mixed", 4)]:
        result = play(variant, 17, wording, seed)
        assert result[:2] == canonical[:2]
        if wording != "mixed":
            systems.append(result[2])
    assert len(set(systems)) == 7
    play(variant, 17, notes=True)
    print(variant, "10 complete matched/private-note games PASS", flush=True)
for wording in WORDINGS[-2:]:
    result = subprocess.run(
        [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), VARIANTS[0]],
        input=json.dumps(
            {
                "kind": "reset",
                "players": 5,
                "seed": "17",
                "promptVariant": wording,
                "split": "train",
            }
        )
        + "\n",
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert (
        result.returncode != 0
        and "held-out wording cannot be used for training" in result.stderr
    )
print("30 complete language games; held-out gate PASS", flush=True)
