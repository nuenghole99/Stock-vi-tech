//+------------------------------------------------------------------+
//| GoldGridTests.mq4                                                |
//| ชุดทดสอบ GuardManager + StateStore — รันใน Strategy Tester เท่านั้น    |
//|                                                                  |
//| 1) Unit tests (OnInit): ฟังก์ชัน pure ของ guard + GlobalVariables    |
//| 2) Scenario tests (OnTick): เปิดไม้ทดสอบจริงในเทสเตอร์ แล้วตรวจว่า       |
//|    trailing / dry-run / enforce SL / emergency / กู้สถานะ /          |
//|    loss cap + หยุดวัน + รีเซ็ตข้ามวัน ทำงานถูกต้อง                     |
//|                                                                  |
//| ผล: Journal ของ tester + ไฟล์ tester/files/GoldGridTests_result.txt |
//+------------------------------------------------------------------+
#property copyright "GoldGrid"
#property version   "0.10"
#property strict

#include <GoldGrid/TestKit.mqh>
#include <GoldGrid/Common.mqh>
#include <GoldGrid/OrderScan.mqh>
#include <GoldGrid/StateStore.mqh>
#include <GoldGrid/GuardManager.mqh>
#include <GoldGrid/Notifier.mqh>

input int    TestMagic          = 999001;  // magic สำหรับไม้ทดสอบ
input bool   RunScenarioTests   = true;    // false = รันเฉพาะ unit tests
input int    TrailObserveTicks  = 3000;    // จำนวน tick ที่เฝ้าดู trailing
input bool   WaitDayRollover    = true;    // รอข้ามวันเพื่อทดสอบการรีเซ็ต flag หยุดวัน
input int    TestSLPoints       = 500;
input int    TestTrailStart     = 200;
input int    TestTrailDistance  = 150;
input int    TestMaxSpread      = 1000;    // หลวมไว้ เพื่อไม่ให้ spread บล็อกเทสอื่น

#define UNIT_PREFIX      "GGTEST_U_"
#define SCEN_PREFIX      "GGTEST_S_"
#define RESULT_FILE      "GoldGridTests_result.txt"

#define PH_TRAIL_OPEN    0
#define PH_TRAIL_RUN     1
#define PH_DRYRUN        2
#define PH_ENFORCE_SL    3
#define PH_EMERGENCY     4
#define PH_RESTORE       5
#define PH_LOSSCAP       6
#define PH_WAIT_DAY      7
#define PH_DONE          8

CNotifier     g_notifier;
CStateStore   g_sState;
CGuardManager g_guard;      // โหมดจริง (ในเทสเตอร์)
CGuardManager g_guardDry;   // โหมด dry-run
int           g_phase = PH_TRAIL_OPEN;
bool          g_reported = false;
double        g_lot = 0.01;

// trailing scenario
int    g_tB = -1, g_tS = -1;
double g_prevSlB = 0, g_prevSlS = 0, g_initSlB = 0, g_initSlS = 0;
bool   g_actB = false, g_actS = false;
int    g_trailTicks = 0, g_trailViolations = 0;

// day rollover scenario
int    g_haltDayKey = 0;
int    g_haltLeaks = 0;

//==================================================================
// helpers
//==================================================================
void MakeCfg(GuardConfig &c, const bool dryRun)
  {
   c.magic                 = TestMagic;
   c.lossCapPct            = 5.0;
   c.lossCapUseNetClosed   = false;
   c.slPoints              = TestSLPoints;
   c.trailStartPoints      = TestTrailStart;
   c.trailDistancePoints   = TestTrailDistance;
   c.trailStepPoints       = 10;
   c.breakevenOffsetPoints = 0;
   c.maxSpreadPoints       = TestMaxSpread;
   c.minMarginLevelPct     = 0;
   c.maxTradesPerDay       = GG_HARD_MAX_TRADES;
   c.maxRetries            = 3;
   c.slippagePoints        = 30;
   c.emergencyStop         = false;
   c.dryRun                = dryRun;
  }

