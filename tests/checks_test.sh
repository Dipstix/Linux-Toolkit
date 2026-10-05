#!/bin/sh
#
# Scenario tests for the health checks. Each test feeds a check fake
# kernel files (TK_PROC/TK_SYS) or fake tools (systemctl, rc-status, df,
# dmesg, journalctl) and asserts the exit status and the key messages.
# Run with any POSIX shell; TK_SHELL picks the shell the checks run under:
#   TK_SHELL="bash --posix" dash tests/checks_test.sh

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SH=${TK_SHELL:-sh}
tmp=$(mktemp -d) || exit 3
trap 'rm -rf "$tmp"' EXIT

fails=0
# expect NAME WANT_RC PATTERN CMD...: run CMD, check its exit status and
# that its output matches the extended regex PATTERN.
expect() {
	_name=$1 _want=$2 _pat=$3
	shift 3
	_out=$("$@" 2>&1)
	_rc=$?
	if [ "$_rc" = "$_want" ] && printf '%s\n' "$_out" | grep -Eq -- "$_pat"; then
		printf 'ok   %s\n' "$_name"
	else
		printf 'FAIL %s (exit %s, wanted %s; pattern %s)\n' "$_name" "$_rc" "$_want" "$_pat"
		printf '%s\n' "$_out" | sed 's/^/     | /'
		fails=$((fails + 1))
	fi
}

# check NAME [ARGS...]: run checks/NAME.sh under the shell being tested.
check() {
	_c=$1
	shift
	# shellcheck disable=SC2086 # SH may be "bash --posix"
	$SH "$ROOT/checks/$_c.sh" --no-color "$@"
}

# stub NAME BODY: a fake command in $tmp/bin.
mkdir -p "$tmp/bin"
stub() {
	printf '#!/bin/sh\n%s\n' "$2" >"$tmp/bin/$1"
	chmod +x "$tmp/bin/$1"
}

# --- memory ------------------------------------------------------------------
P=$tmp/proc
mkdir -p "$P" "$tmp/sys"
meminfo() {
	# total_kB available_kB swap_total_kB swap_free_kB
	printf 'MemTotal: %s kB\nMemFree: 100 kB\nMemAvailable: %s kB\nBuffers: 0 kB\nCached: 0 kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' \
		"$1" "$2" "$3" "$4" >"$P/meminfo"
}
mem() { TK_PROC=$P TK_SYS=$tmp/sys check memory --top 0 "$@"; }

printf 'oom_kill 0\n' >"$P/vmstat"
meminfo 1000000 500000 0 0
expect "memory: 50% used is ok" 0 'Memory is 50% used' mem
expect "memory: no swap noted" 0 'No swap configured' mem
meminfo 1000000 100000 0 0
expect "memory: 90% used warns" 1 '\[WARN\] Memory is 90% used' mem
meminfo 1000000 20000 0 0
expect "memory: 98% used is critical" 2 '\[CRIT\] Memory is 98% used' mem
expect "memory: thresholds are options" 0 'Memory is 98% used' mem --warn 99 --crit 99
meminfo 1000000 500000 1000 100
expect "memory: swap 90% used warns" 1 'Swap is 90% used' mem
printf 'MemTotal: 1000 kB\nMemFree: 200 kB\nBuffers: 100 kB\nCached: 200 kB\n' >"$P/meminfo"
expect "memory: estimates MemAvailable on old kernels" 0 'Memory is 50% used' mem
meminfo 1000000 500000 0 0
printf 'oom_kill 3\n' >"$P/vmstat"
expect "memory: OOM kills warn" 1 'OOM killer has killed 3' mem
printf 'oom_kill 0\n' >"$P/vmstat"
mkdir -p "$tmp/sys/fs/cgroup"
echo 102400000 >"$tmp/sys/fs/cgroup/memory.max"
echo 100000000 >"$tmp/sys/fs/cgroup/memory.current"
echo 'inactive_file 1000000' >"$tmp/sys/fs/cgroup/memory.stat"
expect "memory: cgroup limit nearly reached is critical" 2 'cgroup memory limit is 97% used' mem
echo max >"$tmp/sys/fs/cgroup/memory.max"
expect "memory: unlimited cgroup is ignored" 0 'Memory is 50% used' mem
expect "memory: bad option value" 3 'whole numbers' mem --warn abc
expect "memory: warn above crit" 3 'must not be above' mem --warn 99 --crit 90

