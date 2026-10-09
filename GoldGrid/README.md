# GoldGrid — EA (MQL4) สำหรับ MT4 / XAUUSD

Grid EA สองทาง (BUY LIMIT / SELL LIMIT) สำหรับทองคำ เน้น **guard ก่อนกำไร**
เฟสแรกรันได้เฉพาะบัญชี **DEMO** (บังคับในโค้ดด้วย `GG_DEMO_ONLY`; ใน Strategy Tester รันได้)

> **สถานะปัจจุบัน (v0.2.0)**
> - ✅ `GuardManager`, `StateStore`, `TradeOps` (retry), `OrderScan`
> - ✅ `OrderManager` วางกริด BUY/SELL LIMIT บนระดับราคาคงที่ (1 pending ต่อฝั่ง, SL+TP ตั้งแต่ตอนวาง)
> - ✅ `Notifier` แจ้ง Telegram + POST JSON สถานะผ่าน WebRequest
> - ✅ ลบ pending อัตโนมัติตอนปิด EA/MT4 (`DeletePendingsOnExit`)
> - ✅ ชุดทดสอบ `GoldGridTests.mq4` สำหรับ Strategy Tester
> - ⚠️ โค้ดเขียนนอก MetaEditor และยังไม่ได้คอมไพล์จริง ต้องกด Compile ใน MetaEditor ก่อนใช้งาน
>   ถ้ามี error/warning ให้แจ้งกลับมาแก้
> - 🔒 ยังล็อก DEMO เท่านั้น (`GG_DEMO_ONLY` ใน `Common.mqh`)

---

## โครงสร้างไฟล์

โฟลเดอร์ `MQL4/` จัดวางแบบเดียวกับ Data Folder ของ MT4 คัดลอกทับได้ทันที

```
GoldGrid/
├── README.md
└── MQL4/
    ├── Experts/GoldGrid/
    │   ├── GoldGrid.mq4          # EA หลัก: inputs, OnInit/OnTick/OnTimer, ลำดับการทำงาน
    │   └── GoldGridTests.mq4     # ชุดทดสอบ (รันใน Strategy Tester เท่านั้น)
    └── Include/GoldGrid/
        ├── Common.mqh            # enum, ค่าคงที่, เวลา/วันเซิร์ฟเวอร์, log
        ├── OrderScan.mqh         # สแกนออเดอร์ของ EA (magic+symbol): นับไม้, floating, P/L ที่ปิดแล้ว
        ├── TradeOps.mqh          # ปิด/ลบ/แก้ออเดอร์ + retry จำกัดครั้ง + dry-run
        ├── StateStore.mqh        # สถานะรายวันใน GlobalVariables + กู้คืนหลังรีสตาร์ต
        ├── GuardManager.mqh      # guard ทั้ง 6 ข้อ (pure functions + ส่วนที่สั่งงานจริง)
        ├── OrderManager.mqh      # วางกริด BUY/SELL LIMIT + แจ้ง fill/close
        ├── Notifier.mqh          # Telegram + Status JSON (WebRequest)
        └── TestKit.mqh           # assert สำหรับชุดทดสอบ
```

## ลำดับการทำงานต่อรอบ (OnTick และ OnTimer ทุก 1 วินาที)

1. **ข้ามวันเซิร์ฟเวอร์?** → เก็บ equity ต้นวันใหม่, รีเซ็ตตัวนับไม้, ปลด flag หยุดวัน
2. **TrackFills** → แจ้ง Telegram เมื่อ pending fill (ORDER_OPEN) หรือไม้ถูกปิดด้วย TP/SL/guard (ORDER_CLOSE พร้อม P/L)
3. **EmergencyStop** → ปิดทุกไม้ + ลบ pending ของ EA แล้วจบรอบ (ทำซ้ำทุกรอบจนไม่เหลือ)
4. **Enforce SL** → ไม้ของ EA ที่ไม่มี SL จะถูกตั้ง SL ทันที ถ้าตั้งไม่ได้จะถูกปิด/ลบ
5. **Sync ตัวนับไม้วันนี้** จากการสแกนออเดอร์
6. **เพดานขาดทุน** → ถ้า `floating + ขาดทุนที่ปิดแล้ววันนี้ <= -MaxDailyLossPct% × equity ต้นวัน`
   บันทึก flag หยุดวันลง GlobalVariables **ก่อน** แล้วลบ pending → ปิดไม้ทั้งหมด → ไม่เปิดใหม่จนข้ามวัน
