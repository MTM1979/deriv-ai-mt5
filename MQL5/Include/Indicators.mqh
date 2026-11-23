//+------------------------------------------------------------------+
//|                                                   Indicators.mqh |
//|  Indicator plumbing and the normalized market snapshot that both  |
//|  the strategy engine and the ONNX feature builder consume.        |
//|                                                                  |
//|  All evaluation uses CLOSED bars (shift >= 1). Live bid/ask are    |
//|  read only for execution prices and spread checks. This prevents  |
//|  intrabar repainting of signals.                                  |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_INDICATORS_MQH__
#define __DERIV_AI_INDICATORS_MQH__

#include <Config.mqh>
#include <Utils.mqh>
#include <SymbolSpec.mqh>
#include <Sessions.mqh>

struct IndicatorSnapshot
  {
   bool     valid;
   string   symbol;
   string   error;
   int      bars_available;
   datetime bar_time;

   double   open, high, low, close;
   double   bid, ask, point, tick_size;
   int      digits;

   double   atr;
   double   atr_points;
   double   atr_percentile;

   double   ema_fast, ema_mid, ema_slow;
   double   ema_slow_slope;          // change over 10 bars, in ATR
   double   ema_fast_prev;

   double   rsi, rsi_prev;
   double   macd_main, macd_signal, macd_hist, macd_hist_prev;
   double   bb_upper, bb_middle, bb_lower, bb_width;
   double   adx, di_plus, di_minus;

   double   swing_high, swing_low;
   double   session_high, session_low, session_mid;
   double   prior_day_high, prior_day_low;
   double   day_high, day_low;
   double   vwap;

   double   htf_close, htf_ema_slow, htf_rsi, htf_atr, htf_ema_fast;
   double   volume_ratio;
   double   ret1, ret3, ret12;
   double   range_expansion;

   bool     sweep_high, sweep_low;
   double   swept_high_level, swept_low_level;

   //--- raw bar windows used by the signal engine for retest logic --
   double   last_high[6];
   double   last_low[6];
   double   last_close[6];
   double   last_open[6];
  };

//+------------------------------------------------------------------+
//| Per symbol/timeframe indicator handles, created lazily.           |
//+------------------------------------------------------------------+
class CIndicatorHandles
  {
public:
   string   key;
   int      h_ema_fast;
   int      h_ema_mid;
   int      h_ema_slow;
   int      h_rsi;
   int      h_macd;
   int      h_atr;
   int      h_bb;
   int      h_adx;
   int      h_htf_ema_fast;
   int      h_htf_ema_slow;
   int      h_htf_rsi;
   int      h_htf_atr;

            CIndicatorHandles(void);
   void     Reset(void);
   bool     AllValid(void);
   void     Release(void);
  };

CIndicatorHandles::CIndicatorHandles(void)
  {
   Reset();
  }

void CIndicatorHandles::Reset(void)
  {
   key = "";
   h_ema_fast = INVALID_HANDLE;
   h_ema_mid = INVALID_HANDLE;
   h_ema_slow = INVALID_HANDLE;
   h_rsi = INVALID_HANDLE;
   h_macd = INVALID_HANDLE;
   h_atr = INVALID_HANDLE;
   h_bb = INVALID_HANDLE;
   h_adx = INVALID_HANDLE;
   h_htf_ema_fast = INVALID_HANDLE;
   h_htf_ema_slow = INVALID_HANDLE;
   h_htf_rsi = INVALID_HANDLE;
   h_htf_atr = INVALID_HANDLE;
  }

bool CIndicatorHandles::AllValid(void)
  {
   return (h_ema_fast != INVALID_HANDLE && h_ema_mid != INVALID_HANDLE &&
           h_ema_slow != INVALID_HANDLE && h_rsi != INVALID_HANDLE &&
           h_macd != INVALID_HANDLE && h_atr != INVALID_HANDLE &&
           h_bb != INVALID_HANDLE && h_adx != INVALID_HANDLE &&
           h_htf_ema_fast != INVALID_HANDLE && h_htf_ema_slow != INVALID_HANDLE &&
           h_htf_rsi != INVALID_HANDLE && h_htf_atr != INVALID_HANDLE);
  }