# --- cpu ---------------------------------------------------------------------
printf 'processor : 0\nmodel name : Test CPU\nprocessor : 1\nmodel name : Test CPU\n' >"$P/cpuinfo"
cpu() { TK_PROC=$P TK_SYS=$tmp/sys check cpu --interval 0 "$@"; }
echo '0.50 0.40 0.30 1/100 999' >"$P/loadavg"
expect "cpu: light load is ok" 0 'Load is 0.40 on 2 CPU\(s\)' cpu
expect "cpu: reads the model" 0 'Model: +Test CPU' cpu
echo '4.00 4.00 4.00 3/100 999' >"$P/loadavg"
expect "cpu: 2 per CPU warns" 1 '\[WARN\] Load is 4.00 on 2 CPU' cpu
echo '9.00 9.00 9.00 3/100 999' >"$P/loadavg"
expect "cpu: 4.5 per CPU is critical" 2 '\[CRIT\] Load is 9.00' cpu
expect "cpu: load thresholds are options" 0 'Load is 9.00' cpu --load-warn 5 --load-crit 6
printf 'cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 100 0 100 800 0 0 0 0 0 0\n' >"$P/stat"
cpu1() { TK_PROC=$P TK_SYS=$tmp/sys check cpu --interval 1; }
expect "cpu: a frozen /proc/stat is skipped, not a crash" 2 'Could not sample' cpu1
expect "cpu: bad interval" 3 'interval' cpu --interval x

# --- disk --------------------------------------------------------------------
# Fake df output and /proc/mounts. Mount points must exist, so use / and
# directories in $tmp.
mkdir -p "$tmp/data" "$tmp/ro"
cat >"$P/mounts" <<EOF
/dev/sda1 / ext4 rw,relatime 0 0
/dev/sdb1 $tmp/data xfs rw,relatime 0 0
/dev/sdc1 $tmp/ro ext4 ro,relatime 0 0
proc /proc proc rw 0 0
EOF
dfout() {
	# root% data% inode% for the data filesystem
	stub df "case \$1 in
-Pi) printf '%s\n' 'Filesystem Inodes IUsed IFree IUse% Mounted on' \\
	'/dev/sda1 1000 10 990 1% /' '/dev/sdb1 1000 $3 0 0% $tmp/data' '/dev/sdc1 1000 10 990 1% $tmp/ro' ;;
*) printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' \\
	'/dev/sda1 1000 $1 $((1000 - $1)) $1% /' '/dev/sdb1 1000 $2 $((1000 - $2)) $2% $tmp/data' \\
	'/dev/sdc1 1000 999 1 100% $tmp/ro' 'proc 0 0 0 0% /proc' ;;
esac"
}
disk() {
	PATH="$tmp/bin:$PATH" TK_PROC=$P TK_SYS=$tmp/sys _TK_VIRT_DONE=1 TK_CONTAINER='' TK_VIRT='' \
		check disk "$@"
}
dfout 500 100 10
expect "disk: read-only data filesystem warns" 1 '\[WARN\] .*/ro \(ext4\) is mounted read-only' disk
expect "disk: pseudo filesystems are skipped" 1 'Count: +3' disk
dfout 900 100 10
expect "disk: 90% full warns" 1 '\[WARN\] / is 90% full' disk
dfout 970 100 10
expect "disk: 97% full is critical" 2 '\[CRIT\] / is 97% full' disk
dfout 500 100 990
expect "disk: inodes nearly exhausted is critical" 2 "\\[CRIT\\] $tmp/data has used 99% of its inodes" disk
expect "disk: JSON lists mounts" 2 '"mount":"/","device":"/dev/sda1","fstype":"ext4"' disk --json
rm -f "$tmp/bin/df"

