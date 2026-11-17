//+------------------------------------------------------------------+
//|                                                  NewsCalendar.mqh |
//|  High/medium impact economic calendar with a CSV fallback so the   |
//|  filter also works in the Strategy Tester.                        |
//|                                                                  |
//|  Live source : MT5 economic calendar API (server time basis by    |
//|                default, configurable).                            |
//|  Fallback    : calendar_history.csv in UTC.                       |
//|  Unavailable : policy is explicit and defaults to fail-closed.     |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_NEWSCALENDAR_MQH__
#define __DERIV_AI_NEWSCALENDAR_MQH__

#include <Config.mqh>
#include <Utils.mqh>
#include <SymbolSpec.mqh>

struct NewsEvent
  {
   long     id;
   datetime time_utc;
   string   currency;
   string   country;
   string   name;
   int      impact;          // 0 none, 1 low, 2 medium, 3 high
   double   forecast;
   double   previous;
   double   actual;
   bool     has_actual;
   bool     has_forecast;
   bool     has_previous;
  };

struct NewsContext
  {
   bool     available;
   bool     blackout;
   string   blackout_reason;
   datetime blocked_until;
   int      minutes_to_next;
   int      next_impact;
   string   next_event;
   string   next_currency;
   double   risk_multiplier;
   int      event_count;
   string   source;
  };

//+------------------------------------------------------------------+
class CNewsCalendar
  {
private:
   NewsConfig         m_cfg;
   NewsEvent          m_events[];
   string             m_currencies[];
   datetime           m_loaded_at;
   bool               m_available;
   bool               m_refresh_attempted;
   string             m_source;
   string             m_error;
   bool               m_tester;

   bool               LoadCsv(string &err);
   bool               LoadLive(const datetime utc_now, const int offset_seconds, string &err);
   void               AddEvent(const NewsEvent &e);
   void               SortAndDedup(void);
   bool               CurrencyRelevant(const string currency, const string list);
   int                ParseImpact(const string s);
   void               BuildQueryCurrencies(const string &configured[]);
   string             NextEventText(const datetime utc_now, const string list, int &impact, int &minutes);

public:
                     CNewsCalendar(void);
   bool               Init(const NewsConfig &cfg, const string &configured_currencies[],
                           const bool tester, string &err);
   bool               Refresh(const datetime utc_now, const int offset_seconds, string &err);
   bool               RefreshIfStale(const datetime utc_now, const int offset_seconds, string &err);
   bool               BuildContext(const string symbol, const string currencies,
                                   const datetime utc_now, NewsContext &ctx);
   bool               Available(void)      { return m_available; }
   string             Source(void)        { return m_source; }
   string             LastError(void)     { return m_error; }
   int                EventCount(void)    { return ArraySize(m_events); }
  };

//+------------------------------------------------------------------+
CNewsCalendar::CNewsCalendar(void)
  {
   m_loaded_at = 0;
   m_available = false;
   m_refresh_attempted = false;
   m_source = "none";
   m_error = "";
   m_tester = false;
  }

int CNewsCalendar::ParseImpact(const string s)
  {
   string v = LowerStr(TrimStr(s));
   if(v == "high" || v == "3" || v == "h")
      return 3;
   if(v == "medium" || v == "moderate" || v == "2" || v == "m")
      return 2;
   if(v == "low" || v == "1" || v == "l")
      return 1;
   return 0;
  }

void CNewsCalendar::AddEvent(const NewsEvent &e)
  {
   int n = ArraySize(m_events);
   if(!ArrayResize(m_events, n + 1))
      return;
   m_events[n] = e;
  }

//+------------------------------------------------------------------+
//| Sort ascending by time and drop exact duplicates from repeated     |
//| currency queries.                                                  |
//+------------------------------------------------------------------+
void CNewsCalendar::SortAndDedup(void)
  {
   int n = ArraySize(m_events);
   for(int i = 1; i < n; i++)
     {
      NewsEvent key = m_events[i];
      int j = i - 1;
      while(j >= 0 && m_events[j].time_utc > key.time_utc)
        {
         m_events[j + 1] = m_events[j];
         j--;
        }
      m_events[j + 1] = key;
     }
   NewsEvent unique[];
   ArrayResize(unique, 0);
   for(int i = 0; i < n; i++)
     {
      bool dup = false;
      int un = ArraySize(unique);
      for(int k = MathMax(0, un - 8); k < un; k++)
        {
         if(unique[k].id == m_events[i].id &&
            unique[k].time_utc == m_events[i].time_utc &&
            unique[k].currency == m_events[i].currency)
           {
            dup = true;
            break;
           }
        }
      if(!dup)
        {
         int sz = ArraySize(unique);
         ArrayResize(unique, sz + 1);
         unique[sz] = m_events[i];
        }
     }
   ArrayResize(m_events, 0);
   for(int i = 0; i < ArraySize(unique); i++)
     {
      int n = ArraySize(m_events);
      ArrayResize(m_events, n + 1);
      m_events[n] = unique[i];
     }
  }

