#!/usr/bin/env bash
# 打包成可直接发人的 zip（dist/goodtripplus-<版本>.zip）
#
# 本脚本只产出分发用的压缩包，不碰游戏目录。
#
# 排除项：
#   pack.sh              —— 打包脚本本身不属于模组运行文件
#   disable.it           —— 游戏生成的「禁用该 mod」标记，不属于源码
#   .git                  —— 版本控制
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SRC"

# 版本号取自 metadata.xml，避免手改漏改
VERSION="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' metadata.xml | head -1)"
OUT_DIR="$SRC/dist"
OUT="$OUT_DIR/goodtripplus-$VERSION.zip"

PY=""
for candidate in \
  "$(command -v python3 || true)" \
  "$(command -v python || true)"
do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "找不到 python，无法打包" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
"$PY" - "$OUT" <<'PYEOF'
import os, sys, zipfile

out = sys.argv[1]
EXCLUDE_FILES = {"deploy.sh", "pack.sh", "disable.it"}
EXCLUDE_DIRS = {".git", "dist"}

files = []
for dirpath, dirnames, filenames in os.walk("."):
    dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
    for f in filenames:
        if f in EXCLUDE_FILES:
            continue
        rel = os.path.relpath(os.path.join(dirpath, f), ".")
        files.append(rel.replace("\\", "/"))

files.sort()
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in files:
        # 压缩包内统一带一层 goodtripplus/ 前缀，解压即得正确目录名
        z.write(rel, "goodtripplus/" + rel)

size = os.path.getsize(out)
print("打包完成: %s (%d 字节, %d 个文件)" % (out, size, len(files)))
PYEOF
