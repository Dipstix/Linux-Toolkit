#!/bin/sh
#
# services - is the service manager healthy, which services have failed,
# and are the services you care about running? Works with systemd,
# OpenRC, SysV init, runit and Upstart, and falls back to looking for
# processes where there is no service manager (containers).

TK_NAME=services
TK_DESC='Show failed services and check that the services you name are running'
TK_OPTIONS='      --expect LIST  Comma-separated services that must be running,
                     e.g. --expect sshd,cron (critical if one is not)'
TK_HELP_EXTRA='Service names are what your init system calls them: "ssh" on Debian
is "sshd" on RHEL and Alpine. Without a service manager, --expect looks
for a running process of that name instead.'

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
case $expect in
*[!A-Za-z0-9@:._,-]*) tk_usage_error "--expect takes service names separated by commas" ;;
esac

# proc_running NAME: true if a process called NAME is running. The kernel
# truncates process names to 15 characters.
proc_running() {
	_n=$(printf '%s' "$1" | cut -c 1-15)
	cat "$TK_PROC"/[0-9]*/comm 2>/dev/null | grep -qx -- "$_n"
}

# list_json LINES: a JSON array of strings, one per non-empty line.
list_json() {
	_items=''
	while IFS= read -r _l; do
		[ -n "$_l" ] && _items="${_items:+$_items,}$(tk_json_str "$_l")"
	done <<EOF
$1
EOF
	printf '[%s]' "$_items"
}

# report_failed LINES HINT: one warning per failed service, plus the list.
report_failed() {
	_n=0
	while IFS= read -r _s; do
		[ -n "$_s" ] || continue
		_n=$((_n + 1))
		# shellcheck disable=SC2059 # HINT holds a %s for the service name
		tk_warn "$_s has failed; see: $(printf "$2" "$_s")"
	done <<EOF
$1
EOF
	tk_kvn "Failed" "$_n"
	tk_kvj "Failed services" "$(list_json "$1")"
	[ "$_n" = 0 ] && tk_ok "No failed services"
	return 0
}

# is_running NAME: does the init system say NAME is running? 0 yes, 1 no.
is_running() {
	case $TK_INIT in
	systemd) systemctl is-active --quiet "$1" 2>/dev/null ;;
	openrc) rc-service "$1" status >/dev/null 2>&1 ;;
	runit)
		for _d in /var/service /etc/service /service /run/runit/service; do
			[ -d "$_d/$1" ] || continue
			sv status "$_d/$1" 2>/dev/null | grep -q '^run:'
			return
		done
		proc_running "$1"
		;;
	upstart) initctl status "$1" 2>/dev/null | grep -q 'start/running' ;;
	sysv)
		if [ -x "/etc/init.d/$1" ]; then
			tk_timeout 10 "/etc/init.d/$1" status >/dev/null 2>&1
		else
			proc_running "$1"
		fi
		;;
	*) proc_running "$1" ;;
	esac
}

tk_start
tk_detect_init

tk_section "Service manager"
tk_kv "Init system" "$TK_INIT"

case $TK_INIT in
systemd)
	if tk_need_cmd systemctl systemd; then
		state=$(systemctl is-system-running 2>/dev/null)
		tk_kv "System state" "$state"
		running=$(systemctl list-units --type=service --state=running --no-legend --plain --no-pager 2>/dev/null | grep -c .)
		tk_kvn "Running" "$running"
		# Failed units of any type (services, mounts, timers...). Older
		# systemd prints a bullet before the name, so take the first word
		# that looks like a unit.
		failed=$(systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null |
			awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\./) { print $i; break } }')
		case $state in
		running | degraded) ;; # degraded = failed units, reported below
		maintenance) tk_crit "System is in maintenance (rescue/emergency) mode" ;;
		starting | initializing) tk_info "System is still booting ($state)" ;;
		stopping) tk_warn "System is shutting down" ;;
		*) tk_info "System state is '${state:-unknown}'" ;;
		esac
		report_failed "$failed" 'systemctl status %s'
	fi
	;;
