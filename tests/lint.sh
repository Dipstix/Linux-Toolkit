#!/bin/sh
#
# Runs ShellCheck over every shell script in the repo, as CI does.
#
#   sh tests/lint.sh

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT" || exit 3

command -v shellcheck >/dev/null 2>&1 || {
	echo "shellcheck not found: https://github.com/koalaman/shellcheck#installing" >&2
	exit 3
}

# shellcheck disable=SC2046 # word splitting is wanted: one arg per file
shellcheck -x bin/toolkit $(find lib checks templates tests -name '*.sh' | sort)
