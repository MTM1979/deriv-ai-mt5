//+------------------------------------------------------------------+
//|                                                  SignalEngine.mqh |
//|  Four strategy modules operating on the normalized snapshot:      |
//|    A. trend continuation                                            |
//|    B. opening-range breakout                                       |
//|    C. liquidity-sweep reversal                                     |
//|    D. regime-limited mean reversion                                |
//|                                                                  |
//|  The engine emits at most one candidate per symbol per bar, in     |
//|  priority order of technical score. It never sizes or executes.    |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_SIGNALENGINE_MQH__
#define __DERIV_AI_SIGNALENGINE_MQH__

#include <Config.mqh>
#include <Utils.mqh>
#include <SymbolSpec.mqh>
#include <Sessions.mqh>
#include <Indicators.mqh>
#include <NewsCalendar.mqh>

double MinTargetGap(const SymbolSpec &spec);

class CSignalEngine
  {
private:
   SignalConfig       m_cfg;
   string             m_cooldown_key[];
   datetime           m_cooldown_time[];

   bool               CooldownActive(const string symbol, const ENUM_STRATEGY s, const datetime now);
   void               MarkSignal(const string symbol, const ENUM_STRATEGY s, const datetime now);
   double             WeightedScore(const TradeCandidate &c);
   bool               NormalizeAndScore(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                        const CSessionEngine &sess, const NewsContext &news,
                                        const ENUM_REGIME regime, double rr1, double rr2,
                                        TradeCandidate &c);
   ENUM_REGIME        DetectRegime(const IndicatorSnapshot &snap);
   bool               TrendAllowed(const ENUM_REGIME regime, const int dir);
   bool               SweepAllowed(const IndicatorSnapshot &snap, const ENUM_REGIME regime);
   bool               MeanRevAllowed(const IndicatorSnapshot &snap, const ENUM_REGIME regime);
   bool               OrbAllowed(const ENUM_REGIME regime);
   bool               BuildTrend(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                 const CSessionEngine &sess, const NewsContext &news,
                                 const ENUM_REGIME regime, TradeCandidate &c);
   bool               BuildOrb(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                               const CSessionEngine &sess, CIndicatorHub &hub,
                               const NewsContext &news, const ENUM_REGIME regime, TradeCandidate &c);
   bool               BuildSweep(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                 const CSessionEngine &sess, const NewsContext &news,
                                 const ENUM_REGIME regime, TradeCandidate &c);
   bool               BuildMeanRev(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                   const CSessionEngine &sess, const NewsContext &news,
                                   const ENUM_REGIME regime, TradeCandidate &c);

public:
                     CSignalEngine(void);
   bool               Init(const SignalConfig &cfg);
   bool               Generate(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                               const CSessionEngine &sess, CIndicatorHub &hub,
                               const NewsContext &news, TradeCandidate &cand,
                               ENUM_REASON &reason);
  };

//+------------------------------------------------------------------+
CSignalEngine::CSignalEngine(void)
  {
   ArrayResize(m_cooldown_key, 0);
   ArrayResize(m_cooldown_time, 0);
  }

bool CSignalEngine::Init(const SignalConfig &cfg)
  {
   m_cfg = cfg;
   if(cfg.min_technical_score < 0.0 || cfg.min_technical_score > 100.0)
      return false;
   if(cfg.score_weight_trend + cfg.score_weight_momentum + cfg.score_weight_volatility +
      cfg.score_weight_location + cfg.score_weight_structure <= 0.0)
      return false;
   return true;
  }

bool CSignalEngine::CooldownActive(const string symbol, const ENUM_STRATEGY s, const datetime now)
  {
   if(m_cfg.cooldown_minutes <= 0)
      return false;
   string key = StringFormat("%s|%d", symbol, (int)s);
   for(int i = 0; i < ArraySize(m_cooldown_key); i++)
      if(m_cooldown_key[i] == key)
        {
         if(now - m_cooldown_time[i] < m_cfg.cooldown_minutes * 60)
            return true;
         return false;
        }
   return false;
  }

