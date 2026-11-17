//+------------------------------------------------------------------+
//|                                                   Execution.mqh  |
//|  Broker boundary. Owns order requests, retcode classification,     |
//|  fill verification, protection repair, trailing/breakeven/partial  |
//|  management and reconciliation after a restart.                    |
//|                                                                    |
//|  Nothing here decides whether a trade is allowed; that is the risk |
//|  engine's job. This module only executes an approved instruction   |
//|  and reports exactly what happened.                               |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_EXECUTION_MQH__
#define __DERIV_AI_EXECUTION_MQH__

#include <Config.mqh>
#include <Utils.mqh>
#include <SymbolSpec.mqh>
#include <State.mqh>
#include <Journal.mqh>

//+------------------------------------------------------------------+
struct ExecResult
  {
   bool           ok;
   bool           retryable;
   ulong          order;
   ulong          deal;
   ulong          position;
   double         requested_price;
   double         fill_price;
   double         volume;
   double         slippage_points;
   double         slippage_ratio;      // slippage in R
   int            retcode;
   int            attempts;
   string         message;
   ENUM_REASON    reason;
  };

//+------------------------------------------------------------------+
struct ManageOutcome
  {
   bool           modified;
   bool           partial;
   bool           closed;
   double         new_sl;
   double         close_volume;
   string         note;
   ENUM_REASON    reason;
  };

//+------------------------------------------------------------------+
//| Explicit resets. ZeroMemory is not used on structs that own       |
//| strings; assigning every field keeps ownership unambiguous.       |
//+------------------------------------------------------------------+
void ResetExecResult(ExecResult &o)
  {
   o.ok = false;
   o.retryable = false;
   o.order = 0;
   o.deal = 0;
   o.position = 0;
   o.requested_price = 0.0;
   o.fill_price = 0.0;
   o.volume = 0.0;
   o.slippage_points = 0.0;
   o.slippage_ratio = 0.0;
   o.retcode = 0;
   o.attempts = 0;
   o.message = "";
   o.reason = RC_NONE;
  }

void ResetManageOutcome(ManageOutcome &o)
  {
   o.modified = false;
   o.partial = false;
   o.closed = false;
   o.new_sl = 0.0;
   o.close_volume = 0.0;
   o.note = "";
   o.reason = RC_NONE;
  }

void ResetPositionMeta(PositionMeta &pm)
  {
   pm.ticket = 0;
   pm.symbol = "";
   pm.strategy = STRAT_NONE;
   pm.direction = 0;
   pm.entry = 0.0;
   pm.initial_stop = 0.0;
   pm.initial_risk_price = 0.0;
   pm.risk_money = 0.0;
   pm.risk_pct = 0.0;
   pm.sl_current = 0.0;
   pm.tp_current = 0.0;
   pm.best_price = 0.0;
   pm.worst_price = 0.0;
   pm.ai_multiplier = 1.0;
   pm.ml_probability = 0.0;
   pm.be_done = false;
   pm.partial_done = false;
   pm.trailing_active = false;
   pm.opened_at = 0;
   pm.last_update = 0;
   pm.setup_id = "";
   pm.comment = "";
  }

