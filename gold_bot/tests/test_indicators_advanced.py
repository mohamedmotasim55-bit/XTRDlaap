import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import indicators

def base_df(n=60):
    rows=[]
    for i in range(n):
        c=2000.0+0.1*i
        rows.append(dict(open=c-0.05,high=c+0.3,low=c-0.3,close=c,tick_volume=100+i))
    return pd.DataFrame(rows)

class TestAdvancedIndicators(unittest.TestCase):
    def setUp(self):
        self.df=indicators.add_indicators(base_df(60), point=0.01)

    def test_new_columns(self):
        for c in ["ema_5","ema_13","macd_line","macd_signal","macd_hist",
                  "stoch_k","stoch_d","adx_14","fvg_bull","fvg_bear"]:
            self.assertIn(c, self.df.columns)

    def test_stoch_bounds(self):
        s=self.df["stoch_k"].dropna()
        self.assertTrue((s>=-1e-6).all() and (s<=100+1e-6).all())

    def test_adx_nonneg(self):
        a=self.df["adx_14"].dropna()
        self.assertTrue((a>=0).all())

    def test_fvg_bull_detected(self):
        d=pd.DataFrame([
            dict(open=2000,high=2000.5,low=1999.5,close=2000),
            dict(open=2000,high=2000.6,low=1999.8,close=2000.4),
            dict(open=2002,high=2002.6,low=2001.5,close=2002.2),  # low 2001.5 > high[-2] 2000.5
        ])
        out=indicators.add_indicators(d, point=0.01)
        self.assertEqual(int(out["fvg_bull"].iloc[-1]),1)

    def test_fvg_bear_detected(self):
        d=pd.DataFrame([
            dict(open=2000,high=2000.5,low=1999.5,close=2000),
            dict(open=2000,high=2000.4,low=1999.7,close=1999.8),
            dict(open=1998,high=1998.4,low=1997.5,close=1997.8),  # high 1998.4 < low[-2] 1999.7
        ])
        out=indicators.add_indicators(d, point=0.01)
        self.assertEqual(int(out["fvg_bear"].iloc[-1]),1)

if __name__=="__main__":
    unittest.main(verbosity=2)