void CSignalEngine::MarkSignal(const string symbol, const ENUM_STRATEGY s, const datetime now)
  {
   string key = StringFormat("%s|%d", symbol, (int)s);
   for(int i = 0; i < ArraySize(m_cooldown_key); i++)
      if(m_cooldown_key[i] == key)
        {
         m_cooldown_time[i] = now;
         return;
        }
   int n = ArraySize(m_cooldown_key);
   ArrayResize(m_cooldown_key, n + 1);
   ArrayResize(m_cooldown_time, n + 1);
   m_cooldown_key[n] = key;
   m_cooldown_time[n] = now;
  }

double CSignalEngine::WeightedScore(const TradeCandidate &c)
  {
   double w = m_cfg.score_weight_trend + m_cfg.score_weight_momentum +
              m_cfg.score_weight_volatility + m_cfg.score_weight_location +
              m_cfg.score_weight_structure;
   if(w <= 0.0)
      return 0.0;
   double s = c.sc_trend * m_cfg.score_weight_trend +
              c.sc_momentum * m_cfg.score_weight_momentum +
              c.sc_volatility * m_cfg.score_weight_volatility +
              c.sc_location * m_cfg.score_weight_location +
              c.sc_structure * m_cfg.score_weight_structure;
   return ClampD(s / w, 0.0, 100.0);
  }

//+------------------------------------------------------------------+
ENUM_REGIME CSignalEngine::DetectRegime(const IndicatorSnapshot &snap)
  {
   double gap = SafeDiv(MathAbs(snap.ema_fast - snap.ema_slow), snap.atr, 0.0);
   bool up = (snap.ema_fast > snap.ema_mid && snap.ema_mid > snap.ema_slow &&
              snap.htf_close > snap.htf_ema_slow && snap.ema_slow_slope > 0.0);
   bool down = (snap.ema_fast < snap.ema_mid && snap.ema_mid < snap.ema_slow &&
                snap.htf_close < snap.htf_ema_slow && snap.ema_slow_slope < 0.0);
   if(snap.adx >= m_cfg.adx_trend_min && gap >= 0.45)
     {
      if(up)
         return REGIME_TREND_UP;
      if(down)
         return REGIME_TREND_DOWN;
     }
   if(snap.atr_percentile >= 0.85 && snap.adx < m_cfg.adx_trend_min)
      return REGIME_EXPANSION;
   if(snap.adx <= m_cfg.adx_range_max)
      return REGIME_RANGE;
   return REGIME_CHOP;
  }

bool CSignalEngine::TrendAllowed(const ENUM_REGIME regime, const int dir)
  {
   if(dir > 0)
      return (regime == REGIME_TREND_UP || regime == REGIME_EXPANSION);
   if(dir < 0)
      return (regime == REGIME_TREND_DOWN || regime == REGIME_EXPANSION);
   return false;
  }

bool CSignalEngine::SweepAllowed(const IndicatorSnapshot &snap, const ENUM_REGIME regime)
  {
   if(regime == REGIME_CHOP && snap.adx > m_cfg.sweep_max_adx)
      return false;
   return snap.adx <= m_cfg.sweep_max_adx;
  }

bool CSignalEngine::MeanRevAllowed(const IndicatorSnapshot &snap, const ENUM_REGIME regime)
  {
   if(regime != REGIME_RANGE && regime != REGIME_EXPANSION && regime != REGIME_CHOP)
      return false;
   return (snap.adx <= m_cfg.adx_range_max);
  }

bool CSignalEngine::OrbAllowed(const ENUM_REGIME regime)
  {
   return (regime != REGIME_CHOP);
  }

