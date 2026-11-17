//+------------------------------------------------------------------+
//|                                             ExportSymbols.mq5     |
//|  Export the live contract specification of every symbol configured |
//|  in deriv_symbols.csv. Use this to verify the broker's actual      |
//|  values before running the EA, and to attach evidence to a build.  |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property description "Export live specs for the symbols in deriv_symbols.csv."

input string InpSymbolCsv  = "deriv_symbols.csv";   // Symbol CSV
input bool   InpCommonFolder = false;               // Read CSV from Common\Files
input string InpSuffix     = "";                    // Broker suffix
input string InpOutFile    = "deriv_symbols_export.csv";

//+------------------------------------------------------------------+
string Cell(const string s)
  {
   string t = s;
   StringReplace(t, ",", ";");
   StringReplace(t, "\r", " ");
   StringReplace(t, "\n", " ");
   return t;
  }

//+------------------------------------------------------------------+
bool ReadCsv(string &lines[])
  {
   int flags = FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ;
   if(InpCommonFolder)
      flags |= FILE_COMMON;
   int h = FileOpen(InpSymbolCsv, flags);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("cannot open %s (error %d)", InpSymbolCsv, GetLastError());
      return false;
     }
   ArrayResize(lines, 0);
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "")
         continue;
      int n = ArraySize(lines);
      ArrayResize(lines, n + 1);
      lines[n] = line;
     }
   FileClose(h);
   return (ArraySize(lines) >= 2);
  }

string Field(const string &f[], const int idx, const string fallback = "")
  {
   if(idx < 0 || idx >= ArraySize(f))
      return fallback;
   string v = f[idx];
   StringTrimLeft(v);
   StringTrimRight(v);
   return v;
  }

//+------------------------------------------------------------------+
void OnStart(void)
  {
   string lines[];
   if(!ReadCsv(lines))
     {
      Print("no symbol rows found");
      return;
     }

   string head[];
   int hc = StringSplit(lines[0], ',', head);
   int i_sym = -1, i_en = -1;
   for(int i = 0; i < hc; i++)
     {
      string h = head[i];
      StringTrimLeft(h);
      StringTrimRight(h);
      StringToLower(h);
      if(h == "symbol")     i_sym = i;
      if(h == "enabled")    i_en = i;
     }
   if(i_sym < 0)
     {
      Print("CSV has no 'symbol' column");
      return;
     }

   int out = FileOpen(InpOutFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(out == INVALID_HANDLE)
     {
      PrintFormat("cannot open %s (error %d)", InpOutFile, GetLastError());
      return;
     }
   FileWriteString(out,
      "logical,symbol,resolved,digits,point,tick_size,contract_size,vol_min,vol_max,"
      "vol_step,stops_level,freeze_level,spread_points,trade_mode,filling_mask,"
      "margin_initial,currency_profit,currency_margin,market_open\r\n");

   int ok = 0, missing = 0;
   for(int r = 1; r < ArraySize(lines); r++)
     {
      string f[];
      int fc = StringSplit(lines[r], ',', f);
      string logical = Field(f, i_sym);
      if(logical == "")
         continue;
      string enabled = Field(f, i_en, "1");
      if(enabled == "0" || enabled == "false")
         continue;

      string name = logical;
      if(InpSuffix != "" && !SymbolSelect(logical, true))
         name = logical + InpSuffix;

      bool resolved = SymbolSelect(name, true);
      if(!resolved)
        {
         missing++;
         FileWriteString(out, StringFormat("%s,%s,0,,,,,,,,,,,,,,,\r\n",
                                           Cell(logical), Cell(name)));
         continue;
        }
      ok++;

      string line = StringFormat(
         "%s,%s,1,%I64d,%s,%s,%s,%s,%s,%s,%I64d,%I64d,%I64d,%I64d,%I64d,%s,%s,%s,%s",
         Cell(logical),
         Cell(name),
         SymbolInfoInteger(name, SYMBOL_DIGITS),
         DoubleToString(SymbolInfoDouble(name, SYMBOL_POINT), 10),
         DoubleToString(SymbolInfoDouble(name, SYMBOL_TRADE_TICK_SIZE), 10),
         DoubleToString(SymbolInfoDouble(name, SYMBOL_TRADE_CONTRACT_SIZE), 4),
         DoubleToString(SymbolInfoDouble(name, SYMBOL_VOLUME_MIN), 4),
         DoubleToString(SymbolInfoDouble(name, SYMBOL_VOLUME_MAX), 4),
         DoubleToString(SymbolInfoDouble(name, SYMBOL_VOLUME_STEP), 4),
         SymbolInfoInteger(name, SYMBOL_TRADE_STOPS_LEVEL),
         SymbolInfoInteger(name, SYMBOL_TRADE_FREEZE_LEVEL),
         SymbolInfoInteger(name, SYMBOL_SPREAD),
         SymbolInfoInteger(name, SYMBOL_TRADE_MODE),
         SymbolInfoInteger(name, SYMBOL_FILLING_MODE),
         DoubleToString(SymbolInfoDouble(name, SYMBOL_MARGIN_INITIAL), 4),
         Cell(SymbolInfoString(name, SYMBOL_CURRENCY_PROFIT)),
         Cell(SymbolInfoString(name, SYMBOL_CURRENCY_MARGIN)),
         SymbolInfoInteger(name, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED ? "0" : "1");
      FileWriteString(out, line + "\r\n");
     }
   FileClose(out);
   PrintFormat("exported %d symbols (%d unresolved) to %s", ok, missing, InpOutFile);
  }
//+------------------------------------------------------------------+
