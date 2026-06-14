#!/bin/bash
set -euo pipefail

# =============================================================================
# 远程配置地址（可通过环境变量覆盖）
# =============================================================================
CONFIG_BASE="${CLAUDE_CONFIG_BASE_URL:-https://static.jbjbjb.site/claude}"

# 各资源 URL
STATUSLINE_URL="${CONFIG_BASE}/statusLine.mjs"
CLAUDE_MD_APPEND_URL="${CONFIG_BASE}/CLAUDE.md"

# ── 本地路径 ──────────────────────────────────────────────────────────────
CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
STATUS_LINE="$CLAUDE_DIR/statusLine.mjs"
SETTINGS="$CLAUDE_DIR/settings.json"

# =============================================================================
# 参数解析
# =============================================================================
RUN_CLAUDE_MD=false
RUN_STATUSLINE=false
RUN_SETTINGS=false
NON_INTERACTIVE=false

# Settings 值 — 命令行参数直接设置，交互模式由 select_option 填充
# 注意：CUSTOM_MODEL 可选，其余为必填
BASE_URL=""
API_KEY=""
MODEL=""
HAIKU_MODEL=""
CUSTOM_MODEL=""

# ── 临时文件清理 ──────────────────────────────────────────────────────────
cleanup() {
  rm -f "${SETTINGS}.tmp" "${STATUS_LINE}.tmp" "${CLAUDE_MD}.tmp"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP

usage() {
  cat << 'USAGE'
用法: ./claude-code-config.sh [选项]

交互模式（无预设参数）按提示依次配置。传入任一 Settings 参数即进入非交互模式。
CLAUDE.md 与 statusLine.mjs 从远程拉取。

操作范围:
  --claude-md       更新 ~/.claude/CLAUDE.md
  --statusline      更新 ~/.claude/statusLine.mjs

Settings 参数（带 * 必填，传入后自动激活 settings + 非交互模式）:
  * --base-url <URL>     Base URL
  * --api-key <KEY>      API KEY
  * --model <MODEL>      Model（同时用于 Opus/Sonnet）
  * --haiku-model <M>    Haiku Model
    --custom-model <M>   Custom Model（可选，不传留空）

  -h, --help           显示帮助

示例:
  ./claude-code-config.sh                                                       # 交互
  ./claude-code-config.sh --base-url https://api.deepseek.com/anthropic \
    --api-key sk-xxxx --model deepseek-v4-pro --haiku-model claude-haiku-4-5   # 非交互
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-md)   RUN_CLAUDE_MD=true; shift ;;
    --statusline)  RUN_STATUSLINE=true; shift ;;
    --base-url)      BASE_URL="$2"; NON_INTERACTIVE=true; RUN_SETTINGS=true; shift 2 ;;
    --api-key)       API_KEY="$2"; NON_INTERACTIVE=true; RUN_SETTINGS=true; shift 2 ;;
    --model)         MODEL="$2"; NON_INTERACTIVE=true; RUN_SETTINGS=true; shift 2 ;;
    --haiku-model)   HAIKU_MODEL="$2"; NON_INTERACTIVE=true; RUN_SETTINGS=true; shift 2 ;;
    --custom-model)  CUSTOM_MODEL="$2"; NON_INTERACTIVE=true; RUN_SETTINGS=true; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "❌ 未知参数: $1（使用 -h 查看帮助）"; exit 1 ;;
  esac
done

# 未指定模块范围时默认全部执行
# 非交互模式：settings 已由参数激活，仅需判断 --claude-md / --statusline
# 交互模式：三个模块均需判断
if $NON_INTERACTIVE; then
  if ! $RUN_CLAUDE_MD && ! $RUN_STATUSLINE; then
    RUN_CLAUDE_MD=true
    RUN_STATUSLINE=true
  fi
elif ! $RUN_CLAUDE_MD && ! $RUN_STATUSLINE && ! $RUN_SETTINGS; then
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

