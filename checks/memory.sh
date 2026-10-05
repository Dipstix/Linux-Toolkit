#!/bin/sh
#
# memory - RAM and swap: how much is really in use (page cache counts as
# free), container limits, memory pressure, OOM kills and the biggest
# processes.

TK_NAME=memory
TK_DESC='Show RAM and swap use, memory pressure, OOM kills and top memory users'
TK_OPTIONS='      --warn N       Warn when RAM use is at least N% (default 85)
      --crit N       Critical when RAM use is at least N% (default 95)
      --swap-warn N  Warn when swap use is at least N% (default 80)
      --top N        List the N largest processes (default 5, 0 for none)'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

warn=85
crit=95
swap_warn=80
top=5
while [ $# -gt 0 ]; do
	case $1 in
	--warn) tk_need_arg "$@"; warn=$2; shift ;;
	--crit) tk_need_arg "$@"; crit=$2; shift ;;
	--swap-warn) tk_need_arg "$@"; swap_warn=$2; shift ;;
	--top) tk_need_arg "$@"; top=$2; shift ;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done
for v in "$warn" "$crit" "$swap_warn" "$top"; do
	tk_is_uint "$v" || tk_usage_error "option values must be whole numbers (got '$v')"
done
[ "$warn" -le "$crit" ] || tk_usage_error "--warn must not be above --crit"

meminfo=$TK_PROC/meminfo
[ -r "$meminfo" ] || tk_die "cannot read $meminfo (is /proc mounted?)"

# mem KEY: a /proc/meminfo value in bytes, empty if the kernel lacks it.
mem() {
	awk -v k="$1:" '$1 == k { printf "%.0f\n", $2 * 1024; exit }' "$meminfo"
}

# level PCT WHAT: report PCT% use of WHAT against --warn/--crit.
level() {
	if [ "$1" -ge "$crit" ]; then
		tk_crit "$2 is $1% used; find what is using it below, or add memory"
	elif [ "$1" -ge "$warn" ]; then
		tk_warn "$2 is $1% used (warning at $warn%)"
	else
		tk_ok "$2 is $1% used"
	fi
}

tk_start

total=$(mem MemTotal)
free=$(mem MemFree)
buffers=$(mem Buffers)
cached=$(mem Cached)
reclaimable=$(mem SReclaimable)
avail=$(mem MemAvailable)
if [ -z "$avail" ]; then
	# Kernels before 3.14 have no MemAvailable; estimate it the old way.
	avail=$(awk -v a="${free:-0}" -v b="${buffers:-0}" -v c="${cached:-0}" -v r="${reclaimable:-0}" \
		'BEGIN { printf "%.0f\n", a + b + c + r }')
fi
[ -n "$total" ] || tk_die "no MemTotal in $meminfo"
used=$(awk -v t="$total" -v a="$avail" 'BEGIN { u = t - a; if (u < 0) u = 0; printf "%.0f\n", u }')
cache=$(awk -v b="${buffers:-0}" -v c="${cached:-0}" -v r="${reclaimable:-0}" 'BEGIN { printf "%.0f\n", b + c + r }')
pct=$(tk_pct "$used" "$total")

tk_section "Memory"
tk_kvn "Total bytes" "$total" "$(tk_human_bytes "$total")"
tk_kvn "Used bytes" "$used" "$(tk_human_bytes "$used")"
tk_kvn "Available bytes" "$avail" "$(tk_human_bytes "$avail")"
tk_kvn "Cache bytes" "$cache" "$(tk_human_bytes "$cache")"
shmem=$(mem Shmem)
[ -n "$shmem" ] && tk_kvn "Shared bytes" "$shmem" "$(tk_human_bytes "$shmem")"
tk_kvn "Used percent" "$pct" "$pct%"
level "$pct" "Memory"

swap_total=$(mem SwapTotal)
swap_free=$(mem SwapFree)
tk_section "Swap"
if [ "${swap_total:-0}" = 0 ]; then
	tk_kvn "Total bytes" 0 "none"
	tk_info "No swap configured"
else
	swap_used=$(awk -v t="$swap_total" -v f="${swap_free:-0}" 'BEGIN { printf "%.0f\n", t - f }')
	swap_pct=$(tk_pct "$swap_used" "$swap_total")
	tk_kvn "Total bytes" "$swap_total" "$(tk_human_bytes "$swap_total")"
	tk_kvn "Used bytes" "$swap_used" "$(tk_human_bytes "$swap_used")"
	tk_kvn "Used percent" "$swap_pct" "$swap_pct%"
	if [ "$swap_pct" -ge "$swap_warn" ]; then
		tk_warn "Swap is $swap_pct% used; the system may be short of RAM"
	else
		tk_ok "Swap is $swap_pct% used"
	fi
fi

