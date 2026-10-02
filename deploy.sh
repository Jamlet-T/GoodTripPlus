#!/usr/bin/env bash
# 把 GoodTripPlus 从本仓库同步到《以撒的结合：忏悔+》的 mods 目录。
# 用法： bash deploy.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODS_DIR="F:/Steam/steamapps/common/The Binding of Isaac Rebirth/mods"
DST="$MODS_DIR/goodtripplus"

mkdir -p "$DST"
rm -rf "$DST/scripts" "$DST/resources"
cp "$SRC/main.lua" "$SRC/metadata.xml" "$SRC/gtconfig.lua" "$DST/"
cp "$SRC/LICENSE" "$SRC/THIRD_PARTY.md" "$DST/"
cp -r "$SRC/scripts" "$DST/scripts"
cp -r "$SRC/resources" "$DST/resources"

echo "已同步到: $DST"
find "$DST" -type f | sort