# 模型选项 (model / haiku-model / custom-model 共用) — 普通值，无标签|值分隔符
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

# 下载 URL（2 次重试、静默模式），成功输出到 stdout，失败打印错误到 stderr 并返回 1
fetch() {
  curl -fsSL --retry 2 "$1" || { echo "    ❌ 下载失败: $1" >&2; return 1; }
}

# ── 通用选项选择（支持标签|值格式） ──────────────────────────────────────
# 用法: select_option "提示" ARRAY_NAME[@] result_var [allow_skip]
# 返回: 0=成功, 1=失败（用户取消或无效选择）
# allow_skip=true 时增加"留空"选项；用户选择后 result_var 设为空字符串，函数返回 0
select_option() {
  local prompt="$1"
  local -a opts=("${!2}")
  local result_var="$3"
  local allow_skip="${4:-false}"

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
  if $allow_skip; then
    echo "  $((count + 2))) 留空（不设置）"
  fi
  echo ""

  local max_opt=$((count + 1))
  $allow_skip && max_opt=$((count + 2))

  read -r -p "请选择 [1-${max_opt}]: " choice

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $count ]; then
    local entry="${opts[$((choice - 1))]}"
    if [[ "$entry" == *"|"* ]]; then
      eval "$result_var=\"${entry#*|}\""
    else
      eval "$result_var=\"$entry\""
    fi
  elif [ "$choice" -eq $((count + 1)) ]; then
    local custom_val
    read -r -p "请输入自定义值: " custom_val
    if [ -z "$custom_val" ]; then
      echo "❌ 输入不能为空"
      return 1
    fi
    eval "$result_var=\"$custom_val\""
  elif $allow_skip && [ "$choice" -eq $((count + 2)) ]; then
    eval "$result_var=\"\""
  else
    echo "❌ 无效选项: $choice"
    return 1
  fi
}

