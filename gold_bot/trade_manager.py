"""
trade_manager.py
================
Smart trade execution + active position management for the $10 XAUUSD
micro-account.

Responsibilities
----------------
* ``count_bot_positions()``      – count open positions for our symbol + magic.
* ``can_open_new_trade()``       – enforce MAX_OPEN_TRADES, COOLDOWN_SECONDS,
                                   and a free-margin buffer via order_calc_margin.
* ``execute_signal(signal)``     – send a market order with live-price SL/TP,
                                   filling-mode auto-detection + fallback,
                                   order_check before order_send.
* ``manage_open_positions(atr)`` – auto break-even and dynamic ATR trailing.

The module imports ``MetaTrader5`` defensively so it can be imported (and
unit-tested with a fake) on non-Windows hosts.
"""

from __future__ import annotations

import logging
import math
from datetime import datetime, timedelta
from typing import List, Optional

try:  # Windows-only; keep import defensive.
    import MetaTrader5 as mt5  # type: ignore
except ImportError:  # pragma: no cover
    mt5 = None  # type: ignore

import config
from dynamic_lot_sizer import DynamicLotSizer

log = logging.getLogger(__name__)


def _num(value) -> Optional[float]:
    try:
        f = float(value)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


class TradeManager:
    """Execution + position-management helper bound to an MT5Connector."""

    def __init__(self, connector) -> None:
        self.conn = connector
        self.last_error: str = ""
        self.peak_equity: float = 0.0
        self.lot_sizer = DynamicLotSizer(symbol=getattr(connector, "symbol", None))

    # ------------------------------------------------------------------ utils
    @property
    def symbol(self) -> str:
        return self.conn.symbol

    def _info(self):
        return mt5.symbol_info(self.symbol)

    def _tick(self):
        return mt5.symbol_info_tick(self.symbol)

    def _point(self) -> float:
        info = self._info()
        return info.point if info is not None and info.point > 0 else 0.01

    def _stops_level(self) -> float:
        info = self._info()
        return float(info.trade_stops_level) if info is not None else 0.0

    def _positions(self) -> list:
        if mt5 is None:
            return []
        return mt5.positions_get(symbol=self.symbol) or []

    # --------------------------------------------------------------- counting
    def count_bot_positions(self) -> int:
        """Number of open positions matching our symbol AND magic number."""
        return sum(1 for p in self._positions() if p.magic == config.MAGIC_NUMBER)

    # -------------------------------------------------------------- cooldown
    def _last_close_time(self) -> Optional[datetime]:
        """Time of the most recent OUT deal for our symbol + magic (or None)."""
        if mt5 is None:
            return None
        now = datetime.now()
        frm = now - timedelta(days=3)
        to = now + timedelta(minutes=5)
        deals = mt5.history_deals_get(frm, to) or []
        last: Optional[datetime] = None
        for d in deals:
            if d.symbol != self.symbol or d.magic != config.MAGIC_NUMBER:
                continue
            if getattr(d, "entry", None) != mt5.DEAL_ENTRY_OUT:
                continue
            t = datetime.fromtimestamp(d.time)
            if last is None or t > last:
                last = t
        return last

    def _cooldown_active(self) -> bool:
        last = self._last_close_time()
        if last is None:
            return False
        return (datetime.now() - last).total_seconds() < config.COOLDOWN_SECONDS

    # ---------------------------------------------------------- open gating
    def _bot_positions(self) -> list:
        return [p for p in self._positions() if p.magic == config.MAGIC_NUMBER]

    @staticmethod
    def _position_is_risk_free(pos) -> bool:
        """True if SL is at or beyond break-even (locked in profit)."""
        if mt5 is None or not getattr(pos, "sl", 0.0):
            return False
        if pos.type == mt5.POSITION_TYPE_BUY:
            return pos.sl >= pos.price_open
        return pos.sl <= pos.price_open

    def can_open_new_trade(self, direction: Optional[str] = None) -> bool:
        """Return True if a base entry OR a zero-risk pyramid add-on is allowed."""
        self.last_error = ""
        n = self.count_bot_positions()

        if n == 0:
            pass  # normal base entry
        elif (
            n == 1
            and config.ENABLE_ZERO_RISK_PYRAMID
            and n < config.MAX_TOTAL_TRADES_WITH_PYRAMID
            and direction in ("BUY", "SELL")
        ):
            existing = self._bot_positions()[0]
            want_buy = direction == "BUY"
            same_dir = (existing.type == mt5.POSITION_TYPE_BUY) == want_buy
            if not same_dir:
                self.last_error = "pyramid direction mismatch"
                return False
            if not self._position_is_risk_free(existing):
                self.last_error = "pyramid blocked: existing trade not risk-free"
                return False
        else:
            self.last_error = "max open trades reached"
            return False

        # Cooldown gates fresh base entries only, not pyramid add-ons.
        if n == 0 and self._cooldown_active():
            self.last_error = "cooldown after last close"
            return False

        info = self._info()
        tick = self._tick()
        if info is None or tick is None:
            self.last_error = "symbol info/tick unavailable"
            return False

        is_buy = direction != "SELL"
        price = tick.ask if is_buy else tick.bid
        order_type = mt5.ORDER_TYPE_BUY if is_buy else mt5.ORDER_TYPE_SELL
        lot_for_margin = self._compute_lot("BUY" if is_buy else "SELL", price)
        margin = mt5.order_calc_margin(order_type, self.symbol, lot_for_margin, price)
        acc = mt5.account_info()
        if margin is None or acc is None:
            self.last_error = "margin/account unavailable"
            return False

        if (acc.margin_free - margin) < config.MIN_FREE_MARGIN_USD:
            self.last_error = "insufficient free-margin buffer"
            return False

        return True

    # ------------------------------------------------------------ filling mode
    def _filling_candidates(self) -> List[int]:
        """Ordered list of filling modes the symbol supports (preferred first)."""
        info = self._info()
        fm = int(getattr(info, "filling_mode", 0)) if info is not None else 0
        modes: List[int] = []
        # SYMBOL_FILLING_FOK = 1, SYMBOL_FILLING_IOC = 2 (bitmask)
        if fm & 1:
            modes.append(mt5.ORDER_FILLING_FOK)
        if fm & 2:
            modes.append(mt5.ORDER_FILLING_IOC)
        modes.append(mt5.ORDER_FILLING_RETURN)  # always a safe fallback
        # de-duplicate preserving order
        seen = set()
        out = []
        for m in modes:
            if m not in seen:
                seen.add(m)
                out.append(m)
        return out

    # ---------------------------------------------------------------- execute
    def _compute_lot(self, direction: str, price: float) -> float:
        """Dynamic lot from equity/peak/free-margin; ultra-safe on pyramid."""
        if mt5 is None:
            return float(config.LOT_SIZE)
        acc = mt5.account_info()
        equity = float(getattr(acc, "equity", 0.0) or 0.0) if acc else 0.0
        if equity <= 0:
            equity = float(getattr(acc, "balance", 0.0) or 0.0) if acc else 0.0
        if equity <= 0:
            equity = 10.0
        self.peak_equity = max(self.peak_equity, equity)
        free_margin = float(getattr(acc, "margin_free", 0.0) or 0.0) if acc else None
        lot = self.lot_sizer.size(equity, self.peak_equity,
                                  free_margin=free_margin, price=price)
        if self.count_bot_positions() >= 1:
            lot = min(lot, 0.01)  # 2nd zero-risk pyramid add-on stays ultra-safe
        return lot

    def execute_signal(self, signal) -> bool:
        """Send a market order for ``signal``. Returns True on a filled order."""
        if not config.ENABLE_LIVE_TRADING:
            self.last_error = "live trading disabled"
            return False
        if mt5 is None:
            self.last_error = "MT5 unavailable"
            return False
        if signal is None or not getattr(signal, "signal", "NONE") in ("BUY", "SELL"):
            self.last_error = "no actionable signal"
            return False

        info = self._info()
        tick = self._tick()
        if info is None or tick is None:
            self.last_error = "symbol info/tick unavailable"
            return False

        point = info.point
        stops = max(float(info.trade_stops_level), 2.0) + config.SL_SAFETY_BUFFER_POINTS
        min_dist = stops * point

        is_buy = signal.signal == "BUY"
        entry = tick.ask if is_buy else tick.bid
        limit_price = float(getattr(signal, "limit_price", 0.0) or 0.0)
        use_limit = getattr(signal, "entry_type", "MARKET") == "LIMIT" and limit_price > 0
        if use_limit:
            valid = limit_price < tick.ask if is_buy else limit_price > tick.bid
            if valid:
                entry = limit_price
            else:
                use_limit = False

        # Recompute SL/TP distances from the LIVE entry price.
        sl_dist = abs(entry - float(signal.sl))
        tp_dist = abs(float(signal.tp) - entry)
        sl_dist = max(sl_dist, min_dist)
        tp_dist = max(tp_dist, min_dist)
        # Hard calibration clamp (points) — protects the $10 account.
        sl_dist = min(max(sl_dist, config.MIN_SL_POINTS * point),
                      config.MAX_SL_POINTS * point)
        tp_dist = min(max(tp_dist, config.MIN_TP_POINTS * point),
                      config.MAX_TP_POINTS * point)

        if is_buy:
            sl = entry - sl_dist
            tp = entry + tp_dist
        else:
            sl = entry + sl_dist
            tp = entry - tp_dist

        digits = info.digits
        sl = round(sl, digits)
        tp = round(tp, digits)

        lot = self._compute_lot(signal.signal, entry)

        comment = (signal.strategy or "XTRD")[:31]
        for filling in self._filling_candidates():
            if use_limit:
                request = {
                    "action": mt5.TRADE_ACTION_PENDING,
                    "symbol": self.symbol,
                    "volume": float(lot),
                    "type": (mt5.ORDER_TYPE_BUY_LIMIT if is_buy
                             else mt5.ORDER_TYPE_SELL_LIMIT),
                    "price": entry,
                    "sl": sl,
                    "tp": tp,
                    "magic": config.MAGIC_NUMBER,
                    "comment": comment,
                    "type_time": mt5.ORDER_TIME_SPECIFIED,
                    "expiration": datetime.now() + timedelta(seconds=config.LIMIT_TTL_SECONDS),
                    "type_filling": filling,
                }
            else:
                request = {
                    "action": mt5.TRADE_ACTION_DEAL,
                    "symbol": self.symbol,
                    "volume": float(lot),
                    "type": mt5.ORDER_TYPE_BUY if is_buy else mt5.ORDER_TYPE_SELL,
                    "price": entry,
                    "sl": sl,
                    "tp": tp,
                    "deviation": config.DEVIATION_POINTS,
                    "magic": config.MAGIC_NUMBER,
                    "comment": comment,
                    "type_time": mt5.ORDER_TIME_GTC,
                    "type_filling": filling,
                }

            check = mt5.order_check(request)
            if check is None:
                self.last_error = "order_check returned None"
                return False
            if check.retcode != mt5.TRADE_RETCODE_DONE:
                self.last_error = f"order_check failed retcode={check.retcode}"
                log.error("Order check failed: retcode=%s comment=%s",
                          check.retcode, getattr(check, "comment", ""))
                return False

            result = mt5.order_send(request)
            if result is None:
                self.last_error = "order_send returned None"
                return False

            if result.retcode in (mt5.TRADE_RETCODE_DONE, mt5.TRADE_RETCODE_PLACED):
                spread_pts = (tick.ask - tick.bid) / point
                log.info(
                    "ORDER %s: ticket=%s %s %s | vol=%.2f | entry=%.3f | "
                    "SL=%.3f | TP=%.3f | spread=%.1f pts",
                    "LIMIT PLACED" if use_limit else "FILLED",
                    result.order, signal.signal, signal.strategy,
                    lot, result.price if result.price else entry,
                    sl, tp, spread_pts,
                )
                self.last_error = ""
                return True

            # Filling mode rejected -> try the next candidate.
            if result.retcode == getattr(mt5, "TRADE_RETCODE_INVALID_FILL", 10030):
                log.warning("Filling mode %s rejected; trying next.", filling)
                continue

            self.last_error = f"order_send failed retcode={result.retcode}"
            log.error("Order send failed: retcode=%s comment=%s",
                      result.retcode, getattr(result, "comment", ""))
            return False

        self.last_error = "all filling modes rejected"
        return False

    # ------------------------------------------------------- position manager
    def manage_open_positions(self, current_atr: Optional[float]) -> None:
        """Apply auto break-even and dynamic ATR trailing to bot positions."""
        if mt5 is None:
            return
        info = self._info()
        tick = self._tick()
        if info is None or tick is None:
            return
        point = info.point
        stops = max(float(info.trade_stops_level), 2.0)
        min_dist = stops * point

        for p in self._positions():
            if p.magic != config.MAGIC_NUMBER:
                continue
            self._manage_one(p, tick, point, min_dist, current_atr)

    def _manage_one(self, pos, tick, point, min_dist, current_atr) -> None:
        is_buy = pos.type == mt5.POSITION_TYPE_BUY
        open_price = pos.price_open
        sl = pos.sl
        tp = pos.tp

        if is_buy:
            profit_pts = (tick.bid - open_price) / point
            current_price = tick.bid
        else:
            profit_pts = (open_price - tick.ask) / point
            current_price = tick.ask

        new_sl = None

        # ---- Auto break-even -------------------------------------------------
        if profit_pts >= config.BREAKEVEN_TRIGGER_POINTS:
            be_sl = (open_price + config.BREAKEVEN_LOCK_POINTS * point) if is_buy \
                else (open_price - config.BREAKEVEN_LOCK_POINTS * point)
            locked = (sl > 0 and sl >= open_price) if is_buy else (sl > 0 and sl <= open_price)
            if not locked:
                # Respect broker stop distance from current price.
                if is_buy and be_sl <= current_price - min_dist:
                    new_sl = be_sl
                elif (not is_buy) and be_sl >= current_price + min_dist:
                    new_sl = be_sl
                if new_sl is not None:
                    log.info("BREAK-EVEN: ticket=%s -> SL=%.3f (profit=%.1f pts)",
                             pos.ticket, new_sl, profit_pts)

        # ---- Dynamic trailing ------------------------------------------------
        if profit_pts >= config.TRAILING_START_POINTS and current_atr and current_atr > 0:
            trail_dist = config.TRAILING_ATR_MULT * current_atr
            if is_buy:
                candidate = current_price - trail_dist
                better = candidate > (new_sl if new_sl is not None else sl)
                if better and candidate <= current_price - min_dist:
                    new_sl = candidate
            else:
                candidate = current_price + trail_dist
                better = candidate < (new_sl if new_sl is not None else sl)
                if better and candidate >= current_price + min_dist:
                    new_sl = candidate

        if new_sl is None:
            return

        new_sl = round(new_sl, 3)
        old_ref = new_sl if sl == 0 else sl
        # Only move forward; ignore tiny changes (< TRAIL_MIN_STEP_POINTS).
        if sl != 0 and abs(new_sl - sl) / point < config.TRAIL_MIN_STEP_POINTS:
            return
        if (is_buy and new_sl <= sl) or ((not is_buy) and sl != 0 and new_sl >= sl):
            return

        self._modify_sltp(pos, new_sl, tp, profit_pts)

    def close_all_positions(self, reason: str = "manual") -> int:
        """Market-close every bot position (e.g. before a high-impact news release)."""
        if mt5 is None:
            return 0
        tick = self._tick()
        if tick is None:
            return 0
        closed = 0
        for p in self._positions():
            if p.magic != config.MAGIC_NUMBER:
                continue
            is_buy = p.type == mt5.POSITION_TYPE_BUY
            price = tick.bid if is_buy else tick.ask
            request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": self.symbol,
                "volume": float(p.volume),
                "type": mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY,
                "position": p.ticket,
                "price": price,
                "deviation": config.DEVIATION_POINTS,
                "magic": config.MAGIC_NUMBER,
                "comment": reason[:31],
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": self._filling_candidates()[0],
            }
            result = mt5.order_send(request)
            if result is not None and result.retcode in (
                mt5.TRADE_RETCODE_DONE, mt5.TRADE_RETCODE_PLACED
            ):
                closed += 1
                log.info("CLOSED #%s (%s) before news.", p.ticket, reason)
        return closed

    def _modify_sltp(self, pos, new_sl: float, tp: float, profit_pts: float) -> None:
        request = {
            "action": mt5.TRADE_ACTION_SLTP,
            "symbol": self.symbol,
            "position": pos.ticket,
            "sl": new_sl,
            "tp": tp,
            "magic": config.MAGIC_NUMBER,
        }
        result = mt5.order_send(request)
        if result is None:
            log.error("SLTP modify returned None for ticket=%s", pos.ticket)
            return
        if result.retcode == mt5.TRADE_RETCODE_DONE:
            log.info("SL UPDATED: ticket=%s SL=%.3f (profit=%.1f pts)",
                     pos.ticket, new_sl, profit_pts)
        else:
            log.warning("SLTP modify failed ticket=%s retcode=%s",
                        pos.ticket, result.retcode)
