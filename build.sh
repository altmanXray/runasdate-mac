#!/bin/zsh
# 构建 MacRunAsDate.app（含注入库）以及测试程序
set -euo pipefail
cd "$(dirname "$0")"

OUT=build
APP="$OUT/MacRunAsDate.app"
MIN=13.0
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/tmp"

echo "==> 编译注入库 libfaketime.dylib（arm64 + x86_64）"
clang -dynamiclib -O2 -Wall -arch arm64 -arch x86_64 -mmacosx-version-min=$MIN \
  -framework CoreFoundation -o "$APP/Contents/Resources/libfaketime.dylib" src/faketime.c

echo "==> 编译界面程序"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos$MIN \
    -o "$OUT/tmp/MacRunAsDate-$arch" src/App.swift
done
lipo -create -output "$APP/Contents/MacOS/MacRunAsDate" "$OUT"/tmp/MacRunAsDate-*

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacRunAsDate</string>
  <key>CFBundleDisplayName</key><string>MacRunAsDate</string>
  <key>CFBundleIdentifier</key><string>local.macrunasdate</string>
  <key>CFBundleExecutable</key><string>MacRunAsDate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 编译测试程序 timecheck"
swiftc -O -o "$OUT/timecheck" test/timecheck.swift

echo "==> ad-hoc 签名"
codesign --force -s - "$APP/Contents/Resources/libfaketime.dylib"
codesign --force -s - "$APP"
codesign --force -s - "$OUT/timecheck"
rm -rf "$OUT/tmp"

echo "完成：$APP"
