#!/bin/sh
# Copyright (C) 2018-2020 L-WRT Team
# Copyright (C) 2021 xiaorouji

. $IPKG_INSTROOT/lib/functions.sh
. $IPKG_INSTROOT/lib/functions/service.sh

CONFIG=passwall
TMP_PATH=/var/etc/$CONFIG
TMP_BIN_PATH=$TMP_PATH/bin
TMP_ID_PATH=$TMP_PATH/id
TMP_PORT_PATH=$TMP_PATH/port
TMP_ROUTE_PATH=$TMP_PATH/route
LOG_FILE=/var/log/$CONFIG.log
APP_PATH=/usr/share/$CONFIG
RULES_PATH=/usr/share/${CONFIG}/rules
DNS_N=dnsmasq
DNS_PORT=7913
TUN_DNS="127.0.0.1#${DNS_PORT}"
IS_DEFAULT_DNS=0
LOCAL_DNS=
DEFAULT_DNS=
NO_PROXY=
use_tcp_node_resolve_dns=0
use_udp_node_resolve_dns=0
LUA_API_PATH=/usr/lib/lua/luci/model/cbi/$CONFIG/api
API_GEN_SS=$LUA_API_PATH/gen_shadowsocks.lua
API_GEN_XRAY=$LUA_API_PATH/gen_xray.lua
API_GEN_XRAY_PROTO=$LUA_API_PATH/gen_xray_proto.lua
API_GEN_TROJAN=$LUA_API_PATH/gen_trojan.lua
API_GEN_NAIVE=$LUA_API_PATH/gen_naiveproxy.lua

echolog() {
	local d="$(date "+%Y-%m-%d %H:%M:%S")"
	echo -e "$d: $*" >>$LOG_FILE
}

config_n_get() {
	local ret=$(uci -q get "${CONFIG}.${1}.${2}" 2>/dev/null)
	echo "${ret:=$3}"
}

config_t_get() {
	local index=${4:-0}
	local ret=$(uci -q get "${CONFIG}.@${1}[${index}].${2}" 2>/dev/null)
	echo "${ret:=${3}}"
}

get_enabled_anonymous_secs() {
	uci -q show "${CONFIG}" | grep "${1}\[.*\.enabled='1'" | cut -d '.' -sf2
}

