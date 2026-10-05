#!/bin/sh
#
# NAME - one line on what this check looks at.
#
# Copy to checks/NAME.sh, fill in TK_NAME/TK_DESC, and replace the body.
# Read docs/CONVENTIONS.md first. Checks only ever read; they never change
# the system.

TK_NAME=example
TK_DESC='Describe in one line what this check shows'
# Extra options, shown in --help above the common ones. Leave empty if none.
TK_OPTIONS='      --limit N     Show at most N entries (default 10)'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

limit=10
while [ $# -gt 0 ]; do
	case $1 in
	--limit)
		tk_need_arg "$@"
		limit=$2
		shift
		;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done
tk_is_number "$limit" || tk_usage_error "--limit needs a number"

tk_start

tk_section "Example"
tk_kv "Kernel" "$(uname -r)"
tk_kvn "Limit" "$limit"
tk_kvb "Running as root" tk_is_root

if tk_need_cmd uptime procps; then
	tk_ok "uptime is available"
fi

tk_finish
