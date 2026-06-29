"""Normalize MetaTrader5 history API arguments for RPyC clients.

The official Python API accepts ``datetime`` or Unix seconds for interval
endpoints. Over RPyC, timezone-aware ``datetime`` objects often arrive with
``tzinfo`` that the terminal-side ``MetaTrader5`` module rejects
(``last_error=(-2, 'Invalid arguments')``).

This module coerces interval endpoints to Unix seconds before calling MT5.
"""
from __future__ import annotations

import datetime as dt
from typing import Any


def coerce_unix_timestamp(value: Any, *, label: str = "timestamp") -> int:
    """Coerce MT5 history interval endpoints to Unix seconds."""
    if isinstance(value, bool):
        raise TypeError(f"{label}: bool is not a timestamp")
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, dt.datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=dt.timezone.utc)
        return int(value.timestamp())
    ts_fn = getattr(value, "timestamp", None)
    if callable(ts_fn):
        return int(ts_fn())
    raise TypeError(f"{label}: unsupported type {type(value).__name__}")


def _is_ticket_or_position_query(args: tuple[Any, ...], kwargs: dict[str, Any]) -> bool:
    if kwargs.get("ticket") is not None and len(args) == 0:
        return True
    if kwargs.get("position") is not None and len(args) == 0:
        return True
    if len(args) == 1 and isinstance(args[0], int) and not kwargs:
        return True
    return False


def normalize_history_interval_args(
    *args: Any,
    **kwargs: Any,
) -> tuple[tuple[Any, ...], dict[str, Any]]:
    """
    Normalize ``history_*_{total,get}`` interval calls to Unix seconds.

    Ticket / position overloads are returned unchanged so callers can apply
    broker-specific fallbacks.
    """
    kw = dict(kwargs)
    if _is_ticket_or_position_query(args, kw):
        return args, kw

    if len(args) >= 2:
        date_from = coerce_unix_timestamp(args[0], label="date_from")
        date_to = coerce_unix_timestamp(args[1], label="date_to")
        return (date_from, date_to) + args[2:], kw

    return args, kw


def coerce_tick_time(value: Any) -> Any:
    """Coerce tick/rate ``date_from`` / ``date_to`` when sent as datetime."""
    if isinstance(value, (int, float, str)) or value is None:
        return value
    try:
        return coerce_unix_timestamp(value, label="tick_time")
    except TypeError:
        return value
