#!/usr/bin/env bash
# 把 GoodTripPlus 从本仓库同步到《以撒的结合：忏悔+》的 mods 目录。
# 2026-10-05 起：直接部署到 Steam 工坊物品的本地目录（带编号后缀），
# 不再部署到 mods/goodtripplus；metadata.xml 的 <id> 换成工坊物品 ID。
# 用法： bash deploy.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODS_DIR="F:/Steam/steamapps/common/The Binding of Isaac Rebirth/mods"
DST="$MODS_DIR/goodtripplus_3813175350"

mkdir -p "$DST"
rm -rf "$DST/scripts" "$DST/resources"
cp "$SRC/main.lua" "$SRC/gtconfig.lua" "$SRC/LICENSE" "$SRC/THIRD_PARTY.md" "$DST/"
cp -r "$SRC/scripts" "$DST/scripts"
cp -r "$SRC/resources" "$DST/resources"
# metadata 用源码版（版本号/描述跟着仓库走），但 <id> 必须是工坊物品 ID，
# 否则 ModUploader 会把它当成新物品上传；thumbnail.png 在 DST 根目录，本脚本不碰它。
sed 's|<id>goodtripplus</id>|<id>3813175350</id>|' "$SRC/metadata.xml" > "$DST/metadata.xml"

echo "已同步到: $DST"
find "$DST" -type f | sort