bool CSignalEngine::NormalizeAndScore(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                      const CSessionEngine &sess, const NewsContext &news,
                                      const ENUM_REGIME regime, double rr1, double rr2,
                                      TradeCandidate &c)
  {
   if(c.direction == 0 || c.entry <= 0.0 || snap.point <= 0.0)
      return false;

   c.symbol = spec.name;
   c.session = sess.StateName();
   c.regime = RegimeToString(regime);
   c.strategy_name = StrategyToString(c.strategy);
   c.atr = snap.atr;
   c.spread_points = (snap.ask - snap.bid) / snap.point;
   c.bar_time = snap.bar_time;
   c.news_blocked = news.blackout;
   c.minutes_to_event = news.minutes_to_next;
   c.event_impact = news.next_impact;
   c.ml_threshold_add = (news.risk_multiplier < 1.0) ? m_cfg.medium_news_threshold_add : 0.0;
   c.minutes_since_open = sess.MinutesSinceSessionStart();
   c.session_risk_scale = sess.RiskScale();
   c.strategy_risk_scale = 1.0;
   if(c.strategy == STRAT_SWEEP)
      c.strategy_risk_scale = m_cfg.risk_scale_sweep;
   else if(c.strategy == STRAT_MEANREV)
      c.strategy_risk_scale = m_cfg.risk_scale_meanrev;

   double min_dist = (MathMax(spec.stops_level, 0) + 2) * spec.point +
                     MathMax(c.spread_points, 1.0) * spec.point;
   if(!IsFinite(min_dist) || min_dist <= 0.0)
      min_dist = 2.0 * spec.point;

   if(c.direction > 0)
     {
      if(c.stop >= c.entry)
         c.stop = c.entry - min_dist;
      if(c.entry - c.stop < min_dist)
         c.stop = c.entry - min_dist;
     }
   else
     {
      if(c.stop <= c.entry)
         c.stop = c.entry + min_dist;
      if(c.stop - c.entry < min_dist)
         c.stop = c.entry + min_dist;
     }
   c.stop = RoundToTick(c.stop, spec.tick_size);
   double risk_price = MathAbs(c.entry - c.stop);
   if(risk_price <= 0.0 || !IsFinite(risk_price))
      return false;

   if(!IsFinite(rr1) || rr1 <= 0.0)
      rr1 = 1.5;
   if(!IsFinite(rr2) || rr2 <= 0.0)
      rr2 = 2.5;
   if(c.direction > 0)
     {
      c.target1 = RoundToTick(c.entry + rr1 * risk_price, spec.tick_size);
      c.target2 = RoundToTick(c.entry + rr2 * risk_price, spec.tick_size);
      if(c.target2 <= c.target1)
         c.target2 = c.target1 + MinTargetGap(spec);
     }
   else
     {
      c.target1 = RoundToTick(c.entry - rr1 * risk_price, spec.tick_size);
      c.target2 = RoundToTick(c.entry - rr2 * risk_price, spec.tick_size);
      if(c.target2 >= c.target1)
         c.target2 = c.target1 - MinTargetGap(spec);
     }
   c.initial_risk_price = risk_price;

   c.sc_trend      = ClampD(c.sc_trend, 0.0, 100.0);
   c.sc_momentum   = ClampD(c.sc_momentum, 0.0, 100.0);
   c.sc_volatility = ClampD(c.sc_volatility, 0.0, 100.0);
   c.sc_location   = ClampD(c.sc_location, 0.0, 100.0);
   c.sc_structure  = ClampD(c.sc_structure, 0.0, 100.0);
   c.technical_score = WeightedScore(c);
   c.setup_id = StringFormat("%s-%s-%s-%d", spec.name, StrategyToString(c.strategy),
                             RegimeToString(regime), (int)snap.bar_time);
   return true;
  }

double MinTargetGap(const SymbolSpec &spec)
  {
   double gap = (MathMax(spec.stops_level, 1) + 1) * spec.point;
   return (gap > 0.0) ? gap : spec.point;
  }

