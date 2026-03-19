#!/usr/bin/env bash
# preflight.sh — 检查指定模块的前置条件，给出下一步动作建议
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DIR="${SDK_ROOT}/output/staging/bin"

usage() {
  cat <<'EOF'
Usage: preflight.sh <模块名> [OPTIONS]

Options:
  --cap <id>    只检查指定 capability
  --json        JSON 格式输出
  -h, --help    显示帮助
EOF
  exit 0
}

# --- YAML 解析 ---

yaml_val() {
  local file="$1" key="$2"
  awk -v k="$key" '$0 ~ "^"k":" {sub("^"k":[ ]*",""); print; exit}' "$file"
}

yaml_build_packages() {
  local file="$1"
  awk '/^build:/{ b=1; next }
    b && /^[a-z]/ { exit }
    b && /^  packages:/{ p=1; next }
    p && /^    - / { gsub(/^    - /,""); print }
    p && /^  [a-z]/ { exit }' "$file"
}

yaml_profiles() {
  local file="$1"
  awk '/^profiles:/{ b=1; next }
    b && /^[a-z]/ { exit }
    b && /^  recommended:/{ p=1; next }
    p && /^    - / { gsub(/^    - /,""); print }
    p && /^  [a-z]/ { exit }' "$file"
}

# 提取 capabilities 块，每个 capability 输出为一行 JSON-like 格式
# 输出: id|binaries|models|hardware|depends_on
parse_capabilities() {
  local file="$1"
  awk '
    /^capabilities:/ { cap=1; next }
    cap && /^[a-z]/ { if (id) print id"|"bins"|"models"|"hw"|"deps; id=""; exit }
    cap && /^  - id:/ {
      if (id) print id"|"bins"|"models"|"hw"|"deps
      gsub(/^  - id:[ ]*/,""); id=$0
      bins=""; models=""; hw=""; deps=""
      next
    }
    cap && /binaries:/ {
      gsub(/.*binaries:[ ]*\[/,""); gsub(/\]/,""); gsub(/ /,"")
      bins=$0; next
    }
    cap && /models:/ && !/^    models:/ { next }
    cap && /^      - / && models_sec {
      gsub(/^      - /,"")
      models = models ? models","$0 : $0; next
    }
    cap && /^    models:/ {
      if (/\[.*\]/) {
        gsub(/.*\[/,""); gsub(/\]/,""); gsub(/ /,"")
        if ($0 != "") models = models ? models","$0 : $0
        models_sec=0
      } else {
        models_sec=1
      }
      next
    }
    cap && /^    hardware:/ {
      models_sec=0
      if (/\[.*\]/) {
        gsub(/.*\[/,""); gsub(/\]/,""); gsub(/ /,"")
        if ($0 != "") hw=$0
      }
      hw_sec=1; next
    }
    cap && /^      - / && hw_sec {
      gsub(/^      - /,"")
      hw = hw ? hw","$0 : $0; next
    }
    cap && /^    depends_on:/ {
      models_sec=0; hw_sec=0
      if (/\[.*\]/) {
        gsub(/.*\[/,""); gsub(/\]/,""); gsub(/ /,"")
        if ($0 != "") deps=$0
      }
      next
    }
    cap && /^    [a-z]/ { models_sec=0; hw_sec=0 }
    END { if (id) print id"|"bins"|"models"|"hw"|"deps }
  ' "$file"
}

# --- 查找模块 ---

find_module_yaml() {
  local name="$1"
  find "$SDK_ROOT/components" "$SDK_ROOT/application" \
    -name "module.yaml" -not -path "*/.git/*" -not -path "*/output/*" \
    2>/dev/null | while IFS= read -r f; do
    local n
    n=$(yaml_val "$f" "name")
    if [[ "$n" == "$name" ]]; then
      echo "$f"
      return
    fi
  done
}

# --- 主逻辑 ---

