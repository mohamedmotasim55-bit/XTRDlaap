import os, sys, unittest
import numpy as np, pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import indicators

def base_df(n=60):
    rows=[]
    for i in range(n):
        c=2000.0+0.1*i
        rows.append(dict(time=i, open=c-0.05, high=c+0.3, low=c-0.3, close=c, tick_volume=100+i))
    return pd.DataFrame(rows)

class TestIndicators(unittest.TestCase):
    def setUp(self):
        self.df=indicators.add_indicators(base_df(60), point=0.01)

    def test_columns_present(self):
        for c in ["ema_9","ema_21","ema_50","rsi_7","bb_mid","bb_upper","bb_lower",
                  "bb_width","atr_14","atr_points","vol_ma_10","swing_high_15","swing_low_15"]:
            self.assertIn(c, self.df.columns)

    def test_bb_ordering(self):
        d=self.df.dropna(subset=["bb_lower","bb_mid","bb_upper"])
        self.assertTrue((d["bb_lower"]<=d["bb_mid"]).all())
        self.assertTrue((d["bb_mid"]<=d["bb_upper"]).all())

    def test_rsi_bounds(self):
        r=self.df["rsi_7"].dropna()
        self.assertTrue((r>=0).all() and (r<=100).all())

    def test_atr_points_relation(self):
        d=self.df.dropna(subset=["atr_14","atr_points"])
        np.testing.assert_allclose(d["atr_points"].values, d["atr_14"].values/0.01, rtol=1e-9)

    def test_swing_shift(self):
        # swing_high_15 at index i must equal max(high[i-15:i]) (previous 15 closed candles)
        highs=self.df["high"].values
        i=40
        self.assertAlmostEqual(self.df["swing_high_15"].iloc[i], max(highs[i-15:i]))
        lows=self.df["low"].values
        self.assertAlmostEqual(self.df["swing_low_15"].iloc[i], min(lows[i-15:i]))

    def test_ema_positive(self):
        self.assertTrue((self.df["ema_9"].dropna()>0).all())

if __name__=="__main__":
    unittest.main(verbosity=2)
