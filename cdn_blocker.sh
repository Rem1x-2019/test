#!/bin/bash

# ==============================================================================
# CDN Blocker Script (Interactive Menu)
#
# 功能:
#   - 提供一个交互式菜单来管理CDN屏蔽规则。
#   - 从指定的来源获取Cloudflare, Fastly, 和 Akamai的IP地址范围。
#   - 生成'iptables'规则来阻止到这些IP范围的出站流量。
#   - 提供清空这些规则的选项。
#
# 使用方法:
#   1. 保存此脚本为 cdn_blocker.sh
#   2. 赋予执行权限: chmod +x cdn_blocker.sh
#   3. 直接运行脚本: sudo ./cdn_blocker.sh
#   4. 根据菜单提示进行选择。
#
# 警告:
#   执行此脚本会中断服务器对大量网站和服务的访问。请谨慎操作。
# ==============================================================================

# --- 配置区域 ---
# 定义CDN IP列表的URL
CLOUDFLARE_IPV4_URL="https://github.com/Loyalsoldier/geoip/raw/refs/heads/release/text/cloudflare.txt"
FASTLY_IPV4_URL="https://github.com/Loyalsoldier/geoip/raw/refs/heads/release/text/fastly.txt"
AKAMAI_IPV4_URL="https://raw.githubusercontent.com/SecOps-Institute/Akamai-ASN-and-IPs-List/refs/heads/master/akamai_ip_cidr_blocks_raw.lst"

# 定义iptables自定义链的名称
CHAIN_NAME="CDN_BLOCK"

# --- 功能函数 ---

# 函数：应用屏蔽规则
apply_rules() {
    echo "----------------------------------------"
    echo "开始应用CDN屏蔽规则..."

    # 检查并创建iptables链
    if ! sudo iptables -L $CHAIN_NAME -n > /dev/null 2>&1; then
        echo "创建新的iptables链: $CHAIN_NAME"
        sudo iptables -N $CHAIN_NAME
        sudo iptables -A OUTPUT -j $CHAIN_NAME
    else
        echo "iptables链 $CHAIN_NAME 已存在，将清空并重新应用规则。"
        sudo iptables -F $CHAIN_NAME
    fi
    
    echo "正在获取并应用Cloudflare的IP规则..."
    for ip in $(curl -sL $CLOUDFLARE_IPV4_URL); do
        sudo iptables -A $CHAIN_NAME -p all -d $ip -j DROP
    done

    echo "正在获取并应用Fastly的IP规则..."
    for ip in $(curl -sL $FASTLY_IPV4_URL); do
        sudo iptables -A $CHAIN_NAME -p all -d $ip -j DROP
    done
    
    echo "正在获取并应用Akamai的IP规则..."
    for ip in $(curl -sL $AKAMAI_IPV4_URL); do
        sudo iptables -A $CHAIN_NAME -p all -d $ip -j DROP
    done

    echo ""
    echo "✅ 所有CDN屏蔽规则已添加完毕！"
    echo "您可以使用 'sudo iptables -L $CHAIN_NAME' 来查看规则。"
    echo ""
    echo "重要：要让这些规则在系统重启后依然生效，请运行以下命令:"
    echo "  sudo apt-get update && sudo apt-get install -y iptables-persistent"
    echo "  sudo netfilter-persistent save"
    echo "----------------------------------------"
}

# 函数：清空并删除iptables链
flush_rules() {
    echo "----------------------------------------"
    echo "正在清空并删除iptables规则和链..."
    
    # 检查链是否存在
    if sudo iptables -L $CHAIN_NAME -n > /dev/null 2>&1; then
        # 从OUTPUT链中删除我们的自定义链跳转规则
        sudo iptables -D OUTPUT -j $CHAIN_NAME > /dev/null 2>&1
        # 清空自定义链中的所有规则
        sudo iptables -F $CHAIN_NAME > /dev/null 2>&1
        # 删除自定义链
        sudo iptables -X $CHAIN_NAME > /dev/null 2>&1
        echo "✅ 所有相关的CDN屏蔽规则已被移除。"
        echo "要使更改在重启后生效，请运行: sudo netfilter-persistent save"
    else
        echo "ℹ️ 未找到CDN_BLOCK链，无需操作。"
    fi
    echo "----------------------------------------"
}

# 函数：显示主菜单
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo "      CDN 屏蔽管理脚本"
        echo "========================================"
        echo "  1. 屏蔽 CDN (Cloudflare, Fastly, Akamai)"
        echo "  2. 解除对 CDN 的屏蔽"
        echo "  3. 退出脚本"
        echo "----------------------------------------"
        read -p "请输入您的选择 [1-3]: " choice

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
                echo "正在退出脚本。再见！"
                exit 0
                ;;
            *)
                echo "无效输入！请输入 1, 2, 或 3。"
                read -n 1 -s -r -p "按任意键重试..."
                ;;
        esac
    done
}

# --- 脚本主入口 ---
main_menu