7. **Trailing SL**
8. **OrderManager** → ดูแล pending ฝั่งละ 1 ไม้ ทุกไม้ใหม่ต้องผ่าน `CheckCanOpen`
   (emergency → halt → trade allowed → จำนวนไม้ → spread → margin)
9. ส่ง JSON สถานะทุก `StatusIntervalSec` วินาที

## การวางออเดอร์ (OrderManager)

- **ระดับราคาคงที่** ทุก ๆ `GridDistancePoints` (300 points บนโบรก 2 ทศนิยม = ทุก 3.00 USD เช่น 1998.00, 2001.00, 2004.00)
- **BUY LIMIT** ที่ระดับใต้ Ask ที่ใกล้ที่สุด, **SELL LIMIT** ที่ระดับเหนือ Bid ที่ใกล้ที่สุด (เว้นระยะ stop/freeze level ของโบรก)
- **1 pending ต่อฝั่ง** ถ้ามี pending ฝั่งนั้นอยู่แล้วจะไม่วางเพิ่ม (รวมหลังรีสตาร์ต เพราะอ่านจากออเดอร์จริง)
- **ไม่ไล่ราคา**: pending ถูกย้ายเฉพาะเมื่อห่างจากระดับเป้าหมายเกิน `RepositionGrids` ระดับ (ย้ายด้วย OrderModify ไม่นับเป็นไม้ใหม่)
- ถ้าระดับเป้าหมายมีไม้ทิศเดียวกันเปิดอยู่แล้ว จะใช้ระดับถัดไป (ไม่ซ้อนไม้ราคาเดียวกัน)
- **SL** = `SLPoints` จาก guard, **TP** = `TakeProfitPoints` (ค่าเริ่มต้น 300 = ระดับกริดถัดไป) + trailing
- ส่งออเดอร์ล้มเหลว → พัก 15 วินาที (market closed พัก 60 วินาที) แล้วลองใหม่

## Guard โดยละเอียด

| # | Guard | ที่อยู่ในโค้ด | หมายเหตุ |
|---|-------|--------------|----------|
| 1 | SL ฝั่งโบรกเกอร์ทุกออเดอร์ | `InitialSLFor`, `CalcInitialSL`, `EnforceStopLoss` | OrderManager ส่ง SL ไปกับ `OrderSend` เสมอ (ไม่มี SL ที่ถูกต้องจะไม่วาง); `EnforceStopLoss` เป็นตาข่ายรองรับ |
| 2 | เพดานขาดทุนรายวัน | `CheckLossCap`, `IsLossCapHit` | นับเฉพาะไม้ magic นี้; ค่าเริ่มต้นนับเฉพาะ **ไม้ที่ปิดขาดทุน** (เข้มกว่า) ตั้ง `LossCapUseNetClosed=true` เพื่อใช้ P/L สุทธิ |
| 3 | Trailing SL | `ManageTrailing`, `CalcTrailingSL` | เริ่มเมื่อกำไร ≥ `TrailStartPoints`; SL = ราคา ∓ `TrailDistancePoints` แต่ **ไม่แย่กว่าจุดทุน (+`BreakevenOffsetPoints`)**; ไม่ถอย SL; ถ้า stop level ของโบรกไม่ให้ตั้งที่ทุนจะรอ (ไม่ตั้งต่ำกว่าทุน) |
| 4 | Spread | `IsSpreadOK` | `(Ask-Bid)/Point <= MaxSpreadPoints` |
| 5 | Margin level | `ProjectedMarginLevel`, `IsMarginOK` | คำนวณ margin level **หลัง** เพิ่มไม้ใหม่ (`MODE_MARGINREQUIRED × LotSize`) |
| 6 | Kill switch | `HandleEmergency` | `EmergencyStop=true` |

