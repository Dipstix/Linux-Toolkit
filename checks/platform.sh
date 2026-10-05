#!/bin/sh
#
# platform - what is this machine? Distro, kernel, init system, package
# manager, container or VM. Handy as a first step on an unfamiliar server.

TK_NAME=platform
TK_DESC='Show distro, kernel, init system, package manager and virtualization'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

while [ $# -gt 0 ]; do
	tk_common_opt "$1" || tk_usage_error "unknown option: $1"
	shift
done

tk_start
tk_detect_os
tk_detect_pkg
tk_detect_init
tk_detect_virt

tk_section "System"
tk_kv "Hostname" "$(uname -n 2>/dev/null)"
tk_kv "OS" "$TK_OS_NAME"
tk_kv "OS ID" "$TK_OS_ID"
tk_kv "OS version" "$TK_OS_VERSION"
tk_kv "OS family" "$TK_OS_FAMILY"
tk_kv "Kernel" "$(uname -r 2>/dev/null)"
tk_kv "Architecture" "$(uname -m 2>/dev/null)"

tk_section "Environment"
tk_kv "Init system" "$TK_INIT"
tk_kv "PID 1" "$TK_INIT_PID1"
tk_kv "Package manager" "$TK_PKG"
tk_kv "Container" "$TK_CONTAINER"
tk_kv "Virtualization" "$TK_VIRT"
tk_kvb "Running as root" tk_is_root
_sh=$(readlink -f /bin/sh 2>/dev/null || readlink /bin/sh 2>/dev/null)
tk_kv "System sh" "${_sh:-/bin/sh}"

tk_section "Assessment"
if [ "$TK_OS_FAMILY" = unknown ]; then
	tk_warn "Unrecognised distribution ($TK_OS_ID); checks will use generic methods"
else
	tk_ok "Distribution recognised ($TK_OS_FAMILY family)"
fi
if [ -n "$TK_PKG" ]; then
	tk_ok "Package manager found ($TK_PKG)"
else
	tk_info "No known package manager found"
fi
if [ "$TK_INIT" = none ]; then
	tk_info "No service manager detected (PID 1 is ${TK_INIT_PID1:-unknown}), common in containers"
else
	tk_ok "Service manager detected ($TK_INIT)"
fi
tk_want_root "some checks will show limited detail" || :

tk_finish
