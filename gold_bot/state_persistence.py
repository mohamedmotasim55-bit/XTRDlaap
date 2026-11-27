"""
state_persistence.py
====================
30-day continuous-operation memory + log rotation.

* Persists bot state to ``logs/bot_state.json`` (atomic write) at most once
  per ``STATE_SAVE_INTERVAL_SEC`` (or forced on trade events).
* Stores peak equity, daily balance/profit, adaptive-brain history & mute
  timers, consecutive losses and cooldown timestamps so restarts are safe.
* ``rotate_logs_if_needed()`` archives CSV/text logs above 5 MB.
"""

from __future__ import annotations

import glob
import json
import logging
import os
import shutil
import time
from typing import Optional

import config

log = logging.getLogger(__name__)


class StatePersistence:
    def __init__(self, path: str = "logs/bot_state.json",
                 save_interval_sec: Optional[int] = None) -> None:
        self.path = path
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        self.save_interval = (
            save_interval_sec if save_interval_sec is not None
            else config.STATE_SAVE_INTERVAL_SEC
        )
        self.state: dict = {}
        self._last_save = 0.0

    # ------------------------------------------------------------- persistence
    def load(self) -> dict:
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                self.state = json.load(fh)
        except (OSError, ValueError):
            self.state = {}
        return self.state

    def update(self, **kwargs) -> None:
        self.state.update(kwargs)

    def get(self, key: str, default=None):
        return self.state.get(key, default)

    def save(self, force: bool = False) -> bool:
        now = time.monotonic()
        if not force and (now - self._last_save) < self.save_interval:
            return False
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self.state, fh, indent=2, default=str)
            os.replace(tmp, self.path)
            self._last_save = now
            return True
        except OSError as exc:  # pragma: no cover
            log.warning("State save failed: %s", exc)
            return False

    # --------------------------------------------------------------- rotation
    @staticmethod
    def rotate_logs_if_needed(directory: str = "logs",
                              max_bytes: Optional[int] = None) -> list:
        limit = max_bytes if max_bytes is not None else config.LOG_ROTATE_MAX_BYTES
        archived = []
        for p in glob.glob(os.path.join(directory, "*")):
            if not os.path.isfile(p) or p.endswith(".json") or p.endswith(".tmp"):
                continue
            try:
                if os.path.getsize(p) > limit:
                    stamp = time.strftime("%Y%m%d-%H%M%S")
                    dst = f"{p}.{stamp}.bak"
                    shutil.move(p, dst)
                    archived.append(dst)
            except OSError:
                continue
        return archived
