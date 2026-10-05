#!/bin/sh
#
# logins - who is trying to get in, and how easy is it? Counts failed
# logins (SSH, su, console) and where they come from, spots an address
# that guessed and then got in, checks the SSH server's login settings,
# and looks for extra root accounts and accounts without a password.

TK_NAME=logins
TK_DESC='Failed logins and their sources, risky SSH settings, and extra root or passwordless accounts'
TK_OPTIONS='      --hours N      Look at the last N hours of the journal (default 24)
      --warn N       Warn at N or more failed logins in that time (default 20)
      --top N        Show the N addresses with most failures (default 5)'
TK_HELP_EXTRA='Logins are read from the journal, or from auth.log/secure/messages where
there is no journal (those are scanned from the end, not by time). Run as
root to read the logs, /etc/shadow and the effective sshd settings.'

: "${TK_ROOT:=$(cd "$(dirname "$0")/.." && pwd -P)}"
# shellcheck source=lib/common.sh
. "$TK_ROOT/lib/common.sh"

hours=24 warn=20 top=5
while [ $# -gt 0 ]; do
	case $1 in
	--hours) tk_need_arg "$@"; hours=$2; shift ;;
	--warn) tk_need_arg "$@"; warn=$2; shift ;;
	--top) tk_need_arg "$@"; top=$2; shift ;;
	*) tk_common_opt "$1" || tk_usage_error "unknown option: $1" ;;
	esac
	shift
done
for v in "$hours" "$warn" "$top"; do
	tk_is_uint "$v" || tk_usage_error "--hours, --warn and --top need whole numbers"
done
[ "$hours" -gt 0 ] || tk_usage_error "--hours needs a whole number above 0"
[ "$warn" -gt 0 ] || tk_usage_error "--warn needs a whole number above 0"

# Failed attempts. OpenSSH logs one "Failed <method> for" per attempt
# (also for invalid users); Dropbear logs "Bad password attempt" and
# "Login attempt for nonexistent user"; local logins go through PAM.
ssh_fail_re='Failed [a-z/-]+ for |Bad password attempt for|Login attempt for nonexistent user'
local_fail_re='pam_unix\((su|su-l|sudo|login|gdm-password|lightdm)(:[a-z]+)?\): authentication failure|FAILED (LOGIN|SU)'
accept_re='Accepted [a-z/-]+ for |Password auth succeeded for|Pubkey auth succeeded for'

