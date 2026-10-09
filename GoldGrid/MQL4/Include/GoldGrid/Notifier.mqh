//+------------------------------------------------------------------+
//| GoldGrid/Notifier.mqh                                            |
//| แจ้งเตือน Telegram และส่ง JSON สถานะไป StatusURL                       |
//|                                                                  |
//| เฟส 1: log อย่างเดียว (โครง API พร้อมแล้ว)                            |
//| TODO(phase 3): ส่ง Telegram ผ่าน WebRequest + POST JSON ทุก N วินาที    |
//|   - ต้องเพิ่ม https://api.telegram.org และโดเมนของ StatusURL            |
//|     ใน Tools > Options > Expert Advisors > Allow WebRequest         |
//|   - ห้าม log token ออกมา                                            |
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

class CNotifier
  {
private:
   bool              m_telegramEnabled;
   string            m_botToken;     // จาก input เท่านั้น ห้ามฮาร์ดโค้ด
   string            m_chatId;
   string            m_statusUrl;

public:
                     CNotifier(void) { m_telegramEnabled = false; }

   void              Init(const bool telegramEnabled, const string botToken,
                          const string chatId, const string statusUrl)
     {
      m_telegramEnabled = telegramEnabled;
      m_botToken        = botToken;
      m_chatId          = chatId;
      m_statusUrl       = statusUrl;
      if(m_telegramEnabled && (m_botToken == "" || m_chatId == ""))
         GG_Log("WARN", "Telegram enabled but token/chat id is empty");
     }

   void              Event(const int evt, const string msg)
     {
      GG_Log(GG_EventText(evt), msg);
      // TODO(phase 3): if(m_telegramEnabled) SendTelegram(...)
     }

   void              PushStatus(const string json)
     {
      if(m_statusUrl == "")
         return;
      // TODO(phase 3): WebRequest("POST", m_statusUrl, ...)
     }
  };

#endif // GOLDGRID_NOTIFIER_MQH
//+------------------------------------------------------------------+
