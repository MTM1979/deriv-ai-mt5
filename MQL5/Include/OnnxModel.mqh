//+------------------------------------------------------------------+
//|                                                    OnnxModel.mqh |
//|  Native ONNX scoring with a hard feature contract.                 |
//|                                                                  |
//|  Fail-closed rules:                                               |
//|   * metadata schema and feature_order must match FeatureSpec.mqh   |
//|   * declared SHA-256 must match the model file                     |
//|   * input/output shapes must bind                                  |
//|   * a zero-vector self-test must produce finite probabilities      |
//|   * repeated inference failures open a circuit breaker             |
//+------------------------------------------------------------------+
#ifndef __DERIV_AI_ONNXMODEL_MQH__
#define __DERIV_AI_ONNXMODEL_MQH__

#include <Config.mqh>
#include <Utils.mqh>
#include <Json.mqh>
#include <SymbolSpec.mqh>
#include <Indicators.mqh>
#include <FeatureSpec.mqh>

struct ModelInfo
  {
   string   key;
   string   asset_class;
   string   file;
   string   version;
   string   sha256;
   long     handle;
   bool     loaded;
   int      feature_count;
   int      output_size;
   double   threshold;
   int      output_kind;
   string   error;
   int      failures;
   datetime disabled_until;
   datetime loaded_at;
  };

class COnnxModelStore
  {
private:
   MlConfig           m_cfg;
   ModelInfo          m_models[];
   bool               m_metadata_ok;
   string             m_error;
   bool               m_common_files;

   bool               LoadMetadata(const string path, string &err);
   bool               LoadOne(ModelInfo &m, string &err);
   bool               SelfTest(ModelInfo &m, string &err);
   bool               Sha256File(const string path, string &hex);
   int                SelectForAsset(const ENUM_ASSET_CLASS asset);
   int                OutputSizeFor(const int kind, const int declared);
   bool               KindFromString(const string s, int &kind);
   string             ResolvePath(const string file);

public:
                     COnnxModelStore(void);
   bool               Init(const MlConfig &cfg, string &err);
   void               Deinit(void);
   bool               Usable(void);
   bool               BuildFeatures(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                    const TradeCandidate &cand, float &f[]);
   bool               Score(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                            const TradeCandidate &cand, double &probability,
                            ENUM_REASON &reason, string &err);
   double             ThresholdFor(const ENUM_ASSET_CLASS asset);
   bool               RequiresModel(const ENUM_ASSET_CLASS asset);
   string             LastError(void)      { return m_error; }
   int                ModelCount(void)     { return ArraySize(m_models); }
   string             ModelKeyAt(const int i)
     {
      if(i < 0 || i >= ArraySize(m_models)) return "";
      return m_models[i].key;
     }
   string             ModelErrorAt(const int i)
     {
      if(i < 0 || i >= ArraySize(m_models)) return "";
      return m_models[i].error;
     }
  };

//+------------------------------------------------------------------+
COnnxModelStore::COnnxModelStore(void)
  {
   m_metadata_ok = false;
   m_error = "";
   m_common_files = false;
  }

string COnnxModelStore::ResolvePath(const string file)
  {
   string dir = TrimStr(m_cfg.model_dir);
   if(dir == "")
      return file;
   StringReplace(dir, "/", "\\");
   if(StringGetCharacter(dir, StringLen(dir) - 1) == '\\')
      return dir + file;
   return dir + "\\" + file;
  }

int COnnxModelStore::OutputSizeFor(const int kind, const int declared)
  {
   switch(kind)
     {
      case ML_OUT_BINARY_ONE:   return 1;
      case ML_OUT_BINARY_TWO:   return 2;
      case ML_OUT_UP_DOWN_TWO:  return 2;
      case ML_OUT_REGIME_PROBS: return MathMax(2, declared);
      default:                  return MathMax(1, declared);
     }
  }

