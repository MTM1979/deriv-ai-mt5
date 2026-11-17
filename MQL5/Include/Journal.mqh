//+------------------------------------------------------------------+
//|                                                      Journal.mqh |
//|  Append-only CSV audit trail. One file per concern, opened and     |
//|  closed per record so every decision is flushed to disk before the |
//|  EA continues. Rotation keeps at most one previous generation.     |
//|                                                                    |
//|  Files (under JournalDir):                                         |
//|    decisions.csv    one row per evaluated candidate                |
//|    trades.csv       open/close/partial/modify events with MAE/MFE  |
//|    rejections.csv   one row per rejected candidate at any stage    |
//|    ai_audit.csv     external AI request/response, redacted         |
//|    events.csv       lifecycle, halts, errors, warnings             |
//|    daily_summary.csv one row per trading day                       |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_JOURNAL_MQH__
#define __DERIV_AI_JOURNAL_MQH__

#include <Config.mqh>
#include <Utils.mqh>
#include <State.mqh>

//+------------------------------------------------------------------+
//| RFC-4180-ish cell: quote when needed, never emit a raw newline.    |
//+------------------------------------------------------------------+
string JournalCell(const string v)
  {
   string s = v;
   StringReplace(s, "\r", "\\r");
   StringReplace(s, "\n", "\\n");
   bool need = false;
   if(StringFind(s, ",") >= 0 || StringFind(s, "\"") >= 0)
      need = true;
   if(!need)
      return s;
   StringReplace(s, "\"", "\"\"");
   return "\"" + s + "\"";
  }

string JournalNum(const double v, const int digits = 6)
  {
   if(!IsFinite(v))
      return "";
   return DoubleToString(v, digits);
  }

//+------------------------------------------------------------------+
class CJournal
  {
private:
   JournalConfig      m_cfg;
   bool               m_ready;
   string             m_error;
   int                m_last_rotate_day;

   int                OpenAppend(const string file, string &err);
   bool               Append(const string file, const string header, const string line,
                             string &err);
   void               Rotate(const string file);

public:
                      CJournal(void);
   bool               Init(const JournalConfig &cfg, string &err);
   bool               Ready(void)      const { return m_ready; }
   string             LastError(void) const { return m_error; }
   string             Dir(void)       const { return m_cfg.dir; }

   void               Event(const string level, const string code, const string text);
   void               Rejection(const TradeCandidate &c, const string stage,
                                const string reason, const string detail);
   void               Decision(const TradeCandidate &c, const string stage);
   void               TradeOpen(const PositionMeta &pm, const double price,
                                const double lot, const double slippage_points,
                                const string note);
   void               TradeModify(const PositionMeta &pm, const string note);
   void               TradePartial(const PositionMeta &pm, const double lot,
                                   const double price, const double pnl,
                                   const string note);
   void               TradeClose(const PositionMeta &pm, const double lot,
                                 const double price, const double pnl,
                                 const double r_multiple, const double mae_r,
                                 const double mfe_r, const double slip_ratio,
                                 const string note);
   void               AiAudit(const string symbol, const string decision,
                              const double multiplier, const int confidence,
                              const string reason, const bool fallback,
                              const bool available, const string request,
                              const string response, const string error);
   void               DailySummary(const int day_id, const double start_equity,
                                   const double end_equity, const int trades,
                                   const int wins, const int losses,
                                   const double net_pnl, const double r_sum,
                                   const double max_dd_pct, const double peak_heat_pct,
                                   const string halt_reason);
  };

//+------------------------------------------------------------------+
CJournal::CJournal(void)
  {
   m_ready = false;
   m_error = "";
   m_last_rotate_day = 0;
  }

//+------------------------------------------------------------------+
bool CJournal::Init(const JournalConfig &cfg, string &err)
  {
   err = "";
   m_cfg = cfg;
   m_ready = false;
   if(!cfg.enabled)
     {
      m_ready = true;    // disabled is a valid state; all writes become no-ops
      return true;
     }
   if(cfg.dir == "")
     {
      err = "journal dir is empty";
      return false;
     }
   if(!EnsureFolder(cfg.dir, cfg.common_folder))
     {
      err = StringFormat("cannot create journal dir '%s' (error %d)",
                         cfg.dir, GetLastError());
      return false;
     }
   m_ready = true;
   return true;
  }

