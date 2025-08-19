#!/usr/bin/env bash
set -o errexit
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

# 自行修改 Cloudflare_Zone_ID & Cloudflare_API_Tokens & Domain_Record
Cloudflare_Zone_ID="type in zoneID"
Cloudflare_API_Tokens="type in token"
Domain_Record="ddns.example.com"

# IP API 地址
api_v4="https://ipv4.ddnsip.cn"
api_v6="https://ipv6.ddnsip.cn"

# 网关地址
gateway='192.168.0.1'

# cloudflare 重连计数
retry_count=0

# 网关测试
gateway_test() {
    ping -c 2 $gateway &> /dev/null
    if [ $? -ne 0 ]; then
        ping -c 5 $gateway &> /dev/null
        if [ $? -ne 0 ]; then
            echo "网关无法连接"
            exit 1
        fi
    fi
}

# 为了防止在 rc.local 中运行脚本时,网络尚未完全启动,造成获取 IP 失败,延迟 120 秒执行
echo "延迟 120 秒执行"
sleep 120
gateway_test

# 获取路由器/光猫的公网 IP
# 为防止大量请求 API , 使用两个文件保存旧的 IP 地址
IPv4_File=$HOME/.IPv4.addr && IPv4=$(curl -s4m8 $api_v4 -k)
IPv6_File=$HOME/.IPv6.addr && IPv6=$(curl -s6m8 $api_v6 -k)
echo $IPv4 > $IPv4_File
echo $IPv6 > $IPv6_File

# 获取所有有效的 ipv4 地址
sys_ipv4() {
    ip -4 -j addr show | jq -r '.[].addr_info[] | select(.scope == "global" and (.deprecated | not)) | .local'
}

# 获取有效时间最大的有效 ipv6 临时地址
sys_ipv6() {
    ip -6 -j addr show | jq -r '[.[].addr_info[] | select(.scope == "global" and .temporary and (.deprecated | not))] | max_by(.valid_life_time) | .local'
}

# 判断路由器/光猫拨号获取的 IP 地址是公网 IP 还是私网 IP , 如果 IPv4/IPv6 某项为空,说明是单栈
if [ -n "$IPv4" ]; then
    if ! [[ `sys_ipv4` =~ $IPv4 ]]; then
        echo -e "\e[33m路由器/光猫 PPPoE 获取的 IPv4 地址为私网IP! \e[0m"
        IPv4_IsLAN="1"
    else
        echo -e "\e[32m路由器/光猫 PPPoE 获取的 IPv4 地址为公网IP! \e[0m"
        IPv4_IsLAN="0"
    fi
else
    echo -e "\e[32m网络错误，无法获取到外网 IPv4 地址! \e[0m"
    exit 1
fi

if [ -n "$IPv6" ]; then
    if ! [[ `sys_ipv6` =~ $IPv6 ]]; then
        echo -e "\e[33m路由器/光猫 PPPoE 获取的 IPv6 地址为私网IP! \e[0m"
        IPv6_IsLAN="1"
    else
        echo -e "\e[32m路由器/光猫 PPPoE 获取的 IPv6 地址为公网IP! \e[0m"
        IPv6_IsLAN="0"
    fi
else
    echo -e "\e[32m无法获取到 IPv6 地址! \e[0m"
fi

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

    # 尝试重连10次，大于10次直接退出
    while true; do
        ((retry_count++))
        if ((retry_count > 10)); then
            echo -e "\e[31m重试次数大于10次， 退出进程\e[0m"
            exit 1
        fi

        if [[ $Record_Info_Success != "true" ]]; then
            echo -e "\e[31m与 Cloudflare 连接失败， 重试中……\e[0m"
            sleep 18
            Record_Info=$(check_CF)
            Record_Info_Success=$(echo "$Record_Info" | jq -r ".success")
        else
            echo -e "\e[31m与 Cloudflare 连接成功！\e[0m"
            break
        fi
    done

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
    elif [[ $Record_Info_Success = "true" ]]; then
        echo -e "\e[32m域名IP更新成功! \e[0m"
    else
        echo -e "\e[31m域名IP更新失败! \e[0m"
    fi
}

first_check() {
	# 第一次或再次执行脚本时，检查 IP 地址是否需要更新
    if [ -n "$IPv4" ] && [ "$IPv4_IsLAN" != "1" ]; then
        New_IP=`cat $IPv4_File`
        Record_Type="A"
        update_IP
    fi

    if [ -n "$IPv6" ] && [ "$IPv6_IsLAN" != "1" ]; then
        New_IP=`cat $IPv6_File`
        Record_Type="AAAA"
        update_IP
    fi
}

check_ip_changes() {
    # 判断 IP 地址是否发生变化.如果IP发生变化,将新的IP地址写入文件,同时将IP赋值给New_IP变量,调用 update_IP 函数更新 IP
    # $IPv4/$IPv6 为空时说明路由器/光猫没有 IPv4/IPv6 地址,不予处理.
    # $IPv4_IsLAN/$IPv6_IsLAN 的值为 1 ,说明路由器/光猫获取的 IP 为内网 IP ,不予处理.
    # $(ip add show) 不包含 $(cat $IPv4_File) ,说明 IP 已发生变化.
    gateway_test

    if [[ -n `sys_ipv6` ]] && ! [ -n "$IPv6" ]; then
        IPv6=$(curl -s6m8 $api_v6 -k)
        echo -e "\e[32m已重新获取到 IPV6 地址：$IPv6\e[0m"
    fi

    if [ -n "$IPv4" ] && [ "$IPv4_IsLAN" != "1" ] && ! [[ `sys_ipv4` =~ `cat $IPv4_File` ]]; then
        New_IP=$(curl -s4m8 $api_v4 -k) && echo $New_IP > $IPv4_File
        echo -e "\e[32mIPV4 地址已更新: $New_IP\e[0m"
        Record_Type="A"
        update_IP
    fi

    if [ -n "$IPv6" ] && [ "$IPv6_IsLAN" != "1" ] && ! [[ `sys_ipv6` =~ `cat $IPv6_File` ]]; then
        New_IP=$(curl -s6m8 $api_v6 -k) && echo $New_IP > $IPv6_File
        echo -e "\e[32mIPV6 地址已更新: $New_IP\e[0m"
        Record_Type="AAAA"
        update_IP
    fi
}


first_check

# 每 3 分钟调用一次 check_ip_changes 函数,检查 IP 是否发生变化
while true; do check_ip_changes && sleep 180; done
