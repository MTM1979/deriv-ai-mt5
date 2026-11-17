//+------------------------------------------------------------------+
//|                                         ExportFeatureSamples.mq5 |
//|  Writes raw snapshots and the EA's own feature vectors to JSON.   |
//|                                                                  |
//|  Run this on a chart with history for every configured symbol,    |
//|  then verify the arithmetic contract on the research side:        |
//|                                                                  |
//|    python -m models.parity --samples MQL5/Files/feature_samples.json
//|                                                                  |
//|  The script never trades and never needs an ONNX model; it calls  |
//|  COnnxModelStore::BuildFeatures, the same code the EA uses.       |
//+------------------------------------------------------------------+
#property copyright "Deriv AI MT5"
#property version   "1.00"
#property script_show_inputs
#property strict

#include <Config.mqh>
#include <Utils.mqh>
#include <SymbolSpec.mqh>
#include <Sessions.mqh>
#include <Indicators.mqh>
#include <OnnxModel.mqh>

input string InpSymbolCsv          = "deriv_symbols.csv";   // Symbol CSV (MQL5/Files)
input bool   InpSymbolsCommon      = false;                 // Read CSV from Common\Files
input string InpSuffix             = "";                    // Broker suffix
input string InpOverrides          = "";                    // LOGICAL=BROKER overrides
input int    InpMaxSamplesPerSymbol= 3;                     // Snapshots per symbol
input string InpOutFile            = "feature_samples.json";// Output file in MQL5/Files

//--- session defaults, matching the EA inputs -----------------------
int    g_asian_s = 0,    g_asian_e = 8 * 60;
int    g_london_s = 7 * 60;
int    g_ny_s = 13 * 60 + 30;
int    g_roll_s = 20 * 60 + 45, g_roll_e = 21 * 60 + 15;

string IsoTime(const datetime t)
  {
   string s = TimeToString(t, TIME_DATE | TIME_SECONDS);
   StringReplace(s, ".", "-");
   StringReplace(s, " ", "T");
   return s;
  }

string D(const double v)
  {
   if(!MathIsValidNumber(v))
      return "0";
   return DoubleToString(v, 10);
  }

string B(const bool v)
  {
   return (v ? "true" : "false");
  }

