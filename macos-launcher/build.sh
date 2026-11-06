#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
set -euo pipefail
cd "$(dirname "$0")"
root="$(cd .. && pwd)"
if [[ "$(uname -m)" != arm64 ]]; then echo "当前打包目标为 Apple Silicon Mac。" >&2; exit 1; fi
./prepare-deps.sh
export PKG_CONFIG_PATH="$(pwd)/.build/ffmpeg-install/lib/pkgconfig:/opt/homebrew/opt/sdl3/lib/pkgconfig"
if [[ ! -f .build/scrcpy/build.ninja ]]; then
    .build/tools/bin/meson setup .build/scrcpy "$root" -Dcompile_server=false -Dportable=true \
        -Dusb=false -Dbuildtype=release -Dstrip=true -Dvideotoolbox=true
fi
.build/tools/bin/meson compile -C .build/scrcpy
# Assemble from an empty staging directory so removed components cannot survive.
staging="$(mktemp -d "$(pwd)/.build/package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Device Mirror.app"
resources="$app/Contents/Resources"
helpers="$app/Contents/Helpers"
frameworks="$app/Contents/Frameworks"
mkdir -p "$app/Contents/MacOS" "$resources/scrcpy" "$resources/ThirdParty/Sources" "$helpers" "$frameworks" .build/prebuilt
tar -xzf vendor/scrcpy-macos-aarch64-v5.0.1.tar.gz --strip-components=1 -C .build/prebuilt
cp .build/prebuilt/scrcpy-server "$resources/scrcpy/"
python3 prepare-adb.py "$app"
cp .build/prebuilt/scrcpy.png .build/prebuilt/disconnected.png "$resources/scrcpy/"
cp .build/scrcpy/app/scrcpy "$helpers/"
chmod u+w "$frameworks/"*.dylib 2>/dev/null || true
cp .build/ffmpeg-install/lib/libavformat.63.dylib .build/ffmpeg-install/lib/libavcodec.63.dylib \
   .build/ffmpeg-install/lib/libavutil.61.dylib .build/ffmpeg-install/lib/libswresample.7.dylib "$frameworks/"
cp /opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib "$frameworks/"
python3 bundle-libraries.py "$app"
mkdir -p "$resources/WebDriverAgent"
python3 prepare-wda.py ../third_party/WebDriverAgent "$resources/WebDriverAgent" WDA/DMControlCommands.m
cp ../LICENSE "$resources/ThirdParty/scrcpy-Apache-2.0.txt"
cp ../third_party/WebDriverAgent/LICENSE "$resources/ThirdParty/WebDriverAgent-BSD.txt"
cp /opt/homebrew/opt/sdl3/share/licenses/SDL3/LICENSE.txt "$resources/ThirdParty/SDL-zlib.txt"
cp .build/ffmpeg-src/COPYING.LGPLv2.1 "$resources/ThirdParty/FFmpeg-LGPL-2.1.txt"
cp ../NOTICE ../THIRD_PARTY.md "$resources/ThirdParty/"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos26.0 Sources/AndroidCore.swift Sources/USBMux.swift DeviceService/*.swift -o "$helpers/device-service"
for tool in "$helpers/"*; do codesign --force --sign - "$tool"; done
cp prepare-deps.sh "$resources/ThirdParty/Sources/ffmpeg-build.sh"
cp prepare-wda.py "$resources/ThirdParty/Sources/"
cp vendor/ffmpeg-n9.0.2.tar.gz "$resources/ThirdParty/Sources/"
cp .build/ffmpeg-src/config.h "$resources/ThirdParty/Sources/ffmpeg-config.h"
cp .build/prebuilt/scrcpy.png "$resources/AppIcon.png"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos26.0 Sources/*.swift -o "$app/Contents/MacOS/DeviceMirror"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Device Mirror</string>
<key>CFBundleIdentifier</key><string>com.keye3tuido.devicemirror</string>
<key>CFBundleExecutable</key><string>DeviceMirror</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.3</string>
<key>CFBundleVersion</key><string>13</string>
<key>CFBundleIconFile</key><string>AppIcon.png</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSCameraUsageDescription</key><string>采集通过 USB 连接的 iPhone 或 iPad 屏幕，用于显示设备画面。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST
for library in "$frameworks/"*.dylib; do codesign --force --sign - "$library"; done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
destination="$root/Device Mirror.app"
# Keep an active app's executable and resources intact during rebuilds.
python3 - "$destination" <<'PYTHON'
import subprocess
import sys
executable = sys.argv[1] + "/Contents/MacOS/DeviceMirror"
processes = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
if executable in (line.strip() for line in processes):
    sys.exit("请先退出仓库根目录的 Device Mirror.app，再替换构建产物。")
PYTHON
rm -rf "$destination"
mv "$app" "$destination"
echo "已生成：$destination"
du -sh "$destination"
