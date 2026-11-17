//+------------------------------------------------------------------+
//|                                                       Config.mqh |
//|         Deriv MT5 Financial multi-asset AI EA - configuration     |
//|                                                                  |
//|  This file owns every enum, struct and default used by the EA.    |
//|  It contains no I/O and no trading logic. Inputs are declared in  |
//|  the expert file and copied into EAConfig once, at OnInit().      |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_CONFIG_MQH__
#define __DERIV_AI_CONFIG_MQH__

#define EA_NAME              "DerivAIPortfolioEA"
#define EA_VERSION           "1.0.0"
#define STATE_SCHEMA_VERSION 1
#define META_SCHEMA_VERSION  1
#define AI_SCHEMA_VERSION    1

//--- strategy identifiers -------------------------------------------
enum ENUM_STRATEGY
  {
   STRAT_NONE     = 0,
   STRAT_TREND    = 1,
   STRAT_ORB      = 2,
   STRAT_SWEEP    = 3,
   STRAT_MEANREV  = 4
  };

//--- trade direction -------------------------------------------------
enum ENUM_TRADE_DIR
  {
   DIR_NONE  =  0,
   DIR_LONG  =  1,
   DIR_SHORT = -1
  };

//--- market regime ---------------------------------------------------
enum ENUM_REGIME
  {
   REGIME_UNKNOWN = 0,
   REGIME_TREND_UP,
   REGIME_TREND_DOWN,
   REGIME_RANGE,
   REGIME_EXPANSION,
   REGIME_CHOP
  };

//--- session state (from the specification) --------------------------
enum ENUM_SESSION_STATE
  {
   SESSION_CLOSED = 0,
   SESSION_ASIAN,
   SESSION_LONDON_PREOPEN,
   SESSION_LONDON_OPEN,
   SESSION_LONDON_CORE,
   SESSION_NY_PREOPEN,
   SESSION_NY_OPEN,
   SESSION_NY_CORE,
   SESSION_ROLLOVER
  };

//--- asset classes (config identifiers, never broker identifiers) ----
enum ENUM_ASSET_CLASS
  {
   ASSET_UNKNOWN = 0,
   ASSET_FX,
   ASSET_METAL,
   ASSET_INDEX
  };

//--- policy enums ----------------------------------------------------
enum ENUM_AI_FALLBACK
  {
   AI_FALLBACK_VETO   = 0,   // Reject the trade when AI is unavailable/invalid
   AI_FALLBACK_REDUCE = 1    // Allow with a reduced risk multiplier
  };

enum ENUM_NEWS_UNAVAILABLE
  {
   NEWS_UNAVAILABLE_BLOCK_ALL       = 0,  // No new entries at all
   NEWS_UNAVAILABLE_BLOCK_HIGH_RISK = 1,  // Only asset classes flagged high-risk
   NEWS_UNAVAILABLE_ALLOW           = 2   // Trade, but journal the gap
  };

enum ENUM_SYMBOL_RESOLUTION
  {
   SYMBOL_RESOLVE_EXACT       = 0,  // Exact match only
   SYMBOL_RESOLVE_SUFFIX      = 1,  // Exact, then base + configured suffix
   SYMBOL_RESOLVE_SEARCH      = 2,  // Exact, suffix, then normalized search
   SYMBOL_RESOLVE_OVERRIDE    = 3   // Override map first, then the above
  };

enum ENUM_ML_OUTPUT_KIND
  {
   ML_OUT_BINARY_TWO   = 0,   // [1,2] classifier probabilities: take index 1
   ML_OUT_BINARY_ONE   = 1,   // [1,1] probability of success
   ML_OUT_UP_DOWN_TWO  = 2,   // [1,2] regime/up-down class probabilities
   ML_OUT_REGIME_PROBS = 3    // [1,K] regime probabilities
  };

