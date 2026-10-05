#!/bin/sh
#
# disk - space and inodes on every real filesystem, read-only mounts,
# and I/O pressure. Pseudo filesystems (proc, sysfs, snaps...) are skipped.

TK_NAME=disk
TK_DESC='Show disk space and inode use per filesystem, read-only mounts and I/O pressure'
TK_OPTIONS='      --warn N       Warn when a filesystem is at least N% full (default 85)
      --crit N       Critical when a filesystem is at least N% full (default 95)
      --inode-warn N Warn when inode use is at least N% (default 85)
      --inode-crit N Critical when inode use is at least N% (default 95)'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

warn=85
crit=95
iwarn=85
icrit=95
while [ $# -gt 0 ]; do
	case $1 in
	--warn) tk_need_arg "$@"; warn=$2; shift ;;
	--crit) tk_need_arg "$@"; crit=$2; shift ;;
	--inode-warn) tk_need_arg "$@"; iwarn=$2; shift ;;
	--inode-crit) tk_need_arg "$@"; icrit=$2; shift ;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done
for v in "$warn" "$crit" "$iwarn" "$icrit"; do
	tk_is_uint "$v" || tk_usage_error "thresholds must be whole numbers (got '$v')"
done
if [ "$warn" -gt "$crit" ] || [ "$iwarn" -gt "$icrit" ]; then
	tk_usage_error "warning thresholds must not be above critical ones"
fi

# Filesystem types that never hold user data, or are always full (squashfs).
pseudo=' proc sysfs devtmpfs devpts cgroup cgroup2 securityfs pstore bpf tracefs debugfs
 configfs fusectl mqueue hugetlbfs autofs binfmt_misc squashfs iso9660 nsfs efivarfs
 rpc_pipefs selinuxfs ramfs overlayfs_internal nfsd fuse.lxcfs fuse.gvfsd-fuse '

tk_start
tk_detect_virt

# One df call for space, one for inodes, each with a timeout so a dead
# network mount cannot hang the check. Mount points are the last field(s).
space=$(tk_timeout 15 df -Pk 2>/dev/null)
rc=$?
if [ "$rc" = 124 ]; then
	tk_warn "df timed out; a network filesystem (NFS, CIFS) is probably not responding"
fi
[ -n "$space" ] || tk_die "df failed (exit $rc)"
inodes=$(tk_timeout 15 df -Pi 2>/dev/null)

