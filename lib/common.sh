# shellcheck shell=sh
# shellcheck disable=SC2034 # TK_* variables are outputs read by check scripts
#
# lib/common.sh - shared helpers for every Linux-Toolkit script.
#
# Source it from a check script (see templates/check.sh and
# docs/CONVENTIONS.md). Everything here is plain POSIX sh: no bashisms,
# no `local`, no GNU-only flags. Internal names start with _tk / _TK so
# they never collide with a script's own variables.

[ -n "${_TK_COMMON_LOADED:-}" ] && return 0
_TK_COMMON_LOADED=1

TK_VERSION=0.1.0

# Exit codes. Nagios-style, so any check can feed a monitoring system.
TK_EXIT_OK=0
TK_EXIT_WARN=1
TK_EXIT_CRIT=2
TK_EXIT_UNKNOWN=3

# Settings. Each can come from the environment or a common option.
TK_NAME=${TK_NAME:-${0##*/}}
TK_DESC=${TK_DESC:-}
TK_OPTIONS=${TK_OPTIONS:-}
TK_HELP_EXTRA=${TK_HELP_EXTRA:-}
TK_JSON=${TK_JSON:-0}
TK_QUIET=${TK_QUIET:-0}
TK_VERBOSE=${TK_VERBOSE:-0}
TK_COLOR=${TK_COLOR:-auto}    # auto | always | never
# Where to read kernel state from. Only tests change these, to point checks
# at fixture files.
TK_PROC=${TK_PROC:-/proc}
TK_SYS=${TK_SYS:-/sys}
TK_ETC=${TK_ETC:-/etc}
TK_LOGDIR=${TK_LOGDIR:-/var/log}

# Result state.
_TK_STATUS=0
_TK_N_OK=0
_TK_N_WARN=0
_TK_N_CRIT=0
_TK_N_INFO=0
_TK_N_SKIP=0
_TK_SECTION=
_TK_J_DATA=
_TK_J_SEC=
_TK_J_CHECKS=
_TK_STARTED=0
_TK_FIRST_NOTE=

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

# tk_has CMD: true if CMD is on PATH (or a builtin).
tk_has() {
	command -v "$1" >/dev/null 2>&1
}

# tk_is_root: true when running as uid 0.
tk_is_root() {
	[ "$(id -u 2>/dev/null)" = 0 ]
}

# tk_timeout SECONDS CMD [ARGS...]: run CMD, killing it after SECONDS when
# a `timeout` command exists. Use it for anything that can hang (DNS,
# network, NFS-backed paths).
tk_timeout() {
	_tk_secs=$1
	shift
	if tk_has timeout; then
		timeout "$_tk_secs" "$@"
	else
		"$@"
	fi
}

# tk_slug TEXT: "Total memory (MiB)" -> "total_memory_mib". Used for JSON keys.
tk_slug() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '_' |
		sed 's/^_//; s/_$//'
}

# tk_json_str TEXT: TEXT as a quoted, escaped JSON string.
tk_json_str() {
	case $1 in
	*[!A-Za-z0-9\ ._:/@+=,%-]*)
		printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037' | awk '
			BEGIN { ORS = ""; printf "\"" }
			{
				if (NR > 1) printf "\\n"
				gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
				print
			}
			END { printf "\"" }'
		;;
	*) printf '"%s"' "$1" ;;
	esac
}

# tk_is_number TEXT: true if TEXT is a valid JSON number (e.g. 42, -1.5).
tk_is_number() {
	printf '%s' "$1" | grep -Eq '^-?(0|[1-9][0-9]*)(\.[0-9]+)?$'
}

# tk_is_uint TEXT: true if TEXT is a whole number >= 0 (for option values).
tk_is_uint() {
	case $1 in
	'' | *[!0-9]*) return 1 ;;
	esac
	return 0
}

# tk_pct PART TOTAL: PART as a rounded whole percent of TOTAL (0 if TOTAL
# is 0 or empty). Works with numbers too big for shell arithmetic.
tk_pct() {
	awk -v p="${1:-0}" -v t="${2:-0}" 'BEGIN { if (t + 0 > 0) printf "%d\n", p * 100 / t + 0.5; else print 0 }'
}

