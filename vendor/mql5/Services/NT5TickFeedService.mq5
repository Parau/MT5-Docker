//+------------------------------------------------------------------+
//| NT5TickFeedService.mq5                                           |
//| MQL5 Service: CopyTicks + cursor + WS push to nautilus adapter   |
//| Spec: res/especificacao_novo_adaptador_nautilus_mt5.md           |
//+------------------------------------------------------------------+
#property service
#property copyright "nt_mt5"
#property version   "1.05"
#property description "NT5 live tick + bar feed via CopyTicks/CopyRates and WebSocket"

#include <WebSocket/client.mqh>
#include <NT5FeedWire.mqh>

input string InpWsUrl        = "ws://host.docker.internal:8765/mt5-feed";
input int    InpSleepMs      = 10;
input int    InpBatchSize    = 100;
input string InpSymbols      = "";
input string InpBarSpecs     = "";
input int    InpBarPollMs    = 300;
input int    InpHeartbeatSec = 30;
input bool   InpDebug        = true;

struct NT5SymbolState
  {
   string  symbol;
   long    last_msc;
   bool    active;
   MqlTick last_sent;
   bool    has_last_sent;
  };

class CNT5FeedWebSocket : public WebSocketClient<Hybi>
  {
public:
                     CNT5FeedWebSocket(const string address, const bool debug)
                        : WebSocketClient(address, debug, false) {}

   void              onConnected() override;
   void              onDisconnect() override;
   void              onMessage(IWebSocketMessage *msg) override;
  };

struct NT5BarState
  {
   string           symbol;
   ENUM_TIMEFRAMES  period;
   string           timeframe;
   datetime         last_closed_time;
   bool             active;
  };

CNT5FeedWebSocket *g_ws = NULL;
NT5SymbolState     g_symbols[];
NT5BarState        g_bars[];
string             g_session = "";
ulong              g_last_heartbeat_tick = 0;
ulong              g_last_bar_poll_tick = 0;

