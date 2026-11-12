#!/bin/zsh
# 用代码里的 defaultConfigJSON() 重新生成 config.example.json（唯一事实来源）。
#
# 存在的原因：示例配置与代码默认值曾经是两份手写文件，已经漂移过 ——
# 示例写着 opencode + omp 两个工具，首启实际只写出 opencode。
# 现在示例由代码生成，tests/main.swift 又反过来断言两者一致，形成闭环。
#
# 用法：./scripts/sync-config-example.sh [--check]
#   --check  只比对不写盘；不一致退出 1（CI 用）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
let data = try! JSONSerialization.data(withJSONObject: defaultConfigJSON(),
                                       options: [.sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
SWIFT

# 只编译 Core + 一个小入口：不依赖 GUI，可进 CI
# （入口文件必须叫 main.swift，顶层表达式才被当作程序主体）
swiftc -O "$ROOT/src/Core.swift" "$TMP/main.swift" -o "$TMP/gen"
"$TMP/gen" > "$TMP/raw.json"

# JSONSerialization 的 prettyPrinted 会写成 `"key" : value`、空数组还拆三行，
# 手写示例文件不好看。统一成 2 空格缩进 + `"key": value`，中文保持原样不转义。
# 另外按「人读顺序」重排 key：dirs → tools → pathPrepend → copy，工具内 name → cmd
# （排字母序会把 cmd 顶到 name 前面，示例是给人照抄的）。
python3 - "$TMP/raw.json" "$TMP/example.json" <<'PY'
import json, sys
raw, out = sys.argv[1], sys.argv[2]
obj = json.load(open(raw, encoding="utf-8"))
ordered = {k: obj[k] for k in ["dirs", "tools", "pathPrepend", "copy"] if k in obj}
for k in obj:
    ordered.setdefault(k, obj[k])
if isinstance(ordered.get("tools"), list):
    ordered["tools"] = [
        {kk: t[kk] for kk in ["name", "cmd"] if kk in t} | {kk: v for kk, v in t.items() if kk not in ("name", "cmd")}
        for t in ordered["tools"]
    ]
text = json.dumps(ordered, ensure_ascii=False, indent=2) + "\n"
open(out, "w", encoding="utf-8").write(text)
PY

TARGET="$ROOT/config.example.json"
if [ "${1:-}" = "--check" ]; then
  if diff -q "$TMP/example.json" "$TARGET" >/dev/null 2>&1; then
    print -r -- "  ✓ config.example.json 与代码默认值一致"
    exit 0
  fi
  print -r -- "  ✗ config.example.json 与代码默认值不一致，运行 ./scripts/sync-config-example.sh 重新生成"
  diff "$TMP/example.json" "$TARGET" | head -20 | sed 's/^/      /'
  exit 1
fi

cp "$TMP/example.json" "$TARGET"
print -r -- "已用代码默认值重写 $TARGET"