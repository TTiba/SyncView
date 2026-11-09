#!/bin/zsh
# Recompila o APK do tablet. Requer: brew install openjdk@21 gradle && brew install --cask android-commandlinetools
set -euo pipefail
cd "$(dirname "$0")"
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
[[ -f local.properties ]] || echo "sdk.dir=/opt/homebrew/share/android-commandlinetools" > local.properties
./gradlew assembleRelease --console=plain -q
mkdir -p ../dist
cp app/build/outputs/apk/release/app-release.apk ../dist/SyncView-tablet.apk
echo "OK: $(cd ..; pwd)/dist/SyncView-tablet.apk"
