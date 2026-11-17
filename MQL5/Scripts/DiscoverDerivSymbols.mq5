//+------------------------------------------------------------------+
//|                                      DiscoverDerivSymbols.mq5     |
//|  Read-only inventory of every symbol the connected broker exposes. |
//|                                                                    |
//|  Produces two files under MQL5/Files:                              |
//|    deriv_symbols_discovered.csv  - all symbols and live specs      |
//|    deriv_symbols_template.csv    - one row per logical symbol from |
//|                                    the strategy template, with the |
//|                                    best matching broker symbol     |
//|                                                                    |
//|  Review both files, then copy the template into deriv_symbols.csv  |
//|  and correct any row the heuristic guessed wrongly.                |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property description "Enumerate broker symbols and suggest Deriv logical-name mappings."

input bool   InpSelectedOnly = false;   // Only Market Watch symbols
input bool   InpIncludePaths = true;    // Include SYMBOL_PATH in the output
input string InpOutFile      = "deriv_symbols_discovered.csv";
input string InpTemplateFile = "deriv_symbols_template.csv";

//+------------------------------------------------------------------+
string Cell(const string s)
  {
   string t = s;
   StringReplace(t, "\r", " ");
   StringReplace(t, "\n", " ");
   StringReplace(t, ",", ";");
   return t;
  }

