//+------------------------------------------------------------------+
//| GoldGrid/TradeOps.mqh                                            |
//| คำสั่งเทรดระดับล่างพร้อม retry จำกัดครั้ง + โหมด Dry-run                  |
//| ใช้ร่วมกันระหว่าง GuardManager (ปิด/แก้ SL) และ OrderManager (เฟสถัดไป)  |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_TRADEOPS_MQH
#define GOLDGRID_TRADEOPS_MQH

#include "Common.mqh"

// error ที่ลองใหม่ได้ทันที (ชั่วคราว)
bool GG_IsTransientError(const int err)
  {
   switch(err)
     {
      case 4:    // ERR_SERVER_BUSY
      case 6:    // ERR_NO_CONNECTION
      case 8:    // ERR_TOO_FREQUENT_REQUESTS
      case 128:  // ERR_TRADE_TIMEOUT
      case 129:  // ERR_INVALID_PRICE
      case 135:  // ERR_PRICE_CHANGED
      case 136:  // ERR_OFF_QUOTES
      case 137:  // ERR_BROKER_BUSY
      case 138:  // ERR_REQUOTE
      case 141:  // ERR_TOO_MANY_REQUESTS
      case 146:  // ERR_TRADE_CONTEXT_BUSY
         return true;
     }
   // 132 ERR_MARKET_CLOSED: ไม่ลองซ้ำในลูปนี้ (ลองใหม่ทันทีไม่มีประโยชน์)
   // ผู้เรียกจะลองอีกครั้งใน tick/timer ถัดไปเอง
   return false;
  }

string GG_ErrText(const int err)
  {
   return IntegerToString(err) + " " + ErrorDescription(err);
  }

// รอ trade context ว่าง (ใช้กับบัญชีจริง/เดโม; ใน tester คืน true ทันที)
bool GG_WaitTradeContext(const uint timeoutMs)
  {
   uint start = GetTickCount();
   while(IsTradeContextBusy())
     {
      if(GetTickCount() - start > timeoutMs)
         return false;
      Sleep(50);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| ปิด market order หรือ ลบ pending order                             |
//+------------------------------------------------------------------+
bool GG_OrderCloseRetry(const int ticket, const int slippage, const int maxRetries,
                        const bool dryRun, int &lastErr)
  {
   lastErr = 0;
   int tries = MathMax(1, maxRetries);
   for(int attempt = 0; attempt < tries; attempt++)
     {
      if(!OrderSelect(ticket, SELECT_BY_TICKET))
        {
         lastErr = GetLastError();
         GG_Log("ERROR", "close: select #" + IntegerToString(ticket) + " failed " + GG_ErrText(lastErr));
         return false;
        }
      if(OrderCloseTime() != 0)
         return true;                                   // ปิดไปแล้ว

      int    type   = OrderType();
      string sym    = OrderSymbol();
      if(dryRun)
        {
         GG_Log("DRY", (GG_IsMarketType(type) ? "would CLOSE #" : "would DELETE #") + IntegerToString(ticket));
         return true;
        }

      if(!GG_WaitTradeContext(5000))
        {
         lastErr = 146;
         GG_Log("WARN", "close: trade context busy, attempt " + IntegerToString(attempt + 1));
         continue;
        }
      RefreshRates();

      bool ok;
      if(GG_IsMarketType(type))
        {
         int    digits = (int)MarketInfo(sym, MODE_DIGITS);
         double price  = (type == OP_BUY) ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK);
         ok = OrderClose(ticket, OrderLots(), NormalizeDouble(price, digits), slippage, clrNONE);
        }
      else
         ok = OrderDelete(ticket, clrNONE);

      if(ok)
         return true;

      lastErr = GetLastError();
      GG_Log("WARN", "close #" + IntegerToString(ticket) + " attempt " + IntegerToString(attempt + 1)
             + "/" + IntegerToString(tries) + " failed " + GG_ErrText(lastErr));
      if(!GG_IsTransientError(lastErr))
         return false;
      Sleep(200 * (attempt + 1));
     }
   return false;
  }

//+------------------------------------------------------------------+
//| แก้ SL/TP (ใช้ราคาเปิดเดิมของออเดอร์)                                 |
//+------------------------------------------------------------------+
bool GG_OrderModifyRetry(const int ticket, const double sl, const double tp,
                         const int maxRetries, const bool dryRun, int &lastErr)
  {
   lastErr = 0;
   int tries = MathMax(1, maxRetries);
   for(int attempt = 0; attempt < tries; attempt++)
     {
      if(!OrderSelect(ticket, SELECT_BY_TICKET))
        {
         lastErr = GetLastError();
         GG_Log("ERROR", "modify: select #" + IntegerToString(ticket) + " failed " + GG_ErrText(lastErr));
         return false;
        }
      if(OrderCloseTime() != 0)
        {
         lastErr = 4108;                                // ERR_INVALID_TICKET (ปิดไปแล้ว)
         return false;
        }
      int digits = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);
      double nsl = NormalizeDouble(sl, digits);
      double ntp = NormalizeDouble(tp, digits);
      if(dryRun)
        {
         GG_Log("DRY", "would MODIFY #" + IntegerToString(ticket) + " SL=" + DoubleToString(nsl, digits)
                + " TP=" + DoubleToString(ntp, digits));
         return true;
        }
      if(!GG_WaitTradeContext(5000))
        {
         lastErr = 146;
         continue;
        }
      RefreshRates();
      if(OrderModify(ticket, OrderOpenPrice(), nsl, ntp, 0, clrNONE))
         return true;

      lastErr = GetLastError();
      if(lastErr == 1)                                  // ERR_NO_RESULT: ค่าเดิมอยู่แล้ว
         return true;
      GG_Log("WARN", "modify #" + IntegerToString(ticket) + " attempt " + IntegerToString(attempt + 1)
             + "/" + IntegerToString(tries) + " failed " + GG_ErrText(lastErr));
      if(!GG_IsTransientError(lastErr))
         return false;
      Sleep(200 * (attempt + 1));
     }
   return false;
  }

