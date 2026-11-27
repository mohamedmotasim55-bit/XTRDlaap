import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import adaptive_trailing, config, dynamic_target_engine, indicators
import strategies
from strategies.base import Ctx


def frames(n=80):
    base = pd.Timestamp("2026-01-05 09:00")
    rows = []
    for i in range(n):
        c = 2000.0 + 0.1 * i
        rows.append(dict(time=base + pd.Timedelta(minutes=i), open=c - 0.05,
                         high=c + 0.3, low=c - 0.3, close=c, tick_volume=100))
    m1 = indicators.add_indicators(pd.DataFrame(rows), point=0.01)
    rows5 = rows[::5]
    m5 = indicators.add_indicators(pd.DataFrame(rows5), point=0.01)
    rows15 = rows[::15]
    m15 = indicators.add_indicators(pd.DataFrame(rows15), point=0.01)
    return m1, m5, m15


class TestRegistry(unittest.TestCase):
    def test_32_unique_names(self):
        self.assertEqual(len(strategies.NAMES), 32)
        self.assertEqual(len(set(strategies.NAMES)), 32)

    def test_names_match_config(self):
        self.assertEqual(tuple(strategies.NAMES), config.STRATEGY_32)

    def test_six_pods_with_expected_sizes(self):
        sizes = {k: len(v) for k, v in strategies.PODS.items()}
        self.assertEqual(sizes, {"momentum": 6, "liquidity": 6, "smc": 5,
                                 "volume": 5, "reversion": 5, "sessions": 5})

    def test_every_strategy_runs_without_error(self):
        m1, m5, m15 = frames()
        ctx = Ctx(m1, m5, m15)
        for name, fn in strategies.ALL:
            out = fn(ctx)
            if out is not None:
                self.assertEqual(out["strategy"], name)
                self.assertIn(out["direction"], ("BUY", "SELL"))
                self.assertIn(out["entry_type"], ("MARKET", "LIMIT"))


class TestConsensus(unittest.TestCase):
    def test_three_agree_forces_tier3(self):
        t = dynamic_target_engine.select_targets(0.20, consensus=3)
        self.assertEqual(t["tier"], "T3")
        self.assertGreaterEqual(t["tp_points"], 280.0)

    def test_two_agree_keeps_tier1(self):
        t = dynamic_target_engine.select_targets(0.20, consensus=2)
        self.assertEqual(t["tier"], "T1")

    def test_consensus_confidence_boost_capped(self):
        m1, m5, m15 = frames()
        old = config.ENABLED_STRATEGIES
        config.ENABLED_STRATEGIES = config.STRATEGY_32
        try:
            import strategy_engine
            sig = strategy_engine.generate_signal(
                m1, config.SESSION_MODE_MOMENTUM, m5, df_m15=m15)
        finally:
            config.ENABLED_STRATEGIES = old
        if sig:
            self.assertLessEqual(sig.confidence_score, 1.0)
            self.assertIn(sig.tier, ("T1", "T2", "T3"))


class TestAdaptiveTrailing(unittest.TestCase):
    def test_profit_ladder(self):
        self.assertEqual(adaptive_trailing.lock_points("BUY", 40, 100, 50, 50, 100, 100, 20), 12.0)
        self.assertEqual(adaptive_trailing.lock_points("BUY", 95, 100, 50, 50, 100, 100, 20), 45.0)
        self.assertEqual(adaptive_trailing.lock_points("BUY", 165, 100, 50, 50, 100, 100, 20), 100.0)

    def test_squeeze_lock_on_rsi_hook(self):
        lock = adaptive_trailing.lock_points("BUY", 70, 100, 45, 55, 100, 100, 20)
        self.assertEqual(lock, 62.0)

    def test_trend_breathing_trail(self):
        lock = adaptive_trailing.lock_points("BUY", 150, 100, 60, 50, 200, 100, 30)
        self.assertEqual(lock, 75.0)

    def test_no_lock_below_threshold(self):
        self.assertIsNone(adaptive_trailing.lock_points("BUY", 20, 100, 50, 50, 100, 100, 15))


if __name__ == "__main__":
    unittest.main(verbosity=2)
