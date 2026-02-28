#!/usr/bin/env bash
# set -o errexit
set -o nounset
set -o pipefail
#############################################################
#
# ddnsupdate v1.0.0
# Dynamic DNS using Cloudflare
# Author: ifeng, <https://t.me/HiaiFeng>
# Usage: https://www.hicairo.com/post/61.html
#
#############################################################

# 使用单独的配置文件保存配置
# 注意文件权限配置
CONFIG_FILE="/path/to/ddns_update.conf"

# ---------------- 日志颜色定义 ----------------
readonly COLOR_RESET='\e[0m'
readonly COLOR_RED='\e[31m'
readonly COLOR_GREEN='\e[32m'
readonly COLOR_YELLOW='\e[33m'
readonly COLOR_BLUE='\e[34m'

# 核心打印函数
# 用法: msg <类型> <内容>
msg() {
    local type=$1
    local color=""
    case "$type" in
        "success") color=$COLOR_GREEN  ;;
        "error")   color=$COLOR_RED    ;;
        "warn")    color=$COLOR_YELLOW ;;
        "info")    color=$COLOR_BLUE   ;;
    esac
    # ${type^^} 会将类型转为大写，%-10s 保证标签对齐
    printf "%b%-10s%b %s\n" "$color" "[${type^^}]" "$COLOR_RESET" "$2"
}

# 检查配置文件
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    msg error "请确认配置文件路径是否正确"
    exit 1
fi

# 检查配置文件变量和系统命令
check_config_and_commands() {
    local error_exit="0"

    # 检查 CloudFlare 变量
    for var in "Cloudflare_Zone_ID" "Cloudflare_API_Tokens" "Domain_Record" "gateway"; do
        if [[ -z "${!var:-}" ]]; then
            msg error "conf: 请填写 $var"
            error_exit="1"
        fi
    done

    # 检查布尔变量
    for var in "ipv6_temporary" "ipv6_detect_retry"; do
        if [[ "${!var}" != "true" && "${!var}" != "false" ]]; then
            msg error "conf: $var 必须为 true/false"
            error_exit="1"
        fi
    done

    # 检查数字变量
    for var in "ipapi_max_retries" "retry_limit" "start_delay" "ip_check_delay" ; do
        if [[ ! "${!var}" =~ ^[0-9]+$ ]]; then
            msg error "conf: $var 必须是数字"
            error_exit="1"
        fi
    done

    # 检查所需系统命令
    for cms in "ip" "sleep" "curl" "jq"; do
        if ! command -v "$cms" &> /dev/null; then
            msg error "命令${cms}未找到"
            error_exit="1"
        fi
    done

    # 检查填写的网卡接口是否存在 (仅在填写了该项时检查)
    for var in "ipv4_nic" "ipv6_nic"; do
        local nic="${!var:-}"
        if [[ -n "$nic" ]] && [[ ! -d "/sys/class/net/$nic" ]]; then
            msg error "conf: $var: 网卡接口 '$nic' 不存在！"
            msg info  "conf: $var: 系统当前可用网卡: [ $(ls /sys/class/net/ | tr '\n' ' ')]"
            error_exit="1"
        fi
    done

    # 等检查完以上所有错误再退出进程
    if [[ "$error_exit" == "1" ]]; then
        exit 1
    fi
}

check_config_and_commands

# --- 变量初始化 ---
retry_count=0
ipv4_update_retry="false"
ipv6_update_retry="false"
readonly tmp_ip_check_delay=$ip_check_delay
readonly tmp_ipv6_temporary=$ipv6_temporary

IPv4=""
IPv6=""
IPv4_IsLAN="-1"
IPv6_IsLAN="-1"
New_IP=""
# -----------------

# 使用ping测试网关
gateway_test() {
    if ! ping -c 2 "$gateway" &> /dev/null; then
        if ! ping -c 5 "$gateway" &> /dev/null; then
            msg info "网关无法连接"
            return 1
        fi
    fi
    return 0
}

# 为了防止网络尚未完全启动而造成获取 IP 失败，延迟 $start_delay 秒执行
msg info "延迟${start_delay}秒执行"
sleep $start_delay

# 等待网关ping通
until gateway_test; do
    ((retry_count++))
    if((retry_count > retry_limit)); then
        msg error "网关仍然无法连接，退出进程"
        exit 1
    fi

    msg info "等待网关就绪……"
    sleep 30
done
retry_count=0

