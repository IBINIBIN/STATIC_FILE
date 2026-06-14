#!/bin/bash
set -euo pipefail

# =============================================================================
# 远程配置地址（可通过环境变量覆盖）
# =============================================================================
CONFIG_BASE="${CLAUDE_CONFIG_BASE_URL:-https://static.jbjbjb/site/claude}"

# 各资源 URL
STATUSLINE_URL="${CONFIG_BASE}/statusLine.mjs"
CLAUDE_MD_APPEND_URL="${CONFIG_BASE}/CLAUDE.md"

# ── 本地路径 ──────────────────────────────────────────────────────────────
CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
STATUS_LINE="$CLAUDE_DIR/statusLine.mjs"
# ── 项目路径（脚本位于 claude/ 目录下）──────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SETTINGS="$PROJECT_DIR/claude/settings.json"

# =============================================================================
# 参数解析
# =============================================================================
RUN_CLAUDE_MD=false
RUN_STATUSLINE=false
RUN_SETTINGS=false
BASE_URL_PRESET=""
API_KEY_PRESET=""
MODEL_PRESET=""
HAIKU_MODEL_PRESET=""
CUSTOM_MODEL_PRESET=""

usage() {
  cat << 'USAGE'
用法: ./claude-code-config.sh [选项]

无参数时，按交互流程依次执行全部配置（settings → CLAUDE.md → statusLine）。
所有配置内容从远程拉取，环境变量 CLAUDE_CONFIG_BASE_URL 可覆盖基地址。

操作范围（可组合）:
  --claude-md       只更新 ~/.claude/CLAUDE.md
  --statusline      只更新 ~/.claude/statusLine.mjs
  --settings        只更新 claude/settings.json（交互收集配置）

Settings 非交互模式:
  --base-url <URL>     预设 Base URL
  --api-key <KEY>      预设 API KEY
  --model <MODEL>      预设 Model（同时用于 Opus/Sonnet）
  --haiku-model <MODEL> 预设 Haiku Model
  --custom-model <STR> 预设 Custom Model

其他:
  -h, --help        显示此帮助信息

示例:
  ./claude-code-config.sh                                                        # 全部交互执行
  ./claude-code-config.sh --claude-md --statusline                               # 组合
  ./claude-code-config.sh --settings --base-url https://api.deepseek.com/anthropic --api-key sk-xxxx --model deepseek-v4-pro --haiku-model claude-haiku-4-5  # 非交互
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-md)   RUN_CLAUDE_MD=true; shift ;;
    --statusline)  RUN_STATUSLINE=true; shift ;;
    --settings)    RUN_SETTINGS=true; shift ;;
    --base-url)      BASE_URL_PRESET="$2"; shift 2 ;;
    --api-key)       API_KEY_PRESET="$2"; shift 2 ;;
    --model)         MODEL_PRESET="$2"; shift 2 ;;
    --haiku-model)   HAIKU_MODEL_PRESET="$2"; shift 2 ;;
    --custom-model)  CUSTOM_MODEL_PRESET="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "❌ 未知参数: $1（使用 -h 查看帮助）"; exit 1 ;;
  esac
done

# 无操作标志时默认全部执行
if ! $RUN_CLAUDE_MD && ! $RUN_STATUSLINE && ! $RUN_SETTINGS; then
  RUN_CLAUDE_MD=true
  RUN_STATUSLINE=true
  RUN_SETTINGS=true
fi

# ── 确保 .claude 目录存在 ────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR"

# ── 预设选项 ──────────────────────────────────────────────────────────────
# Base URL: 标签|值 格式
BASE_URL_OPTIONS=(
  "腾讯云|https://tokenhub.tencentmaas.com"
  "DeepSeek|https://api.deepseek.com/anthropic"
  "ARK|https://ark.cn-beijing.volces.com/api/coding"
  "GLM|https://open.bigmodel.cn/api/anthropic"
)

# 模型选项 (model / haiku-model / custom-model 共用)
MODEL_OPTIONS=(
  "deepseek-v4-flash[1m]"
  "deepseek-v4-pro[1m]"
  "deepseek-v4-flash-202605[1m]"
  "deepseek-v4-pro-202606[1m]"
  "minimax-m3"
)

# =============================================================================
# 辅助函数
# =============================================================================
fetch() {
  curl -fsSL --retry 2 "$1" || { echo "    ❌ 下载失败: $1" >&2; return 1; }
}

