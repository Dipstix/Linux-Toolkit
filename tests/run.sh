#!/bin/sh
#
# Smoke tests: runs the library unit tests and every check under each
# POSIX shell found on this machine (dash, bash --posix, busybox sh, mksh,
# yash, sh). Override with TEST_SHELLS="dash;busybox sh".
#
#   sh tests/run.sh

# ok() always succeeds, so `test && ok || bad` is a safe if/else here.
# shellcheck disable=SC2015

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT" || exit 3

pass=0
fail=0
ok() {
	pass=$((pass + 1))
}
bad() {
	fail=$((fail + 1))
	printf '  FAIL [%s] %s\n' "$sh" "$*"
}

# JSON validator, if one is available.
if command -v python3 >/dev/null 2>&1; then
	json_ok() { python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }
elif command -v jq >/dev/null 2>&1; then
	json_ok() { jq -e . >/dev/null 2>&1; }
else
	printf 'note: no python3 or jq, JSON output is not validated\n'
	json_ok() { cat >/dev/null; }
fi

if [ -n "${TEST_SHELLS:-}" ]; then
	shells=$(printf '%s\n' "$TEST_SHELLS" | tr ';' '\n')
else
	shells=
	for s in dash "bash --posix" "busybox sh" mksh yash sh; do
		# shellcheck disable=SC2086 # $s is a command plus flags
		$s -c ':' 2>/dev/null && shells="$shells$s
"
	done
fi

nl='
'
old_ifs=$IFS
IFS=$nl
for sh in $shells; do
	IFS=$old_ifs
	[ -n "$sh" ] || continue
	printf '== %s\n' "$sh"

	# shellcheck disable=SC2086
	if out=$($sh tests/lib_test.sh 2>&1); then ok; else bad "lib_test.sh"; printf '%s\n' "$out" | grep -v '^ok'; fi
	# shellcheck disable=SC2086
	if out=$(TK_SHELL=$sh $sh tests/checks_test.sh 2>&1); then ok; else bad "checks_test.sh"; printf '%s\n' "$out" | grep -v '^ok'; fi

	for f in checks/*.sh templates/check.sh; do
		n=${f##*/}

		# shellcheck disable=SC2086
		out=$($sh "$f" --help 2>&1) && case $out in *Usage:*) ok ;; *) bad "$n --help has no Usage" ;; esac ||
			bad "$n --help exit $?"

		# shellcheck disable=SC2086
		$sh "$f" --version >/dev/null 2>&1 && ok || bad "$n --version"

		# shellcheck disable=SC2086
		$sh "$f" --bogus-option >/dev/null 2>&1
		[ $? -eq 3 ] && ok || bad "$n bad option should exit 3"

		# shellcheck disable=SC2086
		out=$($sh "$f" --no-color 2>&1)
		rc=$?
		[ "$rc" -le 2 ] && ok || bad "$n exit $rc"
		esc=$(printf '\033')
		case $out in *"$esc"*) bad "$n --no-color printed escape codes" ;; *) ok ;; esac

		# shellcheck disable=SC2086
		out=$($sh "$f" --json 2>/dev/null)
		rc=$?
		[ "$rc" -le 2 ] && ok || bad "$n --json exit $rc"
		printf '%s' "$out" | json_ok && ok || bad "$n --json is not valid JSON"

		# shellcheck disable=SC2086
		out=$($sh "$f" --quiet 2>&1)
		[ "$(printf '%s\n' "$out" | tail -n 1 | cut -d: -f1)" = "${n%.sh}" ] ||
			[ "$n" = check.sh ] && ok || bad "$n --quiet should end with a verdict line"
	done

	# Dispatcher.
	# shellcheck disable=SC2086
	$sh bin/toolkit list 2>&1 | grep -q platform && ok || bad "toolkit list"
	# shellcheck disable=SC2086
	$sh bin/toolkit no-such-check >/dev/null 2>&1
	[ $? -eq 3 ] && ok || bad "toolkit unknown check should exit 3"
	# shellcheck disable=SC2086
	$sh bin/toolkit '../lib/common' >/dev/null 2>&1
	[ $? -eq 3 ] && ok || bad "toolkit should reject path-like names"
	# shellcheck disable=SC2086
	TK_SHELL=$sh $sh bin/toolkit platform --json | json_ok && ok || bad "toolkit platform --json"
	IFS=$nl
done
IFS=$old_ifs

# BusyBox-only systems (Alpine, embedded) have BusyBox awk, sed, grep and df
# instead of the GNU ones. Run everything with only BusyBox applets on PATH.
if command -v busybox >/dev/null 2>&1; then
	sh="busybox-only PATH"
	printf '== %s\n' "$sh"
	bb=$(mktemp -d)
	bbin=$(command -v busybox)
	for a in $(busybox --list); do ln -s "$bbin" "$bb/$a"; done
	if out=$(PATH=$bb TK_SHELL="$bbin sh" "$bbin" sh tests/checks_test.sh 2>&1); then ok; else
		bad "checks_test.sh"
		printf '%s\n' "$out" | grep -v '^ok'
	fi
	for f in checks/*.sh; do
		n=${f##*/}
		out=$(PATH=$bb "$bbin" sh "$f" --json 2>/dev/null)
		rc=$?
		[ "$rc" -le 2 ] && ok || bad "$n --json exit $rc"
		printf '%s' "$out" | json_ok && ok || bad "$n --json is not valid JSON"
		out=$(PATH=$bb "$bbin" sh "$f" --no-color 2>&1)
		case $out in *"not found"* | *"applet"* | *"nrecognized option"* | *"nvalid option"*)
			bad "$n uses a tool or option BusyBox lacks"; printf '%s\n' "$out" | sed 's/^/     | /' ;;
		*) ok ;; esac
	done
	rm -rf "$bb"
fi

# Running through a symlink, as an installed copy would.
tmp=$(mktemp -d)
ln -s "$ROOT/bin/toolkit" "$tmp/toolkit"
"$tmp/toolkit" platform --quiet >/dev/null 2>&1
[ $? -le 2 ] && ok || bad "toolkit via symlink"
rm -rf "$tmp"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
