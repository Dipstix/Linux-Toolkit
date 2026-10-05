#!/bin/sh
#
# cpu - processor model and count, load averages, a short utilization
# sample (user, system, iowait, steal) and the busiest processes.

TK_NAME=cpu
TK_DESC='Show CPU model, load, utilization, iowait, steal and the busiest processes'
TK_OPTIONS='      --interval N   Sample utilization over N seconds (default 1, 0 to skip)
      --load-warn N  Warn when 5-minute load per CPU is at least N (default 1.5)
      --load-crit N  Critical when 5-minute load per CPU is at least N (default 3)
      --top N        List the N busiest processes (default 5, 0 for none)'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

interval=1
load_warn=1.5
load_crit=3
top=5
while [ $# -gt 0 ]; do
	case $1 in
	--interval) tk_need_arg "$@"; interval=$2; shift ;;
	--load-warn) tk_need_arg "$@"; load_warn=$2; shift ;;
	--load-crit) tk_need_arg "$@"; load_crit=$2; shift ;;
	--top) tk_need_arg "$@"; top=$2; shift ;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done
tk_is_uint "$interval" || tk_usage_error "--interval needs a whole number of seconds"
tk_is_uint "$top" || tk_usage_error "--top needs a whole number"
for v in "$load_warn" "$load_crit"; do
	case $v in -*) tk_usage_error "load thresholds must not be negative" ;; esac
	tk_is_number "$v" || tk_usage_error "load thresholds must be numbers (got '$v')"
done
tk_ge "$load_crit" "$load_warn" || tk_usage_error "--load-warn must not be above --load-crit"

# Per-process CPU ticks as "P pid ticks name"; cat skips processes that
# exit mid-scan. The name is between the first "(" and the last ")".
proc_ticks() {
	cat "$TK_PROC"/[0-9]*/stat 2>/dev/null | awk '{
		name = $0; sub(/^[^(]*\(/, "", name); sub(/\) [^)]*$/, "", name)
		rest = $0; sub(/^.*\) /, "", rest); split(rest, f, " ")
		print "P", $1, f[12] + f[13], name
	}'
}

# The aggregate "cpu" line and the per-CPU line count from /proc/stat.
cpu_ticks() {
	awk '$1 == "cpu" { line = $0 } /^cpu[0-9]/ { n++ } END { print line, n + 0 }' "$TK_PROC/stat" 2>/dev/null
}

tk_start

