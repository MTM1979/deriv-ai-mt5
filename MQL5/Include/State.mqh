//+------------------------------------------------------------------+
//|                                                         State.mqh |
//|  Persistent EA state: day/week anchors, drawdown peak, halt flags, |
//|  loss streaks, kill-switch counters and per-position metadata.     |
//|                                                                    |
//|  Ownership: this class owns the state file. Everything else reads  |
//|  and writes through it. Saves are atomic (temp file + FileMove     |
//|  with FILE_REWRITE) so a crash can never truncate the live file.   |
//|                                                                    |
//|  Values are restored before any trading decision. A missing file   |
//|  is a fresh start, not an error; an unreadable or schema-invalid   |
//|  file is an error and the caller must fail closed.                 |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_STATE_MQH__
#define __DERIV_AI_STATE_MQH__

#include <Config.mqh>
#include <Utils.mqh>
#include <Json.mqh>

//+------------------------------------------------------------------+
//| Metadata attached to every position opened by this EA.            |
//| Kept separate from the position itself, because the broker owns   |
//| the position while we own the intent and the risk accounting.     |
//+------------------------------------------------------------------+
struct PositionMeta
  {
   ulong          ticket;
   string         symbol;
   int            strategy;          // ENUM_STRATEGY as int
   int            direction;         // +1 / -1
   double         entry;
   double         initial_stop;
   double         initial_risk_price;
   double         risk_money;        // account currency at entry
   double         risk_pct;          // percent of equity at entry
   double         sl_current;
   double         tp_current;
   double         best_price;
   double         worst_price;
   double         ai_multiplier;
   double         ml_probability;
   bool           be_done;
   bool           partial_done;
   bool           trailing_active;
   datetime       opened_at;
   datetime       last_update;
   string         setup_id;
   string         comment;
  };

//+------------------------------------------------------------------+
//| Halt / kill-switch flags. Each one latches until cleared by the    |
//| documented owner: day roll, week roll, or manual reset.            |
//+------------------------------------------------------------------+
struct HaltState
  {
   bool           daily_loss;
   bool           weekly_loss;
   bool           drawdown;
   bool           loss_streak;
   bool           slippage;
   bool           rejections;
   bool           manual;
   string         reason;            // last reason that latched a flag
   datetime       since;
  };

