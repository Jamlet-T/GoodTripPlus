#!/usr/bin/env bash
# 把 GoodTripPlus 从本仓库同步到《以撒的结合：忏悔+》的 mods 目录。
# 用法： bash deploy.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODS_DIR="F:/Steam/steamapps/common/The Binding of Isaac Rebirth/mods"
DST="$MODS_DIR/goodtripplus"

mkdir -p "$DST"
rm -rf "$DST/scripts"
cp "$SRC/main.lua" "$SRC/metadata.xml" "$SRC/gtconfig.lua" "$DST/"
cp -r "$SRC/scripts" "$DST/scripts"

echo "已同步到: $DST"
find "$DST" -type f | sort