# --- services ----------------------------------------------------------------
stub systemctl 'case "$*" in
is-system-running*) echo degraded ;;
*--state=failed*) echo "nginx.service loaded failed failed A high performance web server" ;;
*--state=running*) printf "a.service loaded active running A\nb.service loaded active running B\n" ;;
"is-active --quiet sshd") exit 0 ;;
is-active*) exit 3 ;;
esac'
svc_sd() { PATH="$tmp/bin:$PATH" _TK_INIT_DONE=1 TK_INIT=systemd check services "$@"; }
expect "services: systemd failed unit warns" 1 '\[WARN\] nginx.service has failed; see: systemctl status nginx.service' svc_sd
expect "services: systemd running count" 1 'Running: +2' svc_sd
expect "services: expected and running" 1 '\[ OK \] sshd is running' svc_sd --expect sshd
expect "services: expected but stopped is critical" 2 '\[CRIT\] postgresql is not running' svc_sd --expect sshd,postgresql
expect "services: bad --expect" 3 'service names' svc_sd --expect 'a;b'

stub rc-status 'case "$*" in
-r) echo default ;;
*) printf " Runlevel: default\n sshd     [  started  ]\n crond    [  crashed  ]\n local    [  stopped  ]\n" ;;
esac'
svc_rc() { PATH="$tmp/bin:$PATH" _TK_INIT_DONE=1 TK_INIT=openrc check services "$@"; }
expect "services: openrc crashed service warns" 1 '\[WARN\] crond has failed' svc_rc
expect "services: openrc stopped service is noted" 1 'local is in this runlevel but stopped' svc_rc
svc_none() { _TK_INIT_DONE=1 TK_INIT=none TK_PROC=$P check services "$@"; }
mkdir -p "$P/42"
echo myapp >"$P/42/comm"
expect "services: no init falls back to processes" 0 '\[ OK \] myapp is running' svc_none --expect myapp
expect "services: missing process is critical" 2 '\[CRIT\] otherd is not running' svc_none --expect otherd

# --- logs --------------------------------------------------------------------
klog='[    1.0] Linux version 6.1
[  100.0] Out of memory: Killed process 1234 (java) total-vm:100kB
[  200.0] blk_update_request: I/O error, dev sda, sector 42
[  300.0] Buffer I/O error on dev sda1, logical block 7
[  400.0] app[99]: segfault at 0 ip 0 sp 0 error 4'
stub dmesg "cat <<'EOF'
$klog
EOF"
# A journal with nothing in it, so the dmesg path is used.
stub journalctl 'exit 0'
lg() { PATH="$tmp/bin:$PATH" check logs "$@"; }
expect "logs: I/O errors are critical" 2 '\[CRIT\] Disk IO errors in the kernel log since boot: 2' lg
expect "logs: OOM kills warn with the victim" 2 'OOM kills in the kernel log since boot: 1; last: Out of memory: Killed process 1234 \(java\)' lg
expect "logs: segfaults are info" 2 '\[INFO\] Segfaults' lg
expect "logs: JSON counts" 2 '"oom_kills":1,"disk_io_errors":2' lg --json
stub dmesg 'echo "[    1.0] Linux version 6.1"'
expect "logs: clean kernel log is ok" 0 'No OOM kills, I/O, filesystem or hardware errors' lg
# A journal with entries: errors come from journalctl -p err.
stub journalctl 'case "$*" in
*-k*) echo "Oct 05 10:00:00 host kernel: Linux version 6.1" ;;
*"-p err"*) printf "Oct 05 10:00:00 host sshd[1]: error: bad thing\nOct 05 11:00:00 host cron[2]: failed job\n" ;;
*--disk-usage*) echo "Archived and active journals take up 48.0M in the file system." ;;
*) echo "Oct 05 10:00:00 host something" ;;
esac'
expect "logs: journal errors are counted" 0 '2 error message\(s\) in the last 24h' lg
expect "logs: latest errors are shown" 0 'cron\[2\]: failed job' lg
expect "logs: journal size" 0 'Journal size: +48.0M' lg
expect "logs: bad --hours" 3 'hours' lg --hours 0

[ "$fails" -eq 0 ] || {
	printf '%d failure(s)\n' "$fails"
	exit 1
}