//+------------------------------------------------------------------+
//| Reset every candidate field. MQL5 does not zero local structs.    |
//+------------------------------------------------------------------+
void ResetCandidate(TradeCandidate &c)
  {
   c.symbol = "";
   c.direction = 0;
   c.strategy = STRAT_NONE;
   c.strategy_name = "";
   c.entry = 0.0;
   c.stop = 0.0;
   c.target1 = 0.0;
   c.target2 = 0.0;
   c.atr = 0.0;
   c.technical_score = 0.0;
   c.ml_probability = 0.0;
   c.ai_risk_multiplier = 1.0;
   c.regime = "";
   c.session = "";
   c.news_blocked = false;
   c.correlation_blocked = false;
   c.approved = false;
   c.reason = RC_NONE;
   c.reason_text = "";
   c.risk_pct = 0.0;
   c.lot = 0.0;
   c.spread_points = 0.0;
   c.bar_time = 0;
   c.minutes_to_event = 9999;
   c.event_impact = 0;
   c.ml_threshold_add = 0.0;
   c.sc_trend = 0.0;
   c.sc_momentum = 0.0;
   c.sc_volatility = 0.0;
   c.sc_location = 0.0;
   c.sc_structure = 0.0;
   c.initial_risk_price = 0.0;
   c.orb_high = 0.0;
   c.orb_low = 0.0;
   c.swept_level = 0.0;
   c.minutes_since_open = 0;
   c.session_risk_scale = 1.0;
   c.strategy_risk_scale = 1.0;
   c.setup_id = "";
   c.notes = "";
  }

//+------------------------------------------------------------------+
//| A. Trend continuation: aligned trend, pullback into the fast EMA,  |
//|    momentum reclaim on the closed bar.                             |
//+------------------------------------------------------------------+
bool CSignalEngine::BuildTrend(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                               const CSessionEngine &sess, const NewsContext &news,
                               const ENUM_REGIME regime, TradeCandidate &c)
  {
   if(!m_cfg.enable_trend)
      return false;
   if((spec.strategies_mask & (1 << STRAT_TREND)) == 0)
      return false;
   if(snap.atr_percentile < m_cfg.atr_percentile_min_trend)
      return false;
   if(snap.adx < m_cfg.adx_trend_min)
      return false;

   bool ema_up = (snap.ema_fast > snap.ema_mid && snap.ema_mid > snap.ema_slow);
   bool ema_dn = (snap.ema_fast < snap.ema_mid && snap.ema_mid < snap.ema_slow);
   bool htf_up = (snap.htf_close > snap.htf_ema_slow && snap.htf_ema_fast > snap.htf_ema_slow);
   bool htf_dn = (snap.htf_close < snap.htf_ema_slow && snap.htf_ema_fast < snap.htf_ema_slow);

   int dir = 0;
   if(ema_up && (!m_cfg.require_htf_alignment_trend || htf_up) &&
      TrendAllowed(regime, 1))
      dir = 1;
   else if(ema_dn && (!m_cfg.require_htf_alignment_trend || htf_dn) &&
           TrendAllowed(regime, -1))
      dir = -1;
   else
      return false;

   double atr = snap.atr;
   double entry = (dir > 0) ? snap.ask : snap.bid;
   double touched = MathMin(MathMin(snap.last_low[0], snap.last_low[1]), snap.last_low[2]);
   double touched_hi = MathMax(MathMax(snap.last_high[0], snap.last_high[1]), snap.last_high[2]);

   if(dir > 0)
     {
      bool pullback = (touched <= snap.ema_fast + 0.30 * atr);
      bool reclaim = (snap.close > snap.ema_fast && snap.close > snap.last_high[1]);
      bool momentum = (snap.macd_hist > 0.0 && snap.rsi > 50.0 && snap.rsi < 80.0);
      if(!(pullback && reclaim && momentum))
         return false;
      c.stop = MathMin(snap.swing_low, snap.close - m_cfg.atr_stop_mult_trend * atr) - 0.08 * atr;
     }
   else
     {
      bool pullback = (touched_hi >= snap.ema_fast - 0.30 * atr);
      bool reclaim = (snap.close < snap.ema_fast && snap.close < snap.last_low[1]);
      bool momentum = (snap.macd_hist < 0.0 && snap.rsi < 50.0 && snap.rsi > 20.0);
      if(!(pullback && reclaim && momentum))
         return false;
      c.stop = MathMax(snap.swing_high, snap.close + m_cfg.atr_stop_mult_trend * atr) + 0.08 * atr;
     }

   c.direction = dir;
   c.strategy = STRAT_TREND;
   c.entry = entry;
   c.sc_trend = 50.0 * ((dir > 0) ? (ema_up ? 1.0 : 0.0) : (ema_dn ? 1.0 : 0.0)) +
                30.0 * ((dir > 0) ? (htf_up ? 1.0 : 0.0) : (htf_dn ? 1.0 : 0.0)) +
                20.0 * ClampD(MathAbs(snap.ema_slow_slope) / 0.5, 0.0, 1.0);
   double mom_center = (dir > 0) ? (snap.rsi - 50.0) : (50.0 - snap.rsi);
   double hist_signed = (dir > 0) ? snap.macd_hist : -snap.macd_hist;
   c.sc_momentum = 50.0 + 25.0 * ClampD(mom_center / 20.0, -1.0, 1.0) +
                   25.0 * ClampD(hist_signed / (0.5 * atr), -1.0, 1.0);
   c.sc_volatility = 100.0 - MathAbs(snap.atr_percentile - 0.60) * 200.0;
   double dist = MathAbs(snap.close - snap.ema_fast) / atr;
   c.sc_location = 100.0 - ClampD(dist, 0.0, 1.5) * 66.0;
   c.sc_structure = (dir > 0)
                    ? 100.0 * ((snap.close > snap.swing_high) ? 1.0 : 0.6)
                    : 100.0 * ((snap.close < snap.swing_low) ? 1.0 : 0.6);

   if(!NormalizeAndScore(spec, snap, sess, news, regime,
                         m_cfg.rr_target1_trend, m_cfg.rr_target2_trend, c))
      return false;
   c.sc_trend = ClampD(c.sc_trend, 0.0, 100.0);
   c.sc_momentum = ClampD(c.sc_momentum, 0.0, 100.0);
   return true;
  }

