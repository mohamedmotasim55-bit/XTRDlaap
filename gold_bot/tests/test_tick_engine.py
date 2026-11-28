import unittest

import config
import tick_engine as te


class TestTickFlow(unittest.TestCase):
    def _feed(self, tf, prices):
        for k, p in enumerate(prices):
            tf.add(p, k * 100)

    def test_impulse_buy_detected(self):
        tf = te.TickFlow(point=0.01)
        # slow drift (1 pt/tick) then a genuine acceleration (4 pts/tick)
        prices = [2000.0]
        for _ in range(34):
            prices.append(prices[-1] + 0.01)
        for _ in range(8):
            prices.append(prices[-1] + 0.04)
        self._feed(tf, prices)
        self.assertGreaterEqual(abs(tf.fast_move), 20.0)
        self.assertEqual(tf.signal(20.0), "BUY")
        self.assertGreaterEqual(tf.directional_ratio, 0.9)
        self.assertGreater(tf.path_efficiency, 0.9)

    def test_noise_does_not_trigger(self):
        tf = te.TickFlow(point=0.01)
        prices = [2000.0, 2000.02, 1999.98, 2000.01, 1999.99] * 8
        self._feed(tf, prices)
        self.assertIsNone(tf.signal(20.0))

    def test_old_v129_threshold_would_be_noise(self):
        tf = te.TickFlow(point=0.01)
        self._feed(tf, [2000.0 + i * 0.006 for i in range(40)])  # ~0.6 pt per tick
        self.assertIsNone(tf.signal(20.0))

    def test_candle_reject(self):
        self.assertTrue(te.candle_rejects("BUY", 2000.0, 2001.0, 1999.9, 2000.05))
        self.assertFalse(te.candle_rejects("BUY", 2000.0, 2000.2, 1999.9, 2000.19))

    def test_overextended(self):
        self.assertTrue(te.is_overextended("BUY", 2001.0, 2000.0, 1.0))
        self.assertFalse(te.is_overextended("BUY", 2000.2, 2000.0, 1.0))

    def test_limits_sane(self):
        self.assertEqual(config.TICK_MIN_FAST_MOVE_POINTS, 20.0)
        self.assertLess(config.MOMENTUM_EXIT_MIN_USD, 1.0)
