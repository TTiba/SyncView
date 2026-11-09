#!/bin/zsh
# Compila o SyncView e monta SyncView.app (assinado com certificado local fixo).
# Uso: ./build-app.sh [--install]   (--install copia para /Applications)
set -euo pipefail
cd "$(dirname "$0")"
setopt pipefail

swift build -c release
# ".noindex" impede o Spotlight de listar esta cópia de build.
APP=build.noindex/SyncView.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SyncView "$APP/Contents/MacOS/SyncView"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.syncview.mac</string>
  <key>CFBundleName</key><string>SyncView</string>
  <key>CFBundleDisplayName</key><string>SyncView</string>
  <key>CFBundleExecutable</key><string>SyncView</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Assina com o certificado local fixo (ver setup-signing.sh): as permissões
# do macOS continuam valendo depois de recompilar.
./setup-signing.sh
KC="$HOME/Library/Keychains/syncview-signing.keychain-db"
security unlock-keychain -p syncview-local "$KC"
IDENTITY=$(security find-identity -p codesigning "$KC" | awk '/SyncView Local Signing/ {print $2; exit}')
xattr -cr "$APP"   # o codesign recusa atributos estendidos (FinderInfo etc.)
codesign --force --sign "$IDENTITY" --keychain "$KC" --identifier com.syncview.mac "$APP"
echo "OK: $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x SyncView 2>/dev/null || true
  rm -rf /Applications/SyncView.app
  cp -R "$APP" /Applications/
  echo "Instalado em /Applications/SyncView.app"
fi