//+------------------------------------------------------------------+
class CStateStore
  {
private:
   string         m_file;
   bool           m_common;
   bool           m_dirty;

   //--- anchors and equity -----------------------------------------
   int            m_day_id;
   int            m_week_id;
   double         m_day_start_equity;
   double         m_week_start_equity;
   double         m_peak_equity;
   double         m_last_equity;
   datetime       m_saved_at;

   //--- counters ----------------------------------------------------
   int            m_consecutive_losses;
   int            m_rejections_today;
   int            m_slip_count;
   double         m_slip_sum_ratio;

   HaltState      m_halt;
   PositionMeta   m_pos[];

   bool           WriteAtomic(const string body, string &err);
   void           Reset(void);

public:
                  CStateStore(void);

   bool           Init(const string file, const bool common_folder, string &err);
   bool           Load(string &err);
   bool           Save(string &err);

   //--- equity and period anchors -----------------------------------
   void           UpdateEquity(const double equity);
   bool           Roll(const int day_id, const int week_id, const double equity);
   void           ResetHalts(void);

   double         DayStartEquity(void)   const { return m_day_start_equity; }
   double         WeekStartEquity(void)  const { return m_week_start_equity; }
   double         PeakEquity(void)       const { return m_peak_equity; }
   double         LastEquity(void)       const { return m_last_equity; }
   int            DayIdStored(void)      const { return m_day_id; }
   int            WeekIdStored(void)     const { return m_week_id; }
   datetime       SavedAt(void)          const { return m_saved_at; }

   //--- counters ----------------------------------------------------
   int            ConsecutiveLosses(void) const { return m_consecutive_losses; }
   void           SetConsecutiveLosses(const int v);
   int            RejectionsToday(void)  const { return m_rejections_today; }
   void           NoteRejection(void);
   int            SlipSamples(void)      const { return m_slip_count; }
   double         AvgSlipRatio(void)     const
     { return (m_slip_count > 0) ? m_slip_sum_ratio / m_slip_count : 0.0; }
   void           NoteSlippage(const double ratio);

   //--- halts -------------------------------------------------------
   HaltState      Halts(void)            const { return m_halt; }
   bool           AnyHalt(void)          const { return m_halt.daily_loss || m_halt.weekly_loss ||
                                                         m_halt.drawdown || m_halt.loss_streak ||
                                                         m_halt.slippage || m_halt.rejections ||
                                                         m_halt.manual; }
   void           LatchDailyLoss(const string why);
   void           LatchWeeklyLoss(const string why);
   void           LatchDrawdown(const string why);
   void           LatchLossStreak(const string why);
   void           LatchSlippage(const string why);
   void           LatchRejections(const string why);
   void           LatchManual(const string why);
   void           ClearManual(void);

   //--- position metadata -------------------------------------------
   int            PositionCount(void)    const { return ArraySize(m_pos); }
   bool           PositionAt(const int i, PositionMeta &out) const;
   int            FindIndex(const ulong ticket) const;
   bool           FindPosition(const ulong ticket, PositionMeta &out) const;
   bool           AddPosition(const PositionMeta &pm);
   bool           UpdatePosition(const PositionMeta &pm);
   bool           RemovePosition(const ulong ticket);
   void           ClearPositions(void);

   //--- views -------------------------------------------------------
   double         SumOpenRiskMoney(void) const;
   double         SumOpenRiskPct(const double equity) const;
   int            CountOpenForSymbol(const string symbol) const;
   int            CountOpenForGroup(const string group,
                                    const string &symbols[],
                                    const string &groups[]) const;
   void           PositionsJson(string &out) const;
   string         HaltReason(void)       const { return m_halt.reason; }
   bool           Dirty(void)            const { return m_dirty; }
   void           MarkClean(void)        { m_dirty = false; }
  };

//+------------------------------------------------------------------+
CStateStore::CStateStore(void)
  {
   m_file  = "";
   m_common = false;
   m_dirty = false;
   Reset();
  }

void CStateStore::Reset(void)
  {
   m_day_id            = 0;
   m_week_id           = 0;
   m_day_start_equity  = 0.0;
   m_week_start_equity = 0.0;
   m_peak_equity       = 0.0;
   m_last_equity       = 0.0;
   m_saved_at          = 0;
   m_consecutive_losses = 0;
   m_rejections_today  = 0;
   m_slip_count        = 0;
   m_slip_sum_ratio    = 0.0;

   m_halt.daily_loss  = false;
   m_halt.weekly_loss = false;
   m_halt.drawdown    = false;
   m_halt.loss_streak = false;
   m_halt.slippage    = false;
   m_halt.rejections  = false;
   m_halt.manual      = false;
   m_halt.reason      = "";
   m_halt.since       = 0;

   ArrayResize(m_pos, 0);
  }

//+------------------------------------------------------------------+
bool CStateStore::Init(const string file, const bool common_folder, string &err)
  {
   err = "";
   if(file == "")
     {
      err = "state file name is empty";
      return false;
     }
   m_file   = file;
   m_common = common_folder;
   return true;
  }

