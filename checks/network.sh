#!/bin/sh
#
# network - are the interfaces up, with link, addresses and few errors,
# and is there a default route through a gateway that answers? Reads
# /sys/class/net and /proc/net, so it works without ip or ifconfig.

TK_NAME=network
TK_DESC='Interfaces (link, speed, addresses, errors) and routes (default route, gateway)'
TK_OPTIONS=''
TK_HELP_EXTRA='Errors are counted since the interface came up. Interfaces without a
hardware device (bridges, veth, tunnels) are listed but never warned about
for having no link.'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

while [ $# -gt 0 ]; do
	tk_common_opt "$1" || tk_usage_error "unknown option: $1"
	shift
done

# rd FILE: first line of FILE, or nothing (some sysfs files fail to read
# when the link is down).
rd() {
	head -n 1 "$1" 2>/dev/null
}

# num VALUE: VALUE as a JSON number, or null.
num() {
	if tk_is_uint "${1:-}"; then printf '%s' "$1"; else printf null; fi
}

# Addresses per interface, one "IFACE ADDR/PREFIX" per line.
addrs=''
if tk_has ip; then
	addrs=$(ip -o addr show 2>/dev/null | awk '$3 == "inet" || $3 == "inet6" { sub(/@.*/, "", $2); print $2, $4 }')
elif tk_has ifconfig; then
	# net-tools ("inet 10.0.0.5  netmask ...") and BusyBox ("inet addr:10.0.0.5  Mask:...").
	addrs=$(ifconfig -a 2>/dev/null | awk '
		/^[^ \t]/ { i = $1; sub(/:$/, "", i) }
		$1 == "inet" || $1 == "inet6" { a = $2; sub(/^addr:/, "", a); if (a != "") print i, a }')
fi
if [ -z "$addrs" ] && [ -r "$TK_PROC/net/if_inet6" ]; then
	addrs=$(awk "$(tk_net_awk)"' { printf "%s %s/%d\n", $6, ip6($1), hexval($3) }' "$TK_PROC/net/if_inet6")
fi

tk_start

# --- Interfaces ----------------------------------------------------------
tk_section "Interfaces"
items='' n=0 n_up=0
tk_print '  %-12s %-8s %-6s %-10s %s\n' IFACE STATE MTU SPEED ADDRESSES
for d in "$TK_SYS"/class/net/*; do
	[ -d "$d" ] || continue
	ifc=${d##*/}
	[ "$ifc" = lo ] && continue
	n=$((n + 1))
	state=$(rd "$d/operstate")
	carrier=$(rd "$d/carrier")
	mtu=$(rd "$d/mtu")
	mac=$(rd "$d/address")
	speed=$(rd "$d/speed")
	duplex=$(rd "$d/duplex")
	flags=$(rd "$d/flags")
	# Physical interfaces have a device link; bridges, veth and tunnels don't.
	if [ -e "$d/device" ]; then virtual=false; else virtual=true; fi
	# IFF_UP (0x1): the admin turned it on.
	admin_up=$(awk -v f="${flags:-0x0}" "$(tk_net_awk)"' BEGIN { sub(/^0[xX]/, "", f); print hexval(f) % 2 }')
	case $speed in '' | -* | *[!0-9]*) speed='' ;; esac

	rx_b=$(rd "$d/statistics/rx_bytes") tx_b=$(rd "$d/statistics/tx_bytes")
	rx_p=$(rd "$d/statistics/rx_packets") tx_p=$(rd "$d/statistics/tx_packets")
	rx_e=$(rd "$d/statistics/rx_errors") tx_e=$(rd "$d/statistics/tx_errors")
	rx_d=$(rd "$d/statistics/rx_dropped") tx_d=$(rd "$d/statistics/tx_dropped")

	a=$(printf '%s\n' "$addrs" | awk -v i="$ifc" '$1 == i { print $2 }')
	ajson=''
	for x in $a; do ajson="${ajson:+$ajson,}$(tk_json_str "$x")"; done
	tk_print '  %-12s %-8s %-6s %-10s %s\n' "$ifc" "${state:--}" "${mtu:--}" \
		"${speed:+${speed}Mb/s}" "$(printf '%s' "$a" | tr '\n' ' ')"

	items="${items:+$items,}{\"name\":$(tk_json_str "$ifc"),\"state\":$(tk_json_str "${state:-unknown}"),\"admin_up\":$([ "$admin_up" = 1 ] && echo true || echo false),\"carrier\":$([ "$carrier" = 1 ] && echo true || echo false),\"virtual\":$virtual,\"mtu\":$(num "$mtu"),\"mac\":$(tk_json_str "$mac"),\"speed_mbps\":$(num "$speed"),\"duplex\":$(tk_json_str "$duplex"),\"addresses\":[$ajson],\"rx_bytes\":$(num "$rx_b"),\"tx_bytes\":$(num "$tx_b"),\"rx_packets\":$(num "$rx_p"),\"tx_packets\":$(num "$tx_p"),\"rx_errors\":$(num "$rx_e"),\"tx_errors\":$(num "$tx_e"),\"rx_dropped\":$(num "$rx_d"),\"tx_dropped\":$(num "$tx_d")}"

	[ "$admin_up" = 1 ] || continue
	if [ "$virtual" = false ] && [ "$carrier" != 1 ]; then
		tk_warn "$ifc is enabled but has no link; check the cable, switch port or virtual NIC"
		continue
	fi
	case $state in up | unknown) n_up=$((n_up + 1)) ;; esac
	if [ "$virtual" = false ] && [ "$duplex" = half ]; then
		tk_warn "$ifc is running at half duplex${speed:+ ($speed Mb/s)}; usually a speed/duplex negotiation problem"
	fi

	# Errors: warn at 0.1% of packets, mention any at all.
	errs=$(awk -v a="${rx_e:-0}" -v b="${tx_e:-0}" -v p="${rx_p:-0}" -v q="${tx_p:-0}" 'BEGIN {
		e = a + b; t = p + q
		if (e == 0) print "none"; else if (t > 0 && e * 1000 >= t) printf "warn %d %.2f\n", e, e * 100 / t; else printf "info %d\n", e }')
	case $errs in
	warn*)
		# shellcheck disable=SC2086 # split into words on purpose
		set -- $errs
		tk_warn "$ifc has $2 receive/transmit errors ($3% of packets); check the cable, NIC driver and ethtool -S $ifc"
		;;
	info*)
		# shellcheck disable=SC2086 # split into words on purpose
		set -- $errs
		tk_info "$ifc has $2 receive/transmit errors since it came up (under 0.1% of packets)"
		;;
	esac