//+------------------------------------------------------------------+
string RetcodeText(const int rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_REQUOTE:            return "REQUOTE";
      case TRADE_RETCODE_REJECT:             return "REJECT";
      case TRADE_RETCODE_CANCEL:             return "CANCEL";
      case TRADE_RETCODE_PLACED:             return "PLACED";
      case TRADE_RETCODE_DONE:               return "DONE";
      case TRADE_RETCODE_DONE_PARTIAL:       return "DONE_PARTIAL";
      case TRADE_RETCODE_ERROR:              return "ERROR";
      case TRADE_RETCODE_TIMEOUT:            return "TIMEOUT";
      case TRADE_RETCODE_INVALID:            return "INVALID";
      case TRADE_RETCODE_INVALID_VOLUME:     return "INVALID_VOLUME";
      case TRADE_RETCODE_INVALID_PRICE:      return "INVALID_PRICE";
      case TRADE_RETCODE_INVALID_STOPS:      return "INVALID_STOPS";
      case TRADE_RETCODE_TRADE_DISABLED:     return "TRADE_DISABLED";
      case TRADE_RETCODE_MARKET_CLOSED:      return "MARKET_CLOSED";
      case TRADE_RETCODE_NO_MONEY:           return "NO_MONEY";
      case TRADE_RETCODE_PRICE_CHANGED:      return "PRICE_CHANGED";
      case TRADE_RETCODE_PRICE_OFF:          return "PRICE_OFF";
      case TRADE_RETCODE_INVALID_EXPIRATION: return "INVALID_EXPIRATION";
      case TRADE_RETCODE_ORDER_CHANGED:      return "ORDER_CHANGED";
      case TRADE_RETCODE_TOO_MANY_REQUESTS:  return "TOO_MANY_REQUESTS";
      case TRADE_RETCODE_NO_CHANGES:         return "NO_CHANGES";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "SERVER_DISABLES_AT";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "CLIENT_DISABLES_AT";
      case TRADE_RETCODE_LOCKED:             return "LOCKED";
      case TRADE_RETCODE_FROZEN:             return "FROZEN";
      case TRADE_RETCODE_INVALID_FILL:       return "INVALID_FILL";
      case TRADE_RETCODE_CONNECTION:         return "CONNECTION";
      case TRADE_RETCODE_ONLY_REAL:          return "ONLY_REAL";
      case TRADE_RETCODE_LIMIT_ORDERS:       return "LIMIT_ORDERS";
      case TRADE_RETCODE_LIMIT_VOLUME:       return "LIMIT_VOLUME";
      case TRADE_RETCODE_INVALID_ORDER:      return "INVALID_ORDER";
      case TRADE_RETCODE_POSITION_CLOSED:    return "POSITION_CLOSED";
      case TRADE_RETCODE_INVALID_CLOSE_VOLUME: return "INVALID_CLOSE_VOLUME";
      case TRADE_RETCODE_CLOSE_ORDER_EXIST:  return "CLOSE_ORDER_EXIST";
      case TRADE_RETCODE_LIMIT_POSITIONS:    return "LIMIT_POSITIONS";
      case TRADE_RETCODE_LONG_ONLY:          return "LONG_ONLY";
      case TRADE_RETCODE_SHORT_ONLY:         return "SHORT_ONLY";
      case TRADE_RETCODE_CLOSE_ONLY:         return "CLOSE_ONLY";
      default:                               return StringFormat("RETCODE_%d", rc);
     }
  }

bool RetcodeIsSuccess(const int rc)
  {
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED ||
           rc == TRADE_RETCODE_DONE_PARTIAL);
  }

//+------------------------------------------------------------------+
//| Transient failures are worth another request with fresh prices.   |
//+------------------------------------------------------------------+
bool RetcodeIsRetryable(const int rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_CONNECTION:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
      case TRADE_RETCODE_ERROR:
      case TRADE_RETCODE_LOCKED:
      case TRADE_RETCODE_FROZEN:
      case TRADE_RETCODE_REJECT:
      case TRADE_RETCODE_ORDER_CHANGED:
         return true;
      default:
         return false;
     }
  }

//+------------------------------------------------------------------+
class CExecution
  {
private:
   ExecConfig         m_cfg;
   CSymbolRegistry   *m_reg;
   CJournal          *m_journal;
   CStateStore       *m_state;
   int                m_last_fill_mode;   // index into the filling order
   long               m_last_reconciled;

   int                DeviationFor(const SymbolSpec &spec) const;
   double             AskOrBid(const SymbolSpec &spec, const int dir, bool &ok) const;
   bool               ChooseFilling(const SymbolSpec &spec, int attempt,
                                    ENUM_ORDER_TYPE_FILLING &mode) const;
   bool               Send(MqlTradeRequest &req, MqlTradeResult &res, string &err);
   bool               FindNewPosition(const SymbolSpec &spec, const ulong filled_order,
                                      ulong &ticket);

public:
                      CExecution(void);
   bool               Init(const ExecConfig &cfg, CSymbolRegistry *reg,
                           CJournal *journal, CStateStore *state, string &err);

   bool               OpenMarket(const SymbolSpec &spec, const TradeCandidate &cand,
                                 const double lot, const double risk_pct,
                                 ExecResult &out, string &err);
   bool               EnsureProtection(const SymbolSpec &spec, const TradeCandidate &cand,
                                       PositionMeta &pm, string &err);
   bool               ModifyProtection(const SymbolSpec &spec, const ulong ticket,
                                       const double sl, const double tp, string &err);
   bool               ClosePosition(const SymbolSpec &spec, const ulong ticket,
                                    const double volume, ExecResult &out, string &err);

   void               ManagePosition(const SymbolSpec &spec, const double atr,
                                     const double bid, const double ask,
                                     PositionMeta &pm, ManageOutcome &out);

   int                Reconcile(string &err);
   int                RebuildLossStreak(const int magic, const int days, string &err);
   int                SyncClosedDeals(const int magic, const datetime from, string &err);
  };

//+------------------------------------------------------------------+
CExecution::CExecution(void)
  {
   m_reg = NULL;
   m_journal = NULL;
   m_state = NULL;
   m_last_fill_mode = 0;
   m_last_reconciled = 0;
  }

