"""RPyC MT5 bridge v0.8 — staging copy for manual deploy.

Changes vs v0.7
---------------
* Normalize ``history_*`` interval endpoints: ``datetime`` → Unix seconds before
  calling MT5 (fixes RPyC ``Invalid arguments`` on tz-aware datetimes).
* Normalize ``copy_ticks_*`` ``date_from`` / ``date_to`` the same way.
* ``history_deals_get(ticket=…)``: log ``last_error`` and retry single positional
  ticket when the named overload fails (broker-dependent).

Deploy: copy to production path (e.g. ``E:\\dev\\TradingUltimate\\mt5_bridge.py``)
and restart the bridge process. Bind port: ``RPYC_PORT`` env (default ``18812``);
Docker XP uses ``18813``. Adapter clients use ``MT5_PORT`` on the host side.
"""
from __future__ import annotations

import rpyc
import MetaTrader5 as mt5

from history_args import (
    coerce_tick_time,
    normalize_history_interval_args,
)


def _result_count(result) -> int | None:
    if result is None:
        return None
    try:
        return len(result)
    except TypeError:
        return None


class MT5Service(rpyc.Service):

    exposed_getmodule = None

    def _is_mt5_ready(self) -> bool:
        try:
            info = mt5.terminal_info()
            return info is not None and getattr(info, "connected", False)
        except Exception:
            return False

    def _call_history(
        self,
        fn_name: str,
        *args,
        **kwargs,
    ):
        raw_args, raw_kwargs = args, kwargs
        args, kwargs = normalize_history_interval_args(*args, **kwargs)

        if fn_name == "history_deals_get" and kwargs.get("ticket") is not None and not args:
            ticket = int(kwargs["ticket"])
            print(
                f"[DEBUG] {fn_name} | ticket query ticket={ticket} "
                f"(raw kwargs={raw_kwargs})"
            )
            result = mt5.history_deals_get(ticket=ticket)
            if result is not None:
                print(f"[DEBUG] {fn_name} | return count={_result_count(result)}")
                return result
            err = mt5.last_error()
            print(
                f"[WARN] {fn_name} | ticket={ticket} named overload failed "
                f"err={err}; retry positional"
            )
            result = mt5.history_deals_get(ticket)
            print(
                f"[DEBUG] {fn_name} | positional ticket return "
                f"count={_result_count(result)} err={mt5.last_error()}"
            )
            return result

        if args != raw_args:
            print(
                f"[DEBUG] {fn_name} | normalized args {raw_args} -> {args} "
                f"kwargs={kwargs}"
            )
        else:
            print(f"[DEBUG] {fn_name} | args={args} kwargs={kwargs}")

        fn = getattr(mt5, fn_name)
        result = fn(*args, **kwargs)
        if fn_name.endswith("_get"):
            print(f"[DEBUG] {fn_name} | return count={_result_count(result)}")
        else:
            print(f"[DEBUG] {fn_name} | return={result}")
        return result

    def exposed_initialize(self, *args, **kwargs):
        print(f"[DEBUG] initialize | args={args} kwargs={kwargs}")
        if self._is_mt5_ready():
            print("[DEBUG] initialize | already connected, returning True")
            return True
        result = mt5.initialize(*args, **kwargs)
        print(f"[DEBUG] initialize | return={result}")
        return result

    def exposed_login(self, login, password, server):
        print(f"[DEBUG] login | login={login} password=*** server={server}")
        result = mt5.login(login, password, server)
        print(f"[DEBUG] login | return={result}")
        return result

    def exposed_last_error(self):
        print("[DEBUG] last_error | (no params)")
        result = mt5.last_error()
        print(f"[DEBUG] last_error | return={result}")
        return result

    def exposed_version(self):
        print("[DEBUG] version | (no params)")
        result = mt5.version()
        print(f"[DEBUG] version | return={result}")
        return result

    def exposed_terminal_info(self):
        print("[DEBUG] terminal_info | (no params)")
        result = mt5.terminal_info()
        print(f"[DEBUG] terminal_info | return={result}")
        return result

    def exposed_account_info(self):
        print("[DEBUG] account_info | (no params)")
        result = mt5.account_info()
        print(f"[DEBUG] account_info | return={result}")
        return result

    def exposed_symbols_get(self, *args, **kwargs):
        print(f"[DEBUG] symbols_get | args={args} kwargs={kwargs}")
        result = mt5.symbols_get(*args, **kwargs)
        print(f"[DEBUG] symbols_get | return count={_result_count(result)}")
        return result

    def exposed_symbol_info(self, symbol):
        print(f"[DEBUG] symbol_info | symbol={symbol}")
        result = mt5.symbol_info(symbol)
        print(f"[DEBUG] symbol_info | return={result}")
        return result

    def exposed_symbol_info_tick(self, symbol):
        print(f"[DEBUG] symbol_info_tick | symbol={symbol}")
        result = mt5.symbol_info_tick(symbol)
        print(f"[DEBUG] symbol_info_tick | return={result}")
        return result

    def exposed_symbol_select(self, symbol, enable):
        print(f"[DEBUG] symbol_select | symbol={symbol} enable={enable}")
        result = mt5.symbol_select(symbol, enable)
        print(f"[DEBUG] symbol_select | return={result}")
        return result

    def exposed_copy_rates_from_pos(self, symbol, timeframe, start_pos, count):
        print(
            f"[DEBUG] copy_rates_from_pos | symbol={symbol} timeframe={timeframe} "
            f"start_pos={start_pos} count={count}"
        )
        result = mt5.copy_rates_from_pos(symbol, timeframe, start_pos, count)
        print(f"[DEBUG] copy_rates_from_pos | return count={_result_count(result)}")
        return result

    def exposed_copy_ticks_range(self, symbol, date_from, date_to, flags):
        norm_from = coerce_tick_time(date_from)
        norm_to = coerce_tick_time(date_to)
        if (norm_from, norm_to) != (date_from, date_to):
            print(
                f"[DEBUG] copy_ticks_range | normalized times "
                f"{date_from!r},{date_to!r} -> {norm_from!r},{norm_to!r}"
            )
        print(
            f"[DEBUG] copy_ticks_range | symbol={symbol} date_from={norm_from} "
            f"date_to={norm_to} flags={flags}"
        )
        result = mt5.copy_ticks_range(symbol, norm_from, norm_to, flags)
        print(f"[DEBUG] copy_ticks_range | return count={_result_count(result)}")
        return result

    def exposed_copy_ticks_from(self, symbol, date_from, count, flags):
        norm_from = coerce_tick_time(date_from)
        if norm_from != date_from:
            print(
                f"[DEBUG] copy_ticks_from | normalized date_from "
                f"{date_from!r} -> {norm_from!r}"
            )
        print(
            f"[DEBUG] copy_ticks_from | symbol={symbol} date_from={norm_from} "
            f"count={count} flags={flags}"
        )
        result = mt5.copy_ticks_from(symbol, norm_from, count, flags)
        print(f"[DEBUG] copy_ticks_from | return count={_result_count(result)}")
        return result

    def exposed_order_send(self, request):
        print(f"[DEBUG] order_send | request={dict(request)}")
        result = mt5.order_send(dict(request))
        print(f"[DEBUG] order_send | return={result}")
        return result

    def exposed_positions_get(self, *args, **kwargs):
        print(f"[DEBUG] positions_get | args={args} kwargs={kwargs}")
        result = mt5.positions_get(*args, **kwargs)
        print(f"[DEBUG] positions_get | return count={_result_count(result)}")
        return result

    def exposed_orders_get(self, *args, **kwargs):
        print(f"[DEBUG] orders_get | args={args} kwargs={kwargs}")
        result = mt5.orders_get(*args, **kwargs)
        print(f"[DEBUG] orders_get | return count={_result_count(result)}")
        return result

    def exposed_history_orders_total(self, *args, **kwargs):
        return self._call_history("history_orders_total", *args, **kwargs)

    def exposed_history_orders_get(self, *args, **kwargs):
        return self._call_history("history_orders_get", *args, **kwargs)

    def exposed_history_deals_total(self, *args, **kwargs):
        return self._call_history("history_deals_total", *args, **kwargs)

    def exposed_history_deals_get(self, *args, **kwargs):
        return self._call_history("history_deals_get", *args, **kwargs)

    def exposed_shutdown(self):
        print("[DEBUG] shutdown | no-op (shared gateway — MT5 stays alive)")
        return True

    def exposed_get_constant(self, name):
        print(f"[DEBUG] get_constant | name={name}")
        result = getattr(mt5, name)
        print(f"[DEBUG] get_constant | return={result}")
        return result


if __name__ == "__main__":
    import os

    from rpyc.utils.server import ThreadedServer

    rpyc_port = int(os.environ.get("RPYC_PORT", "18812"))

    if not mt5.initialize():
        print("initialize() failed, error code =", mt5.last_error())
        quit()

    print(f"MT5 initialized successfully. Starting RPyC server on port {rpyc_port}...")
    print("Bridge V 0.8")
    server = ThreadedServer(
        MT5Service,
        port=rpyc_port,
        protocol_config={"allow_public_attrs": True, "allow_all_attrs": True},
    )
    try:
        server.start()
    finally:
        print("[INFO] Bridge stopping — calling mt5.shutdown()")
        mt5.shutdown()
