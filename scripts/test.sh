#!/bin/zsh
# 运行 Core 逻辑层全量测试（无 GUI 副作用，可进 CI）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/ai-launcher-core-tests"

swiftc -O "$ROOT/src/Core.swift" "$ROOT/tests/main.swift" -o "$OUT"
"$OUT"