//+------------------------------------------------------------------+
int CJournal::OpenAppend(const string file, string &err)
  {
   err = "";
   int flags = FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ;
   if(m_cfg.common_folder)
      flags |= FILE_COMMON;
   int h = FileOpen(file, flags);
   if(h == INVALID_HANDLE)
     {
      err = StringFormat("cannot open journal '%s' (error %d)", file, GetLastError());
      return INVALID_HANDLE;
     }
   FileSeek(h, 0, SEEK_END);
   return h;
  }

//+------------------------------------------------------------------+
void CJournal::Rotate(const string file)
  {
   if(m_cfg.max_mb <= 0)
      return;
   long size = 0;
   int flags = FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ;
   if(m_cfg.common_folder)
      flags |= FILE_COMMON;
   int h = FileOpen(file, flags);
   if(h != INVALID_HANDLE)
     {
      size = (long)FileSize(h);
      FileClose(h);
     }
   if(size < (long)m_cfg.max_mb * 1024 * 1024)
      return;
   string base = file;
   int dot = StringFind(base, ".", 0);
   if(dot > 0)
      base = StringSubstr(base, 0, dot);
   string stamp = TimeToString(TimeTradeServer(), TIME_DATE | TIME_MINUTES);
   StringReplace(stamp, ".", "");
   StringReplace(stamp, ":", "");
   StringReplace(stamp, " ", "_");
   string rotated = base + "_" + stamp + ".csv";
   if(!FileMove(file, m_cfg.common_folder ? FILE_COMMON : 0, rotated, FILE_REWRITE))
      LogWarn(StringFormat("journal rotation failed for %s (error %d)", file, GetLastError()));
  }

//+------------------------------------------------------------------+
bool CJournal::Append(const string file, const string header, const string line,
                      string &err)
  {
   err = "";
   if(!m_ready || !m_cfg.enabled)
      return true;

   Rotate(file);

   int h = OpenAppend(file, err);
   if(h == INVALID_HANDLE)
      return false;

   long size = (long)FileTell(h);
   if(size <= 0 && header != "")
      FileWriteString(h, header + "\r\n");
   FileWriteString(h, line + "\r\n");
   FileFlush(h);
   FileClose(h);
   return true;
  }

//+------------------------------------------------------------------+
void CJournal::Event(const string level, const string code, const string text)
  {
   if(!m_ready || !m_cfg.enabled || m_cfg.verbosity < 0)
      return;
   if(m_cfg.verbosity < 1 && level != "ERROR")
      return;
   string err = "";
   string line = StringFormat("%s,%s,%s,%s",
                              TimeToIso(TimeTradeServer()),
                              JournalCell(level),
                              JournalCell(code),
                              JournalCell(text));
   if(!Append("events.csv", "time,level,code,text", line, err))
      LogError(err);
  }

//+------------------------------------------------------------------+
void CJournal::Rejection(const TradeCandidate &c, const string stage,
                         const string reason, const string detail)
  {
   if(!m_ready || !m_cfg.enabled || !m_cfg.log_rejections)
      return;
   string err = "";
   string line = StringFormat("%s,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s",
                              TimeToIso(TimeTradeServer()),
                              JournalCell(c.symbol),
                              JournalCell(c.strategy_name),
                              JournalCell(stage),
                              JournalCell(reason),
                              JournalCell(c.session),
                              JournalCell(c.regime),
                              c.direction,
                              JournalNum(c.entry),
                              JournalNum(c.stop),
                              JournalCell(detail));
   if(!Append("rejections.csv",
              "time,symbol,strategy,stage,reason,session,regime,direction,entry,stop,detail",
              line, err))
      LogError(err);
  }

