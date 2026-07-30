#!/bin/bash
# Kolonie AI — the hardening the operating system itself enforces (#3)
#
# Usage:
#   ./scripts/host-hardening.sh verify   check the host against every claim; non-zero on drift
#   ./scripts/host-hardening.sh apply    make the claims true, idempotently
#   ./scripts/host-hardening.sh status   show the current state, no exit code meaning
#
# ## Why this exists, and why `verify` is the mode that matters
#
# `ARCHITECTURE.md` in kolonie-docs listed four properties under Security. Three
# of them — ufw, fail2ban, unattended-upgrades — were **already true** when #3
# was opened, installed on 2026-07-25 and recorded nowhere. The fourth, *"SSH
# key auth only, no password login"*, was **false**: cloud-init had written
# `PasswordAuthentication yes` and it had been winning ever since.
#
# So the document was wrong in both directions at once, and the expensive half
# was not the missing work — it was the reassuring sentence. An unexecutable
# security section drifts from the host in whichever direction nobody is
# looking, and nobody looks at the direction that reads as already fine.
#
# `verify` is therefore the point of this file and `apply` is its lesser half.
# It reads and never writes, and it is what makes the Security section a claim
# someone can check rather than a claim someone made.
#
# It needs root, and it refuses to run without it rather than skipping what it
# cannot see. `sshd -T`, `passwd -S` and `iptables -S` all need it, which is
# every check that could come back false — a degraded run would report the
# reassuring half of the answer, which is the exact failure this file exists
# because of.
#
# ## What this does NOT cover
#
# **Ports 80 and 443 are not governed by ufw**, whatever `ufw status` implies by
# listing them. Docker publishes a port by writing its own DNAT rule, so those
# packets are forwarded to the container and never traverse ufw's INPUT chain —
# the ALLOW lines for 80/443 are decoration and deleting them would change
# nothing. What actually filters them is `origin-firewall.sh`, in `DOCKER-USER`,
# from #21. `verify` checks that it is loaded, because a reader of `ufw status`
# will otherwise conclude the firewall covers something it does not.

set -euo pipefail

# The break-glass account: password login, deliberately, and no keys. Named here
# rather than assumed so that `verify` on a host that never had one still says
# something true.
BREAKGLASS_USER="${BREAKGLASS_USER:-admin}"

# The account the deploy authenticates as, by key. It must never gain a password.
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"

SSHD_GLOBAL=/etc/ssh/sshd_config.d/10-kolonie-auth.conf
SSHD_BREAKGLASS=/etc/ssh/sshd_config.d/99-kolonie-breakglass.conf
F2B_JAIL=/etc/fail2ban/jail.d/kolonie.conf

RC=0

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
die()  { echo "ERROR: $1" >&2; exit 1; }
ok()   { echo "  ok    $1"; }
bad()  { echo "  DRIFT $1"; RC=1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "$1 needs root; re-run with sudo"; }

# ---------------------------------------------------------------------------
# SSH authentication policy
# ---------------------------------------------------------------------------
#
# ## Two files, and the split is not tidiness
#
# sshd uses the **first** value it obtains for a keyword, not the last. The host
# shipped with `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf` saying
# `PasswordAuthentication no`, and cloud-init then wrote `50-cloud-init.conf`
# saying `yes`. `50` sorts first, so `yes` won — and the resulting state was not
# a decision anybody took. It was a collision, and it could have gone the other
# way just as silently on the next cloud-init run.
#
# The global `no` therefore has to sort **before** cloud-init's file, hence `10-`.
#
# The `Match` block has to sort **last**, hence `99-`. A `Match` runs until the
# next `Match` or the end of the file, and `Include` splices files inline — so a
# `Match` left open at the end of `10-` would swallow whatever cloud-init writes
# next into a conditional block. Putting it at the true end of the parse means
# there is nothing after it to capture.
#
# Within the block the `yes` overrides the global `no`, which is the documented
# behaviour of `Match` and the one place first-obtained-value does not apply.