# 获取路由器/光猫的公网 IP
# (by Gemini)
curl_ip() {
    local version=$1
    local api_urls
    local target_var=""
    local ip_get=""

    # 1. 确定使用哪个列表和变量
    if [[ "$version" == "4" ]]; then
        api_urls=("${api_v4_list[@]}") # 获取 IPv4 数组
        target_var="IPv4"
    elif [[ "$version" == "6" ]]; then
        api_urls=("${api_v6_list[@]}") # 获取 IPv6 数组
        target_var="IPv6"
    else
        msg error "curl_ip: 错误的 IP 版本参数"
        return 1
    fi

    # 2. 外层循环：遍历每一个 API
    for url in "${api_urls[@]}"; do

        # 3. 内层循环：每个 API 重试 ipapi_max_retries 次
        for ((i=1; i<=ipapi_max_retries; i++)); do

            # 日志：显示当前尝试的 API 和次数
            msg info "正在通过 $url 获取 IPv$version (尝试 $i/$ipapi_max_retries)..."

            # 执行 curl
            # -s: 静默
            # -m 5: 超时5秒 (重试多，单次超时要设短一点)
            # jq -r .ip: 提取 ip 字段
            ip_get=$(curl -s${version} -m 5 "$url" -k | jq -r '.ip' 2>/dev/null)

            # 4. 校验结果
            # 必须非空且不等于 "null"
            if [[ -n "$ip_get" ]] && [[ "$ip_get" != "null" ]]; then
                msg info "成功！IP: $ip_get"

                # 赋值给全局变量 (IPv4 或 IPv6)
                printf -v "$target_var" "%s" "$ip_get"
                return 0 # 彻底成功，跳出所有循环
            else
                msg warn "失败"
                # 如果不是最后一次尝试，则等待2秒再试
                if (( i < ipapi_max_retries )); then
                    sleep 2
                fi
            fi
        done

        msg warn "该 API 重试 $ipapi_max_retries 次均失败，切换 API..."
    done

    # 5. 所有 API 都试完了还是失败
    msg error "严重错误：所有 IPv$version API 均无法获取 IP！"
    printf -v "$target_var" "" # 清空变量
    return 1
}

# 获取所有有效的 ipv4 地址
sys_ipv4() {
    ip -4 -j addr show ${ipv4_nic:-} 2>/dev/null | jq -r '.[].addr_info[] | select(.scope == "global" and (.deprecated | not)) | .local' 2>/dev/null
}

# 获取有效时间最大的有效 ipv6 地址
# 无法/无需获取临时地址时使用
sys_ipv6_able() {
    ip -6 -j addr show ${ipv6_nic:-} 2>/dev/null | jq -r '[.[].addr_info[] | select(.scope == "global" and (.deprecated | not))] | max_by(.valid_life_time) | .local' 2>/dev/null
}

# 当开启 ipv6_temporary 时，获取有效时间最大的有效 ipv6 临时地址
sys_ipv6() {
    if [[ "$ipv6_temporary" == "true" ]]; then
        ip -6 -j addr show ${ipv6_nic:-} 2>/dev/null | jq -r '[.[].addr_info[] | select(.scope == "global" and .temporary and (.deprecated | not))] | max_by(.valid_life_time) | .local' 2>/dev/null
    else
        sys_ipv6_able
    fi
}

# 辅助显示函数
is_wan() {
    msg success "路由器/光猫 PPPoE 获取的 IPv${1} 地址为公网IP!"
    printf -v "IPv${1}_IsLAN" "0"
}

is_lan() {
    msg warn "路由器/光猫 PPPoE 获取的 IPv${1} 地址为私网IP!"
    printf -v "IPv${1}_IsLAN" "1"
}


# 判断路由器/光猫拨号获取的 IP 地址是公网 IP 还是私网 IP , 如果 IPv4/IPv6 某项为空,说明是单栈
detect_lan_or_wan() {
    if [ -n "$IPv4" ]; then
        if [[ "$(sys_ipv4)" != *"$IPv4"* ]]; then
            is_lan 4
        else
            is_wan 4
        fi
    else
        msg warn "无法通过 API 获取到 IPv4 地址!"
        IPv4_IsLAN="-1"
        # exit 1
    fi

    if [ -n "$IPv6" ]; then
        if [[ "$(sys_ipv6)" != "$IPv6" ]]; then
            # 无法获取临时地址时使用
            if [[ "$(sys_ipv6_able)" != "$IPv6" ]]; then
                is_lan 6
            else
                is_wan 6
            fi
        else
            is_wan 6
        fi
    else
        msg warn "无法通过 API 获取到 IPv6 地址!"
        IPv6_IsLAN="-1"
    fi
}

