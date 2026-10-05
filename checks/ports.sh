#!/bin/sh
#
# ports - what is listening, on which addresses, and by which process?
# Flags services that are usually meant to be private (databases, Docker
# API, telnet...) when they listen on every interface. Reads /proc/net
# directly, so it needs neither ss nor netstat.

TK_NAME=ports
TK_DESC='Listening TCP/UDP ports and their processes; flags risky services open to the network'
TK_OPTIONS='      --expect LIST  Comma-separated ports that must be listening, e.g.
                     --expect 22,443 (critical if one is not); 53/udp for UDP'
TK_HELP_EXTRA='"Exposed" means listening on something other than loopback; a firewall
may still block it (see toolkit firewall). Run as root to see which
process owns every socket.'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

expect=''
while [ $# -gt 0 ]; do
	case $1 in
	--expect) tk_need_arg "$@"; expect="${expect:+$expect,}$2"; shift ;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done
for p in $(printf '%s' "$expect" | tr ',' ' '); do
	case ${p%/*} in '' | *[!0-9]*) tk_usage_error "--expect takes port numbers, e.g. 22,443,53/udp" ;; esac
	case $p in */*) case ${p#*/} in tcp | udp) ;; *) tk_usage_error "--expect: protocol must be tcp or udp" ;; esac ;; esac
done

# Listening sockets: "proto address port inode". TCP state 0A is LISTEN;
# a UDP socket with no remote end (state 07) is waiting for packets.
sockets() {
	for _p in tcp tcp6 udp udp6; do
		[ -r "$TK_PROC/net/$_p" ] || continue
		awk -v proto="$_p" "$(tk_net_awk)"' NR > 1 {
			split($2, l, ":"); split($3, r, ":")
			if (proto ~ /^tcp/ && $4 != "0A") next
			if (proto ~ /^udp/ && ($4 != "07" || r[2] != "0000")) next
			a = (proto ~ /6$/) ? ip6w(l[1]) : ip4(l[1])
			print substr(proto, 1, 3), a, hexval(l[2]), $10
		}' "$TK_PROC/net/$_p"
	done
}