# tk_ge A B: true if number A >= number B. Decimals allowed (load averages).
tk_ge() {
	awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# tk_duration SECONDS: 273600 -> "3d 4h 0m".
tk_duration() {
	awk -v s="${1:-0}" 'BEGIN {
		s = int(s); d = int(s / 86400); h = int(s % 86400 / 3600); m = int(s % 3600 / 60)
		if (d > 0) printf "%dd %dh %dm\n", d, h, m
		else if (h > 0) printf "%dh %dm\n", h, m
		else printf "%dm\n", m
	}'
}

# tk_human_bytes BYTES: 1536 -> "1.5 KiB".
tk_human_bytes() {
	awk -v b="$1" 'BEGIN {
		split("B KiB MiB GiB TiB PiB", u, " "); i = 1
		while (b >= 1024 && i < 6) { b /= 1024; i++ }
		if (i == 1) printf "%d %s\n", b, u[i]; else printf "%.1f %s\n", b, u[i]
	}'
}

# tk_net_awk: awk functions for the hex addresses in /proc/net files. Put
# the output in front of an awk program:
#   awk "$(tk_net_awk)"' { print ip4($2) }' "$TK_PROC/net/route"
# hexval(H) is a hex number; ip4(H) an IPv4 address in host byte order (as
# in route and tcp); ip6(H) an IPv6 address in network order (ipv6_route,
# if_inet6); ip6w(H) one printed as four host-order words (tcp6, udp6).
tk_net_awk() {
	case $(uname -m 2>/dev/null) in
	s390* | ppc | ppc64 | mips | mips64 | sparc* | m68k) _tk_le=0 ;;
	*) _tk_le=1 ;;
	esac
	printf 'BEGIN { _tk_le = %s }\n' "$_tk_le"
	cat <<'AWK'
function hexval(h,   i, n) {
	n = 0; h = toupper(h)
	for (i = 1; i <= length(h); i++) n = n * 16 + index("0123456789ABCDEF", substr(h, i, 1)) - 1
	return n
}
function _tk_swap(w) { return substr(w, 7, 2) substr(w, 5, 2) substr(w, 3, 2) substr(w, 1, 2) }
function _tk_dot(h) {
	return hexval(substr(h, 1, 2)) "." hexval(substr(h, 3, 2)) "." hexval(substr(h, 5, 2)) "." hexval(substr(h, 7, 2))
}
function ip4(h) { return _tk_dot(_tk_le ? _tk_swap(h) : h) }
function ip6(h,   i, g, out, best, blen, run, rstart) {
	h = toupper(h)
	if (substr(h, 1, 24) == "00000000000000000000FFFF") return "::ffff:" _tk_dot(substr(h, 25, 8))
	best = 0; blen = 0; run = 0
	for (i = 1; i <= 8; i++) {
		g[i] = tolower(substr(h, i * 4 - 3, 4)); sub(/^0+/, "", g[i]); if (g[i] == "") g[i] = "0"
		if (g[i] == "0") { if (run == 0) rstart = i; run++; if (run > blen) { blen = run; best = rstart } } else run = 0
	}
	out = ""
	for (i = 1; i <= 8; i++) {
		if (blen > 1 && i == best) { out = out "::"; i += blen - 1; continue }
		out = out ((out == "" || out ~ /:$/) ? "" : ":") g[i]
	}
	return out
}
function ip6w(h,   i, s) {
	if (!_tk_le) return ip6(h)
	s = ""
	for (i = 0; i < 4; i++) s = s _tk_swap(substr(h, i * 8 + 1, 8))
	return ip6(s)
}
AWK
}

# ---------------------------------------------------------------------------
# Colors and logging
# ---------------------------------------------------------------------------

