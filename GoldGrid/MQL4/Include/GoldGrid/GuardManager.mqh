//+------------------------------------------------------------------+
//| GoldGrid/GuardManager.mqh                                        |
//| ด่านป้องกันทั้งหมดของ EA                                               |
//|  1. SL ฝั่งโบรกเกอร์ทุกออเดอร์ (คำนวณ SL เริ่มต้น + เก็บกวาดไม้ที่ไม่มี SL) |
//|  2. เพดานขาดทุนรายวัน % ของ equity ต้นวัน -> ปิดทุกไม้ + หยุดถึงข้ามวัน    |
//|  3. Trailing SL ที่ไม่ต่ำกว่าจุดทุนเมื่อเริ่ม trail                         |
//|  4. ตรวจ spread                                                    |
//|  5. ตรวจ margin level (คาดการณ์หลังวางไม้ใหม่)                         |
//|  6. Emergency stop                                                |
//|                                                                  |
//| แยกเป็น 2 ชั้น:                                                     |
//|  - ฟังก์ชัน static แบบ pure (ไม่แตะตลาด) -> ทดสอบด้วย unit test ได้        |
//|  - เมธอด instance ที่อ่านตลาด/สั่งปิด/แก้ออเดอร์ผ่าน TradeOps             |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_GUARDMANAGER_MQH
#define GOLDGRID_GUARDMANAGER_MQH

#include "Common.mqh"
#include "OrderScan.mqh"
#include "TradeOps.mqh"
#include "StateStore.mqh"
#include "Notifier.mqh"

//--- ค่าตั้งของ guard (มาจาก input ของ EA)
struct GuardConfig
  {
   int               magic;
   double            lossCapPct;            // เพดานขาดทุนรวม % ของ equity ต้นวัน
   bool              lossCapUseNetClosed;   // true = ใช้ P/L สุทธิของไม้ที่ปิดแล้ว, false = นับเฉพาะไม้ขาดทุน
   int               slPoints;              // SL เริ่มต้น (points)
   int               trailStartPoints;      // เริ่ม trail เมื่อกำไร >= ค่านี้
   int               trailDistancePoints;   // ระยะ SL ตามหลังราคา
   int               trailStepPoints;       // ต้องขยับดีขึ้นอย่างน้อยเท่านี้ถึงจะ modify
   int               breakevenOffsetPoints; // บวกจากราคาเปิดเพื่อคลุมค่าคอม/สเปรด
   int               maxSpreadPoints;
   double            minMarginLevelPct;     // margin level ขั้นต่ำ (%) หลังวางไม้ใหม่
   int               maxTradesPerDay;
   int               maxRetries;
   int               slippagePoints;
   bool              emergencyStop;
   bool              dryRun;
  };

//--- ภาพรวมสถานะ ณ ขณะหนึ่ง ใช้ตัดสินว่าวางไม้ใหม่ได้หรือไม่ (pure)
struct GuardSnapshot
  {
   bool              emergency;
   bool              dayHalted;
   bool              tradeAllowed;
   int               tradesToday;
   int               pendingCount;
   int               maxTradesPerDay;
   double            spreadPoints;
   int               maxSpreadPoints;
   double            projectedMarginLevel;
   double            minMarginLevelPct;
  };