apply_ssh() {
    need_root apply

    cat >"$SSHD_GLOBAL" <<EOF
# Managed by kolonie-infra scripts/host-hardening.sh (#3). Do not hand-edit.
#
# Sorts before cloud-init's 50-*.conf on purpose: sshd takes the FIRST value it
# finds for a keyword, and cloud-init writes \`PasswordAuthentication yes\`.
# Password login for everyone except the break-glass account in 99-*.conf.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF

    cat >"$SSHD_BREAKGLASS" <<EOF
# Managed by kolonie-infra scripts/host-hardening.sh (#3). Do not hand-edit.
#
# The one account allowed to authenticate by password, kept on purpose: SSH is
# the only way onto this host that does not go through the provider's console,
# and a lost or corrupted key otherwise means the console is the only way back.
#
# What makes this safe enough to keep is not the account, it is the arithmetic.
# fail2ban caps a single source at five attempts per ten minutes, so a long
# passphrase is out of reach by many orders of magnitude. What it is NOT proof
# against is the password leaking by some route that has nothing to do with
# guessing — so it is one account, it holds nothing else, and it is the last
# thing to reach for rather than a convenience.
#
# Sorts last so the Match block cannot swallow a later Include.
Match User $BREAKGLASS_USER
    PasswordAuthentication yes
EOF

    chmod 644 "$SSHD_GLOBAL" "$SSHD_BREAKGLASS"

    # Validate before reloading. A syntactically broken drop-in stops sshd from
    # starting, and on a host reached only over SSH that is the whole machine.
    sshd -t || die "sshd rejected the generated config; nothing reloaded"

    systemctl reload ssh
    log "SSH auth policy applied and sshd reloaded"
}

verify_ssh() {
    echo "SSH authentication"

    local global_pw breakglass_pw
    global_pw=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    breakglass_pw=$(sshd -T -C "user=$BREAKGLASS_USER,host=localhost,addr=127.0.0.1" 2>/dev/null \
        | awk '/^passwordauthentication /{print $2}')

    [ "$global_pw" = no ] \
        && ok "password auth off globally" \
        || bad "password auth is '$global_pw' globally — expected no"

    [ "$breakglass_pw" = yes ] \
        && ok "break-glass account '$BREAKGLASS_USER' may still use a password" \
        || bad "break-glass account '$BREAKGLASS_USER' has password auth '$breakglass_pw' — expected yes"

    # The deploy account authenticating by key is only half of it. If it ever
    # acquires a password hash, the global `no` above is the only thing standing
    # between the deploy account and the internet's password guessers — and a
    # future edit to that line would be judged on the wrong facts.
    case "$(passwd -S "$DEPLOY_USER" 2>/dev/null | awk '{print $2}')" in
        L|NP) ok "deploy account '$DEPLOY_USER' has no usable password" ;;
        P)    bad "deploy account '$DEPLOY_USER' has a password set — it should authenticate by key only" ;;
        *)    bad "could not read the password state of '$DEPLOY_USER'" ;;
    esac

    [ -f "$SSHD_GLOBAL" ] && [ -f "$SSHD_BREAKGLASS" ] \
        && ok "policy is on disk in $(dirname "$SSHD_GLOBAL"), not inherited by accident" \
        || bad "the drop-ins this script manages are missing — the current state is whatever cloud-init last wrote"
}

# ---------------------------------------------------------------------------
# fail2ban
# ---------------------------------------------------------------------------
#
# The values below are the Debian defaults, written down rather than inherited.
# That is deliberate and it is not busywork: the break-glass account above is
# safe *because of these numbers*. Leaving them implicit means the one control
# holding up a documented decision is a package default that a distribution
# upgrade may change without anybody reading a changelog.

F2B_BANTIME=600
F2B_FINDTIME=600
F2B_MAXRETRY=5

apply_f2b() {
    need_root apply

    cat >"$F2B_JAIL" <<EOF
# Managed by kolonie-infra scripts/host-hardening.sh (#3). Do not hand-edit.
#
# These are the Debian defaults, stated explicitly because #3 kept a password
# login for one break-glass account and these numbers are what make that safe:
# five attempts per ten minutes per source is ~720 a day, which puts guessing a
# long passphrase beyond reach. If the defaults ever move, this file means the
# decision moves with a diff instead of with a package upgrade.
[sshd]
enabled  = true
backend  = systemd
bantime  = $F2B_BANTIME
findtime = $F2B_FINDTIME
maxretry = $F2B_MAXRETRY
EOF

    chmod 644 "$F2B_JAIL"
    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
    log "fail2ban jail pinned and reloaded"
}

verify_f2b() {
    echo "fail2ban"

    systemctl is-active --quiet fail2ban \
        && ok "service active" \
        || { bad "service is not active"; return; }

    fail2ban-client status sshd >/dev/null 2>&1 \
        && ok "sshd jail loaded" \
        || bad "sshd jail is not loaded"

    local v
    for pair in "bantime $F2B_BANTIME" "findtime $F2B_FINDTIME" "maxretry $F2B_MAXRETRY"; do
        set -- $pair
        v=$(fail2ban-client get sshd "$1" 2>/dev/null | tail -1)
        [ "$v" = "$2" ] \
            && ok "$1 = $v" \
            || bad "$1 = $v — expected $2"
    done

    [ -f "$F2B_JAIL" ] \
        && ok "policy is on disk, not a package default" \
        || bad "no managed jail file — the numbers above are whatever the package shipped"
}