_tk_init_colors() {
	_tk_c=0
	case $TK_COLOR in
	always) _tk_c=1 ;;
	never) ;;
	*)
		if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ] && [ -t 1 ]; then
			_tk_c=1
		fi
		;;
	esac
	[ "$TK_JSON" = 1 ] && _tk_c=0
	if [ "$_tk_c" = 1 ]; then
		_tk_esc=$(printf '\033')
		TK_C_RESET="${_tk_esc}[0m"
		TK_C_BOLD="${_tk_esc}[1m"
		TK_C_DIM="${_tk_esc}[2m"
		TK_C_RED="${_tk_esc}[31m"
		TK_C_GREEN="${_tk_esc}[32m"
		TK_C_YELLOW="${_tk_esc}[33m"
		TK_C_BLUE="${_tk_esc}[34m"
		TK_C_CYAN="${_tk_esc}[36m"
	else
		TK_C_RESET='' TK_C_BOLD='' TK_C_DIM='' TK_C_RED='' TK_C_GREEN=''
		TK_C_YELLOW='' TK_C_BLUE='' TK_C_CYAN=''
	fi
}
_tk_init_colors

# tk_err MSG: print an error to stderr.
tk_err() {
	printf '%s: %s\n' "$TK_NAME" "$*" >&2
}

# tk_debug MSG: print to stderr only with --verbose.
tk_debug() {
	[ "$TK_VERBOSE" = 1 ] && printf '%sdebug:%s %s\n' "$TK_C_DIM" "$TK_C_RESET" "$*" >&2
	return 0
}

# tk_die MSG: the script cannot do its job. Exits 3 (UNKNOWN). In --json
# mode stdout still gets a valid JSON object describing the error.
tk_die() {
	tk_err "$*"
	if [ "$TK_JSON" = 1 ]; then
		printf '{"tool":%s,"version":%s,"status":"unknown","error":%s}\n' \
			"$(tk_json_str "$TK_NAME")" "$(tk_json_str "$TK_VERSION")" "$(tk_json_str "$*")"
	fi
	exit "$TK_EXIT_UNKNOWN"
}

# ---------------------------------------------------------------------------
# Options and help
# ---------------------------------------------------------------------------

# tk_usage: print help built from TK_NAME, TK_DESC, TK_OPTIONS, TK_HELP_EXTRA.
tk_usage() {
	printf '%s - %s\n\n' "$TK_NAME" "$TK_DESC"
	printf 'Usage: toolkit %s [options]\n' "$TK_NAME"
	printf '       sh checks/%s.sh [options]\n\n' "$TK_NAME"
	printf 'Options:\n'
	[ -n "$TK_OPTIONS" ] && printf '%s\n' "$TK_OPTIONS"
	cat <<'EOF'
  -j, --json        Print results as one JSON object (for scripts and tools)
  -q, --quiet       Only print warnings, problems and a one-line verdict
  -v, --verbose     Print extra debug detail to stderr
      --no-color    Disable colors (NO_COLOR=1 works too)
      --color       Force colors even when not writing to a terminal
  -V, --version     Print the version and exit
  -h, --help        Show this help and exit
EOF
	[ -n "$TK_HELP_EXTRA" ] && printf '\n%s\n' "$TK_HELP_EXTRA"
	printf '\nExit status: 0 OK, 1 warning, 2 critical, 3 unknown or usage error.\n'
}

# tk_usage_error MSG: bad command line. Exits 3.
tk_usage_error() {
	tk_err "$*"
	printf "Try 'toolkit %s --help'.\n" "$TK_NAME" >&2
	exit "$TK_EXIT_UNKNOWN"
}

# tk_need_arg "$@": for options that take a value. Call it before reading $2:
#   --count) tk_need_arg "$@"; count=$2; shift ;;
tk_need_arg() {
	[ $# -ge 2 ] || tk_usage_error "option $1 needs a value"
}

# tk_common_opt ARG: handle the options every script shares. Returns 1 for
# anything it does not know, so the script can report it.
tk_common_opt() {
	case $1 in
	-h | --help)
		tk_usage
		exit 0
		;;
	-V | --version)
		printf '%s %s (linux-toolkit)\n' "$TK_NAME" "$TK_VERSION"
		exit 0
		;;
	-j | --json) TK_JSON=1 ;;
	-q | --quiet) TK_QUIET=1 ;;
	-v | --verbose) TK_VERBOSE=1 ;;
	--no-color | --no-colour) TK_COLOR=never ;;
	--color | --colour) TK_COLOR=always ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Output: header, sections, key/values, check results, summary
# ---------------------------------------------------------------------------