void CIndicatorHandles::Release(void)
  {
   if(h_ema_fast != INVALID_HANDLE)   IndicatorRelease(h_ema_fast);
   if(h_ema_mid != INVALID_HANDLE)    IndicatorRelease(h_ema_mid);
   if(h_ema_slow != INVALID_HANDLE)   IndicatorRelease(h_ema_slow);
   if(h_rsi != INVALID_HANDLE)        IndicatorRelease(h_rsi);
   if(h_macd != INVALID_HANDLE)       IndicatorRelease(h_macd);
   if(h_atr != INVALID_HANDLE)        IndicatorRelease(h_atr);
   if(h_bb != INVALID_HANDLE)         IndicatorRelease(h_bb);
   if(h_adx != INVALID_HANDLE)        IndicatorRelease(h_adx);
   if(h_htf_ema_fast != INVALID_HANDLE) IndicatorRelease(h_htf_ema_fast);
   if(h_htf_ema_slow != INVALID_HANDLE) IndicatorRelease(h_htf_ema_slow);
   if(h_htf_rsi != INVALID_HANDLE)    IndicatorRelease(h_htf_rsi);
   if(h_htf_atr != INVALID_HANDLE)    IndicatorRelease(h_htf_atr);
   Reset();
  }

//+------------------------------------------------------------------+
class CIndicatorHub
  {
private:
   SignalConfig       m_cfg;
   int                m_day_roll_hour;
   int                m_max_tick_age;
   CIndicatorHandles  m_sets[];

   int                FindSet(const string key);
   bool               EnsureSet(const string symbol, string &err);
   bool               CopyValue(const int handle, const int buffer, const int shift, double &value);
   bool               RangeExtremes(const string symbol, const ENUM_TIMEFRAMES tf,
                                    const datetime from, const datetime to,
                                    double &hi, double &lo, int &bars);
   bool               SeriesExtremes(const string symbol, const ENUM_TIMEFRAMES tf,
                                     const datetime from, const datetime to,
                                     double &hi, double &lo, int &bars, const bool prior);
   double             PercentileRank(const double &values[], const double current);
   double             VwapRange(const string symbol, const ENUM_TIMEFRAMES tf,
                                 const datetime from, const datetime to);
   bool               SwingLevels(const string symbol, double &hi, double &lo);

public:
                     CIndicatorHub(void);
   bool               Init(const SignalConfig &cfg, const int day_roll_hour,
                           const int max_tick_age_seconds);
   void               Release(void);
   bool               BuildSnapshot(const string symbol, const SymbolSpec &spec,
                                    const CSessionEngine &sess, IndicatorSnapshot &snap);
   bool               OpeningRange(const string symbol, const datetime from, const datetime to,
                                   double &hi, double &lo, int &bars);
   double             AtrValue(const string symbol);
  };

CIndicatorHub::CIndicatorHub(void)
  {
   m_day_roll_hour = 0;
   m_max_tick_age = 300;
  }

bool CIndicatorHub::Init(const SignalConfig &cfg, const int day_roll_hour, const int max_tick_age_seconds)
  {
   m_cfg = cfg;
   m_day_roll_hour = ClampI(day_roll_hour, 0, 23);
   m_max_tick_age = MathMax(30, max_tick_age_seconds);
   ArrayResize(m_sets, 0);
   return true;
  }

void CIndicatorHub::Release(void)
  {
   for(int i = 0; i < ArraySize(m_sets); i++)
      m_sets[i].Release();
   ArrayResize(m_sets, 0);
  }

