#!/bin/bash

# ==============================================================================
# CDN Blocker Script (Interactive Menu) - IPSET Edition
#
# 功能:
#   - **新增**: 自动检测并安装依赖项 (curl, ipset)。
#   - **优化**: 使用ipset高效处理数万条IP规则，解决执行缓慢问题。
#   - 提供一个交互式菜单来管理CDN屏蔽规则。
#   - 从一个合并的来源获取CDN IP地址范围。
#   - 生成'iptables'规则来阻止到这些IP范围的出站流量。
#   - 提供清空这些规则的选项。
#   - 允许为特定端口添加高优先级放行规则。
#   - 自动为DNS(端口53)和DoH(端口443)添加高优先级放行规则。
#
# 使用方法:
#   1. 保存此脚本为 cdn_blocker.sh
#   2. 赋予执行权限: chmod +x cdn_blocker.sh
#   3. 直接运行脚本: sudo ./cdn_blocker.sh
#
# ==============================================================================

# --- 配置区域 ---
# 使用单一合并的CDN IP列表URL
CDN_IPS_URL="https://ccoff.com/sh/cdn_ips.txt"

# 定义iptables自定义链和ipset的名称
CHAIN_NAME="CDN_BLOCK"
IPSET_NAME="cdn_block_set"

# --- 功能函数 ---

# 函数：自动检测并安装依赖
check_and_install_dependencies() {
    local required_packages=("curl" "ipset")
    local missing_packages=()

    echo "----------------------------------------"
    echo "正在检查所需的依赖..."

    for pkg in "${required_packages[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo "警告：检测到以下缺失的依赖: ${missing_packages[*]}"
        read -p "是否要自动安装它们? (y/N): " choice
        case "$choice" in
            y|Y )
                echo "正在更新软件包列表并安装依赖..."
                sudo apt-get update
                sudo apt-get install -y "${missing_packages[@]}"
                # 验证安装是否成功
                for pkg in "${missing_packages[@]}"; do
                    if ! command -v "$pkg" &> /dev/null; then
                        echo "❌ 错误：安装 '$pkg' 失败。请手动安装后重试。"
                        exit 1
                    fi
                done
                echo "✅ 依赖安装成功。"
                ;;
            * )
                echo "❌ 操作已取消。请先手动安装缺失的依赖: ${missing_packages[*]}"
                exit 1
                ;;
        esac
    else
        echo "✅ 所有依赖均已安装。"
    fi
    echo "----------------------------------------"
    sleep 1
}


# 函数：应用屏蔽规则
apply_rules() {
    echo "----------------------------------------"
    echo "开始应用CDN屏蔽规则..."
    
    # --- 第1步：下载IP列表 ---
    echo "正在从 $CDN_IPS_URL 下载IP列表..."
    all_cdn_ips=$(curl -sL --connect-timeout 15 $CDN_IPS_URL)
    
    if [[ $all_cdn_ips == *"<html"* || -z "$all_cdn_ips" ]]; then
        echo "❌ 错误：无法下载或IP列表为空，操作已中止。"
        return 1
    fi
    echo "✅ IP列表下载成功。"

    # --- 第2步：使用 ipset 高效处理IP ---
    echo "正在应用防火墙规则..."
    # 检查并创建 ipset
    if ! sudo ipset list $IPSET_NAME > /dev/null 2>&1; then
        echo "创建新的 ipset: $IPSET_NAME"
        sudo ipset create $IPSET_NAME hash:net
    else
        echo "ipset $IPSET_NAME 已存在，将清空。"
        sudo ipset flush $IPSET_NAME
    fi

    echo "正在将IP地址批量添加到 $IPSET_NAME (此步骤速度很快)..."
    # 使用临时文件和ipset restore进行极速批量导入
    temp_file=$(mktemp)
    # 过滤掉非IPv4地址并写入临时文件
    echo "$all_cdn_ips" | grep '\.' > "$temp_file"
    # 格式化后通过restore命令导入
    sed 's/^/add cdn_block_set /' "$temp_file" | sudo ipset restore
    rm "$temp_file"

    # --- 第3步：应用iptables规则 ---
    # 检查并创建iptables链
    if ! sudo iptables -L $CHAIN_NAME -n > /dev/null 2>&1; then
        echo "创建新的iptables链: $CHAIN_NAME"
        sudo iptables -N $CHAIN_NAME
        sudo iptables -A OUTPUT -j $CHAIN_NAME
    else
        echo "iptables链 $CHAIN_NAME 已存在，将清空并重新应用规则。"
        sudo iptables -F $CHAIN_NAME
    fi
    
    # **FIX**: 在所有屏蔽规则之前，先为DNS和DoH添加高优先级放行规则
    echo "为DNS(端口53)和DoH(端口443)添加高优先级放行规则..."
    # 注意：规则插入顺序与生效顺序相反，最后插入的在最顶层
    sudo iptables -I OUTPUT 1 -p tcp --dport 443 -j ACCEPT
    sudo iptables -I OUTPUT 1 -p udp --dport 443 -j ACCEPT # 兼容QUIC等
    sudo iptables -I OUTPUT 1 -p tcp --dport 53 -j ACCEPT
    sudo iptables -I OUTPUT 1 -p udp --dport 53 -j ACCEPT
    
    # **IMPROVEMENT**: 使用单一iptables规则引用ipset
    echo "正在应用基于 ipset 的单一屏蔽规则..."
    sudo iptables -A $CHAIN_NAME -m set --match-set $IPSET_NAME dst -j DROP

    echo ""
    echo "✅ CDN屏蔽规则应用流程已完成！"
    echo "您可以使用 'sudo iptables -L OUTPUT --line-numbers' 和 'sudo ipset list $IPSET_NAME' 来查看规则。"
    echo ""
    echo "重要：要让这些规则在系统重启后依然生效，请运行:"
    echo "  sudo netfilter-persistent save"
    echo "----------------------------------------"
}

