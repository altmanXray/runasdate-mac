#!/bin/zsh
# 重新构建并打包成 DMG（含“应用程序”快捷方式，拖入即可安装）和 ZIP
set -euo pipefail
cd "$(dirname "$0")"

zsh build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/MacRunAsDate.app/Contents/Info.plist)
DIST=dist
STAGE=build/dmg
rm -rf "$DIST" "$STAGE"
mkdir -p "$DIST" "$STAGE"

echo "==> 打包 DMG"
cp -R build/MacRunAsDate.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/使用说明.md"
hdiutil create -volname "MacRunAsDate" -srcfolder "$STAGE" -ov -format UDZO \
  "$DIST/MacRunAsDate-$VERSION.dmg" >/dev/null

echo "==> 打包 ZIP"
ditto -c -k --keepParent build/MacRunAsDate.app "$DIST/MacRunAsDate-$VERSION.zip"

rm -rf "$STAGE"
ls -lh "$DIST"