# tk_start: call once after option parsing, before any output.
tk_start() {
	_tk_init_colors
	_TK_STARTED=1
	TK_HOST=$(uname -n 2>/dev/null)
	TK_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
	if [ "$TK_JSON" != 1 ] && [ "$TK_QUIET" != 1 ]; then
		printf '%s== %s ==%s %s%s, %s%s\n' "$TK_C_BOLD$TK_C_CYAN" "$TK_NAME" "$TK_C_RESET" \
			"$TK_C_DIM" "$TK_HOST" "$TK_TIMESTAMP" "$TK_C_RESET"
		[ -n "$TK_DESC" ] && printf '%s%s%s\n' "$TK_C_DIM" "$TK_DESC" "$TK_C_RESET"
	fi
	return 0
}

_tk_json_member() {
	if [ -n "$_TK_SECTION" ]; then
		_TK_J_SEC="${_TK_J_SEC:+$_TK_J_SEC,}$1"
	else
		_TK_J_DATA="${_TK_J_DATA:+$_TK_J_DATA,}$1"
	fi
}

_tk_flush_section() {
	[ -n "$_TK_SECTION" ] || return 0
	_TK_J_DATA="${_TK_J_DATA:+$_TK_J_DATA,}\"$_TK_SECTION\":{$_TK_J_SEC}"
	_TK_SECTION=
	_TK_J_SEC=
}

# tk_section TITLE: start a group of related output. In JSON, the
# key/values that follow are nested under the slug of TITLE.
tk_section() {
	_tk_flush_section
	_TK_SECTION=$(tk_slug "$1")
	if [ "$TK_JSON" != 1 ] && [ "$TK_QUIET" != 1 ]; then
		printf '\n%s%s%s\n' "$TK_C_BOLD" "$1" "$TK_C_RESET"
	fi
	return 0
}

_tk_print_kv() {
	if [ "$TK_JSON" != 1 ] && [ "$TK_QUIET" != 1 ]; then
		printf '  %-24s %s\n' "$1:" "${2:--}"
	fi
	return 0
}

# tk_kv LABEL VALUE: a fact, e.g. tk_kv "Kernel" "$(uname -r)".
# JSON: a string, or null when VALUE is empty.
tk_kv() {
	_tk_print_kv "$1" "${2:-}"
	if [ "$TK_JSON" = 1 ]; then
		if [ -n "${2:-}" ]; then
			_tk_json_member "\"$(tk_slug "$1")\":$(tk_json_str "$2")"
		else
			_tk_json_member "\"$(tk_slug "$1")\":null"
		fi
	fi
	return 0
}

# tk_kvn LABEL NUMBER [DISPLAY]: a numeric fact. JSON gets the bare number
# (null if not numeric); the human view shows DISPLAY when given. DISPLAY
# carries its own unit, so a unit at the end of LABEL ("bytes", "seconds",
# "ms", "celsius") is left out of the human view: "Total: 15.7 GiB".
#   tk_kvn "Memory total bytes" "$bytes" "$(tk_human_bytes "$bytes")"
tk_kvn() {
	_tk_l=$1
	if [ -n "${3:-}" ]; then
		case $_tk_l in
		?*' bytes') _tk_l=${_tk_l% bytes} ;;
		?*' seconds') _tk_l=${_tk_l% seconds} ;;
		?*' ms') _tk_l=${_tk_l% ms} ;;
		?*' celsius') _tk_l=${_tk_l% celsius} ;;
		esac
	fi
	_tk_print_kv "$_tk_l" "${3:-${2:-}}"
	if [ "$TK_JSON" = 1 ]; then
		if tk_is_number "${2:-}"; then
			_tk_json_member "\"$(tk_slug "$1")\":$2"
		else
			_tk_json_member "\"$(tk_slug "$1")\":null"
		fi
	fi
	return 0
}

# tk_kvb LABEL CONDITION...: a yes/no fact. Runs CONDITION; JSON gets
# true/false, humans get yes/no.  tk_kvb "Running as root" tk_is_root
tk_kvb() {
	_tk_label=$1
	shift
	if "$@"; then _tk_b=true _tk_y=yes; else _tk_b=false _tk_y=no; fi
	_tk_print_kv "$_tk_label" "$_tk_y"
	[ "$TK_JSON" = 1 ] && _tk_json_member "\"$(tk_slug "$_tk_label")\":$_tk_b"
	return 0
}

