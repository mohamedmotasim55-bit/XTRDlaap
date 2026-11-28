import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config, dynamic_target_engine as dte
from backtest_runner import BacktestRunner


class TestTargets(unittest.TestCase):
    def test_sl_range(self):
        for atr in (60, 100, 200):
            sl = dte.select_targets(2.0, atr)["sl_points"]
            self.assertTrue(52.0 <= sl <= 68.0)

    def test_tp_range_and_rr(self):
        for pulse in (1.1, 1.6, 2.2, 3.2, 4.0):
            t = dte.select_targets(pulse, 110)
            self.assertTrue(145.0 <= t["tp_points"] <= 360.0)
            self.assertTrue(2.5 - 1e-6 <= t["tp_points"] / t["sl_points"] <= 5.2 + 1e-6)

    def test_alignment_and_consensus_add(self):
        base = dte.select_targets(1.8, 110)
        boosted = dte.select_targets(1.8, 110, m5_aligned=True, consensus=3)
        self.assertGreaterEqual(boosted["tp_points"], base["tp_points"])

    def test_be_and_timeout(self):
        t = dte.select_targets(2.0, 110)
        self.assertEqual(t["be_trigger"], 32.0)
        self.assertEqual(t["be_lock"], 10.0)
        self.assertEqual(t["max_hold_minutes"], 50)


class TestScalpTimeout(unittest.TestCase):
    def test_expiry_after_50_minutes(self):
        pos = dict(open_time=pd.Timestamp("2026-01-05 10:00"), max_hold_minutes=50)
        self.assertFalse(BacktestRunner._scalp_expired(pos, pd.Timestamp("2026-01-05 10:49")))
        self.assertTrue(BacktestRunner._scalp_expired(pos, pd.Timestamp("2026-01-05 10:50")))

    def test_no_timeout_when_unset(self):
        pos = dict(open_time=pd.Timestamp("2026-01-05 10:00"), max_hold_minutes=0)
        self.assertFalse(BacktestRunner._scalp_expired(pos, pd.Timestamp("2026-01-06 10:00")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
