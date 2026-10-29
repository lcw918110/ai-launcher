#!/bin/zsh
# 从本仓源码编译，安装到 ~/Applications/AI启动器菜单栏.app（安装产物，不进 Git）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/main.swift"
CORE="$ROOT/src/Core.swift"
APP="$HOME/Applications/AI启动器菜单栏.app"
BIN="$APP/Contents/MacOS/AI启动器菜单栏"
PLIST_SRC="$ROOT/src/Info.plist"
PLIST_DST="$APP/Contents/Info.plist"

for f in "$CORE" "$SRC"; do
  if [[ ! -f "$f" ]]; then
    echo "找不到源码: $f" >&2
    exit 1
  fi
done

mkdir -p "$APP/Contents/MacOS"
# 每次构建都覆盖 Info.plist，保证源码里的 plist 改动能同步到已安装的 .app
cp "$PLIST_SRC" "$PLIST_DST"

swiftc -O "$CORE" "$SRC" -o "$BIN"
chmod +x "$BIN"

# 精确匹配进程名再杀，避免误杀路径里恰好包含该字样的无关进程
if pgrep -x "AI启动器菜单栏" >/dev/null 2>&1; then
  pkill -x "AI启动器菜单栏" || true
  sleep 1
fi
open "$APP"
echo "已重新编译并重启: $APP"
