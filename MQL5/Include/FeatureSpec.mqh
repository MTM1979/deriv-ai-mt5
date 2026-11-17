//+------------------------------------------------------------------+
//|                                                   FeatureSpec.mqh |
//|  GENERATED FROM python/features/spec.py - DO NOT EDIT BY HAND.     |
//|  Regenerate with:  python -m features.spec --write-mqh            |
//|                                                                  |
//|  The order and meaning of these features is a contract between    |
//|  the Python training pipeline and OnnxModel.mqh. Model metadata   |
//|  is rejected at load time when its feature_order differs.         |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_FEATURESPEC_MQH__
#define __DERIV_AI_FEATURESPEC_MQH__

#define FEATURE_COUNT 30

string FEATURE_NAMES[FEATURE_COUNT] =
  {
   "ret_1",
   "ret_3",
   "ret_12",
   "ema_fast_rel",
   "ema_mid_rel",
   "ema_slow_rel",
   "ema_slow_slope",
   "rsi_norm",
   "macd_hist_norm",
   "macd_accel",
   "atr_percentile",
   "bb_width_atr",
   "bb_position",
   "adx_norm",
   "di_diff",
   "dist_session_high",
   "dist_session_low",
   "dist_vwap",
   "dist_day_high",
   "range_expansion",
   "htf_trend",
   "htf_rsi_norm",
   "minutes_since_open",
   "minutes_to_event",
   "event_impact",
   "spread_ratio",
   "volume_ratio",
   "trend_strength",
   "sweep_flag",
   "direction"
  };

#endif
//+------------------------------------------------------------------+
