//+------------------------------------------------------------------+
//|                                      DerivAIPortfolioEA.mq5       |
//|                                                                    |
//|  Multi-asset Deriv MT5 Financial EA.                               |
//|                                                                    |
//|  Decision pipeline (per symbol, on each closed execution bar):     |
//|    contract spec -> market/session -> spread -> indicators ->      |
//|    calendar -> technical setup -> ONNX score -> external AI        |
//|    advice (veto/reduce only) -> risk engine -> execution           |
//|                                                                    |
//|  The risk engine is the final gate. The external AI can only       |
//|  reduce or veto; it can never raise risk above configured limits.  |
//|                                                                    |
//|  Every decision ends with exactly one machine-readable reason and  |
//|  is journaled before the next one starts.                          |
//+------------------------------------------------------------------+
#property copyright "DerivAIPortfolioEA"
#property link      ""
#property version   "1.00"
#property description "Multi-asset Deriv MT5 Financial EA with ONNX scoring, external AI advisory and a hard risk gate."
#property description "Requires MQL5/Files/deriv_symbols.csv. Read docs/setup.md before running."
#property strict

#include <Config.mqh>
#include <Utils.mqh>
#include <Json.mqh>
#include <SymbolSpec.mqh>
#include <Sessions.mqh>
#include <Indicators.mqh>
#include <NewsCalendar.mqh>
#include <SignalEngine.mqh>
#include <OnnxModel.mqh>
#include <AiAssistant.mqh>
#include <State.mqh>
#include <RiskEngine.mqh>
#include <Journal.mqh>
#include <Execution.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== Symbols ==="
input string   InpSymbolCsv            = "deriv_symbols.csv";   // Symbol CSV (MQL5/Files)
input bool     InpSymbolsCommonFolder  = false;                 // Read CSV from Common\Files
input string   InpSymbolSuffix         = "";                    // Broker suffix (e.g. ".deriv")
input ENUM_SYMBOL_RESOLUTION InpSymbolResolution = SYMBOL_RESOLVE_OVERRIDE; // Resolution mode
input string   InpSymbolOverrides      = "";                    // LOGICAL=BROKER overrides, ';' separated
input bool     InpAutoSelectSymbols    = true;                  // Add resolved symbols to Market Watch
input int      InpSpecRefreshSeconds   = 60;                    // Live spec cache seconds
input int      InpMaxTickAgeSeconds    = 120;                   // Reject stale ticks older than this

input group "=== Sessions (UTC) ==="
input int      InpUtcOffsetOverride    = 99;                    // Server-UTC offset hours (99 = auto)
input int      InpAsianStartHour       = 0;                     // Asian start hour UTC
input int      InpAsianStartMin        = 0;                     // Asian start minute
input int      InpAsianEndHour         = 8;                     // Asian end hour UTC
input int      InpAsianEndMin          = 0;                     // Asian end minute
input int      InpLondonOpenHour       = 7;                     // London open hour UTC
input int      InpLondonOpenMin        = 0;                     // London open minute
input int      InpNyOpenHour           = 13;                     // New York open hour UTC
input int      InpNyOpenMin            = 30;                    // New York open minute
input int      InpRolloverStartHour    = 20;                    // Rollover start hour UTC
input int      InpRolloverStartMin     = 45;                    // Rollover start minute
input int      InpRolloverEndHour      = 21;                    // Rollover end hour UTC
input int      InpRolloverEndMin       = 15;                    // Rollover end minute
input int      InpOpeningRangeMinutes  = 30;                    // Opening range minutes
input int      InpPreopenMinutes       = 15;                    // Pre-open block minutes
input bool     InpEnableAsian          = true;                  // Enable Asian session
input bool     InpEnableLondon         = true;                  // Enable London session
input bool     InpEnableNy             = true;                  // Enable New York session
input double   InpRiskScaleAsian       = 0.50;                  // Asian risk scale
input double   InpRiskScaleOpen        = 1.00;                  // Session open risk scale
input double   InpRiskScaleCore        = 0.90;                  // Session core risk scale
input double   InpRiskScalePreopen     = 0.50;                  // Pre-open risk scale

input group "=== Signals ==="
input ENUM_TIMEFRAMES InpExecTf        = PERIOD_M15;            // Execution timeframe
input ENUM_TIMEFRAMES InpHtfTf         = PERIOD_H1;             // Higher timeframe
input ENUM_TIMEFRAMES InpRangeTf       = PERIOD_M5;             // Range/VWAP timeframe
input double   InpMinTechnicalScore    = 65.0;                  // Minimum technical score (0-100)
input bool     InpEnableTrend          = true;                  // Enable trend continuation
input bool     InpEnableOrb            = true;                  // Enable opening range breakout
input bool     InpEnableSweep          = true;                  // Enable liquidity sweep reversal
input bool     InpEnableMeanRev        = true;                  // Enable mean reversion
input bool     InpRequireHtfAlignTrend = true;                  // Trend needs HTF alignment
input double   InpAtrPctMinTrend       = 0.25;                  // Trend min ATR percentile
input double   InpAtrPctMinOrb         = 0.35;                  // ORB min ATR percentile
input double   InpAtrPctMinSweep       = 0.30;                  // Sweep min ATR percentile
input double   InpAtrPctMinMeanRev     = 0.00;                  // Mean-reversion min ATR percentile
input double   InpAtrPctMaxMeanRev     = 0.80;                  // Mean-reversion max ATR percentile
input int      InpAdxTrendMin          = 22;                    // Trend minimum ADX
input int      InpAdxRangeMax          = 20;                    // Mean-reversion maximum ADX
input double   InpAtrStopTrend         = 1.50;                  // Trend stop ATR multiple
input double   InpAtrStopOrb           = 1.20;                  // ORB stop ATR multiple
input double   InpAtrStopSweep         = 1.00;                  // Sweep stop ATR multiple
input double   InpAtrStopMeanRev       = 1.20;                  // Mean-reversion stop ATR multiple
input double   InpRrT1Trend            = 1.50;                  // Trend target 1 R
input double   InpRrT2Trend            = 2.50;                  // Trend target 2 R
input double   InpRrT1Orb              = 1.50;                  // ORB target 1 R
input double   InpRrT2Orb              = 2.00;                  // ORB target 2 R
input double   InpRrT1Sweep            = 1.20;                  // Sweep target 1 R
input double   InpRrT2Sweep            = 2.00;                  // Sweep target 2 R
input double   InpRrT1MeanRev          = 1.00;                  // Mean-rev fallback target 1 (R)
input double   InpRrT2MeanRev          = 1.50;                  // Mean-rev fallback target 2 (R)
input double   InpOrbBufferAtr         = 0.15;                  // ORB breakout buffer (ATR)
input double   InpOrbMinRangeAtr       = 0.50;                  // ORB minimum range (ATR)
input double   InpOrbMaxRangeAtr       = 3.00;                  // ORB maximum range (ATR)
input double   InpSweepBufferAtr       = 0.10;                  // Sweep entry buffer (ATR)
input double   InpSweepMinWickAtr      = 0.50;                  // Sweep minimum wick (ATR)
input int      InpSwingLookback        = 20;                    // Swing lookback bars
input int      InpCooldownMinutes      = 30;                    // Per-strategy cooldown
input double   InpRiskScaleSweep       = 0.75;                  // Sweep risk scale
input double   InpRiskScaleMeanRev     = 0.75;                  // Mean-reversion risk scale
input double   InpScoreWeightTrend     = 0.30;                  // Score weight: trend
input double   InpScoreWeightMomentum  = 0.20;                  // Score weight: momentum
input double   InpScoreWeightVolatil   = 0.15;                  // Score weight: volatility
input double   InpScoreWeightLocation  = 0.20;                  // Score weight: location
input double   InpScoreWeightStructure = 0.15;                  // Score weight: structure
input double   InpMediumNewsScoreAdd   = 0.03;                  // Extra ML threshold near medium news
input int      InpMinBarsRequired      = 200;                   // Minimum bars for signals
input int      InpEmaFast              = 21;                    // EMA fast
input int      InpEmaMid               = 50;                    // EMA mid
input int      InpEmaSlow              = 200;                   // EMA slow
input int      InpRsiPeriod            = 14;                    // RSI period
input int      InpMacdFast             = 12;                    // MACD fast
input int      InpMacdSlow             = 26;                    // MACD slow
input int      InpMacdSignal           = 9;                     // MACD signal
input int      InpBbPeriod             = 20;                    // Bollinger period
input double   InpBbDeviation          = 2.0;                   // Bollinger deviation
input int      InpAdxPeriod            = 14;                    // ADX period
input int      InpAtrPeriod            = 14;                    // ATR period (also model feature)
input int      InpAtrPercentileLookback= 200;                   // ATR percentile lookback
input int      InpVolumeLookback       = 20;                    // Volume ratio lookback
input int      InpSwingFractal         = 2;                     // Swing fractal strength
input int      InpOrbEntryWindowMin    = 90;                     // ORB entry window (minutes)
input int      InpSweepMaxAdx          = 28;                    // Sweep maximum ADX

