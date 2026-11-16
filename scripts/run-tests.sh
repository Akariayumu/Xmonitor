#!/bin/bash
# 在 macOS 上直接编译并运行测试二进制 build/XmonitorTests（不依赖 Xcode / XCTest）
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="x86_64-apple-macos14.0"
CERT_NAME="XSensei Dev"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
        SIGN_IDENTITY="$CERT_NAME"
    else
        SIGN_IDENTITY="-"
    fi
fi

mkdir -p build

echo "==> 编译 C 采集桥接层 (HardwareBridge.c)"
clang -O3 -Wall -Wextra -std=c11 \
    -target "$TARGET" \
    -c Sources/Bridge/HardwareBridge.c \
    -o build/HardwareBridge.o

SWIFT_FILES=()
while IFS= read -r file; do
    SWIFT_FILES+=("$file")
done < <(find Sources -name '*.swift' ! -name 'App.swift' | sort)

while IFS= read -r file; do
    SWIFT_FILES+=("$file")
done < <(find Tests -name '*.swift' | sort)

echo "==> 编译测试套件 build/XmonitorTests (${#SWIFT_FILES[@]} Swift files)"
swiftc -O -swift-version 5 -parse-as-library \
    -target "$TARGET" \
    -import-objc-header Sources/Bridge/HardwareBridge.h \
    "${SWIFT_FILES[@]}" \
    build/HardwareBridge.o \
    -framework AppKit \
    -framework QuartzCore \
    -framework SwiftUI \
    -framework IOKit \
    -framework CoreFoundation \
    -framework CoreWLAN \
    -framework Security \
    -framework ServiceManagement \
    -o build/XmonitorTests

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
    build/XmonitorTests

echo "==> 运行测试 build/XmonitorTests"
./build/XmonitorTests "$@"
