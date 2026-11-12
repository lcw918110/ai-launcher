#!/bin/zsh
# 从本仓源码编译，安装到 ~/Applications/AI终端启动器.app（安装产物，不进 Git）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 整个 src/ 一起编译：新增 .swift 文件不用回来改这里（顺序对 swiftc 无影响）
SOURCES=("$ROOT"/src/*.swift)
APP_NAME="AI终端启动器"
APP="$HOME/Applications/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
PLIST_SRC="$ROOT/src/Info.plist"
PLIST_DST="$APP/Contents/Info.plist"
# 历史名称（改名前的安装产物）：构建成功后清理，避免两个功能相同的应用并存
LEGACY_NAME="AI启动器菜单栏"
LEGACY_APP="$HOME/Applications/$LEGACY_NAME.app"

for f in "${SOURCES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "找不到源码: $f" >&2
    exit 1
  fi
done

mkdir -p "$APP/Contents/MacOS"
# 每次构建都覆盖 Info.plist，保证源码里的 plist 改动能同步到已安装的 .app
cp "$PLIST_SRC" "$PLIST_DST"

swiftc -O "${SOURCES[@]}" -o "$BIN"
chmod +x "$BIN"

# 每次覆盖二进制后旧签名即失效，必须重签。
# 无 Developer ID 证书时走 ad-hoc：不做这一步，bundle 签名与 linker 自动签名不一致，
# 从网上下载后 Gatekeeper 会报「已损坏」而不是可绕过的「无法验证开发者」。
"$ROOT/scripts/sign-app.sh" "$APP"

# 精确匹配进程名再杀，避免误杀路径里恰好包含该字样的无关进程
for name in "$APP_NAME" "$LEGACY_NAME"; do
  if pgrep -x "$name" >/dev/null 2>&1; then
    pkill -x "$name" || true
  fi
done
sleep 1

# —— 重启这一步要分环境（0.5.5）——
# 在受限沙箱里（自动化 / Agent 跑的 shell、或从沙箱应用里调用）用 open 拉起 GUI 时，
# 新实例会被 LaunchServices 当成「Sandbox」：它再去 open .command，系统直接拒掉这次文稿交接，
# 用户点「启动」只会看到「不允许 Sandbox 在终端中打开文稿」，而且程序侧拿不到任何错误码。
# 这种实例只会污染人工测试，所以宁可不自动重启，把话说清楚。
SANDBOXED=0
if [[ -n "${APP_SANDBOX_CONTAINER_ID:-}" ]]; then SANDBOXED=1; fi
if [[ -n "${CODEBUDDY_SANDBOX_BROKER_SESSION_ID:-}" ]]; then SANDBOXED=1; fi
if [[ -n "${SANDBOX_CENTER_IPC_ADDRESS:-}" ]]; then SANDBOXED=1; fi
if [[ "$SANDBOXED" == "1" ]]; then
  echo "已构建: $APP"
  echo "未自动重启：当前 shell 处在受限沙箱里，重新拉起的实例会被系统当成「Sandbox」，"
  echo "点「启动」只会弹「不允许 Sandbox 在终端中打开文稿」。请从 Finder / 普通终端手动打开。"
else
  open "$APP"
  echo "已重新编译并重启: $APP"
fi

# 旧进程已退出后，把改名前的安装产物移到废纸篓（可恢复，不直接删）
if [[ -d "$LEGACY_APP" ]] && ! pgrep -x "$LEGACY_NAME" >/dev/null 2>&1; then
  mv "$LEGACY_APP" "$HOME/.Trash/$LEGACY_NAME-$(date +%Y%m%d-%H%M%S).app"
  echo "旧版本已移入废纸篓: $LEGACY_APP"
fi
