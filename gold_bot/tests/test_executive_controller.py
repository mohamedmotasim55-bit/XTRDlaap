import unittest

import pandas as pd

import config
import executive_controller as ec
import tick_engine as te


class TestExecutiveController(unittest.TestCase):
    def test_base_mode_when_flow_is_weak(self):
        c = ec.ExecutiveController()
        st = c.update(pulse=1.20, spread_points=26.0, equity=10.0)
        self.assertEqual(st["mode"], "BASE")
        self.assertEqual(st["max_slots"], config.MAX_BASE_TRADES)

    def test_high_flow_unlocks_five_slots(self):
        c = ec.ExecutiveController()
        for _ in range(12):
            c.record_trade(1.0)
        st = c.update(pulse=1.80, spread_points=26.0, equity=10.0)
        self.assertEqual(st["mode"], "HIGH_FLOW")
        self.assertEqual(st["max_slots"], config.MAX_EXECUTIVE_SLOTS)
        self.assertEqual(st["cooldown_bars"], 1)
        self.assertTrue(st["shield"])

    def test_wide_spread_blocks_high_flow(self):
        c = ec.ExecutiveController()
        for _ in range(12):
            c.record_trade(1.0)
        st = c.update(pulse=1.80, spread_points=40.0, equity=30.0)
        self.assertEqual(st["mode"], "BASE")
        self.assertFalse(st["shield"])


class TestRealTickFeatures(unittest.TestCase):
    def _bars(self, n=5):
        t0 = pd.Timestamp("2026-09-01 10:00")
        rows = [dict(time=t0 + pd.Timedelta(minutes=i), open=2000, high=2001,
                     low=1999, close=2000) for i in range(n)]
        return pd.DataFrame(rows)

    def test_features_use_real_ticks_and_report_spread(self):
        bars = self._bars()
        t0_ms = int(pd.Timestamp("2026-09-01 10:00").timestamp() * 1000)
        ticks = pd.DataFrame(dict(
            time_msc=[t0_ms + i * 250 for i in range(200)],
            bid=[2000.0 + i * 0.0005 for i in range(200)],
            ask=[2000.26 + i * 0.0005 for i in range(200)],
        ))
        dirs, audit = te.build_bar_tick_features(bars, ticks, point=0.01)
        self.assertEqual(audit["total_ticks"], 200)
        self.assertFalse(audit["synthetic"])
        self.assertAlmostEqual(audit["spread_pts_p50"], 26.0, delta=1.0)
        self.assertLessEqual(audit["median_interval_ms"], 300)
        self.assertEqual(len(dirs), len(bars))

    def test_no_ticks_means_no_signal(self):
        bars = self._bars()
        dirs, audit = te.build_bar_tick_features(bars, None, point=0.01)
        self.assertEqual(audit["total_ticks"], 0)
        self.assertEqual(dirs, [None] * len(bars))
