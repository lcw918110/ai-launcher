#!/bin/zsh
# 文档与代码一致性校验（进 CI，也可本地手动跑）
#
# 存在的原因：2026-11-02 工作区里的 docs/、README、build.sh 被整批回退到
# 10-29 的版本（净少 490 行），当时没有任何机制报警，靠人工翻文档才发现。
# 断言数是最灵敏的探针——文档写 124、代码实际 311，一跑就露。
#
# 校验五件事：
#   1. src/Info.plist 的版本 == CHANGELOG 最新条目标题
#   2. docs/05「覆盖范围（N 条断言）」的 N == test.sh 实际通过数
#   3. 除 docs/05 那处外，其余 md 不再硬写当前断言数（历史记录行与 CHANGELOG 除外）
#   4. 文档里「（当前 x.y.z）」的版本 == Info.plist
#   5. 现行规格/使用说明不得再写已下线的界面功能（旧句式黑名单）
#
# 用法：./scripts/check-docs.sh [--assert-count N]（--assert-count 可跳过跑测试）
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

fail=0
ok()  { print -r -- "  ✓ $*" }
bad() { print -r -- "  ✗ $*"; fail=1 }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" src/Info.plist 2>/dev/null)
[ -n "${VERSION:-}" ] || { print -r -- "✗ 读不到 src/Info.plist 的 CFBundleShortVersionString"; exit 1 }

print -r -- "== 文档一致性校验（版本 $VERSION）=="

# ---------- 1. 版本与 CHANGELOG 对齐 ----------
CH_VER=$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | sed -E 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
if [ "$CH_VER" = "$VERSION" ]; then
  ok "CHANGELOG 最新条目 $CH_VER 与 Info.plist 一致"
else
  bad "CHANGELOG 最新条目是 ${CH_VER:-未找到}，Info.plist 是 $VERSION（发版时两处要一起改）"
fi

# ---------- 2. 断言数：唯一权威处 vs 实测 ----------
ASSERT_COUNT="${2:-}"
if [ -z "$ASSERT_COUNT" ]; then
  print -r -- "  跑测试取实际条数…"
  TEST_OUT=$("$ROOT/scripts/test.sh" 2>&1)
  ASSERT_COUNT=$(print -r -- "$TEST_OUT" | sed -nE 's/.*测试汇总：([0-9]+) 通过.*/\1/p' | tail -1)
  if [ -z "$ASSERT_COUNT" ]; then
    bad "测试没跑出「测试汇总：N 通过」，原文末尾："
    print -r -- "$TEST_OUT" | tail -5 | sed 's/^/      /'
    ASSERT_COUNT="?"
  fi
fi

DOC_LINE=$(grep -rn "覆盖范围（" docs/ | head -1)
DOC_ASSERT=$(print -r -- "$DOC_LINE" | sed -nE 's/.*（([0-9]+) 条断言）.*/\1/p')

if [ "$DOC_ASSERT" = "$ASSERT_COUNT" ]; then
  ok "docs/05 断言数 $DOC_ASSERT 与实测一致"
else
  bad "docs/05 写的是 ${DOC_ASSERT:-未找到}，实测 $ASSERT_COUNT"
  print -r -- "      位置：$DOC_LINE"
  print -r -- "      （文档被整批回退时最常见的症状就是这个数对不上）"
fi

# ---------- 3. 断言数不得散落在别处 ----------
STRAY=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    docs/05-*"覆盖范围（"*)  continue ;;   # 唯一权威处
    CHANGELOG.md:*)          continue ;;   # 历史条目
    *":| 2026-"*)            continue ;;   # 修订记录表行
    *":- 测试 "*)            continue ;;   # 「- 测试 261 → 311」这类历史叙述
  esac
  bad "断言数硬写在别处：$line"
  STRAY=$((STRAY + 1))
done < <(grep -rnE "[0-9]+ 条(命令行)?断言" docs/ README.md 2>/dev/null)
[ "$STRAY" -eq 0 ] && ok "当前断言数只写在 docs/05 一处"

# ---------- 4. 「当前 x.y.z」与版本一致 ----------
VER_STALE=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  v=$(print -r -- "$line" | sed -nE 's/.*当前 ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  [ -z "$v" ] && continue
  if [ "$v" != "$VERSION" ]; then
    bad "文档里的「当前 $v」与 Info.plist 的 $VERSION 不一致：$line"
    VER_STALE=$((VER_STALE + 1))
  fi
done < <(grep -rn "当前 [0-9]\." docs/ README.md 2>/dev/null)
[ "$VER_STALE" -eq 0 ] && ok "文档里的「当前 x.y.z」均与版本一致"

# ---------- 5. 现行规格/使用说明不得再描述已下线的功能 ----------
# 2026-11-12 查到 docs/02 仍写着「经本机中转」按钮（0.4.6 已删）和「解析不自动改
# 源/目标路径」（0.5.0 已改）：版本号、断言数都对，功能描述却是旧的。旧句式做黑名单。
STALE_UI=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in *"| 2026-"*) continue ;; esac   # 修订记录表本来就该写旧事
  bad "现行文档仍写着已下线的功能：$line"
  STALE_UI=$((STALE_UI + 1))
done < <(grep -rnE '经本机中转」按钮|勾选递归|递归 / 保留属性|填用户名/密码/IP/端口|密码框只作占位|粘贴自动解析|不\*\*自动改源|/IP 框输入|clear && exec|目标空就填源|光标停在末尾|浏览远端前请先解析连接串或填写 IP/主机|勾选保留属性 / 断点续传' docs/02-需求规格.md docs/04-使用说明.md 2>/dev/null)
[ "$STALE_UI" -eq 0 ] && ok "现行规格/使用说明没有已下线功能的残留描述"

# ---------- 汇总 ----------
print -r -- ""
if [ "$fail" -eq 0 ]; then
  print -r -- "== 文档一致性：全部通过（版本 $VERSION，断言 $ASSERT_COUNT）=="
  exit 0
fi
print -r -- "== 文档一致性：有不一致项，见上 =="
exit 1
