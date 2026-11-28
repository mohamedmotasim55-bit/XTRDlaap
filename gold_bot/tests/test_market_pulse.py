import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import indicators, market_pulse


def frame(n=80, vol=100, rng=2.0, start="2026-01-05 09:00"):
    base = pd.Timestamp(start)
    rows = []
    for i in range(n):
        c = 2000.0
        rows.append(dict(time=base + pd.Timedelta(minutes=i), open=c - 0.1,
                         high=c + rng / 2, low=c - rng / 2, close=c,
                         tick_volume=vol))
    return indicators.add_indicators(pd.DataFrame(rows))


class TestPulseColumns(unittest.TestCase):
    def test_columns_present(self):
        d = frame()
        for col in ("pulse_intensity", "effort_vs_result", "tick_accel_buy",
                    "tick_accel_sell", "session_pulse_active"):
            self.assertIn(col, d.columns)

    def test_pulse_intensity_surge(self):
        d = frame(80, vol=100)
        d.loc[d.index[-1], "tick_volume"] = 400
        d = market_pulse.add_pulse(d)
        self.assertGreater(d["pulse_intensity"].iloc[-1], 2.5)

    def test_effort_vs_result_uses_body(self):
        d = frame(80, vol=100)
        d.loc[d.index[-1], "tick_volume"] = 400
        d.loc[d.index[-1], ["open", "high", "low", "close"]] = [2000.0, 2001.0, 1999.0, 2000.02]
        d = market_pulse.add_pulse(d)
        self.assertGreater(d["effort_vs_result"].iloc[-1], 2.2)
        d2 = frame(80, vol=100)
        d2.loc[d2.index[-1], "tick_volume"] = 120
        d2.loc[d2.index[-1], ["open", "high", "low", "close"]] = [1999.0, 2001.0, 1998.9, 2001.0]
        d2 = market_pulse.add_pulse(d2)
        self.assertLess(d2["effort_vs_result"].iloc[-1], 1.3)

    def test_effort_vs_result_high_on_small_range(self):
        d = frame(80, vol=100)
        d.loc[d.index[-1], "tick_volume"] = 400
        d.loc[d.index[-1], ["open", "high", "low", "close"]] = [2000.0, 2000.1, 1999.9, 2000.05]
        d = market_pulse.add_pulse(d)
        self.assertGreater(d["effort_vs_result"].iloc[-1], 2.0)

    def test_session_window(self):
        d = frame(40, start="2026-01-05 22:00")
        self.assertEqual(int(d["session_pulse_active"].iloc[-1]), 0)
        d2 = frame(40, start="2026-01-05 10:00")
        self.assertEqual(int(d2["session_pulse_active"].iloc[-1]), 1)

    def test_low_atr_session_off(self):
        d = frame(40, rng=0.2)
        self.assertEqual(int(d["session_pulse_active"].iloc[-1]), 0)


class TestPulseContext(unittest.TestCase):
    def test_snapshot_fields(self):
        d = frame(80)
        ctx = market_pulse.PulseContext(d, d, d)
        self.assertGreater(ctx.pulse, 0.0)
        self.assertGreater(ctx.atr_points, 80.0)
        self.assertTrue(ctx.session_active)
        self.assertIsNotNone(ctx.point)

    def test_limit_price_improves_entry(self):
        d = frame(80)
        ctx = market_pulse.PulseContext(d, d, d)
        self.assertLess(ctx.limit_price("BUY"), ctx.close)
        self.assertGreater(ctx.limit_price("SELL"), ctx.close)


if __name__ == "__main__":
    unittest.main(verbosity=2)
