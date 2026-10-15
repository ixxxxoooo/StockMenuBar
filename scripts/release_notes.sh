#!/bin/bash
# 从 CHANGELOG.md 提取指定版本的更新说明,输出到标准输出;找不到时输出兜底文案。
# 用法: scripts/release_notes.sh <版本号,如 1.2.0>
# @author ixxxxoooo
set -euo pipefail
VERSION="${1:?用法: scripts/release_notes.sh <版本号>}"
cd "$(dirname "$0")/.."

NOTES="$(awk -v ver="$VERSION" '
  /^## / {
    if (found) exit
    if (index($0, "[" ver "]") > 0 || index($0, " " ver " ") > 0 || $0 ~ ("^## " ver "($| )")) { found = 1; next }
  }
  found { print }
' CHANGELOG.md)"

if [ -n "$(echo "$NOTES" | tr -d '[:space:]')" ]; then
  echo "$NOTES"
else
  echo "完整变更见 [CHANGELOG](https://github.com/ixxxxoooo/StockMenuBar/blob/main/CHANGELOG.md)。"
fi
echo
echo "---"
echo "**安装**:下载 \`StockMenuBar-$VERSION-macOS.zip\`,解压后拖入「应用程序」。已安装用户可在 偏好设置 → 软件更新 中一键更新。"
echo "**校验**:\`shasum -a 256 -c StockMenuBar-$VERSION-macOS.zip.sha256\`"