get_host_ip() {
	local host=$2
	local count=$3
	[ -z "$count" ] && count=3
	local isip=""
	local ip=$host
	if [ "$1" == "ipv6" ]; then
		isip=$(echo $host | grep -E "([[a-f0-9]{1,4}(:[a-f0-9]{1,4}){7}|[a-f0-9]{1,4}(:[a-f0-9]{1,4}){0,7}::[a-f0-9]{0,4}(:[a-f0-9]{1,4}){0,7}])")
		if [ -n "$isip" ]; then
			isip=$(echo $host | cut -d '[' -f2 | cut -d ']' -f1)
		else
			isip=$(echo $host | grep -E "([a-f0-9]{1,4}(:[a-f0-9]{1,4}){7}|[a-f0-9]{1,4}(:[a-f0-9]{1,4}){0,7}::[a-f0-9]{0,4}(:[a-f0-9]{1,4}){0,7})")
		fi
	else
		isip=$(echo $host | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
	fi
	[ -z "$isip" ] && {
		local t=4
		[ "$1" == "ipv6" ] && t=6
		local vpsrip=$(resolveip -$t -t $count $host | awk 'NR==1{print}')
		ip=$vpsrip
	}
	echo $ip
}

get_node_host_ip() {
	local ip
	local address=$(config_n_get $1 address)
	[ -n "$address" ] && {
		local use_ipv6=$(config_n_get $1 use_ipv6)
		local network_type="ipv4"
		[ "$use_ipv6" == "1" ] && network_type="ipv6"
		ip=$(get_host_ip $network_type $address)
	}
	echo $ip
}

get_ip_port_from() {
	local __host=${1}; shift 1
	local __ipv=${1}; shift 1
	local __portv=${1}; shift 1

	local val1 val2
	val2=$(echo $__host | sed -n 's/^.*[:#]\([0-9]*\)$/\1/p')
	val1="${__host%%${val2:+[:#]${val2}*}}"
	eval "${__ipv}=\"$val1\"; ${__portv}=\"$val2\""
}

host_from_url(){
	local f=${1}

	## Remove protocol part of url  ##
	f="${f##http://}"
	f="${f##https://}"
	f="${f##ftp://}"
	f="${f##sftp://}"

	## Remove username and/or username:password part of URL  ##
	f="${f##*:*@}"
	f="${f##*@}"

	## Remove rest of urls ##
	f="${f%%/*}"
	echo "${f%%:*}"
}

hosts_foreach() {
	local __hosts
	eval "__hosts=\$${1}"; shift 1
	local __func=${1}; shift 1
	local __default_port=${1}; shift 1
	local __ret=1

	[ -z "${__hosts}" ] && return 0
	local __ip __port
	for __host in $(echo $__hosts | sed 's/[ ,]/\n/g'); do
		get_ip_port_from "$__host" "__ip" "__port"
		eval "$__func \"${__host}\" \"\${__ip}\" \"\${__port:-${__default_port}}\" \"$@\""
		__ret=$?
		[ ${__ret} -ge ${ERROR_NO_CATCH:-1} ] && return ${__ret}
	done
}

get_first_dns() {
	local __hosts_val=${1}; shift 1
	__first() {
		[ -z "${2}" ] && return 0
		echo "${2}#${3}"
		return 1
	}
	eval "hosts_foreach \"${__hosts_val}\" __first \"$@\""
}

get_last_dns() {
	local __hosts_val=${1}; shift 1
	local __first __last
	__every() {
		[ -z "${2}" ] && return 0
		__last="${2}#${3}"
		__first=${__first:-${__last}}
	}
	eval "hosts_foreach \"${__hosts_val}\" __every \"$@\""
	[ "${__first}" ==  "${__last}" ] || echo "${__last}"
}

check_port_exists() {
	port=$1
	protocol=$2
	result=
	if [ "$protocol" = "tcp" ]; then
		result=$(netstat -tln | grep -c ":$port ")
	elif [ "$protocol" = "udp" ]; then
		result=$(netstat -uln | grep -c ":$port ")
	fi
	echo "${result}"
}

get_new_port() {
	port=$1
	[ "$port" == "auto" ] && port=2082
	protocol=$(echo $2 | tr 'A-Z' 'a-z')
	result=$(check_port_exists $port $protocol)
	if [ "$result" != 0 ]; then
		temp=
		if [ "$port" -lt 65535 ]; then
			temp=$(expr $port + 1)
		elif [ "$port" -gt 1 ]; then
			temp=$(expr $port - 1)
		fi
		get_new_port $temp $protocol
	else
		echo $port
	fi
}

first_type() {
	local path_name=${1}
	type -t -p "/bin/${path_name}" -p "${TMP_BIN_PATH}/${path_name}" -p "${path_name}" "$@" | head -n1
}

ln_start_bin() {
	local file_func=${1}
	local ln_name=${2}
	local output=${3}

	shift 3;
	if [  "${file_func%%/*}" != "${file_func}" ]; then
		[ ! -L "${file_func}" ] && {
			ln -s "${file_func}" "${TMP_BIN_PATH}/${ln_name}" >/dev/null 2>&1
			file_func="${TMP_BIN_PATH}/${ln_name}"
		}
		[ -x "${file_func}" ] || echolog "  - $(readlink ${file_func}) 没有执行权限，无法启动：${file_func} $*"
	fi
	#echo "${file_func} $*" >&2
	[ -n "${file_func}" ] || echolog "  - 找不到 ${ln_name}，无法启动..."
	${file_func:-echolog "  - ${ln_name}"} "$@" >${output} 2>&1 &
}

ENABLED=$(config_t_get global enabled 0)
SOCKS_ENABLED=$(config_t_get global socks_enabled 0)

TCP_REDIR_PORT=1041
TCP_NODE=$(config_t_get global tcp_node nil)

UDP_REDIR_PORT=1051
UDP_NODE=$(config_t_get global udp_node nil)

[ "$UDP_NODE" == "tcp" ] && {
	UDP_NODE=$TCP_NODE
	TCP_UDP=1
}

TCP_REDIR_PORTS=$(config_t_get global_forwarding tcp_redir_ports '80,443')
UDP_REDIR_PORTS=$(config_t_get global_forwarding udp_redir_ports '1:65535')
TCP_NO_REDIR_PORTS=$(config_t_get global_forwarding tcp_no_redir_ports 'disable')
UDP_NO_REDIR_PORTS=$(config_t_get global_forwarding udp_no_redir_ports 'disable')
KCPTUN_REDIR_PORT=$(config_t_get global_forwarding kcptun_port 12948)
TCP_PROXY_MODE=$(config_t_get global tcp_proxy_mode chnroute)
UDP_PROXY_MODE=$(config_t_get global udp_proxy_mode chnroute)
LOCALHOST_TCP_PROXY_MODE=$(config_t_get global localhost_tcp_proxy_mode default)
LOCALHOST_UDP_PROXY_MODE=$(config_t_get global localhost_udp_proxy_mode default)
[ "$LOCALHOST_TCP_PROXY_MODE" == "default" ] && LOCALHOST_TCP_PROXY_MODE=$TCP_PROXY_MODE
[ "$LOCALHOST_UDP_PROXY_MODE" == "default" ] && LOCALHOST_UDP_PROXY_MODE=$UDP_PROXY_MODE
RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
[ -f "${RESOLVFILE}" ] && [ -s "${RESOLVFILE}" ] || RESOLVFILE=/tmp/resolv.conf.auto

load_config() {
	[ "$ENABLED" != 1 ] && NO_PROXY=1
	[ "$TCP_NODE" == "nil" -a "$UDP_NODE" == "nil" ] && {
		echolog "没有选择节点！"
		NO_PROXY=1
	}
	
	count_hosts_str=
	[ -f "${RULES_PATH}/direct_host" ] && direct_hosts_str="$(echo -n $(cat ${RULES_PATH}/direct_host) | sed "s/ /|/g")"
	[ -f "${RULES_PATH}/proxy_host" ] && proxy_hosts_str="$(echo -n $(cat ${RULES_PATH}/proxy_host) | sed "s/ /|/g")"
	[ -n "$direct_hosts_str" ] && {
		tmp="${direct_hosts_str}"
		[ -n "$count_hosts_str" ] && tmp="${count_hosts_str}|${direct_hosts_str}"
		count_hosts_str="$tmp"
	}
	[ -n "$proxy_hosts_str" ] && {
		tmp="${proxy_hosts_str}"
		[ -n "$count_hosts_str" ] && tmp="${count_hosts_str}|${proxy_hosts_str}"
		count_hosts_str="$tmp"
	}

	global=$(echo "${TCP_PROXY_MODE}${LOCALHOST_TCP_PROXY_MODE}${UDP_PROXY_MODE}${LOCALHOST_UDP_PROXY_MODE}" | grep "global")
	returnhome=$(echo "${TCP_PROXY_MODE}${LOCALHOST_TCP_PROXY_MODE}${UDP_PROXY_MODE}${LOCALHOST_UDP_PROXY_MODE}" | grep "returnhome")
	chnlist=$(echo "${TCP_PROXY_MODE}${LOCALHOST_TCP_PROXY_MODE}${UDP_PROXY_MODE}${LOCALHOST_UDP_PROXY_MODE}" | grep "chnroute")
	gfwlist=$(echo "${TCP_PROXY_MODE}${LOCALHOST_TCP_PROXY_MODE}${UDP_PROXY_MODE}${LOCALHOST_UDP_PROXY_MODE}" | grep "gfwlist")
	DNS_MODE=$(config_t_get global dns_mode pdnsd)
	DNS_FORWARD=$(config_t_get global dns_forward 8.8.4.4:53 | sed 's/:/#/g')
	DNS_CACHE=$(config_t_get global dns_cache 0)
	LOCAL_DNS="default"
	if [ "${LOCAL_DNS}" = "default" ]; then
		DEFAULT_DNS=$(uci show dhcp | grep "@dnsmasq" | grep "\.server=" | awk -F '=' '{print $2}' | sed "s/'//g" | tr ' ' ',')
		if [ -z "${DEFAULT_DNS}" ]; then
			DEFAULT_DNS=$(echo -n $(sed -n 's/^nameserver[ \t]*\([^ ]*\)$/\1/p' "${RESOLVFILE}" | grep -v -E "0.0.0.0|127.0.0.1|::" | head -2) | tr ' ' ',')
		fi
		LOCAL_DNS="${DEFAULT_DNS:-119.29.29.29}"
		IS_DEFAULT_DNS=1
	fi
	PROXY_IPV6=$(config_t_get global_forwarding proxy_ipv6 0)
	export XRAY_LOCATION_ASSET=$(config_t_get global_rules xray_location_asset "/usr/share/xray/")
	mkdir -p /var/etc $TMP_PATH $TMP_BIN_PATH $TMP_ID_PATH $TMP_PORT_PATH $TMP_ROUTE_PATH
	return 0
}

run_socks() {
	local flag=$1
	local node=$2
	local bind=$3
	local socks_port=$4
	local config_file=$5
	local http_port=$6
	local http_config_file=$7
	local relay_port=$8
	local log_file="/dev/null"
	local type=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
	local remarks=$(config_n_get $node remarks)
	local server_host=$(config_n_get $node address)
	local port=$(config_n_get $node port)
	[ -n "$relay_port" ] && {
		server_host="127.0.0.1"
		port=$relay_port
	}
	local msg tmp

	if [ -n "$server_host" ] && [ -n "$port" ]; then
		server_host=$(host_from_url "$server_host")
		[ -n "$(echo -n $server_host | awk '{print gensub(/[!-~]/,"","g",$0)}')" ] && msg="$remarks，非法的代理服务器地址，无法启动 ！"
		tmp="（${server_host}:${port}）"
	else
		msg="某种原因，此 Socks 服务的相关配置已失联，启动中止！"
	fi

	if [ "$type" == "xray" ] && ([ -n "$(config_n_get $node balancing_node)" ] || [ "$(config_n_get $node default_node)" != "_direct" -a "$(config_n_get $node default_node)" != "_blackhole" ]); then
		unset msg
	fi

	[ -n "${msg}" ] && {
		[ "$bind" != "127.0.0.1" ] && echolog "  - 启动中止 ${bind}:${socks_port} ${msg}"
		return 1
	}
	[ "$bind" != "127.0.0.1" ] && echolog "  - 启动 ${bind}:${socks_port}  - 节点：$remarks${tmp}"

	case "$type" in
	socks|\
	xray)
		[ "$http_port" != "0" ] && {
			local extra_param="-http_proxy_port $http_port"
			config_file=$(echo $config_file | sed "s/SOCKS/HTTP_SOCKS/g")
		}
		lua $API_GEN_XRAY -node $node -socks_proxy_port $socks_port $extra_param > $config_file
		ln_start_bin "$(first_type $(config_t_get global_app xray_file) xray)" xray $log_file -config="$config_file"
	;;
	trojan-go)
		lua $API_GEN_TROJAN -node $node -run_type client -local_addr $bind -local_port $socks_port -server_host $server_host -server_port $port > $config_file
		ln_start_bin "$(first_type $(config_t_get global_app trojan_go_file) trojan-go)" trojan-go $log_file -config "$config_file"
	;;
	trojan*)
		lua $API_GEN_TROJAN -node $node -run_type client -local_addr $bind -local_port $socks_port -server_host $server_host -server_port $port > $config_file
		ln_start_bin "$(first_type ${type})" "${type}" $log_file -c "$config_file"
	;;
	naiveproxy)
		lua $API_GEN_NAIVE -node $node -run_type socks -local_addr $bind -local_port $socks_port -server_host $server_host -server_port $port > $config_file
		ln_start_bin "$(first_type naive)" naive $log_file "$config_file"
	;;
	brook)
		local protocol=$(config_n_get $node protocol client)
		local brook_tls=$(config_n_get $node brook_tls 0)
		[ "$protocol" == "wsclient" ] && {
			[ "$brook_tls" == "1" ] && server_host="wss://${server_host}" || server_host="ws://${server_host}"
		}
		ln_start_bin "$(first_type $(config_t_get global_app brook_file) brook)" "brook_SOCKS_${flag}" $log_file "$protocol" --socks5 "$bind:$socks_port" -s "$server_host:$port" -p "$(config_n_get $node password)"
	;;
	ssr)
		lua $API_GEN_SS -node $node -local_addr "0.0.0.0" -local_port $socks_port -server_host $server_host -server_port $port > $config_file
		ln_start_bin "$(first_type ssr-local)" "ssr-local" $log_file -c "$config_file" -v
	;;
	ss)
		local bin="ss-local"
		[ "$(config_n_get $node ss_rust 0)" = "1" ] && bin="sslocal"
		lua $API_GEN_SS -node $node -local_addr "0.0.0.0" -local_port $socks_port -server_host $server_host -server_port $port -protocol socks -mode tcp_and_udp > $config_file
		ln_start_bin "$(first_type $bin ss-local)" "$bin" $log_file -c "$config_file" -v
	;;
	esac

	# http to socks
	[ "$type" != "xray" ] && [ "$type" != "socks" ] && [ "$http_port" != "0" ] && [ "$http_config_file" != "nil" ] && {
		lua $API_GEN_XRAY_PROTO -local_proto http -local_address "0.0.0.0" -local_port $http_port -server_proto socks -server_address "127.0.0.1" -server_port $socks_port -server_username $_username -server_password $_password > $http_config_file
		echo lua $API_GEN_XRAY_PROTO -local_proto http -local_address "0.0.0.0" -local_port $http_port -server_proto socks -server_address "127.0.0.1" -server_port $socks_port -server_username $_username -server_password $_password
		ln_start_bin "$(first_type $(config_t_get global_app xray_file) xray)" xray $log_file -config="$http_config_file"
	}
}

