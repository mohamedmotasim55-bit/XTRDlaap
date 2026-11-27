import os, sys, types, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
import trade_manager as tm

class Obj(types.SimpleNamespace): pass

class FakeMT5:
    POSITION_TYPE_BUY=0; POSITION_TYPE_SELL=1
    ORDER_TYPE_BUY=0; ORDER_TYPE_SELL=1
    def __init__(self, positions=None, margin_free=8.0):
        self._positions=positions or []
        self._margin_free=margin_free
    def symbol_info(self,s): return Obj(point=0.01, trade_stops_level=0, filling_mode=3, digits=2)
    def symbol_info_tick(self,s): return Obj(bid=2000.0, ask=2000.26)
    def positions_get(self,symbol=None): return list(self._positions)
    def history_deals_get(self,frm,to): return []
    def order_calc_margin(self,t,s,v,p): return 1.42
    def account_info(self): return Obj(margin_free=self._margin_free)

class Conn: symbol="XAUUSD.m"

def pos(ptype, price_open, sl):
    return Obj(ticket=1, type=ptype, price_open=price_open, sl=sl, tp=0.0,
               magic=config.MAGIC_NUMBER, profit=0.0, volume=0.01)

def make(positions, margin_free=8.0):
    fake=FakeMT5(positions, margin_free); tm.mt5=fake
    return tm.TradeManager(Conn())

class TestPyramid(unittest.TestCase):
    def test_base_entry_when_flat(self):
        m=make([]); self.assertTrue(m.can_open_new_trade("BUY"))

    def test_pyramid_allowed_same_dir_riskfree(self):
        m=make([pos(FakeMT5.POSITION_TYPE_BUY, 2000.0, 2000.05)])
        self.assertTrue(m.can_open_new_trade("BUY"))

    def test_pyramid_blocked_not_riskfree(self):
        m=make([pos(FakeMT5.POSITION_TYPE_BUY, 2000.0, 1999.0)])
        self.assertFalse(m.can_open_new_trade("BUY"))
        self.assertIn("risk-free", m.last_error)

    def test_pyramid_blocked_direction_mismatch(self):
        m=make([pos(FakeMT5.POSITION_TYPE_BUY, 2000.0, 2000.05)])
        self.assertFalse(m.can_open_new_trade("SELL"))
        self.assertIn("direction", m.last_error)

    def test_blocked_when_two_open(self):
        m=make([pos(FakeMT5.POSITION_TYPE_BUY,2000.0,2000.05),
                pos(FakeMT5.POSITION_TYPE_BUY,2001.0,2001.05)])
        self.assertFalse(m.can_open_new_trade("BUY"))

if __name__=="__main__":
    unittest.main(verbosity=2)