openrc)
	if tk_need_cmd rc-status openrc; then
		tk_kv "Runlevel" "$(rc-status -r 2>/dev/null)"
		# Lines look like: " sshd     [  started  ]". -C: no colors.
		status=$(rc-status -C 2>/dev/null)
		tk_kvn "Running" "$(printf '%s\n' "$status" | grep -c '\[ *started')"
		failed=$(printf '%s\n' "$status" | awk '/\[ *crashed/ { print $1 }')
		stopped=$(printf '%s\n' "$status" | awk '/\[ *stopped/ { print $1 }')
		report_failed "$failed" 'rc-service %s status; check its log under /var/log'
		for s in $stopped; do
			tk_info "$s is in this runlevel but stopped (fine if it is a one-shot task)"
		done
	fi
	;;
runit)
	if tk_need_cmd sv runit; then
		for d in /var/service /etc/service /service /run/runit/service; do
			[ -d "$d" ] && break
		done
		status=$(sv status "$d"/* 2>/dev/null)
		tk_kv "Service directory" "$d"
		tk_kvn "Running" "$(printf '%s\n' "$status" | grep -c '^run:')"
		failed=$(printf '%s\n' "$status" | awk -F': ' '/^(down|fail|warning):/ { n = $2; sub(/.*\//, "", n); print n }')
		report_failed "$failed" 'sv status %s'
	fi
	;;
upstart)
	if tk_need_cmd initctl upstart; then
		tk_kvn "Running" "$(initctl list 2>/dev/null | grep -c 'start/running')"
		tk_info "Upstart cannot list failed jobs; use --expect to check the ones you need"
	fi
	;;
sysv)
	# Ask each script enabled for this runlevel. LSB status codes: 0
	# running, 1/2 dead but a pid/lock file remains (crashed), 3 stopped.
	rl=$(runlevel 2>/dev/null | awk '{ print $2 }')
	[ -n "$rl" ] || rl=$(sed -n 's/^[^#]*:\([0-9]\):initdefault:.*/\1/p' /etc/inittab 2>/dev/null)
	tk_kv "Runlevel" "$rl"
	running=0 failed='' stopped=''
	if [ -n "$rl" ] && [ -d "/etc/rc$rl.d" ]; then
		for f in "/etc/rc$rl.d"/S*; do
			[ -e "$f" ] || continue
			s=${f##*/S[0-9][0-9]}
			[ -x "/etc/init.d/$s" ] || continue
			tk_timeout 10 "/etc/init.d/$s" status >/dev/null 2>&1
			case $? in
			0) running=$((running + 1)) ;;
			1 | 2) failed="$failed$s
" ;;
			3) stopped="$stopped $s" ;;
			esac
		done
		tk_kvn "Running" "$running"
		report_failed "$failed" '/etc/init.d/%s status'
		for s in $stopped; do
			tk_info "$s is enabled for runlevel $rl but not running (fine if it is a one-shot task)"
		done
	else
		tk_skip "Could not work out the runlevel, so services were not checked"
	fi
	tk_want_root "some init scripts may not report their status" || :
	;;
s6)
	tk_info "s6 is not inspected yet; use --expect to check the services you need"
	;;
*)
	tk_info "No service manager is running (PID 1 is ${TK_INIT_PID1:-unknown}); normal in a container"
	;;
esac

if [ -n "$expect" ]; then
	tk_section "Expected services"
	old_ifs=$IFS
	IFS=,
	for s in $expect; do
		IFS=$old_ifs
		[ -n "$s" ] || continue
		if is_running "$s"; then
			tk_kvb "$s" true
			tk_ok "$s is running"
		else
			tk_kvb "$s" false
			case $TK_INIT in
			systemd) hint="systemctl status $s" ;;
			openrc) hint="rc-service $s status" ;;
			*) hint="check its logs" ;;
			esac
			tk_crit "$s is not running; $hint"
		fi
	done
	IFS=$old_ifs
fi

tk_finish
