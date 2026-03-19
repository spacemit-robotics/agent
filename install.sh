#!/usr/bin/env bash
# install.sh — 将 spacemit-robot skill 注册到 openclaw
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HOME}/.openclaw/workspace/skills/spacemit_robot"
SRC="${SDK_ROOT}/agent/SKILL.md"

if [[ ! -f "$SRC" ]]; then
  echo "[install] ERROR: ${SRC} 不存在" >&2
  exit 1
fi

echo "[install] SDK_ROOT=${SDK_ROOT}"
echo "[install] 安装 skill 到 ${DEST}"

mkdir -p "$DEST"

# 复制 SKILL.md，将 %SDK_ROOT% 替换为实际绝对路径
sed "s|%SDK_ROOT%|${SDK_ROOT}|g" "$SRC" > "${DEST}/SKILL.md"

echo "[install] 完成"
echo ""
echo "验证: openclaw skills list | grep spacemit"
