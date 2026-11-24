//+------------------------------------------------------------------+
//|                                                   SymbolSpec.mqh |
//|  Owns symbol identity and live contract specifications.           |
//|                                                                  |
//|  Rules enforced here:                                             |
//|   * logical config names are resolved to exact broker names       |
//|   * every contract value is read from the terminal, never         |
//|     hard-coded or trusted from the CSV                             |
//|   * a spec is refreshed before each order and cached briefly       |
//|   * anything unreadable or inconsistent fails closed               |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_SYMBOLSPEC_MQH__
#define __DERIV_AI_SYMBOLSPEC_MQH__

#include <Config.mqh>
#include <Utils.mqh>

class SymbolSpec
  {
public:
   //--- static configuration (from deriv_symbols.csv) --------------
   string   config_name;
   string   name;                 // resolved broker symbol
   string   asset_class;          // fx | metal | index
   ENUM_ASSET_CLASS asset;
   string   base_ccy;
   string   quote_ccy;
   string   session_profile;
   double   max_risk_pct;
   int      max_spread_points;
   int      atr_period;
   int      min_atr_points;
   int      max_positions;
   string   corr_group;
   string   news_currencies;
   bool     enabled;
   int      strategies_mask;

   //--- live contract specification --------------------------------
   bool     resolved;
   bool     live_valid;
   string   resolve_method;
   string   live_error;
   int      digits;
   double   point;
   double   tick_size;
   double   tick_value_profit;
   double   tick_value_loss;
   double   contract_size;
   double   vol_min;
   double   vol_max;
   double   vol_step;
   int      stops_level;
   int      freeze_level;
   int      trade_mode;
   int      filling_mask;
   double   margin_initial;
   double   margin_maintenance;
   double   swap_long;
   double   swap_short;
   string   currency_profit;
   string   currency_margin;
   double   spread_points;
   double   spread_baseline;     // first observed spread, used when no CSV cap
   bool     market_open;
   datetime spec_refreshed;
   datetime market_checked;
  };

//+------------------------------------------------------------------+
//| Registry of configured instruments.                               |
//+------------------------------------------------------------------+
class CSymbolRegistry
  {
private:
   SymbolSpec        m_syms[];
   int               m_count;
   string            m_broker_cache[];
   string            m_override_keys[];
   string            m_override_vals[];
   string            m_warnings[];
   string            m_suffix;
   ENUM_SYMBOL_RESOLUTION m_resolution;
   bool              m_common_folder;
   bool              m_auto_select;
   int               m_refresh_seconds;
   bool              m_warned_session_data;

   int               FindRow(const string name);
   void              Warn(const string msg);
   void              BuildBrokerCache(void);
   bool              ResolveOne(SymbolSpec &s);
   bool              ReadLiveSpec(SymbolSpec &s);
   void              ParseOverrides(const string text);

public:
                     CSymbolRegistry(void);
   bool              LoadConfig(const SymbolsConfig &cfg, string &err);
   bool              ResolveAll(string &err);
   bool              Refresh(const string name, string &err);
   bool              RefreshIfStale(const string name, string &err);
   bool              RefreshAll(string &err);

   int               Count(void)               { return m_count; }
   int               ResolvedCount(void)
     {
      int n = 0;
      for(int i = 0; i < m_count; i++)
         if(m_syms[i].enabled && m_syms[i].resolved)
            n++;
      return n;
     }
   SymbolSpec       *At(const int i);
   SymbolSpec       *Find(const string name);
   int               WarningCount(void)        { return ArraySize(m_warnings); }
   string            WarningAt(const int i)    { return m_warnings[i]; }

   bool              MarketOpen(const string name, const datetime server_time);
   double            SpreadPoints(const string name);
   double            ValuePerPriceUnit(const string name);
   double            MaxRiskPct(const string name);
   int               MaxSpreadPoints(const string name);
   bool              FillingMode(const string name, ENUM_ORDER_TYPE_FILLING &mode);
   bool              StrategyEnabled(const string name, const ENUM_STRATEGY s);
   static ENUM_ASSET_CLASS AssetFromString(const string s);
   static int        StrategyMask(const string s);
  };