[[ $# -lt 1 ]] && usage

MODULE="$1"; shift
CAP_FILTER=""
JSON_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cap) CAP_FILTER="$2"; shift 2 ;;
    --json) JSON_MODE=true; shift ;;
    -h|--help) usage ;;
    *) shift ;;
  esac
done

YAML=$(find_module_yaml "$MODULE")

if [[ -z "$YAML" ]]; then
  echo "[ERROR] 模块不存在: ${MODULE}"
  echo "运行 openclaw/scripts/discover.sh 查看可用模块"
  exit 1
fi

MOD_DIR=$(dirname "$YAML")
REL_DIR="${MOD_DIR#"${SDK_ROOT}"/}"
READY=true
BINS_MISSING=false
MODELS_MISSING=false
HW_MISSING=false
DEPS_MISSING=false

echo "=== 检查模块: ${MODULE} (${REL_DIR}) ==="
echo ""

# 1. 检查 capabilities 中的 binaries / models / hardware / depends_on
echo "=== 编译产物 ==="
CAPS=$(parse_capabilities "$YAML")

while IFS='|' read -r cap_id cap_bins cap_models cap_hw cap_deps; do
  [[ -z "$cap_id" ]] && continue
  [[ -n "$CAP_FILTER" && "$cap_id" != "$CAP_FILTER" ]] && continue

  # 检查 binaries
  IFS=',' read -ra bin_arr <<< "$cap_bins"
  for bin in "${bin_arr[@]}"; do
    [[ -z "$bin" ]] && continue
    if [[ -x "${BIN_DIR}/${bin}" ]]; then
      echo "[OK] ${cap_id} → ${bin}"
    elif command -v "$bin" &>/dev/null; then
      echo "[OK] ${cap_id} → ${bin} (系统命令)"
    else
      echo "[MISSING] ${cap_id} → ${bin}"
      READY=false
      BINS_MISSING=true
    fi
  done
done <<< "$CAPS"

# 2. 检查模型
echo ""
echo "=== 模型文件 ==="
HAS_MODELS=false
while IFS='|' read -r cap_id _ cap_models _ _; do
  [[ -z "$cap_id" || -z "$cap_models" ]] && continue
  [[ -n "$CAP_FILTER" && "$cap_id" != "$CAP_FILTER" ]] && continue
  IFS=',' read -ra model_arr <<< "$cap_models"
  for model_path in "${model_arr[@]}"; do
    [[ -z "$model_path" ]] && continue
    HAS_MODELS=true
    expanded=$(eval echo "$model_path")
    if [[ -d "$expanded" ]] && [[ -n "$(ls -A "$expanded" 2>/dev/null)" ]]; then
      echo "[OK] ${cap_id} → ${model_path}"
    else
      echo "[MISSING] ${cap_id} → ${model_path}"
      READY=false
      MODELS_MISSING=true
    fi
  done
done <<< "$CAPS"
$HAS_MODELS || echo "N/A"

