import os, sys, unittest
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config, indicators, strategy_engine
config.ENABLED_STRATEGIES = list(config.ALL_STRATEGIES)  # tests cover all engines

def base_df(n=60):
    rows=[]
    for i in range(n):
        c=2000.0+0.1*i
        rows.append(dict(open=c-0.05,high=c+0.3,low=c-0.3,close=c,tick_volume=100+i))
    return indicators.add_indicators(pd.DataFrame(rows), point=0.01)

def force(df, pos, **kw):
    d=df.copy(); idx=d.index[pos]
    for k,v in kw.items(): d.loc[idx,k]=v
    return d

def m5_flat():
    d=pd.DataFrame([dict(open=2000.0,high=2000.2,low=1999.8,close=2000.0,tick_volume=100)
                    for _ in range(60)])
    d["m5_adx_14"]=10.0; d["m5_ema_21"]=2000.0; d["m5_ema_50"]=2000.0
    return d

def m5(trend):
    rows=[]
    for i in range(60):
        c=2000.0+(0.5*i if trend>0 else -0.5*i)
        rows.append(dict(open=c-0.05,high=c+0.3,low=c-0.3,close=c,tick_volume=100))
    return pd.DataFrame(rows)

# defaults that keep the other strategies quiet
QUIET=dict(adx_14=15, ema_5=2000.0, ema_13=2001.0, ema_21=2002.0, ema_50=1995.0,
           macd_hist=0.0, stoch_k=50.0, stoch_d=50.0,
           fvg_bull=0, fvg_bear=0, rsi_7=50.0, vol_ma_10=1000.0,
           bb_upper=2020.0, bb_lower=1980.0, atr_14=0.5, atr_points=50.0,
           swing_high_8=2030.0, swing_low_8=1970.0)

def q(**kw):
    d=dict(QUIET); d.update(kw); return d

