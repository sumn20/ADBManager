#!/usr/bin/env bash
# 构建 release 二进制并组装成可双击运行的 ADBManager.app
set -e

cd "$(dirname "$0")"

# —— 版本号：从 VERSION 文件读取（真相源）——
# 升级步骤：改 VERSION → bash build.sh → git tag v<版本>
# CFBundleShortVersionString = 用户可见版本号（如 1.2.0）
# CFBundleVersion            = 构建号（版本号-git 短哈希，如 1.2.0-a1b2c3d；无 git 环境退化为版本号本身）
if [ ! -f VERSION ]; then
    echo "错误：缺少 VERSION 文件（版本号真相源）" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < VERSION)"
if [ -z "$VERSION" ]; then
    echo "错误：VERSION 文件为空" >&2
    exit 1
fi

# —— 自动递增 patch 版本 ——
# 每次 build.sh 执行都把 VERSION 的最后一段 +1（x.y.z → x.y.(z+1)），并写回文件。
# 语义：patch 号 = 构建号；major/minor 仍手动维护。
# 跳过自增：设置环境变量 SKIP_VERSION_BUMP=1（用于打 tag 前不希望再动版本号的场景）
if [ "${SKIP_VERSION_BUMP:-0}" != "1" ]; then
    if [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        MAJOR="${BASH_REMATCH[1]}"
        MINOR="${BASH_REMATCH[2]}"
        PATCH="${BASH_REMATCH[3]}"
        NEW_PATCH=$((PATCH + 1))
        NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"
        echo "$NEW_VERSION" > VERSION
        echo "==> 版本自增：$VERSION → $NEW_VERSION"
        VERSION="$NEW_VERSION"
    else
        echo "==> 版本号 '$VERSION' 不匹配 x.y.z 格式，跳过自增"
    fi
fi

if git rev-parse --short HEAD >/dev/null 2>&1; then
    GIT_SHORT="$(git rev-parse --short HEAD)"
    BUILD_NO="${VERSION}-${GIT_SHORT}"
else
    BUILD_NO="$VERSION"
fi

echo "==> 版本 $VERSION（构建号 $BUILD_NO）"
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

# 注意：这里用未加引号的 heredoc 分隔符（EOF）以启用变量展开
cat > "$APP/Contents/Info.plist" <<EOF
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
    <string>${BUILD_NO}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
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
