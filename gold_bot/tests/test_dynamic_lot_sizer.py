import os, sys, unittest
from types import SimpleNamespace
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from dynamic_lot_sizer import DynamicLotSizer

class FakeMT5:
    ORDER_TYPE_BUY = 0
    def __init__(self, margin_per_lot=None, vmin=0.01, vstep=0.01, vmax=100.0):
        self.margin_per_lot = margin_per_lot
        self.vmin, self.vstep, self.vmax = vmin, vstep, vmax
    def symbol_info(self, s):
        return SimpleNamespace(volume_min=self.vmin, volume_step=self.vstep,
                               volume_max=self.vmax)
    def order_calc_margin(self, t, s, v, p):
        if self.margin_per_lot is not None:
            return self.margin_per_lot * v
        return v * 100

class TestDynamicLotSizer(unittest.TestCase):
    def test_micro_tier(self):
        s = DynamicLotSizer(mt5_module=None)
        for eq in (8.0, 10.0, 15.0, 17.99):
            self.assertAlmostEqual(s.size(eq, eq), 0.01, places=2)

    def test_growth_scaling(self):
        s = DynamicLotSizer(mt5_module=None)
        cases = {18.0: 0.02, 28.0: 0.03, 40.0: 0.04, 55.0: 0.05, 75.0: 0.06}
        for eq, want in cases.items():
            self.assertAlmostEqual(s.size(eq, eq), want, places=2, msg=f"eq={eq}")

    def test_cap(self):
        s = DynamicLotSizer(mt5_module=None)
        self.assertAlmostEqual(s.size(5000.0, 5000.0), config.MAX_LOT_SIZE, places=2)

    def test_drawdown_throttle(self):
        s = DynamicLotSizer(mt5_module=None)
        base = DynamicLotSizer.base_lot(80.0)          # 0.06
        throttled = s.size(80.0, peak_equity=100.0)    # 80 < 92 -> halve
        self.assertTrue(s.throttled)
        self.assertLess(throttled, base)

    def test_throttle_recovery(self):
        s = DynamicLotSizer(mt5_module=None)
        s.size(80.0, peak_equity=100.0)
        self.assertTrue(s.throttled)
        s.size(98.0, peak_equity=100.0)                # >= 97 -> recover
        self.assertFalse(s.throttled)

    def test_margin_guard_steps_down(self):
        fake = FakeMT5(margin_per_lot=5000.0)
        s = DynamicLotSizer(mt5_module=fake, symbol="XAUUSD")
        lot = s.size(100.0, 100.0, price=2000.0)
        self.assertAlmostEqual(lot, 0.01, places=2)
        self.assertIn("margin guard", s.last_reason)

if __name__ == "__main__":
    unittest.main(verbosity=2)
