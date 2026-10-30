#!/bin/zsh
# 给 .app 签名。用法: sign-app.sh <path-to-app> [--require-dev-id]
#
# 两种模式：
#   1. 有 Developer ID Application 证书 → 真签名（--options runtime --timestamp），可继续送公证
#   2. 没有证书 → ad-hoc 签名（--sign -）
#
# 为什么必须签：arm64 上链接器会给二进制自动打 ad-hoc 签名，签名里声明了
# "bundle 有 resources"，但手工组装的 .app 没有 _CodeSignature/CodeResources，
# 于是 codesign 报 "code has no resources but signature indicates they must be present"。
# 从网上下载（带 com.apple.quarantine）时 Gatekeeper 据此直接判「已损坏，应移到废纸篓」。
# 给 bundle 补一次签名后，这个判定消失，改成可绕过的「无法验证开发者」。
set -euo pipefail

APP="${1:-}"
REQUIRE_DEV_ID=0
for arg in "$@"; do
  [[ "$arg" == "--require-dev-id" ]] && REQUIRE_DEV_ID=1
done

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "用法: sign-app.sh <path-to-app> [--require-dev-id]" >&2
  exit 1
fi

# 允许用环境变量显式指定（CI 里从 secrets 注入），否则自动查找
IDENTITY="${DEVELOPER_ID:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi

if [[ -n "$IDENTITY" ]]; then
  echo "签名身份: $IDENTITY"
  # --deep: 一并签内嵌的可执行文件；--options runtime: 公证要求 hardened runtime
  codesign --force --deep --options runtime --timestamp \
           --sign "$IDENTITY" "$APP"
  MODE="developer-id"
else
  if [[ "$REQUIRE_DEV_ID" == "1" ]]; then
    echo "要求 Developer ID 签名，但本机没有可用证书" >&2
    exit 2
  fi
  echo "签名身份: ad-hoc（本机无 Developer ID 证书）"
  codesign --force --deep --sign - "$APP"
  MODE="adhoc"
fi

# 立刻校验，签坏了要在这里就失败，不能带病打包
if ! codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'; then
  echo "签名校验失败" >&2
  exit 3
fi

echo "签名完成（$MODE）: $(basename "$APP")"
