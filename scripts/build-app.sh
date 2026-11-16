#!/bin/bash
# 在 macOS 上编译并打包 Xmonitor：build/Xmonitor.app
# 用法：scripts/build-app.sh [--install]   --install 复制到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Xmonitor.app
VERSION=$(git describe --tags --always 2>/dev/null || echo 0.2.0)
CERT_NAME="XSensei Dev"
TARGET="x86_64-apple-macos14.0"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
        SIGN_IDENTITY="$CERT_NAME"
    else
        SIGN_IDENTITY="-"
        echo "==> 未找到证书 \"$CERT_NAME\"，使用临时签名 (-)"
    fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

if [[ -f "Resources/AppIcon-1024.png" ]]; then
    echo "==> 生成 macOS Retina 应用图标 AppIcon.icns"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sz2=$((sz * 2))
        sips -s format png -z "$sz" "$sz" "Resources/AppIcon-1024.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        sips -s format png -z "$sz2" "$sz2" "Resources/AppIcon-1024.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

echo "==> 编译 C 采集桥接层 (HardwareBridge.c)"
clang -O3 -Wall -Wextra -std=c11 \
    -target "$TARGET" \
    -c Sources/Bridge/HardwareBridge.c \
    -o build/HardwareBridge.o

SWIFT_SOURCES=()
while IFS= read -r file; do
    SWIFT_SOURCES+=("$file")
done < <(find Sources -name '*.swift' | sort)

echo "==> 编译 Swift 应用主体 (${#SWIFT_SOURCES[@]} files)"
swiftc -O -swift-version 5 -parse-as-library \
    -target "$TARGET" \
    -import-objc-header Sources/Bridge/HardwareBridge.h \
    "${SWIFT_SOURCES[@]}" \
    build/HardwareBridge.o \
    -framework AppKit \
    -framework QuartzCore \
    -framework SwiftUI \
    -framework IOKit \
    -framework CoreFoundation \
    -framework CoreWLAN \
    -framework Security \
    -framework ServiceManagement \
    -o "$APP/Contents/MacOS/Xmonitor"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.xstation.xmonitor</string>
    <key>CFBundleName</key>
    <string>Xmonitor</string>
    <key>CFBundleDisplayName</key>
    <string>Xmonitor</string>
    <key>CFBundleExecutable</key>
    <string>Xmonitor</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

ENTITLEMENTS_FILE="Resources/Xmonitor.entitlements"
if [[ "${ENABLE_SYSMOND_ENTITLEMENT:-0}" == "1" ]]; then
    ENTITLEMENTS_FILE="build/Xmonitor.sysmond.entitlements"
    cat > "$ENTITLEMENTS_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.private.sysmond.client</key>
    <true/>
</dict>
</plist>
EOF
fi

codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS_FILE" \
    "$APP"
echo "==> ${APP}（签名：${SIGN_IDENTITY}，权限文件：${ENTITLEMENTS_FILE}）"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x XSensei 2>/dev/null || true
    pkill -x Xmonitor 2>/dev/null || true
    for _ in {1..20}; do
        if ! pgrep -x XSensei >/dev/null 2>&1 && ! pgrep -x Xmonitor >/dev/null 2>&1; then
            break
        fi
        sleep 0.05
    done
    rm -rf /Applications/XSensei.app /Applications/Xmonitor.app
    cp -R "$APP" /Applications/
    touch /Applications/Xmonitor.app
    if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
        open /Applications/Xmonitor.app
        echo "==> 已安装并启动 /Applications/Xmonitor.app（旧版 XSensei.app 已清理）"
    else
        echo "==> 已更新 /Applications/Xmonitor.app（当前未登录 GUI 会话 gui/$(id -u)，下次登录桌面时即可运行）"
    fi
fi