//+------------------------------------------------------------------+
bool CExecution::Init(const ExecConfig &cfg, CSymbolRegistry *reg,
                      CJournal *journal, CStateStore *state, string &err)
  {
   err = "";
   if(reg == NULL)
     {
      err = "execution requires a symbol registry";
      return false;
     }
   if(cfg.max_retries < 0 || cfg.max_retries > 20)
     {
      err = "max_retries must be in [0,20]";
      return false;
     }
   if(cfg.retry_pause_ms < 0 || cfg.retry_pause_ms > 10000)
     {
      err = "retry_pause_ms must be in [0,10000]";
      return false;
     }
   if(cfg.deviation_fx_points < 0 || cfg.deviation_metal_points < 0 ||
      cfg.deviation_index_points < 0)
     {
      err = "deviation points must be >= 0";
      return false;
     }
   m_cfg = cfg;
   m_reg = reg;
   m_journal = journal;
   m_state = state;
   return true;
  }

//+------------------------------------------------------------------+
int CExecution::DeviationFor(const SymbolSpec &spec) const
  {
   switch(spec.asset)
     {
      case ASSET_METAL: return m_cfg.deviation_metal_points;
      case ASSET_INDEX: return m_cfg.deviation_index_points;
      default:          return m_cfg.deviation_fx_points;
     }
  }

//+------------------------------------------------------------------+
double CExecution::AskOrBid(const SymbolSpec &spec, const int dir, bool &ok) const
  {
   ok = false;
   MqlTick tick;
   if(!SymbolInfoTick(spec.name, tick))
      return 0.0;
   if(dir > 0 && tick.ask > 0.0)
     {
      ok = true;
      return tick.ask;
     }
   if(dir < 0 && tick.bid > 0.0)
     {
      ok = true;
      return tick.bid;
     }
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Filling modes in preference order, rotated on INVALID_FILL.       |
//+------------------------------------------------------------------+
bool CExecution::ChooseFilling(const SymbolSpec &spec, int attempt,
                               ENUM_ORDER_TYPE_FILLING &mode) const
  {
   ENUM_ORDER_TYPE_FILLING modes[2];
   modes[0] = ORDER_FILLING_FOK;
   modes[1] = ORDER_FILLING_IOC;

   //--- keep only broker-supported modes, preserving preference ----
   ENUM_ORDER_TYPE_FILLING allowed[2];
   int na = 0;
   for(int i = 0; i < 2; i++)
     {
      int bit = (modes[i] == ORDER_FILLING_FOK) ? SYMBOL_FILLING_FOK : SYMBOL_FILLING_IOC;
      if((spec.filling_mask & bit) != 0)
         allowed[na++] = modes[i];
     }
   if(na == 0)
     {
      mode = ORDER_FILLING_IOC;      // unknown mask: let the broker decide
      return true;
     }
   mode = allowed[attempt % na];
   return true;
  }

//+------------------------------------------------------------------+
bool CExecution::Send(MqlTradeRequest &req, MqlTradeResult &res, string &err)
  {
   err = "";
   ZeroMemory(res);
   ResetLastError();
   if(!OrderSend(req, res))
     {
      int le = GetLastError();
      err = StringFormat("OrderSend failed (error %d, retcode %d %s)",
                         le, (int)res.retcode, RetcodeText((int)res.retcode));
      return false;
     }
   if(!RetcodeIsSuccess((int)res.retcode))
     {
      err = StringFormat("broker returned retcode %d (%s): %s",
                         (int)res.retcode, RetcodeText((int)res.retcode),
                         res.comment);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| After a fill, locate the position this EA just opened.            |
//+------------------------------------------------------------------+
bool CExecution::FindNewPosition(const SymbolSpec &spec, const ulong filled_order,
                                 ulong &ticket)
  {
   ticket = 0;
   datetime newest = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != spec.name)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
         continue;
      if(filled_order != 0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER) == filled_order)
        {
         ticket = t;
         return true;
        }
      datetime open = (datetime)PositionGetInteger(POSITION_TIME);
      if(open >= newest)
        {
         newest = open;
         ticket = t;
        }
     }
   return (ticket != 0);
  }

