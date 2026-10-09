//+------------------------------------------------------------------+
//| GoldGrid.mq4                                                     |
//| Grid EA สองทางสำหรับ XAUUSD (Limit order) — เฟสนี้: DEMO เท่านั้น      |
//|                                                                  |
//| โมดูล: StateStore, GuardManager, OrderManager, Notifier          |
//+------------------------------------------------------------------+
#property copyright "GoldGrid"
#property version   "0.20"
#property strict

#include <GoldGrid/Common.mqh>
#include <GoldGrid/StateStore.mqh>
#include <GoldGrid/GuardManager.mqh>
#include <GoldGrid/OrderManager.mqh>
#include <GoldGrid/Notifier.mqh>

//==================================================================
// INPUTS
//==================================================================
sinput string  InpSepGeneral = "===== General =====";
input int      MagicNumber         = 260701;  // Magic number ของ EA (ห้ามเปลี่ยนขณะมีไม้เปิดอยู่)
input bool     DryRun              = true;    // true = log อย่างเดียว ไม่ส่ง/ปิด/แก้ออเดอร์จริง
input bool     EmergencyStop       = false;   // true = ปิดทุกไม้ของ EA, ลบ pending, หยุดทำงาน

sinput string  InpSepTrading = "===== Trading =====";
input double   LotSize             = 0.01;    // lot คงที่ต่อไม้ (ไม่มี martingale)
input int      GridDistancePoints  = 300;     // ระยะกริด/ระดับราคาคงที่ (points) TODO: ปรับตามสเปรด/ATR
input int      TakeProfitPoints    = 300;     // TP (points) 0 = ไม่ตั้ง TP ใช้ trailing อย่างเดียว
input int      RepositionGrids     = 3;       // ย้าย pending เมื่อห่างระดับเป้าหมายเกินกี่ระดับ (ไม่ไล่ราคา)
input int      MaxTradesPerDay     = 5;       // ไม้สูงสุดต่อวันเซิร์ฟเวอร์ (1..5) นับ pending ที่ค้างด้วย
input bool     DeletePendingsOnExit = true;   // ลบ pending ตอนปิด EA/MT4 (กันไม้ fill ตอนไม่มี guard)

sinput string  InpSepGuard = "===== Guard =====";
input int      SLPoints            = 500;     // SL ฝั่งโบรกเกอร์ทุกออเดอร์ (points) TODO: ทดสอบค่า
input double   MaxDailyLossPct     = 5.0;     // เพดานขาดทุนรวม % ของ equity ต้นวัน
input bool     LossCapUseNetClosed = false;   // false = นับเฉพาะไม้ขาดทุนที่ปิดแล้ว (เข้มกว่า), true = นับ P/L สุทธิ
input int      TrailStartPoints    = 200;     // เริ่ม trailing เมื่อกำไร >= ค่านี้ (points) TODO
input int      TrailDistancePoints = 150;     // ระยะ SL ตามหลังราคา (points) TODO
input int      TrailStepPoints     = 10;      // ขยับ SL เมื่อดีขึ้นอย่างน้อยเท่านี้ (points) ลดจำนวน modify
input int      BreakevenOffsetPoints = 0;     // จุดทุน + offset (points) เผื่อค่าคอม/สเปรด
input int      MaxSpreadPoints     = 50;      // ไม่วางออเดอร์ถ้า spread เกินนี้ (points) TODO: ดูสเปรดจริงของโบรก
input double   MinMarginLevelPct   = 500.0;   // ไม่วางถ้า margin level หลังวางไม้ใหม่ต่ำกว่านี้ (%)

sinput string  InpSepExec = "===== Execution =====";
input int      MaxRetries          = 3;       // จำนวนครั้ง retry เมื่อเจอ requote/busy ฯลฯ
input int      SlippagePoints      = 30;      // slippage ตอนปิดไม้ (points)