# from_ip: the source address of each line ("from 1.2.3.4", "rhost=...",
# Dropbear's "from 1.2.3.4:5555"), or "-".
from_ip() {
	awk '{
		ip = "-"
		for (i = 1; i < NF; i++) if ($i == "from") { ip = $(i + 1); break }
		if (ip == "-") for (i = 1; i <= NF; i++) if ($i ~ /^rhost=./) { ip = substr($i, 7); break }
		gsub(/[\047"]/, "", ip)
		if (ip ~ /^[0-9.]+:[0-9]+$/) sub(/:[0-9]+$/, "", ip)
		sub(/^\[/, "", ip); sub(/\]:?[0-9]*$/, "", ip)
		print ip
	}'
}

# journal_ok: journalctl exists and the journal has something in it.
journal_ok() {
	tk_has journalctl && [ -n "$(journalctl -q -n 1 --no-pager 2>/dev/null)" ]
}

auth_file() {
	for _f in auth.log secure messages; do
		[ -f "$TK_LOGDIR/$_f" ] && { printf '%s' "$TK_LOGDIR/$_f"; return 0; }
	done
	return 1
}

# sshd_text: the SSH server configuration with Include lines expanded, in
# the order sshd reads it.
sshd_text() {
	_main=$TK_ETC/ssh/sshd_config
	[ -r "$_main" ] || return 1
	while IFS= read -r _l || [ -n "$_l" ]; do
		case $_l in
		[Ii]nclude\ * | [Ii]nclude"	"*)
			# Split the patterns without globbing them here: relative ones
			# are relative to /etc/ssh, not to the current directory.
			set -f
			_pats=''
			for _pat in ${_l#* }; do
				case $_pat in /*) ;; *) _pat=$TK_ETC/ssh/$_pat ;; esac
				_pats="$_pats $_pat"
			done
			set +f
			for _inc in $_pats; do
				[ -r "$_inc" ] && cat "$_inc" && echo
			done
			;;
		*) printf '%s\n' "$_l" ;;
		esac
	done <"$_main"
}

tk_start

# --- Failed logins -------------------------------------------------------
tk_section "Failed logins"
log='' src=''
if journal_ok; then
	# auth (4) and authpriv (10) facilities hold sshd, su, sudo and login.
	log=$(tk_timeout 30 journalctl -q --no-pager --since "-${hours}h" -o short \
		SYSLOG_FACILITY=4 SYSLOG_FACILITY=10 2>/dev/null) && src="journal, last ${hours}h"
fi
if [ -z "$src" ] && f=$(auth_file); then
	if [ -r "$f" ]; then
		log=$(tail -n 20000 "$f" 2>/dev/null) && src="$f (last 20000 lines)"
	fi
fi
tk_kv "Source" "$src"

if [ -z "$src" ]; then
	if tk_is_root; then
		tk_skip "No journal or auth log found (common in containers: check the container's own logs)"
	else
		tk_want_root "the auth logs are not readable" || :
		tk_skip "Could not read the auth logs; re-run with sudo"
	fi
else
	ssh_fails=$(printf '%s\n' "$log" | grep -E -- "$ssh_fail_re")
	local_fails=$(printf '%s\n' "$log" | grep -E -- "$local_fail_re")
	accepted=$(printf '%s\n' "$log" | grep -E -- "$accept_re")
	n_ssh=$(printf '%s' "$ssh_fails" | grep -c .)
	n_local=$(printf '%s' "$local_fails" | grep -c .)
	n_acc=$(printf '%s' "$accepted" | grep -c .)
	tk_kvn "SSH failures" "$n_ssh"
	tk_kvn "Local failures" "$n_local"
	tk_kvn "SSH logins" "$n_acc"

	# Count per source address, most first: "count ip".
	by_ip=$(printf '%s\n' "$ssh_fails" | grep . | from_ip | grep -v '^-$' | sort | uniq -c | sort -rn)
	tk_kvn "Source addresses" "$(printf '%s' "$by_ip" | grep -c .)"
	items=''
	if [ -n "$by_ip" ] && [ "$top" -gt 0 ]; then
		tk_print '  %-8s %s\n' FAILURES ADDRESS
		printf '%s\n' "$by_ip" | head -n "$top" | while read -r c ip; do
			tk_print '  %-8s %s\n' "$c" "$ip"
		done
		items=$(printf '%s\n' "$by_ip" | head -n "$top" | while read -r c ip; do
			printf '{"address":%s,"failures":%s},' "$(tk_json_str "$ip")" "$c"
		done)
	fi
	tk_kvj "Top sources" "[${items%,}]"

	total=$((n_ssh + n_local))
	if [ "$total" = 0 ]; then
		tk_ok "No failed logins"
	elif [ "$total" -ge "$warn" ]; then
		worst=$(printf '%s\n' "$by_ip" | head -n 1 | awk '{ print $2 " (" $1 ")" }')
		tk_warn "$total failed logins${worst:+, most from $worst}; use SSH keys only and consider fail2ban or sshguard"
	else
		tk_info "$total failed login(s)"
	fi
	[ "$n_local" -gt 0 ] && tk_info "$n_local failed su/sudo/console login(s); someone on this host is guessing passwords"

	# An address that failed many times and then got in.
	if [ -n "$accepted" ] && [ -n "$by_ip" ]; then
		# "ip user" for each login, then "--", then the failure counts.
		hits=$({
			printf '%s\n' "$accepted" | awk '{
				u = "?"; ip = "-"
				for (i = 1; i < NF; i++) { if ($i == "for") u = $(i + 1); if ($i == "from") ip = $(i + 1) }
				print ip, u }' | sort -u
			echo --
			printf '%s\n' "$by_ip"
		} | awk '
			!sep { if ($0 == "--") sep = 1; else ok[$1] = ok[$1] (ok[$1] == "" ? "" : ",") $2; next }
			$1 >= 10 && ($2 in ok) { print $2, $1, ok[$2] }')
		while read -r ip c users; do
			[ -n "$ip" ] && tk_crit "$ip failed to log in $c times, then logged in as $users; make sure that was you"
		done <<EOF
$hits
EOF
	fi

	root_in=$(printf '%s\n' "$accepted" | awk '{ for (i = 1; i < NF; i++) if ($i == "for" && $(i + 1) == "root") { print; break } }' | grep -c .)
	tk_kvn "Root SSH logins" "$root_in"
	[ "$root_in" -gt 0 ] && tk_info "root logged in over SSH $root_in time(s); personal accounts with sudo leave a better trail"
	tk_is_root || tk_want_root "some log entries may be hidden" || :
fi

# --- SSH server -------------------------------------------------------------
tk_section "SSH server"
cfg='' how=''
if tk_is_root && tk_has sshd && cfg=$(sshd -T 2>/dev/null) && [ -n "$cfg" ]; then
	how="sshd -T"
elif cfg=$(sshd_text); then
	# First value wins; settings after a Match block are conditional.
	cfg=$(printf '%s\n' "$cfg" | awk '
		{ sub(/#.*/, ""); sub(/^[ \t]+/, "") }
		NF == 0 { next }
		tolower($1) == "match" { exit }
		{ k = tolower($1); if (!(k in seen)) { seen[k] = 1; print k, tolower($2) } }')
	how="$TK_ETC/ssh/sshd_config"
