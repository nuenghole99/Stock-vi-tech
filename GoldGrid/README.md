# GoldGrid — EA (MQL4) สำหรับ MT4 / XAUUSD

Grid EA สองทาง (BUY LIMIT / SELL LIMIT) สำหรับทองคำ เน้น **guard ก่อนกำไร**
เฟสแรกรันได้เฉพาะบัญชี **DEMO** (บังคับในโค้ดด้วย `GG_DEMO_ONLY`; ใน Strategy Tester รันได้)

> **สถานะปัจจุบัน (v0.1.0 — เฟส 1)**
> - ✅ โครงโปรเจกต์, `GuardManager`, `StateStore`, `TradeOps` (retry), `OrderScan`
> - ✅ ชุดทดสอบ `GoldGridTests.mq4` สำหรับ Strategy Tester
> - ⏳ `OrderManager` เป็น stub — **EA ยังไม่วางออเดอร์ใด ๆ**
> - ⏳ `Notifier` ตอนนี้ log ลง Journal อย่างเดียว (Telegram/Status JSON อยู่เฟส 3)
> - ⚠️ โค้ดเขียนนอก MetaEditor และยังไม่ได้คอมไพล์จริง ต้องกด Compile ใน MetaEditor ก่อนใช้งาน
>   ถ้ามี error/warning ให้แจ้งกลับมาแก้

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
        ├── OrderManager.mqh      # (stub) วางกริด Limit order — เฟส 2
        ├── Notifier.mqh          # (stub) Telegram + Status JSON — เฟส 3
        └── TestKit.mqh           # assert สำหรับชุดทดสอบ
```

## ลำดับการทำงานต่อรอบ (OnTick และ OnTimer ทุก 1 วินาที)

1. **ข้ามวันเซิร์ฟเวอร์?** → เก็บ equity ต้นวันใหม่, รีเซ็ตตัวนับไม้, ปลด flag หยุดวัน
2. **EmergencyStop** → ปิดทุกไม้ + ลบ pending ของ EA แล้วจบรอบ (ทำซ้ำทุกรอบจนไม่เหลือ)
3. **Enforce SL** → ไม้ของ EA ที่ไม่มี SL จะถูกตั้ง SL ทันที ถ้าตั้งไม่ได้จะถูกปิด/ลบ
4. **Sync ตัวนับไม้วันนี้** จากการสแกนออเดอร์
5. **เพดานขาดทุน** → ถ้า `floating + ขาดทุนที่ปิดแล้ววันนี้ <= -MaxDailyLossPct% × equity ต้นวัน`
   บันทึก flag หยุดวันลง GlobalVariables **ก่อน** แล้วลบ pending → ปิดไม้ทั้งหมด → ไม่เปิดใหม่จนข้ามวัน
6. **Trailing SL**
7. **CheckCanOpen** (emergency → halt → trade allowed → จำนวนไม้ → spread → margin) แล้วจึงส่งต่อให้ OrderManager

## Guard โดยละเอียด

| # | Guard | ที่อยู่ในโค้ด | หมายเหตุ |
|---|-------|--------------|----------|
| 1 | SL ฝั่งโบรกเกอร์ทุกออเดอร์ | `InitialSLFor`, `CalcInitialSL`, `EnforceStopLoss` | OrderManager (เฟส 2) ต้องส่ง SL ไปกับ `OrderSend` เสมอ; `EnforceStopLoss` เป็นตาข่ายรองรับ |
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

ไม่มีการวางออเดอร์ซ้ำใน OnInit (เฟส 2: OrderManager จะสแกนระดับราคาที่มี pending อยู่แล้วก่อนวาง)

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
| | `GridDistancePoints` | 300 | TODO: ปรับตามสเปรด/ATR (ใช้ในเฟส 2) |
| | `MaxTradesPerDay` | 5 | 1..5 |
| Guard | `SLPoints` | 500 | TODO: จูน |
| | `MaxDailyLossPct` | 5.0 | % ของ equity ต้นวัน |
| | `LossCapUseNetClosed` | false | false = นับเฉพาะไม้ปิดขาดทุน |
| | `TrailStartPoints` / `TrailDistancePoints` | 200 / 150 | TODO: จูน |
| | `TrailStepPoints` | 10 | ลดจำนวน OrderModify |
| | `BreakevenOffsetPoints` | 0 | ทุน + offset (เผื่อค่าคอม) ต้อง < TrailStart |
| | `MaxSpreadPoints` | 50 | TODO: ดูสเปรดจริงของโบรก |
| | `MinMarginLevelPct` | 500 | % หลังวางไม้ใหม่ |
| Execution | `MaxRetries` / `SlippagePoints` | 3 / 30 | |
| Notify | `TelegramEnabled`, `TelegramBotToken`, `TelegramChatId`, `StatusURL`, `StatusIntervalSec` | ว่าง / 10 | เฟส 3 — **ห้ามใส่ token ในโค้ด** ใส่ผ่าน input เท่านั้น |

> หน่วย "points" ขึ้นกับจำนวนทศนิยมของโบรก: XAUUSD 2 ทศนิยม → 1 point = 0.01 USD,
> 3 ทศนิยม → 1 point = 0.001 USD (ค่า 500 points จะแคบลง 10 เท่า) ตรวจ `Digits` ของโบรกก่อนตั้งค่า

## ตั้ง WebRequest allowlist (ใช้ในเฟส 3)

MT4 → **Tools → Options → Expert Advisors**
1. ติ๊ก **Allow WebRequest for listed URL**
2. เพิ่ม:
   - `https://api.telegram.org`
   - โดเมนของ `StatusURL` เช่น `https://your-dashboard.example.com` (ใส่เฉพาะ scheme+host)
