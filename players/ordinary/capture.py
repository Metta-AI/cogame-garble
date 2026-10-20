"""Retain accepted player decisions in the standard Coworld artifact."""

from __future__ import annotations

import hashlib
import io
import json
import os
import urllib.request
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlsplit


class Capture:
    def __init__(self, slot: int, backend: str) -> None:
        self.slot = slot
        self.backend = backend
        self.revision = os.environ["POC_SOURCE_REVISION"]
        self.upload_url = os.environ["COWORLD_PLAYER_ARTIFACT_UPLOAD_URL"]
        self.rows: list[dict] = []

    def record(
        self,
        system: str,
        user: str,
        action: dict,
        source: str,
        turn: int,
        selection: dict,
    ) -> None:
        self.rows.append(
            {
                "prompt_template": {
                    **selection,
                    "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
                    "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
                },
                "decision_id": len(self.rows),
                "turn": turn,
                "source": source,
                "prompt": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                "completion": [
                    {"role": "assistant", "content": json.dumps(action, sort_keys=True)}
                ],
            }
        )

    def upload(self, scores: list[float]) -> None:
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr(
                "trajectory.json",
                json.dumps(
                    {
                        "schema_version": 1,
                        "game": "garble",
                        "slot": self.slot,
                        "backend": self.backend,
                        "source_revision": self.revision,
                        "complete": True,
                        "scores": scores,
                        "decisions": self.rows,
                    }
                ),
            )
        data = archive.getvalue()
        url = urlsplit(self.upload_url)
        if url.scheme == "file":
            target = Path(unquote(url.path))
            pending = target.with_name(target.name + ".tmp")
            pending.write_bytes(data)
            os.replace(pending, target)
        else:
            request = urllib.request.Request(
                self.upload_url,
                data=data,
                method="PUT",
                headers={"Content-Type": "application/zip"},
            )
            with urllib.request.urlopen(request, timeout=10) as response:
                response.read()
