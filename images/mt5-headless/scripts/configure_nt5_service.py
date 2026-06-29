#!/usr/bin/env python3
"""Patch MT5 Config/services.ini and common.ini for NT5TickFeedService (UTF-16).

Runs on container start when CONFIGURE_NT5=1. WebRequest URL whitelist remains
a one-time manual step in MT5 Options (stored encrypted in common.ini).
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

WINEPREFIX = os.environ.get("WINEPREFIX", "/config/.wine")
MT5_CONFIG = Path(WINEPREFIX) / "drive_c/Program Files/MetaTrader 5/Config"
SERVICES_INI = MT5_CONFIG / "services.ini"
COMMON_INI = MT5_CONFIG / "common.ini"

WS_URL = os.environ.get("NT5_WS_URL", "ws://host.docker.internal:8765/mt5-feed")
WS_SYMBOLS = os.environ.get("NT5_WS_SYMBOLS", "BTCUSD")
SERVICE_ENABLED = os.environ.get("NT5_SERVICE_ENABLED", "0")


def _read_utf16(path: Path) -> str:
    return path.read_text(encoding="utf-16")


def _write_utf16(path: Path, text: str) -> None:
    if not text.endswith("\r\n"):
        text = text.rstrip("\n") + "\r\n"
    path.write_text(text, encoding="utf-16")


def _whitelist_hints(ws_url: str) -> None:
    parsed = urlparse(ws_url)
    host = parsed.hostname or "host.docker.internal"
    port = parsed.port or 8765
    print("CONFIGURE_NT5: whitelist manual (uma vez via VNC) — adicionar em Opções → Expert Advisors:")
    print(f"  - {host}")
    print(f"  - http://{host}:{port}")


def patch_common_ini() -> None:
    if not COMMON_INI.is_file():
        print(f"CONFIGURE_NT5: {COMMON_INI} ausente — ignorando common.ini")
        return

    lines = _read_utf16(COMMON_INI).splitlines()
    in_experts = False
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped == "[Experts]":
            in_experts = True
            out.append(line)
            continue
        if in_experts and stripped.startswith("[") and stripped != "[Experts]":
            in_experts = False
        if in_experts and line.startswith("Enabled="):
            out.append("Enabled=1")
            continue
        if in_experts and line.startswith("WebRequest="):
            out.append("WebRequest=1")
            continue
        out.append(line)

    _write_utf16(COMMON_INI, "\r\n".join(out))
    print("CONFIGURE_NT5: common.ini — Enabled=1, WebRequest=1 (flags only; URLs whitelist = manual)")


def patch_services_ini() -> None:
    MT5_CONFIG.mkdir(parents=True, exist_ok=True)

    enabled = "1" if SERVICE_ENABLED.strip() in ("1", "true", "yes") else "0"
    if not SERVICES_INI.is_file():
        text = (
            "\r\n<service>\r\n"
            "name=NT5TickFeedService\r\n"
            "path=Services\\NT5TickFeedService.ex5\r\n"
            "expertmode=0\r\n"
            f"enabled={enabled}\r\n"
            "<inputs>\r\n"
            f"InpWsUrl={WS_URL}\r\n"
            "InpSleepMs=10\r\n"
            "InpBatchSize=100\r\n"
            f"InpSymbols={WS_SYMBOLS}\r\n"
            "InpBarSpecs=\r\n"
            "InpBarPollMs=300\r\n"
            "InpHeartbeatSec=30\r\n"
            "InpDebug=true\r\n"
            "</inputs>\r\n"
            "</service>\r\n"
        )
        _write_utf16(SERVICES_INI, text)
        print(
            f"CONFIGURE_NT5: services.ini criado — InpWsUrl={WS_URL} "
            f"InpSymbols={WS_SYMBOLS} enabled={enabled}"
        )
        return

    text = _read_utf16(SERVICES_INI)
    if "NT5TickFeedService" not in text:
        text = (
            "\r\n<service>\r\n"
            "name=NT5TickFeedService\r\n"
            "path=Services\\NT5TickFeedService.ex5\r\n"
            "expertmode=0\r\n"
            f"enabled={enabled}\r\n"
            "<inputs>\r\n"
            f"InpWsUrl={WS_URL}\r\n"
            "InpSleepMs=10\r\n"
            "InpBatchSize=100\r\n"
            f"InpSymbols={WS_SYMBOLS}\r\n"
            "InpBarSpecs=\r\n"
            "InpBarPollMs=300\r\n"
            "InpHeartbeatSec=30\r\n"
            "InpDebug=true\r\n"
            "</inputs>\r\n"
            "</service>\r\n"
        )
    else:
        text = re.sub(r"InpWsUrl=.*", f"InpWsUrl={WS_URL}", text)
        text = re.sub(r"InpSymbols=.*", f"InpSymbols={WS_SYMBOLS}", text)
        text = re.sub(r"enabled=.*", f"enabled={enabled}", text, count=1)

    _write_utf16(SERVICES_INI, text)
    print(
        f"CONFIGURE_NT5: services.ini — InpWsUrl={WS_URL} "
        f"InpSymbols={WS_SYMBOLS} enabled={enabled}"
    )


def main() -> int:
    if not MT5_CONFIG.is_dir():
        print("CONFIGURE_NT5: MT5 config dir ausente — ignorando")
        return 0
    patch_common_ini()
    patch_services_ini()
    _whitelist_hints(WS_URL)
    return 0


if __name__ == "__main__":
    sys.exit(main())
