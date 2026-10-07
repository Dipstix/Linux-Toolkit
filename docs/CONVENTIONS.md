# Conventions

How every Linux-Toolkit check is written, so they all look and behave the
same and keep running on any distro.

## Portability rules

- **POSIX `sh` only.** Shebang `#!/bin/sh`. No bash arrays, `[[ ]]`,
  `local`, `function`, `source`, `$'...'`, `echo -e` or process
  substitution. ShellCheck runs in `sh` mode and catches most of these.
- **No variables named without a prefix inside the library.** Since there
  is no `local`, library internals use `_tk_` / `_TK_` names. Check scripts
  should use lowercase names for their own variables.
- **Only POSIX tool options.** `grep -E`, `sed -n`, `awk` (not gawk
  extensions), `tr`, `cut`, `head`, `sort`. No `grep -P`, `sed -i`,
  `readlink -f` without a fallback, or GNU long options. BusyBox must work.
- **Prefer `/proc` and `/sys`** over tools that may not be installed.
- **Check before using optional tools.** `tk_need_cmd ss iproute2 && ...`
  records a `[SKIP]` with an install hint when a tool is missing.
- **Never hang.** Wrap anything that can block (DNS, network, NFS paths) in
  `tk_timeout 5 ...`.
- **Never change the system.** Checks are read-only diagnostics.
- **Work without root.** Show what you can and call `tk_want_root` to note
  that output is limited. Use `tk_require_root` only when nothing useful
  can be shown otherwise.
- **Detect, don't assume.** Use `tk_detect_os`, `tk_detect_pkg`,
  `tk_detect_init` and `tk_detect_virt` and branch on their results, with
  fallbacks for systemd, OpenRC and SysV.

## Anatomy of a check

Start from `templates/check.sh`. A check is `checks/<name>.sh`, runnable
as `toolkit <name>` or `sh checks/<name>.sh`. Names are lowercase letters,
digits, `-` and `_`.

```sh
#!/bin/sh
TK_NAME=disk
TK_DESC='Disk space, inodes and mount health'
TK_OPTIONS='      --threshold N  Warn above N% used (default 85)'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

threshold=85
while [ $# -gt 0 ]; do
	case $1 in
	--threshold) tk_need_arg "$@"; threshold=$2; shift ;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done

tk_start
tk_section "Root filesystem"
tk_kv  "Mount" "/"
tk_kvn "Used percent" "$used" "$used%"
if [ "$used" -ge "$threshold" ]; then tk_warn "/ is $used% full"; else tk_ok "/ has space"; fi
tk_finish
```

`TK_DESC` must be a single-quoted or double-quoted one-liner: `toolkit
list` reads it straight from the file.

## Options

Every check gets these from `tk_common_opt`; don't redefine them:
`-h/--help`, `-V/--version`, `-j/--json`, `-q/--quiet`, `-v/--verbose`,
`--no-color`, `--color`.

Check-specific options are long options taking a separate value
(`--threshold 90`), documented in `TK_OPTIONS`, and validated with
`tk_usage_error` (exit 3) when wrong.

## Output helpers

| Helper | Use for |
| --- | --- |
| `tk_start` | Once, after option parsing. Prints the header. |
| `tk_section TITLE` | Start a group of related facts and results |
| `tk_kv LABEL VALUE` | A fact (string; empty becomes `null` in JSON) |
| `tk_kvn LABEL NUMBER [DISPLAY]` | A numeric fact; DISPLAY is what humans see |
| `tk_kvb LABEL CMD...` | A yes/no fact from a command's exit status |
| `tk_kvj LABEL JSON` | Raw JSON (an array or object you built) in `data`; not printed |
| `tk_print FORMAT ARGS...` | `printf` for the human view only (tables, lists) |
| `tk_ok MSG` | A check that passed |
| `tk_warn MSG` | Needs attention soon (exit status at least 1) |
| `tk_crit MSG` | Broken or about to break (exit status 2) |
| `tk_info MSG` | Worth knowing, not a problem |
| `tk_skip MSG` | Couldn't check (missing tool, needs root) |
| `tk_finish` | Last line. Prints the result and exits. |
| `tk_die MSG` | The check itself failed. Exits 3. |
| `tk_debug MSG` | Only shown with `--verbose`, on stderr |

