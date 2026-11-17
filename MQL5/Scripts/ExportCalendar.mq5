//+------------------------------------------------------------------+
//|                                            ExportCalendar.mq5     |
//|  Export the terminal economic calendar to calendar_history.csv in  |
//|  the format the EA expects. Use it to build the tester fallback and |
//|  to freeze the event set used for a validation run.                |
//|                                                                    |
//|  The CSV is written in UTC. Calendar timestamps from the terminal  |
//|  are server-based; the server-UTC offset is detected (or supplied) |
//|  before conversion.                                                |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property description "Export the MT5 economic calendar to calendar_history.csv (UTC)."

input int    InpPastDays      = 90;                 // Days of history
input int    InpFutureDays    = 30;                 // Days ahead
input int    InpUtcOffsetHours = 99;                // Server-UTC offset (99 = auto)
input string InpCurrencyFilter = "";                // Comma list, empty = all
input string InpOutFile       = "calendar_history.csv";

//+------------------------------------------------------------------+
string Cell(const string s)
  {
   string t = s;
   StringReplace(t, ",", ";");
   StringReplace(t, "\r", " ");
   StringReplace(t, "\n", " ");
   return t;
  }

int ImpactOf(const ENUM_CALENDAR_EVENT_IMPORTANCE importance)
  {
   switch(importance)
     {
      case CALENDAR_IMPORTANCE_HIGH:     return 3;
      case CALENDAR_IMPORTANCE_MODERATE: return 2;
      case CALENDAR_IMPORTANCE_LOW:      return 1;
      default:                           return 0;
     }
  }

string NumOrEmpty(const long scaled)
  {
   if(scaled == 0)
      return "";
   return DoubleToString((double)scaled / 1000000.0, 6);
  }

//+------------------------------------------------------------------+
void OnStart(void)
  {
   int offset_seconds = 0;
   if(InpUtcOffsetHours == 99)
     {
      long raw = (long)TimeTradeServer() - (long)TimeGMT();
      offset_seconds = (int)(MathRound((double)raw / 900.0) * 900.0);
     }
   else
      offset_seconds = InpUtcOffsetHours * 3600;

   datetime to   = TimeTradeServer() + (datetime)MathMax(0, InpFutureDays) * 86400;
   datetime from = TimeTradeServer() - (datetime)MathMax(0, InpPastDays) * 86400;

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, from, to);
   if(total <= 0)
     {
      PrintFormat("calendar returned no values (error %d). Is the calendar enabled and connected?",
                  GetLastError());
      return;
     }

   string want[];
   int wn = 0;
   if(InpCurrencyFilter != "")
     {
      string parts[];
      wn = StringSplit(InpCurrencyFilter, ',', parts);
      ArrayResize(want, wn);
      for(int i = 0; i < wn; i++)
        {
         string c = parts[i];
         StringTrimLeft(c);
         StringTrimRight(c);
         StringToUpper(c);
         want[i] = c;
        }
     }

   int h = FileOpen(InpOutFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("cannot open %s (error %d)", InpOutFile, GetLastError());
      return;
     }
   FileWriteString(h, "event_id,time_utc,currency,country,event,impact,forecast,previous,actual\r\n");

   int written = 0;
   for(int i = 0; i < total; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;

      MqlCalendarCountry country;
      string ccy = "";
      string cname = "";
      if(CalendarCountryById(ev.country_id, country))
        {
         ccy = country.currency;
         cname = country.name;
        }
      if(ccy == "")
         continue;

      if(wn > 0)
        {
         bool keep = false;
         for(int k = 0; k < wn; k++)
            if(want[k] == ccy)
              {
               keep = true;
               break;
              }
         if(!keep)
            continue;
        }

      datetime utc = values[i].time - (datetime)offset_seconds;
      string line = StringFormat("%I64u,%s,%s,%s,%s,%d,%s,%s,%s",
                                 values[i].event_id,
                                 TimeToString(utc, TIME_DATE | TIME_MINUTES),
                                 Cell(ccy),
                                 Cell(cname),
                                 Cell(ev.name),
                                 ImpactOf(ev.importance),
                                 NumOrEmpty(values[i].forecast_value),
                                 NumOrEmpty(values[i].prev_value),
                                 NumOrEmpty(values[i].actual_value));
      FileWriteString(h, line + "\r\n");
      written++;
     }
   FileClose(h);
   PrintFormat("wrote %d calendar rows (of %d values) to %s (server offset %+d s)",
               written, total, InpOutFile, offset_seconds);
  }
//+------------------------------------------------------------------+
