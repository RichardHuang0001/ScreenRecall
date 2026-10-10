#!/bin/zsh
# ScreenRecall 发布打包脚本（脱敏版）
#
# 作用：构建 → 用「无身份」的 ad-hoc 签名覆盖掉 Apple Development 证书
#       （该证书 CN 里含个人邮箱，公开分发时会泄露）→ 打包 DMG → 扫描确认无个人信息。
#
# 用法：
#   zsh Tools/package-release.sh 0.6.5
#
# 约定：
#   * 本地自用 / 快速迭代：仍用带 Apple Development 签名的包（TCC 屏幕录制权限更稳定）。
#   * 只有要上传到 GitHub Release / 对外分发时，才用本脚本产出的「匿名签名」包。
#
# 说明：ad-hoc 签名没有 Authority / TeamIdentifier，因此不会带出任何个人身份；
#       代价是产物未公证（与现状一致，接收方需右键「打开」）。

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "用法: zsh Tools/package-release.sh <version>   例: zsh Tools/package-release.sh 0.6.5"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> 1/5 构建 Release（不签名）"
xcodebuild -project ScreenRecall.xcodeproj -scheme ScreenRecall -configuration Release \
  -derivedDataPath .build/release-dd -quiet \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

APP=".build/release-dd/Build/Products/Release/ScreenRecall.app"
[ -d "$APP" ] || { echo "构建产物缺失: $APP"; exit 1; }

echo "==> 2/5 剥离原签名，改用 ad-hoc 匿名签名"
codesign --remove-signature "$APP" 2>/dev/null || true
codesign --force --deep --sign - --options runtime "$APP"

echo "==> 3/5 校验签名身份（不得出现 Apple 开发者证书）"
if codesign -dvvv "$APP" 2>&1 | grep -qE 'Authority=Apple'; then
  echo "❌ 仍带 Apple 开发者身份，终止"; exit 1
fi
echo "  OK：匿名签名（Signature=adhoc，无 Apple Authority）"

echo "==> 4/5 打包 DMG"
mkdir -p dist
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/ScreenRecall.app"
ln -s /Applications "$STAGE/Applications"
OUT="dist/ScreenRecall-${VERSION}-local-preview.dmg"
rm -f "$OUT"
hdiutil create -volname "ScreenRecall ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"

echo "==> 5/5 扫描产物二进制是否残留个人邮箱 / 身份"
if grep -a -qE '@(qq|gmail|163|126|outlook|hotmail)\.(com|cn)|Apple Development:' \
     "$APP/Contents/MacOS/ScreenRecall"; then
  echo "❌ 二进制仍含个人身份信息，请勿上传"; exit 1
fi

echo "✅ 完成：$OUT   （无个人信息，可安全上传 GitHub Release）"
