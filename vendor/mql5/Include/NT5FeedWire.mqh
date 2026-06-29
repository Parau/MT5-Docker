//+------------------------------------------------------------------+
//| NT5FeedWire.mqh — wire JSON helpers (Service ↔ adapter)          |
//| Protocol: res/especificacao_novo_adaptador_nautilus_mt5.md §9    |
//+------------------------------------------------------------------+
#ifndef NT5_FEED_WIRE_MQH
#define NT5_FEED_WIRE_MQH

//+------------------------------------------------------------------+
string NT5JsonEscape(const string value)
  {
   string out = value;
   StringReplace(out, "\\", "\\\\");
   StringReplace(out, "\"", "\\\"");
   return out;
  }

//+------------------------------------------------------------------+
string NT5TickToJson(const MqlTick &tick)
  {
   return StringFormat(
      "{\"time_msc\":%I64d,\"bid\":%.8f,\"ask\":%.8f,\"last\":%.8f,\"volume\":%I64d,\"flags\":%u}",
      tick.time_msc,
      tick.bid,
      tick.ask,
      tick.last,
      (long)tick.volume,
      tick.flags
   );
  }

//+------------------------------------------------------------------+
string NT5BarSpecToJson(const string symbol, const string timeframe)
  {
   return StringFormat("\"%s:%s\"", NT5JsonEscape(symbol), NT5JsonEscape(timeframe));
  }

//+------------------------------------------------------------------+
string NT5BuildHelloJson(
   const string session,
   string &symbols[],
   string &bar_specs[]
)
  {
   string symbols_json = "[";
   const int count = ArraySize(symbols);
   for(int i = 0; i < count; i++)
     {
      if(i > 0)
         symbols_json += ",";
      symbols_json += StringFormat("\"%s\"", NT5JsonEscape(symbols[i]));
     }
   symbols_json += "]";

   string bars_json = "[";
   const int bar_count = ArraySize(bar_specs);
   for(int i = 0; i < bar_count; i++)
     {
      if(i > 0)
         bars_json += ",";
      bars_json += bar_specs[i];
     }
   bars_json += "]";

   return StringFormat(
      "{\"op\":\"hello\",\"session\":\"%s\",\"terminal\":\"%s\",\"account\":\"%I64d\",\"symbols\":%s,\"bars\":%s}",
      NT5JsonEscape(session),
      NT5JsonEscape(TerminalInfoString(TERMINAL_NAME)),
      AccountInfoInteger(ACCOUNT_LOGIN),
      symbols_json,
      bars_json
   );
  }

//+------------------------------------------------------------------+
string NT5BuildTicksJson(
   const string symbol,
   const long cursor,
   const MqlTick &ticks[],
   const int count
)
  {
   string data = "[";
   for(int i = 0; i < count; i++)
     {
      if(i > 0)
         data += ",";
      data += NT5TickToJson(ticks[i]);
     }
   data += "]";

   return StringFormat(
      "{\"op\":\"ticks\",\"symbol\":\"%s\",\"cursor\":%I64d,\"data\":%s}",
      NT5JsonEscape(symbol),
      cursor,
      data
   );
  }

//+------------------------------------------------------------------+
string NT5BuildHeartbeatJson()
  {
   // Wall-clock ms (MQL5 datetime is seconds; multiply for wire ts_msc field).
   return StringFormat("{\"op\":\"heartbeat\",\"ts_msc\":%I64d}", (long)((ulong)TimeGMT() * 1000));
  }

//+------------------------------------------------------------------+
string NT5BuildPongJson()
  {
   return "{\"op\":\"pong\"}";
  }

//+------------------------------------------------------------------+
string NT5TimeframeToString(const ENUM_TIMEFRAMES period)
  {
   switch(period)
     {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      default:
         return StringFormat("TF%d", (int)period);
     }
  }

//+------------------------------------------------------------------+
bool NT5TimeframeFromString(const string raw, ENUM_TIMEFRAMES &period)
  {
   string tf = raw;
   StringTrimLeft(tf);
   StringTrimRight(tf);
   if(!StringToUpper(tf))
      return false;

   if(tf == "M1")  { period = PERIOD_M1;  return true; }
   if(tf == "M5")  { period = PERIOD_M5;  return true; }
   if(tf == "M15") { period = PERIOD_M15; return true; }
   if(tf == "M30") { period = PERIOD_M30; return true; }
   if(tf == "H1")  { period = PERIOD_H1;  return true; }
   if(tf == "H4")  { period = PERIOD_H4;  return true; }
   if(tf == "D1")  { period = PERIOD_D1;  return true; }
   return false;
  }

//+------------------------------------------------------------------+
string NT5BuildBarJson(
   const string symbol,
   const string timeframe,
   const MqlRates &rate
)
  {
   return StringFormat(
      "{\"op\":\"bar\",\"symbol\":\"%s\",\"timeframe\":\"%s\",\"time\":%I64d,"
      "\"open\":%.8f,\"high\":%.8f,\"low\":%.8f,\"close\":%.8f,"
      "\"tick_volume\":%I64d,\"real_volume\":%I64d,\"spread\":%d}",
      NT5JsonEscape(symbol),
      NT5JsonEscape(timeframe),
      (long)rate.time,
      rate.open,
      rate.high,
      rate.low,
      rate.close,
      rate.tick_volume,
      rate.real_volume,
      rate.spread
   );
  }

