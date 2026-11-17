//+------------------------------------------------------------------+
//|                                                        ExportBars.mq5 |
//|  Export closed OHLCV history as CSV for the Python pipeline.       |
//|                                                                  |
//|  Times are written in UTC because the research pipeline and the    |
//|  EA sessions both reason in UTC. MT5 stores bar times in server    |
//|  time, so the script subtracts the detected (or configured)        |
//|  offset. A single offset is used for the whole export; if the      |
//|  range spans a DST change, export each period separately or set    |
//|  the offset for the dominant period.                               |
//|                                                                  |
//|  Output columns: time,open,high,low,close,tick_volume              |
//+------------------------------------------------------------------+
#property copyright "Deriv AI MT5"
#property version   "1.00"
#property script_show_inputs
#property strict

#include <Config.mqh>
#include <Utils.mqh>
#include <SymbolSpec.mqh>

input string          InpSymbolCsv    = "deriv_symbols.csv"; // Symbol CSV (MQL5/Files)
input bool            InpSymbolsCommon= false;               // Read symbol CSV from Common\Files
input string          InpSuffix       = "";                  // Broker suffix (e.g. ".deriv")
input string          InpOverrides    = "";                  // LOGICAL=BROKER overrides, ';' separated
input string          InpSymbol       = "";                  // Logical symbol (empty = all enabled)
input ENUM_TIMEFRAMES InpTimeframe    = PERIOD_M15;          // Timeframe
input int             InpBars         = 20000;               // Bars when start time is 0
input datetime        InpStartTime    = 0;                   // Start (server time, 0 = last InpBars)
input datetime        InpEndTime      = 0;                   // End (server time, 0 = now)
input int             InpUtcOffsetHours = 99;                // Server-UTC offset (99 = auto)
input string          InpOutDir       = "";                  // Output directory (empty = MQL5/Files)
input bool            InpCommonFolder = false;               // Write to Common\Files
input bool            InpPrintProgress= true;                // Print progress every 10000 bars

void OnStart()
  {
   if(InpBars < 2 && InpStartTime == 0)
     {
      Print("InpBars must be at least 2");
      return;
     }

   int offset_seconds = 0;
   if(InpUtcOffsetHours == 99)
     {
      long raw = (long)TimeTradeServer() - (long)TimeGMT();
      offset_seconds = (int)(MathRound((double)raw / 900.0) * 900.0);
      if(offset_seconds < -12 * 3600)
         offset_seconds = -12 * 3600;
      if(offset_seconds > 14 * 3600)
         offset_seconds = 14 * 3600;
     }
   else
     {
      if(InpUtcOffsetHours < -12 || InpUtcOffsetHours > 14)
        {
         Print("InpUtcOffsetHours must be -12..14 or 99 for auto");
         return;
        }
      offset_seconds = InpUtcOffsetHours * 3600;
     }

   PrintFormat("server-UTC offset: %+.2f hours", offset_seconds / 3600.0);
   if(offset_seconds == 0)
      Print("WARNING: offset is 0. If the broker is not on UTC, set InpUtcOffsetHours explicitly.");

   string symbols[];
   int count = 0;

   if(InpSymbol != "")
     {
      ArrayResize(symbols, 1);
      symbols[0] = ResolveSymbol(InpSymbol);
      count = 1;
     }
   else
     {
      SymbolsConfig cfg;
      cfg.csv_file = InpSymbolCsv;
      cfg.common_folder = InpSymbolsCommon;
      cfg.suffix = InpSuffix;
      cfg.resolution = SYMBOL_RESOLVE_OVERRIDE;
      cfg.override_map = InpOverrides;
      cfg.auto_select = true;
      cfg.refresh_seconds = 60;
      cfg.max_tick_age_seconds = 300;

      CSymbolRegistry reg;
      string err = "";
      if(!reg.LoadConfig(cfg, err) || !reg.ResolveAll(err))
        {
         PrintFormat("symbol configuration failed: %s", err);
         return;
        }
      for(int i = 0; i < reg.Count(); i++)
        {
         SymbolSpec *spec = reg.At(i);
         if(spec == NULL || !spec.enabled)
            continue;
         ArrayResize(symbols, count + 1);
         symbols[count] = spec.name;
         count++;
        }
     }

   if(count == 0)
     {
      Print("No symbols selected. Provide InpSymbol or enable rows in the CSV.");
      return;
     }

   string tf = TimeframeTag(InpTimeframe);
   int exported = 0;
   int failed = 0;
   for(int i = 0; i < count; i++)
     {
      if(ExportOne(symbols[i], tf, offset_seconds))
         exported++;
      else
         failed++;
     }
   PrintFormat("export complete: %d symbols written, %d failed", exported, failed);
  }

