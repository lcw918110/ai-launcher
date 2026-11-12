#!/bin/zsh
# 运行 Core 逻辑层全量测试（无 GUI 副作用，可进 CI）
#
# 用法：./scripts/test.sh [--core-only]
#   --core-only  只跑 Core 断言，不跑界面接线门禁。
#                CI 里单独列了一步「校验界面控件接线」（让漏接线在日志里一眼可见），
#                再用 --core-only 跑本脚本，避免同一项检查跑两遍。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/ai-launcher-core-tests"

swiftc -O "$ROOT/src/Core.swift" "$ROOT/tests/main.swift" -o "$OUT"
"$OUT"

if [ "${1:-}" = "--core-only" ]; then
  exit 0
fi

# 界面控件接线门禁：只创建 / 只回显 / 只在快照里搬运的控件一律判失败
zsh "$ROOT/scripts/check-ui-wiring.sh"

# 示例配置必须与代码默认值一致：两份手写文件已经漂移过一次（示例多一个 omp）
zsh "$ROOT/scripts/sync-config-example.sh" --check
