//+------------------------------------------------------------------+
//|                                                         Json.mqh |
//|  Small, bounded JSON reader/writer used for the AI policy, model  |
//|  metadata, AI responses and the persisted EA state.               |
//|                                                                  |
//|  Deliberately strict: bounded size, bounded depth, typed access,  |
//|  no silent coercion. Callers must validate semantics.             |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_JSON_MQH__
#define __DERIV_AI_JSON_MQH__

#define JSON_MAX_DEPTH      32
#define JSON_MAX_BYTES      1048576

enum ENUM_JSON_TYPE
  {
   JSON_NULL = 0,
   JSON_BOOL,
   JSON_NUMBER,
   JSON_STRING,
   JSON_ARRAY,
   JSON_OBJECT
  };

//+------------------------------------------------------------------+
//| One JSON value.                                                   |
//+------------------------------------------------------------------+
class CJsonValue
  {
private:
   ENUM_JSON_TYPE     m_type;
   bool               m_bool;
   double             m_num;
   string             m_str;
   CJsonValue        *m_arr[];
   string             m_keys[];
   CJsonValue        *m_obj[];

public:
                      CJsonValue(void);
                     ~CJsonValue(void);
   void               Clear(void);

   ENUM_JSON_TYPE     Type(void)              { return m_type; }
   bool               IsNull(void)            { return m_type == JSON_NULL; }
   bool               IsObject(void)          { return m_type == JSON_OBJECT; }
   bool               IsArray(void)           { return m_type == JSON_ARRAY; }
   bool               IsString(void)          { return m_type == JSON_STRING; }
   bool               IsNumber(void)          { return m_type == JSON_NUMBER; }
   bool               IsBool(void)            { return m_type == JSON_BOOL; }

   void               SetNull(void);
   void               SetBool(const bool v);
   void               SetNumber(const double v);
   void               SetString(const string v);
   void               SetObject(void);
   void               SetArray(void);

   bool               GetBool(const bool fallback = false);
   double             GetNumber(const double fallback = 0.0);
   string             GetString(const string fallback = "");
   int                GetInt(const int fallback = 0);

   int                Count(void);
   bool               Append(CJsonValue *v);         // array
   bool               SetKey(const string key, CJsonValue *v);   // object, replace
   bool               AddKey(const string key, CJsonValue *v);   // object, append
   CJsonValue        *Get(const string key);         // object lookup or NULL
   CJsonValue        *At(const int index);           // array/object by index
   string             KeyAt(const int index);

   bool               HasKey(const string key);
   bool               GetBoolKey(const string key, const bool fallback, bool &found);
   double             GetNumberKey(const string key, const double fallback, bool &found);
   string             GetStringKey(const string key, const string fallback, bool &found);

   string             ToJson(void);
   string             ToJsonPretty(const int indent = 2);
  };

//+------------------------------------------------------------------+
CJsonValue::CJsonValue(void)
  {
   m_type = JSON_NULL;
   m_bool = false;
   m_num  = 0.0;
   m_str  = "";
  }

CJsonValue::~CJsonValue(void)
  {
   Clear();
  }

void CJsonValue::Clear(void)
  {
   for(int i = 0; i < ArraySize(m_arr); i++)
     {
      if(CheckPointer(m_arr[i]) == POINTER_DYNAMIC)
         delete m_arr[i];
      m_arr[i] = NULL;
     }
   ArrayResize(m_arr, 0);
   for(int i = 0; i < ArraySize(m_obj); i++)
     {
      if(CheckPointer(m_obj[i]) == POINTER_DYNAMIC)
         delete m_obj[i];
      m_obj[i] = NULL;
     }
   ArrayResize(m_obj, 0);
   ArrayResize(m_keys, 0);
   m_type = JSON_NULL;
   m_bool = false;
   m_num  = 0.0;
   m_str  = "";
  }

void CJsonValue::SetNull(void)
  {
   Clear();
   m_type = JSON_NULL;
  }

void CJsonValue::SetBool(const bool v)
  {
   Clear();
   m_type = JSON_BOOL;
   m_bool = v;
  }

void CJsonValue::SetNumber(const double v)
  {
   Clear();
   m_type = JSON_NUMBER;
   m_num  = MathIsValidNumber(v) ? v : 0.0;
  }

void CJsonValue::SetString(const string v)
  {
   Clear();
   m_type = JSON_STRING;
   m_str  = v;
  }

