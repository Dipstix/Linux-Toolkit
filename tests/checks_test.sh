#!/bin/sh
#
# Scenario tests for the checks. Each test feeds a check fake kernel
# files (TK_PROC/TK_SYS), config and log files (TK_ETC/TK_LOGDIR) or fake
# tools (systemctl, df, journalctl, iptables, nc...) and asserts the exit
# status and the key messages.
# Run with any POSIX shell; TK_SHELL picks the shell the checks run under:
#   TK_SHELL="bash --posix" dash tests/checks_test.sh

# Stub bodies are run by the stub, so their $1 must not expand here.
# shellcheck disable=SC2016

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


# --- network -------------------------------------------------------------------
N=$tmp/net
S=$tmp/netsys
# nic NAME OPERSTATE CARRIER FLAGS PHYSICAL [RX_PACKETS RX_ERRORS]
nic() {
	_d=$S/class/net/$1
	mkdir -p "$_d/statistics"
	echo "$2" >"$_d/operstate"
	echo "$3" >"$_d/carrier"
	echo "$4" >"$_d/flags"
	echo 1500 >"$_d/mtu"
	echo 02:00:00:00:00:01 >"$_d/address"
	if [ "$5" = 1 ]; then mkdir -p "$_d/device"; echo 1000 >"$_d/speed"; echo full >"$_d/duplex"; fi
	for _s in rx_bytes tx_bytes tx_packets tx_errors rx_dropped tx_dropped; do echo 0 >"$_d/statistics/$_s"; done
	echo "${6:-1000}" >"$_d/statistics/rx_packets"
	echo "${7:-0}" >"$_d/statistics/rx_errors"
}
mkdir -p "$N/net" "$N/sys/net/ipv4"
echo 0 >"$N/sys/net/ipv4/ip_forward"
route_default() {
	{
		printf 'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n'
		[ "$1" = 1 ] && printf 'eth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'
		printf 'eth0\t0001A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n'
	} >"$N/net/route"
}
arp() {
	printf 'IP address       HW type     Flags       HW address            Mask     Device\n192.168.1.1      0x1         %s         aa:bb:cc:dd:ee:ff     *        eth0\n' "$1" >"$N/net/arp"
}
stub ip 'echo "2: eth0    inet 192.168.1.10/24 brd 192.168.1.255 scope global eth0\       valid_lft forever"'
net() { PATH="$tmp/bin:$PATH" TK_PROC=$N TK_SYS=$S check network "$@"; }

rm -rf "$S"
nic eth0 up 1 0x1003 1
nic docker0 down 0 0x1003 0
route_default 1
arp 0x2
expect "network: healthy host is ok" 0 '\[ OK \] Default route via 192.168.1.1 on eth0' net
expect "network: shows addresses" 0 'eth0 +up +1500 +1000Mb/s +192.168.1.10/24' net
expect "network: gateway answers ARP" 0 'The default gateway 192.168.1.1 answers ARP' net
expect "network: virtual interface without link is fine" 0 '1 of 2 interface\(s\) up' net
expect "network: JSON lists interfaces" 0 '"name":"eth0","state":"up","admin_up":true,"carrier":true,"virtual":false' net --json
nic eth1 down 0 0x1003 1
expect "network: enabled NIC without link warns" 1 '\[WARN\] eth1 is enabled but has no link' net
rm -rf "$S/class/net/eth1"
nic eth0 up 1 0x1003 1 1000 50
expect "network: interface errors warn" 1 'eth0 has 50 receive/transmit errors \(5.00% of packets\)' net
nic eth0 up 1 0x1003 1 1000000 5
expect "network: a few errors are info" 0 '\[INFO\] eth0 has 5 receive/transmit errors' net
nic eth0 up 1 0x1003 1
arp 0x0
expect "network: gateway not answering ARP is critical" 2 '\[CRIT\] The default gateway 192.168.1.1 does not answer ARP' net
arp 0x2
route_default 0
expect "network: no default route warns" 1 '\[WARN\] No default route' net
route_default 1
printf '%s\n' '00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000001 00000000 00000003 eth0' \
	'00000000000000000000000000000000 00 00000000000000000000000000000000 00 00000000000000000000000000000000 ffffffff 00000001 00000000 00200200 lo' >"$N/net/ipv6_route"
expect "network: IPv6 default gateway" 0 'IPv6 default gateway: +fe80::1' net
nic eth0 down 0 0x1002 1
expect "network: nothing up is critical" 2 '\[CRIT\] No network interface is up' net