sinput string  InpSepNotify = "===== Notify =====";
input bool     TelegramEnabled     = false;   // เปิดแจ้งเตือน Telegram
input string   TelegramBotToken    = "";      // Bot token จาก @BotFather (ห้ามฮาร์ดโค้ดในโค้ด)
input string   TelegramChatId      = "";      // Chat id ปลายทาง
input string   StatusURL           = "";      // URL รับ JSON สถานะ (POST) เว้นว่าง = ไม่ส่ง
input string   StatusAuthToken     = "";      // ส่งเป็น Authorization: Bearer ... (เว้นว่าง = ไม่ส่ง)
input int      StatusIntervalSec   = 10;      // ส่งสถานะทุกกี่วินาที
input int      HttpTimeoutMs       = 3000;    // timeout ของ WebRequest (ms)

//==================================================================
// GLOBALS
//==================================================================
CStateStore    g_state;
CGuardManager  g_guard;
COrderManager  g_orders;
CNotifier      g_notifier;
bool           g_initOk = false;
datetime       g_lastStatus = 0;

//+------------------------------------------------------------------+
bool ValidateInputs(string &why)
  {
   if(StringFind(Symbol(), "XAU") < 0)                    { why = "symbol must be XAUUSD (got " + Symbol() + ")"; return false; }
   if(MagicNumber <= 0)                                   { why = "MagicNumber must be > 0 (0 = manual trades)"; return false; }
   if(LotSize <= 0)                                       { why = "LotSize must be > 0"; return false; }
   if(MaxTradesPerDay < 1 || MaxTradesPerDay > GG_HARD_MAX_TRADES)
                                                          { why = "MaxTradesPerDay must be 1.." + IntegerToString(GG_HARD_MAX_TRADES); return false; }
   if(SLPoints <= 0)                                      { why = "SLPoints must be > 0 (every order needs a SL)"; return false; }
   if(MaxDailyLossPct <= 0 || MaxDailyLossPct > 100)      { why = "MaxDailyLossPct must be in (0,100]"; return false; }
   if(TrailStartPoints <= 0 || TrailDistancePoints <= 0)  { why = "Trail points must be > 0"; return false; }
   if(TrailStepPoints < 0 || BreakevenOffsetPoints < 0)   { why = "TrailStep/BreakevenOffset must be >= 0"; return false; }
   if(BreakevenOffsetPoints >= TrailStartPoints)          { why = "BreakevenOffsetPoints must be < TrailStartPoints"; return false; }
   if(MaxSpreadPoints <= 0)                               { why = "MaxSpreadPoints must be > 0"; return false; }
   if(MinMarginLevelPct < 0)                              { why = "MinMarginLevelPct must be >= 0"; return false; }
   if(GridDistancePoints <= 0)                            { why = "GridDistancePoints must be > 0"; return false; }
   if(TakeProfitPoints < 0)                               { why = "TakeProfitPoints must be >= 0"; return false; }
   if(RepositionGrids < 1)                                { why = "RepositionGrids must be >= 1"; return false; }
   if(MaxRetries < 1 || MaxRetries > 10)                  { why = "MaxRetries must be 1..10"; return false; }
   if(StatusIntervalSec < 1)                              { why = "StatusIntervalSec must be >= 1"; return false; }
   if(HttpTimeoutMs < 500 || HttpTimeoutMs > 10000)       { why = "HttpTimeoutMs must be 500..10000"; return false; }
   if(TelegramEnabled && (TelegramBotToken == "" || TelegramChatId == ""))
                                                          { why = "TelegramEnabled needs TelegramBotToken and TelegramChatId"; return false; }

   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   if(minLot > 0 && (LotSize < minLot || LotSize > maxLot))
     { why = StringFormat("LotSize %.2f outside broker range %.2f..%.2f", LotSize, minLot, maxLot); return false; }

   int stopLevel = (int)MarketInfo(Symbol(), MODE_STOPLEVEL);
   if(SLPoints <= stopLevel)                              { why = "SLPoints must be > broker stop level " + IntegerToString(stopLevel); return false; }
   if(TakeProfitPoints > 0 && TakeProfitPoints <= stopLevel)
                                                          { why = "TakeProfitPoints must be > broker stop level " + IntegerToString(stopLevel); return false; }
   return true;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_initOk = false;
   if(GG_DEMO_ONLY && !IsTesting() && !IsDemo())
     {
      Alert(GG_NAME, ": this build runs on DEMO accounts only. EA disabled.");
      return INIT_FAILED;
     }
   string why = "";
   if(!ValidateInputs(why))
     {
      Alert(GG_NAME, ": invalid inputs: ", why);
      return INIT_PARAMETERS_INCORRECT;
     }

   string tag = GG_NAME + " " + Symbol() + (IsDemo() ? " DEMO" : " REAL") + (DryRun ? " DRY" : "");
   g_notifier.Init(TelegramEnabled, TelegramBotToken, TelegramChatId, StatusURL, StatusAuthToken, tag, HttpTimeoutMs);

   //--- กู้สถานะ: GlobalVariables + สแกนออเดอร์ magic นี้ (ไม่วางซ้ำ)
   datetime now = TimeCurrent();
   g_state.Init(CStateStore::BuildPrefix(MagicNumber, Symbol(), IsTesting()));
   int scanned = GG_CountFilledSince(MagicNumber, Symbol(), GG_DayStart(now));
   int rs = g_state.Restore(now, AccountEquity(), scanned);
   string rsText = (rs == GG_RESTORE_FRESH) ? "fresh" : (rs == GG_RESTORE_SAME_DAY ? "restored same day" : "new day");
   if(rs == GG_RESTORE_FRESH)
      GG_Log("WARN", "no saved state: day-start equity = current equity " + DoubleToString(AccountEquity(), 2));

   GuardConfig cfg;
   cfg.magic                 = MagicNumber;
   cfg.lossCapPct            = MaxDailyLossPct;
   cfg.lossCapUseNetClosed   = LossCapUseNetClosed;
   cfg.slPoints              = SLPoints;
   cfg.trailStartPoints      = TrailStartPoints;
   cfg.trailDistancePoints   = TrailDistancePoints;
   cfg.trailStepPoints       = TrailStepPoints;
   cfg.breakevenOffsetPoints = BreakevenOffsetPoints;
   cfg.maxSpreadPoints       = MaxSpreadPoints;
   cfg.minMarginLevelPct     = MinMarginLevelPct;
   cfg.maxTradesPerDay       = MaxTradesPerDay;
   cfg.maxRetries            = MaxRetries;
   cfg.slippagePoints        = SlippagePoints;
   cfg.emergencyStop         = EmergencyStop;
   cfg.dryRun                = DryRun;
   g_guard.Init(cfg, Symbol(), GetPointer(g_state), GetPointer(g_notifier));

   OrderConfig ocfg;
   ocfg.magic           = MagicNumber;
   ocfg.lots            = LotSize;
   ocfg.gridPoints      = GridDistancePoints;
   ocfg.tpPoints        = TakeProfitPoints;
   ocfg.repositionGrids = RepositionGrids;
   ocfg.maxRetries      = MaxRetries;
   ocfg.slippagePoints  = SlippagePoints;
   ocfg.dryRun          = DryRun;
   g_orders.Init(ocfg, Symbol(), GetPointer(g_guard), GetPointer(g_notifier));

   g_notifier.Event(GG_EVT_START, StringFormat("v%s started on %s | state %s: %s | open=%d pending=%d | equity=%.2f",
                    GG_VERSION, AccountCompany(), rsText, g_state.ToString(),
                    GG_CountMarket(MagicNumber, Symbol()), GG_CountPending(MagicNumber, Symbol()), AccountEquity()));

   EventSetTimer(1);   // ทำงานต่อแม้ไม่มี tick (หมายเหตุ: MT4 tester ไม่เรียก OnTimer)
   g_initOk = true;
   Process();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_initOk)
     {
      // กันไม้ใหม่ fill ตอนที่ EA ไม่ได้รัน (ไม้ที่เปิดอยู่ยังมี SL ฝั่งโบรก)
      if(DeletePendingsOnExit && !IsTesting())
         g_guard.DeletePendings("EA stopped, reason=" + IntegerToString(reason));
      g_state.Save();
      g_notifier.Event(GG_EVT_STOP, "deinit reason=" + IntegerToString(reason) + " | " + g_state.ToString()
                       + " | open=" + IntegerToString(GG_CountMarket(MagicNumber, Symbol()))
                       + " pending=" + IntegerToString(GG_CountPending(MagicNumber, Symbol())));
     }
   Comment("");
  }

