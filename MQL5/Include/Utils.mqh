//+------------------------------------------------------------------+
//|                                                        Utils.mqh |
//|  Pure helpers: numeric guards, time arithmetic, CSV parsing,      |
//|  lot rounding and file helpers. No trading decisions here.        |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_UTILS_MQH__
#define __DERIV_AI_UTILS_MQH__

#include <Config.mqh>

#define DAI_LOG_PREFIX "[DerivAI] "

//+------------------------------------------------------------------+
//| Numeric helpers                                                    |
//+------------------------------------------------------------------+
bool IsFinite(const double v)
  {
   return MathIsValidNumber(v);
  }

double SafeDiv(const double a, const double b, const double fallback = 0.0)
  {
   if(!IsFinite(a) || !IsFinite(b) || MathAbs(b) < 1e-12)
      return fallback;
   double r = a / b;
   return IsFinite(r) ? r : fallback;
  }

double ClampD(const double v, const double lo, const double hi)
  {
   if(!IsFinite(v))
      return lo;
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
  }

int ClampI(const int v, const int lo, const int hi)
  {
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
  }

double SignD(const double v)
  {
   if(v > 0.0) return 1.0;
   if(v < 0.0) return -1.0;
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Round a price to the instrument tick size.                       |
//+------------------------------------------------------------------+
double RoundToTick(const double price, const double tick_size)
  {
   if(!IsFinite(price) || tick_size <= 0.0)
      return price;
   return MathRound(price / tick_size) * tick_size;
  }

//+------------------------------------------------------------------+
//| Round a volume DOWN to the broker lot step, then clamp.           |
//| Returns 0 when the budget is below the minimum tradable volume.   |
//+------------------------------------------------------------------+
double RoundLotDown(const double volume, const double step,
                    const double vmin, const double vmax)
  {
   if(!IsFinite(volume) || volume <= 0.0 || step <= 0.0)
      return 0.0;
   double steps = MathFloor(volume / step + 1e-9);
   double lot = steps * step;
   if(lot < vmin)
      return 0.0;
   if(lot > vmax)
      lot = MathFloor(vmax / step + 1e-9) * step;
   // re-normalise binary representation noise (e.g. 0.30000000000000004)
   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-9)
     {
      s *= 10.0;
      digits++;
     }
   return NormalizeDouble(lot, digits);
  }

//+------------------------------------------------------------------+
//| Time helpers                                                      |
//+------------------------------------------------------------------+
int MinuteOfDay(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour * 60 + dt.min;
  }

//+------------------------------------------------------------------+
//| Window test on minute-of-day, inclusive start, exclusive end.     |
//| Windows that cross midnight (start >= end) wrap correctly.        |
//+------------------------------------------------------------------+
bool MinuteInWindow(const int minute, const int start_min, const int end_min)
  {
   int s = ((start_min % 1440) + 1440) % 1440;
   int e = ((end_min   % 1440) + 1440) % 1440;
   int m = ((minute     % 1440) + 1440) % 1440;
   if(s == e)
      return true;                 // 24h window
   if(s < e)
      return (m >= s && m < e);
   return (m >= s || m < e);
  }

datetime DayFloor(const datetime t, const int roll_hour_utc)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime midnight = StructToTime(dt);
   int shift = ClampI(roll_hour_utc, 0, 23) * 3600;
   if(t - midnight < shift)
      midnight -= 86400;
   return midnight + shift;
  }