// เปิดไม้ทดสอบโดยตรง (ไม่ใช่ OrderManager) slPts=0 = ไม่ใส่ SL
int T_Open(const int type, const int slPts, const int offsetPts = 0)
  {
   RefreshRates();
   double price = 0;
   if(type == OP_BUY)            price = Ask;
   else if(type == OP_SELL)      price = Bid;
   else if(type == OP_BUYLIMIT)  price = Ask - offsetPts * Point;
   else if(type == OP_SELLLIMIT) price = Bid + offsetPts * Point;
   price = NormalizeDouble(price, Digits);
   double sl = (slPts > 0) ? CGuardManager::CalcInitialSL(type, price, slPts, Point, Digits) : 0;
   int t = OrderSend(Symbol(), type, g_lot, price, 30, sl, 0, "GGTEST", TestMagic, 0, clrNONE);
   if(t < 0)
      Print("[TEST] OrderSend type=", type, " failed err=", GetLastError());
   return t;
  }

bool T_IsOpen(const int ticket)
  {
   return ticket >= 0 && OrderSelect(ticket, SELECT_BY_TICKET) && OrderCloseTime() == 0;
  }

void T_SetOkSnapshot(GuardSnapshot &s)
  {
   s.emergency            = false;
   s.dayHalted            = false;
   s.tradeAllowed         = true;
   s.tradesToday          = 0;
   s.pendingCount         = 0;
   s.maxTradesPerDay      = 5;
   s.spreadPoints         = 30;
   s.maxSpreadPoints      = 50;
   s.projectedMarginLevel = 2000;
   s.minMarginLevelPct    = 500;
  }

//==================================================================
// UNIT TESTS
//==================================================================
void Test_DayHelpers()
  {
   TK_Section("Common: day key / day start");
   TK_EqI("daykey 23:59:59", 20250304, GG_DayKey(D'2025.03.04 23:59:59'));
   TK_EqI("daykey midnight", 20250305, GG_DayKey(D'2025.03.05 00:00:00'));
   TK_True("daystart", GG_DayStart(D'2025.03.04 13:45:10') == D'2025.03.04 00:00:00');
   TK_True("buy types", GG_IsBuyType(OP_BUY) && GG_IsBuyType(OP_BUYLIMIT) && !GG_IsBuyType(OP_SELLLIMIT));
   TK_True("market types", GG_IsMarketType(OP_SELL) && !GG_IsMarketType(OP_BUYLIMIT));
  }

void Test_LossCap()
  {
   TK_Section("Guard: loss cap");
   TK_EqD("cap amount 5% of 10000", -500.0, CGuardManager::LossCapAmount(10000, 5));
   TK_True("exactly -5% -> hit",   CGuardManager::IsLossCapHit(-400, -100, 10000, 5));
   TK_True("-4.9999% -> not hit", !CGuardManager::IsLossCapHit(-399.99, -100, 10000, 5));
   TK_True("floating only -> hit", CGuardManager::IsLossCapHit(-600, 0, 10000, 5));
   TK_True("closed only -> hit",   CGuardManager::IsLossCapHit(0, -501, 10000, 5));
   TK_True("profit offsets",      !CGuardManager::IsLossCapHit(100, -550, 10000, 5));
   TK_True("invalid equity -> no false trigger", !CGuardManager::IsLossCapHit(-1000, 0, 0, 5));
   TK_EqD("closed component loss-only", -100, CGuardManager::ClosedComponent(50, -100, false));
   TK_EqD("closed component net",         50, CGuardManager::ClosedComponent(50, -100, true));
  }

void Test_SpreadMarginLimit()
  {
   TK_Section("Guard: spread / margin / daily limit");
   TK_True("spread below max",  CGuardManager::IsSpreadOK(30, 50));
   TK_True("spread equal max",  CGuardManager::IsSpreadOK(50, 50));
   TK_True("spread above max", !CGuardManager::IsSpreadOK(51, 50));

   TK_EqD("margin lvl no margin = INF", GG_MARGIN_LEVEL_INF, CGuardManager::ProjectedMarginLevel(10000, 0, 0));
   TK_EqD("margin lvl 10000/(100+100)", 5000, CGuardManager::ProjectedMarginLevel(10000, 100, 100));
   TK_True("margin 5000% >= 500%",  CGuardManager::IsMarginOK(5000, 500));
   TK_True("margin 100% < 500%",   !CGuardManager::IsMarginOK(CGuardManager::ProjectedMarginLevel(100, 50, 50), 500));
   TK_True("min 0 = always ok",     CGuardManager::IsMarginOK(1, 0));

   TK_True("4 trades, 0 pending ok",     CGuardManager::IsDailyLimitOK(4, 0, 5));
   TK_True("5 trades blocked",          !CGuardManager::IsDailyLimitOK(5, 0, 5));
   TK_True("4 trades + 1 pending blocked", !CGuardManager::IsDailyLimitOK(4, 1, 5));
   TK_True("0 trades + 5 pending blocked", !CGuardManager::IsDailyLimitOK(0, 5, 5));
  }

