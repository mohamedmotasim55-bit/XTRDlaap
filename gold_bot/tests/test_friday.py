import os, sys, unittest
from datetime import datetime, time, timedelta
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from safety_guard import SafetyGuard

class Stub:
    def server_time(self): return None
    def current_spread_points(self): return 26.0

def first_friday():
    d=datetime(2026,1,1)
    while d.weekday()!=4:
        d+=timedelta(days=1)
    return d

def at(dt, h, m):
    return datetime(dt.year, dt.month, dt.day, h, m)

class TestFriday(unittest.TestCase):
    def setUp(self):
        self.g=SafetyGuard(Stub())
        self.fri=first_friday()

    def test_friday_normal_before_stop(self):
        self.assertEqual(self.g.check_session(at(self.fri,19,0)), config.SESSION_MODE_MOMENTUM)

    def test_friday_stop(self):
        self.assertEqual(self.g.check_session(at(self.fri,19,30)), config.SESSION_MODE_STOP)

    def test_friday_weekend_close(self):
        self.assertEqual(self.g.check_session(at(self.fri,20,15)), config.SESSION_MODE_WEEKEND_CLOSE)

    def test_saturday_sleep(self):
        sat=self.fri+timedelta(days=1)
        self.assertEqual(self.g.check_session(at(sat,12,0)), config.SESSION_MODE_WEEKEND_SLEEP)

    def test_sunday_sleep(self):
        sun=self.fri+timedelta(days=2)
        self.assertEqual(self.g.check_session(at(sun,12,0)), config.SESSION_MODE_WEEKEND_SLEEP)

if __name__=="__main__":
    unittest.main(verbosity=2)