string SnapshotJson(const IndicatorSnapshot &s)
  {
   string j = "{";
   j += "\"valid\":" + B(s.valid) + ",";
   j += "\"bar_time\":\"" + IsoTime(s.bar_time) + "\",";
   j += "\"open\":" + D(s.open) + ",";
   j += "\"high\":" + D(s.high) + ",";
   j += "\"low\":" + D(s.low) + ",";
   j += "\"close\":" + D(s.close) + ",";
   j += "\"ret1\":" + D(s.ret1) + ",";
   j += "\"ret3\":" + D(s.ret3) + ",";
   j += "\"ret12\":" + D(s.ret12) + ",";
   j += "\"atr\":" + D(s.atr) + ",";
   j += "\"atr_percentile\":" + D(s.atr_percentile) + ",";
   j += "\"ema_fast\":" + D(s.ema_fast) + ",";
   j += "\"ema_mid\":" + D(s.ema_mid) + ",";
   j += "\"ema_slow\":" + D(s.ema_slow) + ",";
   j += "\"ema_slow_slope\":" + D(s.ema_slow_slope) + ",";
   j += "\"rsi\":" + D(s.rsi) + ",";
   j += "\"macd_hist\":" + D(s.macd_hist) + ",";
   j += "\"macd_hist_prev\":" + D(s.macd_hist_prev) + ",";
   j += "\"bb_upper\":" + D(s.bb_upper) + ",";
   j += "\"bb_middle\":" + D(s.bb_middle) + ",";
   j += "\"bb_lower\":" + D(s.bb_lower) + ",";
   j += "\"bb_width\":" + D(s.bb_width) + ",";
   j += "\"adx\":" + D(s.adx) + ",";
   j += "\"di_plus\":" + D(s.di_plus) + ",";
   j += "\"di_minus\":" + D(s.di_minus) + ",";
   j += "\"session_high\":" + D(s.session_high) + ",";
   j += "\"session_low\":" + D(s.session_low) + ",";
   j += "\"day_high\":" + D(s.day_high) + ",";
   j += "\"day_low\":" + D(s.day_low) + ",";
   j += "\"prior_day_high\":" + D(s.prior_day_high) + ",";
   j += "\"prior_day_low\":" + D(s.prior_day_low) + ",";
   j += "\"vwap\":" + D(s.vwap) + ",";
   j += "\"htf_close\":" + D(s.htf_close) + ",";
   j += "\"htf_ema_slow\":" + D(s.htf_ema_slow) + ",";
   j += "\"htf_rsi\":" + D(s.htf_rsi) + ",";
   j += "\"htf_atr\":" + D(s.htf_atr) + ",";
   j += "\"volume_ratio\":" + D(s.volume_ratio) + ",";
   j += "\"sweep_high\":" + B(s.sweep_high) + ",";
   j += "\"sweep_low\":" + B(s.sweep_low) + ",";
   j += "\"last_high\":[" + D(s.last_high[0]) + "," + D(s.last_high[1]) + "," +
        D(s.last_high[2]) + "," + D(s.last_high[3]) + "," + D(s.last_high[4]) + "," +
        D(s.last_high[5]) + "],";
   j += "\"last_low\":[" + D(s.last_low[0]) + "," + D(s.last_low[1]) + "," +
        D(s.last_low[2]) + "," + D(s.last_low[3]) + "," + D(s.last_low[4]) + "," +
        D(s.last_low[5]) + "],";
   j += "\"last_close\":[" + D(s.last_close[0]) + "," + D(s.last_close[1]) + "," +
        D(s.last_close[2]) + "," + D(s.last_close[3]) + "," + D(s.last_close[4]) + "," +
        D(s.last_close[5]) + "]";
   j += "}";
   return j;
  }

string FeatureJson(const float &f[])
  {
   string j = "[";
   for(int i = 0; i < ArraySize(f); i++)
     {
      if(i > 0)
         j += ",";
      j += D((double)f[i]);
     }
   j += "]";
   return j;
  }