void CNewsCalendar::BuildQueryCurrencies(const string &configured[])
  {
   ArrayResize(m_currencies, 0);
   for(int i = 0; i < ArraySize(configured); i++)
     {
      string c = UpperStr(TrimStr(configured[i]));
      if(c == "" || StringLen(c) > 4)
         continue;
      bool exists = false;
      for(int k = 0; k < ArraySize(m_currencies); k++)
         if(m_currencies[k] == c)
           {
            exists = true;
            break;
           }
      if(!exists)
        {
         int n = ArraySize(m_currencies);
         ArrayResize(m_currencies, n + 1);
         m_currencies[n] = c;
        }
     }
  }

//+------------------------------------------------------------------+
bool CNewsCalendar::LoadCsv(string &err)
  {
   string lines[];
   if(!ReadTextLines(m_cfg.csv_file, m_cfg.common_folder, lines, err))
      return false;
   if(ArraySize(lines) < 2)
     {
      err = "calendar CSV has no data rows";
      return false;
     }
   string head[];
   int hc = CsvSplit(lines[0], ',', head);
   for(int i = 0; i < hc; i++)
      head[i] = LowerStr(TrimStr(head[i]));
   int i_id = -1, i_time = -1, i_cur = -1, i_country = -1, i_name = -1;
   int i_imp = -1, i_fc = -1, i_prev = -1, i_act = -1;
   for(int i = 0; i < hc; i++)
     {
      if(head[i] == "event_id")        i_id = i;
      else if(head[i] == "time_utc" || head[i] == "time") i_time = i;
      else if(head[i] == "currency")   i_cur = i;
      else if(head[i] == "country")    i_country = i;
      else if(head[i] == "event" || head[i] == "event_name") i_name = i;
      else if(head[i] == "impact")     i_imp = i;
      else if(head[i] == "forecast")   i_fc = i;
      else if(head[i] == "previous")   i_prev = i;
      else if(head[i] == "actual")     i_act = i;
     }
   if(i_time < 0 || i_cur < 0 || i_imp < 0)
     {
      err = "calendar CSV requires time_utc, currency and impact columns";
      return false;
     }
   int loaded = 0;
   for(int r = 1; r < ArraySize(lines); r++)
     {
      string line = TrimStr(lines[r]);
      if(line == "" || StringGetCharacter(line, 0) == '#')
         continue;
      string f[];
      int fc = CsvSplit(line, ',', f);
      if(fc <= MathMax(i_time, MathMax(i_cur, i_imp)))
         continue;
      NewsEvent e;
      e.id = (i_id >= 0 && i_id < fc) ? StringToInteger(TrimStr(f[i_id])) : (long)r;
      string ts = TrimStr(f[i_time]);
      StringReplace(ts, "T", " ");
      StringReplace(ts, "Z", "");
      e.time_utc = StringToTime(ts);
      if(e.time_utc <= 0)
         continue;
      e.currency = UpperStr(TrimStr(f[i_cur]));
      e.country = (i_country >= 0 && i_country < fc) ? TrimStr(f[i_country]) : "";
      e.name = (i_name >= 0 && i_name < fc) ? TrimStr(f[i_name]) : "";
      e.impact = ParseImpact(f[i_imp]);
      e.forecast = (i_fc >= 0 && i_fc < fc) ? StringToDouble(TrimStr(f[i_fc])) : 0.0;
      e.previous = (i_prev >= 0 && i_prev < fc) ? StringToDouble(TrimStr(f[i_prev])) : 0.0;
      e.actual = (i_act >= 0 && i_act < fc) ? StringToDouble(TrimStr(f[i_act])) : 0.0;
      e.has_forecast = (i_fc >= 0 && i_fc < fc && TrimStr(f[i_fc]) != "");
      e.has_previous = (i_prev >= 0 && i_prev < fc && TrimStr(f[i_prev]) != "");
      e.has_actual = (i_act >= 0 && i_act < fc && TrimStr(f[i_act]) != "");
      AddEvent(e);
      loaded++;
     }
   SortAndDedup();
   if(loaded == 0)
     {
      err = "calendar CSV contains no valid events";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Live calendar. Times are interpreted according to the configured   |
//| basis and always stored in UTC.                                   |
//+------------------------------------------------------------------+
bool CNewsCalendar::LoadLive(const datetime utc_now, const int offset_seconds, string &err)
  {
   datetime from_utc = utc_now - 2 * 86400;
   datetime to_utc   = utc_now + MathMax(1, m_cfg.horizon_hours) * 3600;
   datetime from = (m_cfg.calendar_time_basis == 0) ? from_utc + offset_seconds : from_utc;
   datetime to   = (m_cfg.calendar_time_basis == 0) ? to_utc + offset_seconds : to_utc;

   int ok_queries = 0;
   int added = 0;
   for(int c = 0; c < ArraySize(m_currencies); c++)
     {
      MqlCalendarValue values[];
      ResetLastError();
      if(!CalendarValueHistory(values, from, to, NULL, m_currencies[c]))
        {
         LogWarn(StringFormat("calendar query failed for %s (err %d)", m_currencies[c], GetLastError()));
         continue;
        }
      ok_queries++;
      for(int i = 0; i < ArraySize(values); i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         MqlCalendarCountry country;
         string cur = "";
         string cname = "";
         if(CalendarCountryById(ev.country_id, country))
           {
            cur = UpperStr(country.currency);
            cname = country.name;
           }
         if(cur == "")
            cur = m_currencies[c];
         if(cur != m_currencies[c])
            continue;
         NewsEvent e;
         e.id = (long)values[i].event_id;
         e.time_utc = (m_cfg.calendar_time_basis == 0) ? values[i].time - offset_seconds : values[i].time;
         e.currency = cur;
         e.country = cname;
         e.name = ev.name;
         e.impact = (int)ev.importance;
         e.has_forecast = (values[i].forecast_value != 0.0);
         e.has_previous = (values[i].prev_value != 0.0);
         e.has_actual = (values[i].actual_value != 0.0);
         e.forecast = (double)values[i].forecast_value;
         e.previous = (double)values[i].prev_value;
         e.actual = (double)values[i].actual_value;
         AddEvent(e);
         added++;
        }
     }
   if(ok_queries == 0)
     {
      err = "economic calendar API unavailable (no currency query succeeded)";
      return false;
     }
   SortAndDedup();
   m_source = "live";
   LogInfo(2, 1, StringFormat("calendar live: %d events (%d queries)", added, ok_queries));
   return true;
  }

//+------------------------------------------------------------------+
bool CNewsCalendar::Init(const NewsConfig &cfg, const string &configured_currencies[],
                          const bool tester, string &err)
  {
   m_cfg = cfg;
   m_tester = tester;
   m_available = false;
   m_source = "none";
   m_error = "";
   m_loaded_at = 0;
   ArrayResize(m_events, 0);
   BuildQueryCurrencies(configured_currencies);
   if(!cfg.enabled)
     {
      m_source = "disabled";
      return true;
     }
   if(ArraySize(m_currencies) == 0)
     {
      int n = ArraySize(m_currencies);
      ArrayResize(m_currencies, n + 1);
      m_currencies[n] = "USD";
     }
   return true;
  }

bool CNewsCalendar::Refresh(const datetime utc_now, const int offset_seconds, string &err)
  {
   m_refresh_attempted = true;
   err = "";
   m_error = "";
   if(!m_cfg.enabled)
     {
      m_available = false;
      m_source = "disabled";
      m_loaded_at = utc_now;
      return true;
     }

   ArrayResize(m_events, 0);
   bool csv_ok = false;
   string csv_err = "";
   bool live_ok = false;
   string live_err = "";

   if(m_cfg.use_live_calendar && !m_tester)
     {
      live_ok = LoadLive(utc_now, offset_seconds, live_err);
      if(!live_ok)
         LogWarn("live calendar failed: " + live_err);
     }
   if(!live_ok)
     {
      // Always keep a CSV fallback available for testers and outages.
      csv_ok = LoadCsv(csv_err);
      if(csv_ok)
        {
         m_source = m_tester ? "csv_tester" : "csv_fallback";
         m_available = true;
        }
      else
        {
         m_available = false;
         m_source = "unavailable";
         m_error = live_err != "" ? ("live: " + live_err + "; csv: " + csv_err) : csv_err;
        }
     }
   else
      m_available = true;

   m_loaded_at = utc_now;
   if(!m_available)
     {
      err = m_error;
      return false;
     }
   return true;
  }

bool CNewsCalendar::RefreshIfStale(const datetime utc_now, const int offset_seconds, string &err)
  {
   int minutes = MathMax(1, m_cfg.refresh_minutes);
   if(m_refresh_attempted && (utc_now - m_loaded_at) < minutes * 60)
      return m_available;
   return Refresh(utc_now, offset_seconds, err);
  }

bool CNewsCalendar::CurrencyRelevant(const string currency, const string list)
  {
   if(currency == "" || list == "")
      return false;
   string hay = "|" + UpperStr(list) + "|";
   StringReplace(hay, ",", "|");
   StringReplace(hay, ";", "|");
   StringReplace(hay, " ", "");
   return (StringFind(hay, "|" + currency + "|", 0) >= 0);
  }

//+------------------------------------------------------------------+
//| Currency list used for one instrument. An empty result means      |
//| "unknown", which BuildContext treats as all currencies relevant   |
//| (fail-closed, never silently permissive).                         |
//+------------------------------------------------------------------+
string SymbolNewsCurrencies(const SymbolSpec &spec)
  {
   string list = UpperStr(TrimStr(spec.news_currencies));
   if(list == "")
     {
      string base = UpperStr(TrimStr(spec.base_ccy));
      string quote = UpperStr(TrimStr(spec.quote_ccy));
      if(base != "" && quote != "" && base != quote)
         list = base + "," + quote;
      else if(base != "")
         list = base;
      else if(quote != "")
         list = quote;
     }
   return list;
  }

//+------------------------------------------------------------------+
//| Evaluate news risk for one candidate.                              |
//| Returns false when the calendar is unavailable; the caller applies |
//| the configured unavailable policy. Blackout windows are inclusive  |
//| of both the pre-release and post-release bounds.                  |
//+------------------------------------------------------------------+
bool CNewsCalendar::BuildContext(const string symbol, const string currencies,
                                 const datetime utc_now, NewsContext &ctx)
  {
   ctx.available = m_available;
   ctx.blackout = false;
   ctx.blackout_reason = "";
   ctx.blocked_until = 0;
   ctx.minutes_to_next = 9999;
   ctx.next_impact = 0;
   ctx.next_event = "";
   ctx.next_currency = "";
   ctx.risk_multiplier = 1.0;
   ctx.event_count = ArraySize(m_events);
   ctx.source = m_source;
   if(!m_cfg.enabled)
     {
      ctx.available = true;      // filter explicitly disabled
      ctx.source = "disabled";
      return true;
     }
   if(!m_available)
      return false;

   int before = MathMax(0, m_cfg.high_impact_block_before_min);
   int after  = MathMax(0, m_cfg.high_impact_block_after_min);
   int med    = MathMax(0, m_cfg.medium_impact_window_min);
   int next_min = 9999;
   bool relevant_any = (TrimStr(currencies) == "");

   for(int i = 0; i < ArraySize(m_events); i++)
     {
      NewsEvent e = m_events[i];
      bool relevant = relevant_any || CurrencyRelevant(e.currency, currencies);
      if(!relevant)
         continue;

      int delta = (int)((e.time_utc - utc_now) / 60);
      if(e.impact >= 3)
        {
         if(delta < next_min && delta >= 0)
           {
            next_min = delta;
            ctx.next_impact = 3;
            ctx.next_event = e.name;
            ctx.next_currency = e.currency;
           }
         if(delta <= before && delta >= -after)
           {
            ctx.blackout = true;
            datetime until = e.time_utc + after * 60;
            if(until > ctx.blocked_until)
               ctx.blocked_until = until;
            string when = (delta >= 0) ? StringFormat("in %dm", delta)
                                       : StringFormat("%dm ago", -delta);
            if(ctx.blackout_reason != "")
               ctx.blackout_reason += "; ";
            ctx.blackout_reason += StringFormat("%s %s %s (high impact)", e.currency, e.name, when);
           }
        }
      else if(e.impact == 2)
        {
         if(delta < next_min && delta >= 0)
           {
            next_min = delta;
            ctx.next_impact = 2;
            ctx.next_event = e.name;
            ctx.next_currency = e.currency;
           }
         if(MathAbs(delta) <= med)
            ctx.risk_multiplier = MathMin(ctx.risk_multiplier,
                                          ClampD(m_cfg.medium_impact_risk_mult, 0.05, 1.0));
        }
     }
   ctx.minutes_to_next = next_min;
   ctx.risk_multiplier = ClampD(ctx.risk_multiplier, 0.0, 1.0);
   return true;
  }

#endif
//+------------------------------------------------------------------+