# 3. 检查硬件
echo ""
echo "=== 硬件 ==="
HAS_HW=false
DEV_PATTERN_ANY_MATCH=false
DEV_PATTERN_PRESENT=false
while IFS='|' read -r cap_id _ _ cap_hw _; do
  [[ -z "$cap_id" || -z "$cap_hw" ]] && continue
  [[ -n "$CAP_FILTER" && "$cap_id" != "$CAP_FILTER" ]] && continue
  IFS=',' read -ra hw_arr <<< "$cap_hw"
  for hw in "${hw_arr[@]}"; do
    [[ -z "$hw" ]] && continue
    HAS_HW=true
    if [[ "$hw" == /dev/* ]]; then
      DEV_PATTERN_PRESENT=true
      # Support dynamic device nodes like /dev/ttyUSB*.
      # If multiple /dev patterns are provided, treat them as OR-choices:
      # READY depends on whether any pattern matches.
      if [[ "$hw" == *"*"* || "$hw" == *"?"* || "$hw" == *"["* ]]; then
        shopt -s nullglob
        matches=( $hw )
        shopt -u nullglob
        if [[ ${#matches[@]} -gt 0 ]]; then
          DEV_PATTERN_ANY_MATCH=true
          # Print a few examples to keep output concise.
          mcount=${#matches[@]}
          max_show=5
          show_count=$((mcount < max_show ? mcount : max_show))
          candidates=("${matches[@]:0:show_count}")
          candidates_str="$(printf '%s ' "${candidates[@]}" | sed 's/[ ]*$//')"
          if [[ "$mcount" -gt "$max_show" ]]; then
            echo "[OK] ${cap_id} → ${hw} (candidates: ${candidates_str}, ... total=${mcount})"
          else
            echo "[OK] ${cap_id} → ${hw} (candidates: ${candidates_str})"
          fi
        else
          echo "[MISSING] ${cap_id} → ${hw}"
        fi
      else
        if [[ -e "$hw" ]]; then
          DEV_PATTERN_ANY_MATCH=true
          echo "[OK] ${cap_id} → ${hw}"
        else
          echo "[MISSING] ${cap_id} → ${hw}"
        fi
      fi
    else
      echo "[UNKNOWN] ${cap_id} → ${hw} (需手动确认)"
    fi
  done
done <<< "$CAPS"
$HAS_HW || echo "N/A"

# If at least one /dev/* pattern exists but none matched, mark not-ready.
if $DEV_PATTERN_PRESENT && ! $DEV_PATTERN_ANY_MATCH; then
  READY=false
fi

# 4. 检查跨模块依赖
echo ""
echo "=== 模块依赖 ==="
HAS_DEPS=false
while IFS='|' read -r cap_id _ _ _ cap_deps; do
  [[ -z "$cap_id" || -z "$cap_deps" ]] && continue
  [[ -n "$CAP_FILTER" && "$cap_id" != "$CAP_FILTER" ]] && continue
  IFS=',' read -ra dep_arr <<< "$cap_deps"
  for dep in "${dep_arr[@]}"; do
    [[ -z "$dep" ]] && continue
    HAS_DEPS=true
    # 模块内 capability 依赖（如 llm.server 在 llm 模块内）：跳过外部查找
    dep_module="${dep%%.*}"
    if [[ "$dep_module" == "$MODULE" ]]; then
      echo "[OK] ${cap_id} → ${dep} (模块内依赖)"
    else
      dep_yaml=$(find_module_yaml "$dep_module")
      if [[ -n "$dep_yaml" ]]; then
        echo "[OK] ${cap_id} → ${dep} (已注册)"
      else
        echo "[MISSING] ${cap_id} → ${dep}"
        READY=false
        DEPS_MISSING=true
      fi
    fi
  done
done <<< "$CAPS"
$HAS_DEPS || echo "N/A"

# 5. 结果与建议
echo ""
if $READY; then
  echo "[RESULT] READY"
else
  echo "[RESULT] NOT_READY"
  build_pkg=$(yaml_build_packages "$YAML" | head -1)
  profile=$(yaml_profiles "$YAML" | head -1)

  if $BINS_MISSING; then
    if [[ -n "$build_pkg" && -n "$profile" ]]; then
      echo "[ACTION] 编译产物缺失，请先构建: BUILD_TARGET_FILE=target/${profile}.json ./build/build.sh package ${build_pkg}"
    elif [[ -n "$build_pkg" ]]; then
      echo "[ACTION] 编译产物缺失，请先构建: ./build/build.sh package ${build_pkg}"
    fi
  fi

  if $MODELS_MISSING; then
    echo "[ACTION] 模型文件缺失，请参考 ${REL_DIR}/MODULE.md 下载模型"
  fi

  if $HW_MISSING; then
    echo "[ACTION] 硬件未就绪，请检查设备连接"
  fi

  if $DEPS_MISSING; then
    echo "[ACTION] 依赖模块缺失，请先构建依赖模块（运行 discover.sh 查看）"
  fi
fi