//+------------------------------------------------------------------+
int NT5FindSymbolIndex(const string symbol)
  {
   for(int i = 0; i < ArraySize(g_symbols); i++)
     {
      if(g_symbols[i].symbol == symbol)
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
void NT5ListActiveSymbols(string &out[])
  {
   ArrayResize(out, 0);
   for(int i = 0; i < ArraySize(g_symbols); i++)
     {
      if(!g_symbols[i].active)
         continue;

      const int m = ArraySize(out);
      ArrayResize(out, m + 1);
      out[m] = g_symbols[i].symbol;
     }
  }

//+------------------------------------------------------------------+
bool NT5EnsureSymbolSelected(const string symbol)
  {
   if(!SymbolSelect(symbol, true))
     {
      PrintFormat("[NT5Feed] SymbolSelect failed for %s err=%d", symbol, GetLastError());
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void NT5ActivateSymbol(const string symbol, bool &changed)
  {
   changed = false;
   if(!NT5EnsureSymbolSelected(symbol))
      return;

   int idx = NT5FindSymbolIndex(symbol);
   if(idx < 0)
     {
      idx = ArraySize(g_symbols);
      ArrayResize(g_symbols, idx + 1);
      g_symbols[idx].symbol = symbol;
      g_symbols[idx].last_msc = 0;
      g_symbols[idx].active = true;
      g_symbols[idx].has_last_sent = false;
      changed = true;
      PrintFormat("[NT5Feed] subscribed symbol %s", symbol);
      return;
     }

   if(!g_symbols[idx].active)
     {
      g_symbols[idx].active = true;
      changed = true;
      PrintFormat("[NT5Feed] re-subscribed symbol %s", symbol);
     }
  }

//+------------------------------------------------------------------+
void NT5DeactivateSymbol(const string symbol, bool &changed)
  {
   changed = false;
   const int idx = NT5FindSymbolIndex(symbol);
   if(idx < 0 || !g_symbols[idx].active)
      return;

   g_symbols[idx].active = false;
   changed = true;
   PrintFormat("[NT5Feed] unsubscribed symbol %s", symbol);
  }

//+------------------------------------------------------------------+
void NT5ListActiveBarSpecs(string &out[])
  {
   ArrayResize(out, 0);
   for(int i = 0; i < ArraySize(g_bars); i++)
     {
      if(!g_bars[i].active)
         continue;

      const int m = ArraySize(out);
      ArrayResize(out, m + 1);
      out[m] = NT5BarSpecToJson(g_bars[i].symbol, g_bars[i].timeframe);
     }
  }

//+------------------------------------------------------------------+
int NT5FindBarIndex(const string symbol, const ENUM_TIMEFRAMES period)
  {
   for(int i = 0; i < ArraySize(g_bars); i++)
     {
      if(g_bars[i].symbol == symbol && g_bars[i].period == period)
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
void NT5ActivateBar(const string symbol, const ENUM_TIMEFRAMES period, bool &changed)
  {
   changed = false;
   if(!NT5EnsureSymbolSelected(symbol))
      return;

   const string tf = NT5TimeframeToString(period);
   int idx = NT5FindBarIndex(symbol, period);
   if(idx < 0)
     {
      idx = ArraySize(g_bars);
      ArrayResize(g_bars, idx + 1);
      g_bars[idx].symbol = symbol;
      g_bars[idx].period = period;
      g_bars[idx].timeframe = tf;
      g_bars[idx].last_closed_time = 0;
      g_bars[idx].active = true;
      changed = true;
      PrintFormat("[NT5Feed] subscribed bars %s:%s", symbol, tf);
      return;
     }

   if(!g_bars[idx].active)
     {
      g_bars[idx].last_closed_time = 0;
      g_bars[idx].active = true;
      changed = true;
      PrintFormat("[NT5Feed] re-subscribed bars %s:%s", symbol, tf);
     }
  }

//+------------------------------------------------------------------+
void NT5DeactivateBar(const string symbol, const ENUM_TIMEFRAMES period, bool &changed)
  {
   changed = false;
   const int idx = NT5FindBarIndex(symbol, period);
   if(idx < 0 || !g_bars[idx].active)
      return;

   g_bars[idx].active = false;
   changed = true;
   PrintFormat("[NT5Feed] unsubscribed bars %s:%s", symbol, g_bars[idx].timeframe);
  }

//+------------------------------------------------------------------+
void NT5HandleSubscribeBars(const string json, bool subscribe)
  {
   string symbols[];
   if(!NT5ExtractJsonStringArray(json, "symbols", symbols))
      return;

   string tf_raw = "";
   if(!NT5ExtractJsonStringField(json, "timeframe", tf_raw))
     {
      if(g_ws != NULL && g_ws.isConnected())
         g_ws.send(NT5BuildErrorJson("missing_timeframe", "subscribe_bars requires timeframe"));
      return;
     }

   ENUM_TIMEFRAMES period;
   if(!NT5TimeframeFromString(tf_raw, period))
     {
      if(g_ws != NULL && g_ws.isConnected())
         g_ws.send(NT5BuildErrorJson("invalid_timeframe", tf_raw));
      return;
     }

   bool changed = false;
   for(int i = 0; i < ArraySize(symbols); i++)
     {
      bool one = false;
      if(subscribe)
         NT5ActivateBar(symbols[i], period, one);
      else
         NT5DeactivateBar(symbols[i], period, one);
      if(one)
         changed = true;
     }

   if(changed)
      NT5SendHello();
  }

//+------------------------------------------------------------------+
void NT5SendHello()
  {
   if(g_ws == NULL || !g_ws.isConnected())
      return;

   string active[];
   NT5ListActiveSymbols(active);
   string bar_specs[];
   NT5ListActiveBarSpecs(bar_specs);
   const string hello = NT5BuildHelloJson(g_session, active, bar_specs);
   if(!g_ws.send(hello))
     {
      PrintFormat("[NT5Feed] failed to send hello err=%d", GetLastError());
      return;
     }

   if(InpDebug)
      Print("[NT5Feed] sent hello");
  }

//+------------------------------------------------------------------+
void NT5HandleWireMessage(const string json)
  {
   string op = "";
   if(!NT5ParseWireOp(json, op))
      return;

   if(op == "subscribe")
     {
      string symbols[];
      if(NT5ExtractJsonStringArray(json, "symbols", symbols))
        {
         bool changed = false;
         for(int i = 0; i < ArraySize(symbols); i++)
           {
            bool one = false;
            NT5ActivateSymbol(symbols[i], one);
            if(one)
               changed = true;
           }
         if(changed)
            NT5SendHello();
        }
      return;
     }

   if(op == "unsubscribe")
     {
      string symbols[];
      if(NT5ExtractJsonStringArray(json, "symbols", symbols))
        {
         bool changed = false;
         for(int i = 0; i < ArraySize(symbols); i++)
           {
            bool one = false;
            NT5DeactivateSymbol(symbols[i], one);
            if(one)
               changed = true;
           }
         if(changed)
            NT5SendHello();
        }
      return;
     }

   if(op == "subscribe_bars")
     {
      NT5HandleSubscribeBars(json, true);
      return;
     }

   if(op == "unsubscribe_bars")
     {
      NT5HandleSubscribeBars(json, false);
      return;
     }

   if(op == "ping")
     {
      if(g_ws != NULL && g_ws.isConnected())
         g_ws.send(NT5BuildPongJson());
      return;
     }
  }

//+------------------------------------------------------------------+
bool NT5TickSameSnapshot(const MqlTick &a, const MqlTick &b)
  {
   return (
      a.time_msc == b.time_msc
      && a.bid == b.bid
      && a.ask == b.ask
      && a.last == b.last
      && a.flags == b.flags
      && a.volume == b.volume
   );
  }

//+------------------------------------------------------------------+
void NT5SeedCursorFromMarket(const int idx)
  {
   MqlTick latest;
   if(SymbolInfoTick(g_symbols[idx].symbol, latest))
     {
      g_symbols[idx].last_msc = latest.time_msc;
      g_symbols[idx].last_sent = latest;
      g_symbols[idx].has_last_sent = true;
      return;
     }

   g_symbols[idx].last_msc = (long)((ulong)TimeCurrent() * 1000);
   g_symbols[idx].has_last_sent = false;
  }

//+------------------------------------------------------------------+
int NT5FilterNewTicks(const int idx, const MqlTick &src[], const int count, MqlTick &out[])
  {
   ArrayResize(out, 0);
   if(count <= 0)
      return 0;

   int start = 0;
   if(g_symbols[idx].has_last_sent)
     {
      for(int i = 0; i < count; i++)
        {
         if(!NT5TickSameSnapshot(src[i], g_symbols[idx].last_sent))
           {
            start = i;
            break;
           }
         if(i == count - 1)
            return 0;
        }
     }

   const int out_count = count - start;
   ArrayResize(out, out_count);
   for(int i = 0; i < out_count; i++)
      out[i] = src[start + i];

   return out_count;
  }

//+------------------------------------------------------------------+
void NT5ExportSymbolTicks(const int idx)
  {
   if(!g_symbols[idx].active)
      return;

   if(g_symbols[idx].last_msc == 0)
      NT5SeedCursorFromMarket(idx);

   MqlTick raw[];
   const long from_msc = g_symbols[idx].last_msc + 1;
   ResetLastError();
   const int copied = CopyTicks(
      g_symbols[idx].symbol,
      raw,
      COPY_TICKS_ALL,
      from_msc,
      InpBatchSize
   );

   if(copied < 0)
     {
      PrintFormat("[NT5Feed] CopyTicks failed for %s from=%I64d err=%d",
                  g_symbols[idx].symbol, from_msc, GetLastError());
      return;
     }

   if(copied == 0)
      return;

   MqlTick ticks[];
   const int send_count = NT5FilterNewTicks(idx, raw, copied, ticks);
   if(send_count <= 0)
      return;

   const long cursor = ticks[send_count - 1].time_msc;
   const string payload = NT5BuildTicksJson(
      g_symbols[idx].symbol,
      cursor,
      ticks,
      send_count
   );

   if(g_ws == NULL || !g_ws.send(payload))
     {
      PrintFormat("[NT5Feed] failed to send ticks for %s err=%d",
                  g_symbols[idx].symbol, GetLastError());
      return;
     }

   g_symbols[idx].last_msc = cursor;
   g_symbols[idx].last_sent = ticks[send_count - 1];
   g_symbols[idx].has_last_sent = true;

   if(InpDebug)
      PrintFormat("[NT5Feed] sent %d ticks for %s cursor=%I64d",
                  send_count, g_symbols[idx].symbol, cursor);
  }

//+------------------------------------------------------------------+
void NT5ExportAllTicks()
  {
   for(int i = 0; i < ArraySize(g_symbols); i++)
      NT5ExportSymbolTicks(i);
  }

//+------------------------------------------------------------------+
void NT5PollBar(const int idx)
  {
   if(!g_bars[idx].active)
      return;

   if(!NT5EnsureSymbolSelected(g_bars[idx].symbol))
      return;

   MqlRates rates[];
   ResetLastError();
   // start_pos=1, count=1 → rates[0] is the last closed bar (0 = forming bar).
   const int copied = CopyRates(
      g_bars[idx].symbol,
      g_bars[idx].period,
      1,
      1,
      rates
   );

   if(copied < 0)
     {
      PrintFormat(
         "[NT5Feed] CopyRates failed for %s:%s err=%d",
         g_bars[idx].symbol,
         g_bars[idx].timeframe,
         GetLastError()
      );
      return;
     }

   if(copied == 0)
      return;

   const datetime bar_time = rates[0].time;
   if(bar_time <= 0)
      return;

   if(g_bars[idx].last_closed_time == bar_time)
      return;

   const string payload = NT5BuildBarJson(
      g_bars[idx].symbol,
      g_bars[idx].timeframe,
      rates[0]
   );

   if(g_ws == NULL || !g_ws.isConnected() || !g_ws.send(payload))
     {
      PrintFormat(
         "[NT5Feed] failed to send bar for %s:%s err=%d",
         g_bars[idx].symbol,
         g_bars[idx].timeframe,
         GetLastError()
      );
      return;
     }

   g_bars[idx].last_closed_time = bar_time;

   if(InpDebug)
      PrintFormat(
         "[NT5Feed] sent bar %s:%s time=%I64d close=%.8f",
         g_bars[idx].symbol,
         g_bars[idx].timeframe,
         (long)bar_time,
         rates[0].close
      );
  }

//+------------------------------------------------------------------+
void NT5PollAllBars()
  {
   const ulong now = GetTickCount64();
   if(InpBarPollMs > 0 && now - g_last_bar_poll_tick < (ulong)InpBarPollMs)
      return;

   g_last_bar_poll_tick = now;

   for(int i = 0; i < ArraySize(g_bars); i++)
      NT5PollBar(i);
  }

//+------------------------------------------------------------------+
void NT5ActivateInitialBarSpecs()
  {
   string specs[];
   NT5SplitCsvBarSpecs(InpBarSpecs, specs);
   for(int i = 0; i < ArraySize(specs); i++)
     {
      string symbol = "";
      string timeframe = "";
      if(!NT5ParseBarSpecJson(specs[i], symbol, timeframe))
         continue;

      ENUM_TIMEFRAMES period;
      if(!NT5TimeframeFromString(timeframe, period))
         continue;

      bool changed = false;
      NT5ActivateBar(symbol, period, changed);
     }
  }

//+------------------------------------------------------------------+
void NT5MaybeSendHeartbeat()
  {
   const ulong now = GetTickCount64();
   if(now - g_last_heartbeat_tick < (ulong)InpHeartbeatSec * 1000UL)
      return;

   if(g_ws != NULL && g_ws.isConnected())
      g_ws.send(NT5BuildHeartbeatJson());

   g_last_heartbeat_tick = now;
  }

//+------------------------------------------------------------------+
void NT5ClearActiveBarSubscriptions()
  {
   for(int i = 0; i < ArraySize(g_bars); i++)
     {
      if(!g_bars[i].active)
         continue;

      g_bars[i].active = false;
      if(InpDebug)
         PrintFormat(
            "[NT5Feed] WS disconnect: cleared bar sub %s:%s",
            g_bars[i].symbol,
            g_bars[i].timeframe
         );
     }
  }

//+------------------------------------------------------------------+
void NT5DestroyWebSocket()
  {
   if(g_ws == NULL)
      return;

   // WebSocketClient::close() only frees handles while isConnected(); delete always
   // runs ~WebSocketClient which deletes socket/connection (SocketClose in transport dtor).
   g_ws.close();
   delete g_ws;
   g_ws = NULL;
   NT5ClearActiveBarSubscriptions();
  }

//+------------------------------------------------------------------+
bool NT5EnsureWebSocketOpen()
  {
   if(g_ws != NULL && g_ws.isConnected())
      return true;

   NT5DestroyWebSocket();

   g_ws = new CNT5FeedWebSocket(InpWsUrl, InpDebug);
   ResetLastError();
   if(g_ws.open())
      return true;

   const int err = GetLastError();
   PrintFormat(
      "[NT5Feed] WS open failed url=%s err=%d — check allowed URLs in terminal options",
      InpWsUrl,
      err
   );
   NT5DestroyWebSocket();
   return false;
  }

//+------------------------------------------------------------------+
void CNT5FeedWebSocket::onConnected()
  {
   if(InpDebug)
      Print(" > Connected ", InpWsUrl);

   NT5SendHello();
  }

//+------------------------------------------------------------------+
void CNT5FeedWebSocket::onDisconnect()
  {
   if(InpDebug)
      Print(" > Disconnected ", InpWsUrl);

   NT5ClearActiveBarSubscriptions();
  }

//+------------------------------------------------------------------+
void CNT5FeedWebSocket::onMessage(IWebSocketMessage *msg)
  {
   if(msg == NULL)
      return;

   NT5HandleWireMessage(msg.getString());
   delete msg;
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   g_session = StringFormat("nt5-%I64d", (long)GetTickCount64());
   g_last_heartbeat_tick = 0;

   string initial[];
   NT5SplitCsvSymbols(InpSymbols, initial);
   for(int i = 0; i < ArraySize(initial); i++)
     {
      bool changed = false;
      NT5ActivateSymbol(initial[i], changed);
     }

   NT5ActivateInitialBarSpecs();

   PrintFormat("[NT5Feed] starting session=%s url=%s", g_session, InpWsUrl);

   for(; !IsStopped(); )
     {
      if(!NT5EnsureWebSocketOpen())
        {
         Sleep(1000);
         continue;
        }

      g_ws.checkMessages(false);
      NT5ExportAllTicks();
      NT5PollAllBars();
      NT5MaybeSendHeartbeat();
      Sleep(InpSleepMs);
     }

   NT5DestroyWebSocket();

   Print("[NT5Feed] stopped");
  }

//+------------------------------------------------------------------+
