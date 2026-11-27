import os, sys, tempfile, unittest
from datetime import datetime
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from analytics_logger import AnalyticsLogger

def make():
    d=tempfile.mkdtemp()
    return AnalyticsLogger(journal_path=os.path.join(d,"j.csv"))

class TestAnalytics(unittest.TestCase):
    def test_metrics_and_pf(self):
        a=make()
        a.log_open(1,"MomentumBreakout","MOMENTUM","BUY",2000,1999,2001)
        a.log_close(1,2001.2,1.20,120,"TP")
        a.log_open(2,"LiquiditySweep","MOMENTUM","SELL",2000,2001,1998)
        a.log_close(2,1999.5,0.50,50,"TP")
        a.log_open(3,"BollingerBounce","ASIAN_RANGE","BUY",2000,1999,2001)
        a.log_close(3,1999.4,-0.60,-60,"SL")
        m=a.metrics()
        self.assertEqual(m["total"],3)
        self.assertEqual(m["wins"],2)
        self.assertEqual(m["losses"],1)
        self.assertAlmostEqual(m["win_rate"],66.666,places=2)
        self.assertAlmostEqual(m["net"],1.10,places=2)
        self.assertAlmostEqual(m["pf"],1.70/0.60,places=4)
        self.assertIn("MomentumBreakout",m["by_strategy"])

    def test_consecutive_loss_cooldown(self):
        a=make()
        for i in range(3):
            a.log_open(10+i,"MomentumBreakout","MOMENTUM","BUY",2000,1999,2001)
            a.log_close(10+i,1999.5,-0.50,-50,"SL")
        self.assertEqual(a.consecutive_losses(),3)
        self.assertEqual(a.metrics()["max_consec_losses"],3)
        self.assertTrue(a.in_loss_cooldown())
        a.log_open(99,"MomentumBreakout","MOMENTUM","BUY",2000,1999,2001)
        a.log_close(99,2001.2,1.2,120,"TP")
        self.assertEqual(a.consecutive_losses(),0)

    def test_journal_file(self):
        a=make()
        a.log_open(1,"MomentumBreakout","MOMENTUM","BUY",2000,1999,2001)
        a.log_close(1,2001.2,1.2,120,"TP")
        self.assertTrue(os.path.exists(a.path))
        with open(a.path) as fh:
            lines=fh.read().strip().splitlines()
        self.assertGreaterEqual(len(lines),2)  # header + open + close

    def test_summary_runs(self):
        a=make()
        a.log_open(1,"MomentumBreakout","MOMENTUM","BUY",2000,1999,2001)
        a.log_close(1,2001.2,1.2,120,"TP")
        a.print_summary()  # must not raise

if __name__=="__main__":
    unittest.main(verbosity=2)