void Test_Evaluate()
  {
   TK_Section("Guard: Evaluate()");
   GuardSnapshot s;
   T_SetOkSnapshot(s);
   TK_EqI("all ok", GG_OK, CGuardManager::Evaluate(s));

   T_SetOkSnapshot(s); s.emergency = true;
   TK_EqI("emergency", GG_BLOCK_EMERGENCY, CGuardManager::Evaluate(s));
   T_SetOkSnapshot(s); s.dayHalted = true;
   TK_EqI("day halted", GG_BLOCK_DAY_HALT, CGuardManager::Evaluate(s));
   T_SetOkSnapshot(s); s.tradeAllowed = false;
   TK_EqI("trade disabled", GG_BLOCK_TRADE_DISABLED, CGuardManager::Evaluate(s));
   T_SetOkSnapshot(s); s.tradesToday = 5;
   TK_EqI("daily limit", GG_BLOCK_DAILY_LIMIT, CGuardManager::Evaluate(s));
   T_SetOkSnapshot(s); s.tradesToday = 3; s.pendingCount = 2;
   TK_EqI("daily limit incl. pending", GG_BLOCK_DAILY_LIMIT, CGuardManager::Evaluate(s));
   T_SetOkSnapshot(s); s.spreadPoints = 80;
   TK_EqI("spread", GG_BLOCK_SPREAD, CGuardManager::Evaluate(s));
   T_SetOkSnapshot(s); s.projectedMarginLevel = 300;
   TK_EqI("margin", GG_BLOCK_MARGIN, CGuardManager::Evaluate(s));

   T_SetOkSnapshot(s); s.emergency = true; s.dayHalted = true; s.spreadPoints = 999;
   TK_EqI("priority: emergency first", GG_BLOCK_EMERGENCY, CGuardManager::Evaluate(s));
   T_SetOkSnapshot(s); s.dayHalted = true; s.tradesToday = 9;
   TK_EqI("priority: halt before limit", GG_BLOCK_DAY_HALT, CGuardManager::Evaluate(s));
  }

void Test_InitialSL()
  {
   TK_Section("Guard: initial SL");
   TK_EqD("buylimit SL",  1985.00, CGuardManager::CalcInitialSL(OP_BUYLIMIT, 1990.00, 500, 0.01, 2));
   TK_EqD("selllimit SL", 2015.00, CGuardManager::CalcInitialSL(OP_SELLLIMIT, 2010.00, 500, 0.01, 2));
   TK_EqD("buy SL 3-digit", 1989.500, CGuardManager::CalcInitialSL(OP_BUY, 1990.000, 500, 0.001, 3));
   TK_True("valid buy SL",            CGuardManager::IsSLValid(OP_BUYLIMIT, 1990, 1985));
   TK_True("buy SL above entry bad", !CGuardManager::IsSLValid(OP_BUYLIMIT, 1990, 1995));
   TK_True("sell SL below entry bad",!CGuardManager::IsSLValid(OP_SELLLIMIT, 2010, 2005));
   TK_True("SL 0 invalid",           !CGuardManager::IsSLValid(OP_SELL, 2000, 0));
  }

// shorthand: point 0.01, digits 2, start 200, step 10, be 0, stop 0 (ยกเว้นระบุ)
double TS(const int type, const double open, const double curSL, const double bid, const double ask,
          const int dist, const int beOff = 0, const int stopLvl = 0)
  {
   return CGuardManager::CalcTrailingSL(type, open, curSL, bid, ask, 0.01, 2, 200, dist, 10, beOff, stopLvl);
  }