void OnTick()  { Process(); }
void OnTimer() { Process(); }

//+------------------------------------------------------------------+
//| ลำดับงานต่อรอบ:                                                     |
//| ข้ามวัน -> แจ้ง fill/close -> emergency -> SL -> loss cap -> trail -> วางไม้ |
//+------------------------------------------------------------------+
void Process()
  {
   if(!g_initOk)
      return;
   datetime now = TimeCurrent();

   if(g_state.RollDayIfNeeded(now, AccountEquity()))
      g_notifier.Event(GG_EVT_NEW_DAY, "new server day: " + g_state.ToString());

   g_orders.TrackFills();

   if(g_guard.HandleEmergency())
     {
      Finish(now);
      return;
     }

   g_guard.EnforceStopLoss();
   g_guard.SyncTradesToday(now);

   if(g_guard.CheckLossCap(now))
     {
      Finish(now);
      return;
     }

   g_guard.ManageTrailing();
   g_guard.CheckCanOpen(LotSize);       // อัปเดตสถานะ guard สำหรับ dashboard
   g_orders.Manage();                   // เช็ก guard อีกครั้งก่อนวางทุกไม้

   Finish(now);
  }

void Finish(const datetime now)
  {
   UpdateComment();
   if(StatusURL != "" && !IsTesting() && (int)(TimeLocal() - g_lastStatus) >= StatusIntervalSec)
     {
      g_lastStatus = TimeLocal();
      g_notifier.PushStatus(BuildStatusJson(now));
     }
  }