//+------------------------------------------------------------------+
void CJournal::Decision(const TradeCandidate &c, const string stage)
  {
   if(!m_ready || !m_cfg.enabled || m_cfg.verbosity < 1)
      return;
   string err = "";
   string line = StringFormat(
                   "%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s",
                   TimeToIso(TimeTradeServer()),
                   TimeToIso(c.bar_time),
                   JournalCell(c.symbol),
                   JournalCell(c.strategy_name),
                   c.direction,
                   JournalCell(c.regime),
                   JournalCell(c.session),
                   JournalNum(c.technical_score, 4),
                   JournalNum(c.ml_probability, 6),
                   JournalNum(c.ml_threshold_add, 4),
                   JournalNum(c.ai_risk_multiplier, 4),
                   JournalNum(c.session_risk_scale, 4),
                   JournalNum(c.strategy_risk_scale, 4),
                   JournalNum(c.risk_pct, 4),
                   JournalNum(c.lot, 4),
                   JournalNum(c.spread_points, 1),
                   JournalNum(c.atr),
                   c.minutes_to_event,
                   c.event_impact,
                   JournalNum(c.entry),
                   JournalNum(c.stop),
                   JournalNum(c.target1),
                   JournalNum(c.target2),
                   JournalCell(c.setup_id),
                   JournalCell(c.approved ? "approved" : "blocked"),
                   JournalCell(ReasonToString(c.reason)),
                   JournalCell(c.reason_text),
                   JournalCell(stage),
                   JournalCell(c.notes));
   if(!Append("decisions.csv",
              "time,bar_time,symbol,strategy,direction,regime,session,score,ml_prob,ml_threshold_add,"
              "ai_mult,session_scale,strategy_scale,risk_pct,lot,spread_points,atr,"
              "minutes_to_event,event_impact,entry,stop,tp1,tp2,setup_id,outcome,reason,detail,stage,notes",
              line, err))
      LogError(err);
  }

//+------------------------------------------------------------------+
void CJournal::TradeOpen(const PositionMeta &pm, const double price,
                         const double lot, const double slippage_points,
                         const string note)
  {
   if(!m_ready || !m_cfg.enabled)
      return;
   string err = "";
   string line = StringFormat("%s,OPEN,%I64u,%s,%s,%d,%s,%s,%s,%s,%s,%s,,,,%s,%s,%s,%s",
                              TimeToIso(TimeTradeServer()),
                              pm.ticket,
                              JournalCell(pm.symbol),
                              JournalCell(StrategyToString((ENUM_STRATEGY)pm.strategy)),
                              pm.direction,
                              JournalNum(lot, 4),
                              JournalNum(price),
                              JournalNum(pm.initial_stop),
                              JournalNum(pm.sl_current),
                              JournalNum(pm.tp_current),
                              JournalNum(pm.risk_money, 2),
                              JournalNum(slippage_points, 1),
                              JournalCell(pm.setup_id),
                              JournalCell(note),
                              TimeToIso(pm.opened_at),
                              "");
   if(!Append("trades.csv",
              "time,event,ticket,symbol,strategy,direction,lots,price,initial_stop,sl,tp,"
              "risk_money,r_multiple,mae_r,mfe_r,slippage_points,setup_id,note,opened_at,closed_at",
              line, err))
      LogError(err);
  }

//+------------------------------------------------------------------+
void CJournal::TradeModify(const PositionMeta &pm, const string note)
  {
   if(!m_ready || !m_cfg.enabled || m_cfg.verbosity < 2)
      return;
   string err = "";
   string line = StringFormat("%s,MODIFY,%I64u,%s,%s,%d,,,,%s,%s,,,,,,%s,%s,%s,",
                              TimeToIso(TimeTradeServer()),
                              pm.ticket,
                              JournalCell(pm.symbol),
                              JournalCell(StrategyToString((ENUM_STRATEGY)pm.strategy)),
                              pm.direction,
                              JournalNum(pm.sl_current),
                              JournalNum(pm.tp_current),
                              JournalCell(pm.setup_id),
                              JournalCell(note),
                              TimeToIso(pm.opened_at));
   if(!Append("trades.csv", "", line, err))
      LogError(err);
  }

//+------------------------------------------------------------------+
void CJournal::TradePartial(const PositionMeta &pm, const double lot,
                            const double price, const double pnl,
                            const string note)
  {
   if(!m_ready || !m_cfg.enabled)
      return;
   string err = "";
   string line = StringFormat("%s,PARTIAL,%I64u,%s,%s,%d,%s,%s,,,,%s,,,,%s,%s,%s,%s,",
                              TimeToIso(TimeTradeServer()),
                              pm.ticket,
                              JournalCell(pm.symbol),
                              JournalCell(StrategyToString((ENUM_STRATEGY)pm.strategy)),
                              pm.direction,
                              JournalNum(lot, 4),
                              JournalNum(price),
                              JournalNum(pm.risk_money, 2),
                              JournalNum(pnl, 2),
                              JournalCell(pm.setup_id),
                              JournalCell(note),
                              TimeToIso(pm.opened_at));
   if(!Append("trades.csv", "", line, err))
      LogError(err);
  }

