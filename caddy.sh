#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Caddy 核心管理脚本 (L4 分流增强版 v7.5)
# ==========================================
SCRIPT_VERSION="7.5"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_BIN="/usr/bin/caddy"
SERVICE_FILE="/etc/systemd/system/caddy.service"
SHORTCUT="/usr/local/bin/c"

# GitHub 仓库信息
REPO_URL="https://github.com/Tangfffyx/custom-caddy"
SCRIPT_URL="https://raw.githubusercontent.com/Tangfffyx/custom-caddy/refs/heads/main/caddy.sh"

# 颜色定义
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
NC='\033[0m'

# ==========================================
# 基础工具函数
# ==========================================

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}[错误] 请使用 root 权限运行${NC}"
    exit 1
  fi
}

# 修复系统 sudo 无法解析主机名的警告 (自愈功能)
fix_hostname_resolve() {
  local current_hostname
  current_hostname=$(hostname 2>/dev/null || true)
  if [[ -n "$current_hostname" ]] && ! grep -q -w "${current_hostname}" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 ${current_hostname}" >> /etc/hosts 2>/dev/null || true
  fi
}

pause_return_menu() {
  echo
  read -r -n 1 -s -p "按任意键返回上一级菜单..."
  echo
}

backup_caddyfile() {
  [[ -f "${CADDYFILE}" ]] || return 0
  local dir; dir="$(dirname "${CADDYFILE}")"
  find "${dir}" -maxdepth 1 -name "Caddyfile.bak.*" -type f -delete 2>/dev/null
  cp "${CADDYFILE}" "${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
}

apply_config() {
  $CADDY_BIN fmt --overwrite "${CADDYFILE}" >/dev/null 2>&1

  echo -e "${YEL}[校验] 正在检查配置语法...${NC}"
  if ! $CADDY_BIN validate --config "${CADDYFILE}"; then
    echo -e "${RED}[错误] 配置文件校验失败，请检查！${NC}"
    return 1
  fi
  systemctl restart caddy >/dev/null 2>&1 || true
  if systemctl is-active caddy >/dev/null 2>&1; then
    echo -e "${GRN}[成功] Caddy 已成功加载新配置！${NC}"
  else
    echo -e "${RED}[错误] Caddy 启动失败，请检查日志。${NC}"
    return 1
  fi
}

check_domain_exists() {
  local domain="$1"
  if grep -q "# --- \[DOMAIN: ${domain}\] ---" "${CADDYFILE}"; then
    echo -e "${RED}[警告] 域名/SNI [${domain}] 已存在，请先删除旧配置或使用其他域名。${NC}"
    pause_return_menu
    return 1
  fi
  return 0
}

# ==========================================
# 初始化与系统服务配置
# ==========================================

init_caddyfile_skeleton() {
  mkdir -p /etc/caddy
  mkdir -p /var/log/caddy
  cat << 'EOF' > "${CADDYFILE}"
{
    log {
        level WARN
        output file /var/log/caddy/caddy.log {
            roll_size 10MB
            roll_keep 1
        }
    }
    layer4 {
        :443 {
            # === [L4 RULES BEGIN] ===
            # === [L4 RULES END] ===
        }
    }
}

# === [L7 CONFIGS BEGIN] ===
# === [L7 CONFIGS END] ===
EOF
  chmod 644 "${CADDYFILE}"
}

