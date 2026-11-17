//+------------------------------------------------------------------+
//|                                                  AiAssistant.mqh |
//|  External AI advisory layer.                                      |
//|                                                                  |
//|  HARD BOUNDARY: the assistant receives a compact market snapshot   |
//|  and may (a) veto a trade or (b) return a risk multiplier in       |
//|  [0,1]. It cannot choose direction, size, symbol, stop or target,  |
//|  and any multiplier above 1 is clamped. It is never consulted for  |
//|  position management.                                             |
//|                                                                  |
//|  Failure policy is explicit: veto or reduce. Default is veto.      |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_AIASSISTANT_MQH__
#define __DERIV_AI_AIASSISTANT_MQH__

#include <Config.mqh>
#include <Utils.mqh>
#include <Json.mqh>
#include <SymbolSpec.mqh>
#include <Indicators.mqh>
#include <NewsCalendar.mqh>

struct AiCacheEntry
  {
   string       key;
   datetime     created;
   AiDecision   decision;
   string       response;
  };

class CAiAssistant
  {
private:
   AiConfig          m_cfg;
   string            m_endpoint;
   string            m_model;
   string            m_auth_name;
   string            m_auth_value;
   bool              m_ready;
   bool              m_tester;
   bool              m_optimization;
   string            m_error;
   string            m_last_request;
   string            m_last_response;
   int               m_calls_this_hour;
   datetime          m_hour_start;
   int               m_consecutive_failures;
   datetime          m_breaker_until;
   AiCacheEntry      m_cache[];

   bool              LoadPolicy(const string path, string &err);
   void              ApplyFallback(AiDecision &d, const ENUM_REASON code, const string why);
   bool              RateLimitExceeded(void);
   void              NoteCall(void);
   string            BuildRequest(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                  const TradeCandidate &cand, const NewsContext &news,
                                  const PortfolioSnapshot &portfolio);
   bool              CallEndpoint(const string body, string &response, string &err);
   bool              ParseDecision(const string response, AiDecision &d, string &err);
   bool              Cached(const string key, const datetime now, AiDecision &d, string &raw);
   void              StoreCache(const string key, const datetime now,
                                const AiDecision &d, const string raw);
   void              ResetDecision(AiDecision &d);
   void              TrimCache(const datetime now);
   bool              ValidateUrl(const string url, string &err);

public:
                     CAiAssistant(void);
   bool              Init(const AiConfig &cfg, const bool tester, const bool optimization, string &err);
   bool              Decide(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                            const TradeCandidate &cand, const NewsContext &news,
                            const PortfolioSnapshot &portfolio, AiDecision &decision);
   string            LastRequest(void)    { return m_last_request; }
   string            LastResponse(void)   { return m_last_response; }
   string            LastError(void)      { return m_error; }
   bool              Ready(void)          { return m_ready; }
   double            MaxMultiplier(void)  { return ClampD(m_cfg.max_risk_multiplier, 0.0, 1.0); }
  };

//+------------------------------------------------------------------+
CAiAssistant::CAiAssistant(void)
  {
   m_ready = false;
   m_tester = false;
   m_optimization = false;
   m_calls_this_hour = 0;
   m_hour_start = 0;
   m_consecutive_failures = 0;
   m_breaker_until = 0;
   m_error = "";
   m_last_request = "";
   m_last_response = "";
  }

void CAiAssistant::ResetDecision(AiDecision &d)
  {
   d.allowed = true;
   d.risk_multiplier = 1.0;
   d.confidence = 0;
   d.regime = "";
   d.reason = "";
   d.invalidation = "";
   d.used_fallback = false;
   d.available = true;
   d.reason_code = RC_OK;
  }

