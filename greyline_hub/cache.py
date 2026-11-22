"""Last-known feed payloads.

A failed fetch keeps the previous payload and records the error, so the dashboard
can show stale numbers instead of going blank. The file is rewritten atomically.
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path


class FeedCache:
    def __init__(self, path: Path):
        self.path = Path(path)
        self._lock = threading.Lock()
        self._data: dict = {}
        self._dirty = False
        self._load()

    def _load(self) -> None:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        if isinstance(raw, dict) and raw.get("v") == 1 and isinstance(raw.get("feeds"), dict):
            self._data = raw["feeds"]

    def get(self, key: str) -> dict | None:
        with self._lock:
            slot = self._data.get(key)
            return dict(slot) if slot else None

    def put(self, key: str, payload) -> None:
        with self._lock:
            self._data[key] = {
                "payload": payload,
                "fetched_at": time.time(),
                "error": None,
                "attempted_at": time.time(),
            }
            self._dirty = True

    def fail(self, key: str, error: str) -> None:
        with self._lock:
            slot = self._data.get(key) or {
                "payload": None,
                "fetched_at": None,
                "error": None,
                "attempted_at": None,
            }
            slot["error"] = error
            slot["attempted_at"] = time.time()
            self._data[key] = slot
            self._dirty = True

    def save(self) -> None:
        with self._lock:
            if not self._dirty:
                return
            document = {"v": 1, "feeds": self._data}
            body = json.dumps(document).encode("utf-8")
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(self.path.suffix + ".tmp")
            tmp.write_bytes(body)
            os.replace(tmp, self.path)
            self._dirty = False
