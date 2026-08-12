#!/command/with-contenv bash
# s6 oneshot: prepare and validate WINEPREFIX before CMD (install MT5 / lifecycle).
#
# Data flow: depends on window-manager; runs once in stage2; entrypoint assumes COMPLETED.
# Input from container env via with-contenv. Limitations: does not install MT5, deploy MQL5,
# configure NT5, bootstrap Python, or start bridge/lifecycle.
set -Eeuo pipefail

readonly LOG_PREFIX="[WINE-BOOTSTRAP]"

log() {
    echo "${LOG_PREFIX} $*"
}

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEARCH="${WINEARCH:-win64}"
export DISPLAY="${DISPLAY:-:99}"
export WINEDEBUG="${WINEDEBUG:--all}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"

RESET_WINEPREFIX="${RESET_WINEPREFIX:-0}"
BOOTSTRAP_TIMEOUT_SECONDS="${BOOTSTRAP_TIMEOUT_SECONDS:-420}"
MONO_URL="${MONO_URL:-https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi}"
WINE_BOOTSTRAP_DISPLAY_TIMEOUT_SECONDS="${WINE_BOOTSTRAP_DISPLAY_TIMEOUT_SECONDS:-30}"
WINE_BOOTSTRAP_WINDOW_MANAGER_TIMEOUT_SECONDS="${WINE_BOOTSTRAP_WINDOW_MANAGER_TIMEOUT_SECONDS:-30}"

run_wine_nonfatal() {
    local label="$1"
    shift

    log "$label"

    set +e
    timeout "${BOOTSTRAP_TIMEOUT_SECONDS}s" "$@"
    local status=$?
    set -e

    log "$label retornou código: $status"

    if [ "$status" -eq 124 ]; then
        log "AVISO: comando atingiu timeout, mas não vamos abortar imediatamente."
    elif [ "$status" -ne 0 ]; then
        log "AVISO: comando retornou erro, mas não vamos abortar imediatamente."
    fi

    log "Processos Wine após: $label"
    ps -ef | grep -E "wine|wineserver|wineboot|winedevice|rundll32" | grep -v grep || true

    log "kernel32.dll encontrados após: $label"
    find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
}

wait_for_wine_bootstrap() {
    log "Aguardando estabilização dos processos iniciais do Wine..."

    for i in $(seq 1 "$BOOTSTRAP_TIMEOUT_SECONDS"); do
        HAS_64=0
        HAS_32=0
        HAS_BOOT_PROCS=0

        [ -f "$WINEPREFIX/drive_c/windows/system32/kernel32.dll" ] && HAS_64=1
        [ -f "$WINEPREFIX/drive_c/windows/syswow64/kernel32.dll" ] && HAS_32=1

        if pgrep -f "wineboot.exe|winedevice.exe|rundll32.exe setupapi" >/dev/null; then
            HAS_BOOT_PROCS=1
        fi

        if [ "$HAS_64" = "1" ] && [ "$HAS_32" = "1" ] && [ "$HAS_BOOT_PROCS" = "0" ]; then
            log "Bootstrap do Wine parece concluído."
            return 0
        fi

        if [ $((i % 10)) -eq 0 ]; then
            log "Aguardando Wine... ${i}/${BOOTSTRAP_TIMEOUT_SECONDS}s | kernel32_64=$HAS_64 kernel32_32=$HAS_32 boot_procs=$HAS_BOOT_PROCS"
            ps -ef | grep -E "wineboot|winedevice|rundll32|wineserver" | grep -v grep || true
            find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
        fi

        sleep 1
    done

    log "AVISO: Wine não atingiu estado totalmente estável dentro do tempo esperado."
    return 1
}

log "Wine: $(wine --version 2>/dev/null || true)"
log "WINEPREFIX=${WINEPREFIX}"
log "WINEARCH=${WINEARCH}"
log "DISPLAY=${DISPLAY}"
log "BOOTSTRAP_TIMEOUT_SECONDS=${BOOTSTRAP_TIMEOUT_SECONDS}"

