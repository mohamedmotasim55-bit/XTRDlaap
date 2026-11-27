"""Market-adaptive trailing for the 32-strategy scalp engine."""
from __future__ import annotations


def lock_points(direction, profit_points, atr_points, rsi, rsi_prev,
                vol, vol_ma, adx):
    """Return the SL lock distance in points, or None when nothing triggers."""
    lock = None
    if profit_points >= 160:
        lock = 100.0
    elif profit_points >= 90:
        lock = 45.0
    elif profit_points >= 38:
        lock = 12.0

    if profit_points >= 65:
        hooked = (rsi is not None and rsi_prev is not None and (
            (direction == "BUY" and rsi < rsi_prev)
            or (direction == "SELL" and rsi > rsi_prev)))
        dried_up = vol is not None and vol_ma is not None and vol < 0.7 * vol_ma
        if hooked or dried_up:
            lock = max(lock or 0.0, profit_points - 8.0)

    if adx is not None and adx > 25 and vol is not None and vol_ma is not None \
            and vol > vol_ma and atr_points:
        lock = max(lock or 0.0, profit_points - 0.75 * atr_points)

    return lock