**จำนวนไม้ต่อวัน**: นับไม้ที่ fill แล้ววันนี้ (ทั้งที่ยังเปิดและปิดแล้ว) + จอง slot ให้ pending ที่ค้างอยู่
→ `tradesToday + pending < MaxTradesPerDay` (สูงสุด 5 บังคับในโค้ด)

## การกู้สถานะหลังรีสตาร์ต

GlobalVariables (prefix `GG_<magic>_<symbol>_`, ใน tester เติม `T_`):

| ชื่อ | ความหมาย |
|------|----------|
| `DayKey` | วันเซิร์ฟเวอร์ `YYYYMMDD` |
| `DayEq` | equity ต้นวัน |
| `Trades` | จำนวนไม้ที่เปิดวันนี้ |
| `Halt` / `HaltWhy` | flag หยุดวัน / สาเหตุ (1 = loss cap) |

ตอน `OnInit` → `CStateStore::Restore()`:
- ไม่มีสถานะ → เริ่มใหม่ (equity ต้นวัน = equity ปัจจุบัน และ log เตือน)
- สถานะเป็นของวันก่อน → เริ่มวันใหม่
- วันเดียวกัน → ใช้ค่าเดิม (รวมถึง flag หยุดวัน) และใช้ `max(Trades ที่บันทึก, จำนวนที่สแกนได้จากออเดอร์ magic นี้)`

ไม่มีการวางออเดอร์ซ้ำ: OrderManager อ่าน pending/position ที่มีอยู่จริงก่อนวางทุกครั้ง

> **สำคัญ**: แท็บ *Account History* ใน Terminal ต้องแสดงอย่างน้อย "Today" (แนะนำ "All History")
> ไม่เช่นนั้น `OrdersHistoryTotal()` จะไม่เห็นไม้ที่ปิดแล้ว ทำให้นับขาดทุนที่ปิดแล้ว/จำนวนไม้ได้น้อยกว่าจริง

## การจัดการ error

`TradeOps.mqh` retry สูงสุด `MaxRetries` ครั้ง (หน่วงเวลาเพิ่มขึ้นทีละ 200ms) สำหรับ error ชั่วคราว:
requote (138), price changed (135), off quotes (136), trade context busy (146), broker/server busy (137/4),
no connection (6), timeout (128), too many requests (141/8), invalid price (129)

- **Market closed (132)** และ error ถาวรอื่น ๆ: หยุด retry ทันที ส่ง event `ERROR` แล้วลองใหม่รอบถัดไป (tick/timer)
- `OrderModify` ที่ได้ error 1 (ค่าไม่เปลี่ยน) ถือว่าสำเร็จ

---

## ติดตั้ง

1. MT4 → **File → Open Data Folder**
2. คัดลอกโฟลเดอร์ `MQL4/` ของโปรเจกต์นี้ไปวางทับใน Data Folder
   (ได้ `MQL4/Experts/GoldGrid/*.mq4` และ `MQL4/Include/GoldGrid/*.mqh`)
3. เปิด MetaEditor (F4) → เปิด `GoldGrid.mq4` และ `GoldGridTests.mq4` → **Compile (F7)** ทั้งสองไฟล์
4. กลับ MT4 → Navigator → Expert Advisors → Refresh

## ตั้งค่า (inputs)