void Test_Trailing()
  {
   TK_Section("Guard: trailing SL (BUY)");
   TK_EqD("199 pts profit -> no trail", 0,       TS(OP_BUY, 2000.00, 1995.00, 2001.99, 2002.29, 150));
   TK_EqD("200 pts -> SL bid-150",      2000.50, TS(OP_BUY, 2000.00, 1995.00, 2002.00, 2002.30, 150));
   TK_EqD("no SL yet -> set",           2000.50, TS(OP_BUY, 2000.00, 0,       2002.00, 2002.30, 150));
   TK_EqD("dist>start -> breakeven floor", 2000.00, TS(OP_BUY, 2000.00, 1995.00, 2002.00, 2002.30, 250));
   TK_EqD("be offset 30",               2000.30, TS(OP_BUY, 2000.00, 1995.00, 2002.00, 2002.30, 250, 30));
   TK_EqD("never loosen",               0,       TS(OP_BUY, 2000.00, 2000.60, 2002.00, 2002.30, 150));
   TK_EqD("improve < step -> skip",     0,       TS(OP_BUY, 2000.00, 2000.45, 2002.00, 2002.30, 150));
   TK_EqD("improve == step -> move",    2000.50, TS(OP_BUY, 2000.00, 2000.40, 2002.00, 2002.30, 150));
   TK_EqD("stop level clamps",          2000.80, TS(OP_BUY, 2000.00, 1995.00, 2003.00, 2003.30, 150, 0, 220));
   TK_EqD("stop level blocks below BE", 0,       TS(OP_BUY, 2000.00, 1995.00, 2002.00, 2002.30, 150, 0, 250));
   TK_EqD("pending ignored",            0,       TS(OP_BUYLIMIT, 2000.00, 1995.00, 2010.00, 2010.30, 150));

   TK_Section("Guard: trailing SL (SELL)");
   TK_EqD("199 pts profit -> no trail", 0,       TS(OP_SELL, 2000.00, 2005.00, 1997.71, 1998.01, 150));
   TK_EqD("200 pts -> SL ask+150",      1999.50, TS(OP_SELL, 2000.00, 2005.00, 1997.70, 1998.00, 150));
   TK_EqD("no SL yet -> set",           1999.50, TS(OP_SELL, 2000.00, 0,       1997.70, 1998.00, 150));
   TK_EqD("dist>start -> breakeven floor", 2000.00, TS(OP_SELL, 2000.00, 2005.00, 1997.70, 1998.00, 250));
   TK_EqD("never loosen",               0,       TS(OP_SELL, 2000.00, 1999.40, 1997.70, 1998.00, 150));
   TK_EqD("improve < step -> skip",     0,       TS(OP_SELL, 2000.00, 1999.55, 1997.70, 1998.00, 150));
   TK_EqD("stop level blocks above BE", 0,       TS(OP_SELL, 2000.00, 2005.00, 1997.70, 1998.00, 150, 0, 250));
  }

