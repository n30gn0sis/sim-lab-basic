#!/usr/bin/env bash
#
# r770-wan.sh — WAN impairment on the kit's lab TAPs: HTB rate cap plus netem
# delay/jitter/loss, from a profile file. Shapes only lab-tapN (created by
# r770-gns3-deploy.sh labnet), never a physical port, the mgmt bond or a
# capture interface -- the guard list is the refusal of any other name.
#
#   r770-wan.sh apply <profile> <lab-tapN>   shape frames the host sends INTO the TAP
#   r770-wan.sh show                         every kit TAP: profile or clean, and its qdiscs
#   r770-wan.sh clear <lab-tapN> | --all     back to the default qdisc (idempotent)
#
#   WAN_PROFILE_DIR   where <profile>.conf lives (default: the kit's config/wan/profiles)
#   GNS3_LAB_TAPS 4
#
#   0  done · 1  refused
#
# netem shapes egress. A frame from the node on TAP_A to the node on TAP_B
# enters the host through lab-tapA and leaves through lab-tapB, so a profile
# on lab-tapB shapes the A->B direction; asymmetry is two profiles on two TAPs.
# Not gated: it changes only interfaces the kit created and records what it
# applied under /run/r770-wan/<tap>, which show and r770-scenario.sh record read.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PROFILES="${WAN_PROFILE_DIR:-$KIT_DIR/config/wan/profiles}"
LAB_TAPS="${GNS3_LAB_TAPS:-4}"
STATE="/run/r770-wan"
usage() { usage_from_header 3; exit 0; }

tap_check() {  # tap_check <name> — a kit TAP that exists, or die
    [[ "$1" =~ ^lab-tap[0-9]+$ ]] || die "$1 is not a kit TAP (lab-tapN) — r770-wan.sh shapes nothing else"
    [ -e "$(p /sys/class/net)/$1" ] || die "$1 does not exist — run r770-gns3-deploy.sh labnet"
}
profile_read() {  # profile_read <name> — sets RATE DELAY JITTER LOSS REORDER DESC, or die before any tc
    local f="$PROFILES/$1.conf" line k v
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "'$1' is not a profile name"
    if [ ! -f "$f" ]; then
        local have=() g
        for g in "$PROFILES"/*.conf; do [ -f "$g" ] && have+=("$(basename "$g" .conf)"); done
        die "no profile '$1' in $PROFILES (have: ${have[*]:-none})"
    fi
    RATE=""; DELAY=""; JITTER=""; LOSS=""; REORDER=""; DESC=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        k=${line%%=*}; v=${line#*=}
        case "$k" in
            rate)    [[ "$v" =~ ^[0-9]+(k|m|g)?bit$ ]] || die "$f: rate=$v is not a tc rate (e.g. 20mbit)"; RATE=$v ;;
            delay)   [[ "$v" =~ ^[0-9]+(us|ms|s)$ ]] || die "$f: delay=$v is not a tc time (e.g. 40ms)"; DELAY=$v ;;
            jitter)  [[ "$v" =~ ^[0-9]+(us|ms|s)$ ]] || die "$f: jitter=$v is not a tc time"; JITTER=$v ;;
            loss|reorder) [[ "$v" =~ ^[0-9]+(\.[0-9]+)?%$ ]] || die "$f: $k=$v is not a percentage (e.g. 0.2%)"
                     if [ "$k" = loss ]; then LOSS=$v; else REORDER=$v; fi ;;
            description) DESC=$v ;;
            *)       die "$f: unknown key '$k' (known: rate delay jitter loss reorder description)" ;;
        esac
    done < "$f"
    [ -n "$RATE" ] || die "$f: no rate= line"
    [ -n "$DELAY" ] || die "$f: no delay= line"
}
netem_args() {  # netem_args — fills NETEM (an array) from the profile just read
    NETEM=(delay "$DELAY")
    [ -n "$JITTER" ] && NETEM+=("$JITTER" distribution normal)
    [ -n "$LOSS" ] && NETEM+=(loss "$LOSS")
    [ -n "$REORDER" ] && NETEM+=(reorder "$REORDER")
    return 0
}
applied() { cat "$(p "$STATE")/$1" 2>/dev/null || true; }  # applied <tap> — the recorded profile, or empty

cmd_apply() {
    local prof=$1 tap=$2 cur
    need_root; tap_check "$tap"; profile_read "$prof"; netem_args
    cur=$(applied "$tap")
    if [ -n "$cur" ]; then note "current:  $tap profile $cur"; else note "current:  $tap clean (default qdisc)"; fi
    note "proposed: htb rate $RATE, netem ${NETEM[*]}${DESC:+ — $DESC}"
    note "rollback: r770-wan.sh clear $tap"
    if ! { run tc qdisc replace dev "$tap" root handle 1: htb default 10 \
        && run tc class replace dev "$tap" parent 1: classid 1:10 htb rate "$RATE" \
        && run tc qdisc replace dev "$tap" parent 1:10 handle 10: netem "${NETEM[@]}"; }; then
        die "tc refused — $tap may be partly shaped; run r770-wan.sh clear $tap"
    fi
    if [ "$DRY" != "1" ]; then mkdir -p "$(p "$STATE")"; printf '%s\n' "$prof" > "$(p "$STATE")/$tap"; fi
    pass "$tap shaped as $prof (frames the host sends into $tap)"
    footer "apply"
}
clear_one() {  # clear_one <tap> [sweep] — sweep also deletes a root qdisc nothing here recorded
    if [ -z "${2:-}" ] && [ -z "$(applied "$1")" ] && ! tc qdisc show dev "$1" 2>/dev/null | grep -q netem; then pass "$1 already clean"; return 0; fi
    run tc qdisc del dev "$1" root || note "tc had no root qdisc to delete on $1 (already default)"
    [ "$DRY" = "1" ] || rm -f "$(p "$STATE")/$1"
    pass "$1 clean"
}
cmd_clear() {
    need_root
    local i
    if [ "${1:-}" = "--all" ]; then
        for ((i = 0; i < LAB_TAPS; i++)); do [ -e "$(p /sys/class/net)/lab-tap$i" ] && clear_one "lab-tap$i" sweep; done
    else
        [ -n "${1:-}" ] || die "clear needs a kit TAP or --all"
        tap_check "$1"; clear_one "$1"
    fi
    footer "clear"
}
cmd_show() {
    local i t prof
    for ((i = 0; i < LAB_TAPS; i++)); do
        t="lab-tap$i"; [ -e "$(p /sys/class/net)/$t" ] || continue
        prof=$(applied "$t")
        printf '%-10s %s\n' "$t" "${prof:-clean}"
        tc qdisc show dev "$t" 2>/dev/null | sed 's/^/           /'
    done
    return 0
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        --all)     ARGS+=("$1") ;;
        -*)        common_flag "$1" || die "unknown option: $1 (try --help)" ;;
        *)         ARGS+=("$1") ;;
    esac
    shift
done
kit_init "r770-wan"
case "$SUB" in
    apply) [ "${#ARGS[@]}" -eq 2 ] || die "apply needs <profile> <lab-tapN>"; cmd_apply "${ARGS[@]}" ;;
    clear) cmd_clear "${ARGS[@]:-}" ;;
    show)  cmd_show ;;
    -h|--help|help|"") usage ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
