//+------------------------------------------------------------------+
//| GoldGrid/TestKit.mqh                                             |
//| assert เล็ก ๆ สำหรับรันชุดทดสอบใน Strategy Tester                       |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_TESTKIT_MQH
#define GOLDGRID_TESTKIT_MQH

int    g_tkPass = 0;
int    g_tkFail = 0;
int    g_tkSkip = 0;
string g_tkSection = "";
string g_tkFailures = "";

void TK_Section(const string name)
  {
   g_tkSection = name;
   Print("[TEST] ---- ", name, " ----");
  }

void TK_True(const string name, const bool cond, const string detail = "")
  {
   if(cond)
     {
      g_tkPass++;
      return;
     }
   g_tkFail++;
   string line = g_tkSection + " :: " + name + (detail == "" ? "" : " | " + detail);
   g_tkFailures += line + "\n";
   Print("[TEST][FAIL] ", line);
  }

void TK_EqD(const string name, const double expected, const double actual, const double eps = 1e-6)
  {
   TK_True(name, MathAbs(expected - actual) <= eps,
           "expected=" + DoubleToString(expected, 6) + " actual=" + DoubleToString(actual, 6));
  }

void TK_EqI(const string name, const int expected, const int actual)
  {
   TK_True(name, expected == actual,
           "expected=" + IntegerToString(expected) + " actual=" + IntegerToString(actual));
  }

void TK_Skip(const string name, const string why)
  {
   g_tkSkip++;
   Print("[TEST][SKIP] ", g_tkSection, " :: ", name, " | ", why);
  }

// พิมพ์สรุปลง Journal และเขียนไฟล์ใน <tester>/files/<fileName>
void TK_Report(const string fileName)
  {
   string summary = StringFormat("RESULT: %s  pass=%d fail=%d skip=%d",
                                 g_tkFail == 0 ? "ALL PASSED" : "FAILED", g_tkPass, g_tkFail, g_tkSkip);
   Print("[TEST] ==== ", summary, " ====");
   if(g_tkFail > 0)
      Print("[TEST] failures:\n", g_tkFailures);

   int h = FileOpen(fileName, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE)
     {
      FileWriteString(h, summary + "\n");
      if(g_tkFail > 0)
         FileWriteString(h, g_tkFailures);
      FileClose(h);
     }
   Comment("GoldGrid tests: ", summary);
  }

#endif // GOLDGRID_TESTKIT_MQH
//+------------------------------------------------------------------+