# tk_kvj LABEL JSON: raw JSON (an array or object you built) under LABEL in
# the data object. Nothing is printed for humans; pair it with tk_print.
#   tk_kvj "Processes" "[$items]"
tk_kvj() {
	[ "$TK_JSON" = 1 ] && _tk_json_member "\"$(tk_slug "$1")\":$2"
	return 0
}

# tk_print FORMAT [ARGS...]: printf for the human view only (tables, lists).
# Prints nothing with --json or --quiet.
tk_print() {
	if [ "$TK_JSON" = 1 ] || [ "$TK_QUIET" = 1 ]; then return 0; fi
	_tk_fmt=$1
	shift
	# shellcheck disable=SC2059 # the format is the caller's
	printf "$_tk_fmt" "$@"
}

_tk_check() {
	# $1 status, $2 tag, $3 color, $4 message
	if [ "$TK_JSON" = 1 ]; then
		if [ -n "$_TK_SECTION" ]; then _tk_s="\"$_TK_SECTION\""; else _tk_s=null; fi
		_TK_J_CHECKS="${_TK_J_CHECKS:+$_TK_J_CHECKS,}{\"section\":$_tk_s,\"status\":\"$1\",\"message\":$(tk_json_str "$4")}"
	elif [ "$TK_QUIET" = 1 ]; then
		case $1 in
		warn | crit)
			# Messages stand on their own (see CONVENTIONS.md), so no
			# section label: this is also what the toolkit summary shows.
			printf '%s%s%s %s\n' "$3" "$2" "$TK_C_RESET" "$4"
			;;
		esac
	else
		printf '  %s%s%s %s\n' "$3" "$2" "$TK_C_RESET" "$4"
	fi
	return 0
}

# Check results. Each takes one message. ok/warn/crit count towards the
# exit status; info and skip are informational.
tk_ok() {
	_TK_N_OK=$((_TK_N_OK + 1))
	_tk_check ok '[ OK ]' "$TK_C_GREEN" "$*"
}

tk_warn() {
	_TK_N_WARN=$((_TK_N_WARN + 1))
	[ "$_TK_STATUS" -lt "$TK_EXIT_WARN" ] && _TK_STATUS=$TK_EXIT_WARN
	_tk_check warn '[WARN]' "$TK_C_YELLOW" "$*"
}

tk_crit() {
	_TK_N_CRIT=$((_TK_N_CRIT + 1))
	_TK_STATUS=$TK_EXIT_CRIT
	_tk_check crit '[CRIT]' "$TK_C_RED$TK_C_BOLD" "$*"
}

tk_info() {
	_TK_N_INFO=$((_TK_N_INFO + 1))
	[ -n "$_TK_FIRST_NOTE" ] || _TK_FIRST_NOTE="$*"
	_tk_check info '[INFO]' "$TK_C_BLUE" "$*"
}

# tk_skip MSG: a check that could not run here (missing tool, not root...).
tk_skip() {
	_TK_N_SKIP=$((_TK_N_SKIP + 1))
	# A skip explains an empty result better than an info line does.
	[ "$_TK_N_SKIP" = 1 ] && _TK_FIRST_NOTE="$*"
	_tk_check skip '[SKIP]' "$TK_C_DIM" "$*"
}

_tk_status_word() {
	case $_TK_STATUS in
	0) printf ok ;;
	1) printf warn ;;
	*) printf crit ;;
	esac
}

