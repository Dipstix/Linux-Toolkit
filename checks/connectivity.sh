#!/bin/sh
#
# connectivity - can this host reach its gateway and the outside world?
# Pings the default gateway, opens TCP connections to a few targets (by
# IP and by name, to tell routing problems from DNS ones) and optionally
# fetches a URL through any configured proxy.

TK_NAME=connectivity
TK_DESC='Ping the gateway, open TCP connections to targets, and optionally fetch a URL'
TK_OPTIONS='      --target LIST  Comma-separated host:port pairs to connect to
                     (default 1.1.1.1:443,example.com:443)
      --url URL      Also fetch URL with curl or wget (uses any proxy set)
      --timeout N    Seconds to wait for each test (default 3)
      --no-ping      Do not ping the default gateway'
TK_HELP_EXTRA='The default targets are Cloudflare DNS (by IP) and example.com (by name):
if the IP works but the name does not, the problem is DNS (toolkit dns).
TCP tests use nc, bash or curl, whichever is installed.'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

targets='' url='' timeout=3 ping=1
while [ $# -gt 0 ]; do
	case $1 in
	--target) tk_need_arg "$@"; targets="${targets:+$targets,}$2"; shift ;;
	--url) tk_need_arg "$@"; url=$2; shift ;;
	--timeout) tk_need_arg "$@"; timeout=$2; shift ;;
	--no-ping) ping=0 ;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done
[ -n "$targets" ] || targets=1.1.1.1:443,example.com:443
for t in $(printf '%s' "$targets" | tr ',' ' '); do
	case $(printf '%s' "$t" | tr -d '[]') in
	*[!A-Za-z0-9.:_-]* | *:) tk_usage_error "--target takes host:port pairs, e.g. db01:5432,[2001:db8::1]:443" ;;
	*:*) case ${t##*:} in *[!0-9]*) tk_usage_error "--target: '$t' has no port number" ;; esac ;;
	*) tk_usage_error "--target: '$t' needs a port, e.g. $t:443" ;;
	esac
done
case $url in '' | http://* | https://*) ;; *) tk_usage_error "--url must start with http:// or https://" ;; esac
if ! tk_is_uint "$timeout" || [ "$timeout" -eq 0 ]; then
	tk_usage_error "--timeout needs a whole number of seconds above 0"
fi

# tcp_tool: which tool can open a TCP connection here.
tcp_tool() {
	if tk_has nc; then echo nc
	elif tk_has bash; then echo bash
	elif tk_has curl; then echo curl
	fi
}

# connect HOST PORT: 0 connected, 1 failed.
connect() {
	case $tool in
	nc) tk_timeout "$((timeout + 1))" nc -z -w "$timeout" "$1" "$2" >/dev/null 2>&1 ;;
	bash)
		# shellcheck disable=SC2016 # expanded by bash, not here
		tk_timeout "$timeout" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" >/dev/null 2>&1
		;;
	curl)
		# telnet:// just opens the connection; a non-zero connect time
		# means it opened, even if curl then times out waiting for data.
		_tc=$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout "$timeout" -m "$((timeout + 1))" \
			"telnet://$1:$2" </dev/null 2>/dev/null)
		case ${_tc:-0} in 0 | 0.0 | 0.00* | 0,00*) return 1 ;; esac
		return 0
		;;
	esac
}

# is_ip HOST: an IPv4 or IPv6 literal, not a name.
is_ip() {
	case $1 in
	*:*) return 0 ;;
	*[!0-9.]*) return 1 ;;
	esac
	return 0
}

gateway() {
	awk "$(tk_net_awk)"' NR > 1 && $2 == "00000000" && $8 == "00000000" && $3 != "00000000" { print hexval($7), ip4($3) }' \
		"$TK_PROC/net/route" 2>/dev/null | sort -n | head -n 1 | awk '{ print $2 }'
}

tk_start

proxy=${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}
# Only show where the proxy is, not any user:password in it.
proxy_shown=$(printf '%s' "$proxy" | sed 's|//[^@/]*@|//|')

# --- Gateway -------------------------------------------------------------------
tk_section "Gateway"
gw=$(gateway)
tk_kv "Default gateway" "$gw"
if [ -z "$gw" ]; then
	tk_info "No IPv4 default gateway to ping (see toolkit network)"
elif [ "$ping" = 0 ]; then
	tk_info "Gateway ping skipped (--no-ping)"
