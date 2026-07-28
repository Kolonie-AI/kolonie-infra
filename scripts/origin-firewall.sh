#!/bin/bash
# Kolonie AI — let only the edge reach the origin (#21)
#
# Usage:
#   ./scripts/origin-firewall.sh apply     rebuild the rules from Cloudflare's list
#   ./scripts/origin-firewall.sh status    show what is installed
#   ./scripts/origin-firewall.sh remove    take the rules out again
#
# ## What this defends
#
# Every hostname is proxied, so the only traffic that *should* arrive on 80 and
# 443 comes from Cloudflare. Anything else has gone round the edge, and going
# round the edge means: no WAF, no DDoS handling, and — because the registration
# rate limit keys on `CF-Connecting-IP` — a forgeable identity. An attacker who
# rotates that header at the origin gets an unlimited front door while every
# honest caller stays limited (kolonie-platform D-028).
#
# ## Why the rules go in DOCKER-USER and not in ufw
#
# **ufw was already active on this host, with `deny (incoming)` and only 22 open
# — and 80/443 answered the whole internet anyway.** Docker publishes a port by
# writing its own DNAT rule into the `nat` table, so the packet is forwarded to
# the container and never traverses ufw's INPUT chain. `ufw deny 80` would have
# looked like a fix and changed nothing.
#
# `DOCKER-USER` is the chain Docker guarantees it will not overwrite, and it is
# consulted *before* Docker's own forwarding rules. It is the only correct place
# for this.
#
# ## Why -i eth0 is not optional
#
# DOCKER-USER also carries container-to-container traffic, and Traefik reaches
# the website container on port 80. A rule matching "dport 80 and not from
# Cloudflare" would drop exactly that, and the site would 502 from the inside.
# Restricting to the WAN interface confines this to traffic arriving from
# outside the machine.
#
# ## Where the list comes from
#
# `https://www.cloudflare.com/ips-v4` and `ips-v6`, fetched at apply time. Never
# a list pasted into this file: Cloudflare adds ranges, and a hand-copied list
# fails silently in the worse direction — a legitimate edge node stops being able
# to reach the origin and a slice of the world sees 522 with nothing in any log
# here to explain it. The systemd timer that re-runs this is part of the control,
# not a convenience.
#
# This proves *a* Cloudflare edge, not *our zone's* edge: any Cloudflare customer
# can point a hostname at this address and their traffic arrives from the same
# ranges. Closing that needs authenticated origin pull, which needs a zone
# setting this repository has no token for — see #21.

set -euo pipefail

CHAIN="KOLONIE-EDGE-ONLY"
PORTS="80,443"
V4_URL="https://www.cloudflare.com/ips-v4"
V6_URL="https://www.cloudflare.com/ips-v6"

# The interface the world arrives on, asked rather than assumed — a hard-coded
# eth0 is how this silently protects nothing on a host that renamed its NIC.
WAN_IF="${WAN_IF:-$(ip -4 route show default | awk '{print $5; exit}')}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
die() { echo "ERROR: $1" >&2; exit 1; }

[ -n "$WAN_IF" ] || die "could not determine the default-route interface; set WAN_IF"

# Fetch and sanity-check one family's ranges.
#
# The validation is the point. An empty answer, an HTML error page or a captive
# portal would otherwise become "no ranges", and a chain built from no ranges
# drops everything — this script's failure mode has to be *leave the firewall
# alone*, never *take the site off the internet*.
fetch_ranges() {
    local url="$1" family="$2" body
    body=$(curl -fsS --max-time 20 "$url") || die "could not fetch $url"

    local valid
    if [ "$family" = 4 ]; then
        valid=$(grep -cE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' <<<"$body" || true)
    else
        valid=$(grep -cE '^[0-9a-fA-F:]+/[0-9]{1,3}$' <<<"$body" || true)
    fi

    [ "$valid" -ge 5 ] || die "$url returned $valid usable IPv$family ranges — refusing to build a chain from that"
    [ "$valid" -eq "$(grep -c . <<<"$body")" ] || die "$url contained lines that are not CIDRs — refusing to parse it"

    printf '%s\n' "$body"
}

apply() {
    local v4 v6 cidr ipt
    v4=$(fetch_ranges "$V4_URL" 4)
    v6=$(fetch_ranges "$V6_URL" 6)
    log "Cloudflare publishes $(grep -c . <<<"$v4") IPv4 and $(grep -c . <<<"$v6") IPv6 ranges"

    for ipt in iptables ip6tables; do
        $ipt -N "$CHAIN" 2>/dev/null || true
        # Flushed and rebuilt with the DROP added last, so the only window this
        # has is one where traffic is *allowed*. A rebuild that dropped first
        # would take the site down for the length of its own loop.
        $ipt -F "$CHAIN"

        # Replies to connections the origin itself opened, and anything already
        # established, are not the thing being filtered.
        $ipt -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

        if [ "$ipt" = iptables ]; then
            while read -r cidr; do
                [ -n "$cidr" ] && $ipt -A "$CHAIN" -s "$cidr" -j RETURN
            done <<<"$v4"
        else
            while read -r cidr; do
                [ -n "$cidr" ] && $ipt -A "$CHAIN" -s "$cidr" -j RETURN
            done <<<"$v6"
        fi

        $ipt -A "$CHAIN" -j DROP

        # Hook it from DOCKER-USER, once. `-C` first, because this script runs on
        # a timer and a duplicated jump per run would grow the chain forever.
        if ! $ipt -C DOCKER-USER -i "$WAN_IF" -p tcp -m multiport --dports "$PORTS" -j "$CHAIN" 2>/dev/null; then
            $ipt -I DOCKER-USER 1 -i "$WAN_IF" -p tcp -m multiport --dports "$PORTS" -j "$CHAIN"
            log "$ipt: hooked $CHAIN from DOCKER-USER on $WAN_IF"
        fi
    done

    log "Applied: $PORTS on $WAN_IF reachable from Cloudflare only"
}

status() {
    local ipt
    for ipt in iptables ip6tables; do
        echo "=== $ipt DOCKER-USER ==="
        $ipt -L DOCKER-USER -n --line-numbers 2>/dev/null || true
        echo "=== $ipt $CHAIN ($(($( $ipt -S "$CHAIN" 2>/dev/null | grep -c RETURN) - 1)) ranges) ==="
        $ipt -L "$CHAIN" -n 2>/dev/null | tail -3 || echo "not installed"
    done
}

remove() {
    local ipt
    for ipt in iptables ip6tables; do
        while $ipt -C DOCKER-USER -i "$WAN_IF" -p tcp -m multiport --dports "$PORTS" -j "$CHAIN" 2>/dev/null; do
            $ipt -D DOCKER-USER -i "$WAN_IF" -p tcp -m multiport --dports "$PORTS" -j "$CHAIN"
        done
        $ipt -F "$CHAIN" 2>/dev/null || true
        $ipt -X "$CHAIN" 2>/dev/null || true
    done
    log "Removed — 80/443 are open to the whole internet again"
}

case "${1:-}" in
    apply)  apply ;;
    status) status ;;
    remove) remove ;;
    *) die "usage: $0 {apply|status|remove}" ;;
esac