# ── 合并 env 配置到 settings.json（纯 Bash：awk + sed）───────────────────
# 只写入非空字段，自动跳过已有 ANTHROPIC_ 行
# 注意：仅处理空 JSON {} 或已有 "env" 键的 settings.json；非空且无 "env" 键时会产生无效 JSON
merge_env() {
  local base_url="$1" api_key="$2" model="$3" haiku_model="$4" custom_model="$5" target="$6"

  if [ ! -f "$target" ]; then
    echo '{}' > "$target"
  fi

  local tmp="${target}.tmp"

  awk \
    -v base_url="$base_url" \
    -v api_key="$api_key" \
    -v model="$model" \
    -v haiku="$haiku_model" \
    -v custom="$custom_model" '
    BEGIN { has_env = 0 }

    /"ANTHROPIC_/ { next }

    /^[[:space:]]*"env"[[:space:]]*:[[:space:]]*\{/ {
      has_env = 1
      print
      _insert_keys()
      next
    }

    /^\}[[:space:]]*,?[[:space:]]*$/ && !has_env {
      print "  \"env\": {"
      _insert_keys()
      print "  },"
      print "}"
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
  ' "$target" > "$tmp"

  # 清理最后一个 ANTHROPIC 键后的尾随逗号（当它在 env 闭合 } 之前时）
  sed -e '/,$/{ N; s/,\n\([[:space:]]*\}\)/\n\1/; }' "$tmp" > "$target"
  rm -f "$tmp"
}

# =============================================================================
# 配置函数
# =============================================================================

# ── settings.json — 配置收集、写入与 TypeScript Language Server 安装 ────
configure_settings() {
  # ── 收集缺失的必填项 ──────────────────────────────────────────────────
  local missing=()
  [ -z "$BASE_URL" ]    && missing+=("--base-url")
  [ -z "$API_KEY" ]     && missing+=("--api-key")
  [ -z "$MODEL" ]       && missing+=("--model")
  [ -z "$HAIKU_MODEL" ] && missing+=("--haiku-model")

  if $NON_INTERACTIVE && [ ${#missing[@]} -eq 0 ]; then
    # 所有必填项已通过命令行提供 → 纯非交互模式
    echo "API Base URL: $BASE_URL"
    echo "Model: $MODEL"
    echo "Haiku Model: $HAIKU_MODEL"
    echo "Custom Model: ${CUSTOM_MODEL:-(未设置)}"
  else
    # 有缺失项或纯交互模式 → 提示并只询问未提供的值
    if [ ${#missing[@]} -gt 0 ]; then
      echo ""
      echo "⚠️  以下必填项未通过命令行提供，将进入交互式选择："
      for m in "${missing[@]}"; do
        echo "    • $m"
      done
    fi

    # ── 只询问未提供的值 ──────────────────────────────────────────────
    if [ -z "$BASE_URL" ]; then
      echo ""
      until select_option "请选择 API Base URL:" BASE_URL_OPTIONS[@] BASE_URL; do :; done
    fi

    if [ -z "$API_KEY" ]; then
      echo ""
      read -r -s -p "请输入你的 API KEY: " API_KEY
      echo ""
      [ -z "$API_KEY" ] && { echo "❌ API KEY 不能为空"; exit 1; }
    fi

    if [ -z "$MODEL" ]; then
      until select_option "请选择默认 Model（同时用于 Opus / Sonnet）:" MODEL_OPTIONS[@] MODEL; do :; done
    fi

    if [ -z "$HAIKU_MODEL" ]; then
      until select_option "请选择 Haiku Model:" MODEL_OPTIONS[@] HAIKU_MODEL; do :; done
    fi

    if [ -z "$CUSTOM_MODEL" ]; then
      until select_option "请选择 Custom Model（可选）:" MODEL_OPTIONS[@] CUSTOM_MODEL true; do :; done
    fi
  fi

  echo ""
  echo "==> 写入 settings.json ..."
  mkdir -p "$(dirname "$SETTINGS")"
  merge_env "$BASE_URL" "$API_KEY" "$MODEL" "$HAIKU_MODEL" "$CUSTOM_MODEL" "$SETTINGS"
  echo "    ✅ settings.json 写入完成 → $SETTINGS"

  # ── 安装 TypeScript Language Server（skills 依赖）──────────────────────
  echo ""
  echo "==> 安装 TypeScript Language Server ..."
  if command -v typescript-language-server &>/dev/null; then
    echo "    ✅ typescript-language-server 已安装"
  else
    echo "    📦 正在安装 typescript-language-server ..."
    if npm install -g typescript-language-server; then
      echo "    ✅ typescript-language-server 安装成功"
    else
      echo "    ❌ 安装失败，请手动执行: npm install -g typescript-language-server"
      echo "    🔗 https://github.com/typescript-language-server/typescript-language-server"
    fi
  fi
}

# ── CLAUDE.md — 从 GitHub 下载基础 CLAUDE.md，再附加远程补充内容 ─────────
configure_claude_md() {
  echo "==> 获取 CLAUDE.md ..."
  local tmp="${CLAUDE_MD}.tmp"

  fetch "https://raw.githubusercontent.com/forrestchang/andrej-karpathy-skills/main/CLAUDE.md" > "$tmp" || exit 1

  local append
  if append=$(fetch "$CLAUDE_MD_APPEND_URL"); then
    printf '\n%s\n' "$append" >> "$tmp"
  else
    echo "    ⚠️  远程附加配置获取失败，将使用基础 CLAUDE.md" >&2
  fi

  mv "$tmp" "$CLAUDE_MD"
  echo "    ✅ CLAUDE.md 写入完成 → $CLAUDE_MD"
}

# ── statusLine.mjs — 远程下载 ────────────────────────────────────────────
configure_statusline() {
  echo "==> 获取 statusLine.mjs ..."
  local tmp="${STATUS_LINE}.tmp"
  fetch "$STATUSLINE_URL" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$STATUS_LINE"
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