elif ! tk_has ping; then
	tk_skip "ping not found (install: $(tk_install_hint iputils-ping))"
else
	out=$(tk_timeout "$((timeout + 2))" ping -c 1 -W "$timeout" "$gw" 2>&1)
	rc=$?
	ms=$(printf '%s\n' "$out" | sed -n 's/.*time[=<]\([0-9.]*\) *ms.*/\1/p' | head -n 1)
	if [ "$rc" = 0 ]; then
		tk_kvn "Gateway ping ms" "$ms" "${ms:+$ms ms}"
		tk_ok "The gateway $gw answers ping${ms:+ in $ms ms}"
	else
		case $out in
		*"ermission denied"* | *"not permitted"* | *"must be root"* | *"socket:"*)
			tk_skip "Not allowed to ping here (needs root or the net.ipv4.ping_group_range sysctl)"
			;;
		*)
			tk_kvn "Gateway ping ms" ""
			tk_warn "The gateway $gw does not answer ping; it may just block ICMP, see the tests below"
			;;
		esac
	fi
fi

# --- TCP connections -----------------------------------------------------------
tk_section "Connections"
tool=$(tcp_tool)
tk_kv "Tool" "$tool"
tk_kvn "Timeout seconds" "$timeout"
ok_n=0 fail_n=0 ip_ok=0 name_fail=0 items=''
if [ -z "$tool" ]; then
	tk_skip "No nc, bash or curl to test TCP connections with (install: $(tk_install_hint netcat-openbsd))"
else
	for t in $(printf '%s' "$targets" | tr ',' ' '); do
		port=${t##*:} host=${t%:*}
		host=${host#[} host=${host%]}
		if connect "$host" "$port"; then
			ok_n=$((ok_n + 1)) res=true
			is_ip "$host" && ip_ok=1
			tk_print '  %-36s %s\n' "$host:$port" connected
			tk_ok "Connected to $host port $port"
		else
			fail_n=$((fail_n + 1)) res=false
			is_ip "$host" || name_fail=1
			tk_print '  %-36s %s\n' "$host:$port" failed
			tk_warn "Could not connect to $host port $port within ${timeout}s"
		fi
		items="${items:+$items,}{\"host\":$(tk_json_str "$host"),\"port\":$port,\"connected\":$res}"
	done
	tk_kvj "Results" "[$items]"
	if [ "$ok_n" = 0 ]; then
		if [ -n "$proxy" ]; then
			tk_crit "No target could be reached directly; a proxy is configured ($proxy_shown), so try --url to test through it"
		else
			tk_crit "No target could be reached; check the default route (toolkit network) and any outbound firewall"
		fi
	elif [ "$ip_ok" = 1 ] && [ "$name_fail" = 1 ]; then
		tk_warn "Targets by IP work but some by name fail; check name resolution with toolkit dns"
	fi
fi

# --- Proxy and URL ---------------------------------------------------------------
tk_section "HTTP"
tk_kv "Proxy" "$proxy_shown"
if [ -n "$url" ]; then
	tk_kv "URL" "$url"
	if tk_has curl; then
		code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "$timeout" -m "$((timeout * 3))" "$url" 2>/dev/null)
		rc=$?
		[ "$code" = 000 ] && code=''
	elif tk_has wget; then
		# wget only says whether it worked; 8 means the server answered
		# with an error status, which still proves the path works.
		tk_timeout "$((timeout * 3))" wget -q -O /dev/null -T "$timeout" "$url" >/dev/null 2>&1
		rc=$?
		case $rc in 0) code=200 ;; 8) code=4xx/5xx rc=0 ;; *) code='' ;; esac
	else
		rc=-1 code=''
		tk_skip "curl or wget not found, so --url was not tested (install: $(tk_install_hint curl))"
	fi
	tk_kv "HTTP status" "$code"
	if [ "$rc" = 0 ] && [ -n "$code" ]; then
		case $code in
		[45]*) tk_warn "$url answered with HTTP $code" ;;
		*) tk_ok "Fetched $url (HTTP ${code:-?})" ;;
		esac
	elif [ "$rc" != -1 ]; then
		tk_crit "Could not fetch $url${proxy:+ through the proxy $proxy_shown}"
	fi
elif [ -n "$proxy" ]; then
	tk_info "A proxy is set ($proxy_shown); add --url https://... to test fetching through it"
fi

tk_finish
