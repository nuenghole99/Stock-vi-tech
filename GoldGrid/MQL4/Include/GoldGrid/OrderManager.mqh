//+------------------------------------------------------------------+
//| GoldGrid/OrderManager.mqh                                        |
//| วางกริด BUY LIMIT / SELL LIMIT บนระดับราคาคงที่                        |
//|                                                                  |
//| กติกา:                                                            |
//|  - ระดับกริดคงที่ = ทุก ๆ GridDistancePoints (เช่น 3.00 USD)            |
//|    BUY LIMIT ที่ระดับใต้ Ask ที่ใกล้สุด, SELL LIMIT ที่ระดับเหนือ Bid ที่ใกล้สุด |
//|  - 1 pending ต่อฝั่ง ไม่ไล่ราคา: pending เดิมจะถูกย้ายก็ต่อเมื่อห่างจาก     |
//|    ระดับเป้าหมายเกิน RepositionGrids ระดับ (ย้ายด้วย OrderModify)         |
//|  - ทุกออเดอร์มี SL (จาก guard) และ TP ตั้งแต่ตอนวาง                     |
//|  - lot คงที่ ไม่มี martingale                                        |
//|  - ผ่าน guard.CheckCanOpen() ทุกครั้งก่อนวางไม้ใหม่                      |
//|  - ไม่วางซ้ำหลังรีสตาร์ต: อ่าน pending/position ที่มีอยู่จากออเดอร์จริงเสมอ  |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_ORDERMANAGER_MQH
#define GOLDGRID_ORDERMANAGER_MQH

#include "Common.mqh"
#include "OrderScan.mqh"
#include "TradeOps.mqh"
#include "GuardManager.mqh"
#include "Notifier.mqh"

struct OrderConfig
  {
   int               magic;
   double            lots;               // lot คงที่
   int               gridPoints;         // ระยะกริด (points)
   int               tpPoints;           // TP (points), 0 = ไม่ตั้ง TP
   int               repositionGrids;    // ย้าย pending เมื่อห่างเป้าหมายเกินกี่ระดับ
   int               maxRetries;
   int               slippagePoints;
   bool              dryRun;
  };