//+------------------------------------------------------------------+
string ResolveSymbol(const string requested)
  {
   SymbolsConfig cfg;
   cfg.csv_file = InpSymbolCsv;
   cfg.common_folder = InpSymbolsCommon;
   cfg.suffix = InpSuffix;
   cfg.resolution = SYMBOL_RESOLVE_OVERRIDE;
   cfg.override_map = InpOverrides;
   cfg.auto_select = true;
   cfg.refresh_seconds = 60;
   cfg.max_tick_age_seconds = 300;

   CSymbolRegistry reg;
   string err = "";
   if(reg.LoadConfig(cfg, err) && reg.ResolveAll(err))
     {
      for(int i = 0; i < reg.Count(); i++)
        {
         SymbolSpec *spec = reg.At(i);
         if(spec == NULL)
            continue;
         if(LowerStr(spec.config_name) == LowerStr(requested) ||
            LowerStr(spec.name) == LowerStr(requested))
            return spec.name;
        }
     }
   //--- fall back to the exact name: the caller may have used the broker's
   //--- own symbol, which is still validated by SymbolSelect below.
   return requested;
  }

//+------------------------------------------------------------------+
string TimeframeTag(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   if(StringFind(s, "PERIOD_") == 0)
      s = StringSubstr(s, 7);
   return s;
  }

//+------------------------------------------------------------------+
string CsvTime(const datetime utc)
  {
   return TimeToString(utc, TIME_DATE | TIME_SECONDS);
  }

//+------------------------------------------------------------------+
bool ExportOne(const string symbol, const string tf_tag, const int offset_seconds)
  {
   if(!SymbolSelect(symbol, true))
     {
      PrintFormat("%s: cannot select in Market Watch (error %d)", symbol, GetLastError());
      return false;
     }

   MqlRates rates[];
   int copied = 0;
   if(InpStartTime > 0)
     {
      datetime to = (InpEndTime > 0) ? InpEndTime : TimeTradeServer();
      copied = CopyRates(symbol, InpTimeframe, InpStartTime, to, rates);
     }
   else
     {
      copied = CopyRates(symbol, InpTimeframe, 0, InpBars, rates);
     }

   if(copied <= 0)
     {
      PrintFormat("%s %s: no history (error %d). Open the chart and scroll back to download it.",
                  symbol, tf_tag, GetLastError());
      return false;
     }
   if(copied < 2)
     {
      PrintFormat("%s %s: only %d bar available", symbol, tf_tag, copied);
      return false;
     }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits < 0)
      digits = _Digits;

   string dir = InpOutDir;
   while(StringLen(dir) > 0 && StringGetCharacter(dir, StringLen(dir) - 1) == '\\')
      dir = StringSubstr(dir, 0, StringLen(dir) - 1);

   string file = (dir == "" ? "" : dir + "\\") + symbol + "_" + tf_tag + ".csv";
   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(InpCommonFolder)
      flags |= FILE_COMMON;

   int handle = FileOpen(file, flags);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("cannot write %s (error %d)", file, GetLastError());
      return false;
     }

   FileWriteString(handle, "time,open,high,low,close,tick_volume\r\n");
   for(int i = 0; i < copied; i++)
     {
      datetime utc = rates[i].time - offset_seconds;
      string line = CsvTime(utc) + "," +
                    DoubleToString(rates[i].open, digits) + "," +
                    DoubleToString(rates[i].high, digits) + "," +
                    DoubleToString(rates[i].low, digits) + "," +
                    DoubleToString(rates[i].close, digits) + "," +
                    IntegerToString((long)rates[i].tick_volume) + "\r\n";
      FileWriteString(handle, line);
      if(InpPrintProgress && (i + 1) % 10000 == 0)
         PrintFormat("%s: %d / %d bars", symbol, i + 1, copied);
     }
   FileClose(handle);

   PrintFormat("wrote %s (%d bars, %s to %s UTC)", file, copied,
               CsvTime(rates[0].time - offset_seconds),
               CsvTime(rates[copied - 1].time - offset_seconds));
   return true;
  }
//+------------------------------------------------------------------+