# Join df space + inodes + /proc/mounts into:
#   mount|device|fstype|size|used|avail|pct|ipct|ro
# Sizes are bytes; ipct is empty where the filesystem has no inode limit.
rows=$({
	printf '%s\n' "$space" | sed '1d; s/^/S /'
	printf '%s\n' "$inodes" | sed '1d; s/^/I /'
	sed 's/^/M /' "$TK_PROC/mounts" 2>/dev/null
} | awk -v pseudo="$pseudo" '
	function mnt(   m, i) { m = $7; for (i = 8; i <= NF; i++) m = m " " $i; return m }
	function unoct(s) {
		gsub(/\\040/, " ", s); gsub(/\\011/, "\t", s); gsub(/\\134/, "\\", s); return s
	}
	$1 == "M" {
		m = unoct($3); type[m] = $4
		ro[m] = ("," $5 ",") ~ /,ro,/ ? 1 : 0
		next
	}
	$1 == "S" && NF >= 7 { m = mnt(); if (!(m in seen)) order[++n] = m; seen[m] = 1
		dev[m] = $2; size[m] = $3 * 1024; used[m] = $4 * 1024; avail[m] = $5 * 1024; next }
	$1 == "I" && NF >= 7 { m = mnt(); if ($3 + 0 > 0) ipct[m] = int($4 * 100 / $3 + 0.5); next }
	END {
		for (i = 1; i <= n; i++) {
			m = order[i]; t = (m in type) ? type[m] : "unknown"
			if (index(pseudo, " " t " ") || size[m] == 0) continue
			if (m ~ /^\/(proc|sys)(\/|$)/) continue
			# Same calculation as df: used / (used + available), rounded up.
			tot = used[m] + avail[m]
			p = tot > 0 ? int(used[m] * 100 / tot) : 0
			if (tot > 0 && used[m] * 100 % tot > 0) p++
			printf "%s|%s|%s|%.0f|%.0f|%.0f|%d|%s|%d\n", m, dev[m], t, size[m], used[m], avail[m], p,
				(m in ipct) ? ipct[m] : "", ro[m] + 0
		}
	}')

tk_section "Filesystems"
# Skip file bind mounts (Docker's /etc/hosts and friends).
real=''
while IFS='|' read -r m rest; do
	[ -n "$m" ] && [ -d "$m" ] && real="$real$m|$rest
"
done <<EOF
$rows
EOF

tk_print '  %-12s %10s %10s %5s %6s  %s\n' TYPE SIZE AVAIL USE% INODE% MOUNT
items=''
count=0
while IFS='|' read -r m dev type size used avail pct ipct ro; do
	[ -n "$m" ] || continue
	count=$((count + 1))
	tk_print '  %-12s %10s %10s %4s%% %6s  %s\n' "$type" "$(tk_human_bytes "$size")" \
		"$(tk_human_bytes "$avail")" "$pct" "${ipct:+$ipct%}" "$m"
	[ "$ro" = 1 ] && ro=true || ro=false
	items="${items:+$items,}{\"mount\":$(tk_json_str "$m"),\"device\":$(tk_json_str "$dev"),\"fstype\":$(tk_json_str "$type"),\"size_bytes\":$size,\"used_bytes\":$used,\"avail_bytes\":$avail,\"used_percent\":$pct,\"inodes_used_percent\":${ipct:-null},\"read_only\":$ro}"
done <<EOF
$real
EOF
tk_kvj "Mounts" "[$items]"
tk_kvn "Count" "$count"

problems=0
while IFS='|' read -r m dev type size used avail pct ipct ro; do
	[ -n "$m" ] || continue
	# A read-only filesystem cannot fill up any further.
	if [ "$ro" = 1 ]; then
		:
	elif [ "$pct" -ge "$crit" ]; then
		tk_crit "$m is $pct% full ($(tk_human_bytes "$avail") left); find what grew with: du -xh $m | sort -h | tail"
		problems=$((problems + 1))
	elif [ "$pct" -ge "$warn" ]; then
		tk_warn "$m is $pct% full ($(tk_human_bytes "$avail") left)"
		problems=$((problems + 1))
	fi
	if [ -n "$ipct" ] && [ "$ro" = 0 ]; then
		if [ "$ipct" -ge "$icrit" ]; then
			tk_crit "$m has used $ipct% of its inodes; look for directories with huge numbers of small files"
			problems=$((problems + 1))
		elif [ "$ipct" -ge "$iwarn" ]; then
			tk_warn "$m has used $ipct% of its inodes"
			problems=$((problems + 1))
		fi
	fi
	# A data filesystem that is read-only usually means the kernel remounted
	# it after an error. Containers often mount things read-only on purpose.
	if [ "$ro" = 1 ]; then
		case $type in
		ext2 | ext3 | ext4 | xfs | btrfs | f2fs | jfs | reiserfs)
			if [ -n "$TK_CONTAINER" ]; then
				tk_info "$m is mounted read-only (normal for some container mounts)"
			else
				tk_warn "$m ($type) is mounted read-only; check toolkit logs for filesystem errors"
				problems=$((problems + 1))
			fi
			;;
		esac
	fi
done <<EOF
$real
EOF
if [ "$count" = 0 ]; then
	tk_skip "No filesystems found in df output"
elif [ "$problems" = 0 ]; then
	tk_ok "All $count filesystem(s) below $warn% space and $iwarn% inodes"
fi
[ -n "$inodes" ] || tk_skip "df -i is not supported here, so inodes were not checked"

if [ -r "$TK_PROC/pressure/io" ]; then
	tk_section "IO pressure"
	psi_some=$(sed -n 's/^some .*avg60=\([0-9.]*\).*/\1/p' "$TK_PROC/pressure/io")
	psi_full=$(sed -n 's/^full .*avg60=\([0-9.]*\).*/\1/p' "$TK_PROC/pressure/io")
	tk_kvn "Some avg60" "$psi_some" "${psi_some:+$psi_some%}"
	tk_kvn "Full avg60" "$psi_full" "${psi_full:+$psi_full%}"
	if [ -n "$psi_full" ] && tk_ge "$psi_full" 20; then
		tk_warn "All tasks were stalled on I/O $psi_full% of the last minute; a disk is too slow or failing"
	elif [ -n "$psi_some" ] && tk_ge "$psi_some" 20; then
		tk_warn "Tasks waited on I/O $psi_some% of the last minute"
	else
		tk_ok "No significant I/O pressure"
	fi
fi

tk_finish
