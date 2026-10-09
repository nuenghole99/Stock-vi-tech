//+------------------------------------------------------------------+
//| GoldGrid/OrderManager.mqh                                        |
//| วางกริด BUY LIMIT / SELL LIMIT                                     |
//|                                                                  |
//| เฟส 1: ยังไม่วางออเดอร์ (stub) — รอให้ GuardManager/StateStore ผ่านเทสก่อน |
//|                                                                  |
//| TODO(phase 2) กติกาที่ต้องทำตาม:                                       |
//|  - เรียก guard.CheckCanOpen(LotSize) == GG_OK ก่อนวางทุกไม้              |
//|  - SL = guard.InitialSLFor(type, price) ส่งไปพร้อม OrderSend เสมอ       |
//|  - lot = LotSize คงที่ ห้าม martingale / ห้ามเพิ่ม lot ตามการขาดทุน       |
//|  - Limit order เท่านั้น ห่าง GridDistancePoints (ไม่ไล่ราคา)              |
//|  - Dry-run: log แทนการส่ง                                           |
//|  - retry ด้วย GG_IsTransientError (เหมือน TradeOps)                  |
//|  - ไม่วางซ้ำ: สแกนออเดอร์ magic เดิมที่ระดับราคาเดียวกันก่อนวาง            |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_ORDERMANAGER_MQH
#define GOLDGRID_ORDERMANAGER_MQH

#include "Common.mqh"
#include "GuardManager.mqh"

class COrderManager
  {
private:
   bool              m_warned;

public:
                     COrderManager(void) { m_warned = false; }

   void              OnTick(const int guardReason)
     {
      if(!m_warned)
        {
         GG_Log("INFO", "OrderManager is a stub in phase 1: no orders will be placed.");
         m_warned = true;
        }
     }
  };

#endif // GOLDGRID_ORDERMANAGER_MQH
//+------------------------------------------------------------------+