| กลุ่ม | Input | ค่าเริ่มต้น | ความหมาย |
|------|-------|-----------|----------|
| General | `MagicNumber` | 260701 | แยกไม้ EA จากไม้มือ ห้ามเปลี่ยนขณะมีไม้เปิด |
| | `DryRun` | **true** | log อย่างเดียว ไม่ส่ง/ปิด/แก้ออเดอร์จริง |
| | `EmergencyStop` | false | true = ปิดทุกอย่างและหยุด |
| Trading | `LotSize` | 0.01 | lot คงที่ (ไม่มี martingale) |
| | `GridDistancePoints` | 300 | ระยะระดับกริด TODO: ปรับตามสเปรด/ATR |
| | `TakeProfitPoints` | 300 | 0 = ไม่ตั้ง TP ใช้ trailing อย่างเดียว |
| | `RepositionGrids` | 3 | ย้าย pending เมื่อห่างเป้าหมายเกินกี่ระดับ |
| | `MaxTradesPerDay` | 5 | 1..5 (pending ที่ค้างนับรวมด้วย) |
| | `DeletePendingsOnExit` | true | ลบ pending ตอนปิด EA/MT4 |
| Guard | `SLPoints` | 500 | TODO: จูน |
| | `MaxDailyLossPct` | 5.0 | % ของ equity ต้นวัน |
| | `LossCapUseNetClosed` | false | false = นับเฉพาะไม้ปิดขาดทุน |
| | `TrailStartPoints` / `TrailDistancePoints` | 200 / 150 | TODO: จูน |
| | `TrailStepPoints` | 10 | ลดจำนวน OrderModify |
| | `BreakevenOffsetPoints` | 0 | ทุน + offset (เผื่อค่าคอม) ต้อง < TrailStart |
| | `MaxSpreadPoints` | 50 | TODO: ดูสเปรดจริงของโบรก |
| | `MinMarginLevelPct` | 500 | % หลังวางไม้ใหม่ |
| Execution | `MaxRetries` / `SlippagePoints` | 3 / 30 | |
| Notify | `TelegramEnabled` | false | เปิดแจ้งเตือน |
| | `TelegramBotToken`, `TelegramChatId` | ว่าง | **ห้ามใส่ token ในโค้ด** ใส่ผ่าน input เท่านั้น |
| | `StatusURL`, `StatusAuthToken` | ว่าง | URL รับ JSON (POST) และ Bearer token (ถ้ามี) |
| | `StatusIntervalSec` / `HttpTimeoutMs` | 10 / 3000 | |

> หน่วย "points" ขึ้นกับจำนวนทศนิยมของโบรก: XAUUSD 2 ทศนิยม → 1 point = 0.01 USD,
> 3 ทศนิยม → 1 point = 0.001 USD (ค่า 500 points จะแคบลง 10 เท่า) ตรวจ `Digits` ของโบรกก่อนตั้งค่า

## ตั้งค่า Telegram

1. คุยกับ **@BotFather** ใน Telegram → `/newbot` → ได้ **bot token**
2. ส่งข้อความอะไรก็ได้หา bot ของคุณ 1 ครั้ง
3. เปิด `https://api.telegram.org/bot<TOKEN>/getUpdates` ในเบราว์เซอร์ → หา `"chat":{"id":...}` = **chat id**
4. ใส่ token และ chat id ใน input ของ EA แล้วตั้ง `TelegramEnabled=true`
5. ตั้ง WebRequest allowlist (ด้านล่าง) — เมื่อ EA เริ่มทำงานต้องได้ข้อความ `START`

เหตุการณ์ที่ส่ง: START, STOP, ORDER_OPEN, ORDER_CLOSE, LOSS_CAP, EMERGENCY, NEW_DAY, ERROR
(error ข้อความเดิมซ้ำภายใน 60 วินาทีจะไม่ส่งซ้ำ)

## ตั้ง WebRequest allowlist

MT4 → **Tools → Options → Expert Advisors**
1. ติ๊ก **Allow WebRequest for listed URL**
2. เพิ่ม:
   - `https://api.telegram.org`
   - โดเมนของ `StatusURL` เช่น `https://your-dashboard.example.com` (ใส่เฉพาะ scheme+host)
3. กด OK แล้ว reload EA

ถ้าลืมตั้ง จะเห็น log `WebRequest blocked ... add the URL host ...`
หมายเหตุ: `WebRequest` ใช้ไม่ได้ใน Strategy Tester (EA จะข้ามการส่ง); ESP32 ในวง LAN ให้ใช้ URL ของ dashboard/proxy ที่อยู่ใน allowlist

## JSON สถานะ (POST ไป `StatusURL`)

```json
{"ea":"GoldGrid","version":"0.2.0","symbol":"XAUUSD","server_time":"2026.10.09 14:00:05",
 "demo":true,"dry_run":false,"equity":10012.34,"balance":10000.00,"floating_pl":12.34,
 "closed_today":0.00,"day_start_equity":10000.00,"loss_cap":-500.00,"trades_today":1,
 "max_trades":5,"open_count":1,"pending_count":2,"spread":25.0,"guard":"OK",
 "halted":false,"emergency":false}
```