# ── 通用选项选择（支持标签|值格式） ──────────────────────────────────────
# 用法: select_option "提示" BASE_URL_OPTIONS[@] result_var
# 返回: 0=成功, 1=失败（用户取消或无效选择）
select_option() {
  local prompt="$1"
  local -a opts=("${!2}")
  local -n result=$3

  echo ""
  echo "$prompt"
  echo ""

  local count=${#opts[@]}
  for ((i = 0; i < count; i++)); do
    local entry="${opts[$i]}"
    if [[ "$entry" == *"|"* ]]; then
      local label="${entry%%|*}"
      local value="${entry#*|}"
      echo "  $((i + 1))) $label $value"
    else
      echo "  $((i + 1))) $entry"
    fi
  done
  echo "  $((count + 1))) 自定义输入..."
  echo ""

  read -r -p "请选择 [1-$((count + 1))]: " choice

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $count ]; then
    local entry="${opts[$((choice - 1))]}"
    if [[ "$entry" == *"|"* ]]; then
      result="${entry#*|}"
    else
      result="$entry"
    fi
  elif [ "$choice" -eq $((count + 1)) ]; then
    read -r -p "请输入自定义值: " result
    if [ -z "$result" ]; then
      echo "❌ 输入不能为空"
      return 1
    fi
  else
    echo "❌ 无效选项: $choice"
    return 1
  fi
}

# ── 合并 env 配置到 settings.json（纯 Bash：sed + awk）────────────────────
# 只写入非空字段，保留已有 key
# 依赖：settings.json 为标准多行缩进格式（2 空格）；非此格式请改用 JSON 解析器
merge_env() {
  local base_url="$1" api_key="$2" model="$3" haiku_model="$4" custom_model="$5" target="$6"

  # 如果 settings.json 不存在，从空对象初始化
  if [ ! -f "$target" ]; then
    echo '{}' > "$target"
  fi

  local tmp="${target}.tmp"

  # Step 1: 删除文件中已有的 ANTHROPIC_* 行（支持重新运行）
  sed '/"ANTHROPIC_/d' "$target" > "$tmp"

  # Step 2: 在 "env": { 行之后插入新配置；若无 env 块则新建
  awk \
    -v base_url="$base_url" \
    -v api_key="$api_key" \
    -v model="$model" \
    -v haiku="$haiku_model" \
    -v custom="$custom_model" '
    BEGIN { has_env = 0 }

    /^[[:space:]]*"env"[[:space:]]*:[[:space:]]*\{/ {
      has_env = 1
      print
      _insert_keys()
      next
    }

    # 如果没有 env 块，在文件最后的 } 之前插入（处理多行和单行 {} 两种情况）
    /^\}[[:space:]]*,?[[:space:]]*$/ && !has_env {
      print "  \"env\": {"
      _insert_keys()
      print "  },"
    }
    /^\{[[:space:]]*\}[[:space:]]*$/ && !has_env {
      print "{"
      print "  \"env\": {"
      _insert_keys()
      print "  }"
      print "}"
      next
    }

    { print }

    function _insert_keys() {
      if (length(base_url)  > 0) printf "    \"ANTHROPIC_BASE_URL\": \"%s\",\n", base_url
      if (length(api_key)   > 0) printf "    \"ANTHROPIC_AUTH_TOKEN\": \"%s\",\n", api_key
      if (length(model)     > 0) {
        printf "    \"ANTHROPIC_MODEL\": \"%s\",\n", model
        printf "    \"ANTHROPIC_DEFAULT_OPUS_MODEL\": \"%s\",\n", model
        printf "    \"ANTHROPIC_DEFAULT_SONNET_MODEL\": \"%s\",\n", model
      }
      if (length(haiku)     > 0) printf "    \"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"%s\",\n", haiku
      if (length(custom)    > 0) printf "    \"ANTHROPIC_CUSTOM_MODEL_OPTION\": \"%s\",\n", custom
    }
  ' "$tmp" > "${target}.tmp2"

  # Step 3: 移除 env 块内 } 之前的尾随逗号
  sed -e ':a' -e '$!N; s/,\(\n[[:space:]]*\}[[:space:]]*\)/\1/; t a' -e 'P; D' "${target}.tmp2" > "${target}.tmp3"

  mv "${target}.tmp3" "$target" && rm -f "$tmp" "${target}.tmp2"
}

# =============================================================================
# 配置函数
# =============================================================================

