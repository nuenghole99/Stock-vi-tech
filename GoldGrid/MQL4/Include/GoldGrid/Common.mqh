//+------------------------------------------------------------------+
//| GoldGrid/Common.mqh                                              |
//| ค่าคงที่, enum และฟังก์ชันช่วยที่ทุกโมดูลใช้ร่วมกัน                         |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_COMMON_MQH
#define GOLDGRID_COMMON_MQH

#include <stdlib.mqh>   // ErrorDescription()

#define GG_VERSION            "0.2.0"
#define GG_NAME               "GoldGrid"

// เฟสแรก: บังคับใช้บัญชี DEMO เท่านั้น (ไม่ใช่ input เพื่อกันเปิดโดยไม่ตั้งใจ)
#define GG_DEMO_ONLY          true

// เพดานจำนวนไม้ต่อวันตามกติกา (input ตั้งต่ำกว่านี้ได้ แต่สูงกว่าไม่ได้)
#define GG_HARD_MAX_TRADES    5

// ใช้แทน "margin level เป็นอนันต์" เมื่อยังไม่มี margin ถูกใช้
#define GG_MARGIN_LEVEL_INF   1.0e9

//--- เหตุผลที่ guard ไม่อนุญาตให้วางไม้ใหม่ (เรียงตามลำดับความสำคัญ)
enum ENUM_GG_BLOCK
  {
   GG_OK = 0,                 // วางได้
   GG_BLOCK_EMERGENCY,        // EmergencyStop เปิดอยู่
   GG_BLOCK_DAY_HALT,         // ชนเพดานขาดทุนวันนี้แล้ว
   GG_BLOCK_TRADE_DISABLED,   // เทอร์มินัล/โบรกเกอร์ไม่อนุญาตเทรด
   GG_BLOCK_DAILY_LIMIT,      // ครบจำนวนไม้ต่อวัน
   GG_BLOCK_SPREAD,           // spread กว้างเกิน
   GG_BLOCK_MARGIN            // margin level ต่ำกว่าเกณฑ์
  };

//--- สาเหตุที่หยุดวัน (เก็บใน GlobalVariable เป็นตัวเลข)
#define GG_HALT_NONE          0
#define GG_HALT_LOSS_CAP      1

//--- ผลของการกู้สถานะตอน OnInit
#define GG_RESTORE_FRESH      0   // ไม่มีสถานะเก่า เริ่มใหม่
#define GG_RESTORE_SAME_DAY   1   // กู้สถานะของวันเดียวกัน
#define GG_RESTORE_NEW_DAY    2   // สถานะเก่าเป็นของวันก่อน เริ่มวันใหม่

string GG_BlockText(const int reason)
  {
   switch(reason)
     {
      case GG_OK:                   return "OK";
      case GG_BLOCK_EMERGENCY:      return "EMERGENCY_STOP";
      case GG_BLOCK_DAY_HALT:       return "DAY_HALTED";
      case GG_BLOCK_TRADE_DISABLED: return "TRADE_DISABLED";
      case GG_BLOCK_DAILY_LIMIT:    return "DAILY_LIMIT";
      case GG_BLOCK_SPREAD:         return "SPREAD_TOO_WIDE";
      case GG_BLOCK_MARGIN:         return "MARGIN_LEVEL_LOW";
     }
   return "UNKNOWN(" + IntegerToString(reason) + ")";
  }

//+------------------------------------------------------------------+
//| Log                                                              |
//+------------------------------------------------------------------+
void GG_Log(const string level, const string msg)
  {
   Print("[", GG_NAME, "][", level, "] ", msg);
  }

//+------------------------------------------------------------------+
//| เวลา: วันตามเวลาเซิร์ฟเวอร์ (datetime ของ MT4 คือเวลาเซิร์ฟเวอร์อยู่แล้ว)    |
//+------------------------------------------------------------------+
int GG_DayKey(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;   // เช่น 20250304
  }

datetime GG_DayStart(const datetime t)
  {
   return t - (t % 86400);                            // เที่ยงคืนเซิร์ฟเวอร์
  }

//+------------------------------------------------------------------+
//| ชนิดออเดอร์                                                       |
//+------------------------------------------------------------------+
bool GG_IsBuyType(const int type)
  {
   return (type == OP_BUY || type == OP_BUYLIMIT || type == OP_BUYSTOP);
  }

bool GG_IsMarketType(const int type)
  {
   return (type == OP_BUY || type == OP_SELL);
  }

double GG_SpreadPoints(const string symbol)
  {
   double pt = MarketInfo(symbol, MODE_POINT);
   if(pt <= 0)
      return 0;
   return (MarketInfo(symbol, MODE_ASK) - MarketInfo(symbol, MODE_BID)) / pt;
  }

#endif // GOLDGRID_COMMON_MQH
//+------------------------------------------------------------------+
