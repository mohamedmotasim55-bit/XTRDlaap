"""
executive_controller.py
=======================
Autonomous trading-desk director.

Governs slot count, re-arm cooldown, stacking permission and the drawdown
throttle from live market-flow and rolling performance:

* base mode  : MAX_BASE_TRADES simultaneous engines, normal cooldown
* high flow  : pulse >= 1.55, spread <= 32 pts and rolling WR >= 45%
               -> up to MAX_EXECUTIVE_SLOTS (5) positions, 0-second re-arm

The early account shield (equity < $15 -> daily loss cap 0.85) is enforced
by ``safety_guard.daily_loss_limit``; this module only reports the regime.
"""
from __future__ import annotations

from collections import deque
from typing import Deque, Dict

import config


class ExecutiveController:
    def __init__(self, window: int = 20) -> None:
        self.recent: Deque[float] = deque(maxlen=window)
        self.mode = "BASE"
        self.max_slots = config.MAX_BASE_TRADES
        self.cooldown_bars = max(1, int(config.COOLDOWN_SECONDS // 60))
        self.rolling_win_rate = 0.0

    def record_trade(self, pnl: float) -> None:
        self.recent.append(float(pnl))

    def _win_rate(self) -> float:
        if len(self.recent) < 10:
            return 50.0
        return 100.0 * sum(1 for x in self.recent if x > 0) / len(self.recent)

    def update(self, pulse: float, spread_points: float, equity: float) -> Dict[str, object]:
        self.rolling_win_rate = self._win_rate()
        high_flow = (pulse >= config.EXEC_PULSE_THRESHOLD
                     and spread_points <= config.EXEC_MAX_SPREAD_POINTS
                     and self.rolling_win_rate >= config.EXEC_MIN_WIN_RATE)
        self.mode = "HIGH_FLOW" if high_flow else "BASE"
        self.max_slots = (config.MAX_EXECUTIVE_SLOTS if high_flow
                          else config.MAX_BASE_TRADES)
        self.cooldown_bars = 1 if high_flow else max(1, int(config.COOLDOWN_SECONDS // 60))
        return dict(mode=self.mode, max_slots=self.max_slots,
                    cooldown_bars=self.cooldown_bars,
                    win_rate=self.rolling_win_rate,
                    shield=equity < config.EARLY_SHIELD_EQUITY_USD)