//+------------------------------------------------------------------+
void CJournal::TradeClose(const PositionMeta &pm, const double lot,
                          const double price, const double pnl,
                          const double r_multiple, const double mae_r,
                          const double mfe_r, const double slip_ratio,
                          const string note)
  {
   if(!m_ready || !m_cfg.enabled)
      return;
   string err = "";
   string line = StringFormat("%s,CLOSE,%I64u,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,,%s,%s,%s,%s",
                              TimeToIso(TimeTradeServer()),
                              pm.ticket,
                              JournalCell(pm.symbol),
                              JournalCell(StrategyToString((ENUM_STRATEGY)pm.strategy)),
                              pm.direction,
                              JournalNum(lot, 4),
                              JournalNum(price),
                              JournalNum(pm.initial_stop),
                              JournalNum(pm.sl_current),
                              JournalNum(pm.tp_current),
                              JournalNum(pm.risk_money, 2),
                              JournalNum(r_multiple, 4),
                              JournalNum(mae_r, 4),
                              JournalNum(mfe_r, 4),
                              JournalCell(pm.setup_id),
                              JournalCell(note + (IsFinite(slip_ratio) ? StringFormat(" slip=%.3fR", slip_ratio) : "")),
                              TimeToIso(pm.opened_at),
                              TimeToIso(TimeTradeServer()));
   if(!Append("trades.csv", "", line, err))
      LogError(err);
  }

//+------------------------------------------------------------------+
void CJournal::AiAudit(const string symbol, const string decision,
                       const double multiplier, const int confidence,
                       const string reason, const bool fallback,
                       const bool available, const string request,
                       const string response, const string error)
  {
   if(!m_ready || !m_cfg.enabled)
      return;
   string err = "";
   string line = StringFormat("%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s",
                              TimeToIso(TimeTradeServer()),
                              JournalCell(symbol),
                              JournalCell(decision),
                              JournalNum(multiplier, 4),
                              confidence,
                              JournalCell(reason),
                              JournalCell(fallback ? "true" : "false"),
                              JournalCell(available ? "true" : "false"),
                              JournalCell(request),
                              JournalCell(response),
                              JournalCell(error));
   if(!Append("ai_audit.csv",
              "time,symbol,decision,multiplier,confidence,reason,fallback,available,request,response,error",
              line, err))
      LogError(err);
  }

//+------------------------------------------------------------------+
void CJournal::DailySummary(const int day_id, const double start_equity,
                            const double end_equity, const int trades,
                            const int wins, const int losses,
                            const double net_pnl, const double r_sum,
                            const double max_dd_pct, const double peak_heat_pct,
                            const string halt_reason)
  {
   if(!m_ready || !m_cfg.enabled || !m_cfg.daily_summary)
      return;
   string err = "";
   double ret = (start_equity > 0.0) ? 100.0 * (end_equity - start_equity) / start_equity : 0.0;
   string line = StringFormat("%s,%d,%s,%s,%s,%s,%d,%d,%d,%s,%s,%s,%s,%s",
                              TimeToIso(TimeTradeServer()),
                              day_id,
                              JournalNum(start_equity, 2),
                              JournalNum(end_equity, 2),
                              JournalNum(ret, 4),
                              JournalNum(net_pnl, 2),
                              trades,
                              wins,
                              losses,
                              JournalNum(r_sum, 4),
                              JournalNum(max_dd_pct, 4),
                              JournalNum(peak_heat_pct, 4),
                              JournalCell(halt_reason),
                              JournalCell(AccountInfoString(ACCOUNT_CURRENCY)));
   if(!Append("daily_summary.csv",
              "time,day_id,start_equity,end_equity,return_pct,net_pnl,trades,wins,losses,"
              "r_sum,max_dd_pct,peak_heat_pct,halt_reason,currency",
              line, err))
      LogError(err);
  }

#endif
//+------------------------------------------------------------------+