# 函数：清空并删除iptables链和ipset
flush_rules() {
    echo "----------------------------------------"
    echo "正在清空并删除所有CDN屏蔽规则..."
    
    if sudo iptables -L $CHAIN_NAME -n > /dev/null 2>&1; then
        while sudo iptables -D OUTPUT -j $CHAIN_NAME > /dev/null 2>&1; do :; done
        sudo iptables -F $CHAIN_NAME
        sudo iptables -X $CHAIN_NAME
        echo "✅ iptables规则链已被移除。"
    else
        echo "ℹ️ 未找到CDN_BLOCK链，无需操作。"
    fi

    if sudo ipset list $IPSET_NAME > /dev/null 2>&1; then
        sudo ipset destroy $IPSET_NAME
        echo "✅ ipset集合 '$IPSET_NAME' 已被销毁。"
    fi

    echo "提示：此操作不会移除您手动添加的端口放行规则。"
    echo "您可以使用 'sudo iptables -L OUTPUT --line-numbers' 查看并手动删除。"
    echo "----------------------------------------"
}

# 函数：为指定端口添加放行规则
allow_port() {
    echo "----------------------------------------"
    read -p "请输入您需要放行的端口号 (例如 2000): " port
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "❌ 错误：无效的端口号。"
        return
    fi
    
    echo "正在为端口 $port 添加高优先级放行规则..."
    sudo iptables -I OUTPUT 1 -p tcp --dport $port -j ACCEPT
    sudo iptables -I OUTPUT 1 -p tcp --sport $port -j ACCEPT
    
    echo "✅ 成功为端口 $port 添加放行规则。"
    echo "请记得运行 'sudo netfilter-persistent save' 来持久化保存此规则。"
    echo "----------------------------------------"
}


# 函数：显示主菜单
main_menu() {
    if [ "$EUID" -ne 0 ]; then
        echo "❌ 错误：此脚本需要root权限运行，请使用 'sudo ./cdn_blocker.sh'"
        exit 1
    fi

    # 自动检测并安装依赖
    check_and_install_dependencies

    while true; do
        clear
        echo "========================================"
        echo "      CDN 屏蔽管理脚本 (ipset 高效版)"
        echo "========================================"
        echo "  1. 屏蔽 CDN"
        echo "  2. 解除对 CDN 的屏蔽"
        echo "  3. 放行指定端口 (节点端口)"
        echo "  4. 退出脚本"
        echo "----------------------------------------"
        read -p "请输入您的选择 [1-4]: " choice

        case $choice in
            1)
                apply_rules
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            2)
                flush_rules
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            3)
                allow_port
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            4)
                echo "正在退出脚本。再见！"
                exit 0
                ;;
            *)
                echo "无效输入！请输入 1, 2, 3, 或 4。"
                read -n 1 -s -r -p "按任意键重试..."
                ;;
        esac
    done
}

# --- 脚本主入口 ---
main_menu