run_redir() {
	local node=$1
	local bind=$2
	local local_port=$3
	local config_file=$4
	local REDIR_TYPE=$5
	local log_file=$6
	[ -z "$log_file" ] && log_file="/dev/null"
	local redir_type=$(echo $REDIR_TYPE | tr 'A-Z' 'a-z')
	local type=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
	local close_log=$(config_t_get global close_log_${redir_type} 1)
	[ "$close_log" = "1" ] && log_file="/dev/null"
	local remarks=$(config_n_get $node remarks)
	local server_host=$(config_n_get $node address)
	local port=$(config_n_get $node port)
	[ -n "$server_host" -a -n "$port" ] && {
		# 判断节点服务器地址是否URL并去掉~
		local server_host=$(host_from_url "$server_host")
		# 判断节点服务器地址是否包含汉字~
		local tmp=$(echo -n $server_host | awk '{print gensub(/[!-~]/,"","g",$0)}')
		[ -n "$tmp" ] && {
			echolog "$remarks节点，非法的服务器地址，无法启动！"
			return 1
		}
		[ "$bind" != "127.0.0.1" ] && echolog "${REDIR_TYPE}节点：$remarks，节点：${server_host}:${port}，监听端口：$local_port"
	}
	eval ${REDIR_TYPE}_NODE_PORT=$port

	case "$REDIR_TYPE" in
	UDP)
		case "$type" in
		socks)
			local node_address=$(config_n_get $node address)
			local node_port=$(config_n_get $node port)
			local server_username=$(config_n_get $node username)
			local server_password=$(config_n_get $node password)
			eval port=\$UDP_REDIR_PORT
			ln_start_bin "$(first_type ipt2socks)" "ipt2socks_udp" $log_file -U -l "$port" -b 0.0.0.0 -s "$node_address" -p "$node_port" -R -v
		;;
		xray)
			local loglevel=$(config_t_get global loglevel "warning")
			lua $API_GEN_XRAY -node $node -proto udp -redir_port $local_port -loglevel $loglevel > $config_file
			ln_start_bin "$(first_type $(config_t_get global_app xray_file) xray)" xray $log_file -config="$config_file"
		;;
		trojan-go)
			local loglevel=$(config_t_get global trojan_loglevel "2")
			lua $API_GEN_TROJAN -node $node -run_type nat -local_addr "0.0.0.0" -local_port $local_port -loglevel $loglevel > $config_file
			ln_start_bin "$(first_type $(config_t_get global_app trojan_go_file) trojan-go)" trojan-go $log_file -config "$config_file"
		;;
		trojan*)
			local loglevel=$(config_t_get global trojan_loglevel "2")
			lua $API_GEN_TROJAN -node $node -run_type nat -local_addr "0.0.0.0" -local_port $local_port -loglevel $loglevel > $config_file
			ln_start_bin "$(first_type ${type})" "${type}" $log_file -c "$config_file"
		;;
		naiveproxy)
			echolog "Naiveproxy不支持UDP转发！"
		;;
		brook)
			local protocol=$(config_n_get $node protocol client)
			if [ "$protocol" == "wsclient" ]; then
				echolog "Brook的WebSocket不支持UDP转发！"
			else
				ln_start_bin "$(first_type $(config_t_get global_app brook_file) brook)" "brook_udp" $log_file tproxy -l ":$local_port" -s "$server_host:$port" -p "$(config_n_get $node password)"
			fi
		;;
		ssr)
			lua $API_GEN_SS -node $node -local_addr "0.0.0.0" -local_port $local_port > $config_file
			ln_start_bin "$(first_type ssr-redir)" "ssr-redir" $log_file -c "$config_file" -v -U
		;;
		ss)
			local bin="ss-redir"
			[ "$(config_n_get $node ss_rust 0)" = "1" ] && bin="sslocal"
			lua $API_GEN_SS -node $node -local_addr "0.0.0.0" -local_port $local_port -protocol redir -mode udp_only > $config_file
			ln_start_bin "$(first_type $bin ss-redir)" "$bin" $log_file -c "$config_file" -v
		;;
		esac
	;;
	TCP)
		local kcptun_use=$(config_n_get $node use_kcp 0)
		if [ "$kcptun_use" == "1" ]; then
			local kcptun_server_host=$(config_n_get $node kcp_server)
			local network_type="ipv4"
			local kcptun_port=$(config_n_get $node kcp_port)
			local kcptun_config="$(config_n_get $node kcp_opts)"
			if [ -z "$kcptun_port" -o -z "$kcptun_config" ]; then
				echolog "Kcptun未配置参数，错误！"
				return 1
			fi
			if [ -n "$kcptun_port" -a -n "$kcptun_config" ]; then
				local run_kcptun_ip=$server_host
				[ -n "$kcptun_server_host" ] && run_kcptun_ip=$(get_host_ip $network_type $kcptun_server_host)
				KCPTUN_REDIR_PORT=$(get_new_port $KCPTUN_REDIR_PORT tcp)
				kcptun_params="-l 0.0.0.0:$KCPTUN_REDIR_PORT -r $run_kcptun_ip:$kcptun_port $kcptun_config"
				ln_start_bin "$(first_type $(config_t_get global_app kcptun_client_file) kcptun-client)" "kcptun_tcp" $log_file $kcptun_params
			fi
		fi
		local _socks_flag _socks_address _socks_port _socks_username _socks_password
		case "$type" in
		socks)
			_socks_flag=1
			_socks_address=$(config_n_get $node address)
			_socks_port=$(config_n_get $node port)
			_socks_username=$(config_n_get $node username)
			_socks_password=$(config_n_get $node password)
		;;
		xray)
			local loglevel=$(config_t_get global loglevel "warning")
			local proto="-proto tcp"
			local extra_param=""
			[ "$tcp_node_socks" = "1" ] && {
				local socks_param="-socks_proxy_port $tcp_node_socks_port"
				extra_param="${extra_param} ${socks_param}"
				config_file=$(echo $config_file | sed "s/TCP/TCP_SOCKS_$tcp_node_socks_id/g")
			}
			[ "$tcp_node_http" = "1" ] && {
				local http_param="-http_proxy_port $tcp_node_http_port"
				extra_param="${extra_param} ${http_param}"
				config_file=$(echo $config_file | sed "s/TCP/TCP_HTTP_$tcp_node_http_id/g")
			}
			[ "$TCP_UDP" = "1" ] && {
				config_file=$(echo $config_file | sed "s/TCP/TCP_UDP/g")
				proto="-proto tcp,udp"
				UDP_REDIR_PORT=$TCP_REDIR_PORT
				UDP_NODE="nil"
			}
			extra_param="${extra_param} ${proto}"
			lua $API_GEN_XRAY -node $node -redir_port $local_port -loglevel $loglevel $extra_param > $config_file
			ln_start_bin "$(first_type $(config_t_get global_app xray_file) xray)" xray $log_file -config="$config_file"
		;;
		trojan-go)
			[ "$TCP_UDP" = "1" ] && {
				config_file=$(echo $config_file | sed "s/TCP/TCP_UDP/g")
				UDP_REDIR_PORT=$TCP_REDIR_PORT
				UDP_NODE="nil"
			}
			local loglevel=$(config_t_get global trojan_loglevel "2")
			lua $API_GEN_TROJAN -node $node -run_type nat -local_addr "0.0.0.0" -local_port $local_port -loglevel $loglevel > $config_file
			ln_start_bin "$(first_type $(config_t_get global_app trojan_go_file) trojan-go)" trojan-go $log_file -config "$config_file"
		;;
		trojan*)
			[ "$TCP_UDP" = "1" ] && {
				config_file=$(echo $config_file | sed "s/TCP/TCP_UDP/g")
				UDP_REDIR_PORT=$TCP_REDIR_PORT
				UDP_NODE="nil"
			}
			local loglevel=$(config_t_get global trojan_loglevel "2")
			lua $API_GEN_TROJAN -node $node -run_type nat -local_addr "0.0.0.0" -local_port $local_port -loglevel $loglevel > $config_file
			ln_start_bin "$(first_type ${type})" "${type}" $log_file -c "$config_file"
		;;
		naiveproxy)
			lua $API_GEN_NAIVE -node $node -run_type redir -local_addr "0.0.0.0" -local_port $local_port > $config_file
			ln_start_bin "$(first_type naive)" naive $log_file "$config_file"
		;;
		brook)
			local server_ip=$server_host
			local protocol=$(config_n_get $node protocol client)
			local brook_tls=$(config_n_get $node brook_tls 0)
			if [ "$protocol" == "wsclient" ]; then
				[ "$brook_tls" == "1" ] && server_ip="wss://${server_ip}" || server_ip="ws://${server_ip}"
				socks_port=$(get_new_port 2081 tcp)
				ln_start_bin "$(first_type $(config_t_get global_app brook_file) brook)" "brook_tcp" $log_file wsclient --socks5 "127.0.0.1:$socks_port" -s "$server_ip:$port" -p "$(config_n_get $node password)"
				_socks_flag=1
				_socks_address="127.0.0.1"
				_socks_port=$socks_port
				echolog "Brook的WebSocket不支持透明代理，将使用ipt2socks转换透明代理！"
			else
				[ "$kcptun_use" == "1" ] && {
					server_ip=127.0.0.1
					port=$KCPTUN_REDIR_PORT
				}
				ln_start_bin "$(first_type $(config_t_get global_app brook_file) brook)" "brook_tcp" $log_file tproxy -l ":$local_port" -s "$server_ip:$port" -p "$(config_n_get $node password)"
			fi
		;;
		ssr)
			if [ "$kcptun_use" == "1" ]; then
				lua $API_GEN_SS -node $node -local_addr "0.0.0.0" -local_port $local_port -server_host "127.0.0.1" -server_port $KCPTUN_REDIR_PORT > $config_file
			else
				[ "$TCP_UDP" = "1" ] && {
					config_file=$(echo $config_file | sed "s/TCP/TCP_UDP/g")
					UDP_REDIR_PORT=$TCP_REDIR_PORT
					UDP_NODE="nil"
					extra_param="-u"
				}
				lua $API_GEN_SS -node $node -local_addr "0.0.0.0" -local_port $local_port > $config_file
			fi
			ln_start_bin "$(first_type ssr-redir)" "ssr-redir" $log_file -c "$config_file" -v $extra_param
		;;
		ss)
			local bin="ss-redir"
			[ "$(config_n_get $node ss_rust 0)" = "1" ] && bin="sslocal"
			lua_mode_arg="-mode tcp_only"
			if [ "$kcptun_use" == "1" ]; then
				lua $API_GEN_SS -node $node -local_addr "0.0.0.0" -local_port $local_port -server_host "127.0.0.1" -server_port $KCPTUN_REDIR_PORT -protocol redir $lua_mode_arg > $config_file
			else
				[ "$TCP_UDP" = "1" ] && {
					config_file=$(echo $config_file | sed "s/TCP/TCP_UDP/g")
					UDP_REDIR_PORT=$TCP_REDIR_PORT
					UDP_NODE="nil"
					lua_mode_arg="-mode tcp_and_udp"
				}
				lua $API_GEN_SS -node $node -local_addr "0.0.0.0" -local_port $local_port -protocol redir $lua_mode_arg > $config_file
			fi
			ln_start_bin "$(first_type $bin ss-redir)" "$bin" $log_file -c "$config_file" -v
		;;
		esac
		if [ -n "$_socks_flag" ]; then
			local extra_param="-T"
			[ "$TCP_UDP" = "1" ] && extra_param=""
			ln_start_bin "$(first_type ipt2socks)" "ipt2socks_tcp" $log_file -l "$local_port" -b 0.0.0.0 -s "$_socks_address" -p "$_socks_port" -R -v $extra_param
		fi
		unset _socks_flag _socks_address _socks_port _socks_username _socks_password

		[ "$type" != "xray" ] && {
			[ "$tcp_node_socks" = "1" ] && {
				local port=$tcp_node_socks_port
				local config_file=$TMP_PATH/SOCKS_$tcp_node_socks_id.json
				local log_file=$TMP_PATH/SOCKS_$tcp_node_socks_id.log
				local http_port=0
				local http_config_file=$TMP_PATH/HTTP2SOCKS_$tcp_node_http_id.json
				[ "$tcp_node_http" = "1" ] && {
					http_port=$tcp_node_http_port
				}
				run_socks TCP $node "0.0.0.0" $port $config_file $http_port $http_config_file
			}
		}
	;;
	esac
	return 0
}

