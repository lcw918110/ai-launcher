#!/bin/zsh
# AI终端启动器 一键安装（免 Gatekeeper 拦截）
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/lcw918110/ai-launcher/main/scripts/install-remote.sh | zsh
#
# 指定版本 / 内网镜像：
#   AI_LAUNCHER_VERSION=0.4.5 curl -fsSL .../install-remote.sh | zsh
#   AI_LAUNCHER_MIRROR=https://内网地址/releases curl -fsSL .../install-remote.sh | zsh
#
# 为什么命令行装不会有「已损坏」提示：
#   浏览器下载会给文件打 com.apple.quarantine 扩展属性，Gatekeeper 据此拦截未公证的应用。
#   curl 不经过 LaunchServices，本身不打标记；本脚本装完还会主动清一次，
#   所以装出来的 .app 双击即开，没有任何提示。
set -euo pipefail

REPO="lcw918110/ai-launcher"
APP_NAME="AI终端启动器"
VERSION="${AI_LAUNCHER_VERSION:-latest}"
RELEASES="${AI_LAUNCHER_MIRROR:-https://github.com/$REPO/releases}"

# 允许传 v0.4.5 / 0.4.5 两种写法
VERSION="${VERSION#v}"

if [[ "$VERSION" == "latest" ]]; then
  URL="$RELEASES/latest/download/ai-launcher-latest.dmg"
else
  URL="$RELEASES/download/v$VERSION/ai-launcher-$VERSION.dmg"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-launcher-install.XXXXXX")"
MNT="$TMP/mnt"
cleanup() {
  if mount | grep -q "on $MNT "; then
    hdiutil detach "$MNT" -quiet -force 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "→ 下载 $URL"
if ! curl -fL --progress-bar -o "$TMP/app.dmg" "$URL"; then
  echo "下载失败。检查网络或版本号（当前请求：$VERSION）" >&2
  exit 1
fi

echo "→ 挂载安装包"
mkdir -p "$MNT"
hdiutil attach "$TMP/app.dmg" -mountpoint "$MNT" -nobrowse -readonly -quiet

SRC="$MNT/$APP_NAME.app"
if [[ ! -d "$SRC" ]]; then
  echo "安装包里找不到 $APP_NAME.app" >&2
  exit 1
fi

# /Applications 通常对管理员可写；不可写时退到用户级目录
# AI_LAUNCHER_DEST_DIR 可指定安装位置（内网批量部署、自动化测试用）
DEST_DIR="${AI_LAUNCHER_DEST_DIR:-/Applications}"
if [[ ! -w "$DEST_DIR" ]]; then
  if [[ -n "${AI_LAUNCHER_DEST_DIR:-}" ]]; then
    mkdir -p "$DEST_DIR"
  else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
    echo "  /Applications 不可写，改装到 $DEST_DIR"
  fi
fi
DEST="$DEST_DIR/$APP_NAME.app"

# 先退掉正在运行的旧版本，否则覆盖后进程仍指向旧 inode
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "→ 退出正在运行的旧版本"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
fi

echo "→ 安装到 $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
# DMG 是只读卷，属性只能在拷出来之后清
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

if codesign --verify --deep --strict "$DEST" 2>/dev/null; then
  echo "  签名校验通过"
else
  echo "  签名校验未通过（ad-hoc 分发的正常现象，不影响使用）"
fi

INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo '未知')"
echo "→ 已安装 $APP_NAME $INSTALLED"

# AI_LAUNCHER_NO_OPEN=1 只装不启动（批量部署 / 自动化测试）
if [[ "${AI_LAUNCHER_NO_OPEN:-0}" != "1" ]]; then
  open "$DEST"
fi
echo "完成。"
