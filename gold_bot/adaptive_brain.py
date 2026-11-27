"""
adaptive_brain.py
=================
Self-optimising strategy weighting layer.

Responsibilities
----------------
* Track rolling performance (last ``ROLLING_WINDOW`` trades) per strategy.
* Auto-mute a strategy after 3 consecutive losses for ``STRATEGY_MUTE_MINUTES``.
* Dynamic confidence multiplier in [0.7, 1.3] from recent win rate.
* Regime-strategy alignment boost (+``REGIME_BOOST``).
* Gate execution on final confidence >= ``MIN_CONFIDENCE_TO_TRADE``.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Dict, Optional

import config
import regime_detector

STRATEGIES = [
    "MomentumBreakout",
    "LiquiditySweep",
    "BollingerBounce",
    "EMARibbonPullback",
    "FastMACDCross",
    "FairValueGapScalp",
    "MicroEngulfingReversal",
]

# Which strategies are favoured in which regime.
REGIME_AFFINITY = {
    regime_detector.REGIME_TREND_UP: {"MomentumBreakout", "EMARibbonPullback", "FastMACDCross"},
    regime_detector.REGIME_TREND_DOWN: {"MomentumBreakout", "EMARibbonPullback", "FastMACDCross"},
    regime_detector.REGIME_RANGING: {"BollingerBounce", "LiquiditySweep"},
    regime_detector.REGIME_VOLATILE: {"FairValueGapScalp", "MicroEngulfingReversal"},
}


class AdaptiveBrain:
    def __init__(self, mute_minutes: Optional[int] = None,
                 min_confidence: Optional[float] = None,
                 window: Optional[int] = None) -> None:
        self.mute_minutes = mute_minutes if mute_minutes is not None else config.STRATEGY_MUTE_MINUTES
        self.min_confidence = (
            min_confidence if min_confidence is not None else config.MIN_CONFIDENCE_TO_TRADE
        )
        self.window = window if window is not None else config.ROLLING_WINDOW

        self.history: Dict[str, list] = {s: [] for s in STRATEGIES}   # True=win
        self.consec_losses: Dict[str, int] = {s: 0 for s in STRATEGIES}
        self.muted_until: Dict[str, Optional[datetime]] = {s: None for s in STRATEGIES}

    # ------------------------------------------------------------- recording
    def record_trade(self, strategy: str, profit_usd: float, now: Optional[datetime] = None) -> None:
        now = now or datetime.now()
        if strategy not in self.history:
            return
        win = profit_usd > 0
        self.history[strategy].append(win)
        if len(self.history[strategy]) > self.window:
            self.history[strategy].pop(0)

        if win:
            self.consec_losses[strategy] = 0
        else:
            self.consec_losses[strategy] += 1
            if (self.consec_losses[strategy] >= 3
                    and len(self.history[strategy]) >= config.MUTE_MIN_TRADES):
                self.muted_until[strategy] = now + timedelta(minutes=self.mute_minutes)

    # ---------------------------------------------------------------- status
    def is_muted(self, strategy: str, now: Optional[datetime] = None) -> bool:
        now = now or datetime.now()
        until = self.muted_until.get(strategy)
        if until is None:
            return False
        if now >= until:
            self.muted_until[strategy] = None
            self.consec_losses[strategy] = 0
            return False
        return True

    def win_rate(self, strategy: str) -> float:
        h = self.history.get(strategy, [])
        if not h:
            return 0.0
        return sum(1 for w in h if w) / len(h)

    def multiplier(self, strategy: str) -> float:
        """0.7x .. 1.3x based on recent win rate (0.35..0.65 maps to 0.7..1.3)."""
        h = self.history.get(strategy, [])
        if not h:
            return 1.0
        wr = self.win_rate(strategy)
        lo, hi = 0.35, 0.65
        if wr <= lo:
            return config.CONF_MULT_FLOOR
        if wr >= hi:
            return 1.3
        raw = config.CONF_MULT_FLOOR + (wr - lo) / (hi - lo) * (1.3 - config.CONF_MULT_FLOOR)
        return max(config.CONF_MULT_FLOOR, raw)

    def regime_boost(self, strategy: str, regime) -> float:
        regime_name = getattr(regime, "regime", regime)
        favoured = REGIME_AFFINITY.get(regime_name, set())
        return config.REGIME_BOOST if strategy in favoured else 0.0

    # -------------------------------------------------------------- evaluate
    # ------------------------------------------------------------- persistence
    def export_state(self) -> dict:
        return {
            "history": {k: list(v) for k, v in self.history.items()},
            "consec_losses": dict(self.consec_losses),
            "muted_until": {k: (v.isoformat() if v else None)
                            for k, v in self.muted_until.items()},
        }

    def import_state(self, data: Optional[dict]) -> None:
        if not data:
            return
        for k, v in (data.get("history") or {}).items():
            if k in self.history:
                self.history[k] = [bool(x) for x in v][-self.window:]
        for k, v in (data.get("consec_losses") or {}).items():
            if k in self.consec_losses:
                self.consec_losses[k] = int(v)
        for k, v in (data.get("muted_until") or {}).items():
            if k in self.muted_until:
                self.muted_until[k] = datetime.fromisoformat(v) if v else None

    def evaluate(self, signal, regime, now: Optional[datetime] = None):
        """Return (allowed, final_confidence, reason)."""
        if signal is None or getattr(signal, "signal", "NONE") not in ("BUY", "SELL"):
            return False, 0.0, "no signal"
        strategy = signal.strategy
        if self.is_muted(strategy, now):
            return False, 0.0, f"{strategy} muted"

        base = float(getattr(signal, "confidence_score", 0.0) or 0.0)
        final = base * self.multiplier(strategy) + self.regime_boost(strategy, regime)
        final = round(min(1.0, max(0.0, final)), 3)
        allowed = final >= self.min_confidence
        reason = "ok" if allowed else f"confidence {final:.2f} < {self.min_confidence}"
        return allowed, final, reason