# ---------------------------------------------------------------------------
# unattended-upgrades
# ---------------------------------------------------------------------------

verify_uu() {
    echo "unattended-upgrades"

    systemctl is-active --quiet unattended-upgrades \
        && ok "service active" \
        || bad "service is not active"

    # The service being up is not the same as it being switched on: the periodic
    # keys are what actually schedule a run, and they live somewhere else.
    local periodic
    periodic=$(apt-config dump 2>/dev/null | awk -F'"' '/^APT::Periodic::Unattended-Upgrade /{print $2}')
    [ "${periodic:-0}" != 0 ] \
        && ok "APT::Periodic::Unattended-Upgrade = $periodic" \
        || bad "APT::Periodic::Unattended-Upgrade is 0 or unset — nothing runs on a schedule"

    grep -qE '^[^/]*\$\{distro_id\}:\$\{distro_codename\}-security' \
        /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null \
        && ok "the -security pocket is an allowed origin" \
        || bad "the -security pocket is not in Allowed-Origins"

    # A timer that is enabled but has never fired looks identical to a working
    # one in `systemctl is-active`. The log is the only thing that says it ran.
    local last=""
    [ -r /var/log/unattended-upgrades/unattended-upgrades.log ] && last=$(
        awk '/Starting unattended upgrades script/{d=$1} END{print d}' \
            /var/log/unattended-upgrades/unattended-upgrades.log)
    [ -n "$last" ] \
        && ok "last run recorded: $last" \
        || bad "no run recorded in the unattended-upgrades log"
}

# ---------------------------------------------------------------------------
# ufw, and the part of the story it does not tell
# ---------------------------------------------------------------------------

verify_ufw() {
    echo "ufw"

    if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
        bad "ufw is not active"
        return
    fi
    ok "active"

    ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming)' \
        && ok "default deny (incoming)" \
        || bad "the inbound default is not deny"

    local port
    for port in 22 80 443; do
        ufw status 2>/dev/null | grep -qE "^${port}/tcp\s+ALLOW" \
            && ok "$port/tcp allowed" \
            || bad "$port/tcp is not allowed — check this before trusting any deploy"
    done

    # Everything above is true and half of it is inert. Say so here rather than
    # letting `ufw status` be read as the whole firewall.
    echo "  note  80 and 443 bypass ufw entirely — Docker's DNAT rules forward"
    echo "        those packets without them ever reaching ufw's INPUT chain."
    echo "        origin-firewall.sh (#21) is what filters them:"
    if iptables -S KOLONIE-EDGE-ONLY >/dev/null 2>&1; then
        ok "KOLONIE-EDGE-ONLY chain is loaded"
    else
        bad "KOLONIE-EDGE-ONLY is NOT loaded — 80/443 are open to the whole internet"
    fi
}

# ---------------------------------------------------------------------------

verify() {
    need_root verify
    echo "=== host hardening, verified against the running system ==="
    echo
    verify_ssh;  echo
    verify_ufw;  echo
    verify_f2b;  echo
    verify_uu;   echo
    if [ "$RC" -eq 0 ]; then
        echo "All checks passed. ARCHITECTURE.md's Security section describes this host."
    else
        echo "DRIFT: the host and the documented claims disagree. Fix one of them."
    fi
    return "$RC"
}

apply() {
    need_root apply
    apply_ssh
    apply_f2b
    echo
    log "applied — re-running verify"
    echo
    verify
}

status() {
    echo "=== sshd, effective ==="
    sshd -T 2>/dev/null | grep -E '^(passwordauthentication|pubkeyauthentication|permitrootlogin|kbdinteractive)' || true
    echo "--- for $BREAKGLASS_USER ---"
    sshd -T -C "user=$BREAKGLASS_USER,host=localhost,addr=127.0.0.1" 2>/dev/null \
        | grep -E '^passwordauthentication' || true
    echo
    echo "=== ufw ==="
    ufw status verbose 2>/dev/null || true
    echo
    echo "=== fail2ban ==="
    fail2ban-client status sshd 2>/dev/null || true
    echo
    echo "=== unattended-upgrades ==="
    apt-config dump 2>/dev/null | grep -E '^APT::Periodic::(Update-Package-Lists|Unattended-Upgrade) ' || true
}

case "${1:-}" in
    verify) verify ;;
    apply)  apply ;;
    status) status ;;
    *) die "usage: $0 {verify|apply|status}" ;;
esac
