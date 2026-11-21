#!/bin/zsh
# Packages Kiri into dist/Kiri-<version>.dmg: drag-to-Applications installer with a demo project
# and a "Read Me First" guide.
set -e
cd "${0:A:h}"
VERSION="1.1.3"
./make-app.sh

STAGE=$(mktemp -d)
cp -R Kiri.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ -d ../kiri-demo ]; then
  mkdir -p "$STAGE/Kiri Demo Project"
  cp ../kiri-demo/calculator.py ../kiri-demo/test_calculator.py ../kiri-demo/reset-demo.sh "$STAGE/Kiri Demo Project/"
fi
cp packaging/READ-ME-FIRST.txt "$STAGE/Read Me First.txt"

mkdir -p dist
DMG="dist/Kiri-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "Kiri ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
