//+------------------------------------------------------------------+
//|                                                     Sessions.mqh |
//|  Market session state machine driven by UTC.                      |
//|                                                                  |
//|  Broker server time is converted to UTC once per update using an  |
//|  explicit offset or an auto-detected offset. Session windows are  |
//|  configured in UTC so DST changes do not require EA changes, but  |
//|  the offset itself must be verified after any DST transition.     |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_SESSIONS_MQH__
#define __DERIV_AI_SESSIONS_MQH__

#include <Config.mqh>
#include <Utils.mqh>

struct SessionContext
  {
   ENUM_SESSION_STATE state;
   datetime           utc_now;
   datetime           server_now;
   datetime           session_start_utc;
   int                minutes_since_open;
   int                offset_seconds;
   bool               trading_allowed;
   double             risk_scale;
   bool               weekend;
   string             name;
  };

class CSessionEngine
  {
private:
   SessionConfig      m_cfg;
   int                m_offset_seconds;
   bool               m_auto_offset;
   ENUM_SESSION_STATE m_state;
   datetime           m_utc_now;
   datetime           m_server_now;
   datetime           m_session_start;
   string             m_warning;

   int                Minute(const int h, const int m) { return h * 60 + m; }
   void               DetectOffset(const datetime server_now);
   datetime           WindowStartToday(const datetime utc, const int start_min);
   double             ScaleFor(const ENUM_SESSION_STATE st) const;

public:
                     CSessionEngine(void);
   bool              Init(const SessionConfig &cfg, string &err);
   void              Update(const datetime server_now);
   bool              UtcWindowContains(const datetime utc, const int start_min, const int end_min);

   datetime          UtcNow(void) const    { return m_utc_now; }
   datetime          ServerNow(void) const { return m_server_now; }
   datetime          ServerToUtc(const datetime server) const { return server - m_offset_seconds; }
   datetime          UtcToServer(const datetime utc) const    { return utc + m_offset_seconds; }
   ENUM_SESSION_STATE State(void) const    { return m_state; }
   string            StateName(void) const  { return SessionStateToString(m_state); }
   bool              TradingAllowed(void) const;
   double            RiskScale(void) const { return ScaleFor(m_state); }
   bool              IsOpeningWindow(void) const
     { return (m_state == SESSION_LONDON_OPEN || m_state == SESSION_NY_OPEN); }
   bool              IsCoreWindow(void) const
     { return (m_state == SESSION_LONDON_CORE || m_state == SESSION_NY_CORE); }
   bool              IsAnyOpenWindow(void) const
     { return (m_state == SESSION_LONDON_OPEN || m_state == SESSION_NY_OPEN ||
               m_state == SESSION_LONDON_CORE || m_state == SESSION_NY_CORE); }
   datetime          SessionStartUtc(void) const { return m_session_start; }
   int               MinutesSinceSessionStart(void) const;
   int               OffsetSeconds(void) const { return m_offset_seconds; }
   int               OpeningRangeMinutes(void) const { return m_cfg.opening_range_minutes; }
   bool              IsWeekend(void) const
     {
      MqlDateTime dt;
      TimeToStruct(m_utc_now, dt);
      return (dt.day_of_week == 0 || dt.day_of_week == 6);
     }
   string            Warning(void) const   { return m_warning; }
   void              GetContext(SessionContext &ctx) const;
  };

//+------------------------------------------------------------------+
CSessionEngine::CSessionEngine(void)
  {
   m_offset_seconds = 0;
   m_auto_offset = false;
   m_state = SESSION_CLOSED;
   m_utc_now = 0;
   m_server_now = 0;
   m_session_start = 0;
   m_warning = "";
  }