class CGuardManager
  {
private:
   GuardConfig       m_cfg;
   string            m_symbol;
   CStateStore      *m_state;
   CNotifier        *m_notifier;

   int               m_lastReason;
   double            m_lastFloating;
   double            m_lastClosed;
   bool              m_emergencyNotified;

   void              Notify(const int evt, const string msg)
     {
      if(CheckPointer(m_notifier) != POINTER_INVALID)
         m_notifier.Event(evt, msg);
      else
         GG_Log(GG_EventText(evt), msg);
     }

public:
   //=================================================================
   // ชั้น PURE (static) — ไม่อ่านตลาด ไม่ส่งคำสั่ง
   //=================================================================

   // ยอดเพดานขาดทุนเป็นเงิน (ค่าติดลบ) เช่น 10000, 5% -> -500
   static double     LossCapAmount(const double dayStartEquity, const double capPct)
     {
      return -dayStartEquity * capPct / 100.0;
     }

   // ส่วนของไม้ที่ปิดแล้ววันนี้ที่นำมานับ
   static double     ClosedComponent(const double closedNet, const double closedLossOnly, const bool useNet)
     {
      return useNet ? closedNet : closedLossOnly;
     }

   // true เมื่อ floating + closed <= -cap% ของ equity ต้นวัน
   static bool       IsLossCapHit(const double floatingPL, const double closedPL,
                                  const double dayStartEquity, const double capPct)
     {
      if(dayStartEquity <= 0 || capPct <= 0)
         return false;
      return (floatingPL + closedPL) <= LossCapAmount(dayStartEquity, capPct) + 1e-9;
     }

   static bool       IsSpreadOK(const double spreadPoints, const int maxSpreadPoints)
     {
      return spreadPoints <= maxSpreadPoints + 1e-9;
     }

   // margin level (%) ที่คาดว่าจะเป็นหลังวางไม้ใหม่ที่ใช้ margin = addMargin
   static double     ProjectedMarginLevel(const double equity, const double usedMargin, const double addMargin)
     {
      double m = usedMargin + addMargin;
      if(m <= 0)
         return GG_MARGIN_LEVEL_INF;
      return equity / m * 100.0;
     }

   static bool       IsMarginOK(const double marginLevelPct, const double minMarginLevelPct)
     {
      return marginLevelPct >= minMarginLevelPct;
     }

   static bool       IsDailyLimitOK(const int tradesToday, const int pendingCount, const int maxTrades)
     {
      // pending ที่ค้างอยู่อาจ fill ได้ทุกเมื่อ จึงจองโควตาไว้ด้วย
      return (tradesToday + pendingCount) < maxTrades;
     }

   // ตัดสินว่าวางไม้ใหม่ได้หรือไม่ คืน GG_OK หรือเหตุผลแรกที่บล็อก
   static int        Evaluate(const GuardSnapshot &s)
     {
      if(s.emergency)
         return GG_BLOCK_EMERGENCY;
      if(s.dayHalted)
         return GG_BLOCK_DAY_HALT;
      if(!s.tradeAllowed)
         return GG_BLOCK_TRADE_DISABLED;
      if(!IsDailyLimitOK(s.tradesToday, s.pendingCount, s.maxTradesPerDay))
         return GG_BLOCK_DAILY_LIMIT;
      if(!IsSpreadOK(s.spreadPoints, s.maxSpreadPoints))
         return GG_BLOCK_SPREAD;
      if(!IsMarginOK(s.projectedMarginLevel, s.minMarginLevelPct))
         return GG_BLOCK_MARGIN;
      return GG_OK;
     }

   // SL เริ่มต้นจากราคาเข้า (ใช้ได้ทั้ง market และ pending)
   static double     CalcInitialSL(const int orderType, const double entryPrice, const int slPoints,
                                   const double point, const int digits)
     {
      double sl = GG_IsBuyType(orderType) ? entryPrice - slPoints * point
                                          : entryPrice + slPoints * point;
      return NormalizeDouble(sl, digits);
     }

   // SL ต้องมีค่าและอยู่ฝั่งที่ถูกต้องของราคาเข้า
   static bool       IsSLValid(const int orderType, const double entryPrice, const double sl)
     {
      if(sl <= 0)
         return false;
      return GG_IsBuyType(orderType) ? (sl < entryPrice) : (sl > entryPrice);
     }

   // คำนวณ SL ใหม่แบบ trailing; คืน 0 ถ้าไม่ต้องแก้
   //  - เริ่มเมื่อกำไร >= startPts
   //  - SL = ราคา -/+ distPts แต่ไม่แย่กว่าจุดทุน (+beOffset)
   //  - ถ้า stop level ของโบรกเกอร์ไม่ให้ตั้งที่จุดทุน -> รอ (ไม่ตั้ง SL ต่ำกว่าทุน)
   //  - ไม่ถอย SL และต้องดีขึ้นอย่างน้อย max(stepPts,1) points
   static double     CalcTrailingSL(const int type, const double openPrice, const double curSL,
                                    const double bid, const double ask,
                                    const double point, const int digits,
                                    const int startPts, const int distPts, const int stepPts,
                                    const int beOffsetPts, const int stopLevelPts)
     {
      if(point <= 0 || !GG_IsMarketType(type))
         return 0;
      double half       = point * 0.5;
      double minImprove = MathMax(stepPts, 1) * point;
      double cand, be;

      if(type == OP_BUY)
        {
         int profitPts = (int)MathRound((bid - openPrice) / point);
         if(profitPts < startPts)
            return 0;
         be   = openPrice + beOffsetPts * point;
         cand = bid - distPts * point;
         if(cand < be)
            cand = be;
         double maxAllowed = bid - stopLevelPts * point;
         if(cand > maxAllowed)
            cand = maxAllowed;
         if(cand < be - half)
            return 0;
         cand = NormalizeDouble(cand, digits);
         if(curSL > 0 && (cand - curSL) < minImprove - half)
            return 0;
         return cand;
        }

      // OP_SELL
      int profitPtsS = (int)MathRound((openPrice - ask) / point);
      if(profitPtsS < startPts)
         return 0;
      be   = openPrice - beOffsetPts * point;
      cand = ask + distPts * point;
      if(cand > be)
         cand = be;
      double minAllowed = ask + stopLevelPts * point;
      if(cand < minAllowed)
         cand = minAllowed;
      if(cand > be + half)
         return 0;
      cand = NormalizeDouble(cand, digits);
      if(curSL > 0 && (curSL - cand) < minImprove - half)
         return 0;
      return cand;
     }

   //=================================================================
   // ชั้น INSTANCE — อ่านตลาด/บัญชี และสั่งงานผ่าน TradeOps
   //=================================================================
                     CGuardManager(void)
     {
      m_state = NULL;
      m_notifier = NULL;
      m_symbol = "";
      m_lastReason = -1;
      m_lastFloating = 0;
      m_lastClosed = 0;
      m_emergencyNotified = false;
     }

   void              Init(const GuardConfig &cfg, const string symbol,
                          CStateStore *state, CNotifier *notifier)
     {
      m_cfg      = cfg;
      m_symbol   = symbol;
      m_state    = state;
      m_notifier = notifier;
      m_lastReason = -1;
      m_emergencyNotified = false;
     }

   //--- setter สำหรับชุดทดสอบ / ปรับระหว่างรัน
   void              SetEmergency(const bool on) { m_cfg.emergencyStop = on; if(!on) m_emergencyNotified = false; }
   void              SetLossCapPct(const double pct) { m_cfg.lossCapPct = pct; }
   void              SetMaxTradesPerDay(const int n) { m_cfg.maxTradesPerDay = n; }
   void              SetDryRun(const bool on) { m_cfg.dryRun = on; }

   //--- getter สำหรับ dashboard / status JSON
   bool              IsEmergency(void) { return m_cfg.emergencyStop; }
   int               LastReason(void) { return m_lastReason; }
   double            LastFloating(void) { return m_lastFloating; }
   double            LastClosed(void) { return m_lastClosed; }
   double            LossCapMoney(void) { return LossCapAmount(m_state.dayStartEquity, m_cfg.lossCapPct); }

   // ดึงจำนวนไม้วันนี้จากการสแกน มารวมกับที่ StateStore จำไว้
   void              SyncTradesToday(const datetime now)
     {
      int scanned = GG_CountFilledSince(m_cfg.magic, m_symbol, GG_DayStart(now));
      m_state.MergeTradesCount(scanned);
     }

   // SL เริ่มต้นสำหรับออเดอร์ใหม่ (OrderManager ต้องใช้ตัวนี้เสมอ)
   double            InitialSLFor(const int orderType, const double entryPrice)
     {
      return CalcInitialSL(orderType, entryPrice, m_cfg.slPoints,
                           MarketInfo(m_symbol, MODE_POINT), (int)MarketInfo(m_symbol, MODE_DIGITS));
     }

   //--- Guard 4,5 + daily limit + halt/emergency: วางไม้ใหม่ได้ไหม
   int               CheckCanOpen(const double lots)
     {
      GuardSnapshot s;
      s.emergency            = m_cfg.emergencyStop;
      s.dayHalted            = m_state.dayHalted;
      s.tradeAllowed         = m_cfg.dryRun ? true : IsTradeAllowed();
      s.tradesToday          = m_state.tradesToday;
      s.pendingCount         = GG_CountPending(m_cfg.magic, m_symbol);
      s.maxTradesPerDay      = m_cfg.maxTradesPerDay;
      s.spreadPoints         = GG_SpreadPoints(m_symbol);
      s.maxSpreadPoints      = m_cfg.maxSpreadPoints;
      s.projectedMarginLevel = ProjectedMarginLevel(AccountEquity(), AccountMargin(),
                                                    MarketInfo(m_symbol, MODE_MARGINREQUIRED) * lots);
      s.minMarginLevelPct    = m_cfg.minMarginLevelPct;

      int reason = Evaluate(s);
      if(reason != m_lastReason)
        {
         GG_Log("GUARD", "can-open = " + GG_BlockText(reason)
                + StringFormat(" (trades=%d pending=%d spread=%.1f marginLvl=%.0f%%)",
                               s.tradesToday, s.pendingCount, s.spreadPoints,
                               MathMin(s.projectedMarginLevel, 999999)));
         m_lastReason = reason;
        }
      return reason;
     }

   //--- Guard 2: เพดานขาดทุนรายวัน; คืน true ถ้าวันนี้หยุดแล้ว
   bool              CheckLossCap(const datetime now)
     {
      if(m_state.dayHalted)
        {
         // ยังมีไม้ค้าง (เช่นปิดไม่สำเร็จรอบก่อน) -> ลองปิดซ้ำ
         if(GG_CountAll(m_cfg.magic, m_symbol) > 0 && !m_cfg.dryRun)
            CloseAll("day halted cleanup");
         return true;
        }
      if(m_state.dayStartEquity <= 0)
        {
         m_state.dayStartEquity = AccountEquity();
         m_state.Save();
         GG_Log("WARN", "dayStartEquity was invalid, reset to current equity");
        }

      double net, lossOnly;
      GG_ClosedPLSince(m_cfg.magic, m_symbol, GG_DayStart(now), net, lossOnly);
      m_lastClosed   = ClosedComponent(net, lossOnly, m_cfg.lossCapUseNetClosed);
      m_lastFloating = GG_FloatingPL(m_cfg.magic, m_symbol);

      if(!IsLossCapHit(m_lastFloating, m_lastClosed, m_state.dayStartEquity, m_cfg.lossCapPct))
         return false;

      // persist ก่อนปิด: ถ้ารีสตาร์ตกลางคัน ก็ยังหยุดวันอยู่
      m_state.SetHalted(GG_HALT_LOSS_CAP);
      Notify(GG_EVT_LOSS_CAP,
             StringFormat("Daily loss cap hit: floating=%.2f closed=%.2f cap=%.2f (%.2f%% of %.2f). Closing all, halted until next server day.",
                          m_lastFloating, m_lastClosed, LossCapMoney(), m_cfg.lossCapPct, m_state.dayStartEquity));
      CloseAll("loss cap");
      return true;
     }

   //--- Guard 6: Emergency stop; คืน true ถ้า emergency เปิดอยู่
   bool              HandleEmergency(void)
     {
      if(!m_cfg.emergencyStop)
         return false;
      if(!m_emergencyNotified)
        {
         Notify(GG_EVT_EMERGENCY, "EmergencyStop=true: closing all EA orders and stopping.");
         m_emergencyNotified = true;
        }
      if(GG_CountAll(m_cfg.magic, m_symbol) > 0)
         CloseAll("emergency");
      return true;
     }

   //--- ปิด/ลบออเดอร์ของ EA เฉพาะชนิดเดียว (market หรือ pending); คืนจำนวนที่ล้มเหลว
   //    การแจ้ง ORDER_CLOSE ของไม้ market ทำโดย OrderManager::TrackFills (มีกำไร/ขาดทุนครบ)
   int               CloseKind(const bool market, const string why)
     {
      int tickets[];
      int n = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(!GG_IsOurs(m_cfg.magic, m_symbol))
            continue;
         if(GG_IsMarketType(OrderType()) != market)
            continue;
         ArrayResize(tickets, n + 1);
         tickets[n++] = OrderTicket();
        }
      int failed = 0;
      for(int k = 0; k < n; k++)
        {
         int err = 0;
         if(GG_OrderCloseRetry(tickets[k], m_cfg.slippagePoints, m_cfg.maxRetries, m_cfg.dryRun, err))
           {
            if(!m_cfg.dryRun)
               GG_Log("GUARD", (market ? "closed #" : "deleted pending #") + IntegerToString(tickets[k]) + " (" + why + ")");
           }
         else
           {
            failed++;
            Notify(GG_EVT_ERROR, (market ? "close #" : "delete #") + IntegerToString(tickets[k])
                   + " failed (" + why + "): " + GG_ErrText(err));
           }
        }
      return failed;
     }

   //--- ลบ pending ทั้งหมดของ EA (เช่นตอนปิด EA เพื่อไม่ให้มีไม้ fill ตอนไม่มี guard คุม)
   int               DeletePendings(const string why)
     {
      return CloseKind(false, why);
     }

   //--- ปิดทุกไม้ + ลบ pending ทั้งหมดของ EA; คืนจำนวนที่ยังค้างอยู่
   int               CloseAll(const string why)
     {
      CloseKind(false, why);   // pending ก่อน กันไม่ให้ fill ระหว่างปิด
      CloseKind(true, why);
      int remaining = m_cfg.dryRun ? 0 : GG_CountAll(m_cfg.magic, m_symbol);
      if(remaining > 0)
         GG_Log("ERROR", "CloseAll(" + why + "): " + IntegerToString(remaining) + " order(s) still open, will retry");
      return remaining;
     }

   //--- Guard 1 (safety net): ไม้ของ EA ที่ไม่มี SL -> ตั้ง SL; ถ้าตั้งไม่ได้ -> ปิด/ลบ
   int               EnforceStopLoss(void)
     {
      int tickets[];
      int n = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(!GG_IsOurs(m_cfg.magic, m_symbol))
            continue;
         if(OrderStopLoss() > 0)
            continue;                         // มี SL แล้ว (รวม SL ที่ trail ข้ามทุนไปแล้ว)
         ArrayResize(tickets, n + 1);
         tickets[n++] = OrderTicket();
        }

      int fixedCount = 0;
      double point  = MarketInfo(m_symbol, MODE_POINT);
      int    digits = (int)MarketInfo(m_symbol, MODE_DIGITS);
      double stop   = MarketInfo(m_symbol, MODE_STOPLEVEL) * point;
      for(int k = 0; k < n; k++)
        {
         if(!OrderSelect(tickets[k], SELECT_BY_TICKET))
            continue;
         int    type = OrderType();
         double sl   = InitialSLFor(type, OrderOpenPrice());
         double tp   = OrderTakeProfit();
         bool   tooClose = false;
         if(type == OP_BUY)
            tooClose = (sl > MarketInfo(m_symbol, MODE_BID) - stop);
         else
            if(type == OP_SELL)
               tooClose = (sl < MarketInfo(m_symbol, MODE_ASK) + stop);

         int err = 0;
         bool ok = false;
         if(!tooClose)
            ok = GG_OrderModifyRetry(tickets[k], sl, tp, m_cfg.maxRetries, m_cfg.dryRun, err);
         if(ok)
           {
            fixedCount++;
            Notify(GG_EVT_INFO, "#" + IntegerToString(tickets[k]) + " had no SL -> set SL=" + DoubleToString(sl, digits));
            continue;
           }
         // ตั้ง SL ไม่ได้ (ราคาเลยจุด SL ไปแล้ว หรือโบรกเกอร์ปฏิเสธ) -> ปิดทิ้ง
         Notify(GG_EVT_ERROR, "#" + IntegerToString(tickets[k]) + " has no SL and SL cannot be set ("
                + (tooClose ? "price beyond SL" : GG_ErrText(err)) + ") -> closing");
         GG_OrderCloseRetry(tickets[k], m_cfg.slippagePoints, m_cfg.maxRetries, m_cfg.dryRun, err);
        }
      return fixedCount;
     }

   //--- Guard 3: trailing SL ของไม้ market ทั้งหมดของ EA; คืนจำนวนที่ขยับ
   int               ManageTrailing(void)
     {
      int tickets[];
      int n = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(GG_IsOurs(m_cfg.magic, m_symbol) && GG_IsMarketType(OrderType()))
           {
            ArrayResize(tickets, n + 1);
            tickets[n++] = OrderTicket();
           }
        }

      RefreshRates();
      double point     = MarketInfo(m_symbol, MODE_POINT);
      int    digits    = (int)MarketInfo(m_symbol, MODE_DIGITS);
      int    stopLevel = (int)MarketInfo(m_symbol, MODE_STOPLEVEL);
      double bid       = MarketInfo(m_symbol, MODE_BID);
      double ask       = MarketInfo(m_symbol, MODE_ASK);
      int moved = 0;
      for(int k = 0; k < n; k++)
        {
         if(!OrderSelect(tickets[k], SELECT_BY_TICKET))
            continue;
         double newSL = CalcTrailingSL(OrderType(), OrderOpenPrice(), OrderStopLoss(), bid, ask,
                                       point, digits,
                                       m_cfg.trailStartPoints, m_cfg.trailDistancePoints,
                                       m_cfg.trailStepPoints, m_cfg.breakevenOffsetPoints, stopLevel);
         if(newSL <= 0)
            continue;
         double oldSL = OrderStopLoss();
         int err = 0;
         if(GG_OrderModifyRetry(tickets[k], newSL, OrderTakeProfit(), m_cfg.maxRetries, m_cfg.dryRun, err))
           {
            moved++;
            GG_Log("TRAIL", "#" + IntegerToString(tickets[k]) + " SL " + DoubleToString(oldSL, digits)
                   + " -> " + DoubleToString(newSL, digits));
           }
         else
            Notify(GG_EVT_ERROR, "trail #" + IntegerToString(tickets[k]) + " failed: " + GG_ErrText(err));
        }
      return moved;
     }

   string            StatusLine(void)
     {
      return StringFormat("guard=%s emergency=%s halted=%s trades=%d/%d floating=%.2f closed=%.2f cap=%.2f",
                          GG_BlockText(m_lastReason), m_cfg.emergencyStop ? "Y" : "N",
                          m_state.dayHalted ? "Y" : "N", m_state.tradesToday, m_cfg.maxTradesPerDay,
                          m_lastFloating, m_lastClosed, LossCapMoney());
     }
  };

#endif // GOLDGRID_GUARDMANAGER_MQH
//+------------------------------------------------------------------+