void Test_StateStore()
  {
   TK_Section("StateStore: GlobalVariables round-trip");
   TK_True("prefix live",   CStateStore::BuildPrefix(260701, "XAUUSD", false) == "GG_260701_XAUUSD_");
   TK_True("prefix tester", CStateStore::BuildPrefix(260701, "XAUUSD", true)  == "GG_260701_XAUUSD_T_");
   TK_True("GV name <= 63 chars", StringLen(CStateStore::BuildPrefix(2147483647, "XAUUSD.micro", true) + "HaltWhy") <= 63);

   CStateStore s;
   s.Init(UNIT_PREFIX);
   s.Clear();
   TK_True("no state initially", !s.Load());

   s.StartNewDay(20250304, 10000);
   s.tradesToday = 3;
   TK_True("save ok", s.Save());

   CStateStore s2;
   s2.Init(UNIT_PREFIX);
   TK_True("load ok", s2.Load());
   TK_EqI("dayKey", 20250304, s2.dayKey);
   TK_EqD("dayStartEquity", 10000, s2.dayStartEquity);
   TK_EqI("tradesToday", 3, s2.tradesToday);
   TK_True("not halted", !s2.dayHalted);

   s2.SetHalted(GG_HALT_LOSS_CAP);
   CStateStore s3;
   s3.Init(UNIT_PREFIX);
   s3.Load();
   TK_True("halt persisted", s3.dayHalted);
   TK_EqI("halt reason persisted", GG_HALT_LOSS_CAP, s3.haltReason);

   TK_Section("StateStore: trade counter");
   TK_True("merge lower ignored", !s3.MergeTradesCount(2));
   TK_EqI("still 3", 3, s3.tradesToday);
   TK_True("merge higher taken", s3.MergeTradesCount(4));
   TK_EqI("now 4", 4, s3.tradesToday);
   s3.IncTrades();
   CStateStore s3b;
   s3b.Init(UNIT_PREFIX);
   s3b.Load();
   TK_EqI("inc persisted", 5, s3b.tradesToday);

   TK_Section("StateStore: day rollover");
   TK_True("same day no roll", !s3.RollDayIfNeeded(D'2025.03.04 23:59:59', 9000));
   TK_True("same day keeps halt", s3.dayHalted);
   TK_EqD("same day keeps equity", 10000, s3.dayStartEquity);
   TK_True("next day rolls", s3.RollDayIfNeeded(D'2025.03.05 00:00:01', 9000));
   TK_EqI("new dayKey", 20250305, s3.dayKey);
   TK_EqD("new day equity", 9000, s3.dayStartEquity);
   TK_EqI("trades reset", 0, s3.tradesToday);
   TK_True("halt cleared", !s3.dayHalted);
   TK_EqI("reason cleared", GG_HALT_NONE, s3.haltReason);
   CStateStore s4;
   s4.Init(UNIT_PREFIX);
   s4.Load();
   TK_True("rollover persisted", !s4.dayHalted && s4.dayKey == 20250305);

   TK_Section("StateStore: Restore() after restart");
   s4.SetHalted(GG_HALT_LOSS_CAP);
   CStateStore r1;
   r1.Init(UNIT_PREFIX);
   TK_EqI("same day", GG_RESTORE_SAME_DAY, r1.Restore(D'2025.03.05 10:00:00', 8000, 2));
   TK_True("same day stays halted", r1.dayHalted);
   TK_EqD("same day keeps start equity", 9000, r1.dayStartEquity);
   TK_EqI("trades = max(saved 0, scanned 2)", 2, r1.tradesToday);

   CStateStore r2;
   r2.Init(UNIT_PREFIX);
   TK_EqI("stale -> new day", GG_RESTORE_NEW_DAY, r2.Restore(D'2025.03.06 10:00:00', 8000, 0));
   TK_True("new day not halted", !r2.dayHalted);
   TK_EqD("new day equity = current", 8000, r2.dayStartEquity);

   r2.Clear();
   CStateStore r3;
   r3.Init(UNIT_PREFIX);
   TK_EqI("fresh", GG_RESTORE_FRESH, r3.Restore(D'2025.03.06 10:00:00', 7000, 1));
   TK_EqD("fresh equity", 7000, r3.dayStartEquity);
   TK_EqI("fresh trades from scan", 1, r3.tradesToday);

   GlobalVariableSet(UNIT_PREFIX + "DayEq", 0);
   CStateStore r4;
   r4.Init(UNIT_PREFIX);
   r4.Restore(D'2025.03.06 11:00:00', 6500, 0);
   TK_EqD("corrupt equity repaired", 6500, r4.dayStartEquity);

   r4.Clear();
   TK_True("clear removes GVs", !GlobalVariableCheck(UNIT_PREFIX + "DayKey") && !GlobalVariableCheck(UNIT_PREFIX + "Halt"));
  }

void RunUnitTests()
  {
   Test_DayHelpers();
   Test_LossCap();
   Test_SpreadMarginLimit();
   Test_Evaluate();
   Test_InitialSL();
   Test_Trailing();
   Test_StateStore();
   Print("[TEST] unit tests done: pass=", g_tkPass, " fail=", g_tkFail);
  }

//==================================================================
// SCENARIO TESTS (one phase per tick)
//==================================================================
void CheckTrailInvariant(const int t, double &prevSL, bool &activated, const double initSL)
  {
   if(!T_IsOpen(t))
      return;
   double sl = OrderStopLoss();
   double op = OrderOpenPrice();
   double h  = Point * 0.5;
   bool moved = MathAbs(sl - initSL) > h;
   if(OrderType() == OP_BUY)
     {
      if(sl < prevSL - h)        { g_trailViolations++; Print("[TEST] BUY SL moved back ", prevSL, " -> ", sl); }
      if(moved && sl < op - h)   { g_trailViolations++; Print("[TEST] BUY trailed SL below BE ", sl, " < ", op); }
     }
   else
     {
      if(sl > prevSL + h)        { g_trailViolations++; Print("[TEST] SELL SL moved back ", prevSL, " -> ", sl); }
      if(moved && sl > op + h)   { g_trailViolations++; Print("[TEST] SELL trailed SL above BE ", sl, " > ", op); }
     }
   if(moved)
      activated = true;
   prevSL = sl;
  }

