import os, sys, tempfile, unittest
from datetime import datetime, timezone
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from news_filter import NewsFilter

EVENTS = [
    {"country":"USD","impact":"High","date":"2026-11-27T13:00:00+00:00","title":"US NFP"},
    {"country":"EUR","impact":"High","date":"2026-11-27T13:00:00+00:00","title":"EU CPI"},
    {"country":"USD","impact":"Low","date":"2026-11-27T13:00:00+00:00","title":"US minor"},
]

def make():
    d=tempfile.mkdtemp()
    nf=NewsFilter(cache_path=os.path.join(d,"c.json"), fetcher=lambda: EVENTS)
    nf.refresh(force=True)
    return nf

class TestNewsFilter(unittest.TestCase):
    def test_filter_usd_high_only(self):
        nf=make()
        self.assertEqual(len(nf.events),1)
        self.assertEqual(nf.events[0]["title"],"US NFP")

    def test_danger_before(self):
        nf=make()
        ok,title=nf.is_news_danger_zone(datetime(2026,11,27,12,50,tzinfo=timezone.utc))
        self.assertTrue(ok); self.assertEqual(title,"US NFP")

    def test_danger_after(self):
        nf=make()
        ok,_=nf.is_news_danger_zone(datetime(2026,11,27,13,10,tzinfo=timezone.utc))
        self.assertTrue(ok)

    def test_not_danger(self):
        nf=make()
        ok,_=nf.is_news_danger_zone(datetime(2026,11,27,12,40,tzinfo=timezone.utc))
        self.assertFalse(ok)

    def test_force_close(self):
        nf=make()
        self.assertTrue(nf.should_close_before_news(datetime(2026,11,27,12,56,tzinfo=timezone.utc)))
        self.assertFalse(nf.should_close_before_news(datetime(2026,11,27,12,50,tzinfo=timezone.utc)))

    def test_offline_fallback(self):
        d=tempfile.mkdtemp()
        def boom(): raise RuntimeError("offline")
        nf=NewsFilter(cache_path=os.path.join(d,"c.json"), fetcher=boom)
        nf.refresh(force=True)
        self.assertEqual(nf.events,[])
        ok,_=nf.is_news_danger_zone(datetime.now(timezone.utc))
        self.assertFalse(ok)

if __name__=="__main__":
    unittest.main(verbosity=2)
