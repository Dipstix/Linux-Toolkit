# Linux-Toolkit

Simple diagnostic and troubleshooting scripts for Linux servers that run on
any distro: Debian, Ubuntu, RHEL and its clones, Fedora, SUSE, Arch, Alpine
and more.

- **No dependencies.** Plain POSIX `sh` and the standard tools every system
  has, so it works on minimal images, Alpine/BusyBox and old servers.
- **Read-only.** Checks look, they never change anything.
- **Consistent.** Every check has the same options, the same output layout,
  `--json` for scripts, and monitoring-friendly exit codes.

## Quick start

```sh
git clone https://github.com/Dipstix/Linux-Toolkit.git
cd Linux-Toolkit
./bin/toolkit list              # what's available
./bin/toolkit platform          # what is this machine?
./bin/toolkit platform --json   # same, as JSON
sudo ./bin/toolkit platform     # some checks show more as root
```

Each check also runs on its own: `sh checks/platform.sh --help`.

## Common options

| Option | Meaning |
| --- | --- |
| `-j`, `--json` | One JSON object on stdout |
| `-q`, `--quiet` | Only warnings, problems and a one-line verdict |
| `-v`, `--verbose` | Debug detail on stderr |
| `--no-color` | No colors (`NO_COLOR=1` works too) |
| `-V`, `--version` | Print the version |
| `-h`, `--help` | Help for that check |

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | OK |
| 1 | Warning |
| 2 | Critical |
| 3 | Unknown, or a usage error |

These match the Nagios plugin convention, so a check can be dropped into
most monitoring systems or a cron job as is.

## Checks

| Check | What it shows |
| --- | --- |
| `platform` | Distro, kernel, init system, package manager, container/VM |

More are on the way: system overview, CPU and memory, disks, services and
logs, networking, security, and a one-shot `toolkit report`.

## Layout

```
bin/toolkit          entry point: toolkit <check> [options]
lib/common.sh        shared helpers: output, JSON, options, detection
checks/*.sh          one script per check
templates/check.sh   starting point for a new check
tests/               lint.sh (ShellCheck) and run.sh (smoke tests)
docs/CONVENTIONS.md  how checks are written
```

## Contributing

Read [docs/CONVENTIONS.md](docs/CONVENTIONS.md), copy `templates/check.sh`
to `checks/<name>.sh`, then run:

```sh
sh tests/lint.sh   # ShellCheck
sh tests/run.sh    # tests under every POSIX shell installed
```

CI runs both on every pull request.