# 检查与 CF 的连接
check_CF() {
    cat << EOF | curl -s -m 10 -K -
request = GET
url = "$Record_Info_Api"
header = "Authorization: Bearer $Cloudflare_API_Tokens"
header = "Content-Type:application/json"
EOF
}

# 添加域名
add_domain() {
    cat << EOF | curl -s -m 10 -K -
request = POST
url = "$Create_Record_Api"
header = "Authorization: Bearer $Cloudflare_API_Tokens"
header = "Content-Type:application/json"
data = "{\"type\":\"$Record_Type\",\"name\":\"$Domain_Record\",\"content\":\"$New_IP\",\"proxied\":false}"
EOF
}

# 更新域名 DNS 记录
dns_update() {
    cat << EOF | curl -s -m 10 -K -
request = PUT
url = "${Create_Record_Api}/${Record_Id}"
header = "Authorization: Bearer $Cloudflare_API_Tokens"
header = "Content-Type:application/json"
data = "{\"type\":\"$Record_Type\",\"name\":\"$Domain_Record\",\"content\":\"$New_IP\",\"proxied\":$Record_Proxy}"
EOF
}

# 设置是否需要尝试更新IP
# 输入参数为 true / false
update_Retry_Set() {
    if [[ "$Record_Type" == "A" ]]; then
        ipv4_update_retry="$1"
    fi

    if [[ "$Record_Type" == "AAAA" ]]; then
        ipv6_update_retry="$1"
    fi
}

# 核心更新逻辑
update_IP() {
    Create_Record_Api="https://api.cloudflare.com/client/v4/zones/${Cloudflare_Zone_ID}/dns_records"
    Record_Info_Api="${Create_Record_Api}?type=${Record_Type}&name=${Domain_Record}"

    Record_Info=$(check_CF)
    Record_Info_Success=$(echo "$Record_Info" | jq -r ".success")

    # 尝试重连$retry_limit次，大于直接退出
    local cf_retry=0
    while [[ "$Record_Info_Success" != "true" ]]; do
        ((cf_retry++))
        if ((cf_retry > retry_limit)); then
            msg error "与 CloudFlare 连接重试次数大于${retry_limit}次，退出进程"
            exit 1
        fi

        msg warn "与 Cloudflare 连接失败，重试中……(${cf_retry})"
        sleep 18
        Record_Info=$(check_CF)
        Record_Info_Success=$(echo "$Record_Info" | jq -r ".success")
    done
    msg success "与 Cloudflare 连接成功！"

    Record_Id=$(echo "$Record_Info" | jq -r ".result[0].id")
    Record_Proxy=$(echo "$Record_Info" | jq -r ".result[0].proxied")
    Record_IP=$(echo "$Record_Info" | jq -r ".result[0].content")

    local Record_Needs_Update="false"

    if [[ "$Record_Id" == "null" ]]; then
        # 没有记录时新增一个域名
        Record_Info=$(add_domain)
        Record_Needs_Update="true"
    elif [[ "$Record_IP" != "$New_IP" ]]; then
        # 有记录时更新域名的 IP 地址
        # 若域名的 IP 地址与当前机器的 IP 相同，则不更新 DNS 记录
        Record_Info=$(dns_update)
        Record_Needs_Update="true"
    else
        msg info "域名IP无需更新"
    fi


    if [[ "$Record_Needs_Update" == "true" ]]; then
        Record_Info_Success=$(echo "$Record_Info" | jq -r ".success")
        if [[ "$Record_Info_Success" == "true" ]]; then
            msg success "域名IP更新成功!"
            retry_count=0
            ip_check_delay=$tmp_ip_check_delay
            update_Retry_Set "false"
        else
            msg warn "域名IP更新失败，重试中……(${retry_count})"
            ((retry_count++))
            if ((retry_count > retry_limit)); then
                msg error "重试次数大于${retry_limit}次，退出进程"
                exit 1
            fi
            # 当域名IP更新失败时，缩短check_ip_changes的循环执行时间到10秒，快速重试
            ip_check_delay=10
            update_Retry_Set "true"
        fi
    else
        ip_check_delay=$tmp_ip_check_delay
        update_Retry_Set "false"
    fi
}

# 尝试重新更新
update_Retry() {
    if [[ "$ipv4_update_retry" == "true" ]]; then
        New_IP="$IPv4"
        Record_Type="A"
        update_IP
    fi

    if [[ "$ipv6_update_retry" == "true" ]]; then
        New_IP="$IPv6"
        Record_Type="AAAA"
        update_IP
    fi
}

