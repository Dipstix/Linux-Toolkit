#!/bin/sh
#
# dns - is name resolution configured, does it work, and does each
# nameserver answer? Reads resolv.conf and nsswitch.conf, resolves names
# the way applications do (getent), and asks each nameserver directly
# when dig or nslookup is installed.

TK_NAME=dns
TK_DESC='Resolver configuration, name lookups, and whether each nameserver answers'
TK_OPTIONS='      --name LIST    Comma-separated names to look up (default example.com)
      --timeout N    Seconds to wait for each lookup (default 5)
      --offline      Only check the configuration and local names'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

names='' timeout=5 offline=0
while [ $# -gt 0 ]; do
	case $1 in
	--name) tk_need_arg "$@"; names="${names:+$names,}$2"; shift ;;
	--timeout) tk_need_arg "$@"; timeout=$2; shift ;;
	--offline) offline=1 ;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done
[ -n "$names" ] || names=example.com
case $names in
*[!A-Za-z0-9.,_-]*) tk_usage_error "--name takes host names separated by commas" ;;
esac
if ! tk_is_uint "$timeout" || [ "$timeout" -eq 0 ]; then
	tk_usage_error "--timeout needs a whole number of seconds above 0"
fi

# lookup NAME: the addresses NAME resolves to, one per line, the way
# applications see them (nsswitch: /etc/hosts, then DNS).
lookup() {
	if tk_has getent; then
		tk_timeout "$timeout" getent hosts "$1" 2>/dev/null | awk '{ print $1 }'
	elif tk_has nslookup; then
		# nslookup only asks DNS, so look in the hosts file first as
		# applications would.
		_h=$(awk -v n="$1" '{ sub(/#.*/, "") } { for (i = 2; i <= NF; i++) if (tolower($i) == tolower(n)) { print $1; break } }' "$TK_ETC/hosts" 2>/dev/null)
		[ -n "$_h" ] && { printf '%s\n' "$_h"; return 0; }
		# Skip the "Server:/Address:" header; answers follow the "Name:" line.
		tk_timeout "$timeout" nslookup "$1" 2>/dev/null |
			awk '/^Name:/ { a = 1; next } a && /^Address/ { sub(/^Address( [0-9]+)?:[ \t]*/, ""); sub(/ .*/, ""); print }'
	else
		return 2
	fi
}

# ask SERVER NAME: true if SERVER answers a query for NAME (any answer,
# even "no such name", proves the server works).
ask() {
	if tk_has dig; then
		_out=$(tk_timeout "$timeout" dig +time="$timeout" +tries=1 "@$1" "$2" A 2>/dev/null)
		printf '%s\n' "$_out" | grep -Eq 'status: (NOERROR|NXDOMAIN)'
	elif tk_has nslookup; then
		_out=$(tk_timeout "$timeout" nslookup "$2" "$1" 2>&1)
		case $_out in
		*"timed out"* | *"no servers could be reached"* | *"connection refused"* | *"can't resolve"* | *SERVFAIL* | *REFUSED*) return 1 ;;
		*"Name:"* | *NXDOMAIN* | *"can't find"*) return 0 ;;
		*) return 1 ;;
		esac
	else
		return 2
	fi
}

# dns_pkg: the package with dig and nslookup on this distro.
dns_pkg() {
	tk_detect_pkg
	case $TK_PKG in
	apt) printf dnsutils ;;
	dnf | yum) printf bind-utils ;;
	apk) printf bind-tools ;;
	pacman) printf bind ;;
	*) printf bind-utils ;;
	esac
}

resolv=$TK_ETC/resolv.conf

tk_start

# --- Configuration ---------------------------------------------------------
tk_section "Configuration"
servers='' search='' opts=''
if [ -r "$resolv" ]; then
	servers=$(awk '$1 == "nameserver" { print $2 }' "$resolv")
	search=$(awk '$1 == "search" || $1 == "domain" { $1 = ""; sub(/^ /, ""); s = $0 } END { print s }' "$resolv")
	opts=$(awk '$1 == "options" { $1 = ""; sub(/^ /, ""); print }' "$resolv" | tr '\n' ' ' | sed 's/ $//')
	tk_kv "Resolv conf" "$resolv"
	# shellcheck disable=SC2012 # ls -l is the portable way to read a link
	[ -L "$resolv" ] && tk_kv "Resolv conf target" "$(ls -l "$resolv" 2>/dev/null | sed 's/.* -> //')"
fi
sjson=''
for s in $servers; do sjson="${sjson:+$sjson,}$(tk_json_str "$s")"; done
tk_kv "Nameservers" "$(printf '%s' "$servers" | tr '\n' ' ')"
tk_kvj "Nameserver list" "[$sjson]"
tk_kv "Search" "$search"
tk_kv "Options" "$opts"
hosts_line=$(sed -n 's/^hosts:[ \t]*//p' "$TK_ETC/nsswitch.conf" 2>/dev/null | head -n 1)
tk_kv "Nsswitch hosts" "$hosts_line"