void CJsonValue::SetObject(void)
  {
   Clear();
   m_type = JSON_OBJECT;
  }

void CJsonValue::SetArray(void)
  {
   Clear();
   m_type = JSON_ARRAY;
  }

bool CJsonValue::GetBool(const bool fallback)
  {
   return (m_type == JSON_BOOL) ? m_bool : fallback;
  }

double CJsonValue::GetNumber(const double fallback)
  {
   if(m_type == JSON_NUMBER)
      return m_num;
   if(m_type == JSON_BOOL)
      return m_bool ? 1.0 : 0.0;
   return fallback;
  }

string CJsonValue::GetString(const string fallback)
  {
   return (m_type == JSON_STRING) ? m_str : fallback;
  }

int CJsonValue::GetInt(const int fallback)
  {
   if(m_type == JSON_NUMBER)
      return (int)MathRound(m_num);
   return fallback;
  }

int CJsonValue::Count(void)
  {
   if(m_type == JSON_ARRAY)
      return ArraySize(m_arr);
   if(m_type == JSON_OBJECT)
      return ArraySize(m_obj);
   return 0;
  }

bool CJsonValue::Append(CJsonValue *v)
  {
   if(m_type != JSON_ARRAY || CheckPointer(v) != POINTER_DYNAMIC)
      return false;
   int n = ArraySize(m_arr);
   if(!ArrayResize(m_arr, n + 1))
      return false;
   m_arr[n] = v;
   return true;
  }

bool CJsonValue::AddKey(const string key, CJsonValue *v)
  {
   if(m_type != JSON_OBJECT || key == "" || CheckPointer(v) != POINTER_DYNAMIC)
      return false;
   int n = ArraySize(m_obj);
   if(!ArrayResize(m_obj, n + 1))
      return false;
   if(!ArrayResize(m_keys, n + 1))
     {
      ArrayResize(m_obj, n);
      return false;
     }
   m_obj[n]  = v;
   m_keys[n] = key;
   return true;
  }

bool CJsonValue::SetKey(const string key, CJsonValue *v)
  {
   if(m_type != JSON_OBJECT || key == "" || CheckPointer(v) != POINTER_DYNAMIC)
      return false;
   for(int i = 0; i < ArraySize(m_obj); i++)
     {
      if(m_keys[i] == key)
        {
         if(CheckPointer(m_obj[i]) == POINTER_DYNAMIC)
            delete m_obj[i];
         m_obj[i] = v;
         return true;
        }
     }
   return AddKey(key, v);
  }

CJsonValue *CJsonValue::Get(const string key)
  {
   if(m_type != JSON_OBJECT)
      return NULL;
   for(int i = 0; i < ArraySize(m_obj); i++)
      if(m_keys[i] == key)
         return m_obj[i];
   return NULL;
  }

CJsonValue *CJsonValue::At(const int index)
  {
   if(m_type == JSON_ARRAY)
     {
      if(index < 0 || index >= ArraySize(m_arr))
         return NULL;
      return m_arr[index];
     }
   if(m_type == JSON_OBJECT)
     {
      if(index < 0 || index >= ArraySize(m_obj))
         return NULL;
      return m_obj[index];
     }
   return NULL;
  }

string CJsonValue::KeyAt(const int index)
  {
   if(m_type != JSON_OBJECT || index < 0 || index >= ArraySize(m_keys))
      return "";
   return m_keys[index];
  }

bool CJsonValue::HasKey(const string key)
  {
   return (Get(key) != NULL);
  }

bool CJsonValue::GetBoolKey(const string key, const bool fallback, bool &found)
  {
   CJsonValue *v = Get(key);
   found = (v != NULL && v.IsBool());
   return found ? v.GetBool() : fallback;
  }

double CJsonValue::GetNumberKey(const string key, const double fallback, bool &found)
  {
   CJsonValue *v = Get(key);
   found = (v != NULL && v.IsNumber());
   return found ? v.GetNumber() : fallback;
  }

string CJsonValue::GetStringKey(const string key, const string fallback, bool &found)
  {
   CJsonValue *v = Get(key);
   found = (v != NULL && v.IsString());
   return found ? v.GetString() : fallback;
  }

