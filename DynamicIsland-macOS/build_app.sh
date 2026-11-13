#!/bin/bash
# Сборка Dynamic Island.app (нужны Xcode или Command Line Tools: xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Dynamic Island.app"

echo "▸ Компиляция (release)…"
# UNIVERSAL=1 ./build_app.sh — собрать для Apple Silicon и Intel сразу
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/DynamicIsland"

echo "▸ Сборка бандла…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DynamicIsland"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ MediaRemote-адаптер («Сейчас играет» на macOS 15.4+)…"
mkdir -p "$APP/Contents/Frameworks"
clang -dynamiclib -fobjc-arc -O2 \
    -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
    -framework Foundation \
    -install_name @rpath/MediaRemoteAdapter.dylib \
    -o "$APP/Contents/Frameworks/MediaRemoteAdapter.dylib" \
    Adapter/MediaRemoteAdapter.m
cp Adapter/mediaremote-adapter.pl "$APP/Contents/Resources/mediaremote-adapter.pl"
codesign --force --sign - "$APP/Contents/Frameworks/MediaRemoteAdapter.dylib"

if [ -f Resources/AppIcon.png ]; then
    echo "▸ Иконка…"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▸ Подпись (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Готово: $APP"
echo "  Запуск:   open \"$APP\""
echo "  Установка: cp -R \"$APP\" /Applications/"