input group "=== Risk ==="
input double   InpRiskPerTradePct      = 0.35;                  // Risk per trade (% equity)
input double   InpMaxPortfolioHeatPct  = 1.50;                  // Maximum portfolio heat (%)
input double   InpMaxDailyLossPct      = 1.25;                  // Daily loss cutoff (%)
input double   InpMaxWeeklyLossPct     = 3.50;                  // Weekly loss cutoff (%)
input double   InpMaxDrawdownPct       = 9.00;                  // Drawdown halt (%)
input double   InpMaxCorrExposurePct   = 1.25;                  // Max correlated exposure (%)
input double   InpCorrelationThreshold = 0.70;                  // |Pearson| considered correlated
input int      InpCorrelationLookback  = 120;                   // Correlation lookback bars
input int      InpMaxOpenPositions     = 4;                     // Max concurrent positions
input int      InpMaxPosPerSymbol      = 2;                     // Max positions per symbol
input int      InpMaxPosPerGroup       = 2;                     // Max positions per correlation group
input double   InpMaxMarginUsagePct    = 50.0;                  // Max margin usage (%)
input double   InpMinFreeMarginPct     = 30.0;                  // Min free margin after entry (%)
input double   InpLotRiskTolerance     = 1.25;                  // Allowed min-lot risk overshoot
input int      InpMaxConsecutiveLosses = 5;                     // Loss-streak kill switch
input int      InpDayRollHourUtc       = 0;                     // Day anchor hour UTC
input bool     InpResetHaltsOnInit     = false;                 // Clear latched halts at startup
input bool     InpCloseOnDrawdownHalt  = true;                  // Close positions on drawdown halt
input double   InpMaxAvgSlipRatio      = 0.35;                  // Max average slippage (R)
input int      InpMaxRejectionsPerDay  = 3;                     // Max broker rejections per day
input int      InpMinTradesForSlipHalt = 10;                    // Trades before slippage halt applies
input bool     InpCorrelationEnabled   = true;                  // Enable correlation limits

input group "=== Machine learning (ONNX) ==="
input bool     InpMlEnabled            = true;                  // Enable ONNX scoring
input string   InpMlMetadataFile       = "model_metadata.json"; // Model metadata file
input string   InpMlModelDir           = "";                    // Extra model dir (optional)
input bool     InpMlFailOnLoadError    = false;                 // Fail init if models do not load
input bool     InpMlRequireHash        = true;                  // Require SHA-256 in metadata
input bool     InpMlAllowWithoutModel  = false;                 // Allow entries without a model
input double   InpMlDefaultThreshold   = 0.62;                  // Fallback probability threshold
input int      InpMlMaxFailures        = 5;                     // Inference failure circuit breaker
input bool     InpMlUseEnsembleMeta    = false;                 // Use ensemble_meta.onnx (reserved)
input bool     InpMlLogInference       = false;                 // Log every inference

input group "=== External AI advisory ==="
input bool     InpAiEnabled            = false;                 // Enable external AI advisor
input string   InpAiPolicyFile         = "ai_policy.json";      // AI policy file (holds endpoint/auth)
input int      InpAiMaxCallsPerHour    = 20;                    // Hourly call limit
input int      InpAiCacheSeconds       = 300;                   // Decision cache lifetime
input int      InpAiTimeoutMs          = 3000;                  // HTTP timeout (ms)
input ENUM_AI_FALLBACK InpAiFallback   = AI_FALLBACK_VETO;      // Behaviour when AI is unavailable
input double   InpAiFallbackReduce     = 0.50;                  // Risk factor for AI_FALLBACK_REDUCE
input int      InpAiMinConfidence      = 55;                    // Minimum AI confidence
input double   InpAiMaxRiskMultiplier  = 1.00;                  // Hard AI multiplier ceiling (<=1)
input int      InpAiMaxFailures        = 3;                     // AI failure circuit breaker
input int      InpAiBreakerSeconds     = 900;                   // Circuit breaker duration
input bool     InpAiRequireHttps       = true;                  // Require https
input int      InpAiMaxResponseBytes   = 65536;                 // Maximum response size

input group "=== News calendar ==="
input bool     InpNewsEnabled          = true;                  // Enable news protection
input string   InpNewsCsv              = "calendar_history.csv";// Calendar CSV fallback
input bool     InpNewsCommonFolder     = false;                 // Read CSV from Common\Files
input bool     InpNewsUseLiveCalendar  = true;                  // Use terminal economic calendar
input int      InpNewsRefreshMinutes   = 15;                    // Calendar refresh minutes
input int      InpNewsHighBlockBefore  = 30;                    // High-impact block before (min)
input int      InpNewsHighBlockAfter   = 15;                    // High-impact block after (min)
input int      InpNewsMediumWindowMin  = 120;                   // Medium-impact context window (min)
input double   InpNewsMediumRiskMult   = 0.75;                  // Medium-impact risk multiplier
input ENUM_NEWS_UNAVAILABLE InpNewsUnavailable = NEWS_UNAVAILABLE_BLOCK_ALL; // No-calendar policy
input int      InpNewsHorizonHours     = 24;                    // Calendar look-ahead (hours)
input bool     InpNewsGlobalBlackout   = true;                  // Blackout blocks all symbols
input int      InpCalendarTimeBasis    = 0;                     // 0 = server time, 1 = UTC

input group "=== Execution ==="
input int      InpMagic                = 20261116;              // Magic number
input bool     InpAllowLong            = true;                  // Allow long entries
input bool     InpAllowShort           = true;                  // Allow short entries
input double   InpMaxSpreadMultiplier  = 2.00;                  // Spread cap multiplier (no CSV cap)
input int      InpSpreadBufferPoints   = 5;                     // Extra stop buffer (points)
input int      InpDeviationFx          = 20;                    // FX deviation (points)
input int      InpDeviationMetal       = 50;                    // Metal deviation (points)
input int      InpDeviationIndex       = 100;                   // Index deviation (points)
input int      InpMaxRetries           = 3;                     // Retryable order attempts
input int      InpRetryPauseMs         = 500;                   // Pause between retries (ms)
input bool     InpVerifyProtection     = true;                  // Verify SL/TP after fill
input bool     InpCloseIfNoProtection  = true;                  // Close a fill without protection
input bool     InpUsePendingBreakout   = false;                 // Use pending breakout orders (reserved)
input bool     InpBreakevenEnabled     = true;                  // Move stop to breakeven
input double   InpBreakevenAtR         = 1.00;                  // Breakeven trigger (R)
input double   InpBreakevenBufferAtr   = 0.05;                  // Breakeven buffer (ATR)
input bool     InpTrailEnabled         = true;                  // Enable trailing stop
input double   InpTrailStartR          = 1.50;                  // Trailing start (R)
input double   InpTrailAtrMult         = 1.00;                  // Trailing distance (ATR)
input double   InpTrailMinStepAtr      = 0.20;                  // Minimum trailing step (ATR)
input bool     InpPartialEnabled       = false;                 // Enable partial take-profit
input double   InpPartialAtR           = 1.50;                  // Partial trigger (R)
input double   InpPartialPct           = 0.33;                  // Partial close fraction
input bool     InpTimeExitEnabled      = true;                  // Enable time-based exit
input int      InpMaxHoldMinutes       = 240;                   // Maximum hold time (min)
input double   InpTimeExitMinR         = 0.30;                  // Close at time exit below this R
input bool     InpExitOnInvalidation   = true;                  // Close outside the symbol session
input int      InpModifyRetries        = 2;                     // SL/TP modify attempts
input bool     InpDryRun               = false;                 // Dry run: log, never send
input bool     InpEnableTrading        = true;                  // Master execution switch

input group "=== Journal ==="
input bool     InpJournalEnabled       = true;                  // Enable CSV journals
input string   InpJournalDir           = "DerivAIPortfolioEA";  // Journal directory
input bool     InpJournalCommonFolder  = false;                 // Write journals to Common\Files
input int      InpJournalVerbosity     = 2;                     // 0 errors, 1 decisions, 2 verbose
input bool     InpJournalRejections    = true;                  // Journal rejections
input bool     InpJournalMaeMfe        = true;                  // Journal MAE/MFE
input bool     InpJournalDailySummary  = true;                  // Write daily summary
input int      InpJournalMaxMb         = 32;                    // Rotate a journal above this size

input group "=== Runtime ==="
input int      InpTimerSeconds         = 5;                     // Timer period (seconds)
input int      InpMaxLoopMs            = 3000;                  // Per-loop CPU budget (ms)
input bool     InpFailOnModelLoad      = false;                 // Fail init if ML is unusable
input bool     InpPrintBanner          = true;                  // Print startup banner

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
EAConfig          g_cfg;
CSymbolRegistry   g_reg;
CSessionEngine    g_sess;
CIndicatorHub     g_hub;
CNewsCalendar     g_news;
CSignalEngine     g_sig;
COnnxModelStore   g_ml;
CAiAssistant      g_ai;
CRiskEngine       g_risk;
CJournal          g_journal;
CStateStore       g_state;
CExecution        g_exec;

bool              g_init_ok           = false;
string            g_ops_dir           = "DerivAIPortfolioEA";
string            g_state_file        = "DerivAIPortfolioEA/state.json";
datetime          g_last_save         = 0;
bool              g_dd_close_done     = false;
datetime          g_last_day_summary  = 0;

string            g_bar_symbol[];
datetime          g_bar_time[];