fi
tk_kv "Settings from" "$how"

if [ -z "$how" ]; then
	tk_info "No SSH server configuration found"
else
	get() { printf '%s\n' "$cfg" | awk -v k="$1" '$1 == k { print $2; exit }'; }
	port=$(get port) prl=$(get permitrootlogin) pwa=$(get passwordauthentication) epw=$(get permitemptypasswords)
	# OpenSSH defaults when a setting is absent.
	tk_kv "Port" "${port:-22}"
	tk_kv "Permit root login" "${prl:-prohibit-password}"
	tk_kv "Password authentication" "${pwa:-yes}"
	tk_kv "Permit empty passwords" "${epw:-no}"
	if [ "${epw:-no}" = yes ]; then
		tk_crit "SSH accepts empty passwords (PermitEmptyPasswords yes); set it to no"
	fi
	case ${prl:-prohibit-password} in
	yes) tk_warn "root can log in over SSH with a password (PermitRootLogin yes); use prohibit-password or no" ;;
	*) tk_ok "root cannot log in over SSH with a password" ;;
	esac
	if [ "${pwa:-yes}" = yes ]; then
		if [ "${n_ssh:-0}" -ge "$warn" ]; then
			tk_warn "SSH allows password logins and they are being guessed; set PasswordAuthentication no once keys are set up"
		else
			tk_info "SSH allows password logins; keys only (PasswordAuthentication no) is safer"
		fi
	fi
fi

# --- Accounts -------------------------------------------------------------------
tk_section "Accounts"
if [ -r "$TK_ETC/passwd" ]; then
	logins=$(awk -F: '$7 !~ /(nologin|false|sync|shutdown|halt)$/ && $7 != "" { print $1 }' "$TK_ETC/passwd")
	tk_kvn "Login accounts" "$(printf '%s' "$logins" | grep -c .)"
	lj=''
	for u in $logins; do lj="${lj:+$lj,}$(tk_json_str "$u")"; done
	tk_kvj "Login account list" "[$lj]"
	uid0=$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' "$TK_ETC/passwd")
	for u in $uid0; do
		tk_crit "$u has UID 0, so it is another root account; remove it unless you added it on purpose"
	done
	[ -z "$uid0" ] && tk_ok "root is the only account with UID 0"
fi
if [ -r "$TK_ETC/shadow" ]; then
	empty=$(awk -F: 'NF > 1 && $2 == "" { print $1 }' "$TK_ETC/shadow")
	for u in $empty; do
		tk_crit "$u has no password, so anyone can log in as it on the console; set one or lock it (passwd -l $u)"
	done
	[ -z "$empty" ] && tk_ok "No account has an empty password"
elif [ -e "$TK_ETC/shadow" ]; then
	tk_want_root "$TK_ETC/shadow is not readable" || :
	tk_skip "Could not check for accounts without a password"
fi

tk_finish
