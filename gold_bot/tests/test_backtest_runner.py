import os, sys, tempfile, unittest
import numpy as np, pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from backtest_runner import BacktestRunner

def synth(n=260, start=2000.0):
    rows=[]
    px=start
    rng=np.random.default_rng(7)
    t=pd.Timestamp("2026-06-02 10:00:00")
    for i in range(n):
        px += rng.normal(0, 0.6)
        o=px+rng.normal(0,0.1); c=px
        h=max(o,c)+abs(rng.normal(0,0.4)); l=min(o,c)-abs(rng.normal(0,0.4))
        rows.append(dict(time=t+pd.Timedelta(minutes=i), open=o, high=h, low=l,
                         close=c, tick_volume=int(100+abs(rng.normal(0,50)))))
    return pd.DataFrame(rows)

class TestBacktest(unittest.TestCase):
    def test_runs_and_reports(self):
        d=tempfile.mkdtemp()
        r=BacktestRunner(synth(260), journal_path=os.path.join(d,"bt.csv"),
                         spread_points=26.0, point=0.01)
        res=r.run()
        for k in ["initial_balance","final_balance","total_trades","win_rate",
                  "profit_factor","max_drawdown_usd","by_strategy"]:
            self.assertIn(k,res)
        self.assertAlmostEqual(res["initial_balance"],10.0,places=2)
        self.assertTrue(os.path.exists(os.path.join(d,"bt.csv")))

if __name__=="__main__":
    unittest.main(verbosity=2)
