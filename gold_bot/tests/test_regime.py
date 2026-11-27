import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import indicators, regime_detector as rd

def base_df(n=60):
    rows=[]
    for i in range(n):
        c=2000.0+0.1*i
        rows.append(dict(open=c-0.05,high=c+0.3,low=c-0.3,close=c,tick_volume=100+i))
    return indicators.add_indicators(pd.DataFrame(rows), point=0.01)

def force_last(df, **kw):
    d=df.copy(); idx=d.index[-1]
    for k,v in kw.items(): d.loc[idx,k]=v
    return d

def m5(trend):
    rows=[]
    for i in range(60):
        c=2000.0+(0.5*i if trend>0 else -0.5*i)
        rows.append(dict(open=c-0.05,high=c+0.3,low=c-0.3,close=c,tick_volume=100))
    return pd.DataFrame(rows)

class TestRegime(unittest.TestCase):
    def test_trend_up(self):
        d=force_last(base_df(), adx_14=30, atr_points=60, ema_21=2005, ema_50=2000)
        r=rd.RegimeDetector.classify(d, m5(+1))
        self.assertEqual(r.regime, rd.REGIME_TREND_UP)
        self.assertTrue(r.is_trending)

    def test_trend_down(self):
        d=force_last(base_df(), adx_14=30, atr_points=60, ema_21=1995, ema_50=2000)
        r=rd.RegimeDetector.classify(d, m5(-1))
        self.assertEqual(r.regime, rd.REGIME_TREND_DOWN)

    def test_ranging(self):
        d=force_last(base_df(), adx_14=15, atr_points=60, ema_21=2000, ema_50=2000)
        r=rd.RegimeDetector.classify(d, m5(+1))
        self.assertEqual(r.regime, rd.REGIME_RANGING)

    def test_volatile_spike(self):
        d=force_last(base_df(), adx_14=15, atr_points=500, ema_21=2000, ema_50=2000)
        r=rd.RegimeDetector.classify(d, m5(+1))
        self.assertEqual(r.regime, rd.REGIME_VOLATILE)

if __name__=="__main__":
    unittest.main(verbosity=2)
