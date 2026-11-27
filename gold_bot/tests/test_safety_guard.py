import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from safety_guard import SafetyGuard

class FakeConn:
    def __init__(self, spread):
        self.spread = spread
    def current_spread_points(self):
        return self.spread

class TestSpreadGuard(unittest.TestCase):
    def test_spread_ok_vs_wide_sl(self):
        self.assertTrue(SafetyGuard(FakeConn(26.0)).check_spread(sl_points=105.0))

    def test_spread_blocked_vs_tight_sl(self):
        # 26 > 0.45 * 50 (22.5)
        self.assertFalse(SafetyGuard(FakeConn(26.0)).check_spread(sl_points=50.0))

    def test_spread_blocked_over_max(self):
        self.assertFalse(SafetyGuard(FakeConn(40.0)).check_spread(sl_points=105.0))

    def test_spread_unavailable(self):
        self.assertFalse(SafetyGuard(FakeConn(None)).check_spread())

    def test_spread_ok_without_sl(self):
        self.assertTrue(SafetyGuard(FakeConn(26.0)).check_spread())

if __name__ == "__main__":
    unittest.main(verbosity=2)
