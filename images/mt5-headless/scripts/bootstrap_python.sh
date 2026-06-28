#!/bin/bash
# Install Windows Python under Wine once per Wine prefix (persisted in volume).
set -Eeuo pipefail

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"

PYTHON_VERSION="${PYTHON_VERSION:-3.11.9}"
PYTHON_INSTALLER_URL="${PYTHON_INSTALLER_URL:-https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-amd64.exe}"
PYTHON_INSTALLER="/tmp/python-${PYTHON_VERSION}-amd64.exe"

wine_python_ok() {
    wine python -c "import MetaTrader5, rpyc, numpy; assert numpy.__version__.startswith('1.')" >/dev/null 2>&1
}

if wine_python_ok; then
    echo "BOOTSTRAP_PYTHON: Wine Python + MetaTrader5 + rpyc + numpy<2 já presentes."
    wine python --version || true
    exit 0
fi

if ! wine python --version >/dev/null 2>&1; then
    echo "BOOTSTRAP_PYTHON: instalando Python ${PYTHON_VERSION} no Wine prefix..."
    curl -fL --retry 3 -o "$PYTHON_INSTALLER" "$PYTHON_INSTALLER_URL"
    wine "$PYTHON_INSTALLER" /quiet InstallAllUsers=0 PrependPath=1 Include_pip=1
    rm -f "$PYTHON_INSTALLER"
    wineserver -w || true
fi

if ! wine python --version >/dev/null 2>&1; then
    echo "ERRO: Wine Python não encontrado após instalação."
    exit 1
fi

echo "BOOTSTRAP_PYTHON: instalando pacotes pip (numpy<2, MetaTrader5, rpyc)..."
wine python -m pip install --upgrade pip
wine python -m pip install "numpy<2" MetaTrader5 rpyc

if ! wine_python_ok; then
    echo "ERRO: bootstrap Python incompleto — verifique pip/Wine."
    exit 1
fi

echo "BOOTSTRAP_PYTHON: OK"
wine python --version
wine python -m pip show MetaTrader5 rpyc numpy | sed -n '1,12p'
