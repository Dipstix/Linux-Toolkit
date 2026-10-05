#!/bin/sh
#
# logs - what the logs say went wrong: kernel trouble since boot (OOM
# kills, disk and filesystem errors, hung tasks, hardware errors), recent
# error messages from the journal or syslog, and log disk usage.

TK_NAME=logs
TK_DESC='Scan kernel and system logs for OOM kills, I/O errors, crashes and recent errors'
TK_OPTIONS='      --hours N      Look at errors from the last N hours (default 24)
      --lines N      Show the N most recent error lines (default 5, 0 for none)'
TK_HELP_EXTRA='Kernel messages are read from the journal or dmesg; plain syslog files
are used where there is no journal. Run as root (or as a member of the adm
or systemd-journal group) to see every message.'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

hours=24
lines=5
while [ $# -gt 0 ]; do
	case $1 in
	--hours) tk_need_arg "$@"; hours=$2; shift ;;
	--lines) tk_need_arg "$@"; lines=$2; shift ;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done
if ! tk_is_uint "$hours" || [ "$hours" -eq 0 ]; then
	tk_usage_error "--hours needs a whole number above 0"
fi
tk_is_uint "$lines" || tk_usage_error "--lines needs a whole number"

# Plain-text syslog files, newest-style names first.
syslog_file() {
	for _f in /var/log/syslog /var/log/messages /var/log/kern.log; do
		[ -f "$_f" ] && { printf '%s' "$_f"; return 0; }
	done
	return 1
}

# show_lines TITLE LINES: print LINES for humans and add them to the JSON.
show_lines() {
	[ -n "$2" ] || return 0
	tk_print '  %s\n' "$1:"
	_items=''
	while IFS= read -r _l; do
		[ -n "$_l" ] || continue
		tk_print '    %s\n' "$(printf '%s' "$_l" | cut -c 1-160)"
		_items="${_items:+$_items,}$(tk_json_str "$_l")"
	done <<EOF
$2
EOF
	tk_kvj "$1" "[$_items]"
}

# journal_ok: journalctl exists and the journal has something in it.
journal_ok() {
	tk_has journalctl && [ -n "$(journalctl -q -n 1 --no-pager 2>/dev/null)" ]
}

# can_read_all_logs: root, or in a group that can read the system journal.
can_read_all_logs() {
	tk_is_root && return 0
	case " $(id -Gn 2>/dev/null) " in
	*" adm "* | *" systemd-journal "* | *" wheel "*) return 0 ;;
	esac
	return 1
}

tk_start
tk_detect_init

# --- Kernel messages since boot ------------------------------------------
tk_section "Kernel"
klog='' ksrc=''
if journal_ok; then
	klog=$(tk_timeout 30 journalctl -k -b -q --no-pager -o short 2>/dev/null) && ksrc="journalctl -k -b"
fi
if [ -z "$klog" ] && tk_has dmesg; then
	klog=$(dmesg 2>/dev/null) && ksrc=dmesg
fi
if [ -z "$klog" ] && f=$(syslog_file) && [ -r "$f" ]; then
	# Only the tail: syslog files are not limited to this boot.
	klog=$(tail -n 20000 "$f" 2>/dev/null | grep ' kernel: ') && ksrc="$f (kernel lines)"
fi
tk_kv "Source" "$ksrc"

if [ -z "$ksrc" ]; then
	if can_read_all_logs; then
		tk_skip "No kernel log available (no journal, dmesg or syslog file)"
	else
		tk_skip "Could not read the kernel log; re-run with sudo"
	fi
else
	# label|level|pattern (extended regex, matched case-sensitively).
	patterns='OOM kills|warn|Out of memory|oom-kill|Killed process
