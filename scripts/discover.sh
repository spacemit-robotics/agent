#!/usr/bin/env bash
# discover.sh — 扫描 SDK 内各模块的 module.yaml，输出能力表
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DIR="${SDK_ROOT}/output/staging/bin"

usage() {
  cat <<'EOF'
Usage: discover.sh [OPTIONS]

Options:
  --full              输出完整信息（每个模块详细展示）
  --json              JSON 格式输出（稳定接口，供 AI/脚本解析）
  --category <cat>    按分类过滤（model/peripheral/multimedia/application/tool）
  --targets           列出可用构建方案
  --validate          校验所有 module.yaml（检查必填字段）
  -h, --help          显示帮助
EOF
  exit 0
}

# --- YAML 解析工具函数 ---

# 提取顶层单值字段
yaml_val() {
  local file="$1" key="$2"
  awk -v k="$key" '$0 ~ "^"k":" {sub("^"k":[ ]*",""); print; exit}' "$file"
}

# 提取顶层多行 description（> 折叠格式或单行）
yaml_description() {
  local file="$1"
  local desc
  desc=$(awk '/^description:/{
    if (/^description: >/) { found=1; next }
    else { sub(/^description:[ ]*/,""); print; exit }
  }
  found && /^  [^ ]/ { gsub(/^  /,""); printf "%s ", $0; next }
  found && /^[^ ]/ { exit }' "$file")
  echo "$desc"
}

# 提取 capabilities 中所有 binaries（去重）
yaml_all_binaries() {
  local file="$1"
  awk '/^capabilities:/{ cap=1; next }
    cap && /^[a-z]/ { exit }
    cap && /binaries:/ {
      gsub(/.*binaries:[ ]*\[/,"")
      gsub(/\].*/,"")
      gsub(/,/,"\n")
      gsub(/[ ]/,"")
      print
    }' "$file" | sort -u
}

# 提取 build.packages 列表
yaml_build_packages() {
  local file="$1"
  awk '/^build:/{ b=1; next }
    b && /^[a-z]/ { exit }
    b && /^  packages:/{ p=1; next }
    p && /^    - / { gsub(/^    - /,""); print }
    p && /^  [a-z]/ { exit }' "$file"
}

# 提取 profiles.recommended 列表
yaml_profiles() {
  local file="$1"
  awk '/^profiles:/{ b=1; next }
    b && /^[a-z]/ { exit }
    b && /^  recommended:/{ p=1; next }
    p && /^    - / { gsub(/^    - /,""); print }
    p && /^  [a-z]/ { exit }' "$file"
}

# 检查 binary 是否已编译
check_built() {
  local bins="$1"
  local all_ok=true
  while IFS= read -r bin; do
    [[ -z "$bin" ]] && continue
    [[ -x "${BIN_DIR}/${bin}" ]] || { all_ok=false; break; }
  done <<< "$bins"
  $all_ok && echo "yes" || echo "no"
}

# --- 扫描所有 module.yaml ---

find_modules() {
  find "$SDK_ROOT/components" "$SDK_ROOT/application" \
    -name "module.yaml" -not -path "*/.git/*" -not -path "*/output/*" \
    2>/dev/null | sort
}

# --- 校验 ---

validate_module() {
  local yaml="$1"
  local mod_dir
  mod_dir=$(dirname "$yaml")
  local errors=0

  for field in name name_zh category; do
    val=$(yaml_val "$yaml" "$field")
    if [[ -z "$val" ]]; then
      echo "[ERROR] ${mod_dir}: 缺少必填字段 '$field'"
      ((errors++))
    fi
  done

  local packages
  packages=$(yaml_build_packages "$yaml")
  if [[ -z "$packages" ]]; then
    echo "[ERROR] ${mod_dir}: 缺少 build.packages"
    ((errors++))
  fi

  local bins
  bins=$(yaml_all_binaries "$yaml")
  if [[ -z "$bins" ]]; then
    echo "[WARN] ${mod_dir}: 未定义 capabilities 或 binaries"
  fi

  [[ $errors -eq 0 ]] && echo "[OK] ${mod_dir}"
  return $errors
}

# --- 列出构建方案 ---

