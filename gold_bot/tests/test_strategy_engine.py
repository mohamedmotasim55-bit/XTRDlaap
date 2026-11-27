import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import indicators, strategy_engine, config
config.ENABLED_STRATEGIES = list(config.LEGACY_STRATEGIES)  # tests cover all engines

def base_df(n=60):
    rows=[]
    for i in range(n):
        c=2000.0+0.1*i
        rows.append(dict(time=i, open=c-0.05, high=c+0.3, low=c-0.3, close=c, tick_volume=100+i))
    return indicators.add_indicators(pd.DataFrame(rows), point=0.01)

def m5_flat():
    d=pd.DataFrame([dict(open=2000.0,high=2000.2,low=1999.8,close=2000.0,tick_volume=100)
                    for _ in range(60)])
    d["m5_adx_14"]=10.0; d["m5_ema_21"]=2000.0; d["m5_ema_50"]=2000.0
    return d

def force_last(df, **kw):
    d=df.copy()
    idx=d.index[-1]
    for k,v in kw.items():
        d.loc[idx,k]=v
    return d

class TestStrategy(unittest.TestCase):
    def setUp(self):
        self.df=base_df(60)

    def test_rule0_low_atr(self):
        d=force_last(self.df, atr_14=0.20, atr_points=20.0)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM)
        self.assertEqual(s.signal,"NONE")
        self.assertIn("ATR", s.reason)

    def test_momentum_breakout_buy(self):
        d=force_last(self.df, open=2005, high=2010.5, low=2004.5, close=2010, tick_volume=500,
                     ema_9=2006, ema_21=2004, ema_50=2000, bb_upper=2009, bb_lower=1990, bb_mid=2000,
                     rsi_7=70, atr_14=0.5, atr_points=50, vol_ma_10=300,
                     swing_high_15=2008, swing_low_15=1995)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM)
        self.assertEqual(s.signal,"BUY"); self.assertEqual(s.strategy,"MomentumBreakout")
        self.assertAlmostEqual(s.sl, 2010-0.45, places=3)   # MIN_SL_POINTS clamp
        self.assertAlmostEqual(s.tp, 2010+1.30, places=3)   # MIN_TP_POINTS clamp

    def test_momentum_breakout_sell(self):
        d=force_last(self.df, open=2005, high=2005.5, low=2000, close=2000, tick_volume=500,
                     ema_9=2004, ema_21=2006, ema_50=2010, bb_upper=2020, bb_lower=2001, bb_mid=2010,
                     rsi_7=30, atr_14=0.5, atr_points=50, vol_ma_10=300,
                     swing_high_15=2008, swing_low_15=1995)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM)
        self.assertEqual(s.signal,"SELL"); self.assertEqual(s.strategy,"MomentumBreakout")
        self.assertAlmostEqual(s.sl, 2000+0.45, places=3)

    def test_liquidity_sweep_buy(self):
        # breakout must fail: close<ema50, rsi not in 60..82, vol not> vol_ma
        d=force_last(self.df, open=1996, high=1998.5, low=1990, close=1998, tick_volume=400,
                     ema_9=1999, ema_21=2000, ema_50=2005, bb_upper=2010, bb_lower=1985, bb_mid=2000,
                     rsi_7=30, atr_14=0.5, atr_points=50, vol_ma_10=300,
                     swing_high_15=2005, swing_low_15=1995)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM)
        self.assertEqual(s.signal,"BUY"); self.assertEqual(s.strategy,"LiquiditySweep")

    def test_liquidity_sweep_sell(self):
        d=force_last(self.df, open=2004, high=2010, low=2001.5, close=2002, tick_volume=400,
                     ema_9=2001, ema_21=2000, ema_50=1995, bb_upper=2015, bb_lower=1990, bb_mid=2000,
                     rsi_7=70, atr_14=0.5, atr_points=50, vol_ma_10=300,
                     swing_high_15=2005, swing_low_15=1995)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM)
        self.assertEqual(s.signal,"SELL"); self.assertEqual(s.strategy,"LiquiditySweep")

    def test_bollinger_bounce_buy(self):
        d=force_last(self.df, open=1990, high=1992.5, low=1988, close=1992, tick_volume=200,
                     ema_9=1995, ema_21=1998, ema_50=2000, bb_upper=2000, bb_lower=1989.5, bb_mid=1995,
                     rsi_7=20, atr_14=0.5, atr_points=50, vol_ma_10=100,
                     adx_14=15, swing_high_15=2005, swing_low_15=1985,
                     swing_high_8=2030, swing_low_8=1980)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_ASIAN, m5_flat())
        self.assertEqual(s.signal,"BUY"); self.assertEqual(s.strategy,"BollingerBounce")
        self.assertAlmostEqual(s.sl, 1992-0.45, places=3)
        self.assertAlmostEqual(s.tp, 1992+1.30, places=3)

    def test_bollinger_bounce_sell(self):
        d=force_last(self.df, open=2010, high=2012, low=2007.5, close=2008, tick_volume=200,
                     ema_9=2005, ema_21=2002, ema_50=2000, bb_upper=2011, bb_lower=1990, bb_mid=2000,
                     rsi_7=80, atr_14=0.5, atr_points=50, vol_ma_10=100,
                     adx_14=15, swing_high_15=2015, swing_low_15=1990,
                     swing_high_8=2030, swing_low_8=1970)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_ASIAN, m5_flat())
        self.assertEqual(s.signal,"SELL"); self.assertEqual(s.strategy,"BollingerBounce")

    def test_sl_tp_clamp_bounds(self):
        # point = atr/atr_points = 0.01; high ATR -> MAX caps
        sl, tp = strategy_engine._clamp_sl_tp("BUY", 3770.0, 1.5, 150)
        self.assertAlmostEqual(3770 - sl, 0.62, places=2)   # MAX_SL 62 pts
        self.assertAlmostEqual(tp - 3770, 2.10, places=2)   # MAX_TP 210 pts
        # low ATR -> MIN floors (no 5-point stops possible)
        sl2, tp2 = strategy_engine._clamp_sl_tp("SELL", 3770.0, 0.4, 40)
        self.assertAlmostEqual(sl2 - 3770, 0.45, places=2)  # MIN_SL 45 pts
        self.assertAlmostEqual(3770 - tp2, 1.30, places=2)  # MIN_TP 130 pts

    def test_stop_mode_none(self):
        d=force_last(self.df, atr_14=0.5, atr_points=50)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_STOP)
        self.assertEqual(s.signal,"NONE")

    def test_insufficient_data(self):
        s=strategy_engine.generate_signal(base_df(10), config.SESSION_MODE_MOMENTUM)
        self.assertEqual(s.signal,"NONE")

if __name__=="__main__":
    unittest.main(verbosity=2)
