#!/usr/bin/env bash
#
# r770-airgap-check.sh — prove the box has no path to the internet left open.
# Read-only; safe to run at any time, as often as you like.
#
#   r770-airgap-check.sh [--mgmt-cidr <a.b.c.d/n>]
#
#   --mgmt-cidr   the management subnet; resolvers outside it (and outside
#                 loopback) fail. Without it the resolver checks are SKIPPED,
#                 never guessed.
#
#   0  air-gapped · 2  warnings to disposition · 1  a path to the outside is open
#
# Every check distinguishes "no" from "couldn't tell": a tool that is not
# installed yields SKIP with the reason, never PASS. The rehearsal's air-gap
# simulator once reported OPEN while blocking because a root-only check's
# error was swallowed as "absent" — that is the false pass this vocabulary
# exists to prevent.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MGMT_CIDR=""
PHONE_HOME_UNITS="unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer ua-timer.timer motd-news.timer fwupd-refresh.timer"
usage() { usage_from_header 3 13; exit 0; }

ip2int() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
in_cidr() {  # in_cidr <ip> <cidr>
    local ip=$1 cidr=$2 net bits mask
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    net=${cidr%/*}; bits=${cidr#*/}
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( $(ip2int "$ip") & mask )) -eq $(( $(ip2int "$net") & mask )) ]
}
resolver_ok() {  # loopback, docker's embedded DNS, or inside the management subnet
    local ns=$1
    case "$ns" in 127.*|::1) return 0 ;; esac
    [ -n "$MGMT_CIDR" ] && in_cidr "$ns" "$MGMT_CIDR"
}

check_apt() {
    local uris bad
    if ! command -v apt-get >/dev/null 2>&1; then skip "apt: apt-get not found"; return; fi
    # the '$(URI)' below is apt's own format token, not a shell substitution
    uris=$(apt-get indextargets --format '$''(URI)' 2>/dev/null | sort -u || true)
    if [ -z "$uris" ]; then
        fail "apt: no index targets at all — no sources configured; the local repo is not set up (r770-import-bundle.sh apt)"
    else
        bad=$(printf '%s\n' "$uris" | grep -v '^file:' || true)
        if [ -n "$bad" ]; then
            fail "apt: source(s) beyond the local repo: $(printf '%s' "$bad" | tr '\n' ' ')"
        else
            pass "apt: every index target is file: ($(printf '%s\n' "$uris" | grep -c .) target(s))"
        fi
    fi
    local extra
    extra=$(find "$(p /etc/apt/sources.list.d)" -maxdepth 1 -type f ! -name r770-local.list -printf '%f ' 2>/dev/null || true)
    if [ -n "$extra" ]; then warn "apt: files beside r770-local.list in sources.list.d: $extra"; else pass "apt: sources.list.d holds only r770-local.list"; fi
}

check_snapd() {
    if dpkg -s snapd >/dev/null 2>&1; then fail "snapd is installed — it phones home; purge it (r770-import-bundle.sh phone-home)"; else pass "snapd not installed"; fi
    [ -d "$(p /snap)" ] && warn "/snap directory still present (leftover mounts?)"
    return 0
}

check_units() {
    local u state
    for u in $PHONE_HOME_UNITS; do
        state=$(systemctl is-enabled "$u" 2>/dev/null || true)
        case "$state" in
            enabled|static) warn "unit $u is $state — disable it" ;;
            "")             pass "unit $u not present" ;;
            *)              pass "unit $u $state" ;;
        esac
    done
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then skip "docker: not installed (docker stage not run yet)"; return; fi
    local m pxy dropin
    m=$(docker info --format '{{.RegistryConfig.Mirrors}}' 2>/dev/null || echo unreadable)
    case "$m" in
        "[]") pass "docker: no registry mirrors" ;;
        unreadable) fail "docker: daemon not answering — cannot tell what it would reach" ;;
        *) fail "docker: registry mirrors configured: $m" ;;
    esac
    pxy=$(docker info --format '{{.HTTPProxy}}{{.HTTPSProxy}}' 2>/dev/null || true)
    if [ -z "$pxy" ]; then pass "docker: no daemon proxy"; else fail "docker: daemon proxy set: $pxy"; fi
    dropin=$(grep -ril 'proxy' "$(p /etc/systemd/system/docker.service.d)" 2>/dev/null || true)
    if [ -n "$dropin" ]; then fail "docker: proxy drop-in present: $dropin"; else pass "docker: no proxy drop-in under docker.service.d"; fi
    local ids id ns bad=0 n=0
    ids=$(docker ps -q 2>/dev/null || true)
    if [ -z "$ids" ]; then skip "containers: none running — resolver check has nothing to inspect"; return; fi
    for id in $ids; do
        n=$((n + 1))
        for ns in $(docker exec "$id" cat /etc/resolv.conf 2>/dev/null | awk '/^nameserver/{print $2}'); do
            resolver_ok "$ns" || { bad=$((bad + 1)); note "container $id resolves via $ns"; }
        done
    done
    if [ "$bad" -gt 0 ]; then
        if [ -n "$MGMT_CIDR" ]; then fail "containers: $bad resolver(s) outside loopback/management across $n container(s)"; else skip "containers: $bad non-loopback resolver(s) seen and no --mgmt-cidr to judge them by"; fi
    else
        pass "containers: $n running, every resolver loopback/management"
    fi
}