class COrderManager
  {
private:
   OrderConfig       m_cfg;
   string            m_symbol;
   CGuardManager    *m_guard;
   CNotifier        *m_notifier;
   int               m_known[];           // ticket ของไม้ market ที่รู้จักแล้ว
   datetime          m_cooldownUntil;     // พักหลังส่งออเดอร์ล้มเหลว
   string            m_lastDryKey[2];     // กัน log dry-run ซ้ำ (0=buy,1=sell)

   void              Notify(const int evt, const string msg)
     {
      if(CheckPointer(m_notifier) != POINTER_INVALID)
         m_notifier.Event(evt, msg);
      else
         GG_Log(GG_EventText(evt), msg);
     }

   static bool       InArray(const int &arr[], const int v)
     {
      for(int i = ArraySize(arr) - 1; i >= 0; i--)
         if(arr[i] == v)
            return true;
      return false;
     }

   void              CollectMarketTickets(int &out[])
     {
      ArrayResize(out, 0);
      int n = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(GG_IsOurs(m_cfg.magic, m_symbol) && GG_IsMarketType(OrderType()))
           {
            ArrayResize(out, n + 1);
            out[n++] = OrderTicket();
           }
        }
     }

   // มี position ทิศเดียวกันเปิดอยู่ที่ระดับนี้แล้วหรือยัง
   bool              HasPositionAt(const bool buySide, const double level, const double tol)
     {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(!GG_IsOurs(m_cfg.magic, m_symbol))
            continue;
         int t = OrderType();
         if((buySide && t == OP_BUY) || (!buySide && t == OP_SELL))
            if(MathAbs(OrderOpenPrice() - level) <= tol)
               return true;
        }
      return false;
     }

   // หา pending ชนิด type ของ EA; ถ้ามีมากกว่า 1 จะลบส่วนเกิน (กติกา 1 pending ต่อฝั่ง)
   int               FindPending(const int type)
     {
      int keep = -1;
      int extra[];
      int n = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(!GG_IsOurs(m_cfg.magic, m_symbol) || OrderType() != type)
            continue;
         if(keep < 0)
            keep = OrderTicket();
         else
           {
            ArrayResize(extra, n + 1);
            extra[n++] = OrderTicket();
           }
        }
      for(int k = 0; k < n; k++)
        {
         int err = 0;
         GG_Log("WARN", "duplicate pending #" + IntegerToString(extra[k]) + " -> deleting");
         GG_OrderCloseRetry(extra[k], m_cfg.slippagePoints, m_cfg.maxRetries, m_cfg.dryRun, err);
        }
      return keep;
     }

   void              StartCooldown(const int err)
     {
      int sec = (err == 132 || err == 133) ? 60 : 15;   // market closed / trade disabled พักนานกว่า
      m_cooldownUntil = TimeCurrent() + sec;
     }

   int               ManageSide(const int type)
     {
      bool   buy    = (type == OP_BUYLIMIT);
      double point  = MarketInfo(m_symbol, MODE_POINT);
      int    digits = (int)MarketInfo(m_symbol, MODE_DIGITS);
      double step   = m_cfg.gridPoints * point;
      int    minGap = (int)MathMax(MarketInfo(m_symbol, MODE_STOPLEVEL), MarketInfo(m_symbol, MODE_FREEZELEVEL)) + 1;
      double ref    = buy ? MarketInfo(m_symbol, MODE_ASK) : MarketInfo(m_symbol, MODE_BID);

      double target = buy ? GridLevelBelow(ref, m_cfg.gridPoints, point, digits, minGap)
                          : GridLevelAbove(ref, m_cfg.gridPoints, point, digits, minGap);
      // ระดับนี้มีไม้เปิดอยู่แล้ว -> ใช้ระดับถัดไป (ไม่ซ้อนไม้ที่ราคาเดียวกัน)
      for(int i = 0; i < 5 && HasPositionAt(buy, target, step * 0.5); i++)
         target = NormalizeDouble(buy ? target - step : target + step, digits);

      double sl = m_guard.InitialSLFor(type, target);
      double tp = CalcTP(type, target, m_cfg.tpPoints, point, digits);
      if(!CGuardManager::IsSLValid(type, target, sl))
        {
         Notify(GG_EVT_ERROR, "refuse to place order without valid SL @" + DoubleToString(target, digits));
         return 0;
        }

      int existing = FindPending(type);
      if(existing >= 0 && OrderSelect(existing, SELECT_BY_TICKET))
        {
         double cur = OrderOpenPrice();
         if(MathAbs(cur - target) <= m_cfg.repositionGrids * step + point * 0.5)
            return 0;                                    // อยู่ใกล้พอ ไม่ไล่ราคา
         int errM = 0;
         if(GG_PendingMoveRetry(existing, target, sl, tp, m_cfg.maxRetries, m_cfg.dryRun, errM))
            GG_Log("ORDER", StringFormat("moved %s #%d %s -> %s", buy ? "BUYLIMIT" : "SELLLIMIT", existing,
                                         DoubleToString(cur, digits), DoubleToString(target, digits)));
         else
           {
            Notify(GG_EVT_ERROR, "move pending #" + IntegerToString(existing) + " failed: " + GG_ErrText(errM));
            StartCooldown(errM);
           }
         return 0;
        }

      // ไม้ใหม่: ต้องผ่าน guard ทุกครั้ง (spread, margin, daily limit, halt, emergency)
      int reason = m_guard.CheckCanOpen(m_cfg.lots);
      if(reason != GG_OK)
         return 0;

      if(m_cfg.dryRun)
        {
         string key = DoubleToString(target, digits);
         int idx = buy ? 0 : 1;
         if(m_lastDryKey[idx] != key)
           {
            GG_Log("DRY", StringFormat("would place %s %.2f @%s SL=%s TP=%s", buy ? "BUYLIMIT" : "SELLLIMIT",
                                       m_cfg.lots, key, DoubleToString(sl, digits), DoubleToString(tp, digits)));
            m_lastDryKey[idx] = key;
           }
         return 0;
        }

      int err = 0;
      int ticket = GG_OrderSendRetry(m_symbol, type, m_cfg.lots, target, sl, tp, m_cfg.slippagePoints,
                                     m_cfg.magic, GG_NAME, m_cfg.maxRetries, false, err);
      if(ticket > 0)
        {
         GG_Log("ORDER", StringFormat("placed %s #%d %.2f @%s SL=%s TP=%s", buy ? "BUYLIMIT" : "SELLLIMIT", ticket,
                                      m_cfg.lots, DoubleToString(target, digits), DoubleToString(sl, digits),
                                      DoubleToString(tp, digits)));
         return 1;
        }
      Notify(GG_EVT_ERROR, StringFormat("place %s @%s failed: %s", buy ? "BUYLIMIT" : "SELLLIMIT",
                                        DoubleToString(target, digits), GG_ErrText(err)));
      StartCooldown(err);
      return 0;
     }