//+------------------------------------------------------------------+
//| ส่งออเดอร์ใหม่ (ใช้กับ pending order) คืน ticket, 0 = dry-run, -1 = ล้มเหลว |
//+------------------------------------------------------------------+
int GG_OrderSendRetry(const string symbol, const int type, const double lots, const double price,
                      const double sl, const double tp, const int slippage, const int magic,
                      const string comment, const int maxRetries, const bool dryRun, int &lastErr)
  {
   lastErr = 0;
   int    digits = (int)MarketInfo(symbol, MODE_DIGITS);
   double np  = NormalizeDouble(price, digits);
   double nsl = NormalizeDouble(sl, digits);
   double ntp = NormalizeDouble(tp, digits);
   if(dryRun)
      return 0;                                         // ผู้เรียกเป็นคน log (กัน log ซ้ำทุก tick)
   int tries = MathMax(1, maxRetries);
   for(int attempt = 0; attempt < tries; attempt++)
     {
      if(!GG_WaitTradeContext(5000))
        {
         lastErr = 146;
         continue;
        }
      RefreshRates();
      int t = OrderSend(symbol, type, lots, np, slippage, nsl, ntp, comment, magic, 0, clrNONE);
      if(t > 0)
         return t;
      lastErr = GetLastError();
      GG_Log("WARN", "OrderSend type=" + IntegerToString(type) + " @" + DoubleToString(np, digits)
             + " attempt " + IntegerToString(attempt + 1) + "/" + IntegerToString(tries)
             + " failed " + GG_ErrText(lastErr));
      if(!GG_IsTransientError(lastErr))
         return -1;
      Sleep(200 * (attempt + 1));
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| ย้ายราคา pending order (พร้อม SL/TP ใหม่) โดยไม่ลบ/วางใหม่             |
//+------------------------------------------------------------------+
bool GG_PendingMoveRetry(const int ticket, const double price, const double sl, const double tp,
                         const int maxRetries, const bool dryRun, int &lastErr)
  {
   lastErr = 0;
   int tries = MathMax(1, maxRetries);
   for(int attempt = 0; attempt < tries; attempt++)
     {
      if(!OrderSelect(ticket, SELECT_BY_TICKET) || OrderCloseTime() != 0 || GG_IsMarketType(OrderType()))
        {
         lastErr = 4108;                                // ไม่ใช่ pending ที่ยังค้างอยู่แล้ว
         return false;
        }
      int digits = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);
      if(dryRun)
        {
         GG_Log("DRY", "would MOVE pending #" + IntegerToString(ticket) + " to " + DoubleToString(price, digits));
         return true;
        }
      if(!GG_WaitTradeContext(5000))
        {
         lastErr = 146;
         continue;
        }
      RefreshRates();
      if(OrderModify(ticket, NormalizeDouble(price, digits), NormalizeDouble(sl, digits),
                     NormalizeDouble(tp, digits), 0, clrNONE))
         return true;
      lastErr = GetLastError();
      if(lastErr == 1)
         return true;
      GG_Log("WARN", "move pending #" + IntegerToString(ticket) + " attempt " + IntegerToString(attempt + 1)
             + " failed " + GG_ErrText(lastErr));
      if(!GG_IsTransientError(lastErr))
         return false;
      Sleep(200 * (attempt + 1));
     }
   return false;
  }

#endif // GOLDGRID_TRADEOPS_MQH
//+------------------------------------------------------------------+