check_dns() {
    if ! dpkg -s dnsmasq >/dev/null 2>&1; then skip "dnsmasq: not installed (Phase 5 not built) — .lab authority and no-resolv cannot be checked"; return; fi
    local conf; conf=$(cat "$(p /etc/dnsmasq.conf)" "$(p /etc/dnsmasq.d)"/* 2>/dev/null || true)
    if printf '%s\n' "$conf" | grep -qE '^no-resolv'; then pass "dnsmasq: no-resolv set"; else fail "dnsmasq: no-resolv not set — it would forward to /etc/resolv.conf"; fi
    local up; up=$(printf '%s\n' "$conf" | grep -E '^server=' | grep -v '^server=/' || true)
    if [ -n "$up" ]; then fail "dnsmasq: upstream forwarder(s): $(printf '%s' "$up" | tr '\n' ' ')"; else pass "dnsmasq: no upstream forwarders"; fi
}

check_resolv() {
    local f ns bad=0 n=0; f="$(p /etc/resolv.conf)"
    [ -r "$f" ] || { skip "resolv.conf: not readable"; return; }
    if [ -z "$MGMT_CIDR" ]; then skip "resolv.conf: no --mgmt-cidr given — resolvers not judged (never guessed)"; return; fi
    while read -r ns; do
        [ -n "$ns" ] || continue
        n=$((n + 1)); resolver_ok "$ns" || { bad=$((bad + 1)); note "resolver $ns is outside loopback and $MGMT_CIDR"; }
    done < <(awk '/^nameserver/{print $2}' "$f")
    if [ "$bad" -gt 0 ]; then fail "resolv.conf: $bad of $n resolver(s) point outside the lab"; else pass "resolv.conf: $n resolver(s), all loopback/management"; fi
}

check_pip() {
    if [ -n "${PIP_INDEX_URL:-}${PIP_EXTRA_INDEX_URL:-}" ]; then fail "pip: PIP_INDEX_URL/PIP_EXTRA_INDEX_URL set in the environment"; else pass "pip: no index in the environment"; fi
    local f; for f in "$(p /etc/pip.conf)" "$(p /etc/pip/pip.conf)"; do
        [ -f "$f" ] || continue
        if grep -qiE '^\s*no-index\s*=\s*(true|1|yes)' "$f"; then pass "pip: $f sets no-index"; elif grep -qiE 'index-url' "$f"; then fail "pip: $f names an index-url"; else warn "pip: $f present without no-index"; fi
    done
}

check_pro() {
    if ! command -v pro >/dev/null 2>&1; then skip "ubuntu pro: client not installed"; return; fi
    local st; st=$(pro status 2>/dev/null || true)
    if printf '%s' "$st" | grep -qi 'not attached'; then pass "ubuntu pro: not attached"; elif printf '%s' "$st" | grep -qi 'attached'; then warn "ubuntu pro: attached — its services expect the internet"; else skip "ubuntu pro: status unreadable"; fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mgmt-cidr) MGMT_CIDR="${2:-}"; shift ;;
        -h|--help)   usage ;;
        *)           common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
[ -z "$MGMT_CIDR" ] || [[ $MGMT_CIDR =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || die "--mgmt-cidr must look like a.b.c.d/n"
kit_init "r770-airgap-check"
banner "air-gap posture"
check_apt; check_snapd; check_units; check_docker; check_dns; check_resolv; check_pip; check_pro
footer "air-gap posture"
