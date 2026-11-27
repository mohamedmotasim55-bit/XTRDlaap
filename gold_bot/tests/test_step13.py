import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import alpha_lab, backtest_runner, config, indicators, strategy_engine


def m1_df(n=60, start="2026-01-05 08:00", **last):
    base = pd.Timestamp(start)
    rows = []
    for i in range(n):
        c = 2000.0 + 0.1 * i
        rows.append(dict(time=base + pd.Timedelta(minutes=i), open=c - 0.05,
                         high=c + 0.3, low=c - 0.3, close=c, tick_volume=100))
    d = indicators.add_indicators(pd.DataFrame(rows), point=0.01)
    if last:
        d = d.copy()
        for k, v in last.items():
            d.loc[d.index[-1], k] = v
    return d


def m5_df(**last):
    d = pd.DataFrame([dict(open=2000.0, high=2001.0, low=1999.0, close=2000.0,
                           tick_volume=100) for _ in range(60)])
    d["m5_ema_21"] = 2000.0
    d["m5_ema_50"] = 1999.0
    d["m5_adx_14"] = 30.0
    d["m5_ema21_slope"] = 0.1
    d["m5_vwap_upper"] = 2003.0
    d["m5_vwap_lower"] = 1999.0
    for col in ("m5_ob_bull", "m5_ob_bear", "fvg_bull", "fvg_bear"):
        d[col] = 0
    for k, v in last.items():
        d.loc[d.index[-1], k] = v
    return d


def m15_df(**last):
    d = pd.DataFrame([dict(open=2000.0, high=2001.0, low=1999.0, close=2000.0,
                           tick_volume=100) for _ in range(30)])
    d["ema_21"] = 2000.0
    d["ema_50"] = 1999.0
    d["adx_14"] = 15.0
    d["rsi_7"] = 50.0
    d["swing_high_12"] = 2010.0
    d["swing_low_12"] = 1990.0
    for k, v in last.items():
        d.loc[d.index[-1], k] = v
    return d


def sig_for(model, d, m5=None, m15=None):
    old = config.ENABLED_STRATEGIES
    config.ENABLED_STRATEGIES = (model,)
    try:
        return strategy_engine.generate_signal(
            d, config.SESSION_MODE_MOMENTUM, m5, df_m15=m15)
    finally:
        config.ENABLED_STRATEGIES = old


class TestLimits(unittest.TestCase):
    def test_limit_offset_clamped_to_16(self):
        p = strategy_engine._limit_entry("BUY", 2000.0, 2002.0, 1998.0, 0.5, 50)
        self.assertAlmostEqual(p, 1999.84, places=4)

    def test_limit_offset_floor_12(self):
        p = strategy_engine._limit_entry("SELL", 2000.0, 2000.1, 1999.9, 0.5, 50)
        self.assertAlmostEqual(p, 2000.12, places=4)

    def test_limit_hit_semantics(self):
        self.assertTrue(backtest_runner._limit_hit("BUY", 1999.5, 1999.0, 2001.0))
        self.assertFalse(backtest_runner._limit_hit("BUY", 1999.5, 1999.6, 2001.0))
        self.assertTrue(backtest_runner._limit_hit("SELL", 2000.5, 1999.0, 2000.6))
        self.assertFalse(backtest_runner._limit_hit("SELL", 2000.5, 1999.0, 2000.4))


class TestResample(unittest.TestCase):
    def test_m15_resample_ohlcv(self):
        rows = [dict(time=pd.Timestamp("2026-01-05 08:00") + pd.Timedelta(minutes=i),
                     open=1.0, high=2.0, low=0.5, close=1.5, tick_volume=10)
                for i in range(45)]
        g = backtest_runner.BacktestRunner._resample_m15(pd.DataFrame(rows))
        self.assertEqual(len(g), 3)
        self.assertAlmostEqual(g["open"].iloc[0], 1.0)
        self.assertAlmostEqual(g["high"].iloc[0], 2.0)
        self.assertAlmostEqual(g["low"].iloc[0], 0.5)
        self.assertAlmostEqual(g["tick_volume"].iloc[0], 150)