//+------------------------------------------------------------------+
//| Read the state file. A missing file is a valid fresh start.       |
//+------------------------------------------------------------------+
bool CStateStore::Load(string &err)
  {
   err = "";
   Reset();

   if(!FileExistsIn(m_file, m_common))
     {
      m_dirty = true;      // force an initial save so the file exists
      return true;
     }

   string text = "";
   if(!ReadTextFile(m_file, m_common, text, err))
      return false;
   if(TrimStr(text) == "")
     {
      err = "state file is empty";
      return false;
     }

   string perr = "";
   CJsonValue *root = JsonParse(text, perr);
   if(root == NULL)
     {
      err = "state file is not valid JSON: " + perr;
      return false;
     }
   if(!root.IsObject())
     {
      delete root;
      err = "state file root is not an object";
      return false;
     }

   bool ok = true;
   bool found = false;
   int schema = (int)root.GetNumberKey("schema", 0.0, found);
   if(!found || schema != STATE_SCHEMA_VERSION)
     {
      err = StringFormat("state schema mismatch (found %d, expected %d)",
                         schema, STATE_SCHEMA_VERSION);
      ok = false;
     }

   if(ok)
     {
      m_day_id             = (int)root.GetNumberKey("day_id", 0.0, found);
      m_week_id            = (int)root.GetNumberKey("week_id", 0.0, found);
      m_day_start_equity   = root.GetNumberKey("day_start_equity", 0.0, found);
      m_week_start_equity  = root.GetNumberKey("week_start_equity", 0.0, found);
      m_peak_equity        = root.GetNumberKey("peak_equity", 0.0, found);
      m_last_equity        = root.GetNumberKey("last_equity", 0.0, found);
      m_consecutive_losses = (int)root.GetNumberKey("consecutive_losses", 0.0, found);
      m_rejections_today   = (int)root.GetNumberKey("rejections_today", 0.0, found);
      m_slip_count         = (int)root.GetNumberKey("slip_count", 0.0, found);
      m_slip_sum_ratio     = root.GetNumberKey("slip_sum_ratio", 0.0, found);
      double saved         = root.GetNumberKey("saved_at", 0.0, found);
      m_saved_at           = (datetime)saved;

      if(m_day_start_equity  < 0.0) m_day_start_equity  = 0.0;
      if(m_week_start_equity < 0.0) m_week_start_equity = 0.0;
      if(m_peak_equity       < 0.0) m_peak_equity       = 0.0;
      if(m_slip_count        < 0)   m_slip_count        = 0;
      if(m_rejections_today  < 0)   m_rejections_today  = 0;
      if(m_consecutive_losses < 0)  m_consecutive_losses = 0;

      CJsonValue *halt = root.Get("halt");
      if(halt != NULL && halt.IsObject())
        {
         m_halt.daily_loss  = halt.GetBoolKey("daily_loss",  false, found);
         m_halt.weekly_loss = halt.GetBoolKey("weekly_loss", false, found);
         m_halt.drawdown    = halt.GetBoolKey("drawdown",    false, found);
         m_halt.loss_streak = halt.GetBoolKey("loss_streak", false, found);
         m_halt.slippage    = halt.GetBoolKey("slippage",    false, found);
         m_halt.rejections  = halt.GetBoolKey("rejections",  false, found);
         m_halt.manual      = halt.GetBoolKey("manual",      false, found);
         m_halt.reason      = halt.GetStringKey("reason", "", found);
         m_halt.since       = (datetime)halt.GetNumberKey("since", 0.0, found);
        }

      CJsonValue *arr = root.Get("positions");
      if(arr != NULL && arr.IsArray())
        {
         int n = arr.Count();
         for(int i = 0; i < n; i++)
           {
            CJsonValue *o = arr.At(i);
            if(o == NULL || !o.IsObject())
               continue;
            PositionMeta pm;
            pm.ticket             = (ulong)o.GetNumberKey("ticket", 0.0, found);
            pm.symbol             = o.GetStringKey("symbol", "", found);
            pm.strategy           = (int)o.GetNumberKey("strategy", 0.0, found);
            pm.direction          = (int)o.GetNumberKey("direction", 0.0, found);
            pm.entry              = o.GetNumberKey("entry", 0.0, found);
            pm.initial_stop       = o.GetNumberKey("initial_stop", 0.0, found);
            pm.initial_risk_price = o.GetNumberKey("initial_risk_price", 0.0, found);
            pm.risk_money         = o.GetNumberKey("risk_money", 0.0, found);
            pm.risk_pct           = o.GetNumberKey("risk_pct", 0.0, found);
            pm.sl_current         = o.GetNumberKey("sl_current", 0.0, found);
            pm.tp_current         = o.GetNumberKey("tp_current", 0.0, found);
            pm.best_price         = o.GetNumberKey("best_price", 0.0, found);
            pm.worst_price        = o.GetNumberKey("worst_price", 0.0, found);
            pm.ai_multiplier      = o.GetNumberKey("ai_multiplier", 1.0, found);
            pm.ml_probability     = o.GetNumberKey("ml_probability", 0.0, found);
            pm.be_done            = o.GetBoolKey("be_done", false, found);
            pm.partial_done       = o.GetBoolKey("partial_done", false, found);
            pm.trailing_active    = o.GetBoolKey("trailing_active", false, found);
            pm.opened_at          = (datetime)o.GetNumberKey("opened_at", 0.0, found);
            pm.last_update        = (datetime)o.GetNumberKey("last_update", 0.0, found);
            pm.setup_id           = o.GetStringKey("setup_id", "", found);
            pm.comment            = o.GetStringKey("comment", "", found);
            if(pm.ticket == 0 || pm.symbol == "")
               continue;
            int idx = FindIndex(pm.ticket);
            if(idx < 0)
               AddPosition(pm);
           }
        }
     }

   delete root;
   if(!ok)
      return false;

   m_dirty = false;
   return true;
  }