//--- machine-readable reason codes ----------------------------------
//    Every decision the EA makes ends with exactly one of these.
enum ENUM_REASON
  {
   RC_NONE = 0,
   RC_OK,
   RC_CONFIG_INVALID,
   RC_SYMBOL_UNRESOLVED,
   RC_SYMBOL_DISABLED,
   RC_SYMBOL_NOT_SELECTABLE,
   RC_SYMBOL_TRADE_DISABLED,
   RC_SYMBOL_CLOSE_ONLY,
   RC_SYMBOL_LONG_ONLY,
   RC_SYMBOL_SHORT_ONLY,
   RC_MARKET_CLOSED,
   RC_SESSION_CLOSED,
   RC_SESSION_ROLLOVER,
   RC_SESSION_BLOCKED,
   RC_SPREAD_TOO_WIDE,
   RC_NO_DATA,
   RC_STALE_DATA,
   RC_ATR_TOO_SMALL,
   RC_REGIME_NOT_ALLOWED,
   RC_NO_SETUP,
   RC_SCORE_LOW,
   RC_ML_LOW,
   RC_ML_UNAVAILABLE,
   RC_ML_INFERENCE_FAILED,
   RC_ML_DISABLED,
   RC_AI_VETO,
   RC_AI_LOW_CONFIDENCE,
   RC_AI_UNAVAILABLE,
   RC_AI_INVALID,
   RC_AI_DISABLED,
   RC_NEWS_BLOCKED,
   RC_NEWS_UNAVAILABLE,
   RC_DAILY_LOSS,
   RC_WEEKLY_LOSS,
   RC_DRAWDOWN,
   RC_HEAT_LIMIT,
   RC_CORR_LIMIT,
   RC_MAX_POSITIONS,
   RC_MAX_POS_SYMBOL,
   RC_MARGIN,
   RC_MIN_LOT,
   RC_STOPS_LEVEL,
   RC_INVALID_STOPS,
   RC_COOLDOWN,
   RC_DUPLICATE,
   RC_RISK_LIMIT_ZERO,
   RC_EXEC_REJECTED,
   RC_EXEC_RETRY_EXHAUSTED,
   RC_EXEC_NO_FILL,
   RC_PROTECTION_FAILED,
   RC_CONNECTIVITY,
   RC_PERMISSION,
   RC_KILL_SWITCH,
   RC_STATE_ERROR,
   RC_INTERNAL_ERROR,
   RC_COUNT
  };

string ReasonToString(const ENUM_REASON r)
  {
   switch(r)
     {
      case RC_NONE:                  return "NONE";
      case RC_OK:                    return "OK";
      case RC_CONFIG_INVALID:        return "CONFIG_INVALID";
      case RC_SYMBOL_UNRESOLVED:     return "SYMBOL_UNRESOLVED";
      case RC_SYMBOL_DISABLED:       return "SYMBOL_DISABLED";
      case RC_SYMBOL_NOT_SELECTABLE: return "SYMBOL_NOT_SELECTABLE";
      case RC_SYMBOL_TRADE_DISABLED: return "SYMBOL_TRADE_DISABLED";
      case RC_SYMBOL_CLOSE_ONLY:     return "SYMBOL_CLOSE_ONLY";
      case RC_SYMBOL_LONG_ONLY:      return "SYMBOL_LONG_ONLY";
      case RC_SYMBOL_SHORT_ONLY:     return "SYMBOL_SHORT_ONLY";
      case RC_MARKET_CLOSED:         return "MARKET_CLOSED";
      case RC_SESSION_CLOSED:        return "SESSION_CLOSED";
      case RC_SESSION_ROLLOVER:      return "SESSION_ROLLOVER";
      case RC_SESSION_BLOCKED:       return "SESSION_BLOCKED";
      case RC_SPREAD_TOO_WIDE:       return "SPREAD_TOO_WIDE";
      case RC_NO_DATA:               return "NO_DATA";
      case RC_STALE_DATA:            return "STALE_DATA";
      case RC_ATR_TOO_SMALL:         return "ATR_TOO_SMALL";
      case RC_REGIME_NOT_ALLOWED:    return "REGIME_NOT_ALLOWED";
      case RC_NO_SETUP:              return "NO_SETUP";
      case RC_SCORE_LOW:             return "SCORE_LOW";
      case RC_ML_LOW:                return "ML_LOW";
      case RC_ML_UNAVAILABLE:        return "ML_UNAVAILABLE";
      case RC_ML_INFERENCE_FAILED:   return "ML_INFERENCE_FAILED";
      case RC_ML_DISABLED:           return "ML_DISABLED";
      case RC_AI_VETO:               return "AI_VETO";
      case RC_AI_LOW_CONFIDENCE:     return "AI_LOW_CONFIDENCE";
      case RC_AI_UNAVAILABLE:        return "AI_UNAVAILABLE";
      case RC_AI_INVALID:            return "AI_INVALID";
      case RC_AI_DISABLED:           return "AI_DISABLED";
      case RC_NEWS_BLOCKED:          return "NEWS_BLOCKED";
      case RC_NEWS_UNAVAILABLE:      return "NEWS_UNAVAILABLE";
      case RC_DAILY_LOSS:            return "DAILY_LOSS";
      case RC_WEEKLY_LOSS:           return "WEEKLY_LOSS";
      case RC_DRAWDOWN:              return "DRAWDOWN";
      case RC_HEAT_LIMIT:            return "HEAT_LIMIT";
      case RC_CORR_LIMIT:            return "CORR_LIMIT";
      case RC_MAX_POSITIONS:         return "MAX_POSITIONS";
      case RC_MAX_POS_SYMBOL:        return "MAX_POS_SYMBOL";
      case RC_MARGIN:                return "MARGIN";
      case RC_MIN_LOT:               return "MIN_LOT";
      case RC_STOPS_LEVEL:           return "STOPS_LEVEL";
      case RC_INVALID_STOPS:         return "INVALID_STOPS";
      case RC_COOLDOWN:              return "COOLDOWN";
      case RC_DUPLICATE:             return "DUPLICATE";
      case RC_RISK_LIMIT_ZERO:       return "RISK_LIMIT_ZERO";
      case RC_EXEC_REJECTED:         return "EXEC_REJECTED";
      case RC_EXEC_RETRY_EXHAUSTED:  return "EXEC_RETRY_EXHAUSTED";
      case RC_EXEC_NO_FILL:          return "EXEC_NO_FILL";
      case RC_PROTECTION_FAILED:     return "PROTECTION_FAILED";
      case RC_CONNECTIVITY:          return "CONNECTIVITY";
      case RC_PERMISSION:            return "PERMISSION";
      case RC_KILL_SWITCH:           return "KILL_SWITCH";
      case RC_STATE_ERROR:           return "STATE_ERROR";
      case RC_INTERNAL_ERROR:        return "INTERNAL_ERROR";
      default:                       return "UNKNOWN";
     }
  }

