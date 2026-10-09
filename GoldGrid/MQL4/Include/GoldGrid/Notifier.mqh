//+------------------------------------------------------------------+
//| GoldGrid/Notifier.mqh                                            |
//| แจ้งเตือน Telegram + ส่ง JSON สถานะไป StatusURL ผ่าน WebRequest         |
//|                                                                  |
//| ต้องเพิ่ม URL ใน Tools > Options > Expert Advisors >                 |
//|   "Allow WebRequest for listed URL":                             |
//|     https://api.telegram.org                                     |
//|     และ scheme+host ของ StatusURL                                 |
//| WebRequest ใช้ไม่ได้ใน Strategy Tester -> ข้ามการส่ง (log อย่างเดียว)   |
//| ห้าม log token                                                    |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_NOTIFIER_MQH
#define GOLDGRID_NOTIFIER_MQH

#include "Common.mqh"

enum ENUM_GG_EVENT
  {
   GG_EVT_START = 0,
   GG_EVT_STOP,
   GG_EVT_ORDER_OPEN,
   GG_EVT_ORDER_CLOSE,
   GG_EVT_LOSS_CAP,
   GG_EVT_EMERGENCY,
   GG_EVT_NEW_DAY,
   GG_EVT_ERROR,
   GG_EVT_INFO
  };

string GG_EventText(const int evt)
  {
   switch(evt)
     {
      case GG_EVT_START:       return "START";
      case GG_EVT_STOP:        return "STOP";
      case GG_EVT_ORDER_OPEN:  return "ORDER_OPEN";
      case GG_EVT_ORDER_CLOSE: return "ORDER_CLOSE";
      case GG_EVT_LOSS_CAP:    return "LOSS_CAP";
      case GG_EVT_EMERGENCY:   return "EMERGENCY";
      case GG_EVT_NEW_DAY:     return "NEW_DAY";
      case GG_EVT_ERROR:       return "ERROR";
      case GG_EVT_INFO:        return "INFO";
     }
   return "EVT" + IntegerToString(evt);
  }

// เหตุการณ์ที่ส่งเข้า Telegram (INFO ลง log อย่างเดียว)
bool GG_EventToTelegram(const int evt)
  {
   return evt != GG_EVT_INFO;
  }

// escape ข้อความสำหรับใส่ใน JSON string
string GG_JsonEscape(const string s)
  {
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\n", "\\n");
   StringReplace(r, "\r", "\\r");
   StringReplace(r, "\t", "\\t");
   return r;
  }

string GG_JsonBool(const bool b) { return b ? "true" : "false"; }

class CNotifier
  {
private:
   bool              m_telegramEnabled;
   string            m_botToken;     // จาก input เท่านั้น ห้ามฮาร์ดโค้ด
   string            m_chatId;
   string            m_statusUrl;
   string            m_statusAuth;   // ส่งเป็น Authorization: Bearer <...> (ว่าง = ไม่ส่ง)
   string            m_tag;          // เช่น "GoldGrid XAUUSD DEMO"
   int               m_timeoutMs;
   bool              m_warnedAllowlist;
   string            m_lastErrMsg;
   datetime          m_lastErrTime;

   // POST JSON; คืน HTTP status (หรือ -1 ถ้า WebRequest ล้มเหลว)
   int               PostJson(const string url, const string json, const string extraHeaders)
     {
      if(IsTesting())
         return -1;
      char data[];
      char result[];
      string resultHeaders;
      int len = StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
      if(len > 0)
         ArrayResize(data, len - 1);                    // ตัด null ท้ายสตริง
      string headers = "Content-Type: application/json\r\n" + extraHeaders;
      ResetLastError();
      int code = WebRequest("POST", url, headers, m_timeoutMs, data, result, resultHeaders);
      if(code == -1)
        {
         int err = GetLastError();
         if(err == 4060 || err == 4014 || err == 5203)
           {
            if(!m_warnedAllowlist)
              {
               GG_Log("WARN", "WebRequest blocked (err " + IntegerToString(err)
                      + "): add the URL host to Tools > Options > Expert Advisors > Allow WebRequest");
               m_warnedAllowlist = true;
              }
           }
         else
            GG_Log("WARN", "WebRequest failed err=" + IntegerToString(err));
        }
      else
         if(code >= 400)
            GG_Log("WARN", "WebRequest HTTP " + IntegerToString(code) + " " + CharArrayToString(result, 0, MathMin(ArraySize(result), 200), CP_UTF8));
      return code;
     }

public:
                     CNotifier(void)
     {
      m_telegramEnabled = false;
      m_timeoutMs = 3000;
      m_warnedAllowlist = false;
      m_lastErrTime = 0;
     }

   void              Init(const bool telegramEnabled, const string botToken, const string chatId,
                          const string statusUrl, const string statusAuth = "", const string tag = GG_NAME,
                          const int timeoutMs = 3000)
     {
      m_telegramEnabled = telegramEnabled;
      m_botToken        = botToken;
      m_chatId          = chatId;
      m_statusUrl       = statusUrl;
      m_statusAuth      = statusAuth;
      m_tag             = tag;
      m_timeoutMs       = timeoutMs;
      if(m_telegramEnabled && (m_botToken == "" || m_chatId == ""))
        {
         GG_Log("WARN", "Telegram enabled but token/chat id is empty -> Telegram disabled");
         m_telegramEnabled = false;
        }
     }

   static string     BuildTelegramJson(const string chatId, const string text)
     {
      return "{\"chat_id\":\"" + GG_JsonEscape(chatId) + "\",\"text\":\"" + GG_JsonEscape(text)
             + "\",\"disable_web_page_preview\":true}";
     }

   bool              SendTelegram(const string text)
     {
      if(!m_telegramEnabled)
         return false;
      string url = "https://api.telegram.org/bot" + m_botToken + "/sendMessage";
      int code = PostJson(url, BuildTelegramJson(m_chatId, text), "");
      return (code >= 200 && code < 300);
     }

   void              Event(const int evt, const string msg)
     {
      GG_Log(GG_EventText(evt), msg);
      if(!m_telegramEnabled || !GG_EventToTelegram(evt))
         return;
      // กัน error ข้อความเดิมรัวเข้า Telegram (ซ้ำภายใน 60 วินาทีไม่ส่ง)
      if(evt == GG_EVT_ERROR)
        {
         if(msg == m_lastErrMsg && TimeCurrent() - m_lastErrTime < 60)
            return;
         m_lastErrMsg  = msg;
         m_lastErrTime = TimeCurrent();
        }
      SendTelegram("[" + m_tag + "] " + GG_EventText(evt) + "\n" + msg);
     }

   void              PushStatus(const string json)
     {
      if(m_statusUrl == "")
         return;
      string extra = (m_statusAuth == "") ? "" : "Authorization: Bearer " + m_statusAuth + "\r\n";
      PostJson(m_statusUrl, json, extra);
     }
  };

#endif // GOLDGRID_NOTIFIER_MQH
//+------------------------------------------------------------------+