bool COnnxModelStore::KindFromString(const string s, int &kind)
  {
   string v = LowerStr(TrimStr(s));
   if(v == "binary_two" || v == "binary_probs")
     {
      kind = ML_OUT_BINARY_TWO;
      return true;
     }
   if(v == "binary_one" || v == "binary")
     {
      kind = ML_OUT_BINARY_ONE;
      return true;
     }
   if(v == "up_down_two")
     {
      kind = ML_OUT_UP_DOWN_TWO;
      return true;
     }
   if(v == "regime_probs")
     {
      kind = ML_OUT_REGIME_PROBS;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| SHA-256 of a file inside MQL5/Files.                              |
//+------------------------------------------------------------------+
bool COnnxModelStore::Sha256File(const string path, string &hex)
  {
   hex = "";
   int h = FileOpen(path, FILE_READ | FILE_BIN | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return false;
   uchar data[];
   int n = (int)FileSize(h);
   if(n <= 0 || !ArrayResize(data, n))
     {
      FileClose(h);
      return false;
     }
   int read = (int)FileReadArray(h, data, 0, n);
   FileClose(h);
   if(read != n)
      return false;
   uchar key[1];
   key[0] = 0;
   uchar hash[];
   if(!CryptEncode(CRYPT_HASH_SHA256, data, key, hash))
      return false;
   for(int i = 0; i < ArraySize(hash); i++)
      hex += StringFormat("%02x", (int)hash[i]);
   return (StringLen(hex) == 64);
  }

bool COnnxModelStore::LoadOne(ModelInfo &m, string &err)
  {
   string path = ResolvePath(m.file);
   if(!FileExistsIn(path, m_common_files))
     {
      err = StringFormat("model file '%s' not found", path);
      return false;
     }

   //--- integrity ------------------------------------------------
   string actual = "";
   bool hash_ok = Sha256File(path, actual);
   if(m.sha256 != "")
     {
      if(!hash_ok)
        {
         err = "cannot compute model SHA-256";
         return false;
        }
      if(LowerStr(m.sha256) != LowerStr(actual))
        {
         err = StringFormat("model SHA-256 mismatch (metadata %s, file %s)",
                            StringSubstr(m.sha256, 0, 12), StringSubstr(actual, 0, 12));
         return false;
        }
     }
   else if(m_cfg.require_hash)
     {
      err = "metadata has no sha256 but require_hash is enabled";
      return false;
     }
   else if(!hash_ok)
      LogWarn(StringFormat("model '%s': SHA-256 unavailable (integrity not verified)", m.file));

   //--- load -----------------------------------------------------
   m.handle = OnnxCreate(path, ONNX_DEFAULT);
   if(m.handle == INVALID_HANDLE)
     {
      err = StringFormat("OnnxCreate failed for '%s'", path);
      return false;
     }
   ulong in_shape[2];
   in_shape[0] = 1;
   in_shape[1] = (ulong)FEATURE_COUNT;
   if(!OnnxSetInputShape(m.handle, 0, in_shape))
     {
      err = "OnnxSetInputShape failed";
      OnnxRelease(m.handle);
      m.handle = INVALID_HANDLE;
      return false;
     }
   ulong out_shape[2];
   out_shape[0] = 1;
   out_shape[1] = (ulong)m.output_size;
   if(!OnnxSetOutputShape(m.handle, 0, out_shape))
     {
      err = "OnnxSetOutputShape failed";
      OnnxRelease(m.handle);
      m.handle = INVALID_HANDLE;
      return false;
     }
   m.feature_count = FEATURE_COUNT;
   return true;
  }

bool COnnxModelStore::SelfTest(ModelInfo &m, string &err)
  {
   float fin[FEATURE_COUNT];
   for(int i = 0; i < FEATURE_COUNT; i++)
      fin[i] = 0.0f;
   float fout[];
   ArrayResize(fout, m.output_size);
   for(int i = 0; i < m.output_size; i++)
      fout[i] = 0.0f;
   if(!OnnxRun(m.handle, ONNX_NO_CONVERSION, fin, fout))
     {
      err = "self-test inference failed";
      return false;
     }
   for(int i = 0; i < m.output_size; i++)
     {
      if(!MathIsValidNumber((double)fout[i]) || fout[i] < -1e-6f || fout[i] > 1.000001f)
        {
         err = StringFormat("self-test output[%d]=%.6f is not a probability (export probabilities, not logits)",
                            i, (double)fout[i]);
         return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Load metadata and every declared model.                           |
//+------------------------------------------------------------------+
bool COnnxModelStore::Init(const MlConfig &cfg, string &err)
  {
   m_cfg = cfg;
   m_metadata_ok = false;
   m_error = "";
   err = "";
   ArrayResize(m_models, 0);

   if(!cfg.enabled)
     {
      m_metadata_ok = true;
      return true;
     }
   if(cfg.metadata_file == "")
     {
      err = "model metadata file is not configured";
      return false;
     }

   if(!LoadMetadata(cfg.metadata_file, err))
     {
      m_error = err;
      return !cfg.fail_on_load_error;
     }

   bool any_loaded = false;
   for(int i = 0; i < ArraySize(m_models); i++)
     {
      string merr = "";
      bool ok = LoadOne(m_models[i], merr);
      if(ok)
        {
         string serr = "";
         if(!SelfTest(m_models[i], serr))
           {
            ok = false;
            merr = serr;
           }
        }
      if(!ok)
        {
         m_models[i].loaded = false;
         m_models[i].error = merr;
         LogError(StringFormat("model '%s' unusable: %s", m_models[i].key, merr));
         if(m_models[i].handle != INVALID_HANDLE)
           {
            OnnxRelease(m_models[i].handle);
            m_models[i].handle = INVALID_HANDLE;
           }
        }
      else
        {
         m_models[i].loaded = true;
         m_models[i].loaded_at = TimeTradeServer();
         m_models[i].error = "";
         any_loaded = true;
         LogInfo(2, 2, StringFormat("model '%s' loaded (feature_count=%d, output=%d, threshold=%.2f, version=%s)",
                                    m_models[i].key, FEATURE_COUNT, m_models[i].output_size,
                                    m_models[i].threshold, m_models[i].version));
        }
     }

   if(!any_loaded)
     {
      err = "no ONNX model could be loaded";
      m_error = err;
      return !cfg.fail_on_load_error;
     }
   m_metadata_ok = true;
   return true;
  }

bool COnnxModelStore::LoadMetadata(const string path, string &err)
  {
   string text = "";
   if(!ReadTextFile(path, m_common_files, text, err))
      return false;
   string jerr = "";
   CJsonValue *root = JsonParse(text, jerr);
   if(root == NULL)
     {
      err = "metadata JSON invalid: " + jerr;
      return false;
     }
   bool ok = false;
   do
     {
      if(!root.IsObject())
        {
         err = "metadata root must be an object";
         break;
        }
      CJsonValue *schema = root.Get("schema");
      if(schema == NULL || !schema.IsNumber() || schema.GetInt() != META_SCHEMA_VERSION)
        {
         err = StringFormat("metadata schema must be %d", META_SCHEMA_VERSION);
         break;
        }

      //--- feature contract ---------------------------------------
      CJsonValue *order = root.Get("feature_order");
      if(order == NULL || !order.IsArray())
        {
         err = "metadata feature_order missing";
         break;
        }
      if(order.Count() != FEATURE_COUNT)
        {
         err = StringFormat("feature_order has %d entries, EA expects %d", order.Count(), FEATURE_COUNT);
         break;
        }
      bool mismatch = false;
      for(int i = 0; i < FEATURE_COUNT; i++)
        {
         CJsonValue *item = order.At(i);
         if(item == NULL || !item.IsString() || item.GetString() != FEATURE_NAMES[i])
           {
            err = StringFormat("feature_order[%d] mismatch ('%s' vs '%s')",
                               i, (item != NULL ? item.GetString() : ""), FEATURE_NAMES[i]);
            mismatch = true;
            break;
           }
        }
      if(mismatch)
         break;

      CJsonValue *models = root.Get("models");
      if(models == NULL || !models.IsArray() || models.Count() == 0)
        {
         err = "metadata models array missing or empty";
         break;
        }

      for(int i = 0; i < models.Count(); i++)
        {
         CJsonValue *m = models.At(i);
         if(m == NULL || !m.IsObject())
           {
            err = StringFormat("models[%d] is not an object", i);
            break;
           }
         ModelInfo info;
         info.key = "";
         info.asset_class = "";
         info.file = "";
         info.version = "";
         info.sha256 = "";
         info.handle = INVALID_HANDLE;
         info.loaded = false;
         info.feature_count = 0;
         info.output_size = 2;
         info.threshold = m_cfg.default_threshold;
         info.output_kind = ML_OUT_BINARY_TWO;
         info.error = "";
         info.failures = 0;
         info.disabled_until = 0;
         info.loaded_at = 0;

         bool found = false;
         info.key = m.GetStringKey("key", "", found);
         if(!found || info.key == "")
           {
            err = StringFormat("models[%d].key missing", i);
            break;
           }
         info.asset_class = LowerStr(m.GetStringKey("asset_class", "", found));
         if(!found || info.asset_class == "")
           {
            err = StringFormat("model '%s': asset_class missing", info.key);
            break;
           }
         info.file = m.GetStringKey("file", "", found);
         if(!found || info.file == "")
           {
            err = StringFormat("model '%s': file missing", info.key);
            break;
           }
         info.version = m.GetStringKey("version", "unknown", found);
         info.sha256 = m.GetStringKey("sha256", "", found);
         double threshold = m.GetNumberKey("threshold", info.threshold, found);
         if(found)
            info.threshold = ClampD(threshold, 0.0, 1.0);
         string kind_str = m.GetStringKey("output_kind", "binary_two", found);
         if(!KindFromString(kind_str, info.output_kind))
           {
            err = StringFormat("model '%s': unknown output_kind '%s'", info.key, kind_str);
            break;
           }
         int declared = (int)m.GetNumberKey("output_size", 2, found);
         info.output_size = OutputSizeFor(info.output_kind, declared);
         if(info.output_size < 1 || info.output_size > 16)
           {
            err = StringFormat("model '%s': invalid output_size", info.key);
            break;
           }
         int n = ArraySize(m_models);
         if(!ArrayResize(m_models, n + 1))
           {
            err = "out of memory loading model metadata";
            break;
           }
         m_models[n] = info;
        }
      if(err != "")
         break;
      ok = true;
     }
   while(false);
   delete root;
   return ok;
  }

void COnnxModelStore::Deinit(void)
  {
   for(int i = 0; i < ArraySize(m_models); i++)
     {
      if(m_models[i].handle != INVALID_HANDLE)
        {
         OnnxRelease(m_models[i].handle);
         m_models[i].handle = INVALID_HANDLE;
        }
      m_models[i].loaded = false;
     }
   ArrayResize(m_models, 0);
  }

bool COnnxModelStore::Usable(void)
  {
   for(int i = 0; i < ArraySize(m_models); i++)
      if(m_models[i].loaded)
         return true;
   return false;
  }

int COnnxModelStore::SelectForAsset(const ENUM_ASSET_CLASS asset)
  {
   string want = "";
   switch(asset)
     {
      case ASSET_FX:    want = "fx";    break;
      case ASSET_METAL: want = "metal"; break;
      case ASSET_INDEX: want = "index"; break;
      default:          want = "";      break;
     }
   int fallback = -1;
   for(int i = 0; i < ArraySize(m_models); i++)
     {
      if(!m_models[i].loaded)
         continue;
      if(want != "" && m_models[i].asset_class == want)
         return i;
      if(m_models[i].asset_class == "all" && fallback < 0)
         fallback = i;
     }
   return fallback;
  }

bool COnnxModelStore::RequiresModel(const ENUM_ASSET_CLASS asset)
  {
   return (SelectForAsset(asset) >= 0);
  }

double COnnxModelStore::ThresholdFor(const ENUM_ASSET_CLASS asset)
  {
   int i = SelectForAsset(asset);
   if(i < 0)
      return m_cfg.default_threshold;
   return m_models[i].threshold;
  }

//+------------------------------------------------------------------+
//| Build the exact feature vector described by FeatureSpec.mqh.      |
//| All features are direction-adjusted and bounded.                  |
//+------------------------------------------------------------------+
bool COnnxModelStore::BuildFeatures(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                                    const TradeCandidate &cand, float &f[])
  {
   if(!snap.valid || cand.direction == 0 || snap.atr <= 0.0 || spec.point <= 0.0)
      return false;
   if(!ArrayResize(f, FEATURE_COUNT))
      return false;
   double dir = (cand.direction > 0) ? 1.0 : -1.0;
   double atr = snap.atr;
   double point = spec.point;
   double max_spread = MathMax(1.0, (double)spec.max_spread_points);
   double bb_half = MathMax(0.5 * snap.bb_width, 0.1 * atr);

   double v[FEATURE_COUNT];
   v[0]  = 100.0 * snap.ret1;
   v[1]  = 100.0 * snap.ret3;
   v[2]  = 100.0 * snap.ret12;
   v[3]  = dir * (snap.close - snap.ema_fast) / atr;
   v[4]  = dir * (snap.ema_fast - snap.ema_mid) / atr;
   v[5]  = dir * (snap.ema_mid - snap.ema_slow) / atr;
   v[6]  = dir * snap.ema_slow_slope;
   v[7]  = dir * (snap.rsi - 50.0) / 50.0;
   v[8]  = dir * snap.macd_hist / (0.5 * atr);
   v[9]  = dir * (snap.macd_hist - snap.macd_hist_prev) / (0.5 * atr);
   v[10] = snap.atr_percentile;
   v[11] = snap.bb_width / atr;
   v[12] = dir * (snap.close - snap.bb_middle) / bb_half;
   v[13] = snap.adx / 100.0;
   v[14] = dir * (snap.di_plus - snap.di_minus) / 100.0;
   v[15] = dir * (snap.session_high - snap.close) / atr;
   v[16] = dir * (snap.close - snap.session_low) / atr;
   v[17] = dir * (snap.close - snap.vwap) / atr;
   v[18] = dir * (snap.day_high - snap.close) / atr;
   v[19] = (snap.session_high - snap.session_low) / atr;
   v[20] = dir * (snap.htf_close - snap.htf_ema_slow) / MathMax(snap.htf_atr, point);
   v[21] = dir * (snap.htf_rsi - 50.0) / 50.0;
   v[22] = (double)cand.minutes_since_open / 240.0;
   v[23] = (cand.minutes_to_event >= 9999) ? 1.0 : (double)cand.minutes_to_event / 240.0;
   v[24] = (double)cand.event_impact / 3.0;
   v[25] = cand.spread_points / max_spread;
   v[26] = snap.volume_ratio;
   v[27] = dir * (snap.ema_fast - snap.ema_slow) / atr;
   v[28] = ((dir > 0 && snap.sweep_low) || (dir < 0 && snap.sweep_high)) ? 1.0 : 0.0;
   v[29] = dir;

   double lo[FEATURE_COUNT] =
     {
      -5.0, -8.0, -15.0, -3.0, -3.0, -3.0, -2.0, -1.0, -3.0, -3.0,
      0.0, 0.0, -3.0, 0.0, -1.0, -5.0, -5.0, -5.0, -8.0, 0.0,
      -3.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, -3.0, 0.0, -1.0
     };
   double hi[FEATURE_COUNT] =
     {
      5.0, 8.0, 15.0, 3.0, 3.0, 3.0, 2.0, 1.0, 3.0, 3.0,
      1.0, 6.0, 3.0, 1.0, 1.0, 5.0, 5.0, 5.0, 8.0, 10.0,
      3.0, 1.0, 1.0, 1.0, 1.0, 2.0, 3.0, 3.0, 1.0, 1.0
     };
   for(int i = 0; i < FEATURE_COUNT; i++)
     {
      if(!MathIsValidNumber(v[i]))
         return false;
      f[i] = (float)ClampD(v[i], lo[i], hi[i]);
     }
   return true;
  }

//+------------------------------------------------------------------+
bool COnnxModelStore::Score(const SymbolSpec &spec, const IndicatorSnapshot &snap,
                            const TradeCandidate &cand, double &probability,
                            ENUM_REASON &reason, string &err)
  {
   probability = 0.0;
   err = "";
   if(!m_cfg.enabled)
     {
      reason = RC_ML_DISABLED;
      return false;
     }
   int idx = SelectForAsset(spec.asset);
   if(idx < 0)
     {
      reason = RC_ML_UNAVAILABLE;
      err = "no model for asset class";
      return false;
     }
   ModelInfo m = m_models[idx];
   if(!m.loaded || m.handle == INVALID_HANDLE)
     {
      reason = RC_ML_UNAVAILABLE;
      err = m.error;
      return false;
     }
   datetime now = TimeTradeServer();
   if(m.disabled_until > now)
     {
      reason = RC_ML_UNAVAILABLE;
      err = "model circuit breaker open";
      return false;
     }

   float fin[];
   if(!BuildFeatures(spec, snap, cand, fin))
     {
      reason = RC_ML_INFERENCE_FAILED;
      err = "feature vector invalid";
      return false;
     }
   float fout[];
   ArrayResize(fout, m.output_size);
   for(int i = 0; i < m.output_size; i++)
      fout[i] = 0.0f;
   if(!OnnxRun(m.handle, ONNX_NO_CONVERSION, fin, fout))
     {
      m_models[idx].failures++;
      if(m_models[idx].failures >= MathMax(1, m_cfg.max_consecutive_failures))
        {
         m_models[idx].disabled_until = now + 300;
         m_models[idx].failures = 0;
         LogError(StringFormat("model '%s' disabled for 300s after repeated inference failures", m.key));
        }
      reason = RC_ML_INFERENCE_FAILED;
      err = "OnnxRun failed";
      return false;
     }

   double p = 0.0;
   switch(m.output_kind)
     {
      case ML_OUT_BINARY_ONE:
         p = (double)fout[0];
         break;
      case ML_OUT_REGIME_PROBS:
        {
         double best = -1.0;
         for(int i = 0; i < m.output_size; i++)
            if((double)fout[i] > best)
               best = (double)fout[i];
         p = best;
         break;
        }
      default:
         p = (double)fout[1];
         break;
     }
   if(!MathIsValidNumber(p) || p < -1e-6 || p > 1.000001)
     {
      m_models[idx].failures++;
      reason = RC_ML_INFERENCE_FAILED;
      err = "model output is not a probability";
      return false;
     }
   probability = ClampD(p, 0.0, 1.0);
   m_models[idx].failures = 0;
   reason = RC_OK;
   if(m_cfg.log_inference)
      LogInfo(2, 2, StringFormat("ML %s %s p=%.4f threshold=%.2f", spec.name,
                                 StrategyToString(cand.strategy), probability, m.threshold));
   return true;
  }

#endif
//+------------------------------------------------------------------+