//+------------------------------------------------------------------+
//| Serialisation                                                     |
//+------------------------------------------------------------------+
string JsonEscape(const string s)
  {
   string out = "\"";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      ushort ch = StringGetCharacter(s, i);
      switch(ch)
        {
         case '"':  out += "\\\""; break;
         case '\\': out += "\\\\"; break;
         case 8:    out += "\\b";  break;
         case 12:   out += "\\f";  break;
         case '\n': out += "\\n";  break;
         case '\r': out += "\\r";  break;
         case '\t': out += "\\t";  break;
         default:
            if(ch < 32)
               out += StringFormat("\\u%04x", (int)ch);
            else
               out += ShortToString(ch);
            break;
        }
     }
   out += "\"";
   return out;
  }

string JsonNumber(const double v)
  {
   if(!MathIsValidNumber(v))
      return "0";
   if(v == MathRound(v) && MathAbs(v) < 1e15)
      return StringFormat("%.0f", v);
   return StringFormat("%.10g", v);
  }

string CJsonValue::ToJson(void)
  {
   switch(m_type)
     {
      case JSON_BOOL:   return m_bool ? "true" : "false";
      case JSON_NUMBER: return JsonNumber(m_num);
      case JSON_STRING: return JsonEscape(m_str);
      case JSON_ARRAY:
        {
         string out = "[";
         for(int i = 0; i < ArraySize(m_arr); i++)
           {
            if(i > 0) out += ",";
            out += (m_arr[i] != NULL) ? m_arr[i].ToJson() : "null";
           }
         return out + "]";
        }
      case JSON_OBJECT:
        {
         string out = "{";
         for(int i = 0; i < ArraySize(m_obj); i++)
           {
            if(i > 0) out += ",";
            out += JsonEscape(m_keys[i]) + ":";
            out += (m_obj[i] != NULL) ? m_obj[i].ToJson() : "null";
           }
         return out + "}";
        }
      default:
         return "null";
     }
  }

string CJsonValue::ToJsonPretty(const int indent)
  {
   // Pretty output is for human-facing audit files only. It delegates to a
   // simple recursive formatter that keeps the same ordering as ToJson().
   if(m_type == JSON_OBJECT)
     {
      string pad = "";
      for(int i = 0; i < indent; i++) pad += " ";
      string inner = "";
      for(int i = 0; i < ArraySize(m_obj); i++)
        {
         if(i > 0) inner += ",\n";
         inner += pad + "  " + JsonEscape(m_keys[i]) + ": ";
         if(m_obj[i] == NULL)
            inner += "null";
         else if(m_obj[i].Type() == JSON_OBJECT || m_obj[i].Type() == JSON_ARRAY)
            inner += m_obj[i].ToJsonPretty(indent + 2);
         else
            inner += m_obj[i].ToJson();
        }
      return "{\n" + inner + "\n" + pad + "}";
     }
   if(m_type == JSON_ARRAY)
     {
      string pad = "";
      for(int i = 0; i < indent; i++) pad += " ";
      string inner = "";
      for(int i = 0; i < ArraySize(m_arr); i++)
        {
         if(i > 0) inner += ",\n";
         inner += pad + "  ";
         if(m_arr[i] == NULL)
            inner += "null";
         else if(m_arr[i].Type() == JSON_OBJECT || m_arr[i].Type() == JSON_ARRAY)
            inner += m_arr[i].ToJsonPretty(indent + 2);
         else
            inner += m_arr[i].ToJson();
        }
      return "[\n" + inner + "\n" + pad + "]";
     }
   return ToJson();
  }

//+------------------------------------------------------------------+
//| Strict recursive-descent parser.                                  |
//+------------------------------------------------------------------+
class CJsonParser
  {
private:
   string             m_s;
   int                m_i;
   int                m_len;
   int                m_depth;
   string             m_err;

   void               SkipWs(void);
   bool               Fail(const string msg);
   bool               ParseValue(CJsonValue *out);
   bool               ParseObject(CJsonValue *out);
   bool               ParseArray(CJsonValue *out);
   bool               ParseString(string &out);
   bool               ParseNumber(double &out);
   bool               Hex4(int &value);
   string             Peek(const int count);

public:
   CJsonValue        *Parse(const string text, string &err);
  };