//+------------------------------------------------------------------+
//| Write the whole state atomically.                                 |
//+------------------------------------------------------------------+
bool CStateStore::Save(string &err)
  {
   err = "";
   CJsonValue *root = new CJsonValue();
   if(root == NULL)
     {
      err = "out of memory building state";
      return false;
     }
   root.SetObject();

   CJsonValue *v = NULL;

   v = new CJsonValue(); v.SetString(EA_NAME);        root.AddKey("ea", v);
   v = new CJsonValue(); v.SetString(EA_VERSION);     root.AddKey("version", v);
   v = new CJsonValue(); v.SetNumber(STATE_SCHEMA_VERSION); root.AddKey("schema", v);
   v = new CJsonValue(); v.SetNumber((double)TimeTradeServer()); root.AddKey("saved_at", v);

   v = new CJsonValue(); v.SetNumber(m_day_id);             root.AddKey("day_id", v);
   v = new CJsonValue(); v.SetNumber(m_week_id);            root.AddKey("week_id", v);
   v = new CJsonValue(); v.SetNumber(m_day_start_equity);   root.AddKey("day_start_equity", v);
   v = new CJsonValue(); v.SetNumber(m_week_start_equity);  root.AddKey("week_start_equity", v);
   v = new CJsonValue(); v.SetNumber(m_peak_equity);        root.AddKey("peak_equity", v);
   v = new CJsonValue(); v.SetNumber(m_last_equity);        root.AddKey("last_equity", v);
   v = new CJsonValue(); v.SetNumber(m_consecutive_losses); root.AddKey("consecutive_losses", v);
   v = new CJsonValue(); v.SetNumber(m_rejections_today);   root.AddKey("rejections_today", v);
   v = new CJsonValue(); v.SetNumber(m_slip_count);         root.AddKey("slip_count", v);
   v = new CJsonValue(); v.SetNumber(m_slip_sum_ratio);     root.AddKey("slip_sum_ratio", v);

   CJsonValue *halt = new CJsonValue();
   halt.SetObject();
   CJsonValue *h = NULL;
   h = new CJsonValue(); h.SetBool(m_halt.daily_loss);  halt.AddKey("daily_loss", h);
   h = new CJsonValue(); h.SetBool(m_halt.weekly_loss); halt.AddKey("weekly_loss", h);
   h = new CJsonValue(); h.SetBool(m_halt.drawdown);    halt.AddKey("drawdown", h);
   h = new CJsonValue(); h.SetBool(m_halt.loss_streak); halt.AddKey("loss_streak", h);
   h = new CJsonValue(); h.SetBool(m_halt.slippage);    halt.AddKey("slippage", h);
   h = new CJsonValue(); h.SetBool(m_halt.rejections);  halt.AddKey("rejections", h);
   h = new CJsonValue(); h.SetBool(m_halt.manual);      halt.AddKey("manual", h);
   h = new CJsonValue(); h.SetString(m_halt.reason);    halt.AddKey("reason", h);
   h = new CJsonValue(); h.SetNumber((double)m_halt.since); halt.AddKey("since", h);
   root.AddKey("halt", halt);

   CJsonValue *arr = new CJsonValue();
   arr.SetArray();
   for(int i = 0; i < ArraySize(m_pos); i++)
     {
      CJsonValue *o = new CJsonValue();
      o.SetObject();
      CJsonValue *f = NULL;
      f = new CJsonValue(); f.SetNumber((double)m_pos[i].ticket);           o.AddKey("ticket", f);
      f = new CJsonValue(); f.SetString(m_pos[i].symbol);                   o.AddKey("symbol", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].strategy);                 o.AddKey("strategy", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].direction);                o.AddKey("direction", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].entry);                    o.AddKey("entry", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].initial_stop);             o.AddKey("initial_stop", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].initial_risk_price);       o.AddKey("initial_risk_price", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].risk_money);               o.AddKey("risk_money", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].risk_pct);                 o.AddKey("risk_pct", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].sl_current);               o.AddKey("sl_current", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].tp_current);               o.AddKey("tp_current", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].best_price);               o.AddKey("best_price", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].worst_price);              o.AddKey("worst_price", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].ai_multiplier);            o.AddKey("ai_multiplier", f);
      f = new CJsonValue(); f.SetNumber(m_pos[i].ml_probability);           o.AddKey("ml_probability", f);
      f = new CJsonValue(); f.SetBool(m_pos[i].be_done);                    o.AddKey("be_done", f);
      f = new CJsonValue(); f.SetBool(m_pos[i].partial_done);               o.AddKey("partial_done", f);
      f = new CJsonValue(); f.SetBool(m_pos[i].trailing_active);            o.AddKey("trailing_active", f);
      f = new CJsonValue(); f.SetNumber((double)m_pos[i].opened_at);        o.AddKey("opened_at", f);
      f = new CJsonValue(); f.SetNumber((double)m_pos[i].last_update);      o.AddKey("last_update", f);
      f = new CJsonValue(); f.SetString(m_pos[i].setup_id);                 o.AddKey("setup_id", f);
      f = new CJsonValue(); f.SetString(m_pos[i].comment);                  o.AddKey("comment", f);
      arr.Append(o);
     }
   root.AddKey("positions", arr);

   string body = root.ToJsonPretty(1);
   delete root;

   if(!WriteAtomic(body, err))
      return false;
   m_dirty = false;
   return true;
  }

