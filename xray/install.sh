#!/usr/bin/env bash
# ==============================================================================
# 功能描述: 自动安装 Xray 并生成 VLESS + Reality 配置，最终输出标准 vless:// 链接
# 安全提示: 日志文件包含 UUID、私钥和 vless:// 链接等敏感信息，请妥善保管或用后删除
# ==============================================================================

set -o pipefail  # 管道中任意命令失败则整个管道失败

# ------------------------------------------------------------------------------
# 全局变量
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_DIR="/var/log/xray-install"
readonly LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
readonly CONFIG_PATH="/usr/local/etc/xray/config.json"
readonly XRAY_INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
readonly DEFAULT_SNI="www.oracle.com"

# 命令行参数标志
FLAG_UPDATE=false
FLAG_SHOW_LINK=false

# 颜色转义序列（注意：未做 TTY 检测，重定向时仍会输出 ANSI 码）
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

# ------------------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --update)
                FLAG_UPDATE=true
                shift
                ;;
            --show-link)
                FLAG_SHOW_LINK=true
                shift
                ;;
            --help|-h)
                echo "用法: sudo ./${SCRIPT_NAME} [选项]"
                echo ""
                echo "选项:"
                echo "  --update      仅更新 Xray 到最新版本（不重新生成配置）"
                echo "  --show-link   从现有配置中读取参数并显示 vless:// 连接链接"
                echo "  --help,-h     显示帮助信息"
                exit 0
                ;;
            *)
                echo "未知参数: $1（使用 --help 查看帮助）" >&2
                exit 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 日志函数
# ------------------------------------------------------------------------------
_log() {
    local level="$1"
    local color="$2"
    shift 2
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    echo -e "${color}[${timestamp}] [${level}]${COLOR_RESET} ${message}"
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
}

log_info()  { _log "INFO"  "${COLOR_BLUE}"   "$@"; }
log_ok()    { _log "OK"    "${COLOR_GREEN}"  "$@"; }
log_warn()  { _log "WARN"  "${COLOR_YELLOW}" "$@"; }
log_error() { _log "ERROR" "${COLOR_RED}"    "$@" >&2; }