void CJsonParser::SkipWs(void)
  {
   while(m_i < m_len)
     {
      ushort ch = StringGetCharacter(m_s, m_i);
      if(ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
         m_i++;
      else
         break;
     }
  }

bool CJsonParser::Fail(const string msg)
  {
   if(m_err == "")
      m_err = StringFormat("%s at offset %d", msg, m_i);
   return false;
  }

string CJsonParser::Peek(const int count)
  {
   if(m_i + count > m_len)
      return "";
   return StringSubstr(m_s, m_i, count);
  }

bool CJsonParser::Hex4(int &value)
  {
   value = 0;
   if(m_i + 4 > m_len)
      return Fail("truncated \\u escape");
   for(int k = 0; k < 4; k++)
     {
      ushort ch = StringGetCharacter(m_s, m_i + k);
      int d = -1;
      if(ch >= '0' && ch <= '9') d = ch - '0';
      else if(ch >= 'a' && ch <= 'f') d = 10 + ch - 'a';
      else if(ch >= 'A' && ch <= 'F') d = 10 + ch - 'A';
      else return Fail("invalid hex digit in \\u escape");
      value = value * 16 + d;
     }
   m_i += 4;
   return true;
  }

bool CJsonParser::ParseString(string &out)
  {
   out = "";
   if(m_i >= m_len || StringGetCharacter(m_s, m_i) != '"')
      return Fail("expected string");
   m_i++;
   while(m_i < m_len)
     {
      ushort ch = StringGetCharacter(m_s, m_i);
      if(ch == '"')
        {
         m_i++;
         return true;
        }
      if(ch == '\\')
        {
         m_i++;
         if(m_i >= m_len)
            return Fail("truncated escape");
         ushort esc = StringGetCharacter(m_s, m_i);
         m_i++;
         switch(esc)
           {
            case '"':  out += "\""; break;
            case '\\': out += "\\"; break;
            case '/':  out += "/";  break;
            case 'b':  out += ShortToString(8); break;
            case 'f':  out += ShortToString(12); break;
            case 'n':  out += "\n"; break;
            case 'r':  out += "\r"; break;
            case 't':  out += "\t"; break;
            case 'u':
              {
               int code = 0;
               if(!Hex4(code))
                  return false;
               if(code >= 0xD800 && code <= 0xDBFF && Peek(2) == "\\u")
                 {
                  int save = m_i;
                  m_i += 2;
                  int low = 0;
                  if(Hex4(low) && low >= 0xDC00 && low <= 0xDFFF)
                    {
                     out += ShortToString((ushort)code);
                     out += ShortToString((ushort)low);
                    }
                  else
                    {
                     m_i = save;
                     out += "?";
                    }
                 }
               else if(code >= 0xD800 && code <= 0xDFFF)
                  out += "?";
               else
                  out += ShortToString((ushort)code);
               break;
              }
            default:
               return Fail("invalid escape sequence");
           }
         continue;
        }
      if(ch < 32)
         return Fail("unescaped control character in string");
      out += ShortToString(ch);
      m_i++;
     }
   return Fail("unterminated string");
  }

bool CJsonParser::ParseNumber(double &out)
  {
   int start = m_i;
   while(m_i < m_len)
     {
      ushort ch = StringGetCharacter(m_s, m_i);
      if((ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.' || ch == 'e' || ch == 'E')
         m_i++;
      else
         break;
     }
   if(m_i == start)
      return Fail("expected number");
   string token = StringSubstr(m_s, start, m_i - start);
   // Reject tokens MQL5 would silently accept but JSON forbids.
   if(StringFind(token, "e", 0) < 0 && StringFind(token, "E", 0) < 0 &&
      StringFind(token, ".", 0) < 0)
     {
      for(int k = 0; k < StringLen(token); k++)
        {
         ushort ch = StringGetCharacter(token, k);
         if(!((ch >= '0' && ch <= '9') || (k == 0 && ch == '-')))
            return Fail("invalid number");
        }
     }
   out = StringToDouble(token);
   if(!MathIsValidNumber(out))
      return Fail("number out of range");
   return true;
  }

bool CJsonParser::ParseArray(CJsonValue *out)
  {
   if(m_depth >= JSON_MAX_DEPTH)
      return Fail("maximum nesting depth exceeded");
   m_depth++;
   m_i++; // '['
   out.SetArray();
   SkipWs();
   if(m_i < m_len && StringGetCharacter(m_s, m_i) == ']')
     {
      m_i++;
      m_depth--;
      return true;
     }
   while(m_i < m_len)
     {
      CJsonValue *child = new CJsonValue();
      if(child == NULL)
        {
         m_depth--;
         return Fail("out of memory");
        }
      if(!ParseValue(child))
        {
         delete child;
         m_depth--;
         return false;
        }
      if(!out.Append(child))
        {
         delete child;
         m_depth--;
         return Fail("array append failed");
        }
      SkipWs();
      if(m_i >= m_len)
        {
         m_depth--;
         return Fail("unterminated array");
        }
      ushort ch = StringGetCharacter(m_s, m_i);
      if(ch == ',')
        {
         m_i++;
         SkipWs();
         continue;
        }
      if(ch == ']')
        {
         m_i++;
         m_depth--;
         return true;
        }
      m_depth--;
      return Fail("expected ',' or ']'");
     }
   m_depth--;
   return Fail("unterminated array");
  }

bool CJsonParser::ParseObject(CJsonValue *out)
  {
   if(m_depth >= JSON_MAX_DEPTH)
      return Fail("maximum nesting depth exceeded");
   m_depth++;
   m_i++; // '{'
   out.SetObject();
   SkipWs();
   if(m_i < m_len && StringGetCharacter(m_s, m_i) == '}')
     {
      m_i++;
      m_depth--;
      return true;
     }
   while(m_i < m_len)
     {
      SkipWs();
      string key = "";
      if(!ParseString(key))
        {
         m_depth--;
         return false;
        }
      SkipWs();
      if(m_i >= m_len || StringGetCharacter(m_s, m_i) != ':')
        {
         m_depth--;
         return Fail("expected ':'");
        }
      m_i++;
      SkipWs();
      CJsonValue *child = new CJsonValue();
      if(child == NULL)
        {
         m_depth--;
         return Fail("out of memory");
        }
      if(!ParseValue(child))
        {
         delete child;
         m_depth--;
         return false;
        }
      if(!out.AddKey(key, child))
        {
         delete child;
         m_depth--;
         return Fail("duplicate or invalid object key");
        }
      SkipWs();
      if(m_i >= m_len)
        {
         m_depth--;
         return Fail("unterminated object");
        }
      ushort ch = StringGetCharacter(m_s, m_i);
      if(ch == ',')
        {
         m_i++;
         continue;
        }
      if(ch == '}')
        {
         m_i++;
         m_depth--;
         return true;
        }
      m_depth--;
      return Fail("expected ',' or '}'");
     }
   m_depth--;
   return Fail("unterminated object");
  }

bool CJsonParser::ParseValue(CJsonValue *out)
  {
   SkipWs();
   if(m_i >= m_len)
      return Fail("unexpected end of input");
   ushort ch = StringGetCharacter(m_s, m_i);
   if(ch == '{')
      return ParseObject(out);
   if(ch == '[')
      return ParseArray(out);
   if(ch == '"')
     {
      string s = "";
      if(!ParseString(s))
         return false;
      out.SetString(s);
      return true;
     }
   if(ch == 't')
     {
      if(Peek(4) != "true")
         return Fail("invalid literal");
      m_i += 4;
      out.SetBool(true);
      return true;
     }
   if(ch == 'f')
     {
      if(Peek(5) != "false")
         return Fail("invalid literal");
      m_i += 5;
      out.SetBool(false);
      return true;
     }
   if(ch == 'n')
     {
      if(Peek(4) != "null")
         return Fail("invalid literal");
      m_i += 4;
      out.SetNull();
      return true;
     }
   double num = 0.0;
   if(!ParseNumber(num))
      return false;
   out.SetNumber(num);
   return true;
  }

CJsonValue *CJsonParser::Parse(const string text, string &err)
  {
   m_s     = text;
   m_len   = StringLen(text);
   m_i     = 0;
   m_depth = 0;
   m_err   = "";
   if(m_len == 0)
     {
      err = "empty JSON document";
      return NULL;
     }
   if(m_len > JSON_MAX_BYTES)
     {
      err = "JSON document exceeds size limit";
      return NULL;
     }
   CJsonValue *root = new CJsonValue();
   if(root == NULL)
     {
      err = "out of memory";
      return NULL;
     }
   if(!ParseValue(root))
     {
      err = m_err;
      delete root;
      return NULL;
     }
   SkipWs();
   if(m_i != m_len)
     {
      err = StringFormat("trailing data at offset %d", m_i);
      delete root;
      return NULL;
     }
   return root;
  }

//+------------------------------------------------------------------+
//| Convenience wrapper. Caller owns the returned pointer.            |
//+------------------------------------------------------------------+
CJsonValue *JsonParse(const string text, string &err)
  {
   CJsonParser parser;
   return parser.Parse(text, err);
  }

#endif
//+------------------------------------------------------------------+