//+------------------------------------------------------------------+
//| Build the configuration object exactly once from the inputs.       |
//+------------------------------------------------------------------+
void BuildConfig(void)
  {
   g_cfg.symbols.csv_file          = InpSymbolCsv;
   g_cfg.symbols.common_folder     = InpSymbolsCommonFolder;
   g_cfg.symbols.suffix            = InpSymbolSuffix;
   g_cfg.symbols.resolution        = InpSymbolResolution;
   g_cfg.symbols.override_map      = InpSymbolOverrides;
   g_cfg.symbols.auto_select       = InpAutoSelectSymbols;
   g_cfg.symbols.refresh_seconds   = InpSpecRefreshSeconds;
   g_cfg.symbols.max_tick_age_seconds = InpMaxTickAgeSeconds;

   g_cfg.session.utc_offset_override = InpUtcOffsetOverride;
   g_cfg.session.asian_start_hour    = InpAsianStartHour;
   g_cfg.session.asian_start_min     = InpAsianStartMin;
   g_cfg.session.asian_end_hour      = InpAsianEndHour;
   g_cfg.session.asian_end_min       = InpAsianEndMin;
   g_cfg.session.london_open_hour    = InpLondonOpenHour;
   g_cfg.session.london_open_min     = InpLondonOpenMin;
   g_cfg.session.ny_open_hour        = InpNyOpenHour;
   g_cfg.session.ny_open_min         = InpNyOpenMin;
   g_cfg.session.rollover_start_hour = InpRolloverStartHour;
   g_cfg.session.rollover_start_min  = InpRolloverStartMin;
   g_cfg.session.rollover_end_hour   = InpRolloverEndHour;
   g_cfg.session.rollover_end_min    = InpRolloverEndMin;
   g_cfg.session.opening_range_minutes = InpOpeningRangeMinutes;
   g_cfg.session.preopen_minutes     = InpPreopenMinutes;
   g_cfg.session.enable_asian       = InpEnableAsian;
   g_cfg.session.enable_london      = InpEnableLondon;
   g_cfg.session.enable_ny          = InpEnableNy;
   g_cfg.session.risk_scale_asian   = InpRiskScaleAsian;
   g_cfg.session.risk_scale_open    = InpRiskScaleOpen;
   g_cfg.session.risk_scale_core    = InpRiskScaleCore;
   g_cfg.session.risk_scale_preopen = InpRiskScalePreopen;

   g_cfg.signal.exec_tf             = InpExecTf;
   g_cfg.signal.htf_tf              = InpHtfTf;
   g_cfg.signal.range_tf            = InpRangeTf;
   g_cfg.signal.min_technical_score = InpMinTechnicalScore;
   g_cfg.signal.enable_trend        = InpEnableTrend;
   g_cfg.signal.enable_orb          = InpEnableOrb;
   g_cfg.signal.enable_sweep        = InpEnableSweep;
   g_cfg.signal.enable_meanrev      = InpEnableMeanRev;
   g_cfg.signal.require_htf_alignment_trend = InpRequireHtfAlignTrend;
   g_cfg.signal.atr_percentile_min_trend    = InpAtrPctMinTrend;
   g_cfg.signal.atr_percentile_min_orb      = InpAtrPctMinOrb;
   g_cfg.signal.atr_percentile_min_sweep    = InpAtrPctMinSweep;
   g_cfg.signal.atr_percentile_min_meanrev  = InpAtrPctMinMeanRev;
   g_cfg.signal.atr_percentile_max_meanrev  = InpAtrPctMaxMeanRev;
   g_cfg.signal.adx_trend_min       = InpAdxTrendMin;
   g_cfg.signal.adx_range_max       = InpAdxRangeMax;
   g_cfg.signal.atr_stop_mult_trend = InpAtrStopTrend;
   g_cfg.signal.atr_stop_mult_orb   = InpAtrStopOrb;
   g_cfg.signal.atr_stop_mult_sweep = InpAtrStopSweep;
   g_cfg.signal.atr_stop_mult_meanrev = InpAtrStopMeanRev;
   g_cfg.signal.rr_target1_trend    = InpRrT1Trend;
   g_cfg.signal.rr_target2_trend    = InpRrT2Trend;
   g_cfg.signal.rr_target1_orb      = InpRrT1Orb;
   g_cfg.signal.rr_target2_orb      = InpRrT2Orb;
   g_cfg.signal.rr_target1_sweep    = InpRrT1Sweep;
   g_cfg.signal.rr_target2_sweep    = InpRrT2Sweep;
   g_cfg.signal.rr_target1_meanrev  = InpRrT1MeanRev;
   g_cfg.signal.rr_target2_meanrev  = InpRrT2MeanRev;
   g_cfg.signal.orb_buffer_atr      = InpOrbBufferAtr;
   g_cfg.signal.orb_min_range_atr   = InpOrbMinRangeAtr;
   g_cfg.signal.orb_max_range_atr   = InpOrbMaxRangeAtr;
   g_cfg.signal.sweep_buffer_atr    = InpSweepBufferAtr;
   g_cfg.signal.sweep_min_wick_atr  = InpSweepMinWickAtr;
   g_cfg.signal.meanrev_stop_atr    = InpAtrStopMeanRev;
   g_cfg.signal.swing_lookback      = InpSwingLookback;
   g_cfg.signal.cooldown_minutes    = InpCooldownMinutes;
   g_cfg.signal.risk_scale_sweep    = InpRiskScaleSweep;
   g_cfg.signal.risk_scale_meanrev  = InpRiskScaleMeanRev;
   g_cfg.signal.score_weight_trend  = InpScoreWeightTrend;
   g_cfg.signal.score_weight_momentum = InpScoreWeightMomentum;
   g_cfg.signal.score_weight_volatility = InpScoreWeightVolatil;
   g_cfg.signal.score_weight_location = InpScoreWeightLocation;
   g_cfg.signal.score_weight_structure = InpScoreWeightStructure;
   g_cfg.signal.medium_news_threshold_add = InpMediumNewsScoreAdd;
   g_cfg.signal.min_bars_required   = InpMinBarsRequired;
   g_cfg.signal.ema_fast            = InpEmaFast;
   g_cfg.signal.ema_mid             = InpEmaMid;
   g_cfg.signal.ema_slow            = InpEmaSlow;
   g_cfg.signal.rsi_period          = InpRsiPeriod;
   g_cfg.signal.macd_fast           = InpMacdFast;
   g_cfg.signal.macd_slow           = InpMacdSlow;
   g_cfg.signal.macd_signal         = InpMacdSignal;
   g_cfg.signal.bb_period           = InpBbPeriod;
   g_cfg.signal.bb_deviation        = InpBbDeviation;
   g_cfg.signal.adx_period          = InpAdxPeriod;
   g_cfg.signal.atr_period          = InpAtrPeriod;
   g_cfg.signal.atr_percentile_lookback = InpAtrPercentileLookback;
   g_cfg.signal.volume_lookback     = InpVolumeLookback;
   g_cfg.signal.swing_fractal       = InpSwingFractal;
   g_cfg.signal.orb_entry_window_minutes = InpOrbEntryWindowMin;
   g_cfg.signal.sweep_max_adx       = InpSweepMaxAdx;

   g_cfg.risk.risk_per_trade_pct    = InpRiskPerTradePct;
   g_cfg.risk.max_portfolio_heat_pct = InpMaxPortfolioHeatPct;
   g_cfg.risk.max_daily_loss_pct    = InpMaxDailyLossPct;
   g_cfg.risk.max_weekly_loss_pct   = InpMaxWeeklyLossPct;
   g_cfg.risk.max_drawdown_pct      = InpMaxDrawdownPct;
   g_cfg.risk.max_correlated_exposure_pct = InpMaxCorrExposurePct;
   g_cfg.risk.correlation_threshold = InpCorrelationThreshold;
   g_cfg.risk.correlation_lookback_bars = InpCorrelationLookback;
   g_cfg.risk.max_open_positions    = InpMaxOpenPositions;
   g_cfg.risk.max_positions_per_symbol = InpMaxPosPerSymbol;
   g_cfg.risk.max_positions_per_correlation_group = InpMaxPosPerGroup;
   g_cfg.risk.max_margin_usage_pct  = InpMaxMarginUsagePct;
   g_cfg.risk.min_free_margin_pct   = InpMinFreeMarginPct;
   g_cfg.risk.lot_risk_tolerance    = InpLotRiskTolerance;
   g_cfg.risk.max_consecutive_losses = InpMaxConsecutiveLosses;
   g_cfg.risk.day_roll_hour_utc     = InpDayRollHourUtc;
   g_cfg.risk.reset_halts_on_init   = InpResetHaltsOnInit;
   g_cfg.risk.close_on_drawdown_halt = InpCloseOnDrawdownHalt;
   g_cfg.risk.max_avg_slippage_stop_ratio = InpMaxAvgSlipRatio;
   g_cfg.risk.max_rejections_per_day = InpMaxRejectionsPerDay;
   g_cfg.risk.min_trades_for_slippage_halt = InpMinTradesForSlipHalt;
   g_cfg.risk.correlation_enabled   = InpCorrelationEnabled;

   g_cfg.ml.enabled                 = InpMlEnabled;
   g_cfg.ml.metadata_file           = InpMlMetadataFile;
   g_cfg.ml.model_dir               = InpMlModelDir;
   g_cfg.ml.fail_on_load_error      = (InpMlFailOnLoadError || InpFailOnModelLoad);
   g_cfg.ml.require_hash            = InpMlRequireHash;
   g_cfg.ml.allow_without_model     = InpMlAllowWithoutModel;
   g_cfg.ml.default_threshold       = InpMlDefaultThreshold;
   g_cfg.ml.max_consecutive_failures = InpMlMaxFailures;
   g_cfg.ml.use_ensemble_meta       = InpMlUseEnsembleMeta;
   g_cfg.ml.log_inference           = InpMlLogInference;

   g_cfg.ai.enabled                 = InpAiEnabled;
   g_cfg.ai.policy_file             = InpAiPolicyFile;
   g_cfg.ai.max_calls_per_hour      = InpAiMaxCallsPerHour;
   g_cfg.ai.cache_seconds           = InpAiCacheSeconds;
   g_cfg.ai.timeout_ms              = InpAiTimeoutMs;
   g_cfg.ai.fallback_mode           = InpAiFallback;
   g_cfg.ai.fallback_reduce_factor  = InpAiFallbackReduce;
   g_cfg.ai.min_confidence          = InpAiMinConfidence;
   g_cfg.ai.max_risk_multiplier     = InpAiMaxRiskMultiplier;
   g_cfg.ai.max_consecutive_failures = InpAiMaxFailures;
   g_cfg.ai.breaker_seconds         = InpAiBreakerSeconds;
   g_cfg.ai.require_https           = InpAiRequireHttps;
   g_cfg.ai.max_response_bytes      = InpAiMaxResponseBytes;

   g_cfg.news.enabled               = InpNewsEnabled;
   g_cfg.news.csv_file              = InpNewsCsv;
   g_cfg.news.common_folder         = InpNewsCommonFolder;
   g_cfg.news.use_live_calendar     = InpNewsUseLiveCalendar;
   g_cfg.news.refresh_minutes       = InpNewsRefreshMinutes;
   g_cfg.news.high_impact_block_before_min = InpNewsHighBlockBefore;
   g_cfg.news.high_impact_block_after_min  = InpNewsHighBlockAfter;
   g_cfg.news.medium_impact_window_min = InpNewsMediumWindowMin;
   g_cfg.news.medium_impact_risk_mult = InpNewsMediumRiskMult;
   g_cfg.news.unavailable_policy    = InpNewsUnavailable;
   g_cfg.news.horizon_hours         = InpNewsHorizonHours;
   g_cfg.news.global_blackout_halts_all = InpNewsGlobalBlackout;
   g_cfg.news.calendar_time_basis   = InpCalendarTimeBasis;

   g_cfg.exec.magic                 = InpMagic;
   g_cfg.exec.allow_long            = InpAllowLong;
   g_cfg.exec.allow_short           = InpAllowShort;
   g_cfg.exec.max_spread_multiplier = InpMaxSpreadMultiplier;
   g_cfg.exec.spread_buffer_points  = InpSpreadBufferPoints;
   g_cfg.exec.deviation_fx_points   = InpDeviationFx;
   g_cfg.exec.deviation_metal_points = InpDeviationMetal;
   g_cfg.exec.deviation_index_points = InpDeviationIndex;
   g_cfg.exec.max_retries           = InpMaxRetries;
   g_cfg.exec.retry_pause_ms        = InpRetryPauseMs;
   g_cfg.exec.verify_protection     = InpVerifyProtection;
   g_cfg.exec.close_if_protection_fails = InpCloseIfNoProtection;
   g_cfg.exec.use_pending_breakout  = InpUsePendingBreakout;
   g_cfg.exec.breakeven_enabled     = InpBreakevenEnabled;
   g_cfg.exec.breakeven_at_r        = InpBreakevenAtR;
   g_cfg.exec.breakeven_buffer_atr  = InpBreakevenBufferAtr;
   g_cfg.exec.trail_enabled         = InpTrailEnabled;
   g_cfg.exec.trail_start_r         = InpTrailStartR;
   g_cfg.exec.trail_atr_mult        = InpTrailAtrMult;
   g_cfg.exec.trail_min_step_atr    = InpTrailMinStepAtr;
   g_cfg.exec.partial_enabled       = InpPartialEnabled;
   g_cfg.exec.partial_at_r          = InpPartialAtR;
   g_cfg.exec.partial_pct           = InpPartialPct;
   g_cfg.exec.time_exit_enabled     = InpTimeExitEnabled;
   g_cfg.exec.max_hold_minutes      = InpMaxHoldMinutes;
   g_cfg.exec.time_exit_min_r       = InpTimeExitMinR;
   g_cfg.exec.exit_on_invalidation  = InpExitOnInvalidation;
   g_cfg.exec.modify_retries        = InpModifyRetries;
   g_cfg.exec.dry_run               = InpDryRun;
   g_cfg.exec.enable_trading        = InpEnableTrading;

   g_cfg.journal.enabled            = InpJournalEnabled;
   g_cfg.journal.dir                = InpJournalDir;
   g_cfg.journal.common_folder      = InpJournalCommonFolder;
   g_cfg.journal.verbosity          = InpJournalVerbosity;
   g_cfg.journal.log_rejections     = InpJournalRejections;
   g_cfg.journal.track_mae_mfe      = InpJournalMaeMfe;
   g_cfg.journal.daily_summary      = InpJournalDailySummary;
   g_cfg.journal.max_mb             = InpJournalMaxMb;

   g_cfg.runtime.timer_seconds      = InpTimerSeconds;
   g_cfg.runtime.max_loop_ms        = InpMaxLoopMs;

   g_ops_dir    = (InpJournalDir != "") ? InpJournalDir : "DerivAIPortfolioEA";
   g_state_file = g_ops_dir + "/state.json";
  }

