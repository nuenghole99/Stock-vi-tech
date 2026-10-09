//+------------------------------------------------------------------+
//| GoldGrid/OrderScan.mqh                                           |
//| สแกนออเดอร์ของ EA (กรองด้วย magic + symbol) แบบอ่านอย่างเดียว           |
//| ใช้ทั้งตอนกู้สถานะหลังรีสตาร์ต และตอนคำนวณ guard ทุก tick                 |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_ORDERSCAN_MQH
#define GOLDGRID_ORDERSCAN_MQH

#include "Common.mqh"

// ต้อง OrderSelect มาก่อนเรียก
bool GG_IsOurs(const int magic, const string symbol)
  {
   return (OrderMagicNumber() == magic && OrderSymbol() == symbol);
  }

// จำนวนไม้ที่เปิดอยู่ (market) ของ EA
int GG_CountMarket(const int magic, const string symbol)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(GG_IsOurs(magic, symbol) && GG_IsMarketType(OrderType()))
         n++;
     }
   return n;
  }

// จำนวน pending order ของ EA
int GG_CountPending(const int magic, const string symbol)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(GG_IsOurs(magic, symbol) && !GG_IsMarketType(OrderType()))
         n++;
     }
   return n;
  }

int GG_CountAll(const int magic, const string symbol)
  {
   return GG_CountMarket(magic, symbol) + GG_CountPending(magic, symbol);
  }

// floating P/L (profit + swap + commission) ของไม้ที่เปิดอยู่
double GG_FloatingPL(const int magic, const string symbol)
  {
   double pl = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(GG_IsOurs(magic, symbol) && GG_IsMarketType(OrderType()))
         pl += OrderProfit() + OrderSwap() + OrderCommission();
     }
   return pl;
  }

// P/L ของไม้ที่ปิดตั้งแต่ since: net = รวมทั้งหมด, lossOnly = รวมเฉพาะไม้ที่ขาดทุน (<= 0)
// หมายเหตุ: ประวัติที่เห็นขึ้นกับแท็บ Account History ของเทอร์มินัล (ดู README)
void GG_ClosedPLSince(const int magic, const string symbol, const datetime since,
                      double &net, double &lossOnly)
  {
   net = 0;
   lossOnly = 0;
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(!GG_IsOurs(magic, symbol) || !GG_IsMarketType(OrderType()))
         continue;                          // ข้าม pending ที่ถูกลบ
      if(OrderCloseTime() < since)
         continue;
      double v = OrderProfit() + OrderSwap() + OrderCommission();
      net += v;
      if(v < 0)
         lossOnly += v;
     }
  }

// จำนวน "ไม้ที่เปิด (fill) แล้ว" ตั้งแต่ since — ทั้งที่ยังเปิดอยู่และที่ปิดไปแล้ว
// pending ที่ยังไม่ fill หรือถูกยกเลิก ไม่นับ (guard นับ pending ค้างแยกต่างหาก)
int GG_CountFilledSince(const int magic, const string symbol, const datetime since)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(GG_IsOurs(magic, symbol) && GG_IsMarketType(OrderType()) && OrderOpenTime() >= since)
         n++;
     }
   for(int j = OrdersHistoryTotal() - 1; j >= 0; j--)
     {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(GG_IsOurs(magic, symbol) && GG_IsMarketType(OrderType()) && OrderOpenTime() >= since)
         n++;
     }
   return n;
  }

#endif // GOLDGRID_ORDERSCAN_MQH
//+------------------------------------------------------------------+