Lists such as processes or mounts are a `tk_print` table for humans plus
one `tk_kvj` array of objects for JSON, built with `tk_json_str` for every
string.

Small helpers: `tk_is_uint` (validate option values), `tk_pct PART TOTAL`
(rounded percent, safe for byte counts too big for shell arithmetic),
`tk_ge A B` (compare decimals such as load averages), `tk_duration SECS`
and `tk_human_bytes BYTES`.

Read kernel state through `$TK_PROC` and `$TK_SYS` (default `/proc` and
`/sys`), and configuration and logs through `$TK_ETC` and `$TK_LOGDIR`
(default `/etc` and `/var/log`), so tests can point a check at fixture
files.

`/proc/net` files hold addresses in hex. Prepend `tk_net_awk` to an awk
program to get `hexval`, `ip4`, `ip6` (network byte order, as in
`ipv6_route` and `if_inet6`) and `ip6w` (four host-order words, as in
`tcp6`):

```sh
awk "$(tk_net_awk)"' NR > 1 { print $1, ip4($2) }' "$TK_PROC/net/route"
```

Write messages a tired admin at 3am understands: say what is wrong and,
where you can, what to do (`Swap is 92% used; check for a memory leak with
toolkit memory`).

Human output goes to stdout. Errors and debug lines go to stderr.

## In the summary

Plain `toolkit` runs every check with `--quiet` and shows one line each,
so `[WARN]` and `[CRIT]` messages must make sense on their own, without
the section title or the facts printed above them: `/var has used 92% of
its inodes`, not `92% used`. Name the thing and the number in the message
itself.

A check that ends with nothing passed and nothing wrong (no firewall in a
container, no service manager) shows as `[ -- ]` with its first `tk_skip`
message, or its first `tk_info` message if it has no skips, so make that
message explain why there was nothing to check.

New checks join the summary automatically, after the ones grouped in
`bin/toolkit` (`_GROUPS`); add yours to a group to place it.

When a `tk_kvn` call passes a DISPLAY value, a unit at the end of the label
(`bytes`, `seconds`, `ms`, `celsius`) is dropped from the human view, since
DISPLAY carries the unit: `"Total bytes"` shows as `Total: 15.7 GiB` but
stays `total_bytes` in JSON.

## JSON

With `--json`, a check prints exactly one JSON object and nothing else on
stdout:

```json
{
  "tool": "platform",
  "version": "0.1.0",
  "host": "web01",
  "timestamp": "2026-10-05T21:28:32Z",
  "status": "ok",
  "summary": {"ok": 2, "warn": 0, "crit": 0, "info": 1, "skip": 0},
  "data": {
    "system": {"os_id": "ubuntu", "kernel": "6.8.0-45-generic"},
    "environment": {"running_as_root": true}
  },
  "checks": [
    {"section": "assessment", "status": "ok", "message": "Distribution recognised (debian family)"}
  ]
}
```

- `status` is `ok`, `warn` or `crit`; `unknown` (with an `error` field)
  when the check failed to run.
- `data` keys are the section and label slugs (`"Used percent"` becomes
  `used_percent`), so keep labels unique within a section and stable
  across releases: other tools will read them.
- Numbers in `data` come from `tk_kvn` and are raw bytes, counts or
  percents, never pre-formatted strings.

## Exit status

`0` OK, `1` warning, `2` critical, `3` unknown or usage error. The worst
result recorded wins.

## Testing

`sh tests/lint.sh` runs ShellCheck. `sh tests/run.sh` runs the library unit
tests, the check scenarios, and smoke-tests every check (`--help`, `--json`
validity, exit codes, `--no-color`, `--quiet`) under each POSIX shell
installed: dash, bash `--posix`, BusyBox, mksh and yash. When BusyBox is
installed it also runs everything with only BusyBox applets on `PATH`, as
on Alpine, to catch GNU-only tool options.

`tests/checks_test.sh` holds scenario tests: give a check fake kernel files
(`TK_PROC=fixture/proc`) or fake tools (a stub `systemctl` or `df` first on
`PATH`) and assert its exit status and messages. To force the init system
or container detection, set `_TK_INIT_DONE=1 TK_INIT=openrc` or
`_TK_VIRT_DONE=1 TK_CONTAINER=` in the environment. Add a scenario for
every threshold and every init-system branch you write.