# Container or service memory limit (cgroup v2, then v1).
cg_limit='' cg_usage=''
cg_path=$(sed -n 's/^0:://p' "$TK_PROC/self/cgroup" 2>/dev/null | head -n 1)
for d in "$TK_SYS/fs/cgroup${cg_path}" "$TK_SYS/fs/cgroup"; do
	if [ -r "$d/memory.max" ]; then
		cg_limit=$(cat "$d/memory.max" 2>/dev/null)
		cg_cur=$(cat "$d/memory.current" 2>/dev/null)
		cg_inactive=$(awk '$1 == "inactive_file" { print $2 }' "$d/memory.stat" 2>/dev/null)
		break
	fi
done
if [ -z "$cg_limit" ] && [ -r "$TK_SYS/fs/cgroup/memory/memory.limit_in_bytes" ]; then
	d=$TK_SYS/fs/cgroup/memory
	cg_limit=$(cat "$d/memory.limit_in_bytes" 2>/dev/null)
	cg_cur=$(cat "$d/memory.usage_in_bytes" 2>/dev/null)
	cg_inactive=$(awk '$1 == "total_inactive_file" { print $2 }' "$d/memory.stat" 2>/dev/null)
fi
# Only a real limit counts: "max", or a number above physical RAM, is none.
if tk_is_uint "$cg_limit" && tk_is_uint "${cg_cur:-}" &&
	awk -v l="$cg_limit" -v t="$total" 'BEGIN { exit !(l < t) }'; then
	cg_usage=$(awk -v c="$cg_cur" -v i="${cg_inactive:-0}" 'BEGIN { u = c - i; if (u < 0) u = 0; printf "%.0f\n", u }')
	cg_pct=$(tk_pct "$cg_usage" "$cg_limit")
	tk_section "Cgroup limit"
	tk_kvn "Limit bytes" "$cg_limit" "$(tk_human_bytes "$cg_limit")"
	tk_kvn "Used bytes" "$cg_usage" "$(tk_human_bytes "$cg_usage")"
	tk_kvn "Used percent" "$cg_pct" "$cg_pct%"
	level "$cg_pct" "The container/cgroup memory limit"
fi

# Pressure stall information (kernel 4.20+): share of time tasks waited
# on memory over the last 60 seconds.
if [ -r "$TK_PROC/pressure/memory" ]; then
	psi_some=$(sed -n 's/^some .*avg60=\([0-9.]*\).*/\1/p' "$TK_PROC/pressure/memory")
	psi_full=$(sed -n 's/^full .*avg60=\([0-9.]*\).*/\1/p' "$TK_PROC/pressure/memory")
	tk_section "Pressure"
	tk_kvn "Some avg60" "$psi_some" "${psi_some:+$psi_some%}"
	tk_kvn "Full avg60" "$psi_full" "${psi_full:+$psi_full%}"
	if [ -n "$psi_full" ] && tk_ge "$psi_full" 10; then
		tk_warn "All tasks stalled on memory $psi_full% of the last minute; the system is thrashing"
	elif [ -n "$psi_some" ] && tk_ge "$psi_some" 10; then
		tk_warn "Tasks waited on memory $psi_some% of the last minute"
	fi
fi

tk_section "OOM killer"
oom=$(awk '$1 == "oom_kill" { print $2 }' "$TK_PROC/vmstat" 2>/dev/null)
if [ -n "$oom" ]; then
	tk_kvn "Kills since boot" "$oom"
	if [ "$oom" -gt 0 ]; then
		tk_warn "The OOM killer has killed $oom process(es) since boot; see toolkit logs for which"
	else
		tk_ok "No OOM kills since boot"
	fi
else
	tk_skip "This kernel does not count OOM kills (needs 4.13+); see toolkit logs"
fi

if [ "$top" -gt 0 ]; then
	tk_section "Top processes"
	# rss|pid|name, largest first. cat skips processes that exit mid-scan.
	list=$(cat "$TK_PROC"/[0-9]*/status 2>/dev/null | awk '
		/^Name:/ { name = $0; sub(/^Name:[ \t]*/, "", name) }
		/^Pid:/ { pid = $2 }
		/^VmRSS:/ { printf "%.0f|%s|%s\n", $2 * 1024, pid, name }' |
		sort -t '|' -k 1,1nr | head -n "$top")
	items=''
	tk_print '  %-8s %10s  %s\n' PID RSS NAME
	while IFS='|' read -r rss pid name; do
		[ -n "$rss" ] || continue
		tk_print '  %-8s %10s  %s\n' "$pid" "$(tk_human_bytes "$rss")" "$name"
		items="${items:+$items,}{\"pid\":$pid,\"rss_bytes\":$rss,\"name\":$(tk_json_str "$name")}"
	done <<EOF
$list
EOF
	tk_kvj "Processes" "[$items]"
	[ -n "$items" ] || tk_skip "Could not read process memory from $TK_PROC"
fi

tk_finish