class TestSevenStrategies(unittest.TestCase):
    def test_momentum_breakout(self):
        d=force(base_df(),-1, **q(open=2005,high=2010.5,low=2004.5,close=2010,tick_volume=500,
            ema_9=2006,ema_21=2004,ema_50=2000,bb_upper=2009,bb_lower=1990,
            rsi_7=70,vol_ma_10=300,swing_high_15=2008,swing_low_15=1995))
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM, m5(+1))
        self.assertEqual(s.strategy,"MomentumBreakout")

    def test_liquidity_sweep(self):
        d=force(base_df(),-1, **q(open=1996,high=1998.5,low=1990,close=1998,tick_volume=400,
            ema_9=1999,ema_21=2000,ema_50=2005,bb_upper=2010,bb_lower=1985,
            rsi_7=30,vol_ma_10=300,swing_high_15=2005,swing_low_15=1995))
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM, m5_flat())
        self.assertEqual(s.strategy,"LiquiditySweep")

    def test_bollinger_bounce(self):
        d=force(base_df(),-1, **q(open=1990,high=1992.5,low=1988,close=1992,tick_volume=200,
            ema_9=1995,ema_21=1998,ema_50=2000,bb_upper=2000,bb_lower=1989.5,
            rsi_7=20,vol_ma_10=100,swing_high_15=2005,swing_low_15=1985))
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_ASIAN, m5_flat())
        self.assertEqual(s.strategy,"BollingerBounce")

    def test_rsi_snapback(self):
        d=force(base_df(),-1, **q(open=1990,high=1992,low=1988,close=1991.5,tick_volume=300,
            rsi_7=15,atr_14=0.5,atr_points=50,
            swing_high_15=2010,swing_low_15=1980,bb_upper=2020,bb_lower=1980))
        d=force(d,-3, close=1990.5)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_ASIAN)
        self.assertEqual(s.strategy,"RSISnapback")

    def test_vwap_reversion(self):
        d=force(base_df(),-1, **q(open=1992,high=1994,low=1990,close=1993.5,tick_volume=300,
            rsi_7=30,bb_upper=2020,bb_lower=1980,
            swing_high_15=2010,swing_low_15=1980,
            vwap=2000.0,vwap_upper=2010.0,vwap_lower=1990.5))
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_ASIAN)
        self.assertEqual(s.strategy,"VWAPReversion")

    def test_bollinger_blocked_by_m5_downtrend(self):
        d=force(base_df(),-1, **q(open=1990,high=1992.5,low=1988,close=1992,tick_volume=200,
            bb_upper=2000,bb_lower=1989.5,rsi_7=20,
            swing_high_15=2005,swing_low_15=1985,
            vwap=2000.0,vwap_upper=2010.0,vwap_lower=1980.0))
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_ASIAN, m5(-1))
        self.assertEqual(s.signal,"NONE")

    def test_disabled_strategies_gated(self):
        d=force(base_df(),-1, **q(open=2005,high=2010.5,low=2004.5,close=2010,tick_volume=500,
            ema_9=2006,ema_21=2004,ema_50=2000,bb_upper=2009,bb_lower=1990,
            rsi_7=70,vol_ma_10=300,swing_high_15=2008,swing_low_15=1995))
        saved=config.ENABLED_STRATEGIES
        config.ENABLED_STRATEGIES=("BollingerBounce",)
        try:
            s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM, m5(+1))
            self.assertEqual(s.signal,"NONE")
        finally:
            config.ENABLED_STRATEGIES=saved

    def test_ema_ribbon_pullback(self):
        d=force(base_df(),-1, **q(open=2005,high=2006.5,low=2004.9,close=2006,tick_volume=100,
            adx_14=30,ema_5=2006,ema_13=2005,ema_21=2004,ema_50=2000,
            bb_upper=2010,bb_lower=1990,rsi_7=50,vol_ma_10=1000))
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM, m5(+1))
        self.assertEqual(s.strategy,"EMARibbonPullback")

    def test_fast_macd_cross(self):
        d=force(base_df(),-1, **q(open=1999.8,high=2000.3,low=1999.6,close=2000,tick_volume=100,
            adx_14=15,ema_5=2000,ema_13=2001,ema_21=2002,ema_50=1995,
            macd_hist=0.1,stoch_k=25,stoch_d=24,rsi_7=50,vol_ma_10=1000,
            bb_upper=2010,bb_lower=1990))
        d=force(d,-2, macd_hist=-0.1, stoch_k=20, stoch_d=22)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM, m5(+1))
        self.assertEqual(s.strategy,"FastMACDCross")

    def test_fair_value_gap(self):
        d=force(base_df(),-1, **q(open=2005,high=2006.5,low=2004.5,close=2006,tick_volume=100,
            adx_14=15,ema_5=2000,ema_13=2001,ema_21=2002,ema_50=1995,
            fvg_bull=1,rsi_7=50,vol_ma_10=1000,bb_upper=2010,bb_lower=1990))
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM, m5(+1))
        self.assertEqual(s.strategy,"FairValueGapScalp")

    def test_micro_engulfing(self):
        d=force(base_df(),-1, **q(open=1999,high=2006.5,low=1998.5,close=2006,tick_volume=500,
            adx_14=15,ema_5=2000,ema_13=2001,ema_21=2002,ema_50=1995,
            rsi_7=50,vol_ma_10=300,bb_upper=2020,bb_lower=1980))
        d=force(d,-2, open=2005,high=2005.2,low=1999.5,close=2000,tick_volume=100)
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM, m5(+1))
        self.assertEqual(s.strategy,"MicroEngulfingReversal")

    def test_confidence_and_agreement(self):
        d=force(base_df(),-1, **q(open=2005,high=2010.5,low=2004.5,close=2010,tick_volume=500,
            ema_9=2006,ema_21=2004,ema_50=2000,bb_upper=2009,bb_lower=1990,
            rsi_7=70,vol_ma_10=300,swing_high_15=2008,swing_low_15=1995,
            adx_14=30,ema_5=2006,ema_13=2005))
        s=strategy_engine.generate_signal(d, config.SESSION_MODE_MOMENTUM, m5(+1))
        self.assertTrue(s)
        self.assertGreaterEqual(s.confidence_score, 0.72)

if __name__=="__main__":
    unittest.main(verbosity=2)