//+------------------------------------------------------------------+
//| B. Opening-range breakout with fresh-break or retest confirmation. |
//+------------------------------------------------------------------+
bool CSignalEngine::BuildOrb(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                             const CSessionEngine &sess, CIndicatorHub &hub,
                             const NewsContext &news, const ENUM_REGIME regime, TradeCandidate &c)
  {
   if(!m_cfg.enable_orb)
      return false;
   if((spec.strategies_mask & (1 << STRAT_ORB)) == 0)
      return false;
   if(!OrbAllowed(regime))
      return false;
   if(!sess.IsAnyOpenWindow())
      return false;
   if(snap.atr_percentile < m_cfg.atr_percentile_min_orb)
      return false;

   int mins = sess.MinutesSinceSessionStart();
   if(mins < sess.OpeningRangeMinutes())
      return false;
   if(mins > sess.OpeningRangeMinutes() + m_cfg.orb_entry_window_minutes)
      return false;

   datetime start = sess.SessionStartUtc();
   datetime or_end = start + sess.OpeningRangeMinutes() * 60;
   double hi = 0.0, lo = 0.0;
   int bars = 0;
   if(!hub.OpeningRange(spec.name, start, or_end, hi, lo, bars))
      return false;
   if(bars < 2 || hi <= lo)
      return false;
   double rng = hi - lo;
   double rng_atr = SafeDiv(rng, snap.atr, 0.0);
   if(rng_atr < m_cfg.orb_min_range_atr || rng_atr > m_cfg.orb_max_range_atr)
      return false;

   double buf = m_cfg.orb_buffer_atr * snap.atr;
   bool fresh_long = (snap.last_close[0] > hi + buf && snap.last_close[1] <= hi + buf);
   bool retest_long = (snap.last_close[0] > hi && snap.last_low[0] <= hi + buf &&
                       snap.last_close[1] > hi);
   bool fresh_short = (snap.last_close[0] < lo - buf && snap.last_close[1] >= lo - buf);
   bool retest_short = (snap.last_close[0] < lo && snap.last_high[0] >= lo - buf &&
                        snap.last_close[1] < lo);

   int dir = 0;
   if(fresh_long || retest_long)
      dir = 1;
   else if(fresh_short || retest_short)
      dir = -1;
   else
      return false;

   double entry = (dir > 0) ? snap.ask : snap.bid;
   if(dir > 0)
      c.stop = MathMax(entry - 1.8 * snap.atr,
                       MathMin(lo, entry - m_cfg.atr_stop_mult_orb * snap.atr) - 0.05 * snap.atr);
   else
      c.stop = MathMin(entry + 1.8 * snap.atr,
                       MathMax(hi, entry + m_cfg.atr_stop_mult_orb * snap.atr) + 0.05 * snap.atr);

   c.direction = dir;
   c.strategy = STRAT_ORB;
   c.entry = entry;
   c.orb_high = hi;
   c.orb_low = lo;

   double break_dist = (dir > 0) ? (snap.last_close[0] - hi) : (lo - snap.last_close[0]);
   c.sc_trend = 100.0 * ClampD(break_dist / (0.8 * snap.atr), 0.0, 1.0);
   c.sc_momentum = 50.0 + 50.0 * ClampD((snap.macd_hist * dir) / (0.5 * snap.atr), -1.0, 1.0);
   c.sc_volatility = 100.0 * ClampD(rng_atr / MathMax(0.1, m_cfg.orb_max_range_atr), 0.0, 1.0);
   double mid = (hi + lo) / 2.0;
   c.sc_location = 100.0 * ClampD((snap.close - lo) / MathMax(rng, snap.point), 0.0, 1.0);
   if(dir < 0)
      c.sc_location = 100.0 - c.sc_location;
   c.sc_structure = (retest_long || retest_short) ? 85.0 : 65.0;
   if(rng_atr > 1.0)
      c.sc_structure += 10.0;

   if(!NormalizeAndScore(spec, snap, sess, news, regime,
                         m_cfg.rr_target1_orb, m_cfg.rr_target2_orb, c))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| C. Liquidity-sweep reversal of the prior day extreme.              |
//+------------------------------------------------------------------+
bool CSignalEngine::BuildSweep(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                               const CSessionEngine &sess, const NewsContext &news,
                               const ENUM_REGIME regime, TradeCandidate &c)
  {
   if(!m_cfg.enable_sweep)
      return false;
   if((spec.strategies_mask & (1 << STRAT_SWEEP)) == 0)
      return false;
   if(!SweepAllowed(snap, regime))
      return false;
   if(snap.atr_percentile < m_cfg.atr_percentile_min_sweep)
      return false;
   if(snap.prior_day_high <= 0.0 || snap.prior_day_low <= 0.0)
      return false;

   int dir = 0;
   double level = 0.0;
   double wick = 0.0;
   if(snap.sweep_high)
     {
      level = snap.swept_high_level;
      wick = snap.last_high[0] - level;
      double range = MathMax(snap.last_high[0] - snap.last_low[0], snap.point);
      double close_pos = (snap.last_close[0] - snap.last_low[0]) / range;
      bool rejection = (close_pos < 0.45 && snap.last_close[0] < snap.last_open[0]);
      bool shift = (snap.macd_hist < snap.macd_hist_prev && snap.rsi < 62.0);
      if(wick >= m_cfg.sweep_min_wick_atr * snap.atr && rejection && shift)
         dir = -1;
     }
   if(dir == 0 && snap.sweep_low)
     {
      level = snap.swept_low_level;
      wick = level - snap.last_low[0];
      double range = MathMax(snap.last_high[0] - snap.last_low[0], snap.point);
      double close_pos = (snap.last_close[0] - snap.last_low[0]) / range;
      bool rejection = (close_pos > 0.55 && snap.last_close[0] > snap.last_open[0]);
      bool shift = (snap.macd_hist > snap.macd_hist_prev && snap.rsi > 38.0);
      if(wick >= m_cfg.sweep_min_wick_atr * snap.atr && rejection && shift)
         dir = 1;
     }
   if(dir == 0)
      return false;
   // Avoid fighting an established higher-timeframe trend.
   if(dir < 0 && regime == REGIME_TREND_UP && snap.adx >= m_cfg.adx_trend_min)
      return false;
   if(dir > 0 && regime == REGIME_TREND_DOWN && snap.adx >= m_cfg.adx_trend_min)
      return false;

   double entry = (dir > 0) ? snap.ask : snap.bid;
   if(dir > 0)
      c.stop = MathMin(snap.last_low[0], level) - m_cfg.sweep_buffer_atr * snap.atr;
   else
      c.stop = MathMax(snap.last_high[0], level) + m_cfg.sweep_buffer_atr * snap.atr;

   c.direction = dir;
   c.strategy = STRAT_SWEEP;
   c.entry = entry;
   c.swept_level = level;

   c.sc_trend = 35.0;   // counter-trend by design; regime gate suppresses strong trends
   double range = MathMax(snap.last_high[0] - snap.last_low[0], snap.point);
   double close_pos = (snap.last_close[0] - snap.last_low[0]) / range;
   c.sc_momentum = (dir > 0) ? 100.0 * close_pos : 100.0 * (1.0 - close_pos);
   c.sc_volatility = 100.0 * ClampD(wick / MathMax(0.1, 1.2 * snap.atr), 0.0, 1.0);
   c.sc_location = 100.0 - 60.0 * ClampD(MathAbs(snap.close - level) / (1.5 * snap.atr), 0.0, 1.0);
   c.sc_structure = (snap.sweep_high || snap.sweep_low) ? 90.0 : 50.0;

   if(!NormalizeAndScore(spec, snap, sess, news, regime,
                         m_cfg.rr_target1_sweep, m_cfg.rr_target2_sweep, c))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| D. Regime-limited mean reversion.                                  |
//+------------------------------------------------------------------+
bool CSignalEngine::BuildMeanRev(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                 const CSessionEngine &sess, const NewsContext &news,
                                 const ENUM_REGIME regime, TradeCandidate &c)
  {
   if(!m_cfg.enable_meanrev)
      return false;
   if((spec.strategies_mask & (1 << STRAT_MEANREV)) == 0)
      return false;
   if(!MeanRevAllowed(snap, regime))
      return false;
   if(snap.atr_percentile < m_cfg.atr_percentile_min_meanrev ||
      snap.atr_percentile > m_cfg.atr_percentile_max_meanrev)
      return false;

   int dir = 0;
   if(snap.close > snap.bb_upper && snap.rsi > 70.0 &&
      snap.last_high[0] <= snap.last_high[1] + 0.05 * snap.atr &&
      snap.macd_hist < snap.macd_hist_prev)
      dir = -1;
   else if(snap.close < snap.bb_lower && snap.rsi < 30.0 &&
           snap.last_low[0] >= snap.last_low[1] - 0.05 * snap.atr &&
           snap.macd_hist > snap.macd_hist_prev)
      dir = 1;
   if(dir == 0)
      return false;

   double entry = (dir > 0) ? snap.ask : snap.bid;
   if(dir > 0)
      c.stop = MathMin(snap.last_low[0], snap.bb_lower) - m_cfg.meanrev_stop_atr * snap.atr;
   else
      c.stop = MathMax(snap.last_high[0], snap.bb_upper) + m_cfg.meanrev_stop_atr * snap.atr;
   // Enforce a minimum stop of one ATR so the target geometry stays sane.
   if(dir > 0 && entry - c.stop < snap.atr)
      c.stop = entry - snap.atr;
   if(dir < 0 && c.stop - entry < snap.atr)
      c.stop = entry + snap.atr;

   c.direction = dir;
   c.strategy = STRAT_MEANREV;
   c.entry = entry;

   double risk = MathAbs(entry - c.stop);
   double target_mid = snap.bb_middle;
   //--- The structural target is preferred; the configured R multiple is
   //--- the fallback when the band is too close to the entry.
   double structure_rr1 = ((target_mid - entry) * dir) / MathMax(risk, snap.point);
   double rr1 = (structure_rr1 >= 0.8) ? structure_rr1 : m_cfg.rr_target1_meanrev;
   rr1 = ClampD(rr1, 0.5, 3.0);
   double target_far = snap.vwap;
   double structure_rr2 = ((target_far - entry) * dir) / MathMax(risk, snap.point);
   double rr2 = (structure_rr2 > rr1) ? structure_rr2 : m_cfg.rr_target2_meanrev;
   rr2 = ClampD(rr2, rr1 + 0.3, 4.0);

   double dev = (dir > 0) ? (snap.bb_lower - snap.close) : (snap.close - snap.bb_upper);
   c.sc_trend = 40.0;
   c.sc_momentum = (dir > 0) ? (100.0 - snap.rsi) : snap.rsi;
   c.sc_volatility = 100.0 * ClampD(snap.atr_percentile, 0.0, 1.0);
   c.sc_location = 100.0 * ClampD(dev / MathMax(0.25 * snap.atr, snap.point), 0.0, 1.0);
   c.sc_structure = 80.0;

   if(!NormalizeAndScore(spec, snap, sess, news, regime, rr1, rr2, c))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Entry point. Evaluates enabled strategies, returns the strongest   |
//| candidate that passes technical gates.                            |
//+------------------------------------------------------------------+
bool CSignalEngine::Generate(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                             const CSessionEngine &sess, CIndicatorHub &hub,
                             const NewsContext &news, TradeCandidate &cand,
                             ENUM_REASON &reason)
  {
   reason = RC_NO_SETUP;
   if(!snap.valid)
     {
      reason = RC_NO_DATA;
      return false;
     }
   if(!sess.TradingAllowed() || !ProfileAllowsSession(spec.session_profile, sess.State()))
     {
      reason = RC_SESSION_BLOCKED;
      return false;
     }
   if(spec.min_atr_points > 0 && snap.atr_points < spec.min_atr_points)
     {
      reason = RC_ATR_TOO_SMALL;
      return false;
     }

   ENUM_REGIME regime = DetectRegime(snap);
   TradeCandidate best;
   ResetCandidate(best);
   bool have = false;

   for(int si = (int)STRAT_TREND; si <= (int)STRAT_MEANREV; si++)
     {
      ENUM_STRATEGY s = (ENUM_STRATEGY)si;
      if((spec.strategies_mask & (1 << s)) == 0)
         continue;
      if(CooldownActive(spec.name, s, snap.bar_time))
         continue;

      TradeCandidate c;
      ResetCandidate(c);
      bool ok = false;
      switch(s)
        {
         case STRAT_TREND:   ok = BuildTrend(spec, snap, sess, news, regime, c);   break;
         case STRAT_ORB:     ok = BuildOrb(spec, snap, sess, hub, news, regime, c); break;
         case STRAT_SWEEP:   ok = BuildSweep(spec, snap, sess, news, regime, c);   break;
         case STRAT_MEANREV: ok = BuildMeanRev(spec, snap, sess, news, regime, c); break;
         default:            ok = false; break;
        }
      if(!ok)
         continue;
      if(!have || c.technical_score > best.technical_score)
        {
         best = c;
         have = true;
        }
     }

   if(!have)
     {
      reason = RC_NO_SETUP;
      return false;
     }
   if(best.technical_score < m_cfg.min_technical_score)
     {
      reason = RC_SCORE_LOW;
      return false;
     }

   best.reason = RC_OK;
   best.reason_text = StringFormat("%s %s score %.1f regime %s", best.symbol,
                                   best.strategy_name, best.technical_score, best.regime);
   MarkSignal(spec.name, best.strategy, snap.bar_time);
   cand = best;
   reason = RC_OK;
   return true;
  }

#endif
//+------------------------------------------------------------------+