void Phase_TrailOpen()
  {
   TK_Section("Scenario: trailing");
   g_tB = T_Open(OP_BUY, TestSLPoints);
   g_tS = T_Open(OP_SELL, TestSLPoints);
   TK_True("opened BUY+SELL", g_tB >= 0 && g_tS >= 0);
   if(g_tB < 0 || g_tS < 0)
     {
      g_guard.CloseAll("test cleanup");
      g_phase = PH_DRYRUN;
      return;
     }
   OrderSelect(g_tB, SELECT_BY_TICKET); g_initSlB = OrderStopLoss(); g_prevSlB = g_initSlB;
   OrderSelect(g_tS, SELECT_BY_TICKET); g_initSlS = OrderStopLoss(); g_prevSlS = g_initSlS;
   TK_True("both have broker-side SL", g_initSlB > 0 && g_initSlS > 0);
   g_phase = PH_TRAIL_RUN;
  }

void Phase_TrailRun()
  {
   g_guard.ManageTrailing();
   CheckTrailInvariant(g_tB, g_prevSlB, g_actB, g_initSlB);
   CheckTrailInvariant(g_tS, g_prevSlS, g_actS, g_initSlS);
   g_trailTicks++;
   bool bothClosed = !T_IsOpen(g_tB) && !T_IsOpen(g_tS);
   if(!bothClosed && g_trailTicks < TrailObserveTicks)
      return;

   TK_EqI("no SL regression / below-BE trail", 0, g_trailViolations);
   if(g_actB || g_actS)
      TK_True("trailing activated at least once", true);
   else
      TK_Skip("trailing activated", "price never moved TrailStart points in favour; increase TrailObserveTicks");
   TK_EqI("CloseAll leaves nothing", 0, g_guard.CloseAll("test cleanup"));
   g_phase = PH_DRYRUN;
  }

void Phase_DryRun()
  {
   TK_Section("Scenario: dry-run");
   int t = T_Open(OP_BUY, TestSLPoints);
   if(t < 0)
     {
      TK_True("open for dry-run", false);
      g_phase = PH_ENFORCE_SL;
      return;
     }
   g_guardDry.CloseAll("dry test");
   TK_True("dry-run CloseAll sends nothing", T_IsOpen(t));
   double slBefore = OrderStopLoss();
   int err = 0;
   GG_OrderModifyRetry(t, slBefore + 10 * Point, 0, 3, true, err);
   OrderSelect(t, SELECT_BY_TICKET);
   TK_EqD("dry-run modify sends nothing", slBefore, OrderStopLoss(), Point * 0.5);

   // loss cap in dry-run: guard must still halt the day (but not close)
   datetime now = TimeCurrent();
   g_sState.StartNewDay(GG_DayKey(now), AccountEquity());
   g_sState.Save();
   double floating = GG_FloatingPL(TestMagic, Symbol());
   if(floating < 0)
     {
      g_guardDry.SetLossCapPct((-floating * 0.5) / g_sState.dayStartEquity * 100.0);
      TK_True("dry-run loss cap detected", g_guardDry.CheckLossCap(now));
      TK_True("dry-run halts day", g_sState.dayHalted);
      TK_True("dry-run did not close order", T_IsOpen(t));
     }
   else
      TK_Skip("dry-run loss cap", "floating P/L not negative (zero spread?)");

   g_sState.StartNewDay(GG_DayKey(now), AccountEquity());
   g_sState.Save();
   TK_EqI("real CloseAll closes", 0, g_guard.CloseAll("test cleanup"));
   g_phase = PH_ENFORCE_SL;
  }

void Phase_EnforceSL()
  {
   TK_Section("Scenario: enforce broker-side SL");
   int t1 = T_Open(OP_BUY, 0);
   int t2 = T_Open(OP_BUYLIMIT, 0, 1000);
   TK_True("opened orders without SL", t1 >= 0 && t2 >= 0);
   g_guard.EnforceStopLoss();
   if(t1 >= 0 && OrderSelect(t1, SELECT_BY_TICKET))
      TK_EqD("market BUY got SL", CGuardManager::CalcInitialSL(OP_BUY, OrderOpenPrice(), TestSLPoints, Point, Digits),
             OrderStopLoss(), Point * 0.5);
   if(t2 >= 0 && OrderSelect(t2, SELECT_BY_TICKET))
      TK_EqD("BUYLIMIT got SL", CGuardManager::CalcInitialSL(OP_BUYLIMIT, OrderOpenPrice(), TestSLPoints, Point, Digits),
             OrderStopLoss(), Point * 0.5);
   TK_EqI("cleanup", 0, g_guard.CloseAll("test cleanup"));
   g_phase = PH_EMERGENCY;
  }