mkdir -p "$WINEPREFIX"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

if [ "$RESET_WINEPREFIX" = "1" ]; then
    log "reset_wineprefix=1 clearing_prefix path=${WINEPREFIX}"
    find "$WINEPREFIX" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
else
    log "reset_wineprefix=0 preserving_prefix"
fi

log "state=WAITING_DISPLAY display=${DISPLAY}"
display_ready=0
for _attempt in $(seq 1 "$WINE_BOOTSTRAP_DISPLAY_TIMEOUT_SECONDS"); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        display_ready=1
        break
    fi
    sleep 1
done

if [ "$display_ready" -ne 1 ]; then
    log "state=FAILED reason=display_not_ready"
    exit 1
fi
log "state=DISPLAY_READY"

log "state=WAITING_WINDOW_MANAGER"
wm_ready=0
for _attempt in $(seq 1 "$WINE_BOOTSTRAP_WINDOW_MANAGER_TIMEOUT_SECONDS"); do
    if pgrep -x openbox >/dev/null 2>&1; then
        wm_ready=1
        break
    fi
    sleep 1
done

if [ "$wm_ready" -ne 1 ]; then
    log "state=FAILED reason=window_manager_not_ready"
    exit 1
fi
log "state=WINDOW_MANAGER_READY"

if [ ! -e "$WINEPREFIX/drive_c/windows/mono" ]; then
    log "Wine Mono não encontrado. Baixando Wine Mono..."
    curl -fL --retry 3 -o /tmp/wine-mono.msi "$MONO_URL"

    run_wine_nonfatal \
        "Instalando Wine Mono para disparar bootstrap do prefixo..." \
        env WINEDLLOVERRIDES=mscoree=d wine msiexec /i /tmp/wine-mono.msi /qn

    log "Aguardando wineserver após Mono..."
    timeout "${BOOTSTRAP_TIMEOUT_SECONDS}s" wineserver -w || true

    rm -f /tmp/wine-mono.msi
else
    log "Wine Mono já instalado."
fi

log "Configurando Wine para Windows 11, seguindo o setup oficial da MetaTrader..."
set +e
winecfg -v=win11
WINECFG_STATUS=$?
set -e

log "winecfg win11 retornou código: $WINECFG_STATUS"

log "Aguardando wineserver após winecfg win11..."
timeout "${BOOTSTRAP_TIMEOUT_SECONDS}s" wineserver -w || true

wait_for_wine_bootstrap || true

log "Estado final dos processos Wine:"
ps -ef | grep -E "wine|wineserver|wineboot|winedevice|rundll32" | grep -v grep || true

log "Arquivos kernel32 encontrados:"
find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true

WINE_KERNEL32_64="$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
WINE_KERNEL32_32="$WINEPREFIX/drive_c/windows/syswow64/kernel32.dll"

log "Validando kernel32.dll 64-bit e 32-bit..."
if [ ! -f "$WINE_KERNEL32_64" ]; then
    log "ERRO: kernel32.dll 64-bit não encontrado em $WINE_KERNEL32_64"
    find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
    exit 1
fi

if [ ! -f "$WINE_KERNEL32_32" ]; then
    log "ERRO: kernel32.dll 32-bit não encontrado em $WINE_KERNEL32_32"
    find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
    exit 1
fi

log "kernel32.dll 64-bit encontrado:"
ls -la "$WINE_KERNEL32_64"

log "kernel32.dll 32-bit encontrado:"
ls -la "$WINE_KERNEL32_32"

log "Validando execução básica do Wine..."
timeout 60s wine cmd /c ver

log "Validando comando simples no Wine..."
timeout 60s wine cmd /c echo Wine bootstrap OK

log "state=COMPLETED"
exit 0
