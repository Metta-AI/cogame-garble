"""Complete mixed-wording exports preserve Garble decisions and seed families."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as directory:
    for variant in ("standard", "storm", "long-session"):
        output = Path(directory) / variant
        subprocess.run(
            [str(EXPORTER), str(output), "10", "1", variant, "mixed", "0"],
            cwd=ROOT,
            check=True,
        )
        manifest = json.loads((output / "manifest.json").read_text())
        families, counts = {}, {}
        for split in ("train", "validation"):
            rows = [
                json.loads(line)
                for line in (output / (split + ".jsonl")).read_text().splitlines()
            ]
            assert len(rows) == manifest[split + "_examples"] > 0
            families[split] = {row["seed"] for row in rows}
            if split == "train":
                assert {row["prompt_template"]["variant"] for row in rows} == {
                    "canonical",
                    "plain",
                    "numbered",
                    "questions",
                    "reordered",
                }
            for row in rows:
                counts[row["seed"]] = counts.get(row["seed"], 0) + 1
                assert row["prompt_template"]["bank"] == "garble-rules-v2"
                for message in row["prompt"]:
                    assert (
                        row["prompt_template"][message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                action = json.loads(row["completion"][0]["content"])
                assert set(action) == {"channel", "text", "notes", "confirm"}
                view = json.JSONDecoder().raw_decode(row["prompt"][1]["content"])[0]
                assert isinstance(view["cash"], int) and len(view["units"]) == 4
        assert families["train"].isdisjoint(families["validation"])
        assert all(
            counts[f"garble-{run['seed']}"]
            == run["decisions"]
            == run["turns_played"] * 5
            for run in manifest["runs"]
        )
        print(variant, "10 complete mixed exports PASS", flush=True)