//+------------------------------------------------------------------+
bool CStateStore::WriteAtomic(const string body, string &err)
  {
   err = "";
   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(m_common)
      flags |= FILE_COMMON;

   string tmp = m_file + ".tmp";
   int h = FileOpen(tmp, flags);
   if(h == INVALID_HANDLE)
     {
      err = StringFormat("cannot open state temp file '%s' (error %d)",
                         tmp, GetLastError());
      return false;
     }
   uint written = FileWriteString(h, body, StringLen(body));
   FileFlush(h);
   FileClose(h);
   if(written == 0 && StringLen(body) > 0)
     {
      err = "state temp file write returned zero bytes";
      return false;
     }

   if(!FileMove(tmp, m_common ? FILE_COMMON : 0, m_file, FILE_REWRITE))
     {
      err = StringFormat("cannot replace state file '%s' (error %d)",
                         m_file, GetLastError());
      FileDelete(tmp, m_common ? FILE_COMMON : 0);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void CStateStore::UpdateEquity(const double equity)
  {
   if(!IsFinite(equity) || equity <= 0.0)
      return;
   m_last_equity = equity;
   if(equity > m_peak_equity)
      m_peak_equity = equity;
   m_dirty = true;
  }

//+------------------------------------------------------------------+
//| Roll day/week anchors. Returns true when anything changed.        |
//+------------------------------------------------------------------+
bool CStateStore::Roll(const int day_id, const int week_id, const double equity)
  {
   bool changed = false;
   double anchor = (IsFinite(equity) && equity > 0.0) ? equity : m_last_equity;

   if(m_day_id != day_id)
     {
      m_day_id            = day_id;
      m_day_start_equity  = anchor;
      m_rejections_today  = 0;
      m_slip_count        = 0;
      m_slip_sum_ratio    = 0.0;
      m_halt.daily_loss   = false;
      m_halt.rejections   = false;
      m_halt.slippage     = false;
      changed = true;
     }

   if(m_week_id != week_id)
     {
      m_week_id           = week_id;
      m_week_start_equity = anchor;
      m_halt.weekly_loss  = false;
      changed = true;
     }

   if(m_day_start_equity <= 0.0)
     {
      m_day_start_equity = anchor;
      changed = true;
     }
   if(m_week_start_equity <= 0.0)
     {
      m_week_start_equity = anchor;
      changed = true;
     }
   if(m_peak_equity <= 0.0)
     {
      m_peak_equity = anchor;
      changed = true;
     }

   if(changed)
      m_dirty = true;
   return changed;
  }

//+------------------------------------------------------------------+
void CStateStore::ResetHalts(void)
  {
   m_halt.daily_loss  = false;
   m_halt.weekly_loss = false;
   m_halt.drawdown    = false;
   m_halt.loss_streak = false;
   m_halt.slippage    = false;
   m_halt.rejections  = false;
   m_halt.manual      = false;
   m_halt.reason      = "";
   m_halt.since       = 0;
   m_dirty = true;
  }

void CStateStore::SetConsecutiveLosses(const int v)
  {
   int nv = MathMax(0, v);
   if(nv != m_consecutive_losses)
     {
      m_consecutive_losses = nv;
      m_dirty = true;
     }
  }

void CStateStore::NoteRejection(void)
  {
   m_rejections_today++;
   m_dirty = true;
  }

void CStateStore::NoteSlippage(const double ratio)
  {
   if(!IsFinite(ratio))
      return;
   m_slip_count++;
   m_slip_sum_ratio += MathAbs(ratio);
   m_dirty = true;
  }

void CStateStore::LatchDailyLoss(const string why)
  {
   m_halt.daily_loss = true;
   m_halt.reason = why;
   if(m_halt.since == 0) m_halt.since = TimeTradeServer();
   m_dirty = true;
  }

void CStateStore::LatchWeeklyLoss(const string why)
  {
   m_halt.weekly_loss = true;
   m_halt.reason = why;
   if(m_halt.since == 0) m_halt.since = TimeTradeServer();
   m_dirty = true;
  }

void CStateStore::LatchDrawdown(const string why)
  {
   m_halt.drawdown = true;
   m_halt.reason = why;
   if(m_halt.since == 0) m_halt.since = TimeTradeServer();
   m_dirty = true;
  }

void CStateStore::LatchLossStreak(const string why)
  {
   m_halt.loss_streak = true;
   m_halt.reason = why;
   if(m_halt.since == 0) m_halt.since = TimeTradeServer();
   m_dirty = true;
  }

void CStateStore::LatchSlippage(const string why)
  {
   m_halt.slippage = true;
   m_halt.reason = why;
   if(m_halt.since == 0) m_halt.since = TimeTradeServer();
   m_dirty = true;
  }

void CStateStore::LatchRejections(const string why)
  {
   m_halt.rejections = true;
   m_halt.reason = why;
   if(m_halt.since == 0) m_halt.since = TimeTradeServer();
   m_dirty = true;
  }

void CStateStore::LatchManual(const string why)
  {
   m_halt.manual = true;
   m_halt.reason = why;
   if(m_halt.since == 0) m_halt.since = TimeTradeServer();
   m_dirty = true;
  }

void CStateStore::ClearManual(void)
  {
   if(m_halt.manual)
     {
      m_halt.manual = false;
      m_dirty = true;
     }
  }

//+------------------------------------------------------------------+
//| Position metadata                                                 |
//+------------------------------------------------------------------+
int CStateStore::FindIndex(const ulong ticket) const
  {
   for(int i = 0; i < ArraySize(m_pos); i++)
      if(m_pos[i].ticket == ticket)
         return i;
   return -1;
  }

bool CStateStore::PositionAt(const int i, PositionMeta &out) const
  {
   if(i < 0 || i >= ArraySize(m_pos))
      return false;
   out = m_pos[i];
   return true;
  }

bool CStateStore::FindPosition(const ulong ticket, PositionMeta &out) const
  {
   int i = FindIndex(ticket);
   if(i < 0)
      return false;
   out = m_pos[i];
   return true;
  }

bool CStateStore::AddPosition(const PositionMeta &pm)
  {
   if(pm.ticket == 0)
      return false;
   int i = FindIndex(pm.ticket);
   if(i >= 0)
     {
      m_pos[i] = pm;
      m_dirty = true;
      return true;
     }
   int n = ArraySize(m_pos);
   if(!ArrayResize(m_pos, n + 1))
      return false;
   m_pos[n] = pm;
   m_dirty = true;
   return true;
  }

bool CStateStore::UpdatePosition(const PositionMeta &pm)
  {
   int i = FindIndex(pm.ticket);
   if(i < 0)
      return false;
   m_pos[i] = pm;
   m_dirty = true;
   return true;
  }

bool CStateStore::RemovePosition(const ulong ticket)
  {
   int i = FindIndex(ticket);
   if(i < 0)
      return false;
   int n = ArraySize(m_pos);
   for(int k = i; k < n - 1; k++)
      m_pos[k] = m_pos[k + 1];
   ArrayResize(m_pos, n - 1);
   m_dirty = true;
   return true;
  }

void CStateStore::ClearPositions(void)
  {
   if(ArraySize(m_pos) > 0)
     {
      ArrayResize(m_pos, 0);
      m_dirty = true;
     }
  }

//+------------------------------------------------------------------+
double CStateStore::SumOpenRiskMoney(void) const
  {
   double s = 0.0;
   for(int i = 0; i < ArraySize(m_pos); i++)
      if(IsFinite(m_pos[i].risk_money) && m_pos[i].risk_money > 0.0)
         s += m_pos[i].risk_money;
   return s;
  }

double CStateStore::SumOpenRiskPct(const double equity) const
  {
   if(!IsFinite(equity) || equity <= 0.0)
      return 0.0;
   return 100.0 * SumOpenRiskMoney() / equity;
  }

int CStateStore::CountOpenForSymbol(const string symbol) const
  {
   int n = 0;
   for(int i = 0; i < ArraySize(m_pos); i++)
      if(m_pos[i].symbol == symbol)
         n++;
   return n;
  }

int CStateStore::CountOpenForGroup(const string group,
                                   const string &symbols[],
                                   const string &groups[]) const
  {
   if(group == "")
      return 0;
   int n = 0;
   for(int i = 0; i < ArraySize(m_pos); i++)
     {
      for(int k = 0; k < ArraySize(symbols); k++)
        {
         if(symbols[k] == m_pos[i].symbol)
           {
            if(k < ArraySize(groups) && groups[k] == group)
               n++;
            break;
           }
        }
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Compact position list handed to the external AI advisor.          |
//+------------------------------------------------------------------+
void CStateStore::PositionsJson(string &out) const
  {
   out = "[";
   bool first = true;
   for(int i = 0; i < ArraySize(m_pos); i++)
     {
      if(!first)
         out += ",";
      first = false;
      out += StringFormat("{\"symbol\":\"%s\",\"direction\":%d,\"risk_pct\":%.4f}",
                          JsonEscape(m_pos[i].symbol),
                          m_pos[i].direction,
                          m_pos[i].risk_pct);
     }
   out += "]";
  }

#endif
//+------------------------------------------------------------------+
