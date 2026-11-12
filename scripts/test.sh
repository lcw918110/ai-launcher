#!/bin/zsh
# 运行 Core 逻辑层全量测试（无 GUI 副作用，可进 CI）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/ai-launcher-core-tests"

swiftc -O "$ROOT/src/Core.swift" "$ROOT/tests/main.swift" -o "$OUT"
"$OUT"

# 界面控件接线门禁：只创建 / 只回显 / 只在快照里搬运的控件一律判失败
zsh "$ROOT/scripts/check-ui-wiring.sh"
