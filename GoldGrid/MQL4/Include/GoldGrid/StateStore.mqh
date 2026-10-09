//+------------------------------------------------------------------+
//| GoldGrid/StateStore.mqh                                          |
//| เก็บสถานะรายวันใน GlobalVariables ของเทอร์มินัล เพื่อกู้คืนหลังรีสตาร์ต      |
//|   - equity ต้นวัน                                                 |
//|   - จำนวนไม้ที่เปิดวันนี้                                              |
//|   - flag หยุดวัน (ชนเพดานขาดทุน) + สาเหตุ                             |
//| ไม่มีการส่งออเดอร์ในไฟล์นี้                                             |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_STATESTORE_MQH
#define GOLDGRID_STATESTORE_MQH

#include "Common.mqh"

#define GG_STATE_SCHEMA   1

class CStateStore
  {
private:
   string            m_prefix;

   string            Key(const string name) { return m_prefix + name; }

   double            GetGV(const string name, const double def)
     {
      string k = Key(name);
      if(GlobalVariableCheck(k))
         return GlobalVariableGet(k);
      return def;
     }

   bool              SetGV(const string name, const double value)
     {
      if(GlobalVariableSet(Key(name), value) == 0)
        {
         GG_Log("ERROR", "GlobalVariableSet(" + Key(name) + ") failed err=" + IntegerToString(GetLastError()));
         return false;
        }
      return true;
     }

public:
   //--- สถานะในหน่วยความจำ (อ่านได้โดยตรง; เขียนผ่านเมธอดเพื่อให้ถูก persist)
   int               dayKey;            // YYYYMMDD ตามเวลาเซิร์ฟเวอร์
   double            dayStartEquity;    // equity ณ ต้นวัน
   int               tradesToday;       // จำนวนไม้ที่ fill วันนี้
   bool              dayHalted;         // true = หยุดเปิดไม้ใหม่จนข้ามวัน
   int               haltReason;        // GG_HALT_*

                     CStateStore(void) { m_prefix = ""; Reset(); }

   //--- prefix แยกตาม magic + symbol และแยก tester ออกจากบัญชีจริง
   //    (ชื่อ GlobalVariable ยาวได้ไม่เกิน 63 ตัวอักษร)
   static string     BuildPrefix(const int magic, const string symbol, const bool testing)
     {
      string p = "GG_" + IntegerToString(magic) + "_" + symbol + "_";
      if(testing)
         p += "T_";
      return p;
     }

   void              Init(const string prefix) { m_prefix = prefix; Reset(); }
   string            Prefix(void) { return m_prefix; }

   void              Reset(void)
     {
      dayKey         = 0;
      dayStartEquity = 0;
      tradesToday    = 0;
      dayHalted      = false;
      haltReason     = GG_HALT_NONE;
     }

   bool              Exists(void) { return GlobalVariableCheck(Key("DayKey")); }

   //--- โหลดจาก GlobalVariables; คืน false ถ้าไม่มีสถานะที่บันทึกไว้
   bool              Load(void)
     {
      Reset();
      if(!Exists())
         return false;
      dayKey         = (int)GetGV("DayKey", 0);
      dayStartEquity = GetGV("DayEq", 0);
      tradesToday    = (int)GetGV("Trades", 0);
      dayHalted      = (GetGV("Halt", 0) != 0);
      haltReason     = (int)GetGV("HaltWhy", GG_HALT_NONE);
      return true;
     }

   bool              Save(void)
     {
      bool ok = true;
      ok = SetGV("Schema",  GG_STATE_SCHEMA) && ok;
      ok = SetGV("DayEq",   dayStartEquity)  && ok;
      ok = SetGV("Trades",  tradesToday)     && ok;
      ok = SetGV("Halt",    dayHalted ? 1 : 0) && ok;
      ok = SetGV("HaltWhy", haltReason)      && ok;
      ok = SetGV("DayKey",  dayKey)          && ok;   // เขียนท้ายสุด = ตัวบอกว่าบันทึกครบ
      GlobalVariablesFlush();                         // ลงดิสก์ทันที กันเทอร์มินัลแครช
      return ok;
     }

   //--- ลบ GlobalVariables ทั้งหมดของ prefix นี้ (ใช้ในชุดทดสอบ/รีเซ็ตด้วยมือ)
   void              Clear(void)
     {
      GlobalVariablesDeleteAll(m_prefix);
      Reset();
     }

   //--- เริ่มวันใหม่: เก็บ equity ต้นวัน, รีเซ็ตตัวนับและ flag หยุดวัน (ไม่ save)
   void              StartNewDay(const int newDayKey, const double equity)
     {
      dayKey         = newDayKey;
      dayStartEquity = equity;
      tradesToday    = 0;
      dayHalted      = false;
      haltReason     = GG_HALT_NONE;
     }

   //--- เรียกทุก tick/timer: ถ้าข้ามวันเซิร์ฟเวอร์แล้ว เริ่มวันใหม่และ save; คืน true เมื่อข้ามวัน
   bool              RollDayIfNeeded(const datetime now, const double equity)
     {
      int today = GG_DayKey(now);
      if(today == dayKey)
         return false;
      StartNewDay(today, equity);
      Save();
      return true;
     }

   //--- ตัวนับไม้วันนี้ไม่ลดลงภายในวัน: ใช้ค่ามากสุดระหว่างที่จำไว้กับที่สแกนได้
   bool              MergeTradesCount(const int scanned)
     {
      if(scanned <= tradesToday)
         return false;
      tradesToday = scanned;
      Save();
      return true;
     }

   void              IncTrades(void)
     {
      tradesToday++;
      Save();
     }

   void              SetHalted(const int reason)
     {
      dayHalted  = true;
      haltReason = reason;
      Save();
     }

   //--- เรียกตอน OnInit: โหลดสถานะเดิม แล้วรวมกับผลสแกนออเดอร์ (scannedTradesToday)
   //    คืน GG_RESTORE_*
   int               Restore(const datetime now, const double equity, const int scannedTradesToday)
     {
      int today  = GG_DayKey(now);
      int result = GG_RESTORE_SAME_DAY;
      if(!Load())
        {
         StartNewDay(today, equity);
         result = GG_RESTORE_FRESH;
        }
      else
         if(dayKey != today)
           {
            StartNewDay(today, equity);
            result = GG_RESTORE_NEW_DAY;
           }
      if(dayStartEquity <= 0)                         // ค่าเสีย/ไม่สมเหตุผล
         dayStartEquity = equity;
      if(scannedTradesToday > tradesToday)
         tradesToday = scannedTradesToday;
      Save();
      return result;
     }

   string            ToString(void)
     {
      return StringFormat("day=%d startEq=%.2f trades=%d halted=%s reason=%d",
                          dayKey, dayStartEquity, tradesToday, dayHalted ? "Y" : "N", haltReason);
     }
  };

#endif // GOLDGRID_STATESTORE_MQH
//+------------------------------------------------------------------+