//+------------------------------------------------------------------+
//| Week id: ISO-like, Monday based, YYYYWW.                          |
//+------------------------------------------------------------------+
int WeekId(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int day_of_year = dt.day_of_year;
   int dow = dt.day_of_week;              // 0 Sunday .. 6 Saturday
   int monday_based = (dow + 6) % 7;      // 0 Monday
   int thursday_based = day_of_year - monday_based + 3;
   int year = dt.year;
   if(thursday_based < 1)
     {
      year--;
      thursday_based += 365 + (((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) ? 1 : 0);
     }
   int week = 1 + (thursday_based - 1) / 7;
   return year * 100 + week;
  }

int DayId(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

string TimeToIso(const datetime t)
  {
   if(t <= 0)
      return "";
   return TimeToString(t, TIME_DATE | TIME_SECONDS);
  }

//+------------------------------------------------------------------+
//| String helpers                                                    |
//+------------------------------------------------------------------+
string TrimStr(const string s)
  {
   string t = s;
   StringTrimLeft(t);
   StringTrimRight(t);
   return t;
  }

string UpperStr(const string s)
  {
   string t = s;
   StringToUpper(t);
   return t;
  }

string LowerStr(const string s)
  {
   string t = s;
   StringToLower(t);
   return t;
  }

//+------------------------------------------------------------------+
//| Normalised symbol key: uppercase, alphanumeric only. Used only    |
//| for matching config names to broker names; never for display.     |
//+------------------------------------------------------------------+
string NormalizeSymbolKey(const string s)
  {
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      ushort ch = StringGetCharacter(s, i);
      if((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9'))
        {
         if(ch >= 'a' && ch <= 'z')
            ch = (ushort)(ch - 32);
         out += ShortToString(ch);
        }
     }
   return out;
  }

//+------------------------------------------------------------------+
//| CSV-safe field: commas, quotes and newlines are replaced.        |
//+------------------------------------------------------------------+
string CsvSafe(const string s)
  {
   string t = s;
   StringReplace(t, "\"", "'");
   StringReplace(t, ",", ";");
   StringReplace(t, "\r", " ");
   StringReplace(t, "\n", " ");
   return t;
  }

//+------------------------------------------------------------------+
//| Split one CSV record, honouring double quotes and escaped quotes. |
//| Accepts ',' or a custom single-character delimiter.              |
//+------------------------------------------------------------------+
int CsvSplit(const string line, const ushort delim, string &out[])
  {
   ArrayResize(out, 0);
   string cur = "";
   bool in_quotes = false;
   int n = StringLen(line);
   for(int i = 0; i < n; i++)
     {
      ushort ch = StringGetCharacter(line, i);
      if(in_quotes)
        {
         if(ch == '"')
           {
            if(i + 1 < n && StringGetCharacter(line, i + 1) == '"')
              {
               cur += "\"";
               i++;
              }
            else
               in_quotes = false;
           }
         else
            cur += ShortToString(ch);
        }
      else
        {
         if(ch == '"')
            in_quotes = true;
         else if(ch == delim)
           {
            int sz = ArraySize(out);
            ArrayResize(out, sz + 1);
            out[sz] = cur;
            cur = "";
           }
         else if(ch != '\r')
            cur += ShortToString(ch);
        }
     }
   int sz = ArraySize(out);
   ArrayResize(out, sz + 1);
   out[sz] = cur;
   return ArraySize(out);
  }

string JoinStrings(const string &arr[], const string sep, const int count)
  {
   string out = "";
   int n = MathMin(count, ArraySize(arr));
   for(int i = 0; i < n; i++)
     {
      if(i > 0)
         out += sep;
      out += arr[i];
     }
   return out;
  }

//+------------------------------------------------------------------+
//| File helpers.                                                     |
//+------------------------------------------------------------------+
bool FileExistsIn(const string name, const bool common_folder)
  {
   int flags = FILE_READ | FILE_BIN;
   if(common_folder)
      flags |= FILE_COMMON;
   int h = FileOpen(name, flags);
   if(h == INVALID_HANDLE)
      return false;
   FileClose(h);
   return true;
  }

bool EnsureFolder(const string dir, const bool common_folder)
  {
   if(dir == "")
      return true;
   int flags = 0;
   if(common_folder)
      flags |= FILE_COMMON;
   if(FolderCreate(dir, flags))
      return true;
   // already exists is not an error
   ResetLastError();
   return true;
  }

//+------------------------------------------------------------------+
//| Read a whole text file into an array of lines.                    |
//| Returns false with err set when the file cannot be opened.        |
//+------------------------------------------------------------------+
bool ReadTextLines(const string name, const bool common_folder,
                   string &lines[], string &err)
  {
   ArrayResize(lines, 0);
   int flags = FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ;
   if(common_folder)
      flags |= FILE_COMMON;
   ResetLastError();
   int h = FileOpen(name, flags);
   if(h == INVALID_HANDLE)
     {
      err = StringFormat("cannot open '%s' (error %d)", name, GetLastError());
      return false;
     }
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringReplace(line, "\r", "");
      if(line == "" && FileIsEnding(h))
         break;
      int sz = ArraySize(lines);
      ArrayResize(lines, sz + 1);
      lines[sz] = line;
     }
   FileClose(h);
   return true;
  }

//+------------------------------------------------------------------+
//| Read a whole text file.                                           |
//+------------------------------------------------------------------+
bool ReadTextFile(const string name, const bool common_folder, string &out, string &err)
  {
   out = "";
   int flags = FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ;
   if(common_folder)
      flags |= FILE_COMMON;
   ResetLastError();
   int h = FileOpen(name, flags);
   if(h == INVALID_HANDLE)
     {
      err = StringFormat("cannot open '%s' (error %d)", name, GetLastError());
      return false;
     }
   while(!FileIsEnding(h))
      out += FileReadString(h) + "\n";
   FileClose(h);
   if(StringLen(out) > 1048576)
     {
      out = "";
      err = StringFormat("file '%s' exceeds the size limit", name);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Verbose logging gated by configuration verbosity.                 |
//+------------------------------------------------------------------+
void LogInfo(const int verbosity, const int required, const string msg)
  {
   if(verbosity >= required)
      Print(DAI_LOG_PREFIX, msg);
  }

void LogError(const string msg)
  {
   Print(DAI_LOG_PREFIX, "ERROR: ", msg);
  }

void LogWarn(const string msg)
  {
   Print(DAI_LOG_PREFIX, "WARN: ", msg);
  }

//+------------------------------------------------------------------+
//| Environment checks                                                |
//+------------------------------------------------------------------+
bool IsStrategyTester()
  {
   return (bool)MQLInfoInteger(MQL_TESTER);
  }

bool IsOptimization()
  {
   return (bool)MQLInfoInteger(MQL_OPTIMIZATION);
  }

bool IsVisualMode()
  {
   return (bool)MQLInfoInteger(MQL_VISUAL_MODE);
  }

bool IsTradingAllowedByTerminal()
  {
   if(!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!(bool)MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return false;
   return true;
  }

bool IsConnected()
  {
   if(IsStrategyTester())
      return true;
   return (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
  }

#endif
//+------------------------------------------------------------------+
