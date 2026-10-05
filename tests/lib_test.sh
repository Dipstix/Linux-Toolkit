#!/bin/sh
#
# Unit tests for lib/common.sh. Run with any POSIX shell:
#   dash tests/lib_test.sh

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TK_NAME=lib_test
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

fails=0
eq() {
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$3" "$2"
		fails=$((fails + 1))
	fi
}

eq "slug basic" "$(tk_slug 'Total memory (MiB)')" "total_memory_mib"
eq "slug trims" "$(tk_slug '  PID 1 ')" "pid_1"
eq "json plain" "$(tk_json_str 'hello world')" '"hello world"'
eq "json empty" "$(tk_json_str '')" '""'
eq "json quote" "$(tk_json_str 'say "hi"')" '"say \"hi\""'
eq "json backslash" "$(tk_json_str 'C:\temp')" '"C:\\temp"'
eq "json newline" "$(tk_json_str 'a
b')" '"a\nb"'
eq "json tab" "$(tk_json_str "$(printf 'a\tb')")" '"a\tb"'
eq "json control" "$(tk_json_str "$(printf 'a\001b')")" '"ab"'

if tk_is_number 42 && tk_is_number -1.5 && tk_is_number 0; then r=yes; else r=no; fi
eq "number valid" "$r" yes
if tk_is_number 007 || tk_is_number 1e5 || tk_is_number '' || tk_is_number 22.04.1; then r=yes; else r=no; fi
eq "number invalid" "$r" no

eq "bytes small" "$(tk_human_bytes 512)" "512 B"
eq "bytes kib" "$(tk_human_bytes 1536)" "1.5 KiB"
eq "bytes gib" "$(tk_human_bytes 8589934592)" "8.0 GiB"

if tk_is_uint 0 && tk_is_uint 42; then r=yes; else r=no; fi
eq "uint valid" "$r" yes
if tk_is_uint '' || tk_is_uint -1 || tk_is_uint 1.5 || tk_is_uint 4x; then r=yes; else r=no; fi
eq "uint invalid" "$r" no

eq "pct half" "$(tk_pct 1 2)" 50
eq "pct rounds" "$(tk_pct 2 3)" 67
eq "pct zero total" "$(tk_pct 5 0)" 0
na() { awk "$(tk_net_awk)"" BEGIN { print $1 }"; }
case $(uname -m) in s390* | ppc | ppc64 | mips | mips64 | sparc* | m68k) be=1 ;; *) be= ;; esac
if [ -z "$be" ]; then
	eq "net ip4" "$(na 'ip4("0101A8C0")')" 192.168.1.1
	eq "net ip6 words" "$(na 'ip6w("00000000000000000000000001000000")')" ::1
	eq "net ip6 mapped" "$(na 'ip6w("0000000000000000FFFF00000100007F")')" ::ffff:127.0.0.1
fi
eq "net hexval" "$(na 'hexval("0016")')" 22
eq "net ip6 any" "$(na 'ip6("00000000000000000000000000000000")')" ::
eq "net ip6 compress" "$(na 'ip6("fe800000000000000000000000000001")')" fe80::1
eq "net ip6 first longest run" "$(na 'ip6("20010db8000000000001000000000001")')" 2001:db8::1:0:0:1
eq "net ip6 no run" "$(na 'ip6("20010db8000100020003000400050006")')" 2001:db8:1:2:3:4:5:6
eq "pct big numbers" "$(tk_pct 8589934592 17179869184)" 50
if tk_ge 1.5 1.5 && tk_ge 2 1.5 && ! tk_ge 0.9 1; then r=yes; else r=no; fi
eq "ge decimals" "$r" yes

eq "duration minutes" "$(tk_duration 59)" "0m"
eq "duration hours" "$(tk_duration 3700)" "1h 1m"
eq "duration days" "$(tk_duration 273600)" "3d 4h 0m"

tk_detect_os
eq "os id set" "$([ -n "$TK_OS_ID" ] && echo yes)" yes
eq "os family set" "$([ -n "$TK_OS_FAMILY" ] && echo yes)" yes
tk_detect_init
eq "init set" "$([ -n "$TK_INIT" ] && echo yes)" yes
tk_detect_pkg
tk_detect_virt
eq "install hint" "$(TK_PKG=apk; _TK_PKG_DONE=1; tk_install_hint curl)" "apk add curl"

# JSON assembly: run a tiny check in a subshell and capture its output.
out=$(
	TK_JSON=1
	tk_start
	tk_kv "Top" "level"
	tk_section "Disk usage"
	tk_kv "Mount" "/"
	tk_kvn "Used pct" 93
	tk_kvn "Bad number" abc
	tk_kv "Empty" ""
	tk_kvb "Is true" true
	tk_kvj "List" '[1,{"a":"b"}]'
	tk_print 'not in json %s\n' x
	tk_warn 'Disk "/" is 93% full'
	tk_finish
)
rc=$?
eq "json exit status" "$rc" 1
case $out in
*'"data":{"top":"level","disk_usage":{"mount":"/","used_pct":93,"bad_number":null,"empty":null,"is_true":true,"list":[1,{"a":"b"}]}}'*) r=yes ;;
*) r=no ;;
esac
eq "json data shape" "$r" yes
case $out in
*'"checks":[{"section":"disk_usage","status":"warn","message":"Disk \"/\" is 93% full"}]'*) r=yes ;;
*) r=no ;;
esac
eq "json checks shape" "$r" yes

out=$(
	tk_start >/dev/null
	tk_print 'row %s|' 1 2
	tk_kvj "Hidden" '[]'
	exit 0
)
eq "print human" "$out" "row 1|row 2|"

out=$(
	tk_start >/dev/null
	tk_crit "bad"
	tk_warn "meh"
	tk_finish
)
eq "crit wins" "$?" 2

out=$(TK_JSON=1 tk_die "boom" 2>/dev/null)
eq "die exit" "$?" 3
eq "die json" "$out" '{"tool":"lib_test","version":"'"$TK_VERSION"'","status":"unknown","error":"boom"}'

[ "$fails" -eq 0 ] || {
	printf '%d failure(s)\n' "$fails"
	exit 1
}
