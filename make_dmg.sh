#!/bin/bash
# Установщик .dmg: окно с приложением и ярлыком «Программы» — пользователь просто перетаскивает.
# Запуск: ./make_dmg.sh   (для Apple Silicon + Intel: UNIVERSAL=1 ./make_dmg.sh)
set -euo pipefail
cd "$(dirname "$0")"

./build_app.sh

APP="build/Dynamic Island.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/DynamicIsland-${VERSION}.dmg"
STAGE="build/dmg"

echo "▸ Установщик DMG…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Dynamic Island" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ Готово: $DMG"