string StrategyToString(const ENUM_STRATEGY s)
  {
   switch(s)
     {
      case STRAT_TREND:   return "trend_continuation";
      case STRAT_ORB:     return "opening_range_breakout";
      case STRAT_SWEEP:   return "liquidity_sweep_reversal";
      case STRAT_MEANREV: return "mean_reversion";
      default:            return "none";
     }
  }

string SessionStateToString(const ENUM_SESSION_STATE s)
  {
   switch(s)
     {
      case SESSION_ASIAN:            return "asian";
      case SESSION_LONDON_PREOPEN:   return "london_preopen";
      case SESSION_LONDON_OPEN:      return "london_open";
      case SESSION_LONDON_CORE:      return "london_core";
      case SESSION_NY_PREOPEN:       return "ny_preopen";
      case SESSION_NY_OPEN:          return "ny_open";
      case SESSION_NY_CORE:          return "ny_core";
      case SESSION_ROLLOVER:         return "rollover";
      default:                       return "closed";
     }
  }

string RegimeToString(const ENUM_REGIME r)
  {
   switch(r)
     {
      case REGIME_TREND_UP:   return "trend_up";
      case REGIME_TREND_DOWN: return "trend_down";
      case REGIME_RANGE:      return "range";
      case REGIME_EXPANSION:  return "expansion";
      case REGIME_CHOP:       return "chop";
      default:                return "unknown";
     }
  }
//+------------------------------------------------------------------+
//| Configuration blocks. Every numeric member is a configurable      |
//| default; nothing here is treated as a universal constant.         |
//+------------------------------------------------------------------+
struct SymbolsConfig
  {
   string                  csv_file;          // MQL5/Files relative name
   bool                    common_folder;     // read from Common\Files
   string                  suffix;            // broker suffix, "" if none
   ENUM_SYMBOL_RESOLUTION  resolution;
   string                  override_map;      // "LOGICAL=BROKER;..."
   bool                    auto_select;       // SymbolSelect() in Market Watch
   int                     refresh_seconds;   // live spec cache lifetime
   int                     max_tick_age_seconds;
  };

struct SessionConfig
  {
   int                     utc_offset_override;   // hours; 99 = auto-detect
   int                     asian_start_hour;
   int                     asian_start_min;
   int                     asian_end_hour;
   int                     asian_end_min;
   int                     london_open_hour;
   int                     london_open_min;
   int                     ny_open_hour;
   int                     ny_open_min;
   int                     rollover_start_hour;
   int                     rollover_start_min;
   int                     rollover_end_hour;
   int                     rollover_end_min;
   int                     opening_range_minutes;
   int                     preopen_minutes;
   bool                    enable_asian;
   bool                    enable_london;
   bool                    enable_ny;
   double                  risk_scale_asian;
   double                  risk_scale_open;
   double                  risk_scale_core;
   double                  risk_scale_preopen;
  };

