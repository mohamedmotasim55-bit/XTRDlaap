import os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from state_persistence import StatePersistence

class TestStatePersistence(unittest.TestCase):
    def test_save_load_roundtrip(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "bot_state.json")
        sp = StatePersistence(path=p, save_interval_sec=0)
        sp.update(peak_equity=123.4, peak_daily_profit=5.6, ratchet_locked=True,
                  adaptive_brain={"history": {"MomentumBreakout": [True, False]}})
        self.assertTrue(sp.save(force=True))

        sp2 = StatePersistence(path=p)
        state = sp2.load()
        self.assertAlmostEqual(state["peak_equity"], 123.4, places=2)
        self.assertTrue(state["ratchet_locked"])
        self.assertEqual(state["adaptive_brain"]["history"]["MomentumBreakout"],
                         [True, False])

    def test_load_missing_returns_empty(self):
        d = tempfile.mkdtemp()
        sp = StatePersistence(path=os.path.join(d, "nope.json"))
        self.assertEqual(sp.load(), {})

    def test_log_rotation(self):
        d = tempfile.mkdtemp()
        big = os.path.join(d, "huge.csv")
        with open(big, "w") as fh:
            fh.write("x" * 2048)
        small = os.path.join(d, "small.txt")
        with open(small, "w") as fh:
            fh.write("ok")
        archived = StatePersistence.rotate_logs_if_needed(d, max_bytes=1024)
        self.assertEqual(len(archived), 1)
        self.assertTrue(os.path.exists(small))
        self.assertFalse(os.path.exists(big))

if __name__ == "__main__":
    unittest.main(verbosity=2)
