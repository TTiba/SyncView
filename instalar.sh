#!/bin/zsh
# Instala o SyncView no Mac e no tablet.
# Uso: ./instalar.sh            (usa o APK já compilado em dist/)
#      ./instalar.sh --rebuild  (recompila o APK antes)
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 1/4 Ferramentas"
if ! command -v adb >/dev/null; then
  command -v brew >/dev/null || { echo "Instale o Homebrew primeiro: https://brew.sh"; exit 1; }
  brew install android-platform-tools
fi

echo "==> 2/4 App do Mac"
./mac/build-app.sh --install

if [[ "${1:-}" == "--rebuild" || ! -f dist/SyncView-tablet.apk ]]; then
  echo "==> Recompilando APK"
  ./android/build-apk.sh
fi

echo "==> 3/4 App do tablet"
adb start-server >/dev/null 2>&1 || true
state=$(adb get-state 2>/dev/null || true)
if [[ "$state" == "device" ]]; then
  adb install -r dist/SyncView-tablet.apk
  # Sem otimização de bateria para o app (evita o Android pausar a conexão).
  adb shell dumpsys deviceidle whitelist +com.syncview.receiver >/dev/null 2>&1 || true
  echo "APK instalado no tablet."
else
  echo "Tablet não encontrado (estado: ${state:-nenhum})."
  echo "Ative a Depuração USB, conecte o cabo, aceite o aviso no tablet e rode ./instalar.sh de novo."
fi

echo "==> 4/4 Abrindo o SyncView"
open /Applications/SyncView.app
echo "Pronto. Procure o ícone do SyncView na barra de menus."
