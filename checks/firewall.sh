#!/bin/sh
#
# firewall - is anything filtering incoming traffic? Looks at firewalld,
# ufw, nftables and iptables/ip6tables (whichever are present), and
# points out common gaps: no filtering at all, IPv6 left open while IPv4
# is filtered, and Docker publishing ports past ufw.

TK_NAME=firewall
TK_DESC='Firewall status: firewalld, ufw, nftables and iptables rules for incoming traffic'
TK_OPTIONS=''
TK_HELP_EXTRA='Reading firewall rules needs root, so run it with sudo. A cloud security
group or a network firewall may protect the host too; this check only sees
the rules on this machine.'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

while [ $# -gt 0 ]; do
	tk_common_opt "$1" || tk_usage_error "unknown option: $1"
	shift
done

# denied OUTPUT: the tool refused because we are not root (or lack
# CAP_NET_ADMIN, as in most containers).
denied() {
	case $1 in
	*"ermission denied"* | *"not permitted"* | *"must be root"* | *"need to be root"* | *"Authorization failed"* | *"Not authorized"*) return 0 ;;
	esac
	return 1
}

# ipt_policy RULES: the INPUT policy from `iptables -S` output.
ipt_policy() {
	printf '%s\n' "$1" | awk '$1 == "-P" && $2 == "INPUT" { print $3; exit }'
}

# ipt_filters RULES: true if the rules drop or reject anything coming in.
ipt_filters() {
	[ "$(ipt_policy "$1")" = DROP ] && return 0
	printf '%s\n' "$1" | grep -q '^-A INPUT ' &&
		printf '%s\n' "$1" | grep -Eq -- '-j (DROP|REJECT)'
}

# global_ipv6: true if an interface has a global IPv6 address (scope 00).
global_ipv6() {
	awk '$4 == "00" && $6 != "lo" { f = 1 } END { exit !f }' "$TK_PROC/net/if_inet6" 2>/dev/null
}

tk_start
tk_detect_virt

filtered='' denied_n=0 seen=0 v4_ipt=0 v6_open=0 docker=0 ufw_on=0

# --- firewalld -------------------------------------------------------------
if tk_has firewall-cmd; then
	seen=$((seen + 1))
	tk_section "firewalld"
	state=$(tk_timeout 10 firewall-cmd --state 2>&1)
	tk_kv "State" "$state"
	if [ "$state" = running ]; then
		filtered="${filtered:+$filtered, }firewalld"
		zone=$(tk_timeout 10 firewall-cmd --get-default-zone 2>/dev/null)
		tk_kv "Default zone" "$zone"
		tk_kv "Services" "$(tk_timeout 10 firewall-cmd --list-services 2>/dev/null)"
		tk_kv "Ports" "$(tk_timeout 10 firewall-cmd --list-ports 2>/dev/null)"
		tk_ok "firewalld is running (default zone ${zone:-unknown})"
		case $zone in trusted) tk_warn "The default firewalld zone is 'trusted', which accepts everything" ;; esac
	elif denied "$state"; then
		denied_n=$((denied_n + 1))
	else
		tk_info "firewalld is installed but not running"
	fi
fi

# --- ufw ---------------------------------------------------------------------
if tk_has ufw; then
	seen=$((seen + 1))
	tk_section "ufw"
	out=$(tk_timeout 10 ufw status 2>&1)
	st=$(printf '%s\n' "$out" | sed -n 's/^Status: *//p' | head -n 1)
	tk_kv "Status" "$st"
	case $st in
	active)
		ufw_on=1
		filtered="${filtered:+$filtered, }ufw"
		tk_kvn "Rules" "$(printf '%s\n' "$out" | grep -Ec ' (ALLOW|DENY|REJECT|LIMIT)( IN)? ')"
		tk_ok "ufw is active"
		;;
	inactive) tk_info "ufw is installed but inactive (enable it with: ufw enable, after allowing ssh)" ;;
	*) denied "$out" && denied_n=$((denied_n + 1)) ;;
	esac
fi