# tk_finish: print the summary (or the JSON object) and exit with the
# worst status seen. Always the last call in a script.
tk_finish() {
	_tk_flush_section
	if [ "$TK_JSON" = 1 ]; then
		printf '{"tool":%s,"version":%s,"host":%s,"timestamp":%s,"status":"%s",' \
			"$(tk_json_str "$TK_NAME")" "$(tk_json_str "$TK_VERSION")" \
			"$(tk_json_str "${TK_HOST:-}")" "$(tk_json_str "${TK_TIMESTAMP:-}")" \
			"$(_tk_status_word)"
		printf '"summary":{"ok":%d,"warn":%d,"crit":%d,"info":%d,"skip":%d},' \
			"$_TK_N_OK" "$_TK_N_WARN" "$_TK_N_CRIT" "$_TK_N_INFO" "$_TK_N_SKIP"
		printf '"data":{%s},"checks":[%s]}\n' "$_TK_J_DATA" "$_TK_J_CHECKS"
		exit "$_TK_STATUS"
	fi

	case $_TK_STATUS in
	0) _tk_word=OK _tk_col=$TK_C_GREEN ;;
	1) _tk_word=WARNING _tk_col=$TK_C_YELLOW ;;
	*) _tk_word=CRITICAL _tk_col=$TK_C_RED ;;
	esac
	# "1 critical, 2 warnings, 5 passed, 1 skipped", leaving out zeros. With
	# nothing passed or failed, say so, and why (the first skip or info).
	_tk_counts=
	[ "$_TK_N_CRIT" -gt 0 ] && _tk_counts="$_TK_N_CRIT critical"
	[ "$_TK_N_WARN" = 1 ] && _tk_counts="${_tk_counts:+$_tk_counts, }1 warning"
	[ "$_TK_N_WARN" -gt 1 ] && _tk_counts="${_tk_counts:+$_tk_counts, }$_TK_N_WARN warnings"
	[ "$_TK_N_OK" -gt 0 ] && _tk_counts="${_tk_counts:+$_tk_counts, }$_TK_N_OK passed"
	if [ -z "$_tk_counts" ]; then
		_tk_counts="nothing to check here"
		[ "$TK_QUIET" = 1 ] && [ -n "$_TK_FIRST_NOTE" ] && _tk_counts="$_tk_counts: $_TK_FIRST_NOTE"
	elif [ "$_TK_N_SKIP" -gt 0 ]; then
		_tk_counts="$_tk_counts, $_TK_N_SKIP skipped"
	fi
	if [ "$TK_QUIET" = 1 ]; then
		printf '%s: %s%s%s - %s\n' "$TK_NAME" "$_tk_col" "$_tk_word" "$TK_C_RESET" "$_tk_counts"
	else
		printf '\n%sResult: %s%s - %s\n' "$_tk_col$TK_C_BOLD" "$_tk_word" "$TK_C_RESET" "$_tk_counts"
	fi
	exit "$_TK_STATUS"
}

# ---------------------------------------------------------------------------
# Privileges
# ---------------------------------------------------------------------------

# tk_require_root: stop (exit 3) unless running as root.
tk_require_root() {
	tk_is_root || tk_die "this check must run as root (try: sudo toolkit $TK_NAME)"
}

# tk_want_root [WHAT]: note, once, that output is limited without root.
tk_want_root() {
	tk_is_root && return 0
	[ -n "${_TK_WANT_ROOT_SAID:-}" ] && return 1
	_TK_WANT_ROOT_SAID=1
	tk_info "Not running as root${1:+, so $1}. Re-run with sudo for full detail."
	return 1
}

# ---------------------------------------------------------------------------
# Platform detection. Each function sets TK_* variables once and caches.
# ---------------------------------------------------------------------------

# Read KEY from an os-release style file, without sourcing it.
_tk_osr() {
	sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1 | sed "s/^[\"']//; s/[\"']\$//"
}