//+------------------------------------------------------------------+
CSymbolRegistry::CSymbolRegistry(void)
  {
   m_count = 0;
   m_suffix = "";
   m_resolution = SYMBOL_RESOLVE_SEARCH;
   m_common_folder = false;
   m_auto_select = true;
   m_refresh_seconds = 15;
   m_warned_session_data = false;
  }

void CSymbolRegistry::Warn(const string msg)
  {
   int n = ArraySize(m_warnings);
   ArrayResize(m_warnings, n + 1);
   m_warnings[n] = msg;
   LogWarn(msg);
  }

//+------------------------------------------------------------------+
//| Asset class mapping used by config and model selection.           |
//+------------------------------------------------------------------+
ENUM_ASSET_CLASS CSymbolRegistry::AssetFromString(const string s)
  {
   string v = LowerStr(TrimStr(s));
   if(v == "fx" || v == "forex" || v == "currency")
      return ASSET_FX;
   if(v == "metal" || v == "metals" || v == "commodity")
      return ASSET_METAL;
   if(v == "index" || v == "indices" || v == "equity" || v == "cash")
      return ASSET_INDEX;
   return ASSET_UNKNOWN;
  }

//+------------------------------------------------------------------+
//| strategy mask: "trend|orb|sweep|meanrev" or "all" / "none".       |
//+------------------------------------------------------------------+
int CSymbolRegistry::StrategyMask(const string s)
  {
   int mask = 0;
   string parts[];
   string v = LowerStr(TrimStr(s));
   if(v == "" || v == "all")
      return (1 << STRAT_TREND) | (1 << STRAT_ORB) | (1 << STRAT_SWEEP) | (1 << STRAT_MEANREV);
   if(v == "none")
      return 0;
   StringReplace(v, " ", "");
   StringReplace(v, ";", "|");
   StringReplace(v, ",", "|");
   int n = StringSplit(v, '|', parts);
   for(int i = 0; i < n; i++)
     {
      string p = parts[i];
      if(p == "trend" || p == "trend_continuation")   mask |= (1 << STRAT_TREND);
      else if(p == "orb" || p == "breakout" || p == "opening_range") mask |= (1 << STRAT_ORB);
      else if(p == "sweep" || p == "liquidity_sweep") mask |= (1 << STRAT_SWEEP);
      else if(p == "meanrev" || p == "mean_reversion" || p == "reversion") mask |= (1 << STRAT_MEANREV);
     }
   return mask;
  }

int CSymbolRegistry::FindRow(const string name)
  {
   for(int i = 0; i < m_count; i++)
      if(m_syms[i].config_name == name || m_syms[i].name == name)
         return i;
   return -1;
  }

SymbolSpec *CSymbolRegistry::At(const int i)
  {
   if(i < 0 || i >= m_count)
      return NULL;
   return &m_syms[i];
  }

SymbolSpec *CSymbolRegistry::Find(const string name)
  {
   int i = FindRow(name);
   return (i < 0) ? NULL : &m_syms[i];
  }

//+------------------------------------------------------------------+
//| Parse "LOGICAL=BROKER;OTHER=NAME" overrides.                      |
//+------------------------------------------------------------------+
void CSymbolRegistry::ParseOverrides(const string text)
  {
   ArrayResize(m_override_keys, 0);
   ArrayResize(m_override_vals, 0);
   string parts[];
   string t = text;
   StringReplace(t, ";", "|");
   StringReplace(t, ",", "|");
   int n = StringSplit(t, '|', parts);
   for(int i = 0; i < n; i++)
     {
      string pair = TrimStr(parts[i]);
      if(pair == "")
         continue;
      int eq = StringFind(pair, "=");
      if(eq <= 0)
         continue;
      string k = NormalizeSymbolKey(StringSubstr(pair, 0, eq));
      string v = TrimStr(StringSubstr(pair, eq + 1));
      if(k == "" || v == "")
         continue;
      int sz = ArraySize(m_override_keys);
      ArrayResize(m_override_keys, sz + 1);
      ArrayResize(m_override_vals, sz + 1);
      m_override_keys[sz] = k;
      m_override_vals[sz] = v;
     }
  }