list_targets() {
  echo "可用构建方案："
  for f in "${SDK_ROOT}"/target/*.json; do
    [[ -f "$f" ]] || continue
    local name desc
    name=$(basename "$f" .json)
    desc=$(grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*: *"//;s/"$//' || true)
    printf "  %-30s %s\n" "$name" "$desc"
  done
}

# --- 主逻辑 ---

MODE="summary"
FILTER_CAT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) MODE="full"; shift ;;
    --json) MODE="json"; shift ;;
    --category) FILTER_CAT="$2"; shift 2 ;;
    --targets) list_targets; exit 0 ;;
    --validate) MODE="validate"; shift ;;
    -h|--help) usage ;;
    *) shift ;;
  esac
done

MODULE_FILES=$(find_modules)

if [[ -z "$MODULE_FILES" ]]; then
  echo "未发现任何 module.yaml"
  exit 1
fi

# validate 模式
if [[ "$MODE" == "validate" ]]; then
  total=0; ok=0
  while IFS= read -r yaml; do
    ((total++))
    validate_module "$yaml" && ((ok++)) || true
  done <<< "$MODULE_FILES"
  echo ""
  echo "校验完成: ${ok}/${total} 通过"
  exit 0
fi

# json 模式
if [[ "$MODE" == "json" ]]; then
  echo "["
  first=true
  while IFS= read -r yaml; do
    mod_dir=$(dirname "$yaml")
    rel_dir="${mod_dir#"${SDK_ROOT}"/}"
    name=$(yaml_val "$yaml" "name")
    name_zh=$(yaml_val "$yaml" "name_zh")
    category=$(yaml_val "$yaml" "category")
    desc=$(yaml_description "$yaml")
    bins=$(yaml_all_binaries "$yaml" | tr '\n' ',' | sed 's/,$//')
    built=$(check_built "$(yaml_all_binaries "$yaml")")
    packages=$(yaml_build_packages "$yaml" | tr '\n' ',' | sed 's/,$//')
    has_module_md="false"
    [[ -f "${mod_dir}/MODULE.md" ]] && has_module_md="true"

    [[ -n "$FILTER_CAT" && "$category" != "$FILTER_CAT" ]] && continue

    $first || echo ","
    first=false
    cat <<ENTRY
  {
    "name": "${name}",
    "name_zh": "${name_zh}",
    "category": "${category}",
    "description": "${desc}",
    "path": "${rel_dir}",
    "binaries": "${bins}",
    "built": "${built}",
    "build_packages": "${packages}",
    "has_module_md": ${has_module_md}
  }
ENTRY
  done <<< "$MODULE_FILES"
  echo ""
  echo "]"
  exit 0
fi

# full 模式
if [[ "$MODE" == "full" ]]; then
  while IFS= read -r yaml; do
    mod_dir=$(dirname "$yaml")
    rel_dir="${mod_dir#"${SDK_ROOT}"/}"
    name=$(yaml_val "$yaml" "name")
    name_zh=$(yaml_val "$yaml" "name_zh")
    category=$(yaml_val "$yaml" "category")
    desc=$(yaml_description "$yaml")
    bins=$(yaml_all_binaries "$yaml" | tr '\n' ',' | sed 's/,$//')
    built=$(check_built "$(yaml_all_binaries "$yaml")")
    packages=$(yaml_build_packages "$yaml" | tr '\n' ',' | sed 's/,$//')
    profiles=$(yaml_profiles "$yaml" | tr '\n' ',' | sed 's/,$//')

    [[ -n "$FILTER_CAT" && "$category" != "$FILTER_CAT" ]] && continue

    echo "=== ${name} (${name_zh}) ==="
    echo "  路径:       ${rel_dir}"
    echo "  分类:       ${category}"
    echo "  说明:       ${desc}"
    echo "  编译产物:   ${bins}"
    echo "  已编译:     ${built}"
    echo "  构建包:     ${packages}"
    echo "  推荐方案:   ${profiles:-N/A}"
    echo "  MODULE.md:  $([ -f "${mod_dir}/MODULE.md" ] && echo "有" || echo "无")"
    echo ""
  done <<< "$MODULE_FILES"
  exit 0
fi

# summary 模式（默认）
printf "%-12s %-12s %-12s %-40s %-6s %s\n" "MODULE" "NAME_ZH" "CATEGORY" "BINARIES" "BUILT" "PATH"
printf "%-12s %-12s %-12s %-40s %-6s %s\n" "------" "-------" "--------" "--------" "-----" "----"

while IFS= read -r yaml; do
  mod_dir=$(dirname "$yaml")
  rel_dir="${mod_dir#"${SDK_ROOT}"/}"
  name=$(yaml_val "$yaml" "name")
  name_zh=$(yaml_val "$yaml" "name_zh")
  category=$(yaml_val "$yaml" "category")
  bins=$(yaml_all_binaries "$yaml" | tr '\n' ',' | sed 's/,$//')
  built=$(check_built "$(yaml_all_binaries "$yaml")")

  [[ -n "$FILTER_CAT" && "$category" != "$FILTER_CAT" ]] && continue

  printf "%-12s %-12s %-12s %-40s %-6s %s\n" "$name" "$name_zh" "$category" "$bins" "$built" "$rel_dir"
done <<< "$MODULE_FILES"