# tk_detect_os: sets TK_OS_ID (e.g. ubuntu), TK_OS_NAME (pretty name),
# TK_OS_VERSION, TK_OS_LIKE, and TK_OS_FAMILY, one of:
# debian redhat suse arch alpine gentoo void nixos slackware unknown.
tk_detect_os() {
	[ -n "${_TK_OS_DONE:-}" ] && return 0
	_TK_OS_DONE=1
	TK_OS_ID='' TK_OS_NAME='' TK_OS_VERSION='' TK_OS_LIKE=''
	for _tk_f in /etc/os-release /usr/lib/os-release; do
		[ -r "$_tk_f" ] || continue
		TK_OS_ID=$(_tk_osr ID "$_tk_f")
		TK_OS_NAME=$(_tk_osr PRETTY_NAME "$_tk_f")
		[ -n "$TK_OS_NAME" ] || TK_OS_NAME=$(_tk_osr NAME "$_tk_f")
		TK_OS_VERSION=$(_tk_osr VERSION_ID "$_tk_f")
		TK_OS_LIKE=$(_tk_osr ID_LIKE "$_tk_f")
		break
	done

	# Older systems without os-release.
	if [ -z "$TK_OS_ID" ]; then
		if [ -r /etc/alpine-release ]; then
			TK_OS_ID=alpine TK_OS_VERSION=$(head -n 1 /etc/alpine-release)
		elif [ -r /etc/redhat-release ]; then
			TK_OS_NAME=$(head -n 1 /etc/redhat-release)
			TK_OS_VERSION=$(printf '%s' "$TK_OS_NAME" | sed -n 's/.*release \([0-9.]*\).*/\1/p')
			case $TK_OS_NAME in
			CentOS*) TK_OS_ID=centos ;;
			Fedora*) TK_OS_ID=fedora ;;
			*) TK_OS_ID=rhel ;;
			esac
		elif [ -r /etc/debian_version ]; then
			TK_OS_ID=debian TK_OS_VERSION=$(head -n 1 /etc/debian_version)
		elif [ -e /etc/arch-release ]; then
			TK_OS_ID=arch
		elif [ -r /etc/gentoo-release ]; then
			TK_OS_ID=gentoo TK_OS_NAME=$(head -n 1 /etc/gentoo-release)
		elif [ -r /etc/SuSE-release ]; then
			TK_OS_ID=suse TK_OS_NAME=$(head -n 1 /etc/SuSE-release)
		elif [ -r /etc/slackware-version ]; then
			TK_OS_ID=slackware TK_OS_NAME=$(head -n 1 /etc/slackware-version)
		else
			TK_OS_ID=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
		fi
	fi
	[ -n "$TK_OS_NAME" ] || TK_OS_NAME="$TK_OS_ID${TK_OS_VERSION:+ $TK_OS_VERSION}"

	case " $TK_OS_ID $TK_OS_LIKE " in
	*" debian "* | *" ubuntu "*) TK_OS_FAMILY=debian ;;
	*" rhel "* | *" fedora "* | *" centos "* | *" rocky "* | *" almalinux "* | *" amzn "* | *" ol "*)
		TK_OS_FAMILY=redhat ;;
	*suse*) TK_OS_FAMILY=suse ;;
	*" arch "* | *" archarm "* | *" manjaro "* | *" endeavouros "*) TK_OS_FAMILY=arch ;;
	*" alpine "*) TK_OS_FAMILY=alpine ;;
	*" gentoo "*) TK_OS_FAMILY=gentoo ;;
	*" void "*) TK_OS_FAMILY=void ;;
	*" nixos "*) TK_OS_FAMILY=nixos ;;
	*" slackware "*) TK_OS_FAMILY=slackware ;;
	*) TK_OS_FAMILY=unknown ;;
	esac
}

# tk_detect_pkg: sets TK_PKG to the package manager in use:
# apt dnf yum zypper pacman apk emerge xbps nix slackpkg, or empty.
tk_detect_pkg() {
	[ -n "${_TK_PKG_DONE:-}" ] && return 0
	_TK_PKG_DONE=1
	TK_PKG=
	for _tk_p in apt-get:apt dnf:dnf yum:yum zypper:zypper pacman:pacman apk:apk \
		emerge:emerge xbps-install:xbps nix-env:nix slackpkg:slackpkg; do
		if tk_has "${_tk_p%%:*}"; then
			TK_PKG=${_tk_p#*:}
			return 0
		fi
	done
}

# tk_install_hint PACKAGE: prints e.g. "apt-get install -y iproute2" for
# this system's package manager (package names can differ per distro).
tk_install_hint() {
	tk_detect_pkg
	case $TK_PKG in
	apt) printf 'apt-get install -y %s' "$1" ;;
	dnf) printf 'dnf install -y %s' "$1" ;;
	yum) printf 'yum install -y %s' "$1" ;;
	zypper) printf 'zypper install -y %s' "$1" ;;
	pacman) printf 'pacman -S --noconfirm %s' "$1" ;;
	apk) printf 'apk add %s' "$1" ;;
	emerge) printf 'emerge %s' "$1" ;;
	xbps) printf 'xbps-install -y %s' "$1" ;;
	nix) printf 'nix-env -i %s' "$1" ;;
	*) printf 'install %s with your package manager' "$1" ;;
	esac
}