struct SignalConfig
  {
   ENUM_TIMEFRAMES         exec_tf;
   ENUM_TIMEFRAMES         htf_tf;
   ENUM_TIMEFRAMES         range_tf;
   double                  min_technical_score;
   bool                    enable_trend;
   bool                    enable_orb;
   bool                    enable_sweep;
   bool                    enable_meanrev;
   bool                    require_htf_alignment_trend;
   double                  atr_percentile_min_trend;
   double                  atr_percentile_min_orb;
   double                  atr_percentile_min_sweep;
   double                  atr_percentile_min_meanrev;
   double                  atr_percentile_max_meanrev;
   int                     adx_trend_min;
   int                     adx_range_max;
   double                  atr_stop_mult_trend;
   double                  atr_stop_mult_orb;
   double                  atr_stop_mult_sweep;
   double                  atr_stop_mult_meanrev;
   double                  rr_target1_trend;
   double                  rr_target2_trend;
   double                  rr_target1_orb;
   double                  rr_target2_orb;
   double                  rr_target1_sweep;
   double                  rr_target2_sweep;
   double                  rr_target1_meanrev;
   double                  rr_target2_meanrev;
   double                  orb_buffer_atr;
   double                  orb_max_range_atr;
   double                  orb_min_range_atr;
   double                  sweep_buffer_atr;
   double                  sweep_min_wick_atr;
   double                  meanrev_stop_atr;
   int                     swing_lookback;
   int                     cooldown_minutes;
   double                  risk_scale_sweep;
   double                  risk_scale_meanrev;
   double                  score_weight_trend;
   double                  score_weight_momentum;
   double                  score_weight_volatility;
   double                  score_weight_location;
   double                  score_weight_structure;
   double                  medium_news_threshold_add;
   int                     min_bars_required;
   int                     ema_fast;
   int                     ema_mid;
   int                     ema_slow;
   int                     rsi_period;
   int                     macd_fast;
   int                     macd_slow;
   int                     macd_signal;
   int                     bb_period;
   double                  bb_deviation;
   int                     adx_period;
   int                     atr_period;
   int                     atr_percentile_lookback;
   int                     volume_lookback;
   int                     swing_fractal;
   int                     orb_entry_window_minutes;
   int                     sweep_max_adx;
  };

//+------------------------------------------------------------------+
//| Risk configuration.                                               |
//+------------------------------------------------------------------+
struct RiskConfig
  {
   double                  risk_per_trade_pct;
   double                  max_portfolio_heat_pct;
   double                  max_daily_loss_pct;
   double                  max_weekly_loss_pct;
   double                  max_drawdown_pct;
   double                  max_correlated_exposure_pct;
   double                  correlation_threshold;
   int                     correlation_lookback_bars;
   int                     max_open_positions;
   int                     max_positions_per_symbol;
   int                     max_positions_per_correlation_group;
   double                  max_margin_usage_pct;
   double                  min_free_margin_pct;
   double                  lot_risk_tolerance;
   int                     max_consecutive_losses;
   int                     day_roll_hour_utc;
   bool                    reset_halts_on_init;
   bool                    close_on_drawdown_halt;
   double                  max_avg_slippage_stop_ratio;
   int                     max_rejections_per_day;
   int                     min_trades_for_slippage_halt;
   bool                    correlation_enabled;
  };

struct MlConfig
  {
   bool                    enabled;
   string                  metadata_file;
   string                  model_dir;
   bool                    fail_on_load_error;
   bool                    require_hash;
   bool                    allow_without_model;
   double                  default_threshold;
   int                     max_consecutive_failures;
   bool                    use_ensemble_meta;
   bool                    log_inference;
  };

struct AiConfig
  {
   bool                    enabled;
   string                  policy_file;
   int                     max_calls_per_hour;
   int                     cache_seconds;
   int                     timeout_ms;
   ENUM_AI_FALLBACK        fallback_mode;
   double                  fallback_reduce_factor;
   int                     min_confidence;
   double                  max_risk_multiplier;
   int                     max_consecutive_failures;
   int                     breaker_seconds;
   bool                    require_https;
   int                     max_response_bytes;
  };