`guard` เป็นหนึ่งใน: `OK`, `EMERGENCY_STOP`, `DAY_HALTED`, `TRADE_DISABLED`, `DAILY_LIMIT`, `SPREAD_TOO_WIDE`, `MARGIN_LEVEL_LOW`

## รันบนคอมพิวเตอร์ตัวเอง (ไม่ใช้ VPS)

EA ทำงานเฉพาะตอนที่ MT4 เปิดอยู่และต่อเน็ต ถ้าคอมปิด/sleep/เน็ตหลุด:

| อะไร | ทำงานไหม |
|------|----------|
| SL / TP ของทุกไม้ (อยู่ฝั่งโบรก) | ✅ |
| Pending order | ลบให้อัตโนมัติตอนปิด EA/MT4 ตามปกติ (`DeletePendingsOnExit`) — แต่ถ้าไฟดับ/แครชจะยังค้างและ fill ได้ |
| Trailing, เพดานขาดทุน, Telegram | ❌ จนกว่าจะเปิด MT4 ใหม่ |

- ตั้ง Windows: Power & sleep → Sleep = **Never** ระหว่างรัน EA
- ปิด MT4 ทุกครั้งด้วยการปิดปกติ (ไม่ใช่ปิดเครื่องทันที) เพื่อให้ EA ลบ pending ก่อน
- เปิด MT4 ใหม่ EA จะกู้สถานะและวาง pending ใหม่เอง (ไม่ซ้ำ)

---

## วิธีทดสอบ

### 1) ชุดทดสอบใน Strategy Tester (`GoldGridTests.mq4`)

ตั้งค่า Strategy Tester (Ctrl+R):
- Expert Advisor: `GoldGrid\GoldGridTests`
- Symbol: `XAUUSD` (ชื่อตามโบรก) · Model: **Every tick** · Period: M1 หรือ M5
- ช่วงวันที่: **อย่างน้อย 1 สัปดาห์** (ต้องข้ามวันเซิร์ฟเวอร์เพื่อทดสอบการปลด flag หยุดวัน)
- Initial deposit: 10000 USD · ไม่ต้องใช้ Optimization
- ต้องมีประวัติราคา XAUUSD (Tools → History Center ดาวน์โหลด M1)

กด Start แล้วดูแท็บ **Journal**:
- `[TEST][FAIL] ...` = เคสที่ไม่ผ่าน · `[TEST][SKIP] ...` = เคสที่ข้าม (เช่นราคาไม่วิ่งถึงจุด trail)
- บรรทัดสุดท้าย `RESULT: ALL PASSED pass=N fail=0 skip=M`
- ผลถูกเขียนลง `tester/files/GoldGridTests_result.txt` ด้วย

สิ่งที่ทดสอบ:

| ชุด | ตรวจอะไร |
|-----|---------|
| Unit: day helpers | DayKey / เที่ยงคืนเซิร์ฟเวอร์ |
| Unit: loss cap | ชนพอดี -5%, ไม่ถึง, floating/closed อย่างเดียว, กำไรหักล้าง, equity เสีย |
| Unit: spread / margin / limit | ขอบเขต =, >, margin level คาดการณ์, จอง slot ให้ pending |
| Unit: Evaluate | เหตุผลบล็อกแต่ละแบบ + ลำดับความสำคัญ |
| Unit: initial SL | BUY/SELL LIMIT, 2 และ 3 ทศนิยม, SL ผิดฝั่ง |
| Unit: trailing | เริ่มที่ TrailStart, floor ที่จุดทุน, offset, ไม่ถอย, step, stop level |
| Unit: StateStore | save/load, merge ตัวนับ, ข้ามวัน, Restore (fresh/same day/new day), ซ่อมค่าเสีย, ลบ GV |
| Scenario: trailing | เปิด BUY+SELL จริงในเทสเตอร์ ตรวจทุก tick ว่า SL ไม่ถอยและไม่ต่ำกว่าทุนเมื่อ trail |
| Scenario: dry-run | CloseAll/Modify ไม่ส่งคำสั่ง, loss cap ยังสั่งหยุดวันแต่ไม่ปิดไม้ |
| Scenario: enforce SL | ไม้/pending ที่ไม่มี SL ได้ SL ตาม `SLPoints` |
| Scenario: emergency | ปิดไม้ + ลบ pending, CheckCanOpen = EMERGENCY |
| Scenario: restore | จำลองรีสตาร์ต: ตัวนับไม้กู้จาก GV และจากการสแกนเมื่อ GV หาย, daily limit บล็อก |
| Unit: grid / TP | ระดับกริดบน/ล่าง, เว้น stop level, 2 และ 3 ทศนิยม, TP |
| Unit: Notifier | JSON escape, payload Telegram |
| Scenario: OrderManager | วาง BUY+SELL LIMIT บนระดับกริด พร้อม SL/TP/lot ถูกต้อง, ไม่วางซ้ำ (รวมหลังรีสตาร์ต), DeletePendings, daily limit, dry-run ไม่ส่ง, ย้าย pending ที่ไกลเกิน |
| Scenario: loss cap | นับขาดทุนที่ปิดแล้ว, ชนเพดาน → ปิดทุกไม้+ลบ pending, halt ถูก persist และรอดการรีสตาร์ต |
| Scenario: next day | ระหว่างหยุดวัน CheckCanOpen ต้องเป็น DAY_HALT ทุก tick และปลดเมื่อข้ามวัน |

### 2) Backtest EA หลักใน Strategy Tester

รัน `GoldGrid\GoldGrid` ด้วย `DryRun=false`, Every tick, ย้อนหลัง 6–12 เดือน แล้วตรวจ:
- Report: Total net profit, Maximal drawdown, จำนวนไม้
- Journal: ไม่มีวันไหนเกิน 5 ไม้, ทุกไม้มี SL (คอลัมน์ S/L ใน Results), เห็น `LOSS_CAP` เมื่อชนเพดาน

### 3) DEMO 1 วัน (บนคอมตัวเอง)

1. ลาก `GoldGrid` ลงกราฟ XAUUSD ของบัญชี DEMO, ติ๊ก *Allow live trading*
2. เริ่มด้วย `DryRun=true` 5–10 นาที ดู log `[DRY] would place BUYLIMIT ...` ว่าราคา/SL/TP สมเหตุสมผล
3. เปลี่ยนเป็น `DryRun=false` และ `TelegramEnabled=true`
4. ระหว่างวันต้องเห็นอย่างน้อยอย่างละครั้ง:
   - [ ] Telegram `START`
   - [ ] pending 2 ใบ (BUY LIMIT/SELL LIMIT) บนระดับกริด มี SL+TP
   - [ ] ไม้ fill → `ORDER_OPEN`, ไม้ปิด → `ORDER_CLOSE` พร้อม P/L
   - [ ] trailing ขยับ SL (log `[TRAIL]`)
   - [ ] ปิด MT4 ปกติ → pending ถูกลบ, เปิดใหม่ → `restored same day` และไม่มี pending ซ้ำ
   - [ ] `EmergencyStop=true` → ทุกไม้ถูกปิด, Telegram `EMERGENCY`
5. ล้างสถานะด้วยมือ: F3 → ลบตัวแปรที่ขึ้นต้นด้วย `GG_<magic>_`

### 4) ก่อนขึ้นบัญชีจริง

- ขอให้ปลดล็อก `GG_DEMO_ONLY` (แก้ใน `Common.mqh`)
- เริ่มด้วยบัญชี **cent**, `MaxDailyLossPct=2`, `LotSize` = lot ต่ำสุดของโบรก
- งดรันช่วงข่าวใหญ่ (NFP, CPI, FOMC) ใน 2 สัปดาห์แรก

## Roadmap

- **ต่อไป** — จูน `GridDistancePoints`, `SLPoints`, trailing, `MaxSpreadPoints` จากผล backtest
- **ทางเลือก** — ปิดรับไม้ช่วงข่าว (news filter), dashboard/ESP32 ที่รับ JSON สถานะ