//+------------------------------------------------------------------+
//| Load and validate the symbol CSV. Header names are matched by     |
//| name, so column order and extra columns are tolerated.            |
//+------------------------------------------------------------------+
bool CSymbolRegistry::LoadConfig(const SymbolsConfig &cfg, string &err)
  {
   m_suffix         = cfg.suffix;
   m_resolution     = cfg.resolution;
   m_common_folder  = cfg.common_folder;
   m_auto_select    = cfg.auto_select;
   m_refresh_seconds = MathMax(1, cfg.refresh_seconds);
   ParseOverrides(cfg.override_map);

   string lines[];
   if(!ReadTextLines(cfg.csv_file, cfg.common_folder, lines, err))
      return false;
   if(ArraySize(lines) < 2)
     {
      err = StringFormat("symbol file '%s' has no data rows", cfg.csv_file);
      return false;
     }

   //--- header -----------------------------------------------------
   string head[];
   int hc = CsvSplit(lines[0], ',', head);
   for(int i = 0; i < hc; i++)
      head[i] = LowerStr(TrimStr(head[i]));
   int i_symbol = -1, i_class = -1, i_base = -1, i_quote = -1, i_profile = -1;
   int i_risk = -1, i_spread = -1, i_atr = -1, i_minatr = -1, i_maxpos = -1;
   int i_corr = -1, i_news = -1, i_enabled = -1, i_strat = -1;
   for(int i = 0; i < hc; i++)
     {
      string h = head[i];
      if(h == "symbol")                 i_symbol = i;
      else if(h == "asset_class")       i_class = i;
      else if(h == "base_currency")     i_base = i;
      else if(h == "quote_currency")    i_quote = i;
      else if(h == "session_profile")   i_profile = i;
      else if(h == "max_risk_pct")      i_risk = i;
      else if(h == "max_spread_points") i_spread = i;
      else if(h == "atr_period")        i_atr = i;
      else if(h == "min_atr_points")    i_minatr = i;
      else if(h == "max_positions")     i_maxpos = i;
      else if(h == "correlation_group") i_corr = i;
      else if(h == "news_currencies")   i_news = i;
      else if(h == "enabled")           i_enabled = i;
      else if(h == "strategies")        i_strat = i;
     }
   if(i_symbol < 0 || i_class < 0 || i_profile < 0)
     {
      err = "symbol CSV requires at least symbol, asset_class and session_profile columns";
      return false;
     }

   m_count = 0;
   ArrayResize(m_syms, 0);
   int rows = ArraySize(lines);
   for(int r = 1; r < rows; r++)
     {
      string line = lines[r];
      if(TrimStr(line) == "" || StringGetCharacter(TrimStr(line), 0) == '#')
         continue;
      string f[];
      int fc = CsvSplit(line, ',', f);
      if(fc <= i_symbol)
         continue;
      string logical = TrimStr(f[i_symbol]);
      if(logical == "")
         continue;
      SymbolSpec s;
      s.config_name       = logical;
      s.name              = "";
      s.asset_class       = LowerStr(TrimStr(f[i_class]));
      s.asset             = AssetFromString(s.asset_class);
      s.base_ccy          = (i_base >= 0 && i_base < fc) ? UpperStr(TrimStr(f[i_base])) : "";
      s.quote_ccy         = (i_quote >= 0 && i_quote < fc) ? UpperStr(TrimStr(f[i_quote])) : "";
      s.session_profile   = LowerStr(TrimStr(f[i_profile]));
      s.max_risk_pct      = (i_risk >= 0 && i_risk < fc) ? StringToDouble(TrimStr(f[i_risk])) : 0.35;
      s.max_spread_points = (i_spread >= 0 && i_spread < fc) ? (int)StringToInteger(TrimStr(f[i_spread])) : 50;
      s.atr_period        = (i_atr >= 0 && i_atr < fc) ? (int)StringToInteger(TrimStr(f[i_atr])) : 14;
      s.min_atr_points    = (i_minatr >= 0 && i_minatr < fc) ? (int)StringToInteger(TrimStr(f[i_minatr])) : 0;
      s.max_positions     = (i_maxpos >= 0 && i_maxpos < fc) ? (int)StringToInteger(TrimStr(f[i_maxpos])) : 1;
      s.corr_group        = (i_corr >= 0 && i_corr < fc) ? TrimStr(f[i_corr]) : s.asset_class;
      s.news_currencies   = (i_news >= 0 && i_news < fc) ? TrimStr(f[i_news]) : "";
      s.enabled           = (i_enabled >= 0 && i_enabled < fc) ? (StringToInteger(TrimStr(f[i_enabled])) != 0) : true;
      s.strategies_mask   = (i_strat >= 0 && i_strat < fc) ? StrategyMask(f[i_strat]) : StrategyMask("all");

      if(s.asset == ASSET_UNKNOWN)
        {
         Warn(StringFormat("symbol '%s': unknown asset_class '%s' - row disabled", logical, s.asset_class));
         s.enabled = false;
        }
      if(s.session_profile == "")
         s.session_profile = "all";
      if(s.corr_group == "")
         s.corr_group = s.asset_class;
      s.max_risk_pct      = ClampD(s.max_risk_pct, 0.0, 5.0);
      s.max_spread_points = ClampI(s.max_spread_points, 1, 1000000);
      s.atr_period        = ClampI(s.atr_period, 2, 200);
      s.min_atr_points    = ClampI(s.min_atr_points, 0, 1000000);
      s.max_positions     = ClampI(s.max_positions, 0, 50);

      // live fields are intentionally zeroed until Refresh()
      s.resolved = false;
      s.live_valid = false;
      s.digits = 0; s.point = 0; s.tick_size = 0;
      s.tick_value_profit = 0; s.tick_value_loss = 0;
      s.contract_size = 0; s.vol_min = 0; s.vol_max = 0; s.vol_step = 0;
      s.stops_level = 0; s.freeze_level = 0; s.trade_mode = 0; s.filling_mask = 0;
      s.margin_initial = 0; s.margin_maintenance = 0;
      s.swap_long = 0; s.swap_short = 0;
      s.currency_profit = ""; s.currency_margin = "";
      s.spread_points = 0; s.spread_baseline = 0; s.market_open = false;
      s.spec_refreshed = 0; s.market_checked = 0;

      int n = ArraySize(m_syms);
      ArrayResize(m_syms, n + 1);
      m_syms[n] = s;
      m_count++;
     }

   if(m_count == 0)
     {
      err = "symbol CSV contains no usable rows";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Broker symbol cache and resolution.                               |
//|                                                                  |
//| Resolution order is explicit and journaled. A fuzzy match is     |
//| accepted only when exactly one candidate exists at the shortest  |
//| remaining length; ambiguity fails closed and is reported.        |
//+------------------------------------------------------------------+
void CSymbolRegistry::BuildBrokerCache(void)
  {
   ArrayResize(m_broker_cache, 0);
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string n = SymbolName(i, false);
      if(n == "")
         continue;
      int sz = ArraySize(m_broker_cache);
      if(!ArrayResize(m_broker_cache, sz + 1))
         break;
      m_broker_cache[sz] = n;
     }
  }

bool CSymbolRegistry::ResolveOne(SymbolSpec &s)
  {
   s.resolved = false;
   s.resolve_method = "";
   string logical = s.config_name;
   string by_override = "";

   //--- 1. explicit override map -----------------------------------
   if(m_resolution == SYMBOL_RESOLVE_OVERRIDE)
     {
      string key = NormalizeSymbolKey(logical);
      for(int i = 0; i < ArraySize(m_override_keys); i++)
         if(m_override_keys[i] == key)
           {
            by_override = m_override_vals[i];
            break;
           }
     }

   double probe = 0.0;
   if(by_override != "")
     {
      if(SymbolInfoDouble(by_override, SYMBOL_POINT, probe) && probe > 0.0)
        {
         s.name = by_override;
         s.resolve_method = "override";
         s.resolved = true;
         return true;
        }
      Warn(StringFormat("symbol '%s': override '%s' not found at broker", logical, by_override));
     }

   //--- 2. exact name ----------------------------------------------
   if(SymbolInfoDouble(logical, SYMBOL_POINT, probe) && probe > 0.0)
     {
      s.name = logical;
      s.resolve_method = "exact";
      s.resolved = true;
     }

   //--- 3. base + suffix -------------------------------------------
   if(!s.resolved && m_suffix != "" && m_resolution != SYMBOL_RESOLVE_EXACT)
     {
      string cand = logical + m_suffix;
      if(SymbolInfoDouble(cand, SYMBOL_POINT, probe) && probe > 0.0)
        {
         s.name = cand;
         s.resolve_method = "suffix";
         s.resolved = true;
        }
     }

   //--- 4. normalized / unique-prefix search -----------------------
   if(!s.resolved && (m_resolution == SYMBOL_RESOLVE_SEARCH || m_resolution == SYMBOL_RESOLVE_OVERRIDE))
     {
      if(ArraySize(m_broker_cache) == 0)
         BuildBrokerCache();
      string nk = NormalizeSymbolKey(logical);
      string best = "";
      int best_len = -1;
      bool ambiguous = false;
      for(int i = 0; i < ArraySize(m_broker_cache); i++)
        {
         string b = m_broker_cache[i];
         string bk = NormalizeSymbolKey(b);
         if(bk == "")
            continue;
         bool hit = false;
         if(bk == nk)
            hit = true;
         else if(StringFind(bk, nk, 0) == 0)
            hit = true;
         if(!hit)
            continue;
         int extra = StringLen(bk) - StringLen(nk);
         if(best_len < 0 || extra < best_len)
           {
            best = b;
            best_len = extra;
            ambiguous = false;
           }
         else if(extra == best_len && b != best)
            ambiguous = true;
        }
      if(best != "" && !ambiguous)
        {
         s.name = best;
         s.resolve_method = (StringLen(NormalizeSymbolKey(best)) == StringLen(nk)) ? "normalized" : "prefix";
         s.resolved = true;
        }
      else if(best != "" && ambiguous)
         Warn(StringFormat("symbol '%s': ambiguous broker matches at '%s' - add an override_map entry",
                           logical, best));
     }

   if(!s.resolved)
     {
      Warn(StringFormat("symbol '%s': no broker match (suffix='%s') - add an InpSymbolOverrides entry or run DiscoverDerivSymbols.mq5",
                        logical, m_suffix));
      return false;
     }

   //--- market watch selection -------------------------------------
   bool selected = (bool)SymbolInfoInteger(s.name, SYMBOL_SELECT);
   if(!selected && m_auto_select)
      selected = SymbolSelect(s.name, true);
   if(!selected)
     {
      Warn(StringFormat("symbol '%s' (%s) is not in Market Watch", logical, s.name));
      s.resolved = false;
      return false;
     }
   return true;
  }

bool CSymbolRegistry::ResolveAll(string &err)
  {
   int resolved = 0;
   for(int i = 0; i < m_count; i++)
     {
      if(!m_syms[i].enabled)
         continue;
      if(ResolveOne(m_syms[i]))
         resolved++;
     }
   if(resolved == 0)
     {
      err = "no configured symbol could be resolved to a broker symbol";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Read the live contract specification. All values come from the     |
//| terminal; any zero/negative essential value invalidates the spec.  |
//+------------------------------------------------------------------+
bool CSymbolRegistry::ReadLiveSpec(SymbolSpec &s)
  {
   s.live_valid = false;
   s.live_error = "";
   if(!s.resolved || s.name == "")
     {
      s.live_error = "unresolved";
      return false;
     }

   s.digits              = (int)SymbolInfoInteger(s.name, SYMBOL_DIGITS);
   s.point               = SymbolInfoDouble(s.name, SYMBOL_POINT);
   s.tick_size           = SymbolInfoDouble(s.name, SYMBOL_TRADE_TICK_SIZE);
   s.tick_value_profit   = SymbolInfoDouble(s.name, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   s.tick_value_loss     = SymbolInfoDouble(s.name, SYMBOL_TRADE_TICK_VALUE_LOSS);
   s.contract_size       = SymbolInfoDouble(s.name, SYMBOL_TRADE_CONTRACT_SIZE);
   s.vol_min             = SymbolInfoDouble(s.name, SYMBOL_VOLUME_MIN);
   s.vol_max             = SymbolInfoDouble(s.name, SYMBOL_VOLUME_MAX);
   s.vol_step            = SymbolInfoDouble(s.name, SYMBOL_VOLUME_STEP);
   s.stops_level         = (int)SymbolInfoInteger(s.name, SYMBOL_TRADE_STOPS_LEVEL);
   s.freeze_level        = (int)SymbolInfoInteger(s.name, SYMBOL_TRADE_FREEZE_LEVEL);
   s.trade_mode          = (int)SymbolInfoInteger(s.name, SYMBOL_TRADE_MODE);
   s.filling_mask        = (int)SymbolInfoInteger(s.name, SYMBOL_FILLING_MODE);
   s.margin_initial      = SymbolInfoDouble(s.name, SYMBOL_MARGIN_INITIAL);
   s.margin_maintenance  = SymbolInfoDouble(s.name, SYMBOL_MARGIN_MAINTENANCE);
   s.swap_long           = SymbolInfoDouble(s.name, SYMBOL_SWAP_LONG);
   s.swap_short          = SymbolInfoDouble(s.name, SYMBOL_SWAP_SHORT);
   s.currency_profit     = SymbolInfoString(s.name, SYMBOL_CURRENCY_PROFIT);
   s.currency_margin     = SymbolInfoString(s.name, SYMBOL_CURRENCY_MARGIN);

   //--- validate -----------------------------------------------
   if(s.point <= 0.0)
      s.live_error = "point is zero";
   else if(s.tick_size <= 0.0)
      s.live_error = "tick size is zero";
   else if(s.tick_value_loss <= 0.0 && s.tick_value_profit <= 0.0)
      s.live_error = "tick value is zero";
   else if(s.contract_size <= 0.0)
      s.live_error = "contract size is zero";
   else if(s.vol_step <= 0.0 || s.vol_min <= 0.0 || s.vol_max < s.vol_min)
      s.live_error = "invalid volume limits";
   else if(s.digits <= 0 || s.digits > 10)
      s.live_error = "invalid digits";

   //--- stamp the attempt even when it fails, so a broken symbol is
   //--- retried at the refresh interval instead of on every loop tick
   s.spec_refreshed = TimeTradeServer();
   if(s.live_error != "")
      return false;

   //--- spread --------------------------------------------------
   MqlTick tick;
   if(SymbolInfoTick(s.name, tick) && tick.ask > 0.0 && tick.bid > 0.0)
      s.spread_points = (tick.ask - tick.bid) / s.point;
   else
      s.spread_points = (double)SymbolInfoInteger(s.name, SYMBOL_SPREAD);
   if(!IsFinite(s.spread_points) || s.spread_points < 0.0)
      s.spread_points = 0.0;
   if(s.spread_points > 0.0 && s.spread_baseline <= 0.0)
      s.spread_baseline = s.spread_points;

   s.market_open = MarketOpen(s.name, TimeTradeServer());
   s.spec_refreshed = TimeTradeServer();
   s.live_valid = true;
   return true;
  }

//+------------------------------------------------------------------+
bool CSymbolRegistry::Refresh(const string name, string &err)
  {
   SymbolSpec *s = Find(name);
   if(s == NULL)
     {
      err = StringFormat("symbol '%s' not configured", name);
      return false;
     }
   if(!ReadLiveSpec(*s))
     {
      err = StringFormat("symbol '%s' invalid: %s", name, s.live_error);
      return false;
     }
   return true;
  }

bool CSymbolRegistry::RefreshIfStale(const string name, string &err)
  {
   SymbolSpec *s = Find(name);
   if(s == NULL)
     {
      err = StringFormat("symbol '%s' not configured", name);
      return false;
     }
   datetime now = TimeTradeServer();
   if(now - s.spec_refreshed < m_refresh_seconds)
     {
      if(s.live_valid)
         return true;
      err = StringFormat("symbol '%s': %s", name,
                         s.live_error != "" ? s.live_error : "contract specification unavailable");
      return false;
     }
   return Refresh(name, err);
  }

//+------------------------------------------------------------------+
//| Read the live contract spec for every resolved, enabled symbol.    |
//| Returns false only when no symbol produced a usable spec. An       |
//| individual failure is a warning and leaves live_valid=false so the |
//| evaluator rejects that symbol instead of trading on zero values.   |
//+------------------------------------------------------------------+
bool CSymbolRegistry::RefreshAll(string &err)
  {
   err = "";
   int ok = 0;
   for(int i = 0; i < m_count; i++)
     {
      if(!m_syms[i].enabled || !m_syms[i].resolved)
         continue;
      if(ReadLiveSpec(m_syms[i]))
        {
         ok++;
         continue;
        }
      Warn(StringFormat("symbol '%s' (%s): contract spec unusable: %s",
                        m_syms[i].config_name, m_syms[i].name, m_syms[i].live_error));
     }
   if(ok == 0)
     {
      err = "no configured symbol produced a usable contract specification";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Market/session status from the broker's own trade sessions.       |
//| Falls back to trade mode when a symbol publishes no session data. |
//+------------------------------------------------------------------+
bool CSymbolRegistry::MarketOpen(const string name, const datetime server_time)
  {
   int mode = (int)SymbolInfoInteger(name, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   if(mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return false;

   MqlDateTime dt;
   TimeToStruct(server_time, dt);
   int minute = dt.hour * 60 + dt.min;
   bool any_session = false;
   datetime from = 0, to = 0;
   for(uint idx = 0; idx < 64; idx++)
     {
      if(!SymbolInfoSessionTrade(name, (ENUM_DAY_OF_WEEK)dt.day_of_week, idx, from, to))
         break;
      any_session = true;
      int f = (int)from / 60;
      int t = (int)to / 60;
      if(t == 0)
         t = 1440;
      if(MinuteInWindow(minute, f, t))
         return true;
     }
   if(!any_session)
     {
      if(!m_warned_session_data)
        {
         m_warned_session_data = true;
         Warn(StringFormat("symbol '%s' publishes no trade sessions; relying on trade mode/tick freshness", name));
        }
      return true;
     }
   return false;
  }

double CSymbolRegistry::SpreadPoints(const string name)
  {
   SymbolSpec *s = Find(name);
   if(s == NULL)
      return 0.0;
   MqlTick tick;
   if(SymbolInfoTick(s.name, tick) && tick.ask > 0.0 && tick.bid > 0.0 && s.point > 0.0)
      return (tick.ask - tick.bid) / s.point;
   return s.spread_points;
  }

//+------------------------------------------------------------------+
//| Account-currency value of one full price unit for one lot.        |
//| Uses the loss-side tick value when available (conservative).      |
//| Returns 0 when the broker does not publish a usable value.        |
//+------------------------------------------------------------------+
double CSymbolRegistry::ValuePerPriceUnit(const string name)
  {
   SymbolSpec *s = Find(name);
   if(s == NULL || s.tick_size <= 0.0)
      return 0.0;
   double tv = (s.tick_value_loss > 0.0) ? s.tick_value_loss : s.tick_value_profit;
   if(tv <= 0.0)
      return 0.0;
   return tv / s.tick_size;
  }

double CSymbolRegistry::MaxRiskPct(const string name)
  {
   SymbolSpec *s = Find(name);
   return (s == NULL) ? 0.0 : s.max_risk_pct;
  }

int CSymbolRegistry::MaxSpreadPoints(const string name)
  {
   SymbolSpec *s = Find(name);
   return (s == NULL) ? 0 : s.max_spread_points;
  }

bool CSymbolRegistry::FillingMode(const string name, ENUM_ORDER_TYPE_FILLING &mode)
  {
   SymbolSpec *s = Find(name);
   mode = ORDER_FILLING_RETURN;
   if(s == NULL)
      return false;
   // Market orders: prefer FOK, then IOC. RETURN is not valid for DEAL.
   if((s.filling_mask & SYMBOL_FILLING_FOK) != 0)
     {
      mode = ORDER_FILLING_FOK;
      return true;
     }
   if((s.filling_mask & SYMBOL_FILLING_IOC) != 0)
     {
      mode = ORDER_FILLING_IOC;
      return true;
     }
   return false;
  }

bool CSymbolRegistry::StrategyEnabled(const string name, const ENUM_STRATEGY s)
  {
   SymbolSpec *sym = Find(name);
   if(sym == NULL)
      return false;
   if(s <= STRAT_NONE || s > STRAT_MEANREV)
      return false;
   return (sym.strategies_mask & (1 << s)) != 0;
  }

#endif
//+------------------------------------------------------------------+