tk_section "Processor"
# x86 says "model name"; ARM, MIPS and others use one of the other keys.
model=$(awk -F ': *' '
	$1 ~ /^(model name|Model|Hardware|cpu model|Processor)[ \t]*$/ && $2 != "" {
		k = $1; sub(/[ \t]+$/, "", k); if (!(k in v)) v[k] = $2
	}
	END {
		split("model name|Model|cpu model|Hardware|Processor", order, "|")
		for (i = 1; i <= 5; i++) if (order[i] in v) { print v[order[i]]; exit }
	}' "$TK_PROC/cpuinfo" 2>/dev/null)
ncpu=$(grep -c '^processor' "$TK_PROC/cpuinfo" 2>/dev/null)
[ "${ncpu:-0}" -gt 0 ] || ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
if ! tk_is_uint "${ncpu:-}" || [ "$ncpu" -eq 0 ]; then ncpu=1; fi
cores=$(awk -F: '/^physical id/ { p = $2 } /^core id/ { c[p ":" $2] = 1 } END { for (k in c) n++; print n + 0 }' \
	"$TK_PROC/cpuinfo" 2>/dev/null)
tk_kv "Model" "$model"
tk_kv "Architecture" "$(uname -m 2>/dev/null)"
tk_kvn "Logical CPUs" "$ncpu"
[ "${cores:-0}" -gt 0 ] && tk_kvn "Physical cores" "$cores"

# A container may be allowed less than the whole machine (cgroup v2 cpu.max).
cg_path=$(sed -n 's/^0:://p' "$TK_PROC/self/cgroup" 2>/dev/null | head -n 1)
for f in "$TK_SYS/fs/cgroup${cg_path}/cpu.max" "$TK_SYS/fs/cgroup/cpu.max"; do
	[ -r "$f" ] || continue
	quota=$(awk '$1 != "max" && $2 > 0 { printf "%.2f\n", $1 / $2 }' "$f")
	[ -n "$quota" ] && tk_kvn "Cgroup CPU limit" "$quota" "$quota CPUs"
	break
done

tk_section "Load"
read -r l1 l5 l15 procs _ <"$TK_PROC/loadavg" 2>/dev/null || tk_die "cannot read $TK_PROC/loadavg"
per=$(awk -v l="$l5" -v n="$ncpu" 'BEGIN { printf "%.2f\n", l / n }')
tk_kvn "Load 1m" "$l1"
tk_kvn "Load 5m" "$l5"
tk_kvn "Load 15m" "$l15"
tk_kvn "Load 5m per CPU" "$per"
tk_kv "Running and total tasks" "$procs"
if [ -r "$TK_PROC/pressure/cpu" ]; then
	psi=$(sed -n 's/^some .*avg60=\([0-9.]*\).*/\1/p' "$TK_PROC/pressure/cpu")
	tk_kvn "Pressure some avg60" "$psi" "${psi:+$psi%}"
fi
if tk_ge "$per" "$load_crit"; then
	tk_crit "Load is $l5 on $ncpu CPU(s) ($per per CPU); work is queueing, see the busiest processes"
elif tk_ge "$per" "$load_warn"; then
	tk_warn "Load is $l5 on $ncpu CPU(s) ($per per CPU, warning at $load_warn)"
else
	tk_ok "Load is $l5 on $ncpu CPU(s) ($per per CPU)"
fi

if [ "$interval" -gt 0 ]; then
	tk_section "Utilization"
	s0=$(cpu_ticks)
	p0=''
	[ "$top" -gt 0 ] && p0=$(proc_ticks)
	sleep "$interval"
	s1=$(cpu_ticks)
	p1=''
	[ "$top" -gt 0 ] && p1=$(proc_ticks)
	# Fields: cpu user nice system idle iowait irq softirq steal ... ncpu.
	# Process % is of one CPU (like top), so a busy 4-thread job shows 400.
	result=$(printf 'A %s\nB %s\n%s\n--\n%s\n' "$s0" "$s1" "$p0" "$p1" | awk -v self=$$ '
		# a[3..10]: user nice system idle iowait irq softirq steal; last: ncpu.
		function tot(x) { return x[3] + x[4] + x[5] + x[6] + x[7] + x[8] + x[9] + x[10] }
		$1 == "A" { split($0, a, " "); next }
		$1 == "B" { nb = split($0, b, " "); next }
		$1 == "--" { second = 1; next }
		$1 == "P" {
			name = $0; sub(/^P [0-9]+ [0-9]+ /, "", name)
			if ($2 == self) next
			if (!second) t0[$2] = $3
			else if ($2 in t0) { d[$2] = $3 - t0[$2]; nm[$2] = name }
		}
		END {
			dt = tot(b) - tot(a)
			if (dt <= 0) { print "U||||||"; exit }
			us = b[3] + b[4] - a[3] - a[4]
			sy = b[5] + b[8] + b[9] - a[5] - a[8] - a[9]
			idle = b[6] - a[6]; io = b[7] - a[7]; st = b[10] - a[10]
			printf "U|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f\n", us * 100 / dt, sy * 100 / dt, io * 100 / dt, \
				st * 100 / dt, idle * 100 / dt, (dt - idle - io) * 100 / dt
			n = b[nb] + 0; if (n < 1) n = 1
			for (p in d) if (d[p] > 0) printf "T|%.1f|%s|%s\n", d[p] * 100 * n / dt, p, nm[p]
		}')
	IFS='|' read -r _ us sy io st idle busy <<EOF
$(printf '%s\n' "$result" | grep '^U|')
EOF
	if [ -z "$busy" ]; then
		tk_skip "Could not sample CPU time from $TK_PROC/stat"
	else
		tk_kvn "Busy percent" "$busy" "$busy%"
		tk_kvn "User percent" "$us" "$us%"
		tk_kvn "System percent" "$sy" "$sy%"
		tk_kvn "Iowait percent" "$io" "$io%"
		tk_kvn "Steal percent" "$st" "$st%"
		tk_kvn "Idle percent" "$idle" "$idle%"
		if tk_ge "$busy" 90; then
			tk_warn "CPUs were $busy% busy over ${interval}s; see the busiest processes"
		else
			tk_ok "CPUs were $busy% busy over ${interval}s"
		fi
		if tk_ge "$io" 20; then
			tk_warn "CPUs spent $io% of the time waiting on disk I/O; check toolkit disk"
		fi
		if tk_ge "$st" 10; then
			tk_warn "The hypervisor took $st% of CPU time (steal); the host may be overcommitted"
		fi
	fi

	if [ "$top" -gt 0 ] && [ -n "$busy" ]; then
		tk_section "Top processes"
		list=$(printf '%s\n' "$result" | grep '^T|' | sort -t '|' -k 2,2nr | head -n "$top")
		items=''
		tk_print '  %-8s %6s  %s\n' PID CPU% NAME
		while IFS='|' read -r _ cpu pid name; do
			[ -n "$pid" ] || continue
			tk_print '  %-8s %6s  %s\n' "$pid" "$cpu" "$name"
			items="${items:+$items,}{\"pid\":$pid,\"cpu_percent\":$cpu,\"name\":$(tk_json_str "$name")}"
		done <<EOF
$list
EOF
		tk_kvj "Processes" "[$items]"
		[ -n "$items" ] || tk_print '  (no process used measurable CPU)\n'
	fi
fi

# Thermal zones report millidegrees Celsius. Many VMs have none.
tmax=$(cat "$TK_SYS"/class/thermal/thermal_zone*/temp 2>/dev/null |
	awk '$1 > m { m = $1 } END { if (m > 0) printf "%d\n", m / 1000 }')
if [ -n "$tmax" ]; then
	tk_section "Temperature"
	tk_kvn "Hottest zone celsius" "$tmax" "$tmax C"
	if [ "$tmax" -ge 90 ]; then
		tk_warn "A thermal zone is at ${tmax}C; check cooling, the CPU may be throttling"
	else
		tk_ok "Hottest thermal zone is ${tmax}C"
	fi
fi

tk_finish