# --- dns -----------------------------------------------------------------------
E=$tmp/etc
mkdir -p "$E"
printf 'hosts: files dns\n' >"$E/nsswitch.conf"
# getent knows example.com and this host, and nothing else.
stub getent 'case "$2" in
example.com) echo "93.184.215.14   example.com" ;;
"$(uname -n)") echo "127.0.1.1 $2" ;;
*) exit 2 ;;
esac'
stub dig 'case "$*" in
*@10.0.0.9*) echo ";; connection timed out; no servers could be reached"; exit 9 ;;
*) echo ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1" ;;
esac'
dns() { PATH="$tmp/bin:$PATH" TK_ETC=$E check dns "$@"; }
printf 'nameserver 10.0.0.1\nsearch example.lan\noptions timeout:2\n' >"$E/resolv.conf"
expect "dns: working resolver is ok" 0 '\[ OK \] example.com resolves to 93.184.215.14' dns
expect "dns: reads resolv.conf" 0 'Search: +example.lan' dns
expect "dns: hostname resolves" 0 'The hostname .* resolves' dns
expect "dns: each nameserver is asked" 0 '\[ OK \] 10.0.0.1 answers queries' dns
expect "dns: JSON results" 0 '"name":"example.com","resolved":true,"address":"93.184.215.14"' dns --json
expect "dns: failed lookup is critical" 2 '\[CRIT\] nope.invalid does not resolve' dns --name example.com,nope.invalid
printf 'nameserver 10.0.0.9\nnameserver 10.0.0.1\n' >"$E/resolv.conf"
expect "dns: dead nameserver warns" 1 '\[WARN\] 10.0.0.9 does not answer queries' dns
printf 'nameserver 10.0.0.9\n' >"$E/resolv.conf"
expect "dns: no nameserver answering is critical" 2 'None of the configured nameservers answers' dns
expect "dns: --offline skips network lookups" 0 'The hostname .* resolves' dns --offline
printf 'nameserver 127.0.0.53\n' >"$E/resolv.conf"
expect "dns: systemd-resolved stub is noted" 0 'systemd-resolved' dns
printf '# no servers\n' >"$E/resolv.conf"
expect "dns: no nameserver is critical" 2 '\[CRIT\] No nameserver in' dns --offline
rm -f "$E/resolv.conf"
expect "dns: missing resolv.conf is critical" 2 'resolv.conf does not exist' dns --offline
stub getent 'exit 2'
printf 'nameserver 10.0.0.1\n' >"$E/resolv.conf"
expect "dns: unresolvable hostname warns" 1 '\[WARN\] The hostname .* does not resolve' dns --offline
expect "dns: bad --name" 3 'host names' dns --name 'a b'
rm -f "$tmp/bin/getent" "$tmp/bin/dig"

# --- ports ---------------------------------------------------------------------
Q=$tmp/portproc
mkdir -p "$Q/net" "$Q/200/fd"
echo sshd >"$Q/200/comm"
ln -s 'socket:[100]' "$Q/200/fd/3"
sock() {
	# hex_local_addr:hex_port state inode
	printf '   0: %s 00000000:0000 %s 00000000:00000000 00:00000000 00000000     0        0 %s 1 0000000000000000 100 0 0 10 0\n' "$1" "$2" "$3"
}
hdr='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
{
	echo "$hdr"
	sock 00000000:0016 0A 100
	sock 0100007F:1538 0A 102
	printf '   9: 0100007F:1538 0100007F:9C40 01 00000000:00000000 00:00000000 00000000     0        0 999 1\n'
} >"$Q/net/tcp"
printf '%s\n' "$hdr" >"$Q/net/tcp6"
printf '%s\n' "$hdr" >"$Q/net/udp"
ports() { TK_PROC=$Q check ports "$@"; }
expect "ports: clean host is ok" 0 '\[ OK \] No database, remote-admin or clear-text service' ports
expect "ports: shows the owning process" 0 'tcp +0.0.0.0 +22 +sshd/200' ports
expect "ports: established connections are not listed" 0 'Count: +2' ports
expect "ports: loopback is not exposed" 0 '"address":"127.0.0.1","port":5432,"exposed":false' ports --json
expect "ports: expected port listening" 0 '\[ OK \] Port 22/tcp is listening' ports --expect 22
expect "ports: expected port missing is critical" 2 '\[CRIT\] Nothing is listening on port 443/tcp' ports --expect 22,443
{
	echo "$hdr"
	sock 00000000:0016 0A 100
	sock 00000000:18EB 0A 101
} >"$Q/net/tcp"
{
	echo "$hdr"
	sock 00000000000000000000000000000000:0947 0A 103
	sock 0000000000000000FFFF00000100007F:0CEA 0A 104
} >"$Q/net/tcp6"
{
	echo "$hdr"
	sock 00000000:2BCB 07 105
} >"$Q/net/udp"
expect "ports: exposed Redis warns" 2 '\[WARN\] Redis listens on 0.0.0.0:6379' ports
expect "ports: Docker API on IPv6 wildcard is critical" 2 '\[CRIT\] Docker API \(no TLS\) listens on :::2375' ports
expect "ports: IPv4-mapped loopback is not exposed" 2 '"address":"::ffff:127.0.0.1","port":3306,"exposed":false' ports --json
expect "ports: UDP memcached warns" 2 'Memcached listens on 0.0.0.0:11211' ports
expect "ports: expected UDP port" 2 'Port 11211/udp is listening' ports --expect 11211/udp
expect "ports: bad --expect" 3 'port numbers' ports --expect ssh