first_check() {
    # 第一次或再次执行脚本时，检查 IP 地址是否需要更新
    if [ -n "$IPv4" ] && [ "$IPv4_IsLAN" == "0" ]; then
        New_IP="$IPv4"
        Record_Type="A"
        update_IP
    fi

    if [ -n "$IPv6" ] && [ "$IPv6_IsLAN" == "0" ]; then
        New_IP="$IPv6"
        Record_Type="AAAA"
        update_IP
    fi
}

check_ip_changes() {
    # 判断 IP 地址是否发生变化.如果IP发生变化,将新的IP地址写入文件,同时将IP赋值给New_IP变量,调用 update_IP 函数更新 IP
    # $IPv4/$IPv6 为空时说明路由器/光猫没有 IPv4/IPv6 地址,不予处理.
    # $IPv4_IsLAN/$IPv6_IsLAN 的值为 1 ,说明路由器/光猫获取的 IP 为内网 IP ,不予处理.
    # 当开启 ipv6_detect_retry 时，尝试重新测试是否有公网 IPv6
    gateway_test || return

    # 检查 IPv4 变化
    if [ -n "$IPv4" ] && [ "$IPv4_IsLAN" == "0" ] && [[ "$(sys_ipv4)" != *"$IPv4"* ]]; then
        curl_ip 4
        if [ -n "$IPv4" ]; then
            New_IP="$IPv4"
            msg info "IPV4 地址已更新: $New_IP"
            Record_Type="A"
            update_IP
        else
            msg warn "获取公网 IPv4 地址失败"
            # return 1
        fi
    fi

    # 尝试重新获取公网 IPv6
    if [[ "$ipv6_detect_retry" == "true" ]] && [[ "$(sys_ipv6_able)" != "null" ]] && [ "$IPv6_IsLAN" != "0" ]; then
        curl_ip 6
        msg info "尝试重新获取 IPV6 地址中：$IPv6"
        detect_lan_or_wan
    fi

    # 重新判断是否有 IPv6 临时地址
    if [[ "$tmp_ipv6_temporary" == "true" ]] && [[ "$ipv6_temporary" == "false" ]]; then
        ipv6_temporary="true"   # 启用ipv6_temporary来测试是否有临时地址
        local test_v6="$(sys_ipv6)"

        if [[ -n "$test_v6" ]] && [[ "$test_v6" != "null" ]]; then
            msg success "IPv6临时地址已恢复，使用IPv6临时地址更新IP"
        else
            ipv6_temporary="false"
        fi
    fi

    # 检查 IPv6 变化
    if [ -n "$IPv6" ] && [ "$IPv6_IsLAN" == "0" ] && [[ "$(sys_ipv6)" != "$IPv6" ]]; then
        curl_ip 6
        New_IP="$IPv6"
        Sys_IPv6="$(sys_ipv6)"
        Sys_IPv6_Able="$(sys_ipv6_able)"
        Record_Type="AAAA"

        # 避免使用API获取IPV6地址错误时无法更新域名IP
        if [ -n "$Sys_IPv6" ] && [[ "$Sys_IPv6" != "null" ]]; then

            if [[ "$New_IP" != "$Sys_IPv6" ]]; then
                IPv6="$Sys_IPv6"
                New_IP="$Sys_IPv6"
                msg warn "使用API获取IPV6异常，以系统获取的IPV6为基准"
            fi

            msg info "IPV6 地址已更新: $New_IP"
            update_IP

        elif [ -n "$Sys_IPv6_Able" ] && [[ "$Sys_IPv6_Able" != "null" ]]; then
            msg warn "无法获取临时 IPv6，使用系统可用的IPV6：${Sys_IPv6_Able}"
            IPv6="$Sys_IPv6_Able"
            New_IP="$Sys_IPv6_Able"
            update_IP
            ipv6_temporary="false"   # 停止使用IPv6临时地址
            msg warn "停止使用IPv6临时地址，等待再次获取……"
        else
            msg warn "获取IPV6异常"
            # ((retry_count++))
            # if ((retry_count > retry_limit)); then
            #     echo -e "\e[31m重试次数大于${retry_limit}次，退出进程\e[0m"
            #     exit 1
            # fi
        fi

    fi
}

# 初始获取 IP
msg info "正在初始化 IP 状态..."
curl_ip 4
curl_ip 6
detect_lan_or_wan
first_check

msg info "初始化完成，进入守护模式 (检查周期: ${ip_check_delay}s)"

# 每 $ip_check_delay 秒调用一次 check_ip_changes 函数，检查 IP 是否发生变化
while true; do
    update_Retry
    check_ip_changes
    sleep $ip_check_delay
done