void Phase_Emergency()
  {
   TK_Section("Scenario: emergency stop");
   T_Open(OP_BUY, TestSLPoints);
   T_Open(OP_SELLLIMIT, TestSLPoints, 1000);
   TK_True("orders exist before", GG_CountAll(TestMagic, Symbol()) == 2);
   g_guard.SetEmergency(true);
   TK_True("HandleEmergency active", g_guard.HandleEmergency());
   TK_EqI("everything closed/deleted", 0, GG_CountAll(TestMagic, Symbol()));
   TK_EqI("can-open blocked", GG_BLOCK_EMERGENCY, g_guard.CheckCanOpen(g_lot));
   g_guard.SetEmergency(false);
   TK_True("HandleEmergency off", !g_guard.HandleEmergency());
   g_phase = PH_RESTORE;
  }

void Phase_Restore()
  {
   TK_Section("Scenario: restore after restart");
   datetime now = TimeCurrent();
   g_sState.StartNewDay(GG_DayKey(now), AccountEquity());
   g_sState.Save();
   T_Open(OP_BUY, TestSLPoints);
   T_Open(OP_BUY, TestSLPoints);
   int scanned = GG_CountFilledSince(TestMagic, Symbol(), GG_DayStart(now));
   TK_True("scan sees today's fills (>=2)", scanned >= 2, "scanned=" + IntegerToString(scanned));
   g_guard.SyncTradesToday(now);
   TK_EqI("SyncTradesToday", scanned, g_sState.tradesToday);

   // จำลองรีสตาร์ต: หน่วยความจำหาย, GV ยังอยู่, สแกนออเดอร์ใหม่
   CStateStore re;
   re.Init(SCEN_PREFIX);
   TK_EqI("restore same day", GG_RESTORE_SAME_DAY,
          re.Restore(now, AccountEquity(), GG_CountFilledSince(TestMagic, Symbol(), GG_DayStart(now))));
   TK_EqI("restored trade count", scanned, re.tradesToday);

   // GV เสีย/ถูกลบ -> ยังได้จำนวนจากการสแกน ไม่รีเซ็ตเป็น 0
   re.Clear();
   CStateStore re2;
   re2.Init(SCEN_PREFIX);
   re2.Restore(now, AccountEquity(), GG_CountFilledSince(TestMagic, Symbol(), GG_DayStart(now)));
   TK_EqI("count rebuilt from orders when GV lost", scanned, re2.tradesToday);

   g_sState.Load();
   g_guard.SetMaxTradesPerDay(scanned);
   TK_EqI("daily limit blocks", GG_BLOCK_DAILY_LIMIT, g_guard.CheckCanOpen(g_lot));
   g_guard.SetMaxTradesPerDay(GG_HARD_MAX_TRADES);
   TK_EqI("cleanup", 0, g_guard.CloseAll("test cleanup"));
   g_phase = PH_LOSSCAP;
  }

void Phase_LossCap()
  {
   TK_Section("Scenario: daily loss cap");
   datetime now = TimeCurrent();
   g_sState.StartNewDay(GG_DayKey(now), AccountEquity());
   g_sState.Save();
   g_guard.SetLossCapPct(5.0);

   // ไม้ที่ปิดขาดทุนวันนี้ต้องถูกนับ
   int tc = T_Open(OP_BUY, TestSLPoints);
   g_guard.CloseAll("realize loss");
   double net, lossOnly;
   GG_ClosedPLSince(TestMagic, Symbol(), GG_DayStart(now), net, lossOnly);
   if(tc >= 0 && lossOnly < 0)
      TK_True("closed loss counted", lossOnly < 0);
   else
      TK_Skip("closed loss counted", "no realized loss (zero spread?)");

   T_Open(OP_BUY, TestSLPoints);
   T_Open(OP_BUY, TestSLPoints);
   T_Open(OP_BUYLIMIT, TestSLPoints, 1000);
   TK_True("not hit at 5%", !g_guard.CheckLossCap(now));
   TK_True("not halted yet", !g_sState.dayHalted);

   double total = GG_FloatingPL(TestMagic, Symbol()) + lossOnly;
   if(total >= 0)
     {
      TK_Skip("loss cap trigger", "total P/L not negative at this tick");
      g_guard.CloseAll("test cleanup");
      g_phase = PH_DONE;
      return;
     }
   // ตั้งเพดานให้เท่าครึ่งหนึ่งของขาดทุนปัจจุบัน -> ต้องชนทันที
   g_guard.SetLossCapPct((-total * 0.5) / g_sState.dayStartEquity * 100.0);
   TK_True("loss cap hit", g_guard.CheckLossCap(now));
   TK_EqI("all EA orders closed + pending deleted", 0, GG_CountAll(TestMagic, Symbol()));
   TK_True("day halted", g_sState.dayHalted);
   TK_EqI("halt reason", GG_HALT_LOSS_CAP, g_sState.haltReason);
   TK_EqI("can-open = DAY_HALT", GG_BLOCK_DAY_HALT, g_guard.CheckCanOpen(g_lot));
   TK_True("still halted on next check", g_guard.CheckLossCap(now));

   CStateStore re;
   re.Init(SCEN_PREFIX);
   TK_EqI("restart same day", GG_RESTORE_SAME_DAY, re.Restore(now, AccountEquity(), 0));
   TK_True("halt survives restart", re.dayHalted);

   g_guard.SetLossCapPct(5.0);
   g_haltDayKey = g_sState.dayKey;
   g_haltLeaks = 0;
   if(WaitDayRollover)
     {
      TK_Section("Scenario: halt until next server day");
      g_phase = PH_WAIT_DAY;
     }
   else
     {
      TK_Skip("day rollover", "WaitDayRollover=false");
      g_phase = PH_DONE;
     }
  }