# --- connectivity ----------------------------------------------------------------
C=$tmp/connproc
mkdir -p "$C/net"
cp "$N/net/route" "$C/net/route"
stub nc 'for a; do h=$p; p=$a; done
case "$h" in 10.9.9.9 | down.example) exit 1 ;; esac
exit 0'
stub ping 'echo "64 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=0.42 ms"'
conn() {
	PATH="$tmp/bin:$PATH" TK_PROC=$C https_proxy='' HTTPS_PROXY='' http_proxy='' HTTP_PROXY='' \
		check connectivity --timeout 1 "$@"
}
expect "connectivity: all targets reachable" 0 '\[ OK \] Connected to 192.0.2.80 port 443' conn --target 192.0.2.80:443,up.example:443
expect "connectivity: gateway ping" 0 'The gateway 192.168.1.1 answers ping in 0.42 ms' conn --target 192.0.2.80:443
expect "connectivity: one target down warns" 1 '\[WARN\] Could not connect to 10.9.9.9 port 5432' conn --target 192.0.2.80:443,10.9.9.9:5432
expect "connectivity: IP works but name fails hints at DNS" 1 'check name resolution with toolkit dns' conn --target 192.0.2.80:443,down.example:443
expect "connectivity: nothing reachable is critical" 2 '\[CRIT\] No target could be reached' conn --target 10.9.9.9:443
# shellcheck disable=SC2086 # SH may be "bash --posix"
expect "connectivity: proxy credentials are hidden" 2 'a proxy is configured \(http://proxy.lan:3128\)' \
	env https_proxy=http://user:secret@proxy.lan:3128 PATH="$tmp/bin:$PATH" TK_PROC=$C $SH "$ROOT/checks/connectivity.sh" --no-color --timeout 1 --target 10.9.9.9:443
stub ping 'echo "ping: socket: Operation not permitted"; exit 2'
expect "connectivity: ping not allowed is skipped" 0 '\[SKIP\] Not allowed to ping' conn --target 192.0.2.80:443
expect "connectivity: --no-ping" 0 'Gateway ping skipped' conn --no-ping --target 192.0.2.80:443
stub curl 'echo 200'
expect "connectivity: URL fetched" 0 '\[ OK \] Fetched https://example.com \(HTTP 200\)' conn --no-ping --target 192.0.2.80:443 --url https://example.com
stub curl 'echo 503'
expect "connectivity: URL error status warns" 1 'answered with HTTP 503' conn --no-ping --target 192.0.2.80:443 --url https://example.com
stub curl 'echo 000; exit 7'
expect "connectivity: URL unreachable is critical" 2 '\[CRIT\] Could not fetch https://example.com' conn --no-ping --target 192.0.2.80:443 --url https://example.com
expect "connectivity: bad target" 3 'needs a port' conn --target example.com
expect "connectivity: bad url" 3 'http' conn --url ftp://x
rm -f "$tmp/bin/nc" "$tmp/bin/ping" "$tmp/bin/curl"