//+------------------------------------------------------------------+
void WriteSymbolRow(const int h, const string name, const bool selected)
  {
   string path        = SymbolInfoString(name, SYMBOL_PATH);
   string desc        = SymbolInfoString(name, SYMBOL_DESCRIPTION);
   string base        = SymbolInfoString(name, SYMBOL_CURRENCY_BASE);
   string profit      = SymbolInfoString(name, SYMBOL_CURRENCY_PROFIT);
   string margin      = SymbolInfoString(name, SYMBOL_CURRENCY_MARGIN);
   long   digits      = SymbolInfoInteger(name, SYMBOL_DIGITS);
   double point       = SymbolInfoDouble(name, SYMBOL_POINT);
   double tick_size   = SymbolInfoDouble(name, SYMBOL_TRADE_TICK_SIZE);
   double tick_value  = SymbolInfoDouble(name, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double contract    = SymbolInfoDouble(name, SYMBOL_TRADE_CONTRACT_SIZE);
   double vol_min     = SymbolInfoDouble(name, SYMBOL_VOLUME_MIN);
   double vol_max     = SymbolInfoDouble(name, SYMBOL_VOLUME_MAX);
   double vol_step    = SymbolInfoDouble(name, SYMBOL_VOLUME_STEP);
   long   stops       = SymbolInfoInteger(name, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze      = SymbolInfoInteger(name, SYMBOL_TRADE_FREEZE_LEVEL);
   long   spread      = SymbolInfoInteger(name, SYMBOL_SPREAD);
   long   trade_mode  = SymbolInfoInteger(name, SYMBOL_TRADE_MODE);
   long   fill_mask   = SymbolInfoInteger(name, SYMBOL_FILLING_MODE);
   double margin_init = SymbolInfoDouble(name, SYMBOL_MARGIN_INITIAL);

   string line = StringFormat("%s,%s,%s,%s,%s,%s,%I64d,%s,%s,%s,%s,%s,%s,%I64d,%I64d,%I64d,%I64d,%I64d,%I64d,%s,%s",
                              Cell(name),
                              InpIncludePaths ? Cell(path) : "",
                              Cell(desc),
                              selected ? "1" : "0",
                              Cell(base),
                              Cell(profit),
                              digits,
                              DoubleToString(point, 10),
                              DoubleToString(tick_size, 10),
                              DoubleToString(tick_value, 5),
                              DoubleToString(contract, 4),
                              DoubleToString(vol_min, 4),
                              DoubleToString(vol_max, 4),
                              (long)MathRound(vol_step / ((point > 0.0) ? point : 1.0)),
                              stops,
                              freeze,
                              spread,
                              trade_mode,
                              fill_mask,
                              Cell(margin),
                              DoubleToString(margin_init, 4));
   FileWriteString(h, line + "\r\n");
  }

//+------------------------------------------------------------------+
//| Logical template rows from the specification.                     |
//+------------------------------------------------------------------+
void WriteTemplates(const int h)
  {
   string logical[] = {"EURUSD","GBPUSD","USDJPY","AUDUSD","USDCAD","USDCHF",
                       "XAUUSD","XAGUSD","US30","US500","NAS100","GER40","UK100"};
   string cls[]     = {"fx","fx","fx","fx","fx","fx",
                       "metal","metal","index","index","index","index","index"};
   string profile[] = {"london_ny","london_ny","tokyo_london_ny","tokyo_london_ny",
                       "london_ny","london_ny","london_ny","london_ny",
                       "us_cash","us_cash","us_cash","europe_cash","europe_cash"};
   string group[]   = {"USD_EUR","USD_GBP","USD_JPY","AUD_USD","USD_CAD","USD_CHF",
                       "USD_MACRO","USD_MACRO","US_EQUITY","US_EQUITY","US_EQUITY",
                       "EU_EQUITY","UK_EQUITY"};
   string ccy[]     = {"USD,EUR","USD,GBP","USD,JPY","AUD,USD","USD,CAD","USD,CHF",
                       "USD","USD","USD","USD","USD","EUR","GBP"};
   double risk[]    = {0.50,0.50,0.50,0.50,0.50,0.50,0.35,0.25,0.35,0.35,0.30,0.30,0.30};
   int spreadcap[]  = {30,35,30,35,35,35,80,100,500,100,200,100,100};
   int minatr[]     = {50,60,50,50,50,50,300,200,500,150,300,200,200};
   int maxpos[]     = {2,2,2,2,2,2,1,1,1,1,1,1,1};

   FileWriteString(h, "symbol,asset_class,base_currency,quote_currency,session_profile,"
                      "max_risk_pct,max_spread_points,atr_period,min_atr_points,max_positions,"
                      "correlation_group,news_currencies,enabled,resolved_broker_symbol,resolve_method\r\n");

   int total = SymbolsTotal(false);
   for(int i = 0; i < ArraySize(logical); i++)
     {
      string logical_name = logical[i];
      string best = "";
      string method = "";
      int best_score = 0;

      for(int k = 0; k < total; k++)
        {
         string broker = SymbolName(k, false);
         string up = broker;
         StringToUpper(up);
         string target = logical_name;
         int score = 0;
         if(up == target)
           {
            score = 100;
           }
         else if(StringFind(up, target) >= 0)
           {
            score = 80;
            string path = SymbolInfoString(broker, SYMBOL_PATH);
            StringToUpper(path);
            if(StringFind(path, "DERIV") >= 0 || StringFind(path, "FINANCIAL") >= 0)
               score += 10;
            score -= (int)StringLen(broker) - (int)StringLen(target);
           }
         else if(StringFind(up, "XAU") >= 0 && target == "XAUUSD")
            score = 50;
         else if(StringFind(up, "XAG") >= 0 && target == "XAGUSD")
            score = 50;
         if(score > best_score)
           {
            best_score = score;
            best = broker;
            method = (score >= 100) ? "exact" : (score >= 50 ? "fuzzy" : "");
           }
        }

      string base = logical_name;
      string quote = "";
      if(StringLen(logical_name) == 6)
        {
         base  = StringSubstr(logical_name, 0, 3);
         quote = StringSubstr(logical_name, 3, 3);
        }
      else
        {
         base = "";
         quote = "";
        }

      string line = StringFormat("%s,%s,%s,%s,%s,%.2f,%d,14,%d,%d,%s,\"%s\",1,%s,%s",
                                 logical_name,
                                 cls[i],
                                 base,
                                 quote,
                                 profile[i],
                                 risk[i],
                                 spreadcap[i],
                                 minatr[i],
                                 maxpos[i],
                                 group[i],
                                 ccy[i],
                                 best,
                                 method);
      FileWriteString(h, line + "\r\n");
     }
  }

//+------------------------------------------------------------------+
void OnStart(void)
  {
   int h = FileOpen(InpOutFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("cannot open %s (error %d)", InpOutFile, GetLastError());
      return;
     }
   FileWriteString(h, "symbol,path,description,selected,base_currency,profit_currency,digits,"
                      "point,tick_size,tick_value_loss,contract_size,vol_min,vol_max,"
                      "vol_step_points,stops_level,freeze_level,spread,trade_mode,filling_mask,"
                      "margin_currency,margin_initial\r\n");

   int total = SymbolsTotal(InpSelectedOnly);
   int written = 0;
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, InpSelectedOnly);
      if(name == "")
         continue;
      WriteSymbolRow(h, name, (bool)SymbolInfoInteger(name, SYMBOL_SELECT));
      written++;
     }
   FileClose(h);
   PrintFormat("wrote %d symbols to %s", written, InpOutFile);

   int t = FileOpen(InpTemplateFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(t == INVALID_HANDLE)
     {
      PrintFormat("cannot open %s (error %d)", InpTemplateFile, GetLastError());
      return;
     }
   WriteTemplates(t);
   FileClose(t);
   PrintFormat("wrote logical template to %s", InpTemplateFile);
  }
//+------------------------------------------------------------------+

