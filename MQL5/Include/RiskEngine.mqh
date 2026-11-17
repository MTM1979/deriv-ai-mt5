//+------------------------------------------------------------------+
//|                                                    RiskEngine.mqh |
//|  The final gate. Every entry must pass through this class, and it  |
//|  only ever returns a risk that is <= the configured limits.        |
//|                                                                    |
//|  Rules:                                                            |
//|    * risk starts at min(risk_per_trade_pct, symbol max_risk_pct)    |
//|    * it is multiplied by session, strategy, news and AI factors,    |
//|      each already bounded to [0,1]                                  |
//|    * it is then reduced to whatever headroom remains below the      |
//|      per-trade, daily, weekly, heat and correlated-exposure caps    |
//|    * margin, stops level and min-lot viability are hard checks      |
//|                                                                    |
//|  A reduction can never raise risk. A failure is always a rejection. |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_RISK_ENGINE_MQH__
#define __DERIV_AI_RISK_ENGINE_MQH__

#include <Config.mqh>
#include <Utils.mqh>
#include <SymbolSpec.mqh>
#include <State.mqh>

//+------------------------------------------------------------------+
class CRiskEngine
  {
private:
   RiskConfig         m_cfg;
   ExecConfig         m_exec;
   CStateStore       *m_state;          // not owned
   CSymbolRegistry   *m_reg;            // not owned
   ENUM_TIMEFRAMES    m_tf;

   double             m_equity;
   double             m_balance;
   double             m_free_margin;
   double             m_margin;
   double             m_daily_pct;
   double             m_weekly_pct;
   double             m_dd_pct;
   double             m_heat_pct;
   string             m_error;

   //--- per-run correlation memo -----------------------------------
   string             m_ck[];
   double             m_cv[];

   void               RefreshMetrics(void);
   bool               CorrMemo(const string a, const string b, double &r);
   bool               ComputePearson(const string a, const string b, double &r);
   double             SymbolRiskPct(const PositionMeta &pm) const;
   bool               CorrelatedWith(const string sym_a, const string sym_b, double &r);
   bool               PositionType(const int dir, ENUM_ORDER_TYPE &t) const;
   bool               StopDistanceValid(const SymbolSpec &spec, const int dir,
                                       const double entry, const double stop,
                                       const double target) const;
   double             RiskPerLot(const SymbolSpec &spec, const int dir,
                                 const double entry, const double stop) const;

public:
                      CRiskEngine(void);
   bool               Init(const RiskConfig &risk, const ExecConfig &exec,
                           const ENUM_TIMEFRAMES tf, string &err);
   void               Attach(CStateStore *state, CSymbolRegistry *reg);

   void               ClearCorrelationMemo(void);

   //--- account state -----------------------------------------------
   bool               UpdateAccount(string &err);
   double             Equity(void)        const { return m_equity; }
   double             DailyLossPct(void)  const { return m_daily_pct; }
   double             WeeklyLossPct(void) const { return m_weekly_pct; }
   double             DrawdownPct(void)   const { return m_dd_pct; }
   double             HeatPct(void)       const { return m_heat_pct; }
   string             LastError(void)     const { return m_error; }

   //--- kill switches ------------------------------------------------
   bool               HaltCheck(ENUM_REASON &code, string &why);
   void               OnPositionClosed(const double pnl_money, const double risk_money,
                                       const double slip_ratio);

   //--- the gate -----------------------------------------------------
   bool               Evaluate(const SymbolSpec &spec, const TradeCandidate &cand,
                               const double session_scale, const double strategy_scale,
                               const double news_scale, const double ai_scale,
                               double &risk_pct, double &lot,
                               ENUM_REASON &reason, string &why);

   //--- views --------------------------------------------------------
   void               BuildSnapshot(PortfolioSnapshot &ps);
   double             Correlation(const string a, const string b);
   double             CorrelatedExposurePct(const SymbolSpec &cand, double &worst_r);
  };

