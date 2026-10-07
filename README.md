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
sudo ./bin/toolkit
```

That checks everything and gives one line per area, with the problems
spelled out:

```
Checking web01 (Ubuntu 24.04.1 LTS, kernel 6.8.0-45-generic, up 41d 3h 12m)

  [ OK ] system
  [ OK ] cpu
  [WARN] memory        Memory is 91% used (warning at 85%)
  [CRIT] disk          / is 97% full (1.2 GiB left); find what grew with: du -xh / | sort -h | tail
                       /var has used 92% of its inodes
  [ OK ] services
  ...
  [ OK ] logins

Result: CRITICAL - 1 critical, 1 with warnings, out of 12 checks
For details, run: toolkit memory, toolkit disk
```

Then look closer at any area:

```sh
./bin/toolkit disk              # everything the disk check knows
./bin/toolkit cpu memory        # a summary of just these two
./bin/toolkit list              # what each check looks at
./bin/toolkit help disk         # its options, such as thresholds
```

Names can be shortened when it's clear which you mean (`toolkit mem`,
`toolkit net`). It runs without root, but some checks see less; `sudo`
gives the full picture. Each check also runs on its own:
`sh checks/disk.sh --help`.

`--quiet` keeps only the problems and the verdict, which suits cron:

```sh
./bin/toolkit --quiet || mail -s "$(hostname) needs a look" admin@example.com
```

`--json` gives one object for the whole run, with each check's full
result under `results`:

```sh
./bin/toolkit --json | jq '.results.disk.checks'
```

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

The summary exits with the worst result of its checks (`3` only when
nothing worse happened). These match the Nagios plugin convention, so a check can be dropped into
most monitoring systems or a cron job as is.

## Checks

| Check | What it shows |
| --- | --- |
| `platform` | Distro, kernel, init system, package manager, container/VM |
| `system` | Uptime, users, processes and zombies, pending reboot, clock sync, file handles |
| `cpu` | CPU model and count, load per CPU, user/system/iowait/steal, busiest processes |
| `memory` | RAM and swap use, container memory limit, pressure, OOM kills, biggest processes |
| `disk` | Space and inodes per filesystem, read-only mounts, I/O pressure |
| `services` | Failed services (systemd, OpenRC, SysV, runit), and `--expect sshd,cron` to require some |
| `logs` | Kernel OOM kills, disk/filesystem/hardware errors and hung tasks; recent errors; log sizes |
| `network` | Interfaces (link, speed, duplex, addresses, errors), routes, default gateway and whether it answers |
| `dns` | resolv.conf and nsswitch, hostname resolution, test lookups, and whether each nameserver answers |
| `connectivity` | Ping the gateway, TCP connections by IP and by name, `--url` fetch through any proxy |
| `ports` | Listening TCP/UDP ports and their processes; databases, Docker API or telnet open to the network |
| `firewall` | firewalld, ufw, nftables and iptables: is incoming traffic filtered, is IPv6 left open |
| `logins` | Failed logins and where they come from, guessed-then-got-in, SSH root/password settings, extra root accounts |

Thresholds are options, e.g. `toolkit disk --warn 80 --crit 90` or
`toolkit memory --warn 90`; see each check's `--help`.

```sh
./bin/toolkit disk --quiet           # one line per problem, then a verdict
./bin/toolkit services --expect sshd,nginx
./bin/toolkit logs --hours 6
./bin/toolkit ports --expect 22,443
./bin/toolkit connectivity --target db01:5432,10.0.0.1:443
sudo ./bin/toolkit firewall
sudo ./bin/toolkit logins --hours 48
```

`connectivity` and `dns` send traffic: by default a TCP connection to
1.1.1.1 and example.com on port 443, and a lookup of example.com. Use
`--target` and `--name` to test your own hosts, or `dns --offline`.

## Layout

```
bin/toolkit          entry point: toolkit [check...] [options]
lib/common.sh        shared helpers: output, JSON, options, detection
checks/*.sh          one script per check
templates/check.sh   starting point for a new check
tests/               lint.sh (ShellCheck), run.sh (runs all tests),
                     lib_test.sh, checks_test.sh (scenarios with fake inputs)
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