//+------------------------------------------------------------------+
bool CExecution::OpenMarket(const SymbolSpec &spec, const TradeCandidate &cand,
                            const double lot, const double risk_pct,
                            ExecResult &out, string &err)
  {
   err = "";
   ResetExecResult(out);
   out.reason = RC_EXEC_REJECTED;

   if(!m_cfg.enable_trading)
     {
      out.reason = RC_KILL_SWITCH;
      err = "enable_trading is false";
      return false;
     }
   if(m_cfg.dry_run)
     {
      out.reason = RC_OK;
      out.ok = true;
      out.message = "dry run: no order sent";
      if(m_journal != NULL)
         m_journal.Event("INFO", "DRY_RUN",
                         StringFormat("%s %s %.4f lots", spec.name,
                                      cand.direction > 0 ? "buy" : "sell", lot));
      return true;
     }
   if(!IsTradingAllowedByTerminal())
     {
      out.reason = RC_PERMISSION;
      err = "terminal, account or EA trading permission is off";
      return false;
     }

   int attempts = MathMax(1, m_cfg.max_retries + 1);
   double requested = 0.0;

   for(int attempt = 0; attempt < attempts; attempt++)
     {
      out.attempts = attempt + 1;

      string rerr = "";
      if(!m_reg.RefreshIfStale(spec.name, rerr))
        {
         out.reason = RC_SYMBOL_UNRESOLVED;
         err = "cannot refresh contract specification: " + rerr;
         return false;
        }

      bool price_ok = false;
      double price = AskOrBid(spec, cand.direction, price_ok);
      if(!price_ok)
        {
         out.reason = RC_MARKET_CLOSED;
         err = StringFormat("no %s price for %s",
                            cand.direction > 0 ? "ask" : "bid", spec.name);
         return false;
        }
      if(requested == 0.0)
         requested = price;

      //--- re-validate the stop against the live stops level ---------
      double min_dist = (double)MathMax(0, spec.stops_level) * spec.point;
      if(MathAbs(price - cand.stop) < min_dist)
        {
         out.reason = RC_STOPS_LEVEL;
         err = StringFormat("stop %.5f is inside stops level (%d pt) at price %.5f",
                            cand.stop, spec.stops_level, price);
         if(m_journal != NULL)
            m_journal.Event("ERROR", "STOPS_LEVEL", err);
         return false;
        }

      ENUM_ORDER_TYPE_FILLING filling;
      if(!ChooseFilling(spec, attempt, filling))
        {
         out.reason = RC_SYMBOL_TRADE_DISABLED;
         err = "no supported filling mode";
         return false;
        }

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = spec.name;
      req.volume       = lot;
      req.type         = (cand.direction > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      req.price        = RoundToTick(price, spec.tick_size);
      req.sl           = RoundToTick(cand.stop, spec.tick_size);
      req.tp           = RoundToTick(cand.target1, spec.tick_size);
      req.deviation    = (ulong)DeviationFor(spec);
      req.magic        = (ulong)m_cfg.magic;
      req.type_filling = filling;
      req.comment      = StringSubstr(StringFormat("%s|%s", EA_NAME,
                                        StrategyToString(cand.strategy)), 0, 31);

      string serr = "";
      if(Send(req, res, serr))
        {
         out.ok = true;
         out.order = res.order;
         out.deal = res.deal;
         out.fill_price = (res.price > 0.0) ? res.price : req.price;
         out.volume = (res.volume > 0.0) ? res.volume : lot;
         out.requested_price = requested;
         out.retcode = (int)res.retcode;
         out.slippage_points = MathAbs(out.fill_price - requested) / spec.point;
         out.slippage_ratio = (MathAbs(cand.entry - cand.stop) > 0.0)
                              ? MathAbs(out.fill_price - requested) / MathAbs(cand.entry - cand.stop)
                              : 0.0;
         out.reason = RC_OK;
         out.message = StringFormat("filled %.4f @ %.5f (%s)",
                                    out.volume, out.fill_price, RetcodeText((int)res.retcode));

         if(!FindNewPosition(spec, res.order, out.position))
           {
            out.ok = false;
            out.reason = RC_EXEC_NO_FILL;
            err = "order succeeded but the position cannot be located";
            return false;
           }
         return true;
        }

      //--- failure: classify and decide whether to retry ------------
      out.retcode = (int)res.retcode;
      out.message = serr;
      err = serr;

      if((int)res.retcode == TRADE_RETCODE_INVALID_FILL)
        {
         if(m_journal != NULL)
            m_journal.Event("WARN", "INVALID_FILL",
                            StringFormat("%s: retrying with another filling mode", spec.name));
         continue;
        }
      if(RetcodeIsRetryable((int)res.retcode))
        {
         if(m_journal != NULL)
            m_journal.Event("WARN", RetcodeText((int)res.retcode),
                            StringFormat("%s: %s", spec.name, serr));
         if(attempt + 1 < attempts && m_cfg.retry_pause_ms > 0)
            Sleep(m_cfg.retry_pause_ms);
         continue;
        }

      //--- permanent rejection --------------------------------------
      out.reason = RC_EXEC_REJECTED;
      switch((int)res.retcode)
        {
         case TRADE_RETCODE_MARKET_CLOSED:      out.reason = RC_MARKET_CLOSED; break;
         case TRADE_RETCODE_INVALID_STOPS:      out.reason = RC_STOPS_LEVEL;   break;
         case TRADE_RETCODE_INVALID_VOLUME:     out.reason = RC_MIN_LOT;       break;
         case TRADE_RETCODE_NO_MONEY:           out.reason = RC_MARGIN;        break;
         case TRADE_RETCODE_TRADE_DISABLED:     out.reason = RC_SYMBOL_TRADE_DISABLED; break;
         case TRADE_RETCODE_LONG_ONLY:          out.reason = RC_SYMBOL_LONG_ONLY;  break;
         case TRADE_RETCODE_SHORT_ONLY:         out.reason = RC_SYMBOL_SHORT_ONLY; break;
         case TRADE_RETCODE_CLOSE_ONLY:         out.reason = RC_SYMBOL_CLOSE_ONLY; break;
         case TRADE_RETCODE_CONNECTION:         out.reason = RC_CONNECTIVITY;  break;
         default:                               out.reason = RC_EXEC_REJECTED; break;
        }
      return false;
     }

   out.reason = RC_EXEC_RETRY_EXHAUSTED;
   return false;
  }

//+------------------------------------------------------------------+
bool CExecution::EnsureProtection(const SymbolSpec &spec, const TradeCandidate &cand,
                                  PositionMeta &pm, string &err)
  {
   err = "";
   if(!PositionSelectByTicket(pm.ticket))
     {
      err = "position disappeared before protection could be verified";
      return false;
     }
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   if(sl > 0.0 && tp > 0.0)
     {
      pm.sl_current = sl;
      pm.tp_current = tp;
      return true;
     }

   if(!m_cfg.verify_protection)
      return true;

   //--- protection is missing: try to repair it ---------------------
   double want_sl = (sl > 0.0) ? sl : cand.stop;
   double want_tp = (tp > 0.0) ? tp : cand.target1;
   string merr = "";
   if(!ModifyProtection(spec, pm.ticket, want_sl, want_tp, merr))
     {
      err = "protection repair failed: " + merr;
      if(m_journal != NULL)
         m_journal.Event("ERROR", "PROTECTION_FAILED", err);
      if(m_cfg.close_if_protection_fails)
        {
         ExecResult cr;
         string cerr = "";
         if(ClosePosition(spec, pm.ticket, 0.0, cr, cerr))
           {
            err += "; position closed due to unprotected fill";
            return false;
           }
         err += "; emergency close also failed: " + cerr;
        }
      return false;
     }

   if(PositionSelectByTicket(pm.ticket))
     {
      pm.sl_current = PositionGetDouble(POSITION_SL);
      pm.tp_current = PositionGetDouble(POSITION_TP);
     }
   return (pm.sl_current > 0.0 && pm.tp_current > 0.0);
  }

//+------------------------------------------------------------------+
bool CExecution::ModifyProtection(const SymbolSpec &spec, const ulong ticket,
                                  const double sl, const double tp, string &err)
  {
   err = "";
   if(!PositionSelectByTicket(ticket))
     {
      err = "position not found";
      return false;
     }
   double cur_sl = PositionGetDouble(POSITION_SL);
   double cur_tp = PositionGetDouble(POSITION_TP);
   double want_sl = (sl > 0.0) ? RoundToTick(sl, spec.tick_size) : cur_sl;
   double want_tp = (tp > 0.0) ? RoundToTick(tp, spec.tick_size) : cur_tp;
   if(MathAbs(want_sl - cur_sl) < spec.point * 0.5 &&
      MathAbs(want_tp - cur_tp) < spec.point * 0.5)
      return true;

   int attempts = MathMax(1, m_cfg.modify_retries + 1);
   for(int attempt = 0; attempt < attempts; attempt++)
     {
      string rerr = "";
      m_reg.RefreshIfStale(spec.name, rerr);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = spec.name;
      req.position = ticket;
      req.sl       = want_sl;
      req.tp       = want_tp;
      req.magic    = (ulong)m_cfg.magic;

      string serr = "";
      if(Send(req, res, serr))
         return true;
      err = serr;
      if((int)res.retcode == TRADE_RETCODE_NO_CHANGES)
         return true;
      if(!RetcodeIsRetryable((int)res.retcode))
         return false;
      if(m_cfg.retry_pause_ms > 0)
         Sleep(m_cfg.retry_pause_ms);
     }
   return false;
  }

//+------------------------------------------------------------------+
bool CExecution::ClosePosition(const SymbolSpec &spec, const ulong ticket,
                               const double volume, ExecResult &out, string &err)
  {
   err = "";
   ResetExecResult(out);
   out.reason = RC_EXEC_REJECTED;

   if(!PositionSelectByTicket(ticket))
     {
      //--- already closed is not a failure for a close request
      out.ok = true;
      out.reason = RC_OK;
      out.message = "position already closed";
      return true;
     }
   double have = PositionGetDouble(POSITION_VOLUME);
   double want = (volume > 0.0 && volume < have) ? volume : have;
   want = RoundLotDown(want, spec.vol_step, spec.vol_min, have);
   if(want <= 0.0)
     {
      out.reason = RC_MIN_LOT;
      err = StringFormat("close volume %.4f is below minimum %.4f", want, spec.vol_min);
      return false;
     }

   long ptype = PositionGetInteger(POSITION_TYPE);
   ENUM_ORDER_TYPE close_type = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   int attempts = MathMax(1, m_cfg.max_retries + 1);
   for(int attempt = 0; attempt < attempts; attempt++)
     {
      string rerr = "";
      m_reg.RefreshIfStale(spec.name, rerr);

      MqlTick tick;
      if(!SymbolInfoTick(spec.name, tick))
        {
         out.reason = RC_MARKET_CLOSED;
         err = "no tick available to close position";
         return false;
        }
      double price = (close_type == ORDER_TYPE_SELL) ? tick.bid : tick.ask;
      if(price <= 0.0)
        {
         out.reason = RC_MARKET_CLOSED;
         err = "no price available to close position";
         return false;
        }

      ENUM_ORDER_TYPE_FILLING filling;
      if(!ChooseFilling(spec, attempt, filling))
         filling = ORDER_FILLING_IOC;

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = spec.name;
      req.position     = ticket;
      req.volume       = want;
      req.type         = close_type;
      req.price        = RoundToTick(price, spec.tick_size);
      req.deviation    = (ulong)DeviationFor(spec);
      req.magic        = (ulong)m_cfg.magic;
      req.type_filling = filling;
      req.comment      = "close";

      out.attempts = attempt + 1;
      string serr = "";
      if(Send(req, res, serr))
        {
         out.ok = true;
         out.order = res.order;
         out.deal = res.deal;
         out.position = ticket;
         out.fill_price = (res.price > 0.0) ? res.price : req.price;
         out.requested_price = req.price;
         out.volume = (res.volume > 0.0) ? res.volume : want;
         out.retcode = (int)res.retcode;
         out.reason = RC_OK;
         out.message = "closed";
         return true;
        }
      out.retcode = (int)res.retcode;
      out.message = serr;
      err = serr;
      if((int)res.retcode == TRADE_RETCODE_POSITION_CLOSED)
        {
         out.ok = true;
         out.reason = RC_OK;
         return true;
        }
      if(!RetcodeIsRetryable((int)res.retcode) &&
         (int)res.retcode != TRADE_RETCODE_INVALID_FILL)
         return false;
      if(m_cfg.retry_pause_ms > 0)
         Sleep(m_cfg.retry_pause_ms);
     }
   out.reason = RC_EXEC_RETRY_EXHAUSTED;
   return false;
  }

//+------------------------------------------------------------------+
//| Breakeven, trailing, partial take-profit and time exit.            |
//| The caller passes the ATR the position was planned with.           |
//+------------------------------------------------------------------+
void CExecution::ManagePosition(const SymbolSpec &spec, const double atr,
                                const double bid, const double ask,
                                PositionMeta &pm, ManageOutcome &out)
  {
   ResetManageOutcome(out);
   out.reason = RC_NONE;

   double price = (pm.direction > 0) ? bid : ask;
   if(price <= 0.0 || pm.initial_risk_price <= 0.0)
      return;

   //--- MAE / MFE in R ---------------------------------------------
   if(pm.best_price <= 0.0) pm.best_price = pm.entry;
   if(pm.worst_price <= 0.0) pm.worst_price = pm.entry;
   if(pm.direction > 0)
     {
      if(price > pm.best_price)  pm.best_price = price;
      if(price < pm.worst_price) pm.worst_price = price;
     }
   else
     {
      if(price < pm.best_price)  pm.best_price = price;
      if(price > pm.worst_price) pm.worst_price = price;
     }

   double r_now = pm.direction * (price - pm.entry) / pm.initial_risk_price;

   //--- 1. partial take-profit -------------------------------------
   if(m_cfg.partial_enabled && !pm.partial_done && r_now >= m_cfg.partial_at_r)
     {
      double have = 0.0;
      if(PositionSelectByTicket(pm.ticket))
         have = PositionGetDouble(POSITION_VOLUME);
      double target = have * ClampD(m_cfg.partial_pct, 0.0, 0.95);
      target = RoundLotDown(target, spec.vol_step, spec.vol_min, have);
      if(target > 0.0 && target < have)
        {
         ExecResult cr;
         string cerr = "";
         if(ClosePosition(spec, pm.ticket, target, cr, cerr))
           {
            pm.partial_done = true;
            out.partial = true;
            out.close_volume = target;
            out.note = StringFormat("partial %.4f lots at %.2fR", target, r_now);
            out.reason = RC_OK;
           }
        }
     }

   //--- 2. breakeven ------------------------------------------------
   if(m_cfg.breakeven_enabled && !pm.be_done && r_now >= m_cfg.breakeven_at_r)
     {
      double buffer = MathAbs(m_cfg.breakeven_buffer_atr) * atr;
      double want = pm.entry + pm.direction * buffer;
      bool better = (pm.direction > 0) ? (want > pm.sl_current) : (want < pm.sl_current || pm.sl_current <= 0.0);
      if(better)
        {
         string merr = "";
         if(ModifyProtection(spec, pm.ticket, want, 0.0, merr))
           {
            pm.sl_current = RoundToTick(want, spec.tick_size);
            pm.be_done = true;
            out.modified = true;
            out.new_sl = pm.sl_current;
            out.note = "breakeven";
           }
        }
     }

   //--- 3. trailing stop ---------------------------------------------
   if(m_cfg.trail_enabled && atr > 0.0 && r_now >= m_cfg.trail_start_r)
     {
      double want = price - pm.direction * MathAbs(m_cfg.trail_atr_mult) * atr;
      double step = MathAbs(m_cfg.trail_min_step_atr) * atr;
      bool better = false;
      if(pm.direction > 0)
         better = (pm.sl_current <= 0.0) ? (want < price) : (want > pm.sl_current + step);
      else
         better = (pm.sl_current <= 0.0) ? (want > price) : (want < pm.sl_current - step);
      if(better)
        {
         string merr = "";
         if(ModifyProtection(spec, pm.ticket, want, 0.0, merr))
           {
            pm.sl_current = RoundToTick(want, spec.tick_size);
            pm.trailing_active = true;
            out.modified = true;
            out.new_sl = pm.sl_current;
            out.note = StringFormat("trail to %.5f", pm.sl_current);
           }
        }
     }

   //--- 4. time exit -------------------------------------------------
   if(m_cfg.time_exit_enabled && pm.opened_at > 0 && r_now < m_cfg.time_exit_min_r)
     {
      int held = (int)((TimeTradeServer() - pm.opened_at) / 60);
      if(held >= m_cfg.max_hold_minutes)
        {
         ExecResult cr;
         string cerr = "";
         if(ClosePosition(spec, pm.ticket, 0.0, cr, cerr))
           {
            out.closed = true;
            out.note = StringFormat("time exit after %d min at %.2fR", held, r_now);
            out.reason = RC_OK;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Reconcile metadata against live positions after a restart.        |
//| Positions without metadata are adopted conservatively: the current |
//| stop (or entry when missing) becomes the initial risk.            |
//+------------------------------------------------------------------+
int CExecution::Reconcile(string &err)
  {
   err = "";
   if(m_state == NULL)
     {
      err = "reconcile requires a state store";
      return 0;
     }

   int adopted = 0;
   int removed = 0;
   int total = PositionsTotal();

   //--- 1. adopt unknown positions opened by this EA ----------------
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
         continue;
      PositionMeta pm;
      if(m_state.FindPosition(ticket, pm))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      SymbolSpec *sp = m_reg.Find(sym);
      if(sp == NULL)
        {
         if(m_journal != NULL)
            m_journal.Event("ERROR", "RECONCILE",
                            StringFormat("position %I64u on unknown symbol %s", ticket, sym));
         continue;
        }
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      ResetPositionMeta(pm);
      pm.ticket = ticket;
      pm.symbol = sym;
      pm.strategy = STRAT_NONE;
      pm.direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      pm.entry = entry;
      pm.initial_stop = (sl > 0.0) ? sl : entry;
      pm.initial_risk_price = MathAbs(entry - pm.initial_stop);
      pm.sl_current = sl;
      pm.tp_current = tp;
      pm.best_price = entry;
      pm.worst_price = entry;
      pm.ai_multiplier = 1.0;
      pm.opened_at = (datetime)PositionGetInteger(POSITION_TIME);
      pm.last_update = TimeTradeServer();
      pm.comment = "adopted";
      double vpp = m_reg.ValuePerPriceUnit(sym);
      double vol = PositionGetDouble(POSITION_VOLUME);
      pm.risk_money = pm.initial_risk_price * vpp * vol;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      pm.risk_pct = (eq > 0.0) ? 100.0 * pm.risk_money / eq : 0.0;
      pm.setup_id = "reconciled";
      m_state.AddPosition(pm);
      adopted++;
      if(m_journal != NULL)
         m_journal.Event("WARN", "RECONCILE",
                         StringFormat("adopted position %I64u %s %.4f lots", ticket, sym, vol));
     }

   //--- 2. drop metadata whose position no longer exists -----------
   for(int i = m_state.PositionCount() - 1; i >= 0; i--)
     {
      PositionMeta pm;
      if(!m_state.PositionAt(i, pm))
         continue;
      if(PositionSelectByTicket(pm.ticket))
         continue;
      m_state.RemovePosition(pm.ticket);
      removed++;
      if(m_journal != NULL)
         m_journal.Event("WARN", "RECONCILE",
                         StringFormat("position %I64u %s closed outside the EA loop",
                                      pm.ticket, pm.symbol));
     }

   if(adopted > 0 || removed > 0)
      m_state.Save(err);

   return adopted + removed;
  }

//+------------------------------------------------------------------+
//| Rebuild the consecutive-loss streak from account history.         |
//| Called once at init so a restart cannot silently reset a kill     |
//| switch. Positions are aggregated by identifier; the streak counts  |
//| the most recent consecutive losing positions.                     |
//+------------------------------------------------------------------+
int CExecution::RebuildLossStreak(const int magic, const int days, string &err)
  {
   err = "";
   if(m_state == NULL)
     {
      err = "loss-streak rebuild requires a state store";
      return 0;
     }
   datetime to = TimeTradeServer();
   datetime from = to - (datetime)MathMax(1, days) * 86400;
   if(!HistorySelect(from, to))
     {
      err = StringFormat("HistorySelect failed (error %d)", GetLastError());
      return 0;
     }

   int deals = HistoryDealsTotal();
   ulong   ids[];
   double  pnl[];
   datetime closed[];

   for(int i = 0; i < deals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if((int)HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic)
         continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      ulong pos = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      double p = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      int idx = -1;
      for(int k = 0; k < ArraySize(ids); k++)
         if(ids[k] == pos)
           {
            idx = k;
            break;
           }
      if(idx < 0)
        {
         int n = ArraySize(ids);
         ArrayResize(ids, n + 1);
         ArrayResize(pnl, n + 1);
         ArrayResize(closed, n + 1);
         ids[n] = pos;
         pnl[n] = p;
         closed[n] = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
        }
      else
        {
         pnl[idx] += p;
         datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         if(t > closed[idx])
            closed[idx] = t;
        }
     }

   //--- insertion sort by close time (small N) ----------------------
   int n = ArraySize(ids);
   for(int i = 1; i < n; i++)
     {
      ulong   kid = ids[i];
      double  kp  = pnl[i];
      datetime kt = closed[i];
      int j = i - 1;
      while(j >= 0 && closed[j] > kt)
        {
         ids[j + 1] = ids[j];
         pnl[j + 1] = pnl[j];
         closed[j + 1] = closed[j];
         j--;
        }
      ids[j + 1] = kid;
      pnl[j + 1] = kp;
      closed[j + 1] = kt;
     }

   int streak = 0;
   for(int i = n - 1; i >= 0; i--)
     {
      if(pnl[i] < 0.0)
         streak++;
      else
         break;
     }
   m_state.SetConsecutiveLosses(streak);
   return streak;
  }

//+------------------------------------------------------------------+
//| Journal closes that happened while the EA was not running.        |
//| Uses deal tickets above the last processed one, so a restart does  |
//| not double count.                                                  |
//+------------------------------------------------------------------+
int CExecution::SyncClosedDeals(const int magic, const datetime from, string &err)
  {
   err = "";
   if(m_journal == NULL || m_state == NULL)
      return 0;
   if(from <= 0)
      return 0;
   if(!HistorySelect(from, TimeTradeServer()))
     {
      err = StringFormat("HistorySelect failed (error %d)", GetLastError());
      return 0;
     }
   int dealtotal = HistoryDealsTotal();
   int count = 0;
   for(int i = 0; i < dealtotal; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || (long)ticket <= m_last_reconciled)
         continue;
      if((int)HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic)
         continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      ulong pos = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      PositionMeta pm;
      bool have = m_state.FindPosition(pos, pm);
      double p = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double price = HistoryDealGetDouble(ticket, DEAL_PRICE);
      double vol = HistoryDealGetDouble(ticket, DEAL_VOLUME);

      if(have)
        {
         double r = (pm.initial_risk_price > 0.0 && pm.risk_money > 0.0)
                    ? p / pm.risk_money : 0.0;
         m_journal.TradeClose(pm, vol, price, p, r, 0.0, 0.0, 0.0, "closed outside the EA");
         m_state.RemovePosition(pos);
         if(p < 0.0)
            m_state.SetConsecutiveLosses(m_state.ConsecutiveLosses() + 1);
         else if(p > 0.0)
            m_state.SetConsecutiveLosses(0);
        }
      else
        {
         m_journal.Event("INFO", "SYNC_CLOSE",
                         StringFormat("deal %I64u position %I64u pnl %.2f (no metadata)",
                                      ticket, pos, p));
        }
      if((long)ticket > m_last_reconciled)
         m_last_reconciled = (long)ticket;
      count++;
     }
   if(count > 0)
      m_state.Save(err);
   return count;
  }

#endif
//+------------------------------------------------------------------+