node_switch() {
	[ -n "$1" -a -n "$2" ] && {
		local node=$2
		top -bn1 | grep -E "$TMP_PATH" | grep -i "${1}" | grep -v "grep" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
		local config_file=$TMP_PATH/${1}.json
		local log_file=$TMP_PATH/${1}.log
		eval current_port=\$${1}_REDIR_PORT
		local port=$(cat $TMP_PORT_PATH/${1})

		local ids=$(uci show $CONFIG | grep "=socks" | awk -F '.' '{print $2}' | awk -F '=' '{print $1}')
		for id in $ids; do
			[ "$(config_n_get $id enabled 0)" == "0" ] && continue
			[ "$(config_n_get $id node nil)" != "tcp" ] && continue
			local socks_port=$(config_n_get $id port)
			local http_port=$(config_n_get $id http_port 0)
			top -bn1 | grep -E "$TMP_PATH" | grep -i "SOCKS" | grep "$id" | grep -v "grep" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
			tcp_node_socks=1
			tcp_node_socks_port=$socks_port
			tcp_node_socks_id=$id
			[ "$http_port" != "0" ] && {
				tcp_node_http=1
				tcp_node_http_port=$http_port
				tcp_node_http_id=$id
			}
			break
		done

		run_redir $node "0.0.0.0" $port $config_file $1 $log_file
		echo $node > $TMP_ID_PATH/${1}

		[ "$1" = "TCP" ] && {
			[ "$(config_t_get global udp_node nil)" = "tcp" ] && {
				top -bn1 | grep -E "$TMP_PATH" | grep -i "UDP" | grep -v "grep" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
				UDP_NODE=$node
				start_redir UDP
			}
		}

		#local node_net=$(echo $1 | tr 'A-Z' 'a-z')
		#uci set $CONFIG.@global[0].${node_net}_node=$node
		#uci commit $CONFIG
		source $APP_PATH/helper_${DNS_N}.sh logic_restart
	}
}

