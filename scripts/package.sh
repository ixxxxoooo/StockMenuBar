#!/bin/bash
# 打包发布产物:通用二进制(arm64 + x86_64)的 StockMenuBar.app → zip + sha256
# 用法: scripts/package.sh <版本号,如 1.2.0> [构建号,默认 1]
# 产物: dist/StockMenuBar-<版本>-macOS.zip 与 dist/StockMenuBar-<版本>-macOS.zip.sha256
# CI(release.yml)与本地共用同一份脚本,保证产物一致。
# @author ixxxxoooo
set -euo pipefail

VERSION="${1:?用法: scripts/package.sh <版本号> [构建号]}"
BUILD="${2:-1}"
cd "$(dirname "$0")/.."

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "版本号格式不正确: $VERSION (应为 1.2.3 或 1.2.3-beta.1)" >&2
  exit 1
fi

echo "==> 生成工程"
xcodegen generate

echo "==> 构建 Release ($VERSION, build $BUILD)"
rm -rf build/release dist
xcodebuild build \
  -scheme StockMenuBar \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO | tail -n 3

APP="build/release/Build/Products/Release/StockMenuBar.app"
[ -d "$APP" ] || { echo "未找到构建产物: $APP" >&2; exit 1; }

echo "==> ad-hoc 签名(无开发者证书时保证包完整性可校验)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUILT" = "$VERSION" ] || { echo "产物版本 $BUILT 与期望 $VERSION 不一致" >&2; exit 1; }
echo "架构: $(lipo -archs "$APP/Contents/MacOS/StockMenuBar")"

echo "==> 打包"
mkdir -p dist
ZIP="StockMenuBar-$VERSION-macOS.zip"
ditto -c -k --keepParent "$APP" "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")
ls -lh dist
cat "dist/$ZIP.sha256"