//+------------------------------------------------------------------+
string NT5BuildErrorJson(const string code, const string message)
  {
   return StringFormat(
      "{\"op\":\"error\",\"code\":\"%s\",\"message\":\"%s\"}",
      NT5JsonEscape(code),
      NT5JsonEscape(message)
   );
  }

//+------------------------------------------------------------------+
bool NT5ExtractJsonStringField(const string json, const string field, string &value)
  {
   value = "";
   const string needle = StringFormat("\"%s\"", field);
   int pos = StringFind(json, needle);
   if(pos < 0)
      return false;

   pos = StringFind(json, ":", pos);
   if(pos < 0)
      return false;

   pos = StringFind(json, "\"", pos + 1);
   if(pos < 0)
      return false;

   const int end = StringFind(json, "\"", pos + 1);
   if(end < 0)
      return false;

   value = StringSubstr(json, pos + 1, end - pos - 1);
   return true;
  }

//+------------------------------------------------------------------+
bool NT5ParseWireOp(const string json, string &op)
  {
   return NT5ExtractJsonStringField(json, "op", op);
  }

//+------------------------------------------------------------------+
void NT5SplitCsvSymbols(const string csv, string &out[])
  {
   ArrayResize(out, 0);
   if(StringLen(csv) == 0)
      return;

   string parts[];
   const int n = StringSplit(csv, ',', parts);
   for(int i = 0; i < n; i++)
     {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(StringLen(parts[i]) == 0)
         continue;

      const int m = ArraySize(out);
      ArrayResize(out, m + 1);
      out[m] = parts[i];
     }
  }

//+------------------------------------------------------------------+
bool NT5ExtractJsonIntField(const string json, const string field, int &value)
  {
   value = 0;
   const string needle = StringFormat("\"%s\"", field);
   int pos = StringFind(json, needle);
   if(pos < 0)
      return false;

   pos = StringFind(json, ":", pos);
   if(pos < 0)
      return false;

   pos++;
   while(pos < StringLen(json) && StringGetCharacter(json, pos) == ' ')
      pos++;

   int end = pos;
   while(end < StringLen(json))
     {
      const ushort ch = StringGetCharacter(json, end);
      if(ch < '0' || ch > '9')
         break;
      end++;
     }

   if(end <= pos)
      return false;

   value = (int)StringToInteger(StringSubstr(json, pos, end - pos));
   return true;
  }

//+------------------------------------------------------------------+
void NT5SplitCsvBarSpecs(const string csv, string &out[])
  {
   ArrayResize(out, 0);
   if(StringLen(csv) == 0)
      return;

   string parts[];
   const int n = StringSplit(csv, ',', parts);
   for(int i = 0; i < n; i++)
     {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(StringLen(parts[i]) == 0)
         continue;

      string pair[];
      if(StringSplit(parts[i], ':', pair) != 2)
         continue;

      StringTrimLeft(pair[0]);
      StringTrimRight(pair[0]);
      StringTrimLeft(pair[1]);
      StringTrimRight(pair[1]);
      if(StringLen(pair[0]) == 0 || StringLen(pair[1]) == 0)
         continue;

      ENUM_TIMEFRAMES period;
      if(!NT5TimeframeFromString(pair[1], period))
         continue;

      const int m = ArraySize(out);
      ArrayResize(out, m + 1);
      out[m] = NT5BarSpecToJson(pair[0], NT5TimeframeToString(period));
     }
  }

//+------------------------------------------------------------------+
bool NT5ParseBarSpecJson(const string spec_json, string &symbol, string &timeframe)
  {
   symbol = "";
   timeframe = "";
   string inner = spec_json;
   StringReplace(inner, "\"", "");
   string parts[];
   if(StringSplit(inner, ':', parts) != 2)
      return false;

   symbol = parts[0];
   timeframe = parts[1];
   return (StringLen(symbol) > 0 && StringLen(timeframe) > 0);
  }

//+------------------------------------------------------------------+
bool NT5ExtractJsonStringArray(const string json, const string field, string &out[])
  {
   ArrayResize(out, 0);
   const string needle = StringFormat("\"%s\"", field);
   int pos = StringFind(json, needle);
   if(pos < 0)
      return false;

   pos = StringFind(json, "[", pos);
   if(pos < 0)
      return false;

   const int end = StringFind(json, "]", pos);
   if(end < 0)
      return false;

   string inner = StringSubstr(json, pos + 1, end - pos - 1);
   StringReplace(inner, " ", "");
   if(StringLen(inner) == 0)
      return true;

   string parts[];
   const int n = StringSplit(inner, ',', parts);
   for(int i = 0; i < n; i++)
     {
      StringReplace(parts[i], "\"", "");
      if(StringLen(parts[i]) == 0)
         continue;

      const int m = ArraySize(out);
      ArrayResize(out, m + 1);
      out[m] = parts[i];
     }
   return true;
  }

#endif