start_redir() {
	eval node=\$${1}_NODE
	[ "$node" != "nil" ] && {
		TYPE=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
		local config_file=$TMP_PATH/${1}.json
		local log_file=$TMP_PATH/${1}.log
		eval current_port=\$${1}_REDIR_PORT
		local port=$(echo $(get_new_port $current_port $1))
		eval ${1}_REDIR=$port
		run_redir $node "0.0.0.0" $port $config_file $1 $log_file
		#eval ip=\$${1}_NODE_IP
		echo $node > $TMP_ID_PATH/${1}
		echo $port > $TMP_PORT_PATH/${1}
	}
}

start_socks() {
	local ids=$(uci show $CONFIG | grep "=socks" | awk -F '.' '{print $2}' | awk -F '=' '{print $1}')
	echolog "分析 Socks 服务的节点配置..."
	for id in $ids; do
		local enabled=$(config_n_get $id enabled 0)
		[ "$enabled" == "0" ] && continue
		local node=$(config_n_get $id node nil)
		[ "$node" == "nil" ] && continue
		local port=$(config_n_get $id port)
		local config_file=$TMP_PATH/SOCKS_${id}.json
		local log_file=$TMP_PATH/SOCKS_${id}.log
		local http_port=$(config_n_get $id http_port 0)
		local http_config_file=$TMP_PATH/HTTP2SOCKS_${id}.json
		[ "$node" == "tcp" ] && {
			tcp_node_socks=1
			tcp_node_socks_port=$port
			tcp_node_socks_id=$id
			[ "$http_port" != "0" ] && {
				tcp_node_http=1
				tcp_node_http_port=$http_port
				tcp_node_http_id=$id
			}
			continue
		}
		run_socks $id $node "0.0.0.0" $port $config_file $http_port $http_config_file
	done
}

clean_log() {
	logsnum=$(cat $LOG_FILE 2>/dev/null | wc -l)
	[ "$logsnum" -gt 1000 ] && {
		echo "" > $LOG_FILE
		echolog "日志文件过长，清空处理！"
	}
}

clean_crontab() {
	touch /etc/crontabs/root
	#sed -i "/${CONFIG}/d" /etc/crontabs/root >/dev/null 2>&1
	sed -i "/$(echo "/etc/init.d/${CONFIG}" | sed 's#\/#\\\/#g')/d" /etc/crontabs/root >/dev/null 2>&1
	sed -i "/$(echo "lua ${APP_PATH}/rule_update.lua log" | sed 's#\/#\\\/#g')/d" /etc/crontabs/root >/dev/null 2>&1
	sed -i "/$(echo "lua ${APP_PATH}/subscribe.lua start log" | sed 's#\/#\\\/#g')/d" /etc/crontabs/root >/dev/null 2>&1
}