init_systemd_service() {
  cat << 'EOF' > "${SERVICE_FILE}"
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# ==========================================
# 核心业务功能
# ==========================================

option_install() {
  echo -e "${YEL}正在连接 GitHub 获取最新版本信息...${NC}"
  local latest_tag
  latest_tag=$(curl -sLs -o /dev/null -w %{url_effective} "${REPO_URL}/releases/latest" | grep -o '[^/]*$')
  
  if [[ -z "$latest_tag" ]]; then
    echo -e "${RED}[错误] 获取最新版本失败，请检查网络！${NC}"
    pause_return_menu; return
  fi
  
  echo -e "最新可用版本: ${BLU}${latest_tag}${NC}"

  if [[ -f "${CADDY_BIN}" ]]; then
    local current_tag
    current_tag=$(${CADDY_BIN} version 2>/dev/null | awk '{print $1}')
    if [[ "$current_tag" == "$latest_tag" ]]; then
      echo -e "${GRN}[提示] 当前安装的已经是最新版本 (${current_tag})，无需重复更新！${NC}"
      pause_return_menu; return
    fi
    echo -e "准备升级: ${YEL}${current_tag:-未知} -> ${latest_tag}${NC}"
  fi

  local arch
  arch=$(uname -m)
  local download_url=""

  if [[ "$arch" == "x86_64" ]]; then
    download_url="${REPO_URL}/releases/download/${latest_tag}/caddy-linux-amd64"
  elif [[ "$arch" == "aarch64" ]]; then
    download_url="${REPO_URL}/releases/download/${latest_tag}/caddy-linux-arm64"
  else
    echo -e "${RED}[错误] 不支持的架构: $arch${NC}"
    pause_return_menu; return
  fi

  systemctl stop caddy 2>/dev/null || true
  echo -e "正在下载: ${download_url}"
  if ! wget -O "${CADDY_BIN}" "${download_url}"; then
    echo -e "${RED}[错误] 下载失败，请检查网络或 URL 是否有效！${NC}"
    pause_return_menu; return
  fi

  chmod +x "${CADDY_BIN}"
  
  if [[ ! -f "${SERVICE_FILE}" ]]; then init_systemd_service; fi
  if [[ ! -f "${CADDYFILE}" ]]; then init_caddyfile_skeleton; fi

  systemctl enable --now caddy
  
  echo -e "${GRN}[成功] 自定义 Caddy 安装/更新完成！${NC}"
  echo -e "当前运行版本: ${BLU}$($CADDY_BIN version | awk '{print $1}')${NC}"
  
  pause_return_menu
}

option_add_proxy() {
  echo
  echo ">>> 请选择流量模式："
  echo "1. L4 纯透传 (443端口按SNI分流)"
  echo "2. L7 七层反代 (网站 / 面板 / WS)"
  read -r -p "请选择 [1-2]: " mode
  if [[ "$mode" != "1" && "$mode" != "2" ]]; then echo -e "${RED}[警告] 无效选项！${NC}"; pause_return_menu; return; fi

  local domain target note tmp_l4 tmp_l7 clean_domain
  tmp_l4=$(mktemp)
  tmp_l7=$(mktemp)

  if [[ "$mode" == "1" ]]; then
    read -r -p "请输入 SNI 伪装域名: " domain
    [[ -z "${domain}" ]] && { echo -e "${RED}[警告] 输入不能为空！${NC}"; pause_return_menu; return; }
    
    read -r -p "请输入后端本地端口: " target
    [[ -z "${target}" ]] && { echo -e "${RED}[警告] 输入不能为空！${NC}"; pause_return_menu; return; }
    
    read -r -p "请输入备注 (可选): " note
    
    check_domain_exists "$domain" || return
    backup_caddyfile
    clean_domain=$(echo "$domain" | tr '.' '_')

    cat << EOF > "$tmp_l4"
            # --- [DOMAIN: ${domain}] ---
            @l4_${clean_domain} tls sni ${domain}
            route @l4_${clean_domain} {
                proxy 127.0.0.1:${target}
            }
            # --- [/DOMAIN: ${domain}] ---
EOF
    sed -i "/# === \[L4 RULES BEGIN\] ===/r $tmp_l4" "${CADDYFILE}"

  elif [[ "$mode" == "2" ]]; then
    echo
    echo ">>> 请选择反代模板："
    echo "1. 普通反代"
    echo "2. WebSocket 反代"
    echo "3. 反代他人服务 (传透真实IP与Host)"
    read -r -p "请选择 [1-3]: " l7_mode
    if [[ "$l7_mode" != "1" && "$l7_mode" != "2" && "$l7_mode" != "3" ]]; then echo -e "${RED}[警告] 无效选项！${NC}"; pause_return_menu; return; fi

    read -r -p "请输入域名 (如 www.example.com): " domain
    [[ -z "${domain}" ]] && { echo -e "${RED}[警告] 输入不能为空！${NC}"; pause_return_menu; return; }
    
    read -r -p "请输入反代目标 (如 127.0.0.1:5000 或 www.example.com): " target
    [[ -z "${target}" ]] && { echo -e "${RED}[警告] 输入不能为空！${NC}"; pause_return_menu; return; }

    # 智能补全：如果输入的是纯数字端口，自动拼接 127.0.0.1:
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      target="127.0.0.1:${target}"
    fi
    
    local ws_path=""
    if [[ "$l7_mode" == "2" ]]; then
      read -r -p "请输入 WebSocket 路径 (如 /ws): " ws_path
      if [[ -z "${ws_path}" || ! "$ws_path" =~ ^/ ]]; then 
        echo -e "${RED}[警告] 路径不能为空且必须以 / 开头！${NC}"; pause_return_menu; return
      fi
    fi

    read -r -p "请输入备注 (可选): " note
    
    check_domain_exists "$domain" || return
    backup_caddyfile
    clean_domain=$(echo "$domain" | tr '.' '_')

    cat << EOF > "$tmp_l4"
            # --- [DOMAIN: ${domain}] ---
            @l7_${clean_domain} tls sni ${domain}
            route @l7_${clean_domain} {
                proxy 127.0.0.1:8443
            }
            # --- [/DOMAIN: ${domain}] ---
EOF
    sed -i "/# === \[L4 RULES BEGIN\] ===/r $tmp_l4" "${CADDYFILE}"

    echo "# --- [DOMAIN: ${domain}] ---" > "$tmp_l7"
    [[ -n "$note" ]] && echo "# 备注: ${note}" >> "$tmp_l7"
    echo "${domain}:8443 {" >> "$tmp_l7"
    
    if [[ "$l7_mode" == "1" ]]; then
        echo "    reverse_proxy ${target}" >> "$tmp_l7"
    elif [[ "$l7_mode" == "2" ]]; then
        echo "    reverse_proxy ${ws_path} ${target} {" >> "$tmp_l7"
        echo "        header_up Host {host}" >> "$tmp_l7"
        echo "        header_up X-Real-IP {remote}" >> "$tmp_l7"
        echo "    }" >> "$tmp_l7"
    elif [[ "$l7_mode" == "3" ]]; then
        echo "    reverse_proxy ${target} {" >> "$tmp_l7"
        echo "        header_up Host {upstream_hostport}" >> "$tmp_l7"
        echo "        header_up X-Real-IP {remote}" >> "$tmp_l7"
        echo "    }" >> "$tmp_l7"
    fi
    echo "}" >> "$tmp_l7"
    echo "# --- [/DOMAIN: ${domain}] ---" >> "$tmp_l7"
    echo "" >> "$tmp_l7"
    
    sed -i "/# === \[L7 CONFIGS BEGIN\] ===/r $tmp_l7" "${CADDYFILE}"
  fi

  rm -f "$tmp_l4" "$tmp_l7"
  apply_config || rollback_caddyfile_silent
  pause_return_menu
}

option_delete_domain() {
  [[ ! -f "${CADDYFILE}" ]] && return
  mapfile -t domains < <(grep -oP '(?<=# --- \[DOMAIN: ).*(?=\] ---)' "${CADDYFILE}" | sort -u)
  
  if [[ ${#domains[@]} -eq 0 ]]; then
    echo -e "${YEL}当前无任何配置规则。${NC}"
    pause_return_menu; return
  fi

  echo -e "${BLU}>>> 当前规则列表:${NC}"
  for i in "${!domains[@]}"; do printf " %d) %s\n" "$((i+1))" "${domains[$i]}"; done
  
  read -r -p "请输入要删除的编号 (0 取消): " idx
  if [[ -z "$idx" || "$idx" == "0" ]]; then return; fi

  if (( idx>=1 && idx<=${#domains[@]} )); then
    local d="${domains[$((idx-1))]}"
    backup_caddyfile
    sed -i "/# --- \[DOMAIN: ${d}\] ---/,/# --- \[\/DOMAIN: ${d}\] ---/d" "${CADDYFILE}"
    echo -e "${GRN}[成功] 已删除 ${d} 的所有关联配置。${NC}"
    apply_config || rollback_caddyfile_silent
  else
    echo -e "${RED}[警告] 无效编号！${NC}"
  fi
  pause_return_menu
}

option_view_logs() {
  local log_file="/var/log/caddy/caddy.log"
  
  if [[ ! -f "${log_file}" ]]; then
    echo -e "${YEL}[提示] 日志文件尚未生成 (可能还没有错误或被拦截的请求产生)。${NC}"
    pause_return_menu
    return
  fi

  echo -e "${YEL}正在查看实时日志，按 Ctrl + C 退出${NC}"
  echo "------------------------------------------------------"
  
  trap 'echo -e "\n${GRN}[退出] 已切回主菜单。${NC}"; sleep 0.5' INT
  tail -n 10 -f "${log_file}" || true
  trap - INT
}

rollback_caddyfile_silent() {
  local dir; dir="$(dirname "${CADDYFILE}")"
  local bak; bak="$(find "${dir}" -maxdepth 1 -name "Caddyfile.bak.*" -type f -print -quit)"
  if [[ -n "${bak}" ]]; then cp -f "${bak}" "${CADDYFILE}"; systemctl reload caddy >/dev/null 2>&1 || true; fi
}

option_rollback() {
  local dir; dir="$(dirname "${CADDYFILE}")"
  local bak; bak="$(find "${dir}" -maxdepth 1 -name "Caddyfile.bak.*" -type f -print -quit)"
  if [[ -z "${bak}" ]]; then echo -e "${YEL}[提示] 未找到备份文件。${NC}"; pause_return_menu; return; fi
  
  echo -e "找到备份文件：${bak}"
  echo -e "${RED}【警告】回滚将覆盖当前正在运行的配置，并重启 Caddy 服务。${NC}"
  read -r -p "是否确认回滚？[y/N]: " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    cp -f "${bak}" "${CADDYFILE}"
    echo -e "${GRN}回滚完成！${NC}"
    apply_config
  else
    echo "已取消。"
  fi
  pause_return_menu
}

option_reset() {
  echo -e "${RED}【警告】这将清空所有配置并恢复初始 L4 框架。${NC}"
  read -r -p "是否确认重置？[y/N]: " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    backup_caddyfile
    init_caddyfile_skeleton
    echo -e "${GRN}已重置为初始骨架（包含自动轮转 WARN 日志配置）！${NC}"
    apply_config
  else
    echo "已取消。"
  fi
  pause_return_menu
}

option_uninstall() {
  echo -e "${RED}【警告】这将停止服务、彻底删除 Caddy 及所有配置文件。${NC}"
  read -r -p "是否确认卸载？[y/N]: " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true
    rm -f "${CADDY_BIN}"
    rm -rf /etc/caddy
    rm -rf /var/log/caddy
    rm -f "${SERVICE_FILE}"
    rm -f "${SHORTCUT}"
    systemctl daemon-reload
    echo -e "${GRN}[成功] Caddy 已被彻底粉碎清理，快捷键 'c' 已失效！${NC}"
    exit 0
  else
    echo "已取消。"
    pause_return_menu
  fi
}

show_menu() {
  clear
  echo -e "${BLU}=== Caddy 管理脚本 (L4分流版 v${SCRIPT_VERSION}) ===${NC}"
  echo "1) 安装/升级 Caddy"
  echo "2) 添加/更新 反代规则"
  echo "3) 删除 域名规则"
  echo "4) 查看 配置内容"
  echo "5) 查看 实时日志"
  echo "6) 回滚 上一份配置"
  echo "7) 重置 Caddyfile"
  echo "8) 卸载 Caddy"
  echo "0) 退出"
  echo -n "请选择 [0-8]: "
}

setup_shortcut() {
  if [[ "$0" != "${SHORTCUT}" ]]; then
    if curl -fsSL "${SCRIPT_URL}" -o "${SHORTCUT}" 2>/dev/null; then
      chmod +x "${SHORTCUT}" 2>/dev/null || true
      echo -e "${GRN}[提示] 全局快捷键 'c' 已更新至 v${SCRIPT_VERSION}。${NC}"
      sleep 1
    fi
  fi
}

main() {
  need_root
  fix_hostname_resolve
  setup_shortcut
  while true; do
    show_menu
    read -r choice || exit 0
    case "$choice" in
      1) option_install ;;
      2) option_add_proxy ;;
      3) option_delete_domain ;;
      4) cat "${CADDYFILE}"; pause_return_menu ;;
      5) option_view_logs ;;
      6) option_rollback ;;
      7) option_reset ;;
      8) option_uninstall ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
  done
}

main "$@"
