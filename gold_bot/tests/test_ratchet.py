import os, sys, unittest
from datetime import datetime
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from safety_guard import SafetyGuard

class Stub:
    def server_time(self): return None
    def current_spread_points(self): return 26.0

class TestRatchet(unittest.TestCase):
    def setUp(self):
        self.g=SafetyGuard(Stub())
        self.now=datetime(2026,1,5,12,0)

    def test_below_start_not_locked(self):
        self.assertTrue(self.g.check_profit_ratchet(daily_pnl=2.0, now=self.now))

    def test_peak_then_drop_locks(self):
        self.assertTrue(self.g.check_profit_ratchet(daily_pnl=4.0, now=self.now))
        # 2.0 < 0.7*4.0 = 2.8 -> lock
        self.assertFalse(self.g.check_profit_ratchet(daily_pnl=2.0, now=self.now))
        self.assertTrue(self.g.ratchet_locked)

    def test_hold_above_keep_ratio_ok(self):
        self.assertTrue(self.g.check_profit_ratchet(daily_pnl=4.0, now=self.now))
        self.assertTrue(self.g.check_profit_ratchet(daily_pnl=3.0, now=self.now))  # 3.0 >= 2.8

    def test_reset_new_day(self):
        self.g.check_profit_ratchet(daily_pnl=4.0, now=self.now)
        self.assertFalse(self.g.check_profit_ratchet(daily_pnl=1.0, now=self.now))
        tomorrow=datetime(2026,1,6,9,0)
        self.assertTrue(self.g.check_profit_ratchet(daily_pnl=0.0, now=tomorrow))
        self.assertFalse(self.g.ratchet_locked)

if __name__=="__main__":
    unittest.main(verbosity=2)
