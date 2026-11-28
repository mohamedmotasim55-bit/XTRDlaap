import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import adaptive_trailing, config, dynamic_target_engine, indicators, strategy_engine


def build_climax_frame():
    base = pd.Timestamp("2026-01-05 09:00")
    rows = []
    for i in range(90):
        c = 2000.0 - i * 0.05
        rows.append(dict(time=base + pd.Timedelta(minutes=i), open=c + 0.02,
                         high=c + 0.6, low=c - 0.6, close=c, tick_volume=100))
    c = 2000.0 - 90 * 0.05
    rows.append(dict(time=base + pd.Timedelta(minutes=90), open=c - 0.05,
                     high=c + 0.25, low=c - 0.65, close=c, tick_volume=500))
    return indicators.add_indicators(pd.DataFrame(rows))


class TestDynamicTargets(unittest.TestCase):
    def test_sl_clamped(self):
        self.assertEqual(dynamic_target_engine.select_targets(2.0, 50)["sl_points"], 52.0)
        self.assertEqual(dynamic_target_engine.select_targets(2.0, 500)["sl_points"], 68.0)
        self.assertAlmostEqual(dynamic_target_engine.select_targets(2.0, 100)["sl_points"], 55.0, 1)

    def test_tp_floor_and_cap(self):
        lo = dynamic_target_engine.select_targets(1.0, 80)
        hi = dynamic_target_engine.select_targets(4.0, 80, m5_aligned=True, consensus=3)
        self.assertGreaterEqual(lo["tp_points"], 145.0)
        self.assertLessEqual(hi["tp_points"], 360.0)
        self.assertGreater(hi["tp_points"], lo["tp_points"])

    def test_reward_risk_band(self):
        for pulse in (1.2, 1.8, 2.5, 3.5):
            for atr in (90, 110, 130):
                t = dynamic_target_engine.select_targets(pulse, atr)
                rr = t["tp_points"] / t["sl_points"]
                self.assertGreaterEqual(rr, 2.5 - 1e-6)
                self.assertLessEqual(rr, 5.2 + 1e-6)

    def test_momentum_geometry(self):
        for pulse in (1.5, 2.0, 3.0, 4.0):
            t = dynamic_target_engine.select_targets(pulse, 110, m5_adx=30)
            self.assertTrue(145.0 <= t["tp_points"] <= 360.0)
            self.assertTrue(52.0 <= t["sl_points"] <= 68.0)
            rr = t["tp_points"] / t["sl_points"]
            self.assertTrue(2.5 - 1e-6 <= rr <= 5.2 + 1e-6)

    def test_hold_time(self):
        self.assertEqual(dynamic_target_engine.select_targets(2.0, 100)["max_hold_minutes"], 50)


class TestAdaptiveTrailing(unittest.TestCase):
    def test_ladder(self):
        self.assertEqual(adaptive_trailing.lock_points("BUY", 35, 100, 50, 50, 100, 100, 20), 10.0)
        self.assertEqual(adaptive_trailing.lock_points("BUY", 80, 100, 50, 50, 100, 100, 20), 40.0)
        self.assertEqual(adaptive_trailing.lock_points("BUY", 170, 100, 50, 50, 100, 100, 20), 90.0)

    def test_squeeze(self):
        self.assertEqual(adaptive_trailing.lock_points("BUY", 60, 100, 45, 55, 100, 100, 20), 52.0)

    def test_breathing(self):
        self.assertEqual(adaptive_trailing.lock_points("BUY", 150, 100, 60, 50, 200, 100, 30), 90.0)


class TestRegistry(unittest.TestCase):
    def test_six_winning_dna_engines(self):
        self.assertEqual(len(config.PULSE_MODELS), 6)
        for retired in ("Pulse_LiquiditySweep_Snap", "InstantMomentum_SqueezeBreak",
                        "InstantMomentum_TickAcceleration", "GoldImpulse_PullbackSniper"):
            self.assertNotIn(retired, config.PULSE_MODELS)
        for name in ("Exhaustion_FOMOFade", "M5_VWAP_ElasticAbsorption",
                     "Intraday_Level_RejectionPulse", "MicroKeltner_SnapLimit"):
            self.assertIn(name, config.PULSE_MODELS)


class TestPulseEngines(unittest.TestCase):
    def test_climax_absorption_fires(self):
        df = build_climax_frame()
        old = config.ENABLED_STRATEGIES
        config.ENABLED_STRATEGIES = config.PULSE_MODELS
        try:
            sig = strategy_engine.generate_signal(df, config.SESSION_MODE_MOMENTUM, df, df_m15=df)
        finally:
            config.ENABLED_STRATEGIES = old
        self.assertIsNotNone(sig)
        self.assertIn(sig.strategy, config.PULSE_MODELS)
        self.assertEqual(sig.signal, "BUY")
        self.assertEqual(sig.max_hold_minutes, 50)
        self.assertGreaterEqual(sig.tp_points, 145.0)
        self.assertLessEqual(sig.tp_points, 360.0)

    def test_session_gate_blocks_offhours(self):
        df = build_climax_frame()
        df["time"] = df["time"] + pd.Timedelta(hours=12)
        df = indicators.add_indicators(df)
        old = config.ENABLED_STRATEGIES
        config.ENABLED_STRATEGIES = config.PULSE_MODELS
        try:
            sig = strategy_engine.generate_signal(df, config.SESSION_MODE_MOMENTUM, df, df_m15=df)
        finally:
            config.ENABLED_STRATEGIES = old
        self.assertEqual(sig.signal, "NONE")


if __name__ == "__main__":
    unittest.main(verbosity=2)