void Phase_WaitDay()
  {
   if(!g_sState.RollDayIfNeeded(TimeCurrent(), AccountEquity()))
     {
      if(g_guard.CheckCanOpen(g_lot) != GG_BLOCK_DAY_HALT)
         g_haltLeaks++;
      return;
     }
   TK_EqI("no can-open leak while halted", 0, g_haltLeaks);
   TK_True("dayKey changed", g_sState.dayKey != g_haltDayKey);
   TK_True("halt cleared on new day", !g_sState.dayHalted);
   TK_EqI("trades reset on new day", 0, g_sState.tradesToday);
   TK_True("can-open no longer DAY_HALT", g_guard.CheckCanOpen(g_lot) != GG_BLOCK_DAY_HALT);
   CStateStore re;
   re.Init(SCEN_PREFIX);
   re.Load();
   TK_True("new day persisted", !re.dayHalted && re.dayKey == g_sState.dayKey);
   g_phase = PH_DONE;
  }

void Finish()
  {
   if(g_reported)
      return;
   g_reported = true;
   if(RunScenarioTests && g_phase < PH_DONE)
      TK_Skip("scenario phase " + IntegerToString(g_phase), "tester ended before scenario finished (extend date range)");
   if(RunScenarioTests)
      g_guard.CloseAll("final cleanup");
   TK_Report(RESULT_FILE);
   g_sState.Clear();
   GlobalVariablesDeleteAll(UNIT_PREFIX);
  }

//==================================================================
// EVENTS
//==================================================================
int OnInit()
  {
   if(!IsTesting())
     {
      Alert("GoldGridTests must run in the Strategy Tester only.");
      return INIT_FAILED;
     }
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   g_lot = MathMax(0.01, minLot);

   GlobalVariablesDeleteAll(UNIT_PREFIX);
   GlobalVariablesDeleteAll(SCEN_PREFIX);

   RunUnitTests();

   g_notifier.Init(false, "", "", "");
   g_sState.Init(SCEN_PREFIX);
   g_sState.StartNewDay(GG_DayKey(TimeCurrent()), AccountEquity());
   g_sState.Save();
   GuardConfig real, dry;
   MakeCfg(real, false);
   MakeCfg(dry, true);
   g_guard.Init(real, Symbol(), GetPointer(g_sState), GetPointer(g_notifier));
   g_guardDry.Init(dry, Symbol(), GetPointer(g_sState), GetPointer(g_notifier));

   g_phase = RunScenarioTests ? PH_TRAIL_OPEN : PH_DONE;
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   switch(g_phase)
     {
      case PH_TRAIL_OPEN: Phase_TrailOpen(); break;
      case PH_TRAIL_RUN:  Phase_TrailRun();  break;
      case PH_DRYRUN:     Phase_DryRun();    break;
      case PH_ENFORCE_SL: Phase_EnforceSL(); break;
      case PH_EMERGENCY:  Phase_Emergency(); break;
      case PH_RESTORE:    Phase_Restore();   break;
      case PH_LOSSCAP:    Phase_LossCap();   break;
      case PH_WAIT_DAY:   Phase_WaitDay();   break;
     }
   if(g_phase == PH_DONE)
     {
      Finish();
      ExpertRemove();
     }
  }

void OnDeinit(const int reason)
  {
   Finish();
  }
//+------------------------------------------------------------------+
