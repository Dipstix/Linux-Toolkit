#!/bin/sh
#
# system - a quick overview: uptime, load, logged-in users, processes, and
# the housekeeping problems that are easy to miss (pending reboot, clock
# not synchronised, zombie processes, file handles running out).

TK_NAME=system
TK_DESC='Show uptime, users and processes, and flag pending reboots, clock sync and zombies'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

while [ $# -gt 0 ]; do
	tk_common_opt "$1" || tk_usage_error "unknown option: $1"
	shift
done

tk_start
tk_detect_os
tk_detect_init
tk_detect_virt

tk_section "Overview"
tk_kv "Hostname" "$(uname -n 2>/dev/null)"
tk_kv "OS" "$TK_OS_NAME"
tk_kv "Kernel" "$(uname -r 2>/dev/null)"
up=$(awk '{ printf "%d\n", $1 }' "$TK_PROC/uptime" 2>/dev/null)
tk_kvn "Uptime seconds" "$up" "$([ -n "$up" ] && tk_duration "$up")"
read -r l1 l5 l15 _ <"$TK_PROC/loadavg" 2>/dev/null
tk_kv "Load average" "${l1:+$l1 $l5 $l15}"
if tk_has who; then
	users=$(who 2>/dev/null | grep -c .)
	tk_kvn "Users logged in" "$users"
fi

tk_section "Processes"
# One pass over every /proc/PID/stat: the state is the first field after
# the ")" that closes the process name.
states=$(cat "$TK_PROC"/[0-9]*/stat 2>/dev/null | awk '
	{ s = $0; sub(/^.*\) /, "", s); split(s, f, " "); n++; st[f[1]]++ }
	END { printf "%d %d %d %d\n", n, st["R"], st["D"], st["Z"] }')
read -r nproc nrun ndisk nzombie <<EOF
$states
EOF
threads=$(awk '{ split($4, a, "/"); print a[2] }' "$TK_PROC/loadavg" 2>/dev/null)
tk_kvn "Total" "$nproc"
tk_kvn "Threads" "$threads"
tk_kvn "Running" "$nrun"
tk_kvn "Waiting on IO" "$ndisk"
tk_kvn "Zombies" "$nzombie"
if [ "${nzombie:-0}" -ge 20 ]; then
	tk_warn "$nzombie zombie processes; their parent is not reaping them (find it with: ps -eo ppid,stat | grep Z)"
elif [ "${nzombie:-0}" -gt 0 ]; then
	tk_info "$nzombie zombie process(es); harmless unless the number keeps growing"
fi
if [ "${ndisk:-0}" -ge 10 ]; then
	tk_warn "$ndisk processes are stuck waiting on I/O (state D); check toolkit disk and toolkit logs"
fi

# Open file handles: allocated, free, max.
if read -r fh_alloc _ fh_max <"$TK_PROC/sys/fs/file-nr" 2>/dev/null; then
	fh_pct=$(tk_pct "$fh_alloc" "$fh_max")
	tk_kvn "Open files" "$fh_alloc"
	tk_kvn "Open files max" "$fh_max"
	if [ "$fh_pct" -ge 90 ]; then
		tk_crit "$fh_pct% of the system-wide file handle limit is in use (fs.file-max)"
	elif [ "$fh_pct" -ge 75 ]; then
		tk_warn "$fh_pct% of the system-wide file handle limit is in use (fs.file-max)"
	fi
fi

tk_section "Maintenance"
# Reboot pending: Debian/Ubuntu flag file, then RHEL's needs-restarting,
# then the generic sign that the running kernel was removed by an upgrade.
reboot=''
if [ -f /var/run/reboot-required ]; then
	pkgs=$(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null | sed 's/ *$//')
	reboot="the system flagged it${pkgs:+ for: $pkgs}"
elif tk_has needs-restarting && [ "$TK_OS_FAMILY" = redhat ]; then
	tk_timeout 30 needs-restarting -r >/dev/null 2>&1
	[ $? = 1 ] && reboot="needs-restarting -r says core packages were updated"
fi
kver=$(uname -r 2>/dev/null)
if [ -z "$reboot" ] && [ -z "$TK_CONTAINER" ] && [ -n "$kver" ]; then
	for d in /lib/modules /usr/lib/modules; do
		[ -d "$d" ] || continue
		if [ ! -d "$d/$kver" ] && [ -n "$(ls "$d" 2>/dev/null)" ]; then
			reboot="the running kernel $kver is no longer installed (upgraded)"
		fi
		break
	done
fi
if [ -n "$reboot" ]; then
	tk_kvb "Reboot required" true
	tk_warn "A reboot is pending: $reboot"
else
	tk_kvb "Reboot required" false
	tk_ok "No reboot pending"
fi

# Clock synchronisation.
sync=''
if [ "$TK_INIT" = systemd ] && tk_has timedatectl; then
	sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
	# systemd before 239 has no "show"; parse the status text instead.
	[ -n "$sync" ] || sync=$(timedatectl status 2>/dev/null |
		sed -n -e 's/.*NTP synchronized: *\([a-z]*\).*/\1/p' \
			-e 's/.*System clock synchronized: *\([a-z]*\).*/\1/p' | head -n 1)
fi
daemon=''
for p in chronyd ntpd openntpd systemd-timesyncd timesyncd ntpclient; do
	if cat "$TK_PROC"/[0-9]*/comm 2>/dev/null | grep -qx "$p"; then
		daemon=$p
		break
	fi
done
tk_kv "Time sync daemon" "$daemon"
case $sync in
yes)
	tk_kvb "Clock synchronised" true
	tk_ok "Clock is synchronised${daemon:+ ($daemon)}"
	;;
no)
	tk_kvb "Clock synchronised" false
	tk_warn "Clock is not synchronised; check timedatectl and${daemon:+ $daemon}${daemon:- a time sync service}"
	;;
*)
	if [ -n "$TK_CONTAINER" ]; then
		tk_info "Running in a container ($TK_CONTAINER); the host keeps the clock"
	elif [ -n "$daemon" ]; then
		tk_ok "Time sync daemon running ($daemon)"
	else
		tk_warn "No time sync service found (chrony, ntpd or systemd-timesyncd); the clock will drift"
	fi
	;;
esac

if [ "${up:-0}" -ge 31536000 ]; then
	tk_info "Up for over a year; the kernel is probably missing security fixes"
fi
taint=$(cat "$TK_PROC/sys/kernel/tainted" 2>/dev/null)
if [ -n "$taint" ]; then
	tk_kvn "Kernel taint" "$taint"
	# Bits 0 (proprietary), 12 (out-of-tree) and 13 (unsigned) are just
	# third-party drivers. Others (e.g. 7 oops, 9 warning) mean trouble.
	if [ "$((taint & ~12289))" -ne 0 ]; then
		tk_info "Kernel is tainted ($taint), e.g. after an oops or warning; see toolkit logs"
	fi
fi

tk_finish
