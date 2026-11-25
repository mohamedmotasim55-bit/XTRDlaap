//+------------------------------------------------------------------+
//| XTRD_SYMBOL_SPEC_v1.00.mq5                                       |
//| Dumps the broker's contract specification for the chart symbol.   |
//| No orders are sent.                                              |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Prints Contract Size, Digits, Point, Tick Size/Value, Volume Min/Step, Stops/Freeze Level."

void Emit(const int file, const string key, const string value)
{
   Print("SPEC| ", key, " = ", value);
   if(file != INVALID_HANDLE)
      FileWrite(file, key, value);
}

int OnInit()
{
   string s = _Symbol;
   int file = FileOpen("XTRD_SYMBOL_SPEC.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(file != INVALID_HANDLE) FileWrite(file, "field", "value");

   Print("================ SYMBOL SPECIFICATION ================");
   Emit(file, "Symbol",        s);
   Emit(file, "Description",   SymbolInfoString(s, SYMBOL_DESCRIPTION));
   Emit(file, "Path",          SymbolInfoString(s, SYMBOL_PATH));
   Emit(file, "ContractSize",  DoubleToString(SymbolInfoDouble(s, SYMBOL_TRADE_CONTRACT_SIZE), 2));
   Emit(file, "Digits",        IntegerToString((int)SymbolInfoInteger(s, SYMBOL_DIGITS)));
   Emit(file, "Point",         DoubleToString(SymbolInfoDouble(s, SYMBOL_POINT), 8));
   Emit(file, "TickSize",      DoubleToString(SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE), 8));
   Emit(file, "TickValue",     DoubleToString(SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE), 4));
   Emit(file, "VolumeMin",     DoubleToString(SymbolInfoDouble(s, SYMBOL_VOLUME_MIN), 4));
   Emit(file, "VolumeStep",    DoubleToString(SymbolInfoDouble(s, SYMBOL_VOLUME_STEP), 4));
   Emit(file, "VolumeMax",     DoubleToString(SymbolInfoDouble(s, SYMBOL_VOLUME_MAX), 4));
   Emit(file, "StopsLevel",    IntegerToString((int)SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL)));
   Emit(file, "FreezeLevel",   IntegerToString((int)SymbolInfoInteger(s, SYMBOL_TRADE_FREEZE_LEVEL)));
   Emit(file, "SpreadPoints",  IntegerToString((int)SymbolInfoInteger(s, SYMBOL_SPREAD)));
   Emit(file, "SpreadFloat",   IntegerToString((int)SymbolInfoInteger(s, SYMBOL_SPREAD_FLOAT)));
   Emit(file, "SwapLong",      DoubleToString(SymbolInfoDouble(s, SYMBOL_SWAP_LONG), 4));
   Emit(file, "SwapShort",     DoubleToString(SymbolInfoDouble(s, SYMBOL_SWAP_SHORT), 4));
   Emit(file, "MarginInitial", DoubleToString(SymbolInfoDouble(s, SYMBOL_MARGIN_INITIAL), 4));
   Emit(file, "CurrencyBase",  SymbolInfoString(s, SYMBOL_CURRENCY_BASE));
   Emit(file, "CurrencyProfit",SymbolInfoString(s, SYMBOL_CURRENCY_PROFIT));
   Emit(file, "TradeMode",     IntegerToString((int)SymbolInfoInteger(s, SYMBOL_TRADE_MODE)));
   Emit(file, "ExecutionMode", IntegerToString((int)SymbolInfoInteger(s, SYMBOL_TRADE_EXEMODE)));
   Emit(file, "FillingMode",   IntegerToString((int)SymbolInfoInteger(s, SYMBOL_FILLING_MODE)));

   MqlTick t;
   if(SymbolInfoTick(s, t))
   {
      Emit(file, "BidNow", DoubleToString(t.bid, (int)SymbolInfoInteger(s, SYMBOL_DIGITS)));
      Emit(file, "AskNow", DoubleToString(t.ask, (int)SymbolInfoInteger(s, SYMBOL_DIGITS)));
      Emit(file, "SpreadNowPoints", DoubleToString((t.ask - t.bid) / SymbolInfoDouble(s, SYMBOL_POINT), 1));
   }

   double margin = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, s, SymbolInfoDouble(s, SYMBOL_VOLUME_MIN),
                      SymbolInfoDouble(s, SYMBOL_ASK), margin))
      Emit(file, "MarginForMinLot", DoubleToString(margin, 4));

   Emit(file, "OnePointValuePerMinLot",
        DoubleToString(SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE) *
                       (SymbolInfoDouble(s, SYMBOL_VOLUME_MIN) /
                        MathMax(SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE) /
                                SymbolInfoDouble(s, SYMBOL_POINT), 1.0)), 6));
   Print("================ END SPEC ================");

   if(file != INVALID_HANDLE) { FileFlush(file); FileClose(file); }
   return INIT_SUCCEEDED;
}

void OnTick() { }
void OnDeinit(const int reason) { }