int CIndicatorHub::FindSet(const string key)
  {
   for(int i = 0; i < ArraySize(m_sets); i++)
      if(m_sets[i].key == key)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| Create all handles for a symbol once. Handles are per symbol and  |
//| timeframe, so multi-symbol operation never shares state.          |
//+------------------------------------------------------------------+
bool CIndicatorHub::EnsureSet(const string symbol, string &err)
  {
   string key = StringFormat("%s|%d|%d|%d|%d|%d|%d|%d|%d|%.2f",
                             symbol, (int)m_cfg.exec_tf, (int)m_cfg.htf_tf,
                             m_cfg.ema_fast, m_cfg.ema_mid, m_cfg.ema_slow,
                             m_cfg.rsi_period, m_cfg.adx_period, m_cfg.bb_deviation);
   if(FindSet(key) >= 0)
      return true;
   CIndicatorHandles hs;
   hs.key = key;
   hs.h_ema_fast = iMA(symbol, m_cfg.exec_tf, m_cfg.ema_fast, 0, MODE_EMA, PRICE_CLOSE);
   hs.h_ema_mid  = iMA(symbol, m_cfg.exec_tf, m_cfg.ema_mid, 0, MODE_EMA, PRICE_CLOSE);
   hs.h_ema_slow = iMA(symbol, m_cfg.exec_tf, m_cfg.ema_slow, 0, MODE_EMA, PRICE_CLOSE);
   hs.h_rsi      = iRSI(symbol, m_cfg.exec_tf, m_cfg.rsi_period, PRICE_CLOSE);
   hs.h_macd     = iMACD(symbol, m_cfg.exec_tf, m_cfg.macd_fast, m_cfg.macd_slow,
                         m_cfg.macd_signal, PRICE_CLOSE);
   hs.h_atr      = iATR(symbol, m_cfg.exec_tf, m_cfg.atr_period);
   hs.h_bb       = iBands(symbol, m_cfg.exec_tf, m_cfg.bb_period, 0, m_cfg.bb_deviation, PRICE_CLOSE);
   hs.h_adx      = iADX(symbol, m_cfg.exec_tf, m_cfg.adx_period);
   hs.h_htf_ema_fast = iMA(symbol, m_cfg.htf_tf, m_cfg.ema_fast, 0, MODE_EMA, PRICE_CLOSE);
   hs.h_htf_ema_slow = iMA(symbol, m_cfg.htf_tf, m_cfg.ema_slow, 0, MODE_EMA, PRICE_CLOSE);
   hs.h_htf_rsi  = iRSI(symbol, m_cfg.htf_tf, m_cfg.rsi_period, PRICE_CLOSE);
   hs.h_htf_atr  = iATR(symbol, m_cfg.htf_tf, m_cfg.atr_period);

   if(!hs.AllValid())
     {
      err = StringFormat("indicator handle creation failed for %s (err %d)", symbol, GetLastError());
      hs.Release();
      return false;
     }
   int n = ArraySize(m_sets);
   if(!ArrayResize(m_sets, n + 1))
     {
      err = "out of memory creating indicator set";
      hs.Release();
      return false;
     }
   m_sets[n] = hs;
   return true;
  }

bool CIndicatorHub::CopyValue(const int handle, const int buffer, const int shift, double &value)
  {
   value = EMPTY_VALUE;
   double tmp[];
   if(CopyBuffer(handle, buffer, shift, 1, tmp) != 1)
      return false;
   value = tmp[0];
   return IsFinite(value) && value != EMPTY_VALUE;
  }

double CIndicatorHub::PercentileRank(const double &values[], const double current)
  {
   int n = ArraySize(values);
   if(n < 20)
      return -1.0;
   int below = 0;
   for(int i = 0; i < n; i++)
      if(IsFinite(values[i]) && values[i] <= current)
         below++;
   return (double)below / (double)n;
  }

//+------------------------------------------------------------------+
//| High/low over a UTC time window on a given timeframe.             |
//| A bar that straddles `from` is included; callers tolerate one      |
//| bar of boundary slack.                                             |
//+------------------------------------------------------------------+
bool CIndicatorHub::RangeExtremes(const string symbol, const ENUM_TIMEFRAMES tf,
                                  const datetime from, const datetime to,
                                  double &hi, double &lo, int &bars)
  {
   hi = 0.0;
   lo = 0.0;
   bars = 0;
   if(from <= 0 || to <= 0 || to < from)
      return false;
   int shift_from = iBarShift(symbol, tf, from, false);
   int shift_to   = iBarShift(symbol, tf, to, false);
   if(shift_from < 0 || shift_to < 0)
      return false;
   if(shift_to > shift_from)
      return false;
   int count = shift_from - shift_to + 1;
   if(count < 1)
      count = 1;
   if(count > 3000)
      count = 3000;
   double highs[], lows[];
   if(CopyHigh(symbol, tf, shift_to, count, highs) != count)
      return false;
   if(CopyLow(symbol, tf, shift_to, count, lows) != count)
      return false;
   int imax = ArrayMaximum(highs);
   int imin = ArrayMinimum(lows);
   if(imax < 0 || imin < 0)
      return false;
   hi = highs[imax];
   lo = lows[imin];
   bars = count;
   return (hi > 0.0 && lo > 0.0 && hi >= lo);
  }

bool CIndicatorHub::SeriesExtremes(const string symbol, const ENUM_TIMEFRAMES tf,
                                   const datetime from, const datetime to,
                                   double &hi, double &lo, int &bars, const bool prior)
  {
   return RangeExtremes(symbol, tf, from, to, hi, lo, bars);
  }

//+------------------------------------------------------------------+
//| Session-anchored VWAP proxy: typical price weighted by tick        |
//| volume over the range timeframe. Tick volume is a proxy for real   |
//| volume; Deriv FX/index CFDs do not publish exchange volume.        |
//+------------------------------------------------------------------+
double CIndicatorHub::VwapRange(const string symbol, const ENUM_TIMEFRAMES tf,
                                const datetime from, const datetime to)
  {
   if(from <= 0 || to <= 0 || to < from)
      return 0.0;
   int shift_from = iBarShift(symbol, tf, from, false);
   int shift_to   = iBarShift(symbol, tf, to, false);
   if(shift_from < 0 || shift_to < 0 || shift_to > shift_from)
      return 0.0;
   int count = shift_from - shift_to + 1;
   if(count < 1 || count > 3000)
      return 0.0;
   MqlRates r[];
   if(CopyRates(symbol, tf, shift_to, count, r) != count)
      return 0.0;
   double pv = 0.0, vol = 0.0;
   for(int i = 0; i < count; i++)
     {
      double typical = (r[i].high + r[i].low + r[i].close) / 3.0;
      double v = (double)r[i].tick_volume;
      if(v <= 0.0)
         continue;
      pv += typical * v;
      vol += v;
     }
   if(vol > 0.0)
      return pv / vol;
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Most recent confirmed fractal swing, falling back to the window    |
//| extreme when no fractal is found.                                  |
//+------------------------------------------------------------------+
bool CIndicatorHub::SwingLevels(const string symbol, double &hi, double &lo)
  {
   hi = 0.0;
   lo = 0.0;
   int f = MathMax(1, m_cfg.swing_fractal);
   int need = m_cfg.swing_lookback + f * 2 + 2;
   double highs[], lows[];
   if(CopyHigh(symbol, m_cfg.exec_tf, 1, need, highs) != need)
      return false;
   if(CopyLow(symbol, m_cfg.exec_tf, 1, need, lows) != need)
      return false;
   int n = ArraySize(highs);
   bool found_hi = false, found_lo = false;
   for(int i = n - 1 - f; i >= f; i--)
     {
      if(!found_hi)
        {
         bool ok = true;
         for(int k = 1; k <= f && ok; k++)
            if(highs[i] < highs[i - k] || highs[i] < highs[i + k])
               ok = false;
         if(ok)
           {
            hi = highs[i];
            found_hi = true;
           }
        }
      if(!found_lo)
        {
         bool ok = true;
         for(int k = 1; k <= f && ok; k++)
            if(lows[i] > lows[i - k] || lows[i] > lows[i + k])
               ok = false;
         if(ok)
           {
            lo = lows[i];
            found_lo = true;
           }
        }
      if(found_hi && found_lo)
         break;
     }
   if(!found_hi)
      hi = highs[ArrayMaximum(highs)];
   if(!found_lo)
      lo = lows[ArrayMinimum(lows)];
   return (hi > 0.0 && lo > 0.0);
  }

//+------------------------------------------------------------------+
//| Build the normalized snapshot. Everything below uses closed bars.  |
//+------------------------------------------------------------------+
bool CIndicatorHub::BuildSnapshot(const string symbol, const SymbolSpec &spec,
                                  const CSessionEngine &sess, IndicatorSnapshot &snap)
  {
   snap.valid = false;
   snap.symbol = symbol;
   snap.error = "";
   snap.bars_available = 0;
   for(int i = 0; i < 6; i++)
     {
      snap.last_high[i] = 0.0;
      snap.last_low[i] = 0.0;
      snap.last_close[i] = 0.0;
      snap.last_open[i] = 0.0;
     }

   string err = "";
   if(!EnsureSet(symbol, err))
     {
      snap.error = err;
      return false;
     }
   int set_idx = FindSet(StringFormat("%s|%d|%d|%d|%d|%d|%d|%d|%d|%.2f",
                                      symbol, (int)m_cfg.exec_tf, (int)m_cfg.htf_tf,
                                      m_cfg.ema_fast, m_cfg.ema_mid, m_cfg.ema_slow,
                                      m_cfg.rsi_period, m_cfg.adx_period, m_cfg.bb_deviation));
   if(set_idx < 0)
     {
      snap.error = "indicator set not found";
      return false;
     }
   CIndicatorHandles hs = m_sets[set_idx];

   int bars = Bars(symbol, m_cfg.exec_tf);
   snap.bars_available = bars;
   if(bars < MathMax(m_cfg.min_bars_required, 60))
     {
      snap.error = StringFormat("insufficient bars (%d)", bars);
      return false;
     }

   //--- closed OHLC window ------------------------------------------
   MqlRates r[];
   int need = 16;
   if(CopyRates(symbol, m_cfg.exec_tf, 1, need, r) != need)
     {
      snap.error = "cannot copy rates";
      return false;
     }
   for(int k = 0; k < 6; k++)
     {
      int idx = need - 1 - k;
      snap.last_high[k]  = r[idx].high;
      snap.last_low[k]   = r[idx].low;
      snap.last_close[k] = r[idx].close;
      snap.last_open[k]  = r[idx].open;
     }
   snap.bar_time  = r[need - 1].time;
   snap.open      = r[need - 1].open;
   snap.high      = r[need - 1].high;
   snap.low       = r[need - 1].low;
   snap.close     = r[need - 1].close;
   snap.ret1      = SafeDiv(snap.close, r[need - 2].close, 1.0) - 1.0;
   snap.ret3      = SafeDiv(snap.close, r[need - 4].close, 1.0) - 1.0;
   snap.ret12     = SafeDiv(snap.close, r[need - 13].close, 1.0) - 1.0;

   //--- live prices -------------------------------------------------
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
     {
      snap.error = "no live tick";
      return false;
     }
   snap.bid = tick.bid;
   snap.ask = tick.ask;
   snap.point = spec.point;
   snap.tick_size = spec.tick_size;
   snap.digits = spec.digits;
   //--- never divide by a missing contract value: an unrefreshed or
   //--- invalid spec must reject the symbol, not crash the EA
   if(snap.point <= 0.0 || snap.tick_size <= 0.0)
     {
      snap.error = "contract point/tick size unavailable";
      return false;
     }
   if(spec.market_open && (TimeTradeServer() - tick.time) > m_max_tick_age)
     {
      snap.error = StringFormat("stale tick (%d s)", (int)(TimeTradeServer() - tick.time));
      return false;
     }

   //--- core indicators --------------------------------------------
   double v = 0.0;
   if(!CopyValue(hs.h_atr, 0, 1, snap.atr) || snap.atr <= 0.0)
     {
      snap.error = "ATR unavailable";
      return false;
     }
   snap.atr_points = snap.atr / snap.point;

   double atr_hist[];
   int lookback = MathMax(60, m_cfg.atr_percentile_lookback);
   int copied = CopyBuffer(hs.h_atr, 0, 1, lookback, atr_hist);
   if(copied < 60)
     {
      snap.error = "ATR history unavailable";
      return false;
     }
   snap.atr_percentile = PercentileRank(atr_hist, atr_hist[ArraySize(atr_hist) - 1]);
   if(snap.atr_percentile < 0.0)
     {
      snap.error = "ATR percentile unavailable";
      return false;
     }

   if(!CopyValue(hs.h_ema_fast, 0, 1, snap.ema_fast) ||
      !CopyValue(hs.h_ema_mid, 0, 1, snap.ema_mid) ||
      !CopyValue(hs.h_ema_slow, 0, 1, snap.ema_slow))
     {
      snap.error = "EMA unavailable";
      return false;
     }
   if(!CopyValue(hs.h_ema_fast, 0, 2, snap.ema_fast_prev))
      snap.ema_fast_prev = snap.ema_fast;
   double ema_slow_old = 0.0;
   if(CopyValue(hs.h_ema_slow, 0, 11, ema_slow_old))
      snap.ema_slow_slope = (snap.ema_slow - ema_slow_old) / (10.0 * snap.atr);
   else
      snap.ema_slow_slope = 0.0;

   if(!CopyValue(hs.h_rsi, 0, 1, snap.rsi) || !CopyValue(hs.h_rsi, 0, 2, snap.rsi_prev))
     {
      snap.error = "RSI unavailable";
      return false;
     }
   double macd_main = 0.0, macd_sig = 0.0, macd_hist_prev_main = 0.0, macd_hist_prev_sig = 0.0;
   if(!CopyValue(hs.h_macd, 0, 1, macd_main) || !CopyValue(hs.h_macd, 1, 1, macd_sig))
     {
      snap.error = "MACD unavailable";
      return false;
     }
   snap.macd_main = macd_main;
   snap.macd_signal = macd_sig;
   snap.macd_hist = macd_main - macd_sig;
   if(CopyValue(hs.h_macd, 0, 2, macd_hist_prev_main) &&
      CopyValue(hs.h_macd, 1, 2, macd_hist_prev_sig))
      snap.macd_hist_prev = macd_hist_prev_main - macd_hist_prev_sig;
   else
      snap.macd_hist_prev = snap.macd_hist;

   if(!CopyValue(hs.h_bb, 0, 1, snap.bb_upper) ||
      !CopyValue(hs.h_bb, 1, 1, snap.bb_lower) ||
      !CopyValue(hs.h_bb, 2, 1, snap.bb_middle))
     {
      snap.error = "Bollinger unavailable";
      return false;
     }
   snap.bb_width = snap.bb_upper - snap.bb_lower;

   if(!CopyValue(hs.h_adx, 0, 1, snap.adx) ||
      !CopyValue(hs.h_adx, 1, 1, snap.di_plus) ||
      !CopyValue(hs.h_adx, 2, 1, snap.di_minus))
     {
      snap.error = "ADX unavailable";
      return false;
     }

   //--- higher timeframe -------------------------------------------
   if(!CopyValue(hs.h_htf_ema_fast, 0, 1, snap.htf_ema_fast) ||
      !CopyValue(hs.h_htf_ema_slow, 0, 1, snap.htf_ema_slow) ||
      !CopyValue(hs.h_htf_rsi, 0, 1, snap.htf_rsi) ||
      !CopyValue(hs.h_htf_atr, 0, 1, snap.htf_atr))
     {
      snap.error = "higher timeframe data unavailable";
      return false;
     }
   double htf_close_arr[];
   if(CopyClose(symbol, m_cfg.htf_tf, 1, 1, htf_close_arr) != 1)
     {
      snap.error = "higher timeframe close unavailable";
      return false;
     }
   snap.htf_close = htf_close_arr[0];

   //--- volume ratio ------------------------------------------------
   long vols[];
   int vlook = MathMax(5, m_cfg.volume_lookback);
   int vcopied = CopyTickVolume(symbol, m_cfg.exec_tf, 1, vlook, vols);
   if(vcopied >= 5)
     {
      double sum = 0.0;
      for(int i = 0; i < vcopied; i++)
         sum += (double)vols[i];
      double avg = sum / (double)vcopied;
      snap.volume_ratio = SafeDiv((double)vols[vcopied - 1], avg, 1.0);
     }
   else
      snap.volume_ratio = 1.0;

   //--- ranges ------------------------------------------------------
   datetime day_start = DayFloor(sess.UtcNow(), m_day_roll_hour);
   datetime sess_start = sess.SessionStartUtc();
   if(sess_start <= 0 || sess_start > snap.bar_time)
      sess_start = day_start;

   int rb = 0;
   double shi = 0.0, slo = 0.0;
   if(!RangeExtremes(symbol, m_cfg.range_tf, sess_start, snap.bar_time, shi, slo, rb))
     {
      snap.error = "session range unavailable";
      return false;
     }
   snap.session_high = shi;
   snap.session_low  = slo;
   snap.session_mid  = (shi + slo) / 2.0;
   snap.range_expansion = SafeDiv(shi - slo, snap.atr, 0.0);

   double dhi = 0.0, dlo = 0.0;
   if(!RangeExtremes(symbol, m_cfg.range_tf, day_start, snap.bar_time, dhi, dlo, rb))
     {
      snap.error = "day range unavailable";
      return false;
     }
   snap.day_high = dhi;
   snap.day_low  = dlo;

   double pdh = 0.0, pdl = 0.0;
   datetime prior_start = day_start - 86400;
   if(RangeExtremes(symbol, m_cfg.range_tf, prior_start, day_start - 1, pdh, pdl, rb))
     {
      snap.prior_day_high = pdh;
      snap.prior_day_low  = pdl;
     }
   else
     {
      snap.prior_day_high = 0.0;
      snap.prior_day_low  = 0.0;
     }

   double vwap = VwapRange(symbol, m_cfg.range_tf, sess_start, snap.bar_time);
   if(vwap <= 0.0)
      vwap = (snap.session_high + snap.session_low + snap.close) / 3.0;
   snap.vwap = vwap;

   //--- structure ---------------------------------------------------
   if(!SwingLevels(symbol, snap.swing_high, snap.swing_low))
     {
      snap.swing_high = snap.high;
      snap.swing_low  = snap.low;
     }

   //--- liquidity sweeps of the prior day extreme -------------------
   snap.sweep_high = false;
   snap.sweep_low = false;
   snap.swept_high_level = snap.prior_day_high;
   snap.swept_low_level = snap.prior_day_low;
   if(snap.prior_day_high > 0.0 && snap.prior_day_low > 0.0)
     {
      for(int i = 0; i < 3; i++)
        {
         double tol = 0.10 * snap.atr;
         if(snap.last_high[i] > snap.prior_day_high + tol &&
            snap.last_close[i] < snap.prior_day_high)
           {
            snap.sweep_high = true;
            snap.swept_high_level = snap.prior_day_high;
            break;
           }
        }
      for(int i = 0; i < 3; i++)
        {
         double tol = 0.10 * snap.atr;
         if(snap.last_low[i] < snap.prior_day_low - tol &&
            snap.last_close[i] > snap.prior_day_low)
           {
            snap.sweep_low = true;
            snap.swept_low_level = snap.prior_day_low;
            break;
           }
        }
     }

   snap.valid = true;
   return true;
  }

bool CIndicatorHub::OpeningRange(const string symbol, const datetime from, const datetime to,
                                 double &hi, double &lo, int &bars)
  {
   return RangeExtremes(symbol, m_cfg.range_tf, from, to, hi, lo, bars);
  }

double CIndicatorHub::AtrValue(const string symbol)
  {
   string prefix = symbol + "|";
   for(int i = 0; i < ArraySize(m_sets); i++)
     {
      if(StringFind(m_sets[i].key, prefix, 0) == 0)
        {
         double v = 0.0;
         if(CopyValue(m_sets[i].h_atr, 0, 1, v))
            return v;
        }
     }
   return 0.0;
  }

#endif
//+------------------------------------------------------------------+