string BuildStatusJson(const datetime now)
  {
   string s = "{";
   s += "\"ea\":\"" + GG_NAME + "\",\"version\":\"" + GG_VERSION + "\"";
   s += ",\"symbol\":\"" + GG_JsonEscape(Symbol()) + "\"";
   s += ",\"server_time\":\"" + TimeToString(now, TIME_DATE | TIME_SECONDS) + "\"";
   s += ",\"demo\":" + GG_JsonBool(IsDemo()) + ",\"dry_run\":" + GG_JsonBool(DryRun);
   s += ",\"equity\":" + DoubleToString(AccountEquity(), 2);
   s += ",\"balance\":" + DoubleToString(AccountBalance(), 2);
   s += ",\"floating_pl\":" + DoubleToString(g_guard.LastFloating(), 2);
   s += ",\"closed_today\":" + DoubleToString(g_guard.LastClosed(), 2);
   s += ",\"day_start_equity\":" + DoubleToString(g_state.dayStartEquity, 2);
   s += ",\"loss_cap\":" + DoubleToString(g_guard.LossCapMoney(), 2);
   s += ",\"trades_today\":" + IntegerToString(g_state.tradesToday);
   s += ",\"max_trades\":" + IntegerToString(MaxTradesPerDay);
   s += ",\"open_count\":" + IntegerToString(GG_CountMarket(MagicNumber, Symbol()));
   s += ",\"pending_count\":" + IntegerToString(GG_CountPending(MagicNumber, Symbol()));
   s += ",\"spread\":" + DoubleToString(GG_SpreadPoints(Symbol()), 1);
   s += ",\"guard\":\"" + GG_BlockText(g_guard.LastReason()) + "\"";
   s += ",\"halted\":" + GG_JsonBool(g_state.dayHalted);
   s += ",\"emergency\":" + GG_JsonBool(g_guard.IsEmergency());
   s += "}";
   return s;
  }

void UpdateComment()
  {
   Comment(GG_NAME, " v", GG_VERSION, DryRun ? "  [DRY-RUN]" : "", "\n",
           g_state.ToString(), "\n",
           g_guard.StatusLine(), "\n",
           "open=", GG_CountMarket(MagicNumber, Symbol()), " pending=", GG_CountPending(MagicNumber, Symbol()));
  }
//+------------------------------------------------------------------+