void OnStart()
  {
   SymbolsConfig symbols;
   symbols.csv_file = InpSymbolCsv;
   symbols.common_folder = InpSymbolsCommon;
   symbols.suffix = InpSuffix;
   symbols.resolution = SYMBOL_RESOLVE_OVERRIDE;
   symbols.override_map = InpOverrides;
   symbols.auto_select = true;
   symbols.refresh_seconds = 60;
   symbols.max_tick_age_seconds = 300;

   CSymbolRegistry registry;
   string err = "";
   if(!registry.LoadConfig(symbols, err) || !registry.ResolveAll(err))
     {
      PrintFormat("symbol configuration failed: %s", err);
      return;
     }

   SessionConfig sc;
   sc.utc_offset_override = 99;
   sc.asian_start_hour = 0;  sc.asian_start_min = 0;
   sc.asian_end_hour = 8;    sc.asian_end_min = 0;
   sc.london_open_hour = 7;  sc.london_open_min = 0;
   sc.ny_open_hour = 13;     sc.ny_open_min = 30;
   sc.rollover_start_hour = 20; sc.rollover_start_min = 45;
   sc.rollover_end_hour = 21;   sc.rollover_end_min = 15;
   sc.opening_range_minutes = 30;
   sc.preopen_minutes = 15;
   sc.enable_asian = true;
   sc.enable_london = true;
   sc.enable_ny = true;
   sc.risk_scale_asian = 0.50;
   sc.risk_scale_open = 1.00;
   sc.risk_scale_core = 0.90;
   sc.risk_scale_preopen = 0.50;
   CSessionEngine sessions;
   if(!sessions.Init(sc, err))
     {
      PrintFormat("session configuration failed: %s", err);
      return;
     }
   sessions.Update(TimeTradeServer());
   if(sessions.OffsetSeconds() == 0)
      Print("WARNING: server-UTC offset is 0; verify it after DST changes.");

   SignalConfig sig;
   sig.exec_tf = PERIOD_M15;
   sig.htf_tf = PERIOD_H1;
   sig.range_tf = PERIOD_M5;
   sig.ema_fast = 21;
   sig.ema_mid = 50;
   sig.ema_slow = 200;
   sig.rsi_period = 14;
   sig.macd_fast = 12;
   sig.macd_slow = 26;
   sig.macd_signal = 9;
   sig.bb_period = 20;
   sig.bb_deviation = 2.0;
   sig.adx_period = 14;
   sig.atr_period = 14;
   sig.atr_percentile_lookback = 200;
   sig.volume_lookback = 20;
   sig.swing_lookback = 20;
   sig.swing_fractal = 2;
   sig.min_bars_required = 200;

   CIndicatorHub hub;
   if(!hub.Init(sig, 0, 300))
     {
      Print("indicator hub init failed");
      return;
     }

   COnnxModelStore features;
   int samples = 0;
   int failures = 0;
   string body = "";

   for(int i = 0; i < registry.Count(); i++)
     {
      SymbolSpec *spec = registry.At(i);
      if(spec == NULL || !spec.enabled)
         continue;
      string symbol = spec.name;
      if(!registry.RefreshIfStale(symbol, err))
        {
         PrintFormat("%s: live spec refresh failed: %s", symbol, err);
         failures++;
         continue;
        }
      spec = registry.Find(symbol);
      if(spec == NULL)
         continue;

      IndicatorSnapshot snap;
      if(!hub.BuildSnapshot(symbol, spec, sessions, snap))
        {
         PrintFormat("%s: snapshot failed: %s", symbol, snap.error);
         failures++;
         continue;
        }

      int emitted = 0;
      for(int direction = 1; direction >= -1 && emitted < InpMaxSamplesPerSymbol; direction -= 2)
        {
         TradeCandidate cand;
         cand.symbol = symbol;
         cand.direction = direction;
         cand.spread_points = (snap.ask - snap.bid) / snap.point;
         cand.minutes_since_open = sessions.MinutesSinceSessionStart();
         cand.minutes_to_event = 9999;
         cand.event_impact = 0;
         cand.atr = snap.atr;
         cand.bar_time = snap.bar_time;
         float f[];
         if(!features.BuildFeatures(spec, snap, cand, f))
           {
            PrintFormat("%s dir=%d: BuildFeatures rejected the snapshot", symbol, direction);
            failures++;
            continue;
           }
         if(samples > 0)
            body += ",";
         body += "{\"symbol\":\"" + symbol + "\",";
         body += "\"direction\":" + IntegerToString(direction) + ",";
         body += "\"point\":" + D(spec.point) + ",";
         body += "\"max_spread_points\":" + IntegerToString(spec.max_spread_points) + ",";
         body += "\"spread_points\":" + D(cand.spread_points) + ",";
         body += "\"minutes_since_open\":" + IntegerToString(cand.minutes_since_open) + ",";
         body += "\"minutes_to_event\":" + IntegerToString(cand.minutes_to_event) + ",";
         body += "\"event_impact\":" + IntegerToString(cand.event_impact) + ",";
         body += "\"snapshot\":" + SnapshotJson(snap) + ",";
         body += "\"features\":" + FeatureJson(f) + "}";
         samples++;
         emitted++;
        }
     }

   string out = "{\"schema\":1,\"note\":\"Generated by ExportFeatureSamples.mq5\",";
   out += "\"generated_at\":\"" + IsoTime(TimeGMT()) + "\",";
   out += "\"samples\":[" + body + "]}";

   int handle = FileOpen(InpOutFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("cannot write %s (error %d)", InpOutFile, GetLastError());
      return;
     }
   FileWriteString(handle, out);
   FileClose(handle);
   PrintFormat("wrote %d feature samples to %s (%d failures)", samples, InpOutFile, failures);
   if(samples == 0)
      Print("No samples were written. Check symbol resolution, history and session state.");
  }
//+------------------------------------------------------------------+