start_crontab() {
	clean_crontab
	auto_on=$(config_t_get global_delay auto_on 0)
	if [ "$auto_on" = "1" ]; then
		time_off=$(config_t_get global_delay time_off)
		time_on=$(config_t_get global_delay time_on)
		time_restart=$(config_t_get global_delay time_restart)
		[ -z "$time_off" -o "$time_off" != "nil" ] && {
			echo "0 $time_off * * * /etc/init.d/$CONFIG stop" >>/etc/crontabs/root
			echolog "配置定时任务：每天 $time_off 点关闭服务。"
		}
		[ -z "$time_on" -o "$time_on" != "nil" ] && {
			echo "0 $time_on * * * /etc/init.d/$CONFIG start" >>/etc/crontabs/root
			echolog "配置定时任务：每天 $time_on 点开启服务。"
		}
		[ -z "$time_restart" -o "$time_restart" != "nil" ] && {
			echo "0 $time_restart * * * /etc/init.d/$CONFIG restart" >>/etc/crontabs/root
			echolog "配置定时任务：每天 $time_restart 点重启服务。"
		}
	fi
	[ "$NO_PROXY" == 1 ] && {
		echolog "运行于非代理模式，仅允许服务启停的定时任务。"
		/etc/init.d/cron restart
		return
	}

	autoupdate=$(config_t_get global_rules auto_update)
	weekupdate=$(config_t_get global_rules week_update)
	dayupdate=$(config_t_get global_rules time_update)
	if [ "$autoupdate" = "1" ]; then
		local t="0 $dayupdate * * $weekupdate"
		[ "$weekupdate" = "7" ] && t="0 $dayupdate * * *"
		echo "$t lua $APP_PATH/rule_update.lua log > /dev/null 2>&1 &" >>/etc/crontabs/root
		echolog "配置定时任务：自动更新规则。"
	fi

	autoupdatesubscribe=$(config_t_get global_subscribe auto_update_subscribe)
	weekupdatesubscribe=$(config_t_get global_subscribe week_update_subscribe)
	dayupdatesubscribe=$(config_t_get global_subscribe time_update_subscribe)
	if [ "$autoupdatesubscribe" = "1" ]; then
		local t="0 $dayupdatesubscribe * * $weekupdatesubscribe"
		[ "$weekupdatesubscribe" = "7" ] && t="0 $dayupdatesubscribe * * *"
		echo "$t lua $APP_PATH/subscribe.lua start log > /dev/null 2>&1 &" >>/etc/crontabs/root
		echolog "配置定时任务：自动更新节点订阅。"
	fi

	start_daemon=$(config_t_get global_delay start_daemon 0)
	[ "$start_daemon" = "1" ] && $APP_PATH/monitor.sh > /dev/null 2>&1 &

	AUTO_SWITCH_ENABLE=$(config_t_get auto_switch enable 0)
	[ "$AUTO_SWITCH_ENABLE" = "1" ] && $APP_PATH/test.sh > /dev/null 2>&1 &

	/etc/init.d/cron restart
}

stop_crontab() {
	clean_crontab
	/etc/init.d/cron restart
	#echolog "清除定时执行命令。"
}