# --- nftables ------------------------------------------------------------------
if tk_has nft; then
	seen=$((seen + 1))
	tk_section "nftables"
	rs=$(tk_timeout 10 nft list ruleset 2>&1)
	rc=$?
	if [ "$rc" = 0 ]; then
		# For each base chain on the input hook: its policy and rule count.
		inputs=$(printf '%s\n' "$rs" | awk '
			/^[ \t]*chain / { c = $2; hook = 0; pol = "accept"; n = 0; drops = 0 }
			/hook input/ { hook = 1; if (match($0, /policy [a-z]+/)) pol = substr($0, RSTART + 7, RLENGTH - 7) }
			c != "" && !/^[ \t]*(chain|type|policy|})/ && NF > 0 { n++; if ($0 ~ /(drop|reject)/) drops++ }
			/^[ \t]*}/ && c != "" { total += n; if (hook) print c, pol, n, drops; c = "" }
			END { print "TOTAL", total + 0 }')
		tk_kvn "Rules" "$(printf '%s\n' "$inputs" | awk '$1 == "TOTAL" { print $2 }')"
		inputs=$(printf '%s\n' "$inputs" | grep -v '^TOTAL ')
		tk_kvn "Input chains" "$(printf '%s' "$inputs" | grep -c .)"
		if printf '%s\n' "$inputs" | awk '$2 == "drop" || $4 > 0 { f = 1 } END { exit !f }'; then
			filtered="${filtered:+$filtered, }nftables"
			tk_ok "nftables filters incoming traffic"
		elif [ -n "$inputs" ]; then
			tk_info "nftables has input chains, but they accept everything"
		fi
	elif denied "$rs"; then
		denied_n=$((denied_n + 1))
	else
		tk_debug "nft list ruleset: $rs"
	fi
fi

# --- iptables / ip6tables -------------------------------------------------------
if tk_has iptables; then
	seen=$((seen + 1))
	tk_section "iptables"
	r4=$(tk_timeout 10 iptables -S 2>&1)
	rc=$?
	if [ "$rc" = 0 ]; then
		tk_kv "Input policy" "$(ipt_policy "$r4")"
		tk_kvn "Input rules" "$(printf '%s\n' "$r4" | grep -c '^-A INPUT ')"
		printf '%s\n' "$r4" | grep -q '^-N DOCKER' && docker=1
		if ipt_filters "$r4"; then
			v4_ipt=1
			case $filtered in *iptables* | *ufw* | *firewalld*) ;; *) filtered="${filtered:+$filtered, }iptables" ;; esac
			tk_ok "iptables filters incoming IPv4 traffic"
		fi
		if tk_has ip6tables; then
			r6=$(tk_timeout 10 ip6tables -S 2>&1) && {
				tk_kv "IPv6 input policy" "$(ipt_policy "$r6")"
				tk_kvn "IPv6 input rules" "$(printf '%s\n' "$r6" | grep -c '^-A INPUT ')"
				ipt_filters "$r6" || v6_open=1
			}
		fi
	elif denied "$r4"; then
		denied_n=$((denied_n + 1))
	else
		tk_debug "iptables -S: $r4"
	fi
fi

# --- Assessment ------------------------------------------------------------------
tk_section "Assessment"
tk_kv "Filtered by" "$filtered"
tk_kv "Container" "$TK_CONTAINER"
if [ -n "$filtered" ]; then
	tk_ok "Incoming traffic is filtered by $filtered"
	# ufw and firewalld handle IPv6 themselves; plain iptables often doesn't.
	if [ "$v4_ipt" = 1 ] && [ "$v6_open" = 1 ] && [ "$ufw_on" = 0 ] && ! printf '%s' "$filtered" | grep -Eq 'firewalld|nftables' && global_ipv6; then
		tk_warn "IPv4 is filtered but IPv6 is not, and this host has a public IPv6 address; add matching ip6tables rules"
	fi
	if [ "$ufw_on" = 1 ] && [ "$docker" = 1 ]; then
		tk_info "Docker is running: ports it publishes bypass ufw rules (see DOCKER-USER in the Docker docs)"
	fi
elif [ -n "$TK_CONTAINER" ]; then
	tk_info "Running in a container ($TK_CONTAINER); the host's firewall applies, not one in here"
elif [ "$denied_n" -gt 0 ]; then
	tk_want_root "firewall rules cannot be read" || :
	tk_skip "Could not read the firewall rules; re-run with sudo"
elif [ "$seen" = 0 ]; then
	tk_warn "No firewall tool found (nft, iptables, ufw, firewalld); every listening port is reachable unless a network or cloud firewall blocks it (see toolkit ports)"
else
	tk_warn "No firewall rules filter incoming traffic; every listening port is reachable unless a network or cloud firewall blocks it (see toolkit ports)"
fi

tk_finish