//+------------------------------------------------------------------+
//| Validate every input before anything is loaded or written.         |
//+------------------------------------------------------------------+
bool ValidateConfig(const EAConfig &c, string &err)
  {
   err = "";
   if(c.symbols.csv_file == "")                  { err = "symbol CSV is empty"; return false; }
   if(c.symbols.refresh_seconds < 5 || c.symbols.refresh_seconds > 3600)
     { err = "spec refresh seconds must be 5..3600"; return false; }
   if(c.symbols.max_tick_age_seconds < 10 || c.symbols.max_tick_age_seconds > 3600)
     { err = "max tick age must be 10..3600"; return false; }
   if(c.symbols.resolution < SYMBOL_RESOLVE_EXACT || c.symbols.resolution > SYMBOL_RESOLVE_OVERRIDE)
     { err = "invalid symbol resolution mode"; return false; }

   if(c.session.utc_offset_override != 99 &&
      (c.session.utc_offset_override < -12 || c.session.utc_offset_override > 14))
     { err = "UTC offset override must be -12..14 or 99"; return false; }
   if(c.session.opening_range_minutes < 5 || c.session.opening_range_minutes > 180)
     { err = "opening range must be 5..180 minutes"; return false; }
   if(c.session.preopen_minutes < 0 || c.session.preopen_minutes > 120)
     { err = "pre-open minutes must be 0..120"; return false; }
   if(!c.session.enable_asian && !c.session.enable_london && !c.session.enable_ny)
     { err = "at least one trading session must be enabled"; return false; }
   if(c.session.risk_scale_asian < 0.0 || c.session.risk_scale_asian > 1.0 ||
      c.session.risk_scale_open < 0.0 || c.session.risk_scale_open > 1.0 ||
      c.session.risk_scale_core < 0.0 || c.session.risk_scale_core > 1.0 ||
      c.session.risk_scale_preopen < 0.0 || c.session.risk_scale_preopen > 1.0)
     { err = "session risk scales must be 0..1"; return false; }

   if(c.signal.exec_tf == PERIOD_CURRENT || c.signal.htf_tf == PERIOD_CURRENT ||
      c.signal.range_tf == PERIOD_CURRENT)
     { err = "timeframes must be explicit (not PERIOD_CURRENT)"; return false; }
   if(c.signal.min_technical_score < 0.0 || c.signal.min_technical_score > 100.0)
     { err = "minimum technical score must be 0..100"; return false; }
   if(c.signal.atr_percentile_min_trend < 0.0 || c.signal.atr_percentile_min_trend > 1.0 ||
      c.signal.atr_percentile_min_orb < 0.0 || c.signal.atr_percentile_min_orb > 1.0 ||
      c.signal.atr_percentile_min_sweep < 0.0 || c.signal.atr_percentile_min_sweep > 1.0 ||
      c.signal.atr_percentile_min_meanrev < 0.0 || c.signal.atr_percentile_min_meanrev > 1.0 ||
      c.signal.atr_percentile_max_meanrev < 0.0 || c.signal.atr_percentile_max_meanrev > 1.0)
     { err = "ATR percentiles must be 0..1"; return false; }
   if(c.signal.atr_percentile_max_meanrev < c.signal.atr_percentile_min_meanrev)
     { err = "mean-reversion ATR percentile range is inverted"; return false; }
   if(c.signal.atr_stop_mult_trend <= 0.0 || c.signal.atr_stop_mult_orb <= 0.0 ||
      c.signal.atr_stop_mult_sweep <= 0.0 || c.signal.atr_stop_mult_meanrev <= 0.0)
     { err = "ATR stop multiples must be > 0"; return false; }
   if(c.signal.rr_target1_trend <= 0.0 || c.signal.rr_target1_orb <= 0.0 ||
      c.signal.rr_target1_sweep <= 0.0 || c.signal.rr_target1_meanrev <= 0.0 ||
      c.signal.rr_target2_trend <= 0.0 || c.signal.rr_target2_orb <= 0.0 ||
      c.signal.rr_target2_sweep <= 0.0 || c.signal.rr_target2_meanrev <= 0.0)
     { err = "target R multiples must be > 0"; return false; }
   if(c.signal.ema_fast < 2 || c.signal.ema_mid <= c.signal.ema_fast ||
      c.signal.ema_slow <= c.signal.ema_mid)
     { err = "EMA periods must be increasing"; return false; }
   if(c.signal.min_bars_required < 60)
     { err = "min_bars_required must be >= 60"; return false; }
   if(c.signal.atr_period < 2 || c.signal.atr_period > 200)
     { err = "ATR period must be 2..200"; return false; }
   if(c.signal.cooldown_minutes < 0 || c.signal.cooldown_minutes > 1440)
     { err = "cooldown must be 0..1440 minutes"; return false; }

   if(c.risk.risk_per_trade_pct <= 0.0 || c.risk.risk_per_trade_pct > 5.0)
     { err = "risk per trade must be in (0,5]%"; return false; }
   if(c.risk.max_portfolio_heat_pct < c.risk.risk_per_trade_pct)
     { err = "max heat must be >= risk per trade"; return false; }
   if(c.risk.max_daily_loss_pct <= 0.0 || c.risk.max_weekly_loss_pct <= 0.0)
     { err = "daily/weekly loss limits must be > 0"; return false; }
   if(c.risk.max_weekly_loss_pct < c.risk.max_daily_loss_pct)
     { err = "weekly loss limit must be >= daily"; return false; }
   if(c.risk.max_drawdown_pct <= 0.0 || c.risk.max_drawdown_pct > 100.0)
     { err = "max drawdown must be in (0,100]%"; return false; }
   if(c.risk.max_correlated_exposure_pct <= 0.0 ||
      c.risk.max_correlated_exposure_pct > c.risk.max_portfolio_heat_pct)
     { err = "correlated exposure must be > 0 and <= max heat"; return false; }
   if(c.risk.correlation_threshold < 0.0 || c.risk.correlation_threshold > 1.0)
     { err = "correlation threshold must be 0..1"; return false; }
   if(c.risk.max_open_positions < 1 || c.risk.max_open_positions > 100)
     { err = "max open positions must be 1..100"; return false; }
   if(c.risk.max_positions_per_symbol < 1 ||
      c.risk.max_positions_per_correlation_group < 1)
     { err = "per-symbol/group position caps must be >= 1"; return false; }
   if(c.risk.lot_risk_tolerance < 1.0 || c.risk.lot_risk_tolerance > 3.0)
     { err = "lot risk tolerance must be 1..3"; return false; }

   if(c.ml.enabled && c.ml.metadata_file == "")
     { err = "ML is enabled but the metadata file is empty"; return false; }
   if(c.ml.default_threshold <= 0.0 || c.ml.default_threshold >= 1.0)
     { err = "ML default threshold must be in (0,1)"; return false; }
   if(c.ml.max_consecutive_failures < 1)
     { err = "ML failure limit must be >= 1"; return false; }

   if(c.ai.enabled)
     {
      if(c.ai.max_calls_per_hour < 1)    { err = "AI hourly call limit must be >= 1"; return false; }
      if(c.ai.timeout_ms < 100 || c.ai.timeout_ms > 30000)
        { err = "AI timeout must be 100..30000 ms"; return false; }
      if(c.ai.max_risk_multiplier <= 0.0 || c.ai.max_risk_multiplier > 1.0)
        { err = "AI max risk multiplier must be in (0,1]"; return false; }
      if(c.ai.fallback_reduce_factor < 0.0 || c.ai.fallback_reduce_factor > 1.0)
        { err = "AI fallback reduce factor must be 0..1"; return false; }
      if(c.ai.min_confidence < 0 || c.ai.min_confidence > 100)
        { err = "AI minimum confidence must be 0..100"; return false; }
      if(c.ai.max_response_bytes < 1024 || c.ai.max_response_bytes > 65536)
        { err = "AI max response size must be 1024..65536"; return false; }
     }

   if(c.news.enabled)
     {
      if(c.news.high_impact_block_before_min < 0 || c.news.high_impact_block_before_min > 240)
        { err = "news block-before must be 0..240 minutes"; return false; }
      if(c.news.high_impact_block_after_min < 0 || c.news.high_impact_block_after_min > 240)
        { err = "news block-after must be 0..240 minutes"; return false; }
      if(c.news.medium_impact_risk_mult < 0.0 || c.news.medium_impact_risk_mult > 1.0)
        { err = "medium-impact risk multiplier must be 0..1"; return false; }
      if(c.news.horizon_hours < 1 || c.news.horizon_hours > 168)
        { err = "news horizon must be 1..168 hours"; return false; }
      if(c.news.calendar_time_basis != 0 && c.news.calendar_time_basis != 1)
        { err = "calendar time basis must be 0 (server) or 1 (UTC)"; return false; }
      if(!c.news.use_live_calendar && c.news.csv_file == "")
        { err = "calendar CSV is required when the live calendar is off"; return false; }
     }

   if(c.exec.magic == 0)              { err = "magic number must be non-zero"; return false; }
   if(c.exec.max_retries < 0 || c.exec.max_retries > 20)
     { err = "max retries must be 0..20"; return false; }
   if(c.exec.breakeven_at_r <= 0.0 || c.exec.trail_start_r <= 0.0)
     { err = "breakeven/trailing triggers must be > 0"; return false; }
   if(c.exec.partial_pct < 0.0 || c.exec.partial_pct >= 1.0)
     { err = "partial fraction must be in [0,1)"; return false; }
   if(c.exec.max_hold_minutes < 5)
     { err = "max hold minutes must be >= 5"; return false; }
   if(c.exec.max_spread_multiplier <= 0.0)
     { err = "spread multiplier must be > 0"; return false; }
   if(c.exec.use_pending_breakout)
     { err = "use_pending_breakout is reserved and not implemented in this build"; return false; }
   if(c.ml.use_ensemble_meta)
     { err = "use_ensemble_meta is reserved and not implemented in this build"; return false; }

   if(c.journal.max_mb < 0 || c.journal.max_mb > 1024)
     { err = "journal rotation size must be 0..1024 MB"; return false; }
   if(c.journal.verbosity < 0 || c.journal.verbosity > 2)
     { err = "journal verbosity must be 0..2"; return false; }
   if(c.runtime.timer_seconds < 1 || c.runtime.timer_seconds > 300)
     { err = "timer seconds must be 1..300"; return false; }
   if(c.runtime.max_loop_ms < 100 || c.runtime.max_loop_ms > 60000)
     { err = "loop budget must be 100..60000 ms"; return false; }

   return true;
  }