# ── settings.json — 交互收集配置 + 写入 ──────────────────────────────────
configure_settings() {

  # 1. Base URL
  if [ -n "$BASE_URL_PRESET" ]; then
    BASE_URL="$BASE_URL_PRESET"
    echo "Base URL 已预设: $BASE_URL"
  else
    while true; do
      select_option "请选择 API Base URL:" BASE_URL_OPTIONS[@] BASE_URL && break
    done
  fi

  # 2. API Key
  if [ -n "$API_KEY_PRESET" ]; then
    API_KEY="$API_KEY_PRESET"
    echo "API KEY 已预设"
  else
    echo ""
    read -r -s -p "请输入你的 API KEY: " API_KEY
    echo ""
    if [ -z "$API_KEY" ]; then
      echo "❌ API KEY 不能为空"
      exit 1
    fi
  fi

  # 3. Model
  if [ -n "$MODEL_PRESET" ]; then
    MODEL="$MODEL_PRESET"
    echo "Model 已预设: $MODEL"
  else
    while true; do
      select_option "请选择默认 Model（同时用于 Opus / Sonnet）:" MODEL_OPTIONS[@] MODEL && break
    done
  fi

  # 4. Haiku Model
  if [ -n "$HAIKU_MODEL_PRESET" ]; then
    HAIKU_MODEL="$HAIKU_MODEL_PRESET"
    echo "Haiku Model 已预设: $HAIKU_MODEL"
  else
    while true; do
      select_option "请选择 Haiku Model:" MODEL_OPTIONS[@] HAIKU_MODEL && break
    done
  fi

  # 5. Custom Model
  if [ -n "$CUSTOM_MODEL_PRESET" ]; then
    CUSTOM_MODEL="$CUSTOM_MODEL_PRESET"
    echo "Custom Model 已预设: $CUSTOM_MODEL"
  else
    echo ""
    read -r -p "请输入 Custom Model（可选，回车跳过）: " CUSTOM_MODEL || true
  fi

  # 合并写入
  echo ""
  echo "==> 写入 settings.json ..."
  merge_env "$BASE_URL" "$API_KEY" "$MODEL" "$HAIKU_MODEL" "$CUSTOM_MODEL" "$SETTINGS"
  echo "    ✅ settings.json 写入完成 → $SETTINGS"
}

# ── CLAUDE.md — 远程下载 + 远程补充内容 ──────────────────────────────────
configure_claude_md() {
  echo "==> 获取 CLAUDE.md ..."
  local content
  content=$(fetch "https://raw.githubusercontent.com/forrestchang/andrej-karpathy-skills/main/CLAUDE.md") || exit 1

  local append
  append=$(fetch "$CLAUDE_MD_APPEND_URL") || true
  if [ -n "$append" ]; then
    content+=$'\n'"$append"$'\n'
  fi

  echo "$content" > "$CLAUDE_MD"
  echo "    ✅ CLAUDE.md 写入完成 → $CLAUDE_MD"
}

# ── statusLine.mjs — 远程下载 ────────────────────────────────────────────
configure_statusline() {
  echo "==> 获取 statusLine.mjs ..."
  local tmp="${STATUS_LINE}.tmp"
  fetch "$STATUSLINE_URL" > "$tmp" && mv "$tmp" "$STATUS_LINE"
  echo "    ✅ statusLine.mjs 写入完成 → $STATUS_LINE"
}

# ── 打印配置摘要 ──────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo "🎉 Claude Code 配置完成！"
  echo ""
  if $RUN_SETTINGS; then
    echo "    Base URL      → ${BASE_URL:-未设置}"
    echo "    API KEY       → ${API_KEY:0:8}****"
    echo "    Model         → ${MODEL:-未设置}"
    echo "    Haiku Model   → ${HAIKU_MODEL:-未设置}"
    echo "    Custom Model  → ${CUSTOM_MODEL:-未设置}"
    echo "    settings.json → $SETTINGS"
  fi
  if $RUN_CLAUDE_MD; then
    echo "    CLAUDE.md     → $CLAUDE_MD"
  fi
  if $RUN_STATUSLINE; then
    echo "    statusLine    → $STATUS_LINE"
  fi
  echo ""
  echo "    📡 配置来源: $CONFIG_BASE"
}

# =============================================================================
# 执行
# =============================================================================
echo "============================================="
echo "  Claude Code 配置脚本"
echo "============================================="
echo ""

$RUN_SETTINGS   && configure_settings
$RUN_CLAUDE_MD  && configure_claude_md
$RUN_STATUSLINE && configure_statusline
print_summary