Disk IO errors|crit|I/O error|Buffer I/O error|blk_update_request: .*error|critical medium error|Medium Error
Filesystem errors|crit|EXT[234]-fs error|XFS .*([Cc]orrupt|[Ee]rror)|BTRFS (error|critical)|Remounting filesystem read-only
Hardware errors|crit|Hardware Error|[Mm]achine [Cc]heck|EDAC .*(CE|UE)
Hung tasks|warn|blocked for more than|soft lockup|hard LOCKUP|rcu_sched self-detected stall|rcu: INFO: rcu_.* detected stalls
Segfaults|info|segfault at
Conntrack table full|warn|nf_conntrack: table full
Thermal throttling|warn|temperature above threshold|cpu clock throttled'
	found=0
	while IFS='|' read -r label level re; do
		[ -n "$label" ] || continue
		matches=$(printf '%s\n' "$klog" | grep -E -- "$re")
		n=$(printf '%s' "$matches" | grep -c .)
		tk_kvn "$label" "$n"
		[ "$n" -gt 0 ] || continue
		found=$((found + 1))
		last=$(printf '%s\n' "$matches" | tail -n 1 | sed 's/^.*\] //; s/^.* kernel: //' | cut -c 1-120)
		msg="$label in the kernel log since boot: $n; last: $last"
		case $level in
		crit) tk_crit "$msg" ;;
		warn) tk_warn "$msg" ;;
		*) tk_info "$msg" ;;
		esac
	done <<EOF
$patterns
EOF
	[ "$found" = 0 ] && tk_ok "No OOM kills, I/O, filesystem or hardware errors in the kernel log"
	can_read_all_logs || tk_want_root "the kernel log may be incomplete" || :
fi

# --- Recent errors ---------------------------------------------------------
tk_section "Recent errors"
tk_kvn "Hours" "$hours"
if journal_ok; then
	tk_kv "Source" "journal (priority err and worse)"
	errs=$(tk_timeout 30 journalctl -q --no-pager -p err --since "-${hours}h" -o short 2>/dev/null)
	n=$(printf '%s' "$errs" | grep -c .)
	tk_kvn "Count" "$n"
	if [ "$n" -gt 0 ]; then
		tk_info "$n error message(s) in the last ${hours}h; more with: journalctl -p err --since -${hours}h"
	else
		tk_ok "No error messages in the last ${hours}h"
	fi
	[ "$lines" -gt 0 ] && show_lines "Latest" "$(printf '%s\n' "$errs" | tail -n "$lines")"
	can_read_all_logs || tk_want_root "only your own journal entries are visible" || :
elif f=$(syslog_file); then
	tk_kv "Source" "$f"
	if [ -r "$f" ]; then
		# Syslog timestamps vary by distro, so scan the tail rather than
		# filtering by time.
		errs=$(tail -n 5000 "$f" 2>/dev/null | grep -Ei '(error|crit|alert|emerg|fail(ed|ure)?|panic)')
		n=$(printf '%s' "$errs" | grep -c .)
		tk_kvn "Count" "$n"
		if [ "$n" -gt 0 ]; then
			tk_info "$n error-like line(s) in the last 5000 lines of $f"
		else
			tk_ok "No error-like lines in the last 5000 lines of $f"
		fi
		[ "$lines" -gt 0 ] && show_lines "Latest" "$(printf '%s\n' "$errs" | tail -n "$lines")"
	else
		tk_want_root "$f is not readable" || :
		tk_skip "Cannot read $f"
	fi
else
	tk_skip "No journal or syslog file found (common in containers: check the container's own logs)"
fi

# --- Log storage -------------------------------------------------------------
tk_section "Log storage"
if [ -d /var/log ]; then
	kb=$(du -sk /var/log 2>/dev/null | awk '{ print $1 }')
	[ -n "$kb" ] && tk_kvn "Var log bytes" "$((kb * 1024))" "$(tk_human_bytes "$((kb * 1024))")"
	if tk_has journalctl; then
		usage=$(journalctl --disk-usage 2>/dev/null | sed -n 's/.* take up \([^ ]*\) .*/\1/p')
		tk_kv "Journal size" "$usage"
	fi
	pct=$(df -Pk /var/log 2>/dev/null | awk 'NR == 2 { sub(/%/, "", $5); print $5 }')
	if tk_is_uint "${pct:-}"; then
		tk_kvn "Filesystem used percent" "$pct" "$pct%"
		if [ "$pct" -ge 90 ]; then
			tk_warn "The filesystem holding /var/log is $pct% full; logs may stop being written"
		fi
	fi
	# Single files over 1 GiB (2097152 blocks of 512 bytes, POSIX find).
	big=$(find /var/log -xdev -type f -size +2097152 2>/dev/null | head -n 5)
	for f in $big; do
		tk_warn "$f is over 1 GiB; check log rotation (logrotate) for it"
	done
	[ -z "$big" ] && tk_ok "No log file over 1 GiB"
else
	tk_skip "/var/log does not exist"
fi

tk_finish