# Socket inode -> "comm/pid", from the fd links of every process we can
# see. /dev/null makes ls print a header for each directory, even one.
owners() {
	# shellcheck disable=SC2012 # ls -l is the portable way to read many links
	ls -l "$TK_PROC"/[0-9]*/fd /dev/null 2>/dev/null | awk -v proc="$TK_PROC" '
		/:$/ { pid = $0; sub(/\/fd:$/, "", pid); sub(/.*\//, "", pid); next }
		/socket:\[/ {
			i = $NF; gsub(/[^0-9]/, "", i)
			if (i in seen) next
			seen[i] = 1; c = ""; f = proc "/" pid "/comm"
			if ((getline c < f) <= 0) c = "?"
			close(f); gsub(/[ \t]/, "_", c)
			print i, c "/" pid
		}'
}

# Ports that are usually meant to stay private: port|proto|name|level|advice.
risky='2375|tcp|Docker API (no TLS)|crit|anyone who reaches it has root on this host; bind it to a socket or use TLS on 2376
23|tcp|telnet|warn|it sends passwords in clear text; use SSH
21|tcp|FTP|warn|it sends passwords in clear text; use SFTP
512|tcp|rexec|warn|it sends passwords in clear text; use SSH
513|tcp|rlogin|warn|it sends passwords in clear text; use SSH
514|tcp|rsh|warn|it trusts the client blindly; use SSH
3306|tcp|MySQL/MariaDB|warn|bind it to 127.0.0.1 or firewall it to the app servers
5432|tcp|PostgreSQL|warn|bind it to 127.0.0.1 or firewall it to the app servers
6379|tcp|Redis|warn|Redis has no password by default; bind it to 127.0.0.1
27017|tcp|MongoDB|warn|bind it to 127.0.0.1 or firewall it
9200|tcp|Elasticsearch|warn|bind it to 127.0.0.1 or firewall it
5984|tcp|CouchDB|warn|bind it to 127.0.0.1 or firewall it
11211|tcp|Memcached|warn|it has no authentication; bind it to 127.0.0.1
11211|udp|Memcached|warn|it can be abused for DDoS amplification; disable UDP (-U 0)
2049|tcp|NFS|info|make sure /etc/exports limits which hosts may mount
111|tcp|rpcbind|info|only needed for NFSv3; firewall it if unused
445|tcp|SMB|info|firewall it unless Windows file sharing is meant to be reachable
5900|tcp|VNC|warn|VNC passwords are weak; tunnel it over SSH
10250|tcp|Kubelet API|warn|make sure anonymous auth is disabled'

tk_start

socks=$(sockets)
own=$(owners)
# proto address port owner, sorted by protocol and port, duplicates gone.
list=$(printf '%s\n--\n%s\n' "$own" "$socks" | awk '
	!sep { if ($0 == "--") sep = 1; else own[$1] = $2; next }
	NF >= 4 { print $1, $2, $3, (($4 in own) ? own[$4] : "-") }' | sort -u | sort -k 1,1 -k 3,3n)

tk_section "Listening"
tk_print '  %-5s %-28s %-6s %s\n' PROTO ADDRESS PORT PROCESS
items='' n=0 n_exp=0 unknown=0
while read -r proto addr port who; do
	[ -n "$proto" ] || continue
	n=$((n + 1))
	case $addr in
	127.* | ::1 | ::ffff:127.*) exposed=false ;;
	*) exposed=true n_exp=$((n_exp + 1)) ;;
	esac
	[ "$who" = - ] && unknown=$((unknown + 1))
	pname=${who%/*} pid=${who##*/}
	[ "$who" = - ] && pname='' pid=''
	tk_print '  %-5s %-28s %-6s %s\n' "$proto" "$addr" "$port" "$who"
	items="${items:+$items,}{\"proto\":\"$proto\",\"address\":$(tk_json_str "$addr"),\"port\":$port,\"exposed\":$exposed,\"process\":$(if [ -n "$pname" ]; then tk_json_str "$pname"; else printf null; fi),\"pid\":${pid:-null}}"
done <<EOF
$list
EOF
tk_kvn "Count" "$n"
tk_kvn "Exposed" "$n_exp"
tk_kvj "Sockets" "[$items]"
if [ "$n" = 0 ] && [ ! -r "$TK_PROC/net/tcp" ]; then
	tk_skip "Cannot read $TK_PROC/net/tcp"
else
	tk_info "$n listening socket(s), $n_exp reachable from other hosts unless a firewall blocks them"
fi
[ "$unknown" -gt 0 ] && { tk_want_root "the process is unknown for $unknown socket(s)" || :; }

# --- Risky services on the network ------------------------------------------
tk_section "Exposure"
found=0
while IFS='|' read -r rport rproto rname level advice; do
	[ -n "$rport" ] || continue
	hit=$(printf '%s\n' "$list" | awk -v p="$rport" -v t="$rproto" '$1 == t && $3 == p && $2 !~ /^(127\.|::1$|::ffff:127\.)/ { print $2 ":" $3 " (" $4 ")"; exit }')
	[ -n "$hit" ] || continue
	found=$((found + 1))
	msg="$rname listens on $hit, reachable from the network; $advice"
	case $level in
	crit) tk_crit "$msg" ;;
	warn) tk_warn "$msg" ;;
	*) tk_info "$msg" ;;
	esac
done <<EOF
$risky
EOF
tk_kvn "Risky services" "$found"
[ "$found" = 0 ] && tk_ok "No database, remote-admin or clear-text service is open to the network"

# --- Expected ports ---------------------------------------------------------
if [ -n "$expect" ]; then
	tk_section "Expected ports"
	for p in $(printf '%s' "$expect" | tr ',' ' '); do
		port=${p%/*} proto=tcp
		case $p in */*) proto=${p#*/} ;; esac
		if printf '%s\n' "$list" | awk -v p="$port" -v t="$proto" '$1 == t && $3 == p { f = 1 } END { exit !f }'; then
			tk_kvb "$port/$proto" true
			tk_ok "Port $port/$proto is listening"
		else
			tk_kvb "$port/$proto" false
			tk_crit "Nothing is listening on port $port/$proto; check the service that should (toolkit services)"
		fi
	done
fi

tk_finish