# --- firewall --------------------------------------------------------------------
# A bin directory with only basic tools, so the real iptables, nft or ufw
# on this machine are never seen; each scenario adds the fakes it needs.
F=$tmp/fwbin
mkdir -p "$F"
# Look each tool up on PATH: `command -v` names builtins, not files, and
# mksh has no printf builtin, and yash looks some builtins up on PATH.
for t in awk sed grep cat head tail tr sort uniq cut uname date id dirname ls timeout \
	printf echo [ test true false ${SH%% *}; do
	case $t in /*) [ -x "$t" ] && ln -sf "$t" "$F/"; continue ;; esac
	for d in $(printf '%s' "$PATH" | tr ':' ' '); do
		[ -x "$d/$t" ] && { ln -sf "$d/$t" "$F/$t"; break; }
	done
done
fwstub() {
	printf '#!/bin/sh\n%s\n' "$2" >"$F/$1"
	chmod +x "$F/$1"
}
fwclear() { rm -f "$F/iptables" "$F/ip6tables" "$F/nft" "$F/ufw" "$F/firewall-cmd"; }
FP=$tmp/fwproc
mkdir -p "$FP/net"
: >"$FP/net/if_inet6"
fw() { PATH=$F TK_PROC=$FP _TK_VIRT_DONE=1 TK_CONTAINER='' TK_VIRT='' check firewall "$@"; }

fwstub iptables 'printf "%s\n" "-P INPUT ACCEPT" "-P FORWARD ACCEPT" "-P OUTPUT ACCEPT"'
expect "firewall: nothing filtering warns" 1 '\[WARN\] No firewall rules filter incoming traffic' fw
fwstub iptables 'printf "%s\n" "-P INPUT DROP" "-P FORWARD DROP" "-P OUTPUT ACCEPT" "-A INPUT -i lo -j ACCEPT" "-A INPUT -p tcp --dport 22 -j ACCEPT"'
expect "firewall: iptables DROP policy is ok" 0 '\[ OK \] Incoming traffic is filtered by iptables' fw
expect "firewall: JSON input policy" 0 '"input_policy":"DROP","input_rules":2' fw --json
fwstub ip6tables 'printf "%s\n" "-P INPUT ACCEPT" "-P FORWARD ACCEPT" "-P OUTPUT ACCEPT"'
echo '20010db8000000000000000000000001 02 40 00 80     eth0' >"$FP/net/if_inet6"
expect "firewall: IPv6 left open warns" 1 '\[WARN\] IPv4 is filtered but IPv6 is not' fw
: >"$FP/net/if_inet6"
expect "firewall: open IPv6 without a public address is fine" 0 'filtered by iptables' fw
fwclear
fwstub iptables 'printf "%s\n" "-P INPUT DROP" "-N DOCKER" "-N ufw-before-input" "-A INPUT -j ufw-before-input"'
fwstub ufw 'printf "Status: active\n\nTo                         Action      From\n--                         ------      ----\n22/tcp                     ALLOW IN    Anywhere\n"'
expect "firewall: ufw active" 0 '\[ OK \] ufw is active' fw
expect "firewall: Docker bypasses ufw" 0 'ports it publishes bypass ufw' fw
fwclear
fwstub nft 'cat <<EOF
table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
		iif "lo" accept
		tcp dport 22 accept
	}
	chain output {
		type filter hook output priority filter; policy accept;
	}
}
EOF'
expect "firewall: nftables drop policy" 0 '\[ OK \] nftables filters incoming traffic' fw
expect "firewall: nftables rule count" 0 'Rules: +3' fw
fwclear
fwstub iptables 'echo "iptables v1.8.10 (nf_tables): Could not fetch rule set generation id: Permission denied (you must be root)" >&2; exit 4'
expect "firewall: unreadable rules are skipped" 0 '\[SKIP\] Could not read the firewall rules' fw
fwclear
expect "firewall: no tool at all warns" 1 '\[WARN\] No firewall tool found' fw
fwc() { PATH=$F TK_PROC=$FP _TK_VIRT_DONE=1 TK_CONTAINER=docker check firewall "$@"; }
expect "firewall: containers defer to the host" 0 '\[INFO\] Running in a container \(docker\)' fwc
fwstub firewall-cmd 'case "$1" in
--state) echo running ;;
--get-default-zone) echo trusted ;;
*) echo "ssh" ;;
esac'
expect "firewall: firewalld trusted zone warns" 1 "default firewalld zone is 'trusted'" fw
fwclear

# --- logins ----------------------------------------------------------------------
L=$tmp/logins
mkdir -p "$L/etc/ssh/sshd_config.d" "$L/log"
authlog=$tmp/auth.txt
{
	i=0
	while [ "$i" -lt 12 ]; do
		echo "Oct 05 10:00:0$((i % 10)) host sshd[100]: Failed password for root from 203.0.113.5 port 5000 ssh2"
		i=$((i + 1))
	done
	echo "Oct 05 10:01:00 host sshd[101]: Invalid user admin from 198.51.100.7 port 4000"
	echo "Oct 05 10:01:00 host sshd[101]: Failed password for invalid user admin from 198.51.100.7 port 4000 ssh2"
	echo "Oct 05 10:03:00 host sshd[103]: Accepted password for deploy from 203.0.113.5 port 5001 ssh2"
	echo "Oct 05 10:04:00 host su[200]: pam_unix(su:auth): authentication failure; logname=bob uid=1000 euid=0 tty=pts/0 ruser=bob rhost=  user=root"
	echo "Oct 05 10:05:00 host sshd[104]: Accepted publickey for root from 192.0.2.10 port 6000 ssh2"
} >"$authlog"
stub journalctl "cat '$authlog'"
stub sshd 'exit 1'
printf 'root:x:0:0:root:/root:/bin/bash\nbob:x:1000:1000::/home/bob:/bin/sh\ndaemon:x:1:1::/:/usr/sbin/nologin\n' >"$L/etc/passwd"
printf 'Include sshd_config.d/*.conf\nPort 2222\nPermitRootLogin yes\nMatch User bob\n  PasswordAuthentication no\n' >"$L/etc/ssh/sshd_config"
lg2() { PATH="$tmp/bin:$PATH" TK_ETC=$L/etc TK_LOGDIR=$L/log check logins "$@"; }
expect "logins: counts SSH failures" 2 'SSH failures: +13' lg2
expect "logins: top source" 2 '12 +203.0.113.5' lg2
expect "logins: guessed then got in is critical" 2 '\[CRIT\] 203.0.113.5 failed to log in 12 times, then logged in as deploy' lg2
expect "logins: local failures" 2 'Local failures: +1' lg2
expect "logins: root SSH login is noted" 2 'root logged in over SSH 1 time' lg2
expect "logins: under the threshold is info" 2 '\[INFO\] 14 failed login\(s\)' lg2
expect "logins: over the threshold warns" 2 '\[WARN\] 14 failed logins, most from 203.0.113.5 \(12\)' lg2 --warn 10
expect "logins: JSON top sources" 2 '"top_sources":\[\{"address":"203.0.113.5","failures":12\},\{"address":"198.51.100.7","failures":1\}\]' lg2 --json
expect "logins: sshd_config is read" 2 'Port: +2222' lg2
expect "logins: PermitRootLogin yes warns" 2 '\[WARN\] root can log in over SSH with a password' lg2
expect "logins: settings after Match are ignored" 2 'Password authentication: +yes' lg2
printf 'PermitRootLogin no\n' >"$L/etc/ssh/sshd_config.d/10-root.conf"
expect "logins: Include files come first" 2 '\[ OK \] root cannot log in over SSH with a password' lg2
stub journalctl 'echo "Oct 05 10:00:00 host CRON[1]: pam_unix(cron:session): session opened for user root"'
expect "logins: clean log is ok" 0 '\[ OK \] No failed logins' lg2
printf 'PermitEmptyPasswords yes\n' >"$L/etc/ssh/sshd_config.d/20-empty.conf"
expect "logins: empty SSH passwords are critical" 2 '\[CRIT\] SSH accepts empty passwords' lg2
rm -f "$L/etc/ssh/sshd_config.d/20-empty.conf"
printf 'toor:x:0:0::/root:/bin/sh\n' >>"$L/etc/passwd"
expect "logins: extra UID 0 account is critical" 2 '\[CRIT\] toor has UID 0' lg2
printf 'root:$6$abc:19000::::::\nbob::19000::::::\n' >"$L/etc/shadow"
expect "logins: empty password is critical" 2 '\[CRIT\] bob has no password' lg2
# No journal: Dropbear lines from auth.log.
stub journalctl 'exit 0'
printf '%s\n' "Oct  5 10:00:00 host dropbear[9]: Bad password attempt for 'root' from 192.0.2.50:41234" \
	"Oct  5 10:00:01 host dropbear[9]: Bad password attempt for 'root' from 192.0.2.50:41235" \
	"Oct  5 10:00:02 host dropbear[9]: Login attempt for nonexistent user from 192.0.2.50:41236" >"$L/log/auth.log"
expect "logins: falls back to auth.log" 2 "Source: +$L/log/auth.log" lg2
expect "logins: Dropbear failures and sources" 2 '3 +192.0.2.50' lg2
expect "logins: bad --warn" 3 'whole numbers' lg2 --warn x
rm -f "$tmp/bin/journalctl" "$tmp/bin/sshd"

[ "$fails" -eq 0 ] || {
	printf '%d failure(s)\n' "$fails"
	exit 1
}