public:
   //=================================================================
   // PURE (static)
   //=================================================================
   // ระดับกริดสูงสุดที่ต่ำกว่า (price - minGapPts) อย่างน้อยครึ่ง point
   static double     GridLevelBelow(const double price, const int gridPts, const double point,
                                    const int digits, const int minGapPts)
     {
      double step = gridPts * point;
      if(step <= 0)
         return 0;
      double limit = price - minGapPts * point - point * 0.5;
      return NormalizeDouble(MathFloor(limit / step) * step, digits);
     }

   // ระดับกริดต่ำสุดที่สูงกว่า (price + minGapPts) อย่างน้อยครึ่ง point
   static double     GridLevelAbove(const double price, const int gridPts, const double point,
                                    const int digits, const int minGapPts)
     {
      double step = gridPts * point;
      if(step <= 0)
         return 0;
      double limit = price + minGapPts * point + point * 0.5;
      return NormalizeDouble(MathCeil(limit / step) * step, digits);
     }

   static double     CalcTP(const int type, const double entry, const int tpPts, const double point, const int digits)
     {
      if(tpPts <= 0)
         return 0;
      return NormalizeDouble(GG_IsBuyType(type) ? entry + tpPts * point : entry - tpPts * point, digits);
     }

   //=================================================================
   // INSTANCE
   //=================================================================
                     COrderManager(void)
     {
      m_guard = NULL;
      m_notifier = NULL;
      m_cooldownUntil = 0;
      m_lastDryKey[0] = "";
      m_lastDryKey[1] = "";
     }

   void              Init(const OrderConfig &cfg, const string symbol, CGuardManager *guard, CNotifier *notifier)
     {
      m_cfg      = cfg;
      m_symbol   = symbol;
      m_guard    = guard;
      m_notifier = notifier;
      m_cooldownUntil = 0;
      m_lastDryKey[0] = "";
      m_lastDryKey[1] = "";
      CollectMarketTickets(m_known);   // ไม้ที่มีอยู่ก่อนรีสตาร์ต ไม่แจ้งซ้ำ
     }

   void              SetDryRun(const bool on) { m_cfg.dryRun = on; }

   //--- แจ้งเตือนไม้ที่ fill ใหม่ และไม้ที่ปิดไป (TP/SL/guard)
   void              TrackFills(void)
     {
      int cur[];
      CollectMarketTickets(cur);
      int digits = (int)MarketInfo(m_symbol, MODE_DIGITS);

      for(int i = 0; i < ArraySize(cur); i++)
        {
         if(InArray(m_known, cur[i]) || !OrderSelect(cur[i], SELECT_BY_TICKET))
            continue;
         Notify(GG_EVT_ORDER_OPEN, StringFormat("#%d %s %.2f @%s SL=%s TP=%s", cur[i],
                OrderType() == OP_BUY ? "BUY" : "SELL", OrderLots(),
                DoubleToString(OrderOpenPrice(), digits), DoubleToString(OrderStopLoss(), digits),
                DoubleToString(OrderTakeProfit(), digits)));
        }
      for(int j = 0; j < ArraySize(m_known); j++)
        {
         if(InArray(cur, m_known[j]) || !OrderSelect(m_known[j], SELECT_BY_TICKET))
            continue;
         double pl = OrderProfit() + OrderSwap() + OrderCommission();
         Notify(GG_EVT_ORDER_CLOSE, StringFormat("#%d %s closed @%s P/L=%.2f", m_known[j],
                OrderType() == OP_BUY ? "BUY" : "SELL", DoubleToString(OrderClosePrice(), digits), pl));
        }
      ArrayResize(m_known, ArraySize(cur));
      for(int k = 0; k < ArraySize(cur); k++)
         m_known[k] = cur[k];
     }

   //--- วาง/ดูแล pending ทั้งสองฝั่ง; คืนจำนวนออเดอร์ที่วางใหม่
   int               Manage(void)
     {
      if(TimeCurrent() < m_cooldownUntil)
         return 0;
      if(MarketInfo(m_symbol, MODE_TRADEALLOWED) == 0)
         return 0;
      RefreshRates();
      int placed = 0;
      placed += ManageSide(OP_BUYLIMIT);
      placed += ManageSide(OP_SELLLIMIT);
      return placed;
     }
  };

#endif // GOLDGRID_ORDERMANAGER_MQH
//+------------------------------------------------------------------+