log_section() {
    local msg="$1"
    echo "------------------------------------------" | tee -a "${LOG_FILE}"
    log_info "${msg}"
    echo "------------------------------------------" | tee -a "${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# 初始化日志目录
# ------------------------------------------------------------------------------
init_log() {
    if ! mkdir -p "${LOG_DIR}" 2>/dev/null; then
        echo "无法创建日志目录 ${LOG_DIR}，请使用 root 权限运行" >&2
        exit 1
    fi
    : > "${LOG_FILE}"
    log_info "日志文件：${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# 检查依赖命令
# ------------------------------------------------------------------------------
check_dependencies() {
    log_section "检查系统依赖"
    local deps=("curl" "shuf" "ss" "awk" "systemctl" "sudo" "openssl" "base64")
    local missing=()

    for cmd in "${deps[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
            log_warn "未找到命令：${cmd}"
        else
            log_info "已检查：${cmd}"
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        log_error "缺少依赖：${missing[*]}，请先安装后再运行本脚本"
        exit 1
    fi
    log_ok "所有依赖检查通过"
}

# ------------------------------------------------------------------------------
# 安装 Xray
# ------------------------------------------------------------------------------
install_xray() {
    log_section "开始安装 Xray"

    if command -v xray >/dev/null 2>&1; then
        local current_version
        current_version="$(xray version 2>/dev/null | head -1)"

        if [ "${FLAG_UPDATE}" != true ]; then
            log_ok "Xray 已安装（${current_version}），跳过重复安装"
            log_info "如需更新到最新版，请执行：sudo ./${SCRIPT_NAME} --update"
            return 0
        fi
        log_info "Xray 已安装（${current_version}），执行更新..."
    else
        log_info "Xray 未安装，将直接安装最新版"
    fi

    log_info "正在从 ${XRAY_INSTALL_URL} 下载安装脚本..."

    local xray_install_content
    xray_install_content="$(curl -Ls --max-time 30 "${XRAY_INSTALL_URL}")"

    if [ -z "${xray_install_content}" ]; then
        log_error "下载 Xray 安装脚本失败，请检查网络连接"
        return 1
    fi
    log_ok "安装脚本下载成功（大小：${#xray_install_content} 字节）"

    log_info "正在执行安装脚本（install 模式）..."
    if echo "${xray_install_content}" | sudo bash -s -- install 2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Xray 安装脚本已成功执行完毕"
        return 0
    else
        log_error "Xray 安装过程中出现错误"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 获取随机空闲端口
# ------------------------------------------------------------------------------
get_free_port() {
    local port
    local max_retries=50
    local retry=0

    while [ "${retry}" -lt "${max_retries}" ]; do
        port="$(shuf -i 1024-65535 -n 1)"
        if ! ss -tuln | grep -q ":${port} "; then
            echo "${port}"
            return 0
        fi
        retry=$((retry + 1))
    done

    log_error "尝试 ${max_retries} 次后仍未找到空闲端口"
    return 1
}

# ------------------------------------------------------------------------------
# 生成 VLESS + Reality 配置
# ------------------------------------------------------------------------------
create_vless_reality_config() {
    cat <<EOF
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "privateKey": "${PRIV_KEY}",
          "shortIds": ["${SHORT_ID}"],
          "serverNames": ["${DEFAULT_SNI}"],
          "target": "${DEFAULT_SNI}:443"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
}

# ------------------------------------------------------------------------------
# 配置 Xray
# ------------------------------------------------------------------------------
configure_xray() {
    log_section "生成 Xray 配置"

    if ! command -v xray >/dev/null 2>&1; then
        log_error "未找到 xray 命令，请确认 Xray 是否已安装成功"
        return 1
    fi

    # 生成 UUID
    UUID="$(xray uuid)"
    if [ -z "${UUID}" ]; then
        log_error "生成 UUID 失败"
        return 1
    fi
    log_info "生成 UUID：${UUID}"

    # 生成 x25519 密钥对
    # xray x25519 输出格式（Xray-core ≥1.8）：
    #   Private key: <base64> Public key: <base64> Hash32: <base64>
    #                $2                   $5                $7
    local x25519_output
    x25519_output="$(xray x25519)"
    # shellcheck disable=SC2086
    PRIV_KEY="$(echo $x25519_output | awk '{print $2}')"
    # shellcheck disable=SC2086
    PUB_KEY="$(echo $x25519_output | awk '{print $5}')"
    # shellcheck disable=SC2086
    HASH32="$(echo $x25519_output | awk '{print $7}')"

    if [ -z "${PRIV_KEY}" ] || [ -z "${PUB_KEY}" ]; then
        log_error "生成 x25519 密钥对失败，原始输出：${x25519_output}"
        return 1
    fi
    log_info "生成 Private Key：${PRIV_KEY}"
    log_info "生成 Public Key： ${PUB_KEY}"
    [ -n "${HASH32}" ] && log_info "生成 Hash32：     ${HASH32}"

    # 生成随机 shortId（固定 16 位十六进制 = 8 字节）
    SHORT_ID="$(openssl rand -hex 8)"
    if [ -z "${SHORT_ID}" ]; then
        log_error "生成随机 shortId 失败"
        return 1
    fi
    log_info "生成 Short ID：${SHORT_ID}"

    # 获取空闲端口
    PORT="$(get_free_port)" || return 1
    log_info "分配空闲端口：${PORT}"

    # 写入配置
    log_info "写入配置文件：${CONFIG_PATH}"

    if ! create_vless_reality_config | sudo tee "${CONFIG_PATH}" >/dev/null; then
        log_error "写入配置文件失败：${CONFIG_PATH}"
        return 1
    fi
    log_ok "配置文件写入成功"

    return 0
}

# ------------------------------------------------------------------------------
# 重启 Xray 服务
# ------------------------------------------------------------------------------
restart_xray() {
    log_section "重启 Xray 服务"

    if sudo systemctl restart xray 2>&1 | tee -a "${LOG_FILE}"; then
        sleep 1
        if sudo systemctl is-active --quiet xray; then
            log_ok "Xray 服务已成功启动"
            return 0
        else
            log_error "Xray 服务启动后状态异常"
            sudo systemctl status xray --no-pager 2>&1 | tee -a "${LOG_FILE}"
            return 1
        fi
    else
        log_error "重启 Xray 服务失败"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 获取服务器出口 IP
# ------------------------------------------------------------------------------
get_server_ip() {
    local ip
    ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)"
    if [ -z "${ip}" ]; then
        ip="$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)"
    fi
    if [ -z "${ip}" ]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    echo "${ip}"
}

# ------------------------------------------------------------------------------
# 获取服务器所在国家代码（ISO 3166-1 alpha-2，如 US、JP、SG）
# ------------------------------------------------------------------------------
get_server_country() {
    local country
    # 优先使用 ipinfo.io（返回纯文本国家代码）
    country="$(curl -s --max-time 5 https://ipinfo.io/country 2>/dev/null)"
    if [ -z "${country}" ] || [ "${#country}" -gt 2 ]; then
        # 备选：ip-api.com（返回 JSON，提取 countryCode 字段）
        country="$(curl -s --max-time 5 'http://ip-api.com/json/?fields=countryCode' 2>/dev/null | awk -F'"' '/countryCode/{print $4}')"
    fi
    # 转为大写并验证格式（仅保留两位字母）
    country="$(echo "${country}" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z')"
    if [ "${#country}" -eq 2 ]; then
        echo "${country}"
    else
        echo "XX"  # 未知时使用占位符
    fi
}

# ------------------------------------------------------------------------------
# 构建 vless:// 链接（符合 XTLS / v2rayN 分享链接规范）
# ------------------------------------------------------------------------------
build_vless_link() {
    local server_ip
    server_ip="$(get_server_ip)"
    if [ -z "${server_ip}" ]; then
        log_warn "未能自动获取服务器 IP，链接中将使用占位符 YOUR_SERVER_IP"
        server_ip="YOUR_SERVER_IP"
    fi
    log_info "服务器 IP：${server_ip}"

    # 获取服务器所在国家
    local country
    country="$(get_server_country)"
    log_info "服务器国家：${country}"

    # URL-encode remark 中的不安全字符（仅处理空格和 #，IPv6 等场景未覆盖）
    local remark="${country}-Xray-Reality-${server_ip}"
    remark="${remark// /%20}"
    remark="${remark//#/%23}"

    # 参数说明：
    #   - encryption=none        VLESS 协议固定值
    #   - flow=xtls-rprx-vision  Reality 使用的 flow（Xray-core ≤1.8.x）
    #   - security=reality       启用 Reality
    #   - sni=${DEFAULT_SNI}     TLS SNI，必须与 serverNames 一致
    #   - fp=chrome              uTLS 指纹（推荐 chrome）
    #   - pbk=${PUB_KEY}         Reality 公钥
    #   - sid=${SHORT_ID}        shortId，与配置中 shortIds 数组的值对应
    #   - spx=%2F                SpiderX 路径，默认 "/"（URL 编码为 %2F）
    #   - type=tcp               传输层为 TCP
    # 注意：TCP + Reality 场景下不要添加 headerType=none，部分客户端会误判为伪装头
    VLESS_LINK="vless://${UUID}@${server_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEFAULT_SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&spx=%2F&type=tcp#${remark}"

    # 生成 BASE64 编码版本（兼容不支持长链接的客户端/场景）
    VLESS_LINK_BASE64="$(echo -n "${VLESS_LINK}" | base64 -w 0)"
}

# ------------------------------------------------------------------------------
# 从现有配置反向生成 vless:// 链接（--show-link 模式）
# 无需重新安装或生成密钥，直接从 config.json 中提取参数
# ------------------------------------------------------------------------------
show_link() {
    log_section "从现有配置读取连接参数"

    # 检查配置文件是否存在
    if [ ! -f "${CONFIG_PATH}" ]; then
        log_error "配置文件不存在：${CONFIG_PATH}"
        log_error "请先运行 sudo ./${SCRIPT_NAME} 完成安装"
        return 1
    fi

    # 检查 xray 命令（用于从私钥反推公钥）
    if ! command -v xray >/dev/null 2>&1; then
        log_error "未找到 xray 命令，无法从私钥计算公钥"
        return 1
    fi

    # 提取 UUID（第一个 client 的 id）
    UUID="$(grep -o '"id": *"[^"]*"' "${CONFIG_PATH}" | head -1 | awk -F'"' '{print $4}')"
    if [ -z "${UUID}" ]; then
        log_error "无法从配置文件中提取 UUID"
        return 1
    fi
    log_info "UUID：${UUID}"

    # 提取端口
    PORT="$(grep -o '"port": *[0-9]*' "${CONFIG_PATH}" | head -1 | awk '{print $2}')"
    if [ -z "${PORT}" ]; then
        log_error "无法从配置文件中提取端口"
        return 1
    fi
    log_info "端口：${PORT}"

    # 提取私钥
    PRIV_KEY="$(grep -o '"privateKey": *"[^"]*"' "${CONFIG_PATH}" | head -1 | awk -F'"' '{print $4}')"
    if [ -z "${PRIV_KEY}" ]; then
        log_error "无法从配置文件中提取 privateKey"
        return 1
    fi
    log_info "Private Key：${PRIV_KEY}"

    # 从私钥反推公钥（xray x25519 -i <privateKey>）
    local x25519_output
    x25519_output="$(xray x25519 -i "${PRIV_KEY}" 2>/dev/null)"
    PUB_KEY="$(echo "${x25519_output}" | grep -i "public" | awk '{print $NF}')"
    if [ -z "${PUB_KEY}" ]; then
        log_error "从私钥反推公钥失败，xray x25519 -i 输出：${x25519_output}"
        return 1
    fi
    log_info "Public Key：${PUB_KEY}"

    # 提取 shortId（取数组第一个值）
    SHORT_ID="$(grep -o '"shortIds": *\[[^]]*\]' "${CONFIG_PATH}" | grep -o '"[0-9a-fA-F]*"' | head -1 | tr -d '"')"
    if [ -z "${SHORT_ID}" ]; then
        log_error "无法从配置文件中提取 shortId"
        return 1
    fi
    log_info "Short ID：${SHORT_ID}"

    # 提取 SNI（serverNames 数组第一个值，回退到 DEFAULT_SNI）
    local sni
    sni="$(grep -o '"serverNames": *\[[^]]*\]' "${CONFIG_PATH}" | grep -o '"[^"]*"' | head -1 | tr -d '"')"
    if [ -z "${sni}" ]; then
        sni="${DEFAULT_SNI}"
        log_warn "未从配置提取到 SNI，使用默认值：${sni}"
    fi
    log_info "SNI：${sni}"

    # 构建并输出链接
    build_vless_link

    echo ""
    echo "=========================================="
    echo " VLESS 分享链接（复制下面整行导入客户端）"
    echo "=========================================="
    echo "${VLESS_LINK}"
    echo "=========================================="
    echo ""
    echo "=========================================="
    echo " VLESS 分享链接 - BASE64（适用于批量导入）"
    echo "=========================================="
    echo "${VLESS_LINK_BASE64}"
    echo "=========================================="
    echo ""
    log_ok "链接生成完毕（以上信息来自 ${CONFIG_PATH}）"

    return 0
}

# ------------------------------------------------------------------------------
# 打印连接信息摘要
# ------------------------------------------------------------------------------
print_summary() {
    build_vless_link

    log_section "安装完成 - 连接信息摘要"
    {
        echo "协议       : VLESS + Reality"
        echo "端口       : ${PORT}"
        echo "UUID       : ${UUID}"
        echo "Public Key : ${PUB_KEY}"
        echo "SNI / Dest : ${DEFAULT_SNI}"
        echo "Flow       : xtls-rprx-vision"
        echo "Fingerprint: chrome"
        echo "配置路径   : ${CONFIG_PATH}"
        echo "日志文件   : ${LOG_FILE}"
    } | tee -a "${LOG_FILE}"
    echo "------------------------------------------" | tee -a "${LOG_FILE}"

    # 输出 vless:// 链接
    echo "" | tee -a "${LOG_FILE}"
    echo "==========================================" | tee -a "${LOG_FILE}"
    echo " VLESS 分享链接（复制下面整行导入客户端）" | tee -a "${LOG_FILE}"
    echo "==========================================" | tee -a "${LOG_FILE}"
    echo "${VLESS_LINK}" | tee -a "${LOG_FILE}"
    echo "==========================================" | tee -a "${LOG_FILE}"
    echo "" | tee -a "${LOG_FILE}"
    echo "==========================================" | tee -a "${LOG_FILE}"
    echo " VLESS 分享链接 - BASE64（适用于批量导入）" | tee -a "${LOG_FILE}"
    echo "==========================================" | tee -a "${LOG_FILE}"
    echo "${VLESS_LINK_BASE64}" | tee -a "${LOG_FILE}"
    echo "==========================================" | tee -a "${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# 主函数
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"

    init_log
    log_section "Xray + Reality 自动安装脚本启动"
    log_info "脚本：${SCRIPT_NAME}"
    log_info "执行用户：$(whoami)"
    log_info "主机：$(hostname)"
    [ "${FLAG_UPDATE}" = true ] && log_info "模式：仅更新 Xray"
    [ "${FLAG_SHOW_LINK}" = true ] && log_info "模式：显示连接链接"

    # --show-link 模式：仅从已有配置中读取参数并输出链接
    if [ "${FLAG_SHOW_LINK}" = true ]; then
        if ! show_link; then
            log_error "链接生成失败"
            exit 1
        fi
        exit 0
    fi

    check_dependencies

    if ! install_xray; then
        log_error "Xray 安装失败，脚本终止"
        exit 1
    fi

    # --update 模式：只安装/更新，不做配置和重启
    if [ "${FLAG_UPDATE}" = true ]; then
        log_ok "Xray 更新完成"
        log_info "如需应用新配置，请手动执行：sudo systemctl restart xray"
        exit 0
    fi

    if ! configure_xray; then
        log_error "配置生成失败，脚本终止"
        exit 1
    fi

    if ! restart_xray; then
        log_error "服务启动失败，请检查日志：${LOG_FILE}"
        exit 1
    fi

    print_summary
    log_ok "全部流程执行成功"
}

# 错误陷阱（注意：未启用 set -e，此 trap 仅在非条件语句中的命令失败时触发）
trap 'log_error "脚本在第 ${LINENO} 行发生异常退出"' ERR

main "$@"
