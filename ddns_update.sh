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

# 检查配置文件
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "请确认配置文件路径是否正确"
    exit 1
fi

# 检查配置文件是否正确
if [ -n "$Cloudflare_Zone_ID" ] && [ -n "$Cloudflare_API_Tokens" ] && [ -n "$Domain_Record" ]; then
    :
else
    echo "请检查配置文件……"
    exit 1
fi

retry_count=0
readonly tmp_ip_check_delay=$ip_check_delay
readonly tmp_ipv6_temporary=$ipv6_temporary

# 使用ping测试网关
gateway_test() {
    if ! ping -c 2 $gateway &> /dev/null; then
        if ! ping -c 5 $gateway &> /dev/null; then
            echo "网关无法连接"
            return 1
        fi
    fi
    return 0
}

# 为了防止网络尚未完全启动而造成获取 IP 失败，延迟 $start_delay 秒执行
echo "延迟$start_delay秒执行"
sleep $start_delay

# 等待网关ping通
until gateway_test; do
    ((retry_count++))
    if((retry_count > retry_limit)); then
        echo "网关仍然无法连接，退出进程"
    fi

    echo "等待网关就绪……"
    sleep 30
done
retry_count=0

# 获取路由器/光猫的公网 IP
curl_ip() {
    if [[ "${1}" == "4" ]]; then
        IPv4=$(curl -s4m8 $api_v4 -k || echo "")
    elif [[ "${1}" == "6" ]]; then
        IPv6=$(curl -s6m8 $api_v6 -k || echo "")
    fi
}

# 获取所有有效的 ipv4 地址
sys_ipv4() {
    ip -4 -j addr show | jq -r '.[].addr_info[] | select(.scope == "global" and (.deprecated | not)) | .local'
}

# 获取有效时间最大的有效 ipv6 地址
# 无法/无需获取临时地址时使用
sys_ipv6_able() {
    ip -6 -j addr show | jq -r '[.[].addr_info[] | select(.scope == "global" and (.deprecated | not))] | max_by(.valid_life_time) | .local'
}

# 当开启 ipv6_temporary 时，获取有效时间最大的有效 ipv6 临时地址
sys_ipv6() {
    if $ipv6_temporary; then
        ip -6 -j addr show | jq -r '[.[].addr_info[] | select(.scope == "global" and .temporary and (.deprecated | not))] | max_by(.valid_life_time) | .local'
    else
        sys_ipv6_able
    fi
}


is_wan() {
    if [[ "${1}" == "4" ]]; then
        echo -e "\e[32m路由器/光猫 PPPoE 获取的 IPv4 地址为公网IP! \e[0m"
        IPv4_IsLAN="0"
    elif [[ "${1}" == "6" ]]; then
        echo -e "\e[32m路由器/光猫 PPPoE 获取的 IPv6 地址为公网IP! \e[0m"
        IPv6_IsLAN="0"
    fi
}


is_lan() {
    if [[ "${1}" == "4" ]]; then
        echo -e "\e[32m路由器/光猫 PPPoE 获取的 IPv4 地址为私网IP! \e[0m"
        IPv4_IsLAN="1"
    elif [[ "${1}" == "6" ]]; then
        echo -e "\e[32m路由器/光猫 PPPoE 获取的 IPv6 地址为私网IP! \e[0m"
        IPv6_IsLAN="1"
    fi
}


