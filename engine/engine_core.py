"""
XTRD ENGINE CORE — analysis + signal reading + decision.
Independent of any bot. Feed it a market snapshot, get a decision.
"""
import numpy as np
from dataclasses import dataclass, field
from typing import Optional

# ---------- 1. MARKET STATE (what the engine sees) ----------
@dataclass
class Snapshot:
    idx: int
    hour: int
    bid: float
    ask: float
    spread: float
    pulse: float          # tick-rate / 60-min average
    m1s: float            # 1-second momentum
    m30s: float
    m60s: float
    m5m: float
    m24h: float           # 24h trend
    ch_hi: float          # 30-min channel high
    ch_lo: float          # 30-min channel low
    atr: float            # 60-min range average

# ---------- 2. SIGNAL READINGS (what the engine computes) ----------
def read_signals(s: Snapshot) -> dict:
    """Read every signal the engine tracks. Pure measurement, no decision."""
    return {
        "pulse_active":   s.pulse > 1.0,
        "pulse_strong":   s.pulse > 1.5,
        "trend_up":       s.m24h > 0,
        "trend_down":     s.m24h < 0,
        "broke_up":       s.bid > s.ch_hi + 20,
        "broke_down":     s.bid < s.ch_lo - 20,
        "micro_up":       s.m30s > 0,
        "micro_down":     s.m30s < 0,
        "spread_ok":      s.spread <= 60,
        "session":        s.hour == 1,
        "vol_expanding":  s.atr > 0,
    }

# ---------- 3. DECISION ----------
@dataclass
class Decision:
    action: str           # "BUY" | "SELL" | "HOLD"
    strategy: str
    confidence: float     # 0..1
    reason: str
    stop: float = 0.0
    hold_min: int = 0

# ---------- 4. STRATEGIES (each reads signals, may emit a decision) ----------
class Strategy:
    name = "base"
    def evaluate(self, s: Snapshot, sig: dict) -> Optional[Decision]:
        return None

class TrendPullback(Strategy):
    """Fade a 30-min channel break that runs AGAINST the 24h trend, in hour 1, with pulse."""
    name = "TREND_PULLBACK"
    def evaluate(self, s, sig):
        if not sig["session"] or not sig["pulse_active"] or not sig["spread_ok"]:
            return None
        if sig["broke_up"] and sig["trend_down"]:
            return Decision("SELL", self.name, 0.7,
                            "rally into 30m high inside 24h downtrend, pulse active",
                            stop=80, hold_min=45)
        if sig["broke_down"] and sig["trend_up"]:
            return Decision("BUY", self.name, 0.7,
                            "dip under 30m low inside 24h uptrend, pulse active",
                            stop=80, hold_min=45)
        return None

class Fade(Strategy):
    """Fade any 30-min channel break in hour 1 with pulse (no trend filter)."""
    name = "FADE"
    def evaluate(self, s, sig):
        if not sig["session"] or not sig["pulse_active"] or not sig["spread_ok"]:
            return None
        if sig["broke_up"]:
            return Decision("SELL", self.name, 0.55, "30m high break, fade", stop=80, hold_min=30)
        if sig["broke_down"]:
            return Decision("BUY", self.name, 0.55, "30m low break, fade", stop=80, hold_min=30)
        return None

# ---------- 5. THE ENGINE ----------
class Engine:
    def __init__(self, strategies):
        self.strategies = strategies
        self.log = []
    def decide(self, s: Snapshot) -> Decision:
        sig = read_signals(s)
        for st in self.strategies:
            d = st.evaluate(s, sig)
            if d is not None:
                self.log.append((s.idx, s.hour, d.action, d.strategy, d.reason))
                return d
        return Decision("HOLD", "-", 0.0, "no signal")