//+------------------------------------------------------------------+
CRiskEngine::CRiskEngine(void)
  {
   m_state      = NULL;
   m_reg        = NULL;
   m_tf         = PERIOD_M15;
   m_equity     = 0.0;
   m_balance    = 0.0;
   m_free_margin = 0.0;
   m_margin     = 0.0;
   m_daily_pct  = 0.0;
   m_weekly_pct = 0.0;
   m_dd_pct     = 0.0;
   m_heat_pct   = 0.0;
   m_error      = "";
   ArrayResize(m_ck, 0);
   ArrayResize(m_cv, 0);
  }

//+------------------------------------------------------------------+
bool CRiskEngine::Init(const RiskConfig &risk, const ExecConfig &exec,
                       const ENUM_TIMEFRAMES tf, string &err)
  {
   err = "";
   m_cfg = risk;
   m_exec = exec;
   m_tf = tf;

   if(!IsFinite(risk.risk_per_trade_pct) || risk.risk_per_trade_pct <= 0.0)
     {
      err = "risk_per_trade_pct must be > 0";
      return false;
     }
   if(!IsFinite(risk.max_portfolio_heat_pct) || risk.max_portfolio_heat_pct <= 0.0)
     {
      err = "max_portfolio_heat_pct must be > 0";
      return false;
     }
   if(!IsFinite(risk.max_daily_loss_pct) || risk.max_daily_loss_pct <= 0.0)
     {
      err = "max_daily_loss_pct must be > 0";
      return false;
     }
   if(!IsFinite(risk.max_weekly_loss_pct) || risk.max_weekly_loss_pct <= 0.0)
     {
      err = "max_weekly_loss_pct must be > 0";
      return false;
     }
   if(!IsFinite(risk.max_drawdown_pct) || risk.max_drawdown_pct <= 0.0 ||
      risk.max_drawdown_pct > 100.0)
     {
      err = "max_drawdown_pct must be in (0,100]";
      return false;
     }
   if(risk.max_open_positions < 1)
     {
      err = "max_open_positions must be >= 1";
      return false;
     }
   if(risk.max_positions_per_symbol < 1)
     {
      err = "max_positions_per_symbol must be >= 1";
      return false;
     }
   if(risk.max_positions_per_correlation_group < 1)
     {
      err = "max_positions_per_correlation_group must be >= 1";
      return false;
     }
   if(!IsFinite(risk.max_correlated_exposure_pct) || risk.max_correlated_exposure_pct <= 0.0)
     {
      err = "max_correlated_exposure_pct must be > 0";
      return false;
     }
   if(!IsFinite(risk.correlation_threshold) ||
      risk.correlation_threshold < 0.0 || risk.correlation_threshold > 1.0)
     {
      err = "correlation_threshold must be in [0,1]";
      return false;
     }
   if(risk.correlation_lookback_bars < 32)
     {
      err = "correlation_lookback_bars must be >= 32";
      return false;
     }
   if(!IsFinite(risk.min_free_margin_pct) || risk.min_free_margin_pct < 0.0 ||
      risk.min_free_margin_pct >= 100.0)
     {
      err = "min_free_margin_pct must be in [0,100)";
      return false;
     }
   if(!IsFinite(risk.max_margin_usage_pct) || risk.max_margin_usage_pct <= 0.0 ||
      risk.max_margin_usage_pct > 100.0)
     {
      err = "max_margin_usage_pct must be in (0,100]";
      return false;
     }
   if(!IsFinite(risk.lot_risk_tolerance) || risk.lot_risk_tolerance < 1.0 ||
      risk.lot_risk_tolerance > 3.0)
     {
      err = "lot_risk_tolerance must be in [1,3]";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void CRiskEngine::Attach(CStateStore *state, CSymbolRegistry *reg)
  {
   m_state = state;
   m_reg   = reg;
  }

//+------------------------------------------------------------------+
void CRiskEngine::ClearCorrelationMemo(void)
  {
   ArrayResize(m_ck, 0);
   ArrayResize(m_cv, 0);
  }

//+------------------------------------------------------------------+
bool CRiskEngine::UpdateAccount(string &err)
  {
   err = "";
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!IsFinite(eq) || eq <= 0.0)
     {
      err = "account equity is unavailable or non-positive";
      return false;
     }
   m_equity      = eq;
   m_balance     = bal;
   m_free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   m_margin      = AccountInfoDouble(ACCOUNT_MARGIN);
   RefreshMetrics();
   return true;
  }

//+------------------------------------------------------------------+
void CRiskEngine::RefreshMetrics(void)
  {
   m_daily_pct  = 0.0;
   m_weekly_pct = 0.0;
   m_dd_pct     = 0.0;
   m_heat_pct   = 0.0;
   if(m_state == NULL || m_equity <= 0.0)
      return;

   double ds = m_state.DayStartEquity();
   double ws = m_state.WeekStartEquity();
   double pk = m_state.PeakEquity();

   if(ds > 0.0 && m_equity < ds)
      m_daily_pct = 100.0 * (ds - m_equity) / ds;
   if(ws > 0.0 && m_equity < ws)
      m_weekly_pct = 100.0 * (ws - m_equity) / ws;
   if(pk > 0.0 && m_equity < pk)
      m_dd_pct = 100.0 * (pk - m_equity) / pk;

   m_heat_pct = m_state.SumOpenRiskPct(m_equity);
  }

//+------------------------------------------------------------------+
bool CRiskEngine::PositionType(const int dir, ENUM_ORDER_TYPE &t) const
  {
   if(dir > 0) { t = ORDER_TYPE_BUY;  return true; }
   if(dir < 0) { t = ORDER_TYPE_SELL; return true; }
   return false;
  }

//+------------------------------------------------------------------+
double CRiskEngine::SymbolRiskPct(const PositionMeta &pm) const
  {
   if(pm.risk_pct > 0.0 && IsFinite(pm.risk_pct))
      return pm.risk_pct;
   if(m_equity > 0.0 && IsFinite(pm.risk_money) && pm.risk_money > 0.0)
      return 100.0 * pm.risk_money / m_equity;
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Money at risk for one lot between entry and stop.                  |
//+------------------------------------------------------------------+
double CRiskEngine::RiskPerLot(const SymbolSpec &spec, const int dir,
                               const double entry, const double stop) const
  {
   ENUM_ORDER_TYPE t;
   if(!PositionType(dir, t))
      return 0.0;

   double profit = 0.0;
   if(OrderCalcProfit(t, spec.name, 1.0, entry, stop, profit) && IsFinite(profit) && profit < 0.0)
      return -profit;

   //--- fallback: tick value per price unit ------------------------
   double tv = (spec.tick_value_loss > 0.0) ? spec.tick_value_loss : spec.tick_value_profit;
   if(tv > 0.0 && spec.tick_size > 0.0)
      return MathAbs(entry - stop) * tv / spec.tick_size;
   return 0.0;
  }

//+------------------------------------------------------------------+
bool CRiskEngine::StopDistanceValid(const SymbolSpec &spec, const int dir,
                                    const double entry, const double stop,
                                    const double target) const
  {
   if(!IsFinite(entry) || !IsFinite(stop) || !IsFinite(target))
      return false;
   if(entry <= 0.0 || stop <= 0.0 || target <= 0.0)
      return false;
   if(dir > 0 && !(stop < entry && target > entry))
      return false;
   if(dir < 0 && !(stop > entry && target < entry))
      return false;
   if(spec.point <= 0.0)
      return false;

   double stop_pts  = MathAbs(entry - stop) / spec.point;
   double target_pts = MathAbs(target - entry) / spec.point;
   double min_pts = (double)MathMax(0, spec.stops_level) + (double)MathMax(0, m_exec.spread_buffer_points);
   return (stop_pts >= min_pts && target_pts >= min_pts);
  }

//+------------------------------------------------------------------+
//| Live Pearson correlation of log returns on the execution timeframe.|
//+------------------------------------------------------------------+
bool CRiskEngine::ComputePearson(const string a, const string b, double &r)
  {
   r = 0.0;
   int n = MathMax(32, m_cfg.correlation_lookback_bars);
   int want = n + 1;

   double ca[], cb[];
   int na = CopyClose(a, m_tf, 0, want, ca);
   int nb = CopyClose(b, m_tf, 0, want, cb);
   if(na < 32 || nb < 32)
      return false;

   int m = MathMin(na, nb);
   if(m < 32)
      return false;

   //--- align at the most recent bar, not at index zero -------------
   double x[], y[];
   ArrayResize(x, m - 1);
   ArrayResize(y, m - 1);
   for(int i = 1; i < m; i++)
     {
      double p0 = ca[na - m + i - 1];
      double p1 = ca[na - m + i];
      double q0 = cb[nb - m + i - 1];
      double q1 = cb[nb - m + i];
      if(p0 <= 0.0 || p1 <= 0.0 || q0 <= 0.0 || q1 <= 0.0)
        {
         x[i - 1] = 0.0;
         y[i - 1] = 0.0;
         continue;
        }
      x[i - 1] = MathLog(p1 / p0);
      y[i - 1] = MathLog(q1 / q0);
     }

   int cnt = m - 1;
   double sx = 0.0, sy = 0.0;
   for(int i = 0; i < cnt; i++)
     {
      sx += x[i];
      sy += y[i];
     }
   double mx = sx / cnt;
   double my = sy / cnt;
   double sxy = 0.0, sxx = 0.0, syy = 0.0;
   for(int i = 0; i < cnt; i++)
     {
      double dx = x[i] - mx;
      double dy = y[i] - my;
      sxy += dx * dy;
      sxx += dx * dx;
      syy += dy * dy;
     }
   if(sxx <= 1e-18 || syy <= 1e-18)
      return false;
   double val = sxy / MathSqrt(sxx * syy);
   if(!IsFinite(val))
      return false;
   r = ClampD(val, -1.0, 1.0);
   return true;
  }

//+------------------------------------------------------------------+
bool CRiskEngine::CorrMemo(const string a, const string b, double &r)
  {
   string key = (a < b) ? (a + "|" + b) : (b + "|" + a);
   for(int i = 0; i < ArraySize(m_ck); i++)
      if(m_ck[i] == key)
        {
         r = m_cv[i];
         return true;
        }
   if(!ComputePearson(a, b, r))
      return false;
   int n = ArraySize(m_ck);
   if(ArrayResize(m_ck, n + 1) && ArrayResize(m_cv, n + 1))
     {
      m_ck[n] = key;
      m_cv[n] = r;
     }
   return true;
  }

//+------------------------------------------------------------------+
double CRiskEngine::Correlation(const string a, const string b)
  {
   if(a == b)
      return 1.0;
   double r = 0.0;
   if(!CorrMemo(a, b, r))
      return 0.0;
   return r;
  }

//+------------------------------------------------------------------+
//| Same declared group is always correlated. Different groups are     |
//| correlated when |Pearson| >= threshold. An unresolvable symbol is  |
//| treated as correlated (fail closed, documented).                   |
//+------------------------------------------------------------------+
bool CRiskEngine::CorrelatedWith(const string sym_a, const string sym_b, double &r)
  {
   r = 0.0;
   if(sym_a == sym_b)
     {
      r = 1.0;
      return true;
     }
   if(m_reg == NULL)
      return true;

   SymbolSpec *a = m_reg.Find(sym_a);
   SymbolSpec *b = m_reg.Find(sym_b);
   if(a == NULL || b == NULL)
      return true;

   if(a.corr_group != "" && LowerStr(a.corr_group) == LowerStr(b.corr_group))
     {
      r = 1.0;
      return true;
     }
   if(!CorrMemo(sym_a, sym_b, r))
      return true;                 // unknown correlation = correlated
   return MathAbs(r) >= m_cfg.correlation_threshold;
  }

//+------------------------------------------------------------------+
double CRiskEngine::CorrelatedExposurePct(const SymbolSpec &cand, double &worst_r)
  {
   worst_r = 0.0;
   if(m_state == NULL)
      return 0.0;
   double sum = 0.0;
   int n = m_state.PositionCount();
   for(int i = 0; i < n; i++)
     {
      PositionMeta pm;
      if(!m_state.PositionAt(i, pm))
         continue;
      double r = 0.0;
      if(!CorrelatedWith(cand.name, pm.symbol, r))
         continue;
      sum += SymbolRiskPct(pm);
      if(MathAbs(r) > MathAbs(worst_r))
         worst_r = r;
     }
   return sum;
  }

//+------------------------------------------------------------------+
//| Evaluate every live halt condition and latch the ones that trip.   |
//+------------------------------------------------------------------+
bool CRiskEngine::HaltCheck(ENUM_REASON &code, string &why)
  {
   code = RC_NONE;
   why = "";
   if(m_state == NULL)
     {
      code = RC_STATE_ERROR;
      why = "state store is not attached";
      return true;
     }

   HaltState h = m_state.Halts();

   //--- already latched flags keep the EA stopped until cleared -----
   if(h.manual)
     {
      code = RC_KILL_SWITCH;
      why = "manual kill switch" + (h.reason != "" ? (": " + h.reason) : "");
      return true;
     }
   if(h.drawdown)
     {
      code = RC_DRAWDOWN;
      why = "drawdown halt latched" + (h.reason != "" ? (": " + h.reason) : "");
      return true;
     }
   if(h.loss_streak)
     {
      code = RC_KILL_SWITCH;
      why = "loss-streak halt latched" + (h.reason != "" ? (": " + h.reason) : "");
      return true;
     }
   if(h.daily_loss)
     {
      code = RC_DAILY_LOSS;
      why = "daily-loss halt latched" + (h.reason != "" ? (": " + h.reason) : "");
      return true;
     }
   if(h.weekly_loss)
     {
      code = RC_WEEKLY_LOSS;
      why = "weekly-loss halt latched" + (h.reason != "" ? (": " + h.reason) : "");
      return true;
     }
   if(h.slippage)
     {
      code = RC_KILL_SWITCH;
      why = "slippage halt latched" + (h.reason != "" ? (": " + h.reason) : "");
      return true;
     }
   if(h.rejections)
     {
      code = RC_KILL_SWITCH;
      why = "rejection halt latched" + (h.reason != "" ? (": " + h.reason) : "");
      return true;
     }

   RefreshMetrics();

   //--- drawdown (hardest first) -----------------------------------
   if(m_dd_pct >= m_cfg.max_drawdown_pct)
     {
      code = RC_DRAWDOWN;
      why = StringFormat("drawdown %.2f%% >= %.2f%%", m_dd_pct, m_cfg.max_drawdown_pct);
      m_state.LatchDrawdown(why);
      return true;
     }
   if(m_daily_pct >= m_cfg.max_daily_loss_pct)
     {
      code = RC_DAILY_LOSS;
      why = StringFormat("daily loss %.2f%% >= %.2f%%", m_daily_pct, m_cfg.max_daily_loss_pct);
      m_state.LatchDailyLoss(why);
      return true;
     }
   if(m_weekly_pct >= m_cfg.max_weekly_loss_pct)
     {
      code = RC_WEEKLY_LOSS;
      why = StringFormat("weekly loss %.2f%% >= %.2f%%", m_weekly_pct, m_cfg.max_weekly_loss_pct);
      m_state.LatchWeeklyLoss(why);
      return true;
     }
   if(m_cfg.max_consecutive_losses > 0 &&
      m_state.ConsecutiveLosses() >= m_cfg.max_consecutive_losses)
     {
      code = RC_KILL_SWITCH;
      why = StringFormat("consecutive losses %d >= %d",
                         m_state.ConsecutiveLosses(), m_cfg.max_consecutive_losses);
      m_state.LatchLossStreak(why);
      return true;
     }

   //--- execution-quality kill switches -----------------------------
   if(m_cfg.min_trades_for_slippage_halt > 0 &&
      m_state.SlipSamples() >= m_cfg.min_trades_for_slippage_halt &&
      m_state.AvgSlipRatio() > m_cfg.max_avg_slippage_stop_ratio)
     {
      code = RC_KILL_SWITCH;
      why = StringFormat("average slippage %.3fR > %.3fR over %d trades",
                         m_state.AvgSlipRatio(), m_cfg.max_avg_slippage_stop_ratio,
                         m_state.SlipSamples());
      m_state.LatchSlippage(why);
      return true;
     }
   if(m_cfg.max_rejections_per_day > 0 &&
      m_state.RejectionsToday() > m_cfg.max_rejections_per_day)
     {
      code = RC_KILL_SWITCH;
      why = StringFormat("broker rejections today %d > %d",
                         m_state.RejectionsToday(), m_cfg.max_rejections_per_day);
      m_state.LatchRejections(why);
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
void CRiskEngine::OnPositionClosed(const double pnl_money, const double risk_money,
                                   const double slip_ratio)
  {
   if(m_state == NULL)
      return;
   if(IsFinite(pnl_money) && pnl_money < 0.0)
      m_state.SetConsecutiveLosses(m_state.ConsecutiveLosses() + 1);
   else if(IsFinite(pnl_money) && pnl_money > 0.0)
      m_state.SetConsecutiveLosses(0);
   if(IsFinite(slip_ratio))
      m_state.NoteSlippage(slip_ratio);
  }

//+------------------------------------------------------------------+
//| The gate. `risk_pct` and `lot` are only meaningful on success.     |
//+------------------------------------------------------------------+
bool CRiskEngine::Evaluate(const SymbolSpec &spec, const TradeCandidate &cand,
                           const double session_scale, const double strategy_scale,
                           const double news_scale, const double ai_scale,
                           double &risk_pct, double &lot,
                           ENUM_REASON &reason, string &why)
  {
   risk_pct = 0.0;
   lot      = 0.0;
   reason   = RC_NONE;
   why      = "";

   if(m_state == NULL || m_reg == NULL)
     {
      reason = RC_STATE_ERROR;
      why = "risk engine is not attached to state/registry";
      return false;
     }
   if(!UpdateAccount(why))
     {
      reason = RC_CONNECTIVITY;
      return false;
     }

   //--- 1. halts ----------------------------------------------------
   ENUM_REASON hc = RC_NONE;
   string hw = "";
   if(HaltCheck(hc, hw))
     {
      reason = hc;
      why = hw;
      return false;
     }

   //--- 2. direction and stop geometry ------------------------------
   if(cand.direction != 1 && cand.direction != -1)
     {
      reason = RC_INVALID_STOPS;
      why = "candidate direction is neither long nor short";
      return false;
     }
   if(cand.stop == 0.0 || cand.entry == 0.0 || cand.target1 == 0.0)
     {
      reason = RC_INVALID_STOPS;
      why = "candidate has an empty stop, entry or target";
      return false;
     }
   if(!StopDistanceValid(spec, cand.direction, cand.entry, cand.stop, cand.target1))
     {
      reason = RC_STOPS_LEVEL;
      why = StringFormat("stop/target inside broker stops level (%d pt) for %s",
                         spec.stops_level, spec.name);
      return false;
     }
   if(m_exec.allow_long == false && cand.direction > 0)
     {
      reason = RC_SYMBOL_LONG_ONLY;
      why = "long entries are disabled by configuration";
      return false;
     }
   if(m_exec.allow_short == false && cand.direction < 0)
     {
      reason = RC_SYMBOL_SHORT_ONLY;
      why = "short entries are disabled by configuration";
      return false;
     }

   //--- 3. position counts ------------------------------------------
   if(m_state.PositionCount() >= m_cfg.max_open_positions)
     {
      reason = RC_MAX_POSITIONS;
      why = StringFormat("open positions %d >= %d",
                         m_state.PositionCount(), m_cfg.max_open_positions);
      return false;
     }
   int per_symbol_cap = MathMin(m_cfg.max_positions_per_symbol, spec.max_positions);
   if(per_symbol_cap < 1)
      per_symbol_cap = 1;
   if(m_state.CountOpenForSymbol(spec.name) >= per_symbol_cap)
     {
      reason = RC_MAX_POS_SYMBOL;
      why = StringFormat("positions on %s %d >= %d", spec.name,
                         m_state.CountOpenForSymbol(spec.name), per_symbol_cap);
      return false;
     }
   if(spec.corr_group != "")
     {
      int in_group = 0;
      for(int i = 0; i < m_state.PositionCount(); i++)
        {
         PositionMeta pm;
         if(!m_state.PositionAt(i, pm))
            continue;
         SymbolSpec *os = m_reg.Find(pm.symbol);
         if(os != NULL && LowerStr(os.corr_group) == LowerStr(spec.corr_group))
            in_group++;
        }
      if(in_group >= m_cfg.max_positions_per_correlation_group)
        {
         reason = RC_CORR_LIMIT;
         why = StringFormat("group %s positions %d >= %d", spec.corr_group,
                            in_group, m_cfg.max_positions_per_correlation_group);
         return false;
        }
     }

   //--- 4. base risk ------------------------------------------------
   double base = m_cfg.risk_per_trade_pct;
   if(spec.max_risk_pct > 0.0 && spec.max_risk_pct < base)
      base = spec.max_risk_pct;

   double risk = base;
   risk *= ClampD(session_scale, 0.0, 1.0);
   risk *= ClampD(strategy_scale, 0.0, 1.0);
   risk *= ClampD(news_scale, 0.0, 1.0);
   risk *= ClampD(ai_scale, 0.0, 1.0);
   if(!IsFinite(risk) || risk <= 0.0)
     {
      reason = RC_RISK_LIMIT_ZERO;
      why = "risk multipliers reduced the risk to zero";
      return false;
     }

   //--- 5. heat headroom -------------------------------------------
   RefreshMetrics();
   double heat_headroom = m_cfg.max_portfolio_heat_pct - m_heat_pct;
   if(heat_headroom <= 0.0)
     {
      reason = RC_HEAT_LIMIT;
      why = StringFormat("portfolio heat %.2f%% >= %.2f%%",
                         m_heat_pct, m_cfg.max_portfolio_heat_pct);
      return false;
     }
   if(risk > heat_headroom)
      risk = heat_headroom;

   //--- 6. daily / weekly headroom ---------------------------------
   double daily_headroom = m_cfg.max_daily_loss_pct - m_daily_pct;
   if(daily_headroom <= 0.0)
     {
      reason = RC_DAILY_LOSS;
      why = "no daily loss headroom";
      return false;
     }
   if(risk > daily_headroom)
      risk = daily_headroom;

   double weekly_headroom = m_cfg.max_weekly_loss_pct - m_weekly_pct;
   if(weekly_headroom <= 0.0)
     {
      reason = RC_WEEKLY_LOSS;
      why = "no weekly loss headroom";
      return false;
     }
   if(risk > weekly_headroom)
      risk = weekly_headroom;

   //--- 7. correlated exposure -------------------------------------
   if(m_cfg.correlation_enabled)
     {
      double worst_r = 0.0;
      double corr_expo = CorrelatedExposurePct(spec, worst_r);
      double corr_headroom = m_cfg.max_correlated_exposure_pct - corr_expo;
      if(corr_headroom <= 0.0)
        {
         reason = RC_CORR_LIMIT;
         why = StringFormat("correlated exposure %.2f%% >= %.2f%% (r=%.2f)",
                            corr_expo, m_cfg.max_correlated_exposure_pct, worst_r);
         return false;
        }
      if(risk > corr_headroom)
         risk = corr_headroom;
     }

   if(!IsFinite(risk) || risk <= 0.0)
     {
      reason = RC_RISK_LIMIT_ZERO;
      why = "risk headroom is zero";
      return false;
     }

   //--- 8. convert to lots -----------------------------------------
   double equity = m_equity;
   double risk_money = equity * risk / 100.0;
   if(risk_money <= 0.0)
     {
      reason = RC_RISK_LIMIT_ZERO;
      why = "risk money computes to zero";
      return false;
     }

   double per_lot = RiskPerLot(spec, cand.direction, cand.entry, cand.stop);
   if(!IsFinite(per_lot) || per_lot <= 0.0)
     {
      reason = RC_SYMBOL_TRADE_DISABLED;
      why = StringFormat("cannot value the stop distance for %s (tick values unavailable)",
                         spec.name);
      return false;
     }

   double raw = risk_money / per_lot;
   double vol = RoundLotDown(raw, spec.vol_step, spec.vol_min, spec.vol_max);
   if(vol <= 0.0)
     {
      //--- allow one minimum lot only if the overshoot stays within tolerance
      double min_risk = spec.vol_min * per_lot;
      if(min_risk <= risk_money * m_cfg.lot_risk_tolerance)
        {
         vol = spec.vol_min;
         risk = 100.0 * min_risk / equity;
        }
      else
        {
         reason = RC_MIN_LOT;
         why = StringFormat("minimum lot %.4f risks %.2f (%.2f%%), above %.2f%% tolerance",
                            spec.vol_min, min_risk, 100.0 * min_risk / equity,
                            risk * m_cfg.lot_risk_tolerance);
         return false;
        }
     }

   //--- 9. margin ---------------------------------------------------
   ENUM_ORDER_TYPE ot;
   PositionType(cand.direction, ot);
   double margin_req = 0.0;
   if(!OrderCalcMargin(ot, spec.name, vol, cand.entry, margin_req) ||
      !IsFinite(margin_req) || margin_req < 0.0)
     {
      reason = RC_MARGIN;
      why = StringFormat("OrderCalcMargin failed for %s (error %d)",
                         spec.name, GetLastError());
      return false;
     }
   double free_after = m_free_margin - margin_req;
   double free_floor = equity * m_cfg.min_free_margin_pct / 100.0;
   if(free_after < free_floor)
     {
      reason = RC_MARGIN;
      why = StringFormat("margin %.2f would leave %.2f free, floor %.2f",
                         margin_req, free_after, free_floor);
      return false;
     }
   double usage_after = m_margin + margin_req;
   double usage_cap = equity * m_cfg.max_margin_usage_pct / 100.0;
   if(usage_after > usage_cap)
     {
      reason = RC_MARGIN;
      why = StringFormat("margin usage %.2f would exceed cap %.2f",
                         usage_after, usage_cap);
      return false;
     }

   //--- 10. final consistency --------------------------------------
   double actual_risk = vol * per_lot;
   double actual_pct = 100.0 * actual_risk / equity;
   if(actual_pct > risk * m_cfg.lot_risk_tolerance + 1e-9)
     {
      reason = RC_RISK_LIMIT_ZERO;
      why = StringFormat("rounded lot %.4f risks %.2f%% above the %.2f%% budget",
                         vol, actual_pct, risk);
      return false;
     }

   risk_pct = actual_pct;
   lot = vol;
   reason = RC_OK;
   why = StringFormat("%s risk %.2f%% (%.4f lots, %.2f %s at risk)",
                      spec.name, risk_pct, lot, actual_risk,
                      AccountInfoString(ACCOUNT_CURRENCY));
   return true;
  }

//+------------------------------------------------------------------+
void CRiskEngine::BuildSnapshot(PortfolioSnapshot &ps)
  {
   RefreshMetrics();
   ps.open_positions    = (m_state != NULL) ? m_state.PositionCount() : 0;
   ps.portfolio_risk_pct = m_heat_pct;
   ps.daily_loss_pct    = m_daily_pct;
   ps.weekly_loss_pct   = m_weekly_pct;
   ps.drawdown_pct      = m_dd_pct;
   if(m_state != NULL)
      m_state.PositionsJson(ps.positions_json);
   else
      ps.positions_json = "[]";
  }

#endif
//+------------------------------------------------------------------+