struct NewsConfig
  {
   bool                    enabled;
   string                  csv_file;
   bool                    common_folder;
   bool                    use_live_calendar;
   int                     refresh_minutes;
   int                     high_impact_block_before_min;
   int                     high_impact_block_after_min;
   int                     medium_impact_window_min;
   double                  medium_impact_risk_mult;
   ENUM_NEWS_UNAVAILABLE   unavailable_policy;
   int                     horizon_hours;
   bool                    global_blackout_halts_all;
   int                     calendar_time_basis;   // 0 = server time, 1 = UTC
  };

struct ExecConfig
  {
   int                     magic;
   bool                    allow_long;
   bool                    allow_short;
   double                  max_spread_multiplier;
   int                     spread_buffer_points;
   int                     deviation_fx_points;
   int                     deviation_metal_points;
   int                     deviation_index_points;
   int                     max_retries;
   int                     retry_pause_ms;
   bool                    verify_protection;
   bool                    close_if_protection_fails;
   bool                    use_pending_breakout;
   bool                    breakeven_enabled;
   double                  breakeven_at_r;
   double                  breakeven_buffer_atr;
   bool                    trail_enabled;
   double                  trail_start_r;
   double                  trail_atr_mult;
   double                  trail_min_step_atr;
   bool                    partial_enabled;
   double                  partial_at_r;
   double                  partial_pct;
   bool                    time_exit_enabled;
   int                     max_hold_minutes;
   double                  time_exit_min_r;
   bool                    exit_on_invalidation;
   int                     modify_retries;
   bool                    dry_run;
   bool                    enable_trading;
  };

struct JournalConfig
  {
   bool                    enabled;
   string                  dir;
   bool                    common_folder;
   int                     verbosity;         // 0 errors, 1 decisions, 2 verbose
   bool                    log_rejections;
   bool                    track_mae_mfe;
   bool                    daily_summary;
   int                     max_mb;
  };

struct RuntimeConfig
  {
   int                     timer_seconds;
   int                     max_loop_ms;
  };

struct EAConfig
  {
   SymbolsConfig           symbols;
   SessionConfig           session;
   SignalConfig            signal;
   RiskConfig              risk;
   MlConfig                ml;
   AiConfig                ai;
   NewsConfig              news;
   ExecConfig              exec;
   JournalConfig           journal;
   RuntimeConfig           runtime;
  };

//+------------------------------------------------------------------+
//| Candidate signal contract (spec 3.3) plus audit fields.           |
//+------------------------------------------------------------------+
struct TradeCandidate
  {
   string          symbol;
   int             direction;
   ENUM_STRATEGY   strategy;
   string          strategy_name;
   double          entry;
   double          stop;
   double          target1;
   double          target2;
   double          atr;
   double          technical_score;
   double          ml_probability;
   double          ai_risk_multiplier;
   string          regime;
   string          session;
   bool            news_blocked;
   bool            correlation_blocked;
   bool            approved;
   ENUM_REASON     reason;
   string          reason_text;
   double          risk_pct;
   double          lot;
   double          spread_points;
   datetime        bar_time;
   int             minutes_to_event;
   int             event_impact;
   double          ml_threshold_add;
   double          sc_trend;
   double          sc_momentum;
   double          sc_volatility;
   double          sc_location;
   double          sc_structure;
   double          initial_risk_price;
   double          orb_high;
   double          orb_low;
   double          swept_level;
   int             minutes_since_open;
   double          session_risk_scale;
   double          strategy_risk_scale;
   string          setup_id;
   string          notes;
  };

//+------------------------------------------------------------------+
//| Portfolio snapshot sent to the external AI assistant.             |
//| Contains no account identifiers, balances or credentials.          |
//+------------------------------------------------------------------+
struct PortfolioSnapshot
  {
   int             open_positions;
   double          portfolio_risk_pct;
   double          daily_loss_pct;
   double          weekly_loss_pct;
   double          drawdown_pct;
   string          positions_json;   // [{"symbol","direction","risk_pct"}...]
  };

//+------------------------------------------------------------------+
//| External AI decision. It can only veto or reduce risk.            |
//+------------------------------------------------------------------+
struct AiDecision
  {
   bool            allowed;
   double          risk_multiplier;
   int             confidence;
   string          regime;
   string          reason;
   string          invalidation;
   bool            used_fallback;
   bool            available;
   ENUM_REASON     reason_code;
  };

#endif
//+------------------------------------------------------------------+