# tk_need_cmd CMD [PACKAGE]: true if CMD exists; otherwise records a skip
# with an install hint and returns 1.
#   tk_need_cmd ss iproute2 && ss -tlnp
tk_need_cmd() {
	tk_has "$1" && return 0
	tk_skip "$1 not found (install: $(tk_install_hint "${2:-$1}"))"
	return 1
}

# tk_detect_init: sets TK_INIT to what is actually managing services:
# systemd openrc runit s6 upstart sysv none, and TK_INIT_PID1 to the
# name of process 1.
tk_detect_init() {
	[ -n "${_TK_INIT_DONE:-}" ] && return 0
	_TK_INIT_DONE=1
	TK_INIT_PID1=$(cat /proc/1/comm 2>/dev/null)
	[ -n "$TK_INIT_PID1" ] || TK_INIT_PID1=$(ps -p 1 -o comm= 2>/dev/null)
	if [ -d /run/systemd/system ]; then
		TK_INIT=systemd
	elif [ -d /run/openrc ] || [ -f /run/openrc/softlevel ]; then
		TK_INIT=openrc
	elif [ -d /run/runit ] || [ "$TK_INIT_PID1" = runit ] || [ "$TK_INIT_PID1" = runit-init ]; then
		TK_INIT=runit
	elif [ "$TK_INIT_PID1" = s6-svscan ]; then
		TK_INIT=s6
	elif tk_has initctl && initctl version 2>/dev/null | grep -q upstart; then
		TK_INIT=upstart
	elif [ "$TK_INIT_PID1" = init ] && [ -d /etc/init.d ]; then
		TK_INIT=sysv
	else
		TK_INIT=none
	fi
}

# tk_detect_virt: sets TK_CONTAINER (docker podman lxc kubernetes wsl ...,
# empty if none) and TK_VIRT (kvm vmware ... , empty for bare metal or
# unknown).
tk_detect_virt() {
	[ -n "${_TK_VIRT_DONE:-}" ] && return 0
	_TK_VIRT_DONE=1
	TK_CONTAINER='' TK_VIRT=''
	if tk_has systemd-detect-virt; then
		TK_CONTAINER=$(systemd-detect-virt -c 2>/dev/null)
		TK_VIRT=$(systemd-detect-virt -v 2>/dev/null)
		[ "$TK_CONTAINER" = none ] && TK_CONTAINER=
		[ "$TK_VIRT" = none ] && TK_VIRT=
	fi

	if [ -z "$TK_CONTAINER" ]; then
		if [ -f /.dockerenv ]; then
			TK_CONTAINER=docker
		elif [ -f /run/.containerenv ]; then
			TK_CONTAINER=podman
		elif [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
			TK_CONTAINER=kubernetes
		elif [ -n "${container:-}" ]; then
			TK_CONTAINER=$container
		elif grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
			TK_CONTAINER=wsl
		elif [ -r /proc/1/cgroup ]; then
			case $(cat /proc/1/cgroup 2>/dev/null) in
			*kubepods*) TK_CONTAINER=kubernetes ;;
			*docker*) TK_CONTAINER=docker ;;
			*lxc*) TK_CONTAINER=lxc ;;
			*containerd*) TK_CONTAINER=containerd ;;
			esac
		fi
	fi

	if [ -z "$TK_VIRT" ]; then
		_tk_dmi="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null)"
		case $_tk_dmi in
		*QEMU* | *KVM*) TK_VIRT=kvm ;;
		*VMware*) TK_VIRT=vmware ;;
		*VirtualBox* | *innotek*) TK_VIRT=oracle ;;
		*Xen*) TK_VIRT=xen ;;
		*"Microsoft Corporation"*) TK_VIRT=microsoft ;;
		*"Amazon EC2"*) TK_VIRT=amazon ;;
		*Google*) TK_VIRT=google ;;
		*)
			if grep -q '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then
				TK_VIRT=vm
			fi
			;;
		esac
	fi
}