nservers=$(printf '%s' "$servers" | grep -c .)
stub=0
case " $(printf '%s' "$servers" | tr '\n' ' ') " in
*" 127.0.0.53 "* | *" 127.0.0.54 "*) stub=1 ;;
esac
if [ ! -e "$resolv" ]; then
	tk_crit "$resolv does not exist; nothing can be looked up by name"
elif [ ! -r "$resolv" ]; then
	tk_crit "$resolv is not readable by this user; name lookups will fail (check its permissions)"
elif [ "$nservers" = 0 ]; then
	tk_crit "No nameserver in $resolv; add one, or fix whatever manages that file"
else
	tk_ok "$nservers nameserver(s) configured"
	[ "$nservers" -gt 3 ] && tk_info "Only the first 3 nameservers in $resolv are used"
fi

# systemd-resolved: resolv.conf points at its local stub, so the real
# upstream servers are elsewhere.
if [ "$stub" = 1 ]; then
	tk_info "Lookups go through systemd-resolved's local stub; upstream servers are shown below"
	if tk_has resolvectl; then
		up=$(resolvectl dns 2>/dev/null | sed -n 's/^[^:]*: *//p' | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ')
		tk_kv "Upstream nameservers" "$up"
		[ -n "$up" ] || tk_warn "systemd-resolved has no upstream nameserver; check resolvectl status"
	fi
fi

# --- Local names -----------------------------------------------------------
tk_section "Local names"
host=$(uname -n 2>/dev/null)
tk_kv "Hostname" "$host"
if [ -n "$host" ]; then
	a=$(lookup "$host")
	rc=$?
	if [ "$rc" = 2 ]; then
		tk_skip "No getent or nslookup to test lookups with (install: $(tk_install_hint "$(dns_pkg)"))"
	elif [ -n "$a" ]; then
		tk_kv "Hostname resolves to" "$(printf '%s' "$a" | tr '\n' ' ')"
		tk_ok "The hostname $host resolves"
	else
		tk_warn "The hostname $host does not resolve; sudo and some daemons get slow or fail. Add it to $TK_ETC/hosts"
	fi
fi

# --- Lookups -----------------------------------------------------------------
if [ "$offline" = 1 ]; then
	tk_finish
fi

tk_section "Lookups"
tk_kvn "Timeout seconds" "$timeout"
ok_n=0 fail_n=0 items=''
old_ifs=$IFS
IFS=,
for name in $names; do
	IFS=$old_ifs
	[ -n "$name" ] || continue
	t0=$(date +%s 2>/dev/null)
	a=$(lookup "$name")
	rc=$?
	t1=$(date +%s 2>/dev/null)
	secs=$((${t1:-0} - ${t0:-0}))
	[ "$rc" = 2 ] && { tk_skip "No getent or nslookup to test lookups with"; break; }
	first=$(printf '%s\n' "$a" | head -n 1)
	items="${items:+$items,}{\"name\":$(tk_json_str "$name"),\"resolved\":$([ -n "$a" ] && echo true || echo false),\"address\":$(tk_json_str "$first"),\"seconds\":$secs}"
	if [ -n "$a" ]; then
		ok_n=$((ok_n + 1))
		tk_print '  %-30s %s\n' "$name" "$first"
		if [ "$secs" -ge 2 ]; then
			tk_warn "$name resolved but took ${secs}s; the first nameserver may be down (see below)"
		else
			tk_ok "$name resolves to $first"
		fi
	else
		fail_n=$((fail_n + 1))
		tk_print '  %-30s %s\n' "$name" "(no answer)"
		tk_crit "$name does not resolve${secs:+ (gave up after ${secs}s)}"
	fi
done
IFS=$old_ifs
tk_kvj "Results" "[$items]"

# --- Each nameserver ------------------------------------------------------
# Querying 127.0.0.53 again tells nothing new; ask the others directly.
probe=${names%%,*}
if [ "$nservers" -gt 0 ]; then
	tk_section "Nameservers"
	if tk_has dig || tk_has nslookup; then
		answered=0 asked=0
		for s in $servers; do
			asked=$((asked + 1))
			if ask "$s" "$probe"; then
				answered=$((answered + 1))
				tk_kvb "$s" true
				tk_ok "$s answers queries"
			else
				tk_kvb "$s" false
				tk_warn "$s does not answer queries; remove it or check the firewall between here and it (port 53)"
			fi
		done
		[ "$asked" -gt 0 ] && [ "$answered" = 0 ] && tk_crit "None of the configured nameservers answers"
	else
		tk_skip "dig or nslookup not found, so nameservers were not asked one by one (install: $(tk_install_hint "$(dns_pkg)"))"
	fi
fi

tk_finish
