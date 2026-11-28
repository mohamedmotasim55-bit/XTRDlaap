"""Market-adaptive trailing: ladder + squeeze lock + trend breathing."""
from __future__ import annotations


def lock_points(direction, profit_points, atr_points, rsi, rsi_prev,
                vol, vol_ma, adx):
    lock = None
    if profit_points >= 145:
        lock = 90.0
    elif profit_points >= 75:
        lock = 40.0
    elif profit_points >= 32:
        lock = 10.0

    if profit_points >= 55:
        hooked = (rsi is not None and rsi_prev is not None and (
            (direction == "BUY" and rsi < rsi_prev)
            or (direction == "SELL" and rsi > rsi_prev)))
        dried = vol is not None and vol_ma is not None and vol < 0.7 * vol_ma
        if hooked or dried:
            lock = max(lock or 0.0, profit_points - 8.0)

    if adx is not None and adx > 25 and vol is not None and vol_ma is not None \
            and vol > vol_ma and atr_points:
        lock = max(lock or 0.0, profit_points - 0.75 * atr_points)

    return lock