done
tk_kvn "Count" "$n"
tk_kvn "Up" "$n_up"
tk_kvj "List" "[$items]"
if [ "$n" = 0 ]; then
	tk_warn "No network interfaces other than loopback"
elif [ "$n_up" = 0 ]; then
	tk_crit "No network interface is up; this host is offline"
else
	tk_ok "$n_up of $n interface(s) up"
fi
[ -n "$addrs" ] || tk_need_cmd ip iproute2 || :

# --- Routes ----------------------------------------------------------------
tk_section "Routes"
gw4='' gw4_if='' gw6='' gw6_if=''
if [ -r "$TK_PROC/net/route" ]; then
	# Iface Destination Gateway Flags RefCnt Use Metric Mask ...; RTF_UP is 0x1.
	routes=$(awk "$(tk_net_awk)"' NR > 1 && hexval($4) % 2 == 1 {
		bits = 0
		for (i = 1; i <= 8; i += 2) { b = hexval(substr($8, i, 2)); while (b > 0) { bits += b % 2; b = int(b / 2) } }
		print ip4($2) "/" bits, ($3 == "00000000" ? "-" : ip4($3)), $1, hexval($7) }' "$TK_PROC/net/route")
	tk_print '  %-20s %-16s %-10s %s\n' DESTINATION GATEWAY IFACE METRIC
	printf '%s\n' "$routes" | while read -r dst gw ifc met; do
		[ -n "$dst" ] && tk_print '  %-20s %-16s %-10s %s\n' "$dst" "$gw" "$ifc" "$met"
	done
	tk_kvn "IPv4 routes" "$(printf '%s' "$routes" | grep -c .)"
	# Lowest-metric default route.
	def=$(printf '%s\n' "$routes" | awk '$1 == "0.0.0.0/0"' | sort -n -k 4 | head -n 1)
	if [ -n "$def" ]; then
		# shellcheck disable=SC2086
		set -- $def
		gw4=$2 gw4_if=$3
		[ "$gw4" = - ] && gw4=''
	fi
fi
tk_kv "IPv4 default gateway" "$gw4"
tk_kv "IPv4 default interface" "$gw4_if"

if [ -r "$TK_PROC/net/ipv6_route" ]; then
	# dest plen src splen nexthop metric refcnt use flags dev. Skip the
	# kernel's reject routes on lo.
	def6=$(awk "$(tk_net_awk)"' $1 ~ /^0+$/ && $2 == "00" && $10 != "lo" {
		print ($5 ~ /^0+$/ ? "-" : ip6($5)), $10, hexval($6) }' "$TK_PROC/net/ipv6_route" | sort -n -k 3 | head -n 1)
	if [ -n "$def6" ]; then
		# shellcheck disable=SC2086
		set -- $def6
		gw6=$1 gw6_if=$2
		[ "$gw6" = - ] && gw6=''
	fi
fi
tk_kv "IPv6 default gateway" "$gw6"
tk_kv "IPv6 default interface" "$gw6_if"
fwd=$(rd "$TK_PROC/sys/net/ipv4/ip_forward")
tk_kvb "IP forwarding" [ "$fwd" = 1 ]

if [ -z "$gw4_if" ] && [ -z "$gw6_if" ]; then
	tk_warn "No default route; this host can only reach directly connected networks"
else
	tk_ok "Default route via ${gw4:-${gw6:-a direct link}} on ${gw4_if:-$gw6_if}"
fi

# The ARP cache says whether the IPv4 gateway answered. Flags 0x0 means
# the kernel asked and got no reply.
if [ -n "$gw4" ] && [ -r "$TK_PROC/net/arp" ]; then
	arp=$(awk -v g="$gw4" 'NR > 1 && $1 == g { print $3, $4 }' "$TK_PROC/net/arp" | head -n 1)
	case $arp in
	'') tk_kv "Gateway MAC" "" ;;
	0x0\ *)
		tk_kv "Gateway MAC" ""
		tk_crit "The default gateway $gw4 does not answer ARP; check the gateway, VLAN and cabling"
		;;
	*)
		tk_kv "Gateway MAC" "${arp#* }"
		tk_ok "The default gateway $gw4 answers ARP"
		;;
	esac
fi

tk_finish