bool CSessionEngine::Init(const SessionConfig &cfg, string &err)
  {
   m_cfg = cfg;
   err = "";
   if(cfg.asian_start_hour < 0 || cfg.asian_start_hour > 23 ||
      cfg.asian_end_hour < 0 || cfg.asian_end_hour > 23 ||
      cfg.london_open_hour < 0 || cfg.london_open_hour > 23 ||
      cfg.ny_open_hour < 0 || cfg.ny_open_hour > 23 ||
      cfg.rollover_start_hour < 0 || cfg.rollover_start_hour > 23 ||
      cfg.rollover_end_hour < 0 || cfg.rollover_end_hour > 23)
     {
      err = "session hours must be within 0..23";
      return false;
     }
   if(cfg.asian_start_min < 0 || cfg.asian_start_min > 59 ||
      cfg.asian_end_min < 0 || cfg.asian_end_min > 59 ||
      cfg.london_open_min < 0 || cfg.london_open_min > 59 ||
      cfg.ny_open_min < 0 || cfg.ny_open_min > 59 ||
      cfg.rollover_start_min < 0 || cfg.rollover_start_min > 59 ||
      cfg.rollover_end_min < 0 || cfg.rollover_end_min > 59)
     {
      err = "session minutes must be within 0..59";
      return false;
     }
   if(cfg.opening_range_minutes < 5 || cfg.opening_range_minutes > 180)
     {
      err = "opening_range_minutes must be 5..180";
      return false;
     }
   if(cfg.preopen_minutes < 0 || cfg.preopen_minutes > 120)
     {
      err = "preopen_minutes must be 0..120";
      return false;
     }
   int asian_s = cfg.asian_start_hour * 60 + cfg.asian_start_min;
   int asian_e = cfg.asian_end_hour * 60 + cfg.asian_end_min;
   int london_s = cfg.london_open_hour * 60 + cfg.london_open_min;
   int ny_s = cfg.ny_open_hour * 60 + cfg.ny_open_min;
   int roll_s = cfg.rollover_start_hour * 60 + cfg.rollover_start_min;
   int roll_e = cfg.rollover_end_hour * 60 + cfg.rollover_end_min;
   if(asian_s == asian_e)
     {
      err = "asian session window must not be zero length";
      return false;
     }
   if(roll_s == roll_e)
     {
      err = "rollover window must not be zero length";
      return false;
     }
   if(london_s >= ny_s)
     {
      err = "london_open must precede ny_open (UTC minutes)";
      return false;
     }
   if(roll_s > ny_s && roll_s <= ny_s + cfg.opening_range_minutes)
     {
      err = "rollover must not start inside the NY opening range";
      return false;
     }
   m_auto_offset = (cfg.utc_offset_override == 99);
   if(!m_auto_offset && (cfg.utc_offset_override < -12 || cfg.utc_offset_override > 14))
     {
      err = "utc_offset_override must be -12..14 or 99 for auto";
      return false;
     }
   m_offset_seconds = m_auto_offset ? 0 : cfg.utc_offset_override * 3600;
   m_warning = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Auto-detect broker server offset. TimeGMT() depends on the local  |
//| PC clock/timezone, so the value is rounded to 15 minutes and      |
//| clamped to plausible broker offsets. A fixed override is the      |
//| supported answer when the workstation clock is not trustworthy.   |
//+------------------------------------------------------------------+
void CSessionEngine::DetectOffset(const datetime server_now)
  {
   if(!m_auto_offset)
      return;
   long raw = (long)server_now - (long)TimeGMT();
   long rounded = (long)(MathRound((double)raw / 900.0) * 900.0);
   if(rounded < -12 * 3600)
      rounded = -12 * 3600;
   if(rounded > 14 * 3600)
      rounded = 14 * 3600;
   if(m_offset_seconds != 0 && MathAbs((int)(rounded - m_offset_seconds)) >= 1800)
      LogWarn(StringFormat("server UTC offset changed from %+.2fh to %+.2fh (DST?) - verify session windows",
                           m_offset_seconds / 3600.0, (double)rounded / 3600.0));
   m_offset_seconds = (int)rounded;
  }

datetime CSessionEngine::WindowStartToday(const datetime utc, const int start_min)
  {
   datetime midnight = DayFloor(utc, 0);
   datetime start = midnight + start_min * 60;
   if(start > utc)
      start -= 86400;
   return start;
  }

bool CSessionEngine::UtcWindowContains(const datetime utc, const int start_min, const int end_min)
  {
   return MinuteInWindow(MinuteOfDay(utc), start_min, end_min);
  }

//+------------------------------------------------------------------+
//| Recompute session state. Called every tick; cheap and stateless   |
//| apart from the detected offset.                                   |
//+------------------------------------------------------------------+
void CSessionEngine::Update(const datetime server_now)
  {
   m_server_now = server_now;
   DetectOffset(server_now);
   m_utc_now = server_now - m_offset_seconds;

   const int asian_s    = Minute(m_cfg.asian_start_hour, m_cfg.asian_start_min);
   const int asian_e    = Minute(m_cfg.asian_end_hour, m_cfg.asian_end_min);
   const int london_s   = Minute(m_cfg.london_open_hour, m_cfg.london_open_min);
   const int ny_s       = Minute(m_cfg.ny_open_hour, m_cfg.ny_open_min);
   const int roll_s     = Minute(m_cfg.rollover_start_hour, m_cfg.rollover_start_min);
   const int roll_e     = Minute(m_cfg.rollover_end_hour, m_cfg.rollover_end_min);
   const int or_min     = m_cfg.opening_range_minutes;
   const int pre        = m_cfg.preopen_minutes;
   const int london_or_end = MathMin(1439, london_s + or_min);
   const int ny_or_end     = MathMin(1439, ny_s + or_min);
   const int minute     = MinuteOfDay(m_utc_now);
   // Intraday segments must be non-empty; an empty segment is skipped
   // rather than being interpreted as a 24h window.
   int london_core_end = ny_s - pre;
   if(london_core_end < london_or_end)
      london_core_end = london_or_end;
   int ny_core_end = 1440;
   if(roll_s > ny_or_end)
      ny_core_end = roll_s;

   m_state = SESSION_CLOSED;
   m_session_start = 0;

   if(MinuteInWindow(minute, roll_s, roll_e))
     {
      m_state = SESSION_ROLLOVER;
      m_session_start = WindowStartToday(m_utc_now, roll_s);
      return;
     }
   if(pre > 0 && london_s - pre != london_s &&
      MinuteInWindow(minute, london_s - pre, london_s))
     {
      m_state = SESSION_LONDON_PREOPEN;
      m_session_start = WindowStartToday(m_utc_now, london_s);
      if(m_session_start < m_utc_now)
         m_session_start += 86400;
      return;
     }
   if(minute >= london_s && minute < london_or_end)
     {
      m_state = SESSION_LONDON_OPEN;
      m_session_start = WindowStartToday(m_utc_now, london_s);
      return;
     }
   if(minute >= london_or_end && minute < london_core_end)
     {
      m_state = SESSION_LONDON_CORE;
      m_session_start = WindowStartToday(m_utc_now, london_s);
      return;
     }
   if(pre > 0 && minute >= ny_s - pre && minute < ny_s)
     {
      m_state = SESSION_NY_PREOPEN;
      m_session_start = WindowStartToday(m_utc_now, ny_s);
      if(m_session_start < m_utc_now)
         m_session_start += 86400;
      return;
     }
   if(minute >= ny_s && minute < ny_or_end)
     {
      m_state = SESSION_NY_OPEN;
      m_session_start = WindowStartToday(m_utc_now, ny_s);
      return;
     }
   if(minute >= ny_or_end && minute < ny_core_end)
     {
      m_state = SESSION_NY_CORE;
      m_session_start = WindowStartToday(m_utc_now, ny_s);
      return;
     }
   if(MinuteInWindow(minute, asian_s, asian_e))
     {
      m_state = SESSION_ASIAN;
      m_session_start = WindowStartToday(m_utc_now, asian_s);
      return;
     }
   m_state = SESSION_CLOSED;
  }

bool CSessionEngine::TradingAllowed(void) const
  {
   switch(m_state)
     {
      case SESSION_ASIAN:          return m_cfg.enable_asian;
      case SESSION_LONDON_PREOPEN: return false;
      case SESSION_LONDON_OPEN:
      case SESSION_LONDON_CORE:    return m_cfg.enable_london;
      case SESSION_NY_PREOPEN:     return false;
      case SESSION_NY_OPEN:
      case SESSION_NY_CORE:        return m_cfg.enable_ny;
      default:                     return false;
     }
  }

double CSessionEngine::ScaleFor(const ENUM_SESSION_STATE st) const
  {
   switch(st)
     {
      case SESSION_ASIAN:          return m_cfg.enable_asian ? ClampD(m_cfg.risk_scale_asian, 0.0, 1.5) : 0.0;
      case SESSION_LONDON_PREOPEN: return ClampD(m_cfg.risk_scale_preopen, 0.0, 1.5);
      case SESSION_NY_PREOPEN:     return ClampD(m_cfg.risk_scale_preopen, 0.0, 1.5);
      case SESSION_LONDON_OPEN:    return m_cfg.enable_london ? ClampD(m_cfg.risk_scale_open, 0.0, 1.5) : 0.0;
      case SESSION_NY_OPEN:        return m_cfg.enable_ny ? ClampD(m_cfg.risk_scale_open, 0.0, 1.5) : 0.0;
      case SESSION_LONDON_CORE:
      case SESSION_NY_CORE:        return ClampD(m_cfg.risk_scale_core, 0.0, 1.5);
      default:                     return 0.0;
     }
  }

int CSessionEngine::MinutesSinceSessionStart(void) const
  {
   if(m_session_start <= 0)
      return 0;
   int mins = (int)((m_utc_now - m_session_start) / 60);
   return MathMax(0, mins);
  }

void CSessionEngine::GetContext(SessionContext &ctx) const
  {
   ctx.state = m_state;
   ctx.utc_now = m_utc_now;
   ctx.server_now = m_server_now;
   ctx.session_start_utc = m_session_start;
   ctx.minutes_since_open = MinutesSinceSessionStart();
   ctx.offset_seconds = m_offset_seconds;
   ctx.trading_allowed = TradingAllowed();
   ctx.risk_scale = RiskScale();
   ctx.weekend = IsWeekend();
   ctx.name = StateName();
  }

//+------------------------------------------------------------------+
//| Symbol session profiles from the CSV. Profiles are only labels    |
//| that map to enabled session states; they never override the       |
//| broker's own trading hours.                                       |
//+------------------------------------------------------------------+
bool ProfileAllowsSession(const string profile, const ENUM_SESSION_STATE st)
  {
   string p = LowerStr(TrimStr(profile));
   bool london = (st == SESSION_LONDON_OPEN || st == SESSION_LONDON_CORE ||
                  st == SESSION_LONDON_PREOPEN);
   bool ny     = (st == SESSION_NY_OPEN || st == SESSION_NY_CORE || st == SESSION_NY_PREOPEN);
   bool asian  = (st == SESSION_ASIAN);

   if(p == "" || p == "all" || p == "any")
      return (st != SESSION_CLOSED && st != SESSION_ROLLOVER);
   if(p == "london_ny" || p == "london_newyork")
      return (london || ny);
   if(p == "tokyo_london_ny" || p == "asia_london_ny" || p == "all_sessions")
      return (asian || london || ny);
   if(p == "us_cash" || p == "us" || p == "newyork")
      return (st == SESSION_NY_OPEN || st == SESSION_NY_CORE);
   if(p == "europe_cash" || p == "europe" || p == "london")
      return (st == SESSION_LONDON_OPEN || st == SESSION_LONDON_CORE);
   if(p == "asia" || p == "asian" || p == "tokyo")
      return asian;
   // Unknown profile: fail closed, surface it in the journal.
   return false;
  }

#endif
//+------------------------------------------------------------------+
