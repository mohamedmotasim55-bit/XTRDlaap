import os, sys, types, unittest
from datetime import datetime, timedelta
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
import trade_manager as tm

class Obj(types.SimpleNamespace):
    pass

class FakeMT5:
    TRADE_ACTION_DEAL=1; TRADE_ACTION_SLTP=6
    ORDER_TYPE_BUY=0; ORDER_TYPE_SELL=1
    POSITION_TYPE_BUY=0; POSITION_TYPE_SELL=1
    ORDER_FILLING_FOK=0; ORDER_FILLING_IOC=1; ORDER_FILLING_RETURN=2
    ORDER_TIME_GTC=0
    TRADE_RETCODE_DONE=0; TRADE_RETCODE_PLACED=10008; TRADE_RETCODE_INVALID_FILL=10030
    DEAL_ENTRY_OUT=1
    def __init__(self):
        self._point=0.01
        self._stops=0
        self._filling_mode=3   # FOK|IOC
        self._bid=2000.0; self._ask=2000.26
        self._positions=[]
        self._deals=[]
        self._margin=1.42
        self._margin_free=8.0
        self.check_retcode=0
        self.send_queue=[]      # list of retcodes; default DONE
        self.sent_requests=[]
    def symbol_info(self, s):
        return Obj(point=self._point, trade_stops_level=self._stops, filling_mode=self._filling_mode, digits=2)
    def symbol_info_tick(self, s):
        return Obj(bid=self._bid, ask=self._ask)
    def positions_get(self, symbol=None):
        return list(self._positions)
    def history_deals_get(self, frm, to):
        return list(self._deals)
    def order_calc_margin(self, t, s, v, p):
        return self._margin
    def account_info(self):
        return Obj(margin_free=self._margin_free)
    def order_check(self, req):
        return Obj(retcode=self.check_retcode)
    def order_send(self, req):
        self.sent_requests.append(dict(req))
        rc = self.send_queue.pop(0) if self.send_queue else self.TRADE_RETCODE_DONE
        return Obj(retcode=rc, order=12345, price=req.get("price", 0.0), comment="")
    def last_error(self):
        return (0, "ok")

class Conn:
    symbol="XAUUSD.m"

def make_tm():
    fake=FakeMT5()
    tm.mt5=fake
    return tm.TradeManager(Conn()), fake

def pos(ticket, ptype, price_open, sl=0.0, tp=0.0, magic=None, profit=0.0):
    return Obj(ticket=ticket, type=ptype, price_open=price_open, sl=sl, tp=tp,
               magic=config.MAGIC_NUMBER if magic is None else magic, profit=profit, volume=0.01)

class TestTradeManager(unittest.TestCase):
    def test_count_positions(self):
        m,f=make_tm()
        f._positions=[pos(1,0,2000), pos(2,1,2000), pos(3,0,2000,magic=999)]
        self.assertEqual(m.count_bot_positions(),2)

    def test_can_open_max_reached(self):
        m,f=make_tm()
        f._positions=[pos(1,0,2000)]
        self.assertFalse(m.can_open_new_trade())
        self.assertIn("max", m.last_error)

    def test_can_open_cooldown(self):
        m,f=make_tm()
        f._positions=[]
        f._deals=[Obj(symbol="XAUUSD.m", magic=config.MAGIC_NUMBER, entry=FakeMT5.DEAL_ENTRY_OUT,
                      time=datetime.now().timestamp())]
        self.assertFalse(m.can_open_new_trade())
        self.assertIn("cooldown", m.last_error)

    def test_can_open_margin_ok(self):
        m,f=make_tm(); f._positions=[]; f._deals=[]; f._margin_free=8.0; f._margin=1.42
        self.assertTrue(m.can_open_new_trade())

    def test_can_open_margin_low(self):
        m,f=make_tm(); f._positions=[]; f._deals=[]; f._margin_free=0.5; f._margin=1.42
        self.assertFalse(m.can_open_new_trade())
        self.assertIn("margin", m.last_error)

    def test_execute_buy_success(self):
        m,f=make_tm()
        sig=Obj(signal="BUY", strategy="MomentumBreakout", entry=2000.0, sl=1999.2, tp=2001.2, atr_points=50)
        self.assertTrue(m.execute_signal(sig))
        req=f.sent_requests[-1]
        self.assertEqual(req["type"], FakeMT5.ORDER_TYPE_BUY)
        self.assertLess(req["sl"], req["price"])
        self.assertGreater(req["tp"], req["price"])

    def test_filling_fallback(self):
        m,f=make_tm()
        f.send_queue=[FakeMT5.TRADE_RETCODE_INVALID_FILL, FakeMT5.TRADE_RETCODE_DONE]
        sig=Obj(signal="SELL", strategy="LiquiditySweep", entry=2000.0, sl=2000.8, tp=1998.8, atr_points=50)
        self.assertTrue(m.execute_signal(sig))
        self.assertGreaterEqual(len(f.sent_requests),2)

    def test_breakeven(self):
        m,f=make_tm()
        f._bid=2000.60; f._ask=2000.86   # +60 pts profit on BUY @2000 (> 48 trigger)
        f._positions=[pos(10, FakeMT5.POSITION_TYPE_BUY, 2000.0, sl=0.0, tp=2002.0)]
        m.manage_open_positions(current_atr=None)
        req=f.sent_requests[-1]
        self.assertEqual(req["action"], FakeMT5.TRADE_ACTION_SLTP)
        self.assertAlmostEqual(req["sl"], 2000.08, places=2)   # open + 8 pts

    def test_trailing(self):
        m,f=make_tm()
        f._bid=2001.20; f._ask=2001.46   # +120 pts; SL already locked at 2000.50
        f._positions=[pos(11, FakeMT5.POSITION_TYPE_BUY, 2000.0, sl=2000.50, tp=2002.0)]
        m.manage_open_positions(current_atr=0.30)
        req=f.sent_requests[-1]
        self.assertEqual(req["action"], FakeMT5.TRADE_ACTION_SLTP)
        self.assertAlmostEqual(req["sl"], 2000.945, places=2)  # 2001.20 - 0.85*0.30

    def test_no_backward_trail(self):
        m,f=make_tm()
        f._bid=2001.00; f._ask=2001.26   # candidate 2000.5 < current SL 2000.95
        f._positions=[pos(12, FakeMT5.POSITION_TYPE_BUY, 2000.0, sl=2000.95, tp=2002.0)]
        m.manage_open_positions(current_atr=0.50)
        self.assertEqual(len(f.sent_requests),0)

if __name__=="__main__":
    unittest.main(verbosity=2)
