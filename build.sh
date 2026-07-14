#!/usr/bin/env bash
# 构建 release 二进制并组装成可双击运行的 ADBManager.app
set -e

cd "$(dirname "$0")"

echo "==> swift build -c release"
# --disable-sandbox 关闭 SwiftPM 自带的 sandbox-exec 包装，
# 在受限环境（如 CI/沙箱）下是必需的；普通开发机上也无害。
swift build -c release --disable-sandbox

BIN=".build/release/ADBManager"
APP="ADBManager.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ADBManager"

# 拷贝应用图标（由 gen_icon.py 生成的 ADBManager.icns）
if [ -f "ADBManager.icns" ]; then
    cp "ADBManager.icns" "$APP/Contents/Resources/ADBManager.icns"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ADBManager</string>
    <key>CFBundleDisplayName</key>
    <string>ADB 管理器</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.adbmanager</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ADBManager</string>
    <key>CFBundleIconFile</key>
    <string>ADBManager</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> 已生成 $APP，可双击运行"