# 判断路由器/光猫拨号获取的 IP 地址是公网 IP 还是私网 IP , 如果 IPv4/IPv6 某项为空,说明是单栈
detect_lan_or_wan() {
    if [ -n "$IPv4" ]; then
        if [[ $(sys_ipv4) != *"$IPv4"* ]]; then
            is_lan 4
        else
            is_wan 4
        fi
    else
        echo -e "\e[32m网络错误，无法获取到外网 IPv4 地址! \e[0m"
        exit 1
    fi

    if [ -n "$IPv6" ]; then
        if [[ $(sys_ipv6) != $IPv6 ]]; then
            # 无法获取临时地址时使用
            if [[ $(sys_ipv6_able) != $IPv6 ]]; then
                is_lan 6
            else
                is_wan 6
            fi
        else
            is_wan 6
        fi
    else
        echo -e "\e[32m无法获取到 IPv6 地址! \e[0m"
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

update_IP() {
    Create_Record_Api="https://api.cloudflare.com/client/v4/zones/${Cloudflare_Zone_ID}/dns_records"
    Record_Info_Api="${Create_Record_Api}?type=${Record_Type}&name=${Domain_Record}"

    Record_Info=$(check_CF)
    Record_Info_Success=$(echo "$Record_Info" | jq -r ".success")

    # 尝试重连$retry_limit次，大于直接退出
    local cf_retry=0
    while [[ $Record_Info_Success != "true" ]]; do
        ((cf_retry++))
        if ((cf_retry > retry_limit)); then
            echo -e "\e[31m与 CloudFlare 连接重试次数大于$retry_limit次，退出进程\e[0m"
            exit 1
        fi

        echo -e "\e[31m与 Cloudflare 连接失败，重试中……($cf_retry)\e[0m"
        sleep 18
        Record_Info=$(check_CF)
        Record_Info_Success=$(echo "$Record_Info" | jq -r ".success")
    done
    echo -e "\e[31m与 Cloudflare 连接成功！\e[0m"

    Record_Id=$(echo "$Record_Info" | jq -r ".result[0].id")
    Record_Proxy=$(echo "$Record_Info" | jq -r ".result[0].proxied")
    Record_IP=$(echo "$Record_Info" | jq -r ".result[0].content")
    Record_Info_No="false"

    if [[ $Record_Id = "null" ]]; then
        # 没有记录时新增一个域名
        Record_Info=$(add_domain)
    elif [[ $Record_IP != $New_IP ]]; then
        # 有记录时更新域名的 IP 地址
        # 若域名的 IP 地址与当前机器的 IP 相同，则不更新 DNS 记录
        Record_Info=$(dns_update)
    else
        Record_Info_No="true"
    fi

    Record_Info_Success=$(echo "$Record_Info" | jq -r ".success")

    if [[ $Record_Info_No = "true" ]]; then
        echo -e "\e[32m域名IP无需更新 \e[0m"
        retry_count=0
        ip_check_delay=$tmp_ip_check_delay
    elif [[ $Record_Info_Success = "true" ]]; then
        echo -e "\e[32m域名IP更新成功! \e[0m"
        retry_count=0
        ip_check_delay=$tmp_ip_check_delay
    else
        echo -e "\e[31m域名IP更新失败，重试中……($cf_retry)\e[0m"
        ((retry_count++))
        if ((retry_count > retry_limit)); then
            echo -e "\e[31m重试次数大于$retry_limit次，退出进程\e[0m"
            exit 1
        fi
        # 当域名IP更新失败时，缩短check_ip_changes的循环执行时间到10秒
        ip_check_delay=10
    fi
}

first_check() {
    # 第一次或再次执行脚本时，检查 IP 地址是否需要更新
    if [ -n "$IPv4" ] && [ "$IPv4_IsLAN" == "0" ]; then
        New_IP=$IPv4
        Record_Type="A"
        update_IP
    fi

    if [ -n "$IPv6" ] && [ "$IPv6_IsLAN" == "0" ]; then
        New_IP=$IPv6
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

    if $ipv6_detect_retry && [[ "$(sys_ipv6_able)" != "null" ]] && [ "$IPv6_IsLAN" != "0" ]; then
        curl_ip 6
        echo -e "\e[32m尝试重新获取 IPV6 地址中：$IPv6\e[0m"
        detect_lan_or_wan
    fi

    # 重新判断是否有临时地址
    if ($tmp_ipv6_temporary) && (! $ipv6_temporary); then
        ipv6_temporary=true   # 启用ipv6_temporary来测试是否有临时地址
        if [[ "$(sys_ipv6)" != "null" ]]; then
            echo "已成功获取IPv6临时地址"
        else
            ipv6_temporary=false
        fi
    fi


    if [ -n "$IPv4" ] && [ "$IPv4_IsLAN" == "0" ] && [[ "$(sys_ipv4)" != *"$IPv4"* ]]; then
        curl_ip 4
        if [ -n "$IPv4"]; then
            New_IP=$IPv4
            echo -e "\e[32mIPV4 地址已更新: $New_IP\e[0m"
            Record_Type="A"
            update_IP
        else
            echo "获取公网 IPv4 地址失败"
            # return 1
        fi
    fi


    if [ -n "$IPv6" ] && [ "$IPv6_IsLAN" == "0" ] && [[ "$(sys_ipv6)" != "$IPv6" ]]; then
        curl_ip 6
        New_IP=$IPv6
        Sys_IPv6=$(sys_ipv6)
        Record_Type="AAAA"

        # 避免使用API获取IPV6地址错误时无法更新域名IP
        if [[ $Sys_IPv6 != "null" ]]; then

            if [[ "$New_IP" != "$Sys_IPv6" ]]; then
                IPv6=$Sys_IPv6
                New_IP=$Sys_IPv6
                echo -e "\e[32m使用API获取IPV6异常，以系统获取的IPV6为基准\e[0m"
            fi

            echo -e "\e[32mIPV6 地址已更新: $New_IP\e[0m"
            update_IP

        elif [[ $(sys_ipv6_able) != "null" ]] && [[ $Sys_IPv6 == "null" ]]; then
            echo -e "\e[32m获取IPV6临时地址异常，使用系统可用的IPV6：$(sys_ipv6_able)\e[0m"
            IPv6=$(sys_ipv6_able)
            New_IP=$IPv6
            update_IP
            ipv6_temporary=false   # 停止使用IPv6临时地址
        else
            echo -e "\e[32m获取IPV6异常\e[0m"
            ((retry_count++))
            if ((retry_count > retry_limit)); then
                echo -e "\e[31m重试次数大于$retry_limit次，退出进程\e[0m"
                exit 1
            fi
        fi

    fi
}

curl_ip 4 && curl_ip 6
detect_lan_or_wan
first_check

# 每 $ip_check_delay 秒调用一次 check_ip_changes 函数，检查 IP 是否发生变化
while true; do
    check_ip_changes
    sleep $ip_check_delay
done