start_dns() {
	local pdnsd_forward other_port msg
	dns_listen_port=${DNS_PORT}
	pdnsd_forward=${DNS_FORWARD}

	china_ng_listen_port=$(expr $dns_listen_port + 1)
	china_ng_listen="127.0.0.1#${china_ng_listen_port}"
	china_ng_chn=$(echo -n $(echo "${LOCAL_DNS}" | sed "s/,/\n/g" | head -n2) | tr " " ",")
	china_ng_gfw="127.0.0.1#${dns_listen_port}"
	[ -n "${returnhome}" ] && china_ng_chn="${china_ng_gfw}" && china_ng_gfw="${LOCAL_DNS}"

	echolog "过滤服务配置：准备接管域名解析..."

	case "$DNS_MODE" in
	nonuse)
		echolog "  - 不过滤DNS..."
		TUN_DNS=""
		use_chinadns_ng=$(config_t_get global always_use_chinadns_ng 0)
		[ "$use_chinadns_ng" == "0" ] && return
	;;
	dns2socks)
		local dns2socks_socks_server=$(echo $(config_t_get global socks_server 127.0.0.1:9050) | sed "s/#/:/g")
		local dns2socks_forward=$(get_first_dns DNS_FORWARD 53 | sed 's/#/:/g')
		[ "$DNS_CACHE" == "0" ] && local dns2sock_cache="/d"
		ln_start_bin "$(first_type dns2socks)" dns2socks "/dev/null" "$dns2socks_socks_server" "$dns2socks_forward" "127.0.0.1:$dns_listen_port" $dns2sock_cache
		echolog "  - dns2sock(127.0.0.1:${dns_listen_port}${dns2sock_cache})，${dns2socks_socks_server:-127.0.0.1:9050} -> ${dns2socks_forward-D8.8.8.8:53}"
		echolog "  - 域名解析：dns2socks..."
	;;
	xray_doh)
		up_trust_doh_dns=$(config_t_get global up_trust_doh_dns "tcp")
		if [ "$up_trust_doh_dns" = "socks" ]; then
			use_tcp_node_resolve_dns=0
			msg="Socks节点"
		elif [ "${up_trust_doh_dns}" = "tcp" ]; then
			use_tcp_node_resolve_dns=1
			msg="TCP节点"
		fi
		up_trust_doh=$(config_t_get global up_trust_doh "https://dns.google/dns-query,8.8.4.4")
		_doh_url=$(echo $up_trust_doh | awk -F ',' '{print $1}')
		_doh_host_port=$(echo $_doh_url | sed "s/https:\/\///g" | awk -F '/' '{print $1}')
		_doh_host=$(echo $_doh_host_port | awk -F ':' '{print $1}')
		_doh_port=$(echo $_doh_host_port | awk -F ':' '{print $2}')
		_doh_bootstrap=$(echo $up_trust_doh | cut -d ',' -sf 2-)

		up_trust_doh_dns=$(config_t_get global up_trust_doh_dns "tcp")
		if [ "$up_trust_doh_dns" = "socks" ]; then
			socks_server=$(echo $(config_t_get global socks_server 127.0.0.1:9050) | sed "s/#/:/g")
			socks_address=$(echo $socks_server | awk -F ':' '{print $1}')
			socks_port=$(echo $socks_server | awk -F ':' '{print $2}')
			lua $API_GEN_XRAY -dns_listen_port "${dns_listen_port}" -dns_server "${_doh_bootstrap}" -doh_url "${_doh_url}" -doh_host "${_doh_host}" -doh_socks_address "${socks_address}" -doh_socks_port "${socks_port}" > $TMP_PATH/DNS.json
			ln_start_bin "$(first_type $(config_t_get global_app xray_file) xray)" xray $TMP_PATH/DNS.log -config="$TMP_PATH/DNS.json"
		elif [ "${up_trust_doh_dns}" = "tcp" ]; then
			DNS_FORWARD=""
			_doh_bootstrap_dns=$(echo $_doh_bootstrap | sed "s/,/ /g")
			for _dns in $_doh_bootstrap_dns; do
				_dns=$(echo $_dns | awk -F ':' '{print $1}'):${_doh_port:-443}
				[ -n "$DNS_FORWARD" ] && DNS_FORWARD=${DNS_FORWARD},${_dns} || DNS_FORWARD=${_dns}
			done
			lua $API_GEN_XRAY -dns_listen_port "${dns_listen_port}" -dns_server "${_doh_bootstrap}" -doh_url "${_doh_url}" -doh_host "${_doh_host}" > $TMP_PATH/DNS.json
			ln_start_bin "$(first_type $(config_t_get global_app xray_file) xray)" xray $TMP_PATH/DNS.log -config="$TMP_PATH/DNS.json"
			unset _dns _doh_bootstrap_dns
		fi
		unset _doh_url _doh_port _doh_bootstrap
		echolog "  - 域名解析 Xray DNS(DoH)..."
	;;
	pdnsd)
		gen_pdnsd_config "${dns_listen_port}" "${pdnsd_forward}"
		ln_start_bin "$(first_type pdnsd)" pdnsd "/dev/null" --daemon -c "${TMP_PATH}/pdnsd/pdnsd.conf" -d
		echolog "  - 域名解析：pdnsd + 使用(TCP节点)解析域名..."
	;;
	udp)
		use_udp_node_resolve_dns=1
		TUN_DNS=${DNS_FORWARD}
		echolog "  - 域名解析：直接使用UDP节点请求DNS（$TUN_DNS）"
	;;
	fake_ip)
		TUN_DNS="11.1.1.1"
		echolog "  - 域名解析：使用FakeIP方案..."
	;;
	custom)
		custom_dns=$(config_t_get global custom_dns)
		TUN_DNS="$(echo ${custom_dns} | sed 's/:/#/g')"
		echolog "  - 域名解析：使用UDP协议自定义DNS（$TUN_DNS）解析..."
	;;
	esac

	[ -n "$chnlist" ] && [ "$DNS_MODE" != "custom" ] && [ "$DNS_MODE" != "fake_ip" ] && {
		[ -n "$(first_type chinadns-ng)" ] && {
			echolog "发现ChinaDNS-NG，将启动。"
			CHINADNS_NG=1
		}
		[ -n "$CHINADNS_NG" ] && {
			echolog "  | - (chinadns-ng) 只支持2~4级的域名过滤..."
			if [ "$DNS_MODE" = "pdnsd" ]; then
				msg="pdnsd"
			elif [ "$DNS_MODE" = "dns2socks" ]; then
				msg="dns2socks"
			elif [ "$DNS_MODE" = "xray_doh" ]; then
				msg="Xray DNS(DoH)"
			elif [ "$DNS_MODE" = "udp" ]; then
				use_udp_node_resolve_dns=1
				china_ng_gfw="${DNS_FORWARD}"
				msg="udp"
			elif [ "$DNS_MODE" = "custom" ]; then
				custom_dns=$(config_t_get global custom_dns)
				china_ng_gfw="$(echo ${custom_dns} | sed 's/:/#/g')"
				msg="自定义DNS"
			fi

			local gfwlist_param="${TMP_PATH}/chinadns_gfwlist"
			[ -f "${RULES_PATH}/gfwlist" ] && cp -a "${RULES_PATH}/gfwlist" "${gfwlist_param}"
			local chnlist_param="${TMP_PATH}/chinadns_chnlist"
			[ -f "${RULES_PATH}/chnlist" ] && cp -a "${RULES_PATH}/chnlist" "${chnlist_param}"

			[ -f "${RULES_PATH}/proxy_host" ] && {
				cat "${RULES_PATH}/proxy_host" >> "${gfwlist_param}"
				echolog "  | - [$?](chinadns-ng) 代理域名表合并到防火墙域名表"
			}
			[ -f "${RULES_PATH}/direct_host" ] && {
				cat "${RULES_PATH}/direct_host" >> "${chnlist_param}"
				echolog "  | - [$?](chinadns-ng) 域名白名单合并到中国域名表"
			}
			chnlist_param=${chnlist_param:+-m "${chnlist_param}" -M}
			local log_path="${TMP_PATH}/chinadns-ng.log"
			log_path="/dev/null"
			ln_start_bin "$(first_type chinadns-ng)" chinadns-ng "$log_path" -v -b 0.0.0.0 -l "${china_ng_listen_port}" ${china_ng_chn:+-c "${china_ng_chn}"} ${chnlist_param} ${china_ng_gfw:+-t "${china_ng_gfw}"} ${gfwlist_param:+-g "${gfwlist_param}"} -f
			echolog "  + 过滤服务：ChinaDNS-NG(:${china_ng_listen_port}) + ${msg}：国内DNS：${china_ng_chn:-D114.114.114.114}，可信DNS：${china_ng_gfw:-D8.8.8.8}"
			#[ -n "${global}${chnlist}" ] && [ -z "${returnhome}" ] && TUN_DNS="${china_ng_gfw}"
		}
	}

	[ "${use_udp_node_resolve_dns}" = "1" ] && echolog "  * 要求代理 DNS 请求，如上游 DNS 非直连地址，确保 UDP 代理打开，并且已经正确转发！"
	[ "${use_tcp_node_resolve_dns}" = "1" ] && echolog "  * 请确认上游 DNS 支持 TCP 查询，如非直连地址，确保 TCP 代理打开，并且已经正确转发！"
}

gen_pdnsd_config() {
	local listen_port=${1}
	local up_dns=${2}
	local pdnsd_dir=${TMP_PATH}/pdnsd
	local perm_cache=2048
	local _cache="on"
	local query_method="tcp_only"

	mkdir -p "${pdnsd_dir}"
	touch "${pdnsd_dir}/pdnsd.cache"
	chown -R root.nogroup "${pdnsd_dir}"
	if [ "${use_udp_node_resolve_dns}" = "1" ]; then
		query_method="udp_only"
	else
		use_tcp_node_resolve_dns=1
	fi
	[ "${DNS_CACHE}" = "0" ] && _cache="off" && perm_cache=0
	cat > "${pdnsd_dir}/pdnsd.conf" <<-EOF
		global {
			perm_cache = $perm_cache;
			cache_dir = "$pdnsd_dir";
			run_as = "root";
			server_ip = 127.0.0.1;
			server_port = ${listen_port};
			status_ctl = on;
			query_method = ${query_method};
			min_ttl = 1h;
			max_ttl = 1w;
			timeout = 10;
			par_queries = 2;
			neg_domain_pol = on;
			udpbufsize = 1024;
			proc_limit = 2;
			procq_limit = 8;
		}

	EOF
	echolog "  + [$?]Pdnsd (127.0.0.1:${listen_port})..."

	append_pdnsd_updns() {
		[ -z "${2}" ] && echolog "  | - 略过错误 : ${1}" && return 0
		cat >> $pdnsd_dir/pdnsd.conf <<-EOF
			server {
				label = "node-${2}_${3}";
				ip = ${2};
				edns_query = on;
				port = ${3};
				timeout = 4;
				interval = 10m;
				uptest = none;
				purge_cache = off;
				proxy_only = on;
				caching = $_cache;
				reject = ::/0;
				reject_policy = negate;
			}
		EOF
		echolog "  | - [$?]上游DNS：${2}:${3}"
	}
	hosts_foreach up_dns append_pdnsd_updns 53
}

