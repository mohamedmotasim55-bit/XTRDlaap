import os, sys, unittest
from datetime import datetime, timedelta
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config, regime_detector
from adaptive_brain import AdaptiveBrain

class Sig:
    def __init__(self, strategy, conf, direction="BUY"):
        self.strategy=strategy; self.confidence_score=conf; self.signal=direction

class TestAdaptiveBrain(unittest.TestCase):
    def test_mute_after_3_losses(self):
        b=AdaptiveBrain(); now=datetime(2026,1,5,10,0)
        for _ in range(config.MUTE_MIN_TRADES):
            b.record_trade("MomentumBreakout",-1.0, now=now)
        self.assertTrue(b.is_muted("MomentumBreakout", now=now))

    def test_mute_expires(self):
        b=AdaptiveBrain(); now=datetime(2026,1,5,10,0)
        for _ in range(config.MUTE_MIN_TRADES):
            b.record_trade("LiquiditySweep",-1.0, now=now)
        self.assertTrue(b.is_muted("LiquiditySweep", now=now))
        later=now+timedelta(minutes=config.STRATEGY_MUTE_MINUTES+1)
        self.assertFalse(b.is_muted("LiquiditySweep", now=later))

    def test_multiplier_high_and_low(self):
        b=AdaptiveBrain()
        for _ in range(10): b.record_trade("FastMACDCross", 1.0)
        self.assertAlmostEqual(b.multiplier("FastMACDCross"),1.3,places=3)
        for _ in range(10): b.record_trade("MicroEngulfingReversal", -1.0)
        self.assertAlmostEqual(b.multiplier("MicroEngulfingReversal"),0.9,places=3)

    def test_regime_boost(self):
        b=AdaptiveBrain()
        up=regime_detector.Regime(regime=regime_detector.REGIME_TREND_UP)
        rng=regime_detector.Regime(regime=regime_detector.REGIME_RANGING)
        self.assertAlmostEqual(b.regime_boost("MomentumBreakout",up),0.15,places=3)
        self.assertAlmostEqual(b.regime_boost("MomentumBreakout",rng),0.0,places=3)
        self.assertAlmostEqual(b.regime_boost("BollingerBounce",rng),0.15,places=3)

    def test_gate(self):
        b=AdaptiveBrain()
        up=regime_detector.Regime(regime=regime_detector.REGIME_TREND_UP)
        ok,conf,_=b.evaluate(Sig("MomentumBreakout",0.6),up)
        self.assertTrue(ok)  # 0.6*1.0 + 0.15 = 0.75
        low=regime_detector.Regime(regime=regime_detector.REGIME_RANGING)
        ok2,conf2,_=b.evaluate(Sig("MomentumBreakout",0.4),low)
        self.assertFalse(ok2)  # 0.4 < 0.62

if __name__=="__main__":
    unittest.main(verbosity=2)