//+------------------------------------------------------------------+
//| The feature contract uses one ATR period for every symbol. The CSV |
//| keeps the column for template compatibility, so a mismatch is a    |
//| startup error instead of a silently ignored setting.               |
//+------------------------------------------------------------------+
bool ValidateSymbolPeriods(string &err)
  {
   err = "";
   for(int i = 0; i < g_reg.Count(); i++)
     {
      SymbolSpec *sp = g_reg.At(i);
      if(sp == NULL || !sp.enabled)
         continue;
      if(sp.atr_period != g_cfg.signal.atr_period)
        {
         err = StringFormat("%s: CSV atr_period %d != InpAtrPeriod %d (one period is required by the feature contract)",
                            sp.config_name, sp.atr_period, g_cfg.signal.atr_period);
         return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Refresh stale contract specs. Position management (trailing,       |
//| breakeven, partials) must never use zero or outdated contract data.|
//| Failures are not logged here: the evaluation and order paths read  |
//| the same spec and reject with a reason. Logging this loop would    |
//| repeat the same warning on every tick.                             |
//+------------------------------------------------------------------+
void RefreshStaleSpecs(void)
  {
   for(int i = 0; i < g_reg.Count(); i++)
     {
      SymbolSpec *sp = g_reg.At(i);
      if(sp == NULL || !sp.enabled || !sp.resolved)
         continue;
      string err = "";
      g_reg.RefreshIfStale(sp.name, err);
     }
  }

//+------------------------------------------------------------------+
//| Startup banner and one-line account context.                      |
//+------------------------------------------------------------------+
void PrintBanner(void)
  {
   if(!InpPrintBanner)
      return;
   PrintFormat("%s %s starting (terminal build %I64d, compiled %s)",
               EA_NAME, EA_VERSION,
               (long)TerminalInfoInteger(TERMINAL_BUILD),
               TimeToString(__DATETIME__, TIME_DATE | TIME_MINUTES));
   PrintFormat("%s account=%I64d broker=%s server=%s currency=%s leverage=1:%I64d",
               DAI_LOG_PREFIX,
               AccountInfoInteger(ACCOUNT_LOGIN),
               AccountInfoString(ACCOUNT_COMPANY),
               AccountInfoString(ACCOUNT_SERVER),
               AccountInfoString(ACCOUNT_CURRENCY),
               AccountInfoInteger(ACCOUNT_LEVERAGE));
   PrintFormat("%s tester=%s optimization=%s visual=%s",
               DAI_LOG_PREFIX,
               IsStrategyTester() ? "yes" : "no",
               IsOptimization() ? "yes" : "no",
               IsVisualMode() ? "yes" : "no");
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   PrintBanner();
   BuildConfig();

   string err = "";
   if(!ValidateConfig(g_cfg, err))
     {
      LogError("configuration invalid: " + err);
      Alert(EA_NAME + ": configuration invalid - " + err);
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- journal first, so every later failure is recorded -----------
   if(!g_journal.Init(g_cfg.journal, err))
     {
      LogError("journal init failed: " + err);
      return INIT_FAILED;
     }
   g_journal.Event("INFO", "INIT", StringFormat("%s %s starting", EA_NAME, EA_VERSION));

   //--- persistent state -------------------------------------------
   if(!EnsureFolder(g_ops_dir, g_cfg.journal.common_folder))
     {
      LogError("cannot create state directory: " + g_ops_dir);
      return INIT_FAILED;
     }
   if(!g_state.Init(g_state_file, g_cfg.journal.common_folder, err))
     {
      LogError("state init failed: " + err);
      return INIT_FAILED;
     }
   if(!g_state.Load(err))
     {
      LogError("state load failed: " + err);
      g_journal.Event("ERROR", "STATE", err);
      return INIT_FAILED;     // fail closed: never trade on an unreadable state
     }
   if(g_cfg.risk.reset_halts_on_init)
     {
      g_state.ResetHalts();
      g_journal.Event("WARN", "STATE", "halts cleared by reset_halts_on_init");
     }

   //--- symbols -----------------------------------------------------
   if(!g_reg.LoadConfig(g_cfg.symbols, err))
     {
      LogError("symbol config failed: " + err);
      g_journal.Event("ERROR", "SYMBOLS", err);
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!g_reg.ResolveAll(err))
     {
      LogError("symbol resolution failed: " + err);
      g_journal.Event("ERROR", "SYMBOLS", err);
      return INIT_FAILED;
     }
   if(!ValidateSymbolPeriods(err))
     {
      LogError("symbol ATR period mismatch: " + err);
      g_journal.Event("ERROR", "SYMBOLS", err);
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!g_reg.RefreshAll(err))
     {
      LogError("contract specification failed: " + err);
      g_journal.Event("ERROR", "SYMBOLS", err);
      return INIT_FAILED;
     }
   for(int i = 0; i < g_reg.WarningCount(); i++)
      g_journal.Event("WARN", "SYMBOLS", g_reg.WarningAt(i));

   //--- sessions ----------------------------------------------------
   if(!g_sess.Init(g_cfg.session, err))
     {
      LogError("session init failed: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }
   g_sess.Update(TimeTradeServer());
   if(g_sess.Warning() != "")
      g_journal.Event("WARN", "SESSIONS", g_sess.Warning());

   //--- indicators --------------------------------------------------
   if(!g_hub.Init(g_cfg.signal, g_cfg.risk.day_roll_hour_utc,
                  g_cfg.symbols.max_tick_age_seconds))
     {
      LogError("indicator init failed");
      return INIT_FAILED;
     }

   //--- news --------------------------------------------------------
   string currencies[];
   CollectNewsCurrencies(currencies);
   if(!g_news.Init(g_cfg.news, currencies, IsStrategyTester(), err))
     {
      LogError("news init failed: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!g_news.RefreshIfStale(g_sess.UtcNow(), g_sess.OffsetSeconds(), err))
      g_journal.Event("WARN", "NEWS", "calendar unavailable at startup: " + err);

   //--- signal engine ----------------------------------------------
   if(!g_sig.Init(g_cfg.signal))
     {
      LogError("signal engine init failed");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- machine learning -------------------------------------------
   if(!g_ml.Init(g_cfg.ml, err))
     {
      LogError("ONNX init failed: " + err);
      g_journal.Event("ERROR", "ML", err);
      return INIT_FAILED;
     }
   if(g_cfg.ml.enabled && g_ml.ModelCount() == 0)
     {
      g_journal.Event("WARN", "ML", "no usable ONNX model; entries will be rejected unless allow_without_model=true");
      LogWarn("no usable ONNX model loaded - see model_metadata.json");
     }

   //--- external AI ------------------------------------------------
   if(!g_ai.Init(g_cfg.ai, IsStrategyTester(), IsOptimization(), err))
     {
      LogError("AI init failed: " + err);
      g_journal.Event("ERROR", "AI", err);
      return INIT_PARAMETERS_INCORRECT;
     }
   if(g_cfg.ai.enabled && !g_ai.Ready())
      LogWarn("AI is enabled but not ready: " + g_ai.LastError());

   //--- risk engine -------------------------------------------------
   if(!g_risk.Init(g_cfg.risk, g_cfg.exec, g_cfg.signal.exec_tf, err))
     {
      LogError("risk init failed: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }
   g_risk.Attach(&g_state, &g_reg);
   if(!g_risk.UpdateAccount(err))
     {
      LogError("account state unavailable: " + err);
      return INIT_FAILED;
     }

   //--- execution ---------------------------------------------------
   if(!g_exec.Init(g_cfg.exec, &g_reg, &g_journal, &g_state, err))
     {
      LogError("execution init failed: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- reconcile state with the account ---------------------------
   g_state.UpdateEquity(g_risk.Equity());
   RollAnchors();
   if(g_state.Save(err))
      g_last_save = TimeTradeServer();
   else
      LogError("initial state save failed: " + err);

   int reconciled = g_exec.Reconcile(err);
   if(reconciled > 0)
      g_journal.Event("INFO", "RECONCILE", StringFormat("%d position records reconciled", reconciled));
   int streak = g_exec.RebuildLossStreak(g_cfg.exec.magic, 30, err);
   if(err != "")
      g_journal.Event("WARN", "HISTORY", err);
   else if(streak > 0)
      g_journal.Event("WARN", "HISTORY", StringFormat("consecutive losses rebuilt: %d", streak));

   //--- runtime state ----------------------------------------------
   ArrayResize(g_bar_symbol, 0);
   ArrayResize(g_bar_time, 0);
   g_init_ok = true;

   if(!IsOptimization())
      EventSetTimer(MathMax(1, g_cfg.runtime.timer_seconds));

   g_journal.Event("INFO", "INIT", StringFormat("ready: %d of %d symbols resolved, %d positions, heat %.2f%%",
                   g_reg.ResolvedCount(), g_reg.Count(),
                   g_state.PositionCount(), g_risk.HeatPct()));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_init_ok)
     {
      g_journal.Event("INFO", "DEINIT",
                      StringFormat("stopping (reason %d, %s)", reason, UninitReasonName(reason)));
      string err = "";
      if(!g_state.Save(err))
         LogError("final state save failed: " + err);
     }
   g_hub.Release();
   g_ml.Deinit();
   g_init_ok = false;
  }

//+------------------------------------------------------------------+
string UninitReasonName(const int reason)
  {
   switch(reason)
     {
      case REASON_PROGRAM:     return "expert removed";
      case REASON_REMOVE:      return "expert removed from chart";
      case REASON_RECOMPILE:   return "recompile";
      case REASON_CHARTCHANGE: return "chart or timeframe changed";
      case REASON_CHARTCLOSE:  return "chart closed";
      case REASON_PARAMETERS:  return "inputs changed";
      case REASON_ACCOUNT:     return "account changed";
      case REASON_TEMPLATE:    return "template applied";
      case REASON_INITFAILED:  return "init failed";
      case REASON_CLOSE:       return "terminal closed";
      default:                 return "unknown";
     }
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   ProcessAll();
  }

void OnTimer(void)
  {
   ProcessAll();
  }

//+------------------------------------------------------------------+
//| One loop: housekeeping, position management, then new-bar scans.   |
//+------------------------------------------------------------------+
void ProcessAll(void)
  {
   if(!g_init_ok)
      return;

   uint start_ms = GetTickCount();
   string err = "";

   g_sess.Update(TimeTradeServer());
   if(!g_risk.UpdateAccount(err))
     {
      g_journal.Event("ERROR", "ACCOUNT", err);
      return;
     }
   g_state.UpdateEquity(g_risk.Equity());

   RollAnchors();
   CheckOperatorFiles();

   //--- hard halts --------------------------------------------------
   ENUM_REASON hcode = RC_NONE;
   string hwhy = "";
   bool halted = g_risk.HaltCheck(hcode, hwhy);
   if(halted && hcode == RC_DRAWDOWN && g_cfg.risk.close_on_drawdown_halt && !g_dd_close_done)
     {
      CloseAll("drawdown halt: " + hwhy);
      g_dd_close_done = true;
     }

   //--- manage open positions --------------------------------------
   RefreshStaleSpecs();
   ManageAll();

   if(!halted)
     {
      int total = g_reg.Count();
      for(int i = 0; i < total; i++)
        {
         if((int)(GetTickCount() - start_ms) > g_cfg.runtime.max_loop_ms)
           {
            g_journal.Event("WARN", "BUDGET", "loop budget exhausted before all symbols");
            break;
           }
         SymbolSpec *sp = g_reg.At(i);
         if(sp == NULL || !sp.enabled || !sp.resolved)
            continue;
         datetime bar = 0;
         if(!IsNewBar(sp.name, g_cfg.signal.exec_tf, bar))
            continue;
         EvaluateSymbol(*sp, bar);
        }
     }
   else if(halted && hcode != RC_NONE)
     {
      static datetime last_halt_note = 0;
      if(TimeTradeServer() - last_halt_note > 300)
        {
         last_halt_note = TimeTradeServer();
         g_journal.Event("WARN", "HALT", StringFormat("%s: %s",
                         ReasonToString(hcode), hwhy));
        }
     }

   MaybeSave(false);
  }

//+------------------------------------------------------------------+
//| New-bar detection per symbol and timeframe.                       |
//+------------------------------------------------------------------+
bool IsNewBar(const string symbol, const ENUM_TIMEFRAMES tf, datetime &bar_time)
  {
   bar_time = 0;
   datetime t[];
   if(CopyTime(symbol, tf, 0, 1, t) != 1)
      return false;
   bar_time = t[0];

   int idx = -1;
   for(int i = 0; i < ArraySize(g_bar_symbol); i++)
      if(g_bar_symbol[i] == symbol)
        {
         idx = i;
         break;
        }
   if(idx < 0)
     {
      int n = ArraySize(g_bar_symbol);
      if(!ArrayResize(g_bar_symbol, n + 1) || !ArrayResize(g_bar_time, n + 1))
         return false;
      g_bar_symbol[n] = symbol;
      g_bar_time[n]   = bar_time;
      return true;                 // first sighting counts as a new bar
     }
   if(g_bar_time[idx] == bar_time)
      return false;
   g_bar_time[idx] = bar_time;
   return true;
  }

//+------------------------------------------------------------------+
//| Day/week anchors and the previous day's summary.                   |
//+------------------------------------------------------------------+
void RollAnchors(void)
  {
   datetime utc = g_sess.UtcNow();
   if(utc <= 0)
      utc = TimeGMT();
   int day_id  = (int)(DayFloor(utc, g_cfg.risk.day_roll_hour_utc) / 86400);
   int week_id = WeekId(utc);

   int prev_day      = g_state.DayIdStored();
   double prev_start = g_state.DayStartEquity();

   if(!g_state.Roll(day_id, week_id, g_risk.Equity()))
      return;

   g_dd_close_done = false;
   if(prev_day > 0 && prev_day != day_id)
      WriteDailySummary(prev_day, prev_start);

   string err = "";
   g_state.Save(err);
  }

//+------------------------------------------------------------------+
void WriteDailySummary(const int day_id, const double start_equity)
  {
   if(!g_cfg.journal.enabled || !g_cfg.journal.daily_summary)
      return;
   if(day_id <= 0)
      return;

   datetime from = (datetime)day_id * 86400;
   datetime to   = from + 86400;
   int trades = 0, wins = 0, losses = 0;
   double net = 0.0, rsum = 0.0;

   if(HistorySelect(from, to))
     {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0)
            continue;
         if((int)HistoryDealGetInteger(ticket, DEAL_MAGIC) != g_cfg.exec.magic)
            continue;
         long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
            continue;
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         trades++;
         net += p;
         if(p > 0.0)      wins++;
         else if(p < 0.0) losses++;
         double risk = 0.0;
         PositionMeta pm;
         if(g_state.FindPosition((ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID), pm))
            risk = pm.risk_money;
         rsum += (risk > 0.0) ? p / risk : 0.0;
        }
     }

   g_journal.DailySummary(day_id, start_equity, g_risk.Equity(), trades, wins, losses,
                          net, rsum, g_risk.DrawdownPct(), g_risk.HeatPct(),
                          g_state.HaltReason());
   g_last_day_summary = TimeTradeServer();
  }

//+------------------------------------------------------------------+
//| Operator files: KILL latches the manual halt, RESET clears halts.  |
//+------------------------------------------------------------------+
void CheckOperatorFiles(void)
  {
   bool common = g_cfg.journal.common_folder;
   string kill = g_ops_dir + "/KILL";
   if(FileExistsIn(kill, common))
     {
      if(!g_state.Halts().manual)
        {
         g_state.LatchManual("KILL file present");
         g_journal.Event("ERROR", "KILL", "manual kill switch latched by KILL file");
         string err = "";
         g_state.Save(err);
        }
     }

   string reset = g_ops_dir + "/RESET";
   if(FileExistsIn(reset, common))
     {
      g_state.ResetHalts();
      g_journal.Event("WARN", "RESET", "halts cleared by RESET file");
      FileDelete(reset, common ? FILE_COMMON : 0);
      string err = "";
      g_state.Save(err);
     }
  }

//+------------------------------------------------------------------+
//| Close every position owned by this EA.                            |
//+------------------------------------------------------------------+
void CloseAll(const string why)
  {
   for(int i = g_state.PositionCount() - 1; i >= 0; i--)
     {
      PositionMeta pm;
      if(!g_state.PositionAt(i, pm))
         continue;
      SymbolSpec *sp = g_reg.Find(pm.symbol);
      if(sp == NULL)
         continue;
      ExecResult er;
      string err = "";
      if(g_exec.ClosePosition(*sp, pm.ticket, 0.0, er, err))
        {
         g_journal.Event("WARN", "CLOSE_ALL",
                         StringFormat("%s closed %.4f: %s", pm.symbol, er.volume, why));
         g_state.RemovePosition(pm.ticket);
        }
      else
        {
         g_journal.Event("ERROR", "CLOSE_ALL",
                         StringFormat("%s close failed: %s", pm.symbol, err));
        }
     }
   string serr = "";
   g_state.Save(serr);
  }

//+------------------------------------------------------------------+
//| Manage one position; capture P&L before a close request.          |
//+------------------------------------------------------------------+
void ManageAll(void)
  {
   for(int i = g_state.PositionCount() - 1; i >= 0; i--)
     {
      PositionMeta pm;
      if(!g_state.PositionAt(i, pm))
         continue;

      SymbolSpec *sp = g_reg.Find(pm.symbol);
      if(sp == NULL)
         continue;

      if(!PositionSelectByTicket(pm.ticket))
         continue;     // reconcile will retire the metadata

      double profit_before = PositionGetDouble(POSITION_PROFIT)
                             + PositionGetDouble(POSITION_SWAP);

      //--- session invalidation (opt-in) --------------------------
      if(g_cfg.exec.exit_on_invalidation &&
         g_sess.State() != SESSION_CLOSED &&
         !ProfileAllowsSession(sp.session_profile, g_sess.State()))
        {
         ExecResult ier;
         string ierr = "";
         if(g_exec.ClosePosition(*sp, pm.ticket, 0.0, ier, ierr))
           {
            double r = (pm.risk_money > 0.0) ? profit_before / pm.risk_money : 0.0;
            g_journal.TradeClose(pm, ier.volume, ier.fill_price, profit_before, r,
                                 0.0, 0.0, 0.0, "session invalidation");
            g_risk.OnPositionClosed(profit_before, pm.risk_money, 0.0);
            g_state.RemovePosition(pm.ticket);
            continue;
           }
         g_journal.Event("ERROR", "INVALIDATION",
                         StringFormat("%s close failed: %s", pm.symbol, ierr));
        }

      double atr = g_hub.AtrValue(pm.symbol);
      if(atr <= 0.0)
         atr = pm.initial_risk_price;

      MqlTick tick;
      if(!SymbolInfoTick(pm.symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
         continue;

      ManageOutcome mo;
      PositionMeta before = pm;
      g_exec.ManagePosition(*sp, atr, tick.bid, tick.ask, pm, mo);

      if(mo.partial)
        {
         g_journal.TradePartial(pm, mo.close_volume, tick.bid, 0.0, mo.note);
         g_state.UpdatePosition(pm);
        }
      if(mo.modified)
        {
         g_journal.TradeModify(pm, mo.note);
         g_state.UpdatePosition(pm);
        }
      if(mo.closed)
        {
         double r = (pm.risk_money > 0.0) ? profit_before / pm.risk_money : 0.0;
         double mae = 0.0, mfe = 0.0;
         if(g_cfg.journal.track_mae_mfe && pm.initial_risk_price > 0.0)
           {
            mfe = pm.direction * (pm.best_price - pm.entry) / pm.initial_risk_price;
            mae = pm.direction * (pm.worst_price - pm.entry) / pm.initial_risk_price;
           }
         g_journal.TradeClose(pm, 0.0, tick.bid, profit_before, r, mae, mfe, 0.0, mo.note);
         g_risk.OnPositionClosed(profit_before, pm.risk_money, 0.0);
         g_state.RemovePosition(pm.ticket);
         continue;
        }

      //--- persist only when the tracked record actually moved --------
      bool moved = (pm.sl_current != before.sl_current ||
                    pm.tp_current != before.tp_current ||
                    pm.be_done != before.be_done ||
                    pm.partial_done != before.partial_done ||
                    pm.trailing_active != before.trailing_active ||
                    pm.best_price != before.best_price ||
                    pm.worst_price != before.worst_price);
      if(moved)
        {
         pm.last_update = TimeTradeServer();
         g_state.UpdatePosition(pm);
        }
     }
  }

//+------------------------------------------------------------------+
//| Full per-symbol decision pipeline.                                |
//+------------------------------------------------------------------+
void EvaluateSymbol(const SymbolSpec &spec, const datetime bar_time)
  {
   TradeCandidate c;
   ResetCandidate(c);
   c.symbol        = spec.name;
   c.bar_time      = bar_time;
   c.session       = g_sess.StateName();
   c.session_risk_scale = g_sess.RiskScale();
   c.minutes_since_open = g_sess.MinutesSinceSessionStart();

   //--- 0. live contract snapshot ------------------------------------
   //--- Sizing, stop validity and spread all depend on live values.
   //--- A failed read rejects this candidate instead of using zeros.
   string serr = "";
   if(!g_reg.Refresh(spec.name, serr))
     {
      Reject(c, "data", RC_NO_DATA,
             "contract specification unavailable: " + serr);
      return;
     }
   if(!spec.live_valid)
     {
      Reject(c, "data", RC_NO_DATA,
             spec.live_error != "" ? spec.live_error : "contract specification invalid");
      return;
     }

   //--- 1. duplicate guard ------------------------------------------
   string setup_seed = StringFormat("%s|%d", spec.name, (int)bar_time);
   for(int i = 0; i < g_state.PositionCount(); i++)
     {
      PositionMeta pm;
      if(!g_state.PositionAt(i, pm))
         continue;
      if(pm.symbol == spec.name && StringFind(pm.setup_id, setup_seed) == 0)
        {
         Reject(c, "duplicate", RC_DUPLICATE, "a position from this bar is already open");
         return;
        }
     }

   //--- 2. spread ---------------------------------------------------
   double spread = g_reg.SpreadPoints(spec.name);
   c.spread_points = spread;
   double cap = (double)spec.max_spread_points;
   if(cap <= 0.0 && spec.spread_baseline > 0.0)
      cap = spec.spread_baseline * g_cfg.exec.max_spread_multiplier;
   if(cap > 0.0 && spread > cap)
     {
      Reject(c, "spread", RC_SPREAD_TOO_WIDE,
             StringFormat("spread %.1f > cap %.1f points", spread, cap));
      return;
     }

   //--- 3. market state ---------------------------------------------
   if(!g_reg.MarketOpen(spec.name, g_sess.ServerNow()))
     {
      Reject(c, "market", RC_MARKET_CLOSED, "broker reports the symbol closed");
      return;
     }

   //--- 4. session ---------------------------------------------------
   if(!g_sess.TradingAllowed())
     {
      Reject(c, "session", RC_SESSION_BLOCKED,
             StringFormat("session %s does not allow entries", g_sess.StateName()));
      return;
     }
   if(!ProfileAllowsSession(spec.session_profile, g_sess.State()))
     {
      Reject(c, "session", RC_SESSION_BLOCKED,
             StringFormat("profile '%s' does not trade %s",
                          spec.session_profile, g_sess.StateName()));
      return;
     }

   //--- 5. indicators ------------------------------------------------
   IndicatorSnapshot snap;
   if(!g_hub.BuildSnapshot(spec.name, spec, g_sess, snap))
     {
      Reject(c, "data", RC_NO_DATA, snap.error != "" ? snap.error : "indicator snapshot unavailable");
      return;
     }
   c.atr = snap.atr;
   if(spec.min_atr_points > 0 && snap.atr_points < (double)spec.min_atr_points)
     {
      Reject(c, "volatility", RC_ATR_TOO_SMALL,
             StringFormat("ATR %.0f < minimum %d points", snap.atr_points, spec.min_atr_points));
      return;
     }

   //--- 6. news ------------------------------------------------------
   NewsContext news;
   g_news.BuildContext(spec.name, spec.news_currencies, g_sess.UtcNow(), news);
   if(g_cfg.news.global_blackout_halts_all && !news.blackout)
     {
      NewsContext global;
      g_news.BuildContext(spec.name, "", g_sess.UtcNow(), global);
      if(global.blackout)
        {
         news.blackout = true;
         news.blackout_reason = "global calendar blackout: " + global.blackout_reason;
        }
     }
   c.minutes_to_event = news.minutes_to_next;
   c.event_impact     = news.next_impact;
   if(news.blackout)
     {
      Reject(c, "news", RC_NEWS_BLOCKED,
             news.blackout_reason != "" ? news.blackout_reason : "calendar blackout");
      return;
     }
   if(!news.available)
     {
      switch(g_cfg.news.unavailable_policy)
        {
         case NEWS_UNAVAILABLE_BLOCK_ALL:
            Reject(c, "news", RC_NEWS_UNAVAILABLE, "no calendar and policy is BLOCK_ALL");
            return;
         case NEWS_UNAVAILABLE_BLOCK_HIGH_RISK:
            if(spec.asset == ASSET_METAL || spec.asset == ASSET_INDEX)
              {
               Reject(c, "news", RC_NEWS_UNAVAILABLE,
                      "no calendar and asset class is high-risk");
               return;
              }
            break;
         default:
            g_journal.Event("WARN", "NEWS", "calendar unavailable; policy ALLOW");
            break;
        }
     }

   //--- 7. technical setup -------------------------------------------
   ENUM_REASON sreason = RC_NO_SETUP;
   if(!g_sig.Generate(spec, snap, g_sess, g_hub, news, c, sreason))
     {
      c.reason = sreason;
      c.reason_text = "no qualifying setup";
      c.approved = false;
      g_journal.Decision(c, "signal");
      return;
     }
   c.strategy_name = StrategyToString(c.strategy);
   c.setup_id = StringFormat("%s|%d|%s|%d", spec.name, (int)bar_time,
                             c.strategy_name, c.direction);
   c.strategy_risk_scale = (c.strategy == STRAT_SWEEP)    ? g_cfg.signal.risk_scale_sweep :
                           (c.strategy == STRAT_MEANREV)  ? g_cfg.signal.risk_scale_meanrev : 1.0;
   c.ml_threshold_add = (news.available && news.next_impact == 2) ? g_cfg.signal.medium_news_threshold_add : 0.0;

   //--- 8. ONNX score ------------------------------------------------
   if(g_cfg.ml.enabled)
     {
      double probability = 0.0;
      ENUM_REASON mreason = RC_ML_UNAVAILABLE;
      string merr = "";
      bool scored = g_ml.Score(spec, snap, c, probability, mreason, merr);
      if(scored)
        {
         c.ml_probability = probability;
         double threshold = g_ml.ThresholdFor(spec.asset) + c.ml_threshold_add;
         if(probability < threshold)
           {
            c.reason_text = StringFormat("p=%.4f < threshold %.4f", probability, threshold);
            Reject(c, "ml", RC_ML_LOW, c.reason_text);
            return;
           }
        }
      else
        {
         c.ml_probability = 0.0;
         bool required = !g_cfg.ml.allow_without_model;
         if(required)
           {
            Reject(c, "ml", (mreason == RC_NONE) ? RC_ML_INFERENCE_FAILED : mreason,
                   merr != "" ? merr : "model inference unavailable");
            return;
           }
         g_journal.Event("WARN", "ML", StringFormat("%s: %s (allowed by configuration)",
                         spec.name, merr));
        }
     }

   //--- 9. external AI advisory (veto / reduce only) -----------------
   AiDecision ai;
   ai.allowed = true;
   ai.risk_multiplier = 1.0;
   ai.confidence = 0;
   ai.reason = "";
   ai.used_fallback = false;
   ai.available = false;
   ai.reason_code = RC_AI_DISABLED;

   if(g_cfg.ai.enabled)
     {
      PortfolioSnapshot ps;
      g_risk.BuildSnapshot(ps);
      g_ai.Decide(spec, snap, c, news, ps, ai);
      c.ai_risk_multiplier = ClampD(ai.risk_multiplier, 0.0, 1.0);
      if(ai.available || ai.used_fallback)
         g_journal.AiAudit(spec.name,
                           ai.allowed ? "allow" : "veto",
                           ai.risk_multiplier, ai.confidence, ai.reason,
                           ai.used_fallback, ai.available,
                           g_cfg.journal.verbosity >= 2 ? g_ai.LastRequest() : "",
                           g_cfg.journal.verbosity >= 2 ? g_ai.LastResponse() : "",
                           g_ai.LastError());

      if(!ai.allowed)
        {
         ENUM_REASON ac = (ai.reason_code == RC_NONE) ? RC_AI_VETO : ai.reason_code;
         Reject(c, "ai", ac, ai.reason != "" ? ai.reason : "AI vetoed the candidate");
         return;
        }
      if(ai.used_fallback && g_cfg.ai.fallback_mode == AI_FALLBACK_REDUCE)
        {
         c.ai_risk_multiplier = MathMin(c.ai_risk_multiplier,
                                        ClampD(g_cfg.ai.fallback_reduce_factor, 0.0, 1.0));
        }
     }

   //--- 10. risk gate ------------------------------------------------
   double risk_pct = 0.0;
   double lot = 0.0;
   ENUM_REASON rreason = RC_NONE;
   string rwhy = "";
   if(!g_risk.Evaluate(spec, c, c.session_risk_scale, c.strategy_risk_scale,
                       news.risk_multiplier, c.ai_risk_multiplier,
                       risk_pct, lot, rreason, rwhy))
     {
      Reject(c, "risk", rreason, rwhy);
      return;
     }

   c.risk_pct = risk_pct;
   c.lot = lot;
   c.approved = true;
   c.reason = RC_OK;
   c.reason_text = rwhy;

   //--- 11. execution ------------------------------------------------
   ExecResult er;
   string eerr = "";
   if(!g_exec.OpenMarket(spec, c, lot, risk_pct, er, eerr))
     {
      c.approved = false;
      c.reason = (er.reason == RC_NONE) ? RC_EXEC_REJECTED : er.reason;
      c.reason_text = eerr;
      g_journal.Decision(c, "exec");
      g_journal.Rejection(c, "exec", ReasonToString(c.reason), eerr);
      if(er.retcode != 0)
         g_state.NoteRejection();
      g_journal.Event("ERROR", "EXEC", StringFormat("%s: %s", spec.name, eerr));
      MaybeSave(true);
      return;
     }

   if(g_cfg.exec.dry_run)
     {
      g_journal.Decision(c, "dry_run");
      return;
     }

   //--- 12. record the filled position ------------------------------
   PositionMeta pm;
   ResetPositionMeta(pm);
   pm.ticket             = er.position;
   pm.symbol             = spec.name;
   pm.strategy           = (int)c.strategy;
   pm.direction          = c.direction;
   pm.entry              = er.fill_price;
   pm.initial_stop       = c.stop;
   pm.initial_risk_price = MathAbs(er.fill_price - c.stop);
   pm.risk_money         = AccountInfoDouble(ACCOUNT_EQUITY) * risk_pct / 100.0;
   pm.risk_pct           = risk_pct;
   pm.sl_current         = c.stop;
   pm.tp_current         = c.target1;
   pm.best_price         = er.fill_price;
   pm.worst_price        = er.fill_price;
   pm.ai_multiplier      = c.ai_risk_multiplier;
   pm.ml_probability     = c.ml_probability;
   pm.opened_at          = TimeTradeServer();
   pm.last_update        = TimeTradeServer();
   pm.setup_id           = c.setup_id;
   pm.comment            = c.target2 > 0.0 ? StringFormat("tp2=%.5f", c.target2) : "";

   if(g_cfg.exec.verify_protection)
     {
      string perr = "";
      if(!g_exec.EnsureProtection(spec, c, pm, perr))
        {
         g_journal.Event("ERROR", "PROTECTION",
                         StringFormat("%s: %s", spec.name, perr));
        }
     }

   g_state.AddPosition(pm);
   g_state.NoteSlippage(er.slippage_ratio);
   if(!g_state.Save(eerr))
      g_journal.Event("ERROR", "STATE", "save after entry failed: " + eerr);

   g_journal.TradeOpen(pm, er.fill_price, er.volume, er.slippage_points,
                       StringFormat("attempts=%d slippage=%.3fR", er.attempts, er.slippage_ratio));
   g_journal.Decision(c, "executed");
  }

//+------------------------------------------------------------------+
//| Reject a candidate and journal it exactly once.                    |
//+------------------------------------------------------------------+
void Reject(TradeCandidate &c, const string stage, const ENUM_REASON reason,
            const string detail)
  {
   c.approved = false;
   c.reason = reason;
   c.reason_text = detail;
   //--- Derived flags keep the reason codes and the candidate fields in
   //--- agreement; no caller has to set them separately.
   if(reason == RC_NEWS_BLOCKED || reason == RC_NEWS_UNAVAILABLE)
      c.news_blocked = true;
   if(reason == RC_CORR_LIMIT)
      c.correlation_blocked = true;
   if(c.strategy_name == "")
      c.strategy_name = StrategyToString(c.strategy);
   g_journal.Decision(c, stage);
   g_journal.Rejection(c, stage, ReasonToString(reason), detail);
  }

//+------------------------------------------------------------------+
//| Unique news currencies across resolved symbols.                   |
//+------------------------------------------------------------------+
void CollectNewsCurrencies(string &out[])
  {
   ArrayResize(out, 0);
   for(int i = 0; i < g_reg.Count(); i++)
     {
      SymbolSpec *sp = g_reg.At(i);
      if(sp == NULL)
         continue;
      string parts[];
      int n = CsvSplit(sp.news_currencies, ',', parts);
      for(int k = 0; k < n; k++)
        {
         string ccy = UpperStr(TrimStr(parts[k]));
         if(ccy == "")
            continue;
         bool seen = false;
         for(int j = 0; j < ArraySize(out); j++)
            if(out[j] == ccy)
              {
               seen = true;
               break;
              }
         if(!seen)
           {
            int m = ArraySize(out);
            if(ArrayResize(out, m + 1))
               out[m] = ccy;
           }
        }
     }
  }

//+------------------------------------------------------------------+
void MaybeSave(const bool force)
  {
   if(!force && !g_state.Dirty())
      return;
   datetime now = TimeTradeServer();
   if(!force && now - g_last_save < 5)
      return;
   string err = "";
   if(g_state.Save(err))
      g_last_save = now;
   else
      LogError("state save failed: " + err);
  }
//+------------------------------------------------------------------+


