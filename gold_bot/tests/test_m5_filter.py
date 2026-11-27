import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config, indicators, strategy_engine

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
        c=2000.0+ (0.5*i if trend>0 else -0.5*i)
        rows.append(dict(open=c-0.05,high=c+0.3,low=c-0.3,close=c,tick_volume=100))
    return pd.DataFrame(rows)

class TestM5Filter(unittest.TestCase):
    def _buy_setup(self):
        return force_last(base_df(), open=2005, high=2010.5, low=2004.5, close=2010,
            tick_volume=500, ema_9=2006, ema_21=2004, ema_50=2000, bb_upper=2009,
            bb_lower=1990, bb_mid=2000, rsi_7=70, atr_14=0.5, atr_points=50,
            vol_ma_10=300, swing_high_15=2008, swing_low_15=1995)

    def test_m5_aligned_allows_buy(self):
        s=strategy_engine.generate_signal(self._buy_setup(), config.SESSION_MODE_MOMENTUM, m5(+1))
        self.assertEqual(s.signal,"BUY")
        self.assertEqual(s.strategy,"MomentumBreakout")

    def test_m5_against_blocks_buy(self):
        s=strategy_engine.generate_signal(self._buy_setup(), config.SESSION_MODE_MOMENTUM, m5(-1))
        self.assertEqual(s.signal,"NONE")

if __name__=="__main__":
    unittest.main(verbosity=2)
