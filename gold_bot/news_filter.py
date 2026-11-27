"""
news_filter.py
==============
High-Impact USD Economic News Shield.

* Fetches the weekly ForexFactory calendar JSON, caches it locally for 4 hours
  (``news_cache.json``) to avoid spamming the endpoint, and falls back
  gracefully to the cache / empty list when offline.
* Keeps only ``country == "USD"`` and ``impact == "High"`` events.
* ``is_news_danger_zone(now_utc)`` -> (bool, title) when inside the
  before/after pause window.
* ``should_close_before_news(now_utc)`` -> True when an event is <= N minutes
  away (so open positions can be closed before the spread explodes).

All times are handled in UTC. The fetcher is injectable for testing.
"""

from __future__ import annotations

import json
import logging
import os
import time
from datetime import datetime, timedelta, timezone
from typing import Callable, List, Optional, Tuple

import config

log = logging.getLogger(__name__)

FF_URL = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "news_cache.json")
CACHE_TTL_SECONDS = 4 * 3600


class NewsFilter:
    """Loads, caches and evaluates the high-impact USD calendar."""

    def __init__(
        self,
        cache_path: str = CACHE_PATH,
        fetcher: Optional[Callable[[], list]] = None,
    ) -> None:
        self.cache_path = cache_path
        self._fetcher = fetcher or self._http_fetch
        self.events: List[dict] = []          # {title, time_utc, country, impact}
        self.last_refresh: float = 0.0

    # ------------------------------------------------------------- fetching
    @staticmethod
    def _http_fetch() -> list:
        import urllib.request

        req = urllib.request.Request(FF_URL, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def _load_cache(self) -> Optional[list]:
        try:
            with open(self.cache_path, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return None

    def _save_cache(self, raw: list) -> None:
        try:
            with open(self.cache_path, "w", encoding="utf-8") as fh:
                json.dump(raw, fh)
        except OSError as exc:  # pragma: no cover
            log.warning("Could not write news cache: %s", exc)

    @staticmethod
    def _parse_time(value) -> Optional[datetime]:
        if not value:
            return None
        try:
            text = str(value).replace(" ", "T")
            dt = datetime.fromisoformat(text)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except (ValueError, TypeError):
            return None

    def _parse_events(self, raw: list) -> List[dict]:
        out: List[dict] = []
        for ev in raw or []:
            if ev.get("country") != "USD":
                continue
            if str(ev.get("impact", "")).strip().lower() != "high":
                continue
            dt = self._parse_time(ev.get("date"))
            if dt is None:
                continue
            out.append(
                {
                    "title": ev.get("title", "USD High-Impact Event"),
                    "time_utc": dt,
                    "country": "USD",
                    "impact": "High",
                }
            )
        out.sort(key=lambda e: e["time_utc"])
        return out

    # ------------------------------------------------------------- refresh
    def refresh(self, force: bool = False) -> None:
        now = time.time()
        if not force and self.events and (now - self.last_refresh) < CACHE_TTL_SECONDS:
            return

        raw = self._load_cache()
        if raw is None or force:
            try:
                raw = self._fetcher()
                self._save_cache(raw)
            except Exception as exc:  # noqa: BLE001 - offline is expected
                log.warning("News fetch failed (%s); using cache/empty.", exc)
                raw = raw or []

        self.events = self._parse_events(raw)
        self.last_refresh = now

    def _ensure(self) -> None:
        if not self.events:
            self.refresh()

    # ------------------------------------------------------------- queries
    @staticmethod
    def _as_utc(now_utc: datetime) -> datetime:
        if now_utc.tzinfo is None:
            return now_utc.replace(tzinfo=timezone.utc)
        return now_utc.astimezone(timezone.utc)

    def is_news_danger_zone(self, now_utc: datetime) -> Tuple[bool, str]:
        """(True, title) if now is within the pause window of a high-impact event."""
        self._ensure()
        now_utc = self._as_utc(now_utc)
        for ev in self.events:
            before = ev["time_utc"] - timedelta(minutes=config.NEWS_PAUSE_BEFORE_MIN)
            after = ev["time_utc"] + timedelta(minutes=config.NEWS_PAUSE_AFTER_MIN)
            if before <= now_utc <= after:
                return True, ev["title"]
        return False, ""

    def should_close_before_news(self, now_utc: datetime) -> bool:
        """True if a high-impact event is <= NEWS_FORCE_CLOSE_MIN minutes away."""
        self._ensure()
        now_utc = self._as_utc(now_utc)
        for ev in self.events:
            delta = (ev["time_utc"] - now_utc).total_seconds()
            if 0 <= delta <= config.NEWS_FORCE_CLOSE_MIN * 60:
                return True
        return False