add_ip2route() {
	local ip=$(get_host_ip "ipv4" $1)
	[ -z "$ip" ] && {
		echolog "  - 无法解析${1}，路由表添加失败！"
		return 1
	}
	local remarks="${1}"
	[ "$remarks" != "$ip" ] && remarks="${1}(${ip})"
	local interface=$2
	local retries=5
	local failcount=0
	while [ "$failcount" -lt $retries ]; do
		unset msg
		ip route show dev ${interface} >/dev/null 2>&1
		if [ $? -ne 0 ]; then
			let "failcount++"
			echolog "  - 找不到出口接口：$interface，1分钟后再重试(${failcount}/${retries})，${ip}"
			[ "$failcount" -ge $retries ] && return 1
			sleep 1m
		else
			route add -host ${ip} dev ${interface} >/dev/null 2>&1
			echolog "  - ${remarks}添加路由表${interface}接口成功！"
			echo "$ip" >> $TMP_ROUTE_PATH/${interface}
			break
		fi
	done
}

delete_ip2route() {
	[ -d "${TMP_ROUTE_PATH}" ] && {
		for interface in $(ls ${TMP_ROUTE_PATH}); do
			for ip in $(cat ${TMP_ROUTE_PATH}/${interface}); do
				route del -host ${ip} dev ${interface} >/dev/null 2>&1
			done
		done
	}
}

start_haproxy() {
	local haproxy_path haproxy_file item items lport sort_items

	[ "$(config_t_get global_haproxy balancing_enable 0)" != "1" ] && return
	echolog "HAPROXY 负载均衡..."

	haproxy_path=${TMP_PATH}/haproxy
	mkdir -p "${haproxy_path}"
	haproxy_file=${haproxy_path}/config.cfg
	cat <<-EOF > "${haproxy_file}"
		global
		    log         127.0.0.1 local2
		    chroot      ${haproxy_path}
		    maxconn     60000
		    stats socket  ${haproxy_path}/haproxy.sock
		    daemon

		defaults
		    mode                    tcp
		    log                     global
		    option                  tcplog
		    option                  dontlognull
		    option http-server-close
		    #option forwardfor       except 127.0.0.0/8
		    option                  redispatch
		    retries                 2
		    timeout http-request    10s
		    timeout queue           1m
		    timeout connect         10s
		    timeout client          1m
		    timeout server          1m
		    timeout http-keep-alive 10s
		    timeout check           10s
		    maxconn                 3000

	EOF

	items=$(get_enabled_anonymous_secs "@haproxy_config")
	for item in $items; do
		lport=$(config_n_get ${item} haproxy_port 0)
		[ "${lport}" = "0" ] && echolog "  - 丢弃1个明显无效的节点" && continue
		sort_items="${sort_items}${IFS}${lport} ${item}"
	done

	items=$(echo "${sort_items}" | sort -n | cut -d ' ' -sf 2)

	unset lport
	local haproxy_port lbss lbort lbweight export backup
	local msg bip bport hasvalid bbackup failcount interface
	for item in ${items}; do
		unset haproxy_port lbort bbackup

		eval $(uci -q show "${CONFIG}.${item}" | cut -d '.' -sf 3-)
		get_ip_port_from "$lbss" bip bport

		[ "$lbort" = "default" ] && lbort=$bport || bport=$lbort
		[ -z "$haproxy_port" ] || [ -z "$bip" ] || [ -z "$lbort" ] && echolog "  - 丢弃1个明显无效的节点" && continue
		[ "$backup" = "1" ] && bbackup="backup"

		[ "$lport" = "${haproxy_port}" ] || {
			hasvalid="1"
			lport=${haproxy_port}
			echolog "  + 入口 0.0.0.0:${lport}..."
			cat <<-EOF >> "${haproxy_file}"
				listen $lport
				    mode tcp
				    bind 0.0.0.0:$lport
			EOF
		}

		cat <<-EOF >> "${haproxy_file}"
			    server $bip:$bport $bip:$bport weight $lbweight check inter 1500 rise 1 fall 3 $bbackup
		EOF

		if [ "$export" != "0" ]; then
			add_ip2route ${bip} ${export} > /dev/null 2>&1 &
		fi
		echolog "  | - 出口节点：${bip}:${bport}，权重：${lbweight}"
	done

	# 控制台配置
	local console_port=$(config_t_get global_haproxy console_port)
	local console_user=$(config_t_get global_haproxy console_user)
	local console_password=$(config_t_get global_haproxy console_password)
	local auth=""
	[ -n "$console_user" ] && [ -n "$console_password" ] && auth="stats auth $console_user:$console_password"
	cat <<-EOF >> "${haproxy_file}"

		listen console
		    bind 0.0.0.0:$console_port
		    mode http
		    stats refresh 30s
		    stats uri /
		    stats admin if TRUE
		    $auth
	EOF

	[ "${hasvalid}" != "1" ] && echolog "  - 没有发现任何有效节点信息，不启动。" && return 0
	ln_start_bin "$(first_type haproxy)" haproxy "/dev/null" -f "${haproxy_file}"
	echolog "  * 控制台端口：${console_port}/，${auth:-公开}"
}

kill_all() {
	kill -9 $(pidof "$@") >/dev/null 2>&1
}

force_stop() {
	stop
	exit 0
}

boot() {
	[ "$ENABLED" == 1 ] && {
		local delay=$(config_t_get global_delay start_delay 1)
		if [ "$delay" -gt 0 ]; then
			echolog "执行启动延时 $delay 秒后再启动!"
			sleep $delay && start >/dev/null 2>&1 &
		else
			start
		fi
	}
	return 0
}

start() {
	load_config
	start_haproxy
	[ "$SOCKS_ENABLED" = "1" ] && {
		start_socks
	}
	[ "$NO_PROXY" == 1 ] || {
		start_redir TCP
		start_redir UDP
		start_dns
		source $APP_PATH/helper_${DNS_N}.sh add
		source $APP_PATH/iptables.sh start
		source $APP_PATH/helper_${DNS_N}.sh logic_restart
	}
	start_crontab
	echolog "运行完成！\n"
}

stop() {
	clean_log
	source $APP_PATH/iptables.sh stop
	delete_ip2route
	kill_all v2ray-plugin obfs-local
	top -bn1 | grep -v "grep" | grep "sleep" | grep -E "9s|58s" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	top -bn1 | grep -v "grep" | grep -v "app.sh" | grep "${CONFIG}/" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	rm -rf $TMP_PATH
	unset XRAY_LOCATION_ASSET
	stop_crontab
	source $APP_PATH/helper_${DNS_N}.sh del
	source $APP_PATH/helper_${DNS_N}.sh restart
	echolog "清空并关闭相关程序和缓存完成。"
}

arg1=$1
shift
case $arg1 in
get_new_port)
	get_new_port $@
	;;
run_socks)
	run_socks $@
	;;
run_redir)
	run_redir $@
	;;
node_switch)
	node_switch $@
	;;
stop)
	[ "$1" = "force" ] && force_stop
	stop
	;;
start)
	start
	;;
boot)
	boot
	;;
esac
