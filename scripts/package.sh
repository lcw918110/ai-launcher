#!/bin/zsh
# 打可分发的安装包：universal .app + DMG + zip + SHA256
#
# 用法:
#   ./scripts/package.sh              # 用 src/Info.plist 里的版本
#   ./scripts/package.sh 0.5.0        # 覆盖版本号（不改 Info.plist）
#
# 产物在 dist/：
#   AI终端启动器-<版本>.dmg   拖入「应用程序」即可，内含说明与一键安装 .command
#   AI终端启动器-<版本>.zip   给不想要 DMG 的人（scp / 内网分发）
#   SHA256SUMS.txt
#
# 签名：有 Developer ID 证书则真签名（可继续公证），否则 ad-hoc。
# 二者都不能免除「未公证」提示，但 ad-hoc 能把「已损坏」变成可放行的
# 「无法验证开发者」；真正零提示靠安装时清掉 com.apple.quarantine。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AI终端启动器"
PLIST="$ROOT/src/Info.plist"
OUT="$ROOT/dist"
STAGE="$OUT/stage"
DMGROOT="$OUT/dmgroot"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null || echo 13.0)"

CATALOG="$OUT/catalog-$VERSION"
# 每次从干净目录开始，避免残留产物互相污染（历史踩坑见 docs/08）
rm -rf "$STAGE" "$DMGROOT" "$CATALOG"
mkdir -p "$OUT" "$CATALOG" "$STAGE"

echo "== 1/6 编译 universal 二进制（arm64 + x86_64，最低 macOS $MIN_OS）=="
# zsh 默认不对变量做空格拆分，必须用数组传多文件给 lipo
ARCHS=()
for arch in arm64 x86_64; do
  swiftc -O -target "${arch}-apple-macos${MIN_OS}" \
         "$ROOT/src/Core.swift" "$ROOT/src/main.swift" \
         -o "$CATALOG/bin-$arch"
  ARCHS+=("$CATALOG/bin-$arch")
  echo "  $arch 完成"
done

APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS"
lipo -create "${ARCHS[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"
cp "$PLIST" "$APP/Contents/Info.plist"
echo "  架构: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

echo "== 2/6 签名 =="
"$ROOT/scripts/sign-app.sh" "$APP"

echo "== 3/6 组装 DMG 内容 =="
# 必须清空：残留的 Applications 是指向 /Applications 的符号链接，
# 直接 ln -s 会跟进去在真实 /Applications 里建链接（实测踩过）
rm -rf "$DMGROOT"
mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"

cat > "$DMGROOT/首次打开说明.txt" <<TXT
$APP_NAME $VERSION
未签名分发版（个人开源项目，无 Apple 开发者账号）

【最省事：命令行安装，装完直接双击打开，没有任何提示】
    curl -fsSL https://raw.githubusercontent.com/lcw918110/ai-launcher/main/scripts/install-remote.sh | bash

【手动安装：拖到「应用程序」后，在本机「终端」执行一行】
    xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app"
    然后双击打开。

【为什么会被拦】
- 提示「已损坏，应移到废纸篓」＝ 文件里的签名不完整（多见于旧版本），
  把 .app 拖进废纸篓，换本 DMG 重新安装。
- 提示「无法验证开发者」＝ 签名有效但没有 Apple 公证。这是预期行为。
  macOS 15 起右键「打开」不再能绕过，需去
  「系统设置 → 隐私与安全性」页面底部点「仍要打开」。

本应用不联网请求任何服务，只在本机调用 ssh / rsync / scp 并写终端脚本，
源码与构建脚本都在仓库里，可自行编译复核。
TXT

cat > "$DMGROOT/安装到应用程序文件夹.command" <<'CMD'
#!/bin/zsh
# 双击运行：把同目录的 .app 装进 /Applications 并清除隔离标记
set -e
cd "$(dirname "$0")"
APP_NAME="AI终端启动器"
SRC="$PWD/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

if [[ ! -d "$SRC" ]]; then
  echo "找不到 $SRC，请确认本脚本与 .app 在同一目录" >&2
  read -r "?按回车退出"; exit 1
fi

echo "安装到 $DEST ..."
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
# 关键一步：拷出只读 DMG 后再清，DMG 里改不了扩展属性
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --deep --strict "$DEST" 2>/dev/null \
  && echo "签名校验通过" || echo "签名校验未通过（ad-hoc 分发的正常现象，不影响使用）"
echo "完成，正在打开…"
open "$DEST"
CMD
chmod +x "$DMGROOT/安装到应用程序文件夹.command"

# Finder 里打开 DMG 时的窗口布局（可选，失败不影响产物）
if command -v osascript >/dev/null 2>&1; then
  :
fi

echo "== 4/6 生成 DMG =="
DMG="$OUT/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME $VERSION" \
               -srcfolder "$DMGROOT" \
               -ov -format UDZO -quiet "$DMG"
echo "  $(du -h "$DMG" | awk '{print $1}')  $DMG"

# 有 Developer ID 时给 DMG 一并签名（公证的对象是 DMG，签了才能 stapler staple）
DEV_ID="${DEVELOPER_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
if [[ -n "$DEV_ID" ]]; then
  codesign --force --timestamp --sign "$DEV_ID" "$DMG"
  echo "  DMG 已用 Developer ID 签名（可继续 notarytool 公证）"
else
  echo "  DMG 未签名（无 Developer ID 证书，分发给他人需走 install-remote.sh 或清 quarantine）"
fi

echo "== 5/6 生成 zip（内网/scp 分发用）=="
ZIP="$OUT/$APP_NAME-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "  $(du -h "$ZIP" | awk '{print $1}')  $ZIP"

echo "== 6/6 校验和 =="
( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt )
cat "$OUT/SHA256SUMS.txt"

rm -rf "$STAGE" "$DMGROOT" "$CATALOG"
echo
echo "完成。产物目录: $OUT"
