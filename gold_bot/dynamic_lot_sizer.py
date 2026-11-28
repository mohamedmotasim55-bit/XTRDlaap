"""
dynamic_lot_sizer.py
====================
Smart anti-Martingale compounding lot sizer.

Rules
-----
* Micro tier (equity < $25): strictly 0.01 lot, locking a +150% buffer.
* Growth tier (equity >= $25): +0.01 lot per $20 of equity
  ($25->0.02, $45->0.03, $65->0.04), capped at MAX_LOT_SIZE (0.50).
* Drawdown throttle: if equity < peak*(1-8%) halve the lot until equity
  recovers to within 3% of peak (hysteresis).
* Margin guard: step the lot down until free margin after the order keeps
  at least 40% of equity free.

Broker constraints (volume_min / volume_step / volume_max) are honoured.
"""

from __future__ import annotations

import logging
import math
from typing import Optional

try:  # Windows-only; defensive import for offline tests.
    import MetaTrader5 as mt5  # type: ignore
except ImportError:  # pragma: no cover
    mt5 = None  # type: ignore

import config

log = logging.getLogger(__name__)

FALLBACK_EQUITY = 10.0


class DynamicLotSizer:
    def __init__(self, mt5_module=None, symbol: Optional[str] = None) -> None:
        self.mt5 = mt5 if mt5_module is None else mt5_module
        self.symbol = symbol
        self.throttled = False
        self.last_reason = ""

    # ------------------------------------------------------------ constraints
    def _constraints(self):
        vmin, vstep, vmax = 0.01, 0.01, 100.0
        if self.mt5 is not None and self.symbol:
            try:
                info = self.mt5.symbol_info(self.symbol)
                if info is not None:
                    vmin = float(getattr(info, "volume_min", 0.01) or 0.01)
                    vstep = float(getattr(info, "volume_step", 0.01) or 0.01)
                    vmax = float(getattr(info, "volume_max", 100.0) or 100.0)
            except Exception:  # noqa: BLE001
                pass
        return vmin, vstep, vmax

    @staticmethod
    def _round_step(lot: float, vmin: float, vstep: float, vmax: float) -> float:
        lot = max(vmin, min(vmax, lot))
        if vstep <= 0:
            return round(lot, 2)
        steps = round((lot - vmin) / vstep)
        return round(vmin + steps * vstep, 2)

    # ---------------------------------------------------------------- sizing
    @staticmethod
    def base_lot(equity: float) -> float:
        if equity < config.COMPOUND_START_EQUITY_USD:
            return 0.01
        steps = 1 + int((equity - config.COMPOUND_START_EQUITY_USD)
                         // config.COMPOUND_EQUITY_STEP_USD)
        return 0.01 + 0.01 * steps

    def _update_throttle(self, equity: float, peak_equity: float) -> None:
        if peak_equity and peak_equity > 0:
            if equity < peak_equity * (1.0 - config.DD_THROTTLE_PCT):
                self.throttled = True
            elif equity >= peak_equity * (1.0 - config.DD_RECOVER_PCT):
                self.throttled = False

    def _margin_guard(self, lot: float, equity: float, price: float,
                      vmin: float, vstep: float) -> float:
        if self.mt5 is None or not self.symbol or price is None:
            return lot
        order_type = getattr(self.mt5, "ORDER_TYPE_BUY", 0)
        while lot >= vmin:
            try:
                margin = self.mt5.order_calc_margin(order_type, self.symbol, lot, price)
            except Exception:  # noqa: BLE001
                return lot
            if margin is None:
                return lot
            if (equity - margin) >= config.MARGIN_FREE_FRACTION * equity:
                return lot
            lot = round(lot - vstep, 2)
        return vmin

    def size(self, equity: float, peak_equity: float = 0.0,
             free_margin: Optional[float] = None, price: Optional[float] = None) -> float:
        equity = float(equity or 0.0)
        if equity <= 0:
            equity = FALLBACK_EQUITY
        peak_equity = float(peak_equity or 0.0)

        self._update_throttle(equity, peak_equity)

        lot = self.base_lot(equity)
        reason = f"base {lot:.2f} @ ${equity:.2f}"

        if self.throttled:
            lot = lot / 2.0
            reason += " (DD throttle x0.5)"

        lot = min(lot, config.MAX_LOT_SIZE)
        vmin, vstep, vmax = self._constraints()
        lot = self._round_step(lot, vmin, vstep, vmax)

        guarded = self._margin_guard(lot, equity, price, vmin, vstep)
        if guarded != lot:
            reason += f" (margin guard {lot:.2f}->{guarded:.2f})"
        lot = guarded

        self.last_reason = reason
        return lot