class TestEightModels(unittest.TestCase):
    def test_model_1_momentum_limit(self):
        d = m1_df(open=2000, high=2001.2, low=1999.8, close=2001,
                  tick_volume=300, vol_ma_10=100, atr_14=0.5, atr_points=100)
        s = sig_for("M1_M5_MomentumLimit", d, m5_df(close=2001), m15_df())
        self.assertEqual(s.strategy, "M1_M5_MomentumLimit")
        self.assertEqual(s.entry_type, "LIMIT")
        self.assertLess(s.limit_price, s.entry)
        self.assertIn(s.tier, ("T1", "T2", "T3"))
        self.assertEqual(s.max_hold_minutes, 40)
        self.assertGreaterEqual(s.tp_points, 85.0)

    def test_model_2_session_open(self):
        d = m1_df(open=2000, high=2001.3, low=2000, close=2001,
                  atr_14=0.5, atr_points=100, tick_volume=200)
        s = sig_for("SessionOpenExpansion", d, m5_df(close=2001), m15_df())
        self.assertEqual(s.strategy, "SessionOpenExpansion")
        self.assertEqual(s.entry_type, "LIMIT")

    def test_model_3_m15_sweep(self):
        d = m1_df(open=1996, high=1998.5, low=1990, close=1998,
                  tick_volume=300, vol_ma_10=100, atr_14=0.5, atr_points=100)
        s = sig_for("M15_LiquiditySweep_M1Trigger", d, m5_df(),
                    m15_df(swing_low_12=1995.0))
        self.assertEqual(s.strategy, "M15_LiquiditySweep_M1Trigger")
        self.assertEqual(s.signal, "BUY")
        self.assertEqual(s.entry_type, "MARKET")

    def test_model_4_order_block(self):
        d = m1_df(open=1996, high=2001, low=1998, close=2000, atr_14=0.5, atr_points=100)
        s = sig_for("M5_OrderBlock_Retest", d, m5_df(m5_ob_bull=1, high=1999, low=1995),
                    m15_df())
        self.assertEqual(s.strategy, "M5_OrderBlock_Retest")
        self.assertEqual(s.signal, "BUY")

    def test_model_5_vwap_magnet(self):
        d = m1_df(open=1996, high=2000.5, low=1998, close=2000, rsi_7=30,
                  atr_14=0.5, atr_points=50)
        s = sig_for("VWAP_SessionMagnet", d, m5_df(m5_vwap_lower=1999.0),
                    m15_df(adx_14=15.0))
        self.assertEqual(s.strategy, "VWAP_SessionMagnet")
        self.assertEqual(s.signal, "BUY")

    def test_model_6_tick_velocity(self):
        d = m1_df(open=2000, high=2001.2, low=2000, close=2001,
                  tick_volume=300, vol_ma_10=100, atr_14=0.5, atr_points=100)
        s = sig_for("TickVelocitySurge", d, m5_df(close=2001), m15_df())
        self.assertEqual(s.strategy, "TickVelocitySurge")
        self.assertEqual(s.entry_type, "LIMIT")

    def test_model_7_fvg_fill(self):
        d = m1_df(open=1996, high=2001, low=1998, close=2000, atr_14=0.5, atr_points=50)
        s = sig_for("FVG_InstitutionalFill", d, m5_df(fvg_bull=1, high=1999, low=1995),
                    m15_df())
        self.assertEqual(s.strategy, "FVG_InstitutionalFill")
        self.assertEqual(s.signal, "BUY")

    def test_model_8_london_fix(self):
        d = m1_df(60, start="2026-01-05 15:00", open=2000, high=1999.5,
                  low=1998.5, close=1999, atr_14=0.5, atr_points=50)
        s = sig_for("LondonFixReversal", d, m5_df(), m15_df(rsi_7=85.0))
        self.assertEqual(s.strategy, "LondonFixReversal")
        self.assertEqual(s.signal, "SELL")


class TestAlphaLab(unittest.TestCase):
    def test_select_models_thresholds(self):
        res = {
            "A": dict(profit_factor=1.30, max_drawdown_pct=20.0, total_trades=10),
            "B": dict(profit_factor=0.90, max_drawdown_pct=10.0, total_trades=10),
            "C": dict(profit_factor=1.50, max_drawdown_pct=60.0, total_trades=10),
            "D": dict(profit_factor=1.50, max_drawdown_pct=10.0, total_trades=2),
        }
        self.assertEqual(alpha_lab.select_models(res), ["A"])

    def test_split_months(self):
        times = [pd.Timestamp("2026-01-01") + pd.Timedelta(hours=6 * i) for i in range(240)]
        m1 = pd.DataFrame(dict(time=times, open=1, high=1, low=1, close=1, tick_volume=1))
        m5 = m1.copy()
        a, b, m5a, m5b, cut = alpha_lab.split_months(m1, m5, days=30)
        self.assertGreater(len(a), 0)
        self.assertGreater(len(b), 0)
        self.assertTrue(pd.to_datetime(a["time"]).max() < cut)
        self.assertTrue(pd.to_datetime(b["time"]).min() >= cut)
        self.assertEqual(len(m5a), len(a))


if __name__ == "__main__":
    unittest.main(verbosity=2)
