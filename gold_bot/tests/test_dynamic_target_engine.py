import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config, dynamic_target_engine as dte


class TestTargetTiers(unittest.TestCase):
    def test_tier1_quick_scalp(self):
        t = dte.select_targets(0.20)
        self.assertEqual(t["tier"], "T1")
        self.assertTrue(85.0 <= t["tp_points"] <= 130.0)
        self.assertTrue(55.0 <= t["sl_points"] <= 70.0)
        self.assertEqual(t["be_trigger"], 38.0)
        self.assertEqual(t["be_lock"], 10.0)
        self.assertEqual(t["trail_start"], 65.0)

    def test_tier2_momentum(self):
        t = dte.select_targets(0.60)
        self.assertEqual(t["tier"], "T2")
        self.assertTrue(150.0 <= t["tp_points"] <= 250.0)
        self.assertTrue(65.0 <= t["sl_points"] <= 85.0)
        self.assertEqual(t["be_trigger"], 45.0)
        self.assertEqual(t["be_lock"], 12.0)
        self.assertEqual(t["trail_start"], 110.0)

    def test_tier3_explosive(self):
        t = dte.select_targets(0.90)
        self.assertEqual(t["tier"], "T3")
        self.assertTrue(280.0 <= t["tp_points"] <= 400.0)
        self.assertTrue(75.0 <= t["sl_points"] <= 95.0)
        self.assertEqual(t["be_trigger"], 55.0)
        self.assertEqual(t["be_lock"], 15.0)
        self.assertEqual(t["trail_start"], 180.0)

    def test_boundaries(self):
        self.assertEqual(dte.select_targets(0.4499)["tier"], "T1")
        self.assertEqual(dte.select_targets(0.45)["tier"], "T2")
        self.assertEqual(dte.select_targets(0.75)["tier"], "T2")
        self.assertEqual(dte.select_targets(0.7501)["tier"], "T3")

    def test_max_hold_is_scalp_only(self):
        for score in (0.1, 0.6, 0.95):
            t = dte.select_targets(score)
            self.assertEqual(t["max_hold_minutes"], config.MAX_SCALP_HOLD_MINUTES)
            self.assertEqual(t["max_hold_minutes"], 40)

    def test_tp_monotonic_within_tier(self):
        lo = dte.select_targets(0.10)["tp_points"]
        hi = dte.select_targets(0.40)["tp_points"]
        self.assertGreater(hi, lo)


class TestScore(unittest.TestCase):
    def test_strong_setup_scores_explosive(self):
        score = dte.momentum_score("BUY", 40, 45, 2.0, 3.0, True, True, True)
        self.assertGreater(score, 0.75)
        self.assertEqual(dte.select_targets(score)["tier"], "T3")

    def test_weak_setup_scores_quick(self):
        score = dte.momentum_score("BUY", 10, 12, 0.7, 0.8, False, False, False)
        self.assertLess(score, 0.45)
        self.assertEqual(dte.select_targets(score)["tier"], "T1")

    def test_misaligned_setup_is_penalised(self):
        aligned = dte.momentum_score("BUY", 30, 30, 1.2, 1.5, True, True, True)
        against = dte.momentum_score("BUY", 30, 30, 1.2, 1.5, False, False, False)
        self.assertGreater(aligned, against)


class TestScalpTimeout(unittest.TestCase):
    def test_expiry_after_35_minutes(self):
        import pandas as pd
        from backtest_runner import BacktestRunner
        pos = dict(open_time=pd.Timestamp("2026-01-05 10:00"), max_hold_minutes=40)
        self.assertFalse(BacktestRunner._scalp_expired(pos, pd.Timestamp("2026-01-05 10:39")))
        self.assertTrue(BacktestRunner._scalp_expired(pos, pd.Timestamp("2026-01-05 10:40")))

    def test_no_timeout_when_unset(self):
        import pandas as pd
        from backtest_runner import BacktestRunner
        pos = dict(open_time=pd.Timestamp("2026-01-05 10:00"), max_hold_minutes=0)
        self.assertFalse(BacktestRunner._scalp_expired(pos, pd.Timestamp("2026-01-06 10:00")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