bool CAiAssistant::ValidateUrl(const string url, string &err)
  {
   string u = LowerStr(TrimStr(url));
   if(u == "")
     {
      err = "AI endpoint is empty";
      return false;
     }
   if(m_cfg.require_https && StringFind(u, "https://", 0) != 0)
     {
      err = "AI endpoint must use https";
      return false;
     }
   if(StringFind(u, "http://", 0) != 0 && StringFind(u, "https://", 0) != 0)
     {
      err = "AI endpoint must be an http(s) URL";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Policy file is authoritative for transport details. The EA inputs |
//| only control the master switch, tester allowance and the hard cap.|
//+------------------------------------------------------------------+
bool CAiAssistant::LoadPolicy(const string path, string &err)
  {
   string text = "";
   if(!ReadTextFile(path, false, text, err))
      return false;
   string jerr = "";
   CJsonValue *root = JsonParse(text, jerr);
   if(root == NULL)
     {
      err = "AI policy JSON invalid: " + jerr;
      return false;
     }
   bool ok = false;
   bool f = false;
   do
     {
      if(!root.IsObject())
        {
         err = "AI policy root must be an object";
         break;
        }
      if((int)root.GetNumberKey("schema", 0, f) != AI_SCHEMA_VERSION)
        {
         err = StringFormat("AI policy schema must be %d", AI_SCHEMA_VERSION);
         break;
        }
      m_endpoint = root.GetStringKey("endpoint", "", f);
      if(m_endpoint == "")
        {
         err = "AI policy endpoint missing";
         break;
        }
      if(!ValidateUrl(m_endpoint, err))
         break;
      m_model = root.GetStringKey("model", "", f);
      m_auth_name = root.GetStringKey("auth_header_name", "", f);
      m_auth_value = root.GetStringKey("auth_header_value", "", f);
      if(m_auth_name != "" && m_auth_value == "")
        {
         err = "AI policy auth_header_name has no auth_header_value";
         break;
        }

      m_cfg.timeout_ms = (int)ClampD(root.GetNumberKey("timeout_ms", m_cfg.timeout_ms, f), 250, 5000);
      m_cfg.max_calls_per_hour = (int)ClampD(root.GetNumberKey("max_calls_per_hour", m_cfg.max_calls_per_hour, f), 1, 600);
      m_cfg.cache_seconds = (int)ClampD(root.GetNumberKey("cache_seconds", m_cfg.cache_seconds, f), 0, 3600);
      m_cfg.fallback_reduce_factor = ClampD(root.GetNumberKey("fallback_reduce_factor",
                                                 m_cfg.fallback_reduce_factor, f), 0.0, 1.0);
      m_cfg.min_confidence = (int)ClampD(root.GetNumberKey("min_confidence", m_cfg.min_confidence, f), 0, 100);
      m_cfg.max_response_bytes = (int)ClampD(root.GetNumberKey("max_response_bytes",
                                                   m_cfg.max_response_bytes, f), 256, 65536);
      m_cfg.max_consecutive_failures = (int)ClampD(root.GetNumberKey("max_consecutive_failures",
                                                        m_cfg.max_consecutive_failures, f), 1, 100);
      m_cfg.breaker_seconds = (int)ClampD(root.GetNumberKey("breaker_seconds", m_cfg.breaker_seconds, f), 10, 86400);
      m_cfg.require_https = root.GetBoolKey("require_https", m_cfg.require_https, f);

      string fallback = LowerStr(root.GetStringKey("fallback", "veto", f));
      if(fallback == "veto" || fallback == "reject")
         m_cfg.fallback_mode = AI_FALLBACK_VETO;
      else if(fallback == "reduce")
         m_cfg.fallback_mode = AI_FALLBACK_REDUCE;
      else
        {
         err = "AI policy fallback must be 'veto' or 'reduce'";
         break;
        }
      // Hard cap is an EA input and cannot be raised by the policy file.
      m_cfg.max_risk_multiplier = ClampD(m_cfg.max_risk_multiplier, 0.0, 1.0);
      ok = true;
     }
   while(false);
   delete root;
   return ok;
  }

bool CAiAssistant::Init(const AiConfig &cfg, const bool tester, const bool optimization, string &err)
  {
   m_cfg = cfg;
   m_tester = tester;
   m_optimization = optimization;
   m_ready = false;
   m_error = "";
   err = "";
   ArrayResize(m_cache, 0);
   if(!cfg.enabled)
     {
      m_ready = false;
      return true;
     }
   if(tester || optimization)
     {
      // Deliberately not configured: the EA treats AI as out of scope in
      // tests rather than silently using the fallback policy.
      m_ready = false;
      return true;
     }
   if(!LoadPolicy(cfg.policy_file, err))
     {
      m_error = err;
      return false;
     }
   m_ready = true;
   return true;
  }

void CAiAssistant::NoteCall(void)
  {
   datetime now = TimeTradeServer();
   if(m_hour_start == 0 || now - m_hour_start >= 3600)
     {
      m_hour_start = now;
      m_calls_this_hour = 0;
     }
   m_calls_this_hour++;
  }

bool CAiAssistant::RateLimitExceeded(void)
  {
   datetime now = TimeTradeServer();
   if(m_hour_start == 0 || now - m_hour_start >= 3600)
      return false;
   return (m_calls_this_hour >= MathMax(1, m_cfg.max_calls_per_hour));
  }

void CAiAssistant::ApplyFallback(AiDecision &d, const ENUM_REASON code, const string why)
  {
   d.available = false;
   d.used_fallback = true;
   d.reason_code = code;
   d.reason = why;
   if(m_cfg.fallback_mode == AI_FALLBACK_REDUCE)
     {
      d.allowed = true;
      d.risk_multiplier = ClampD(m_cfg.fallback_reduce_factor, 0.0, 1.0);
     }
   else
     {
      d.allowed = false;
      d.risk_multiplier = 0.0;
     }
  }

//+------------------------------------------------------------------+
//| Build the compact context snapshot. No account identifier, no      |
//| balance, no equity, no credentials.                                |
//+------------------------------------------------------------------+
string CAiAssistant::BuildRequest(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                  const TradeCandidate &cand, const NewsContext &news,
                                  const PortfolioSnapshot &portfolio)
  {
   string dir = (cand.direction > 0) ? "long" : "short";
   string next_event = "null";
   if(news.minutes_to_next < 9999)
     {
      string impact = (news.next_impact >= 3) ? "high" : ((news.next_impact == 2) ? "medium" : "low");
      next_event = StringFormat("{\"currency\":%s,\"event\":%s,\"minutes_away\":%d,\"impact\":%s}",
                                JsonEscape(news.next_currency), JsonEscape(news.next_event),
                                news.minutes_to_next, JsonEscape(impact));
     }
   string req = "{";
   req += "\"schema\":1";
   req += ",\"symbol\":" + JsonEscape(spec.name);
   req += ",\"asset_class\":" + JsonEscape(spec.asset_class);
   req += ",\"direction\":" + JsonEscape(dir);
   req += ",\"strategy\":" + JsonEscape(StrategyToString(cand.strategy));
   req += ",\"session\":" + JsonEscape(cand.session);
   req += ",\"regime\":" + JsonEscape(cand.regime);
   req += ",\"technical_score\":" + JsonNumber(cand.technical_score);
   req += ",\"ml_probability\":" + JsonNumber(cand.ml_probability);
   req += ",\"atr_percentile\":" + JsonNumber(snap.atr_percentile * 100.0);
   req += ",\"spread_points\":" + JsonNumber(cand.spread_points);
   req += ",\"spread_ratio\":" + JsonNumber(SafeDiv(cand.spread_points,
                                                  MathMax(1.0, (double)spec.max_spread_points), 0.0));
   req += ",\"entry\":" + JsonNumber(cand.entry);
   req += ",\"stop\":" + JsonNumber(cand.stop);
   req += ",\"target1\":" + JsonNumber(cand.target1);
   req += ",\"open_positions\":" + (portfolio.positions_json == "" ? "[]" : portfolio.positions_json);
   req += ",\"portfolio_risk_pct\":" + JsonNumber(portfolio.portfolio_risk_pct);
   req += ",\"daily_loss_pct\":" + JsonNumber(portfolio.daily_loss_pct);
   req += ",\"weekly_loss_pct\":" + JsonNumber(portfolio.weekly_loss_pct);
   req += ",\"drawdown_pct\":" + JsonNumber(portfolio.drawdown_pct);
   req += ",\"next_high_impact_event\":" + next_event;
   req += ",\"news_risk_multiplier\":" + JsonNumber(news.risk_multiplier);
   req += ",\"account_currency\":" + JsonEscape(AccountInfoString(ACCOUNT_CURRENCY));
   req += "}";
   return req;
  }

bool CAiAssistant::CallEndpoint(const string body, string &response, string &err)
  {
   response = "";
   int len = StringLen(body);
   uchar ubody[];
   if(StringToCharArray(body, ubody, 0, len, CP_UTF8) != len)
     {
      err = "cannot encode request body";
      return false;
     }
   char post[];
   if(!ArrayResize(post, len))
     {
      err = "out of memory building request";
      return false;
     }
   for(int i = 0; i < len; i++)
      post[i] = (char)ubody[i];
   string headers = "Content-Type: application/json\r\nAccept: application/json\r\n";
   if(m_auth_name != "" && m_auth_value != "")
      headers += m_auth_name + ": " + m_auth_value + "\r\n";
   char result[];
   string result_headers = "";
   ResetLastError();
   int code = WebRequest("POST", m_endpoint, headers, m_cfg.timeout_ms, post, result, result_headers);
   if(code == -1)
     {
      int e = GetLastError();
      if(e == 4060)
         err = "WebRequest blocked: add the AI endpoint to Tools > Options > Expert Advisors > Allow WebRequest";
      else
         err = StringFormat("WebRequest failed (error %d)", e);
      return false;
     }
   if(code < 200 || code >= 300)
     {
      err = StringFormat("AI endpoint returned HTTP %d", code);
      return false;
     }
   int sz = ArraySize(result);
   if(sz <= 0)
     {
      err = "AI endpoint returned an empty body";
      return false;
     }
   if(sz > m_cfg.max_response_bytes)
     {
      err = StringFormat("AI response too large (%d bytes)", sz);
      return false;
     }
   uchar ures[];
   if(!ArrayResize(ures, sz))
     {
      err = "out of memory reading response";
      return false;
     }
   for(int i = 0; i < sz; i++)
      ures[i] = (uchar)result[i];
   response = CharArrayToString(ures, 0, sz, CP_UTF8);
   return true;
  }

bool CAiAssistant::ParseDecision(const string response, AiDecision &d, string &err)
  {
   string jerr = "";
   CJsonValue *root = JsonParse(response, jerr);
   if(root == NULL)
     {
      err = "invalid JSON: " + jerr;
      return false;
     }
   bool ok = false;
   do
     {
      if(!root.IsObject())
        {
         err = "response must be a JSON object";
         break;
        }
      CJsonValue *allowed = root.Get("trade_allowed");
      if(allowed == NULL || !allowed.IsBool())
        {
         err = "trade_allowed (bool) is required";
         break;
        }
      CJsonValue *mult = root.Get("risk_multiplier");
      if(mult == NULL || !mult.IsNumber())
        {
         err = "risk_multiplier (number) is required";
         break;
        }
      double m = mult.GetNumber();
      if(!MathIsValidNumber(m) || m < 0.0)
        {
         err = "risk_multiplier out of range";
         break;
        }
      bool found = false;
      double conf = root.GetNumberKey("confidence", 0.0, found);
      if(found && (!MathIsValidNumber(conf) || conf < 0.0 || conf > 100.0))
        {
         err = "confidence out of range";
         break;
        }
      d.allowed = allowed.GetBool();
      d.risk_multiplier = ClampD(MathMin(m, 1.0), 0.0, ClampD(m_cfg.max_risk_multiplier, 0.0, 1.0));
      d.confidence = found ? (int)MathRound(conf) : 0;
      d.reason = StringSubstr(root.GetStringKey("reason", "", found), 0, 500);
      d.regime = StringSubstr(root.GetStringKey("regime", "", found), 0, 64);
      d.invalidation = StringSubstr(root.GetStringKey("invalidation", "", found), 0, 200);
      d.used_fallback = false;
      d.available = true;
      d.reason_code = RC_OK;

      if(!d.allowed)
        {
         d.reason_code = RC_AI_VETO;
         d.risk_multiplier = 0.0;
         ok = true;
         break;
        }
      if(m_cfg.min_confidence > 0 && d.confidence < m_cfg.min_confidence)
        {
         d.allowed = false;
         d.risk_multiplier = 0.0;
         d.reason_code = RC_AI_LOW_CONFIDENCE;
         ok = true;
         break;
        }
      ok = true;
     }
   while(false);
   delete root;
   return ok;
  }

bool CAiAssistant::Cached(const string key, const datetime now, AiDecision &d, string &raw)
  {
   if(m_cfg.cache_seconds <= 0)
      return false;
   for(int i = 0; i < ArraySize(m_cache); i++)
     {
      if(m_cache[i].key == key && now - m_cache[i].created < m_cfg.cache_seconds)
        {
         d = m_cache[i].decision;
         raw = m_cache[i].response;
         return true;
        }
     }
   return false;
  }

void CAiAssistant::StoreCache(const string key, const datetime now,
                              const AiDecision &d, const string raw)
  {
   if(m_cfg.cache_seconds <= 0)
      return;
   TrimCache(now);
   int n = ArraySize(m_cache);
   if(!ArrayResize(m_cache, n + 1))
      return;
   m_cache[n].key = key;
   m_cache[n].created = now;
   m_cache[n].decision = d;
   m_cache[n].response = raw;
  }

void CAiAssistant::TrimCache(const datetime now)
  {
   for(int i = ArraySize(m_cache) - 1; i >= 0; i--)
     {
      if(now - m_cache[i].created > MathMax(m_cfg.cache_seconds, 60) * 2)
        {
         for(int k = i; k < ArraySize(m_cache) - 1; k++)
            m_cache[k] = m_cache[k + 1];
         ArrayResize(m_cache, ArraySize(m_cache) - 1);
        }
     }
   if(ArraySize(m_cache) > 200)
      ArrayResize(m_cache, 200);
  }

bool CAiAssistant::Decide(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                          const TradeCandidate &cand, const NewsContext &news,
                          const PortfolioSnapshot &portfolio, AiDecision &decision)
  {
   ResetDecision(decision);
   m_error = "";
   m_last_request = "";
   m_last_response = "";

   if(!m_ready)
     {
      // AI is not part of this decision (disabled, tester or optimization).
      decision.available = false;
      decision.used_fallback = false;
      decision.allowed = true;
      decision.risk_multiplier = 1.0;
      decision.reason_code = RC_AI_DISABLED;
      decision.reason = (m_tester || m_optimization) ? "AI not used in tester/optimization"
                                                      : "AI disabled by configuration";
      return true;
     }

   datetime now = TimeTradeServer();
   string key = StringFormat("%s|%d|%d|%d", spec.name, cand.direction,
                             (int)cand.strategy, (int)cand.bar_time);
   string raw = "";
   if(Cached(key, now, decision, raw))
     {
      m_last_response = raw;
      return true;
     }

   if(m_breaker_until > now)
     {
      ApplyFallback(decision, RC_AI_UNAVAILABLE, "AI circuit breaker open");
      return true;
     }
   if(RateLimitExceeded())
     {
      ApplyFallback(decision, RC_AI_UNAVAILABLE, "AI hourly call limit reached");
      return true;
     }

   string body = BuildRequest(spec, snap, cand, news, portfolio);
   m_last_request = body;
   NoteCall();
   string response = "";
   string err = "";
   if(!CallEndpoint(body, response, err))
     {
      m_consecutive_failures++;
      if(m_consecutive_failures >= MathMax(1, m_cfg.max_consecutive_failures))
        {
         m_breaker_until = now + MathMax(10, m_cfg.breaker_seconds);
         m_consecutive_failures = 0;
         LogWarn("AI circuit breaker opened after repeated failures");
        }
      m_error = err;
      m_last_response = "";
      ApplyFallback(decision, RC_AI_UNAVAILABLE, err);
      return true;
     }
   m_last_response = response;

   AiDecision parsed;
   ResetDecision(parsed);
   if(!ParseDecision(response, parsed, err))
     {
      m_error = err;
      ApplyFallback(decision, RC_AI_INVALID, err);
      return true;
     }
   m_consecutive_failures = 0;
   decision = parsed;
   StoreCache(key, now, decision, response);
   return true;
  }

#endif
//+------------------------------------------------------------------+