3. กด OK แล้ว reload EA

หมายเหตุ: `WebRequest` ใช้ไม่ได้ใน Strategy Tester; ESP32 ในวง LAN ให้ใช้ URL ของ dashboard/proxy ที่อยู่ใน allowlist

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
| Scenario: loss cap | นับขาดทุนที่ปิดแล้ว, ชนเพดาน → ปิดทุกไม้+ลบ pending, halt ถูก persist และรอดการรีสตาร์ต |
| Scenario: next day | ระหว่างหยุดวัน CheckCanOpen ต้องเป็น DAY_HALT ทุก tick และปลดเมื่อข้ามวัน |

### 2) ทดสอบ EA หลักใน Strategy Tester

รัน `GoldGrid\GoldGrid` ด้วย `DryRun=true` → ดู Journal ว่ามี `[START]`, `[GUARD] can-open = ...`
และ Comment บนกราฟแสดงสถานะ guard (เฟสนี้ยังไม่มีการวางออเดอร์)

### 3) Dry-run บนบัญชี DEMO

1. ลาก `GoldGrid` ลงกราฟ XAUUSD ของบัญชี DEMO, ติ๊ก *Allow live trading*, `DryRun=true`
2. ดูแท็บ Experts: `[START] ... state fresh/restored`, การเปลี่ยนสถานะ `[GUARD] can-open = ...`
3. ทดสอบรีสตาร์ต: ปิด/เปิด MT4 แล้วดูว่า log บอก `restored same day` และ F3 (Global Variables) มี `GG_<magic>_...`
4. ทดสอบ kill switch: ตั้ง `EmergencyStop=true` → ต้องเห็น `[EMERGENCY]` และ can-open = `EMERGENCY_STOP`
5. ล้างสถานะด้วยมือ: F3 → ลบตัวแปรที่ขึ้นต้นด้วย `GG_<magic>_`

## Roadmap

- **เฟส 2** — `OrderManager`: วาง BUY/SELL LIMIT ห่าง `GridDistancePoints` พร้อม SL จาก guard, ไม่วางซ้ำ, retry OrderSend
- **เฟส 3** — `Notifier`: Telegram (start, เปิด/ปิดไม้, loss cap, error) + POST JSON สถานะทุก `StatusIntervalSec` วินาที
- **TODO จูนค่า**: `GridDistancePoints` ตามสเปรด/ATR, `SLPoints`, trailing, `MaxSpreadPoints`
