#!/usr/bin/env bash
#
# r770-e2e.sh — the whole lab, end to end, in one command: prove the lab
# mirror, Malcolm's capture and GNS3 (r770-validate.sh), run every scenario of
# the pack in GNS3 (r770-scenario.sh up → traffic → down), then judge every run
# in Malcolm (r770-scenario.sh check). One report; each child's own output is
# kept beside it. A test runner, not a deploy orchestrator: it installs and
# changes nothing a scenario would not, so it is not gated.
#
#   r770-e2e.sh --bundle <dir> --capture-ifs "<if ...>" --lab-bridge <br> [options]
#
#   --bundle <dir>        the bundle the scenarios take their images from
#   --capture-ifs "a b"   Malcolm's capture interfaces — given, never guessed
#   --lab-bridge <br>     the lab bridge the mirror hangs off — given, never guessed
#   --scenarios a,b       only these, in this order (default: the whole pack)
#   --skip-validate       straight to the scenarios (no interface or bridge needed)
#   --out DIR             where the report lands (default: the evidence dir)
#   --dry-run / --yes / --non-interactive   as everywhere in the kit
#
#   E2E_VALIDATE_CMD / E2E_SCENARIO_CMD    the child scripts (tests stub them)
#
#   0  every step passed · 2  warnings (a check that SKIPped counts) · 1  a FAIL
#
# All traffic runs before any check: Malcolm's Arkime indexes a PCAP file only
# when netsniff rotates it, so the first check absorbs that wait (and nudges
# the rotation) and the rest pass as soon as their sessions are indexed.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VALIDATE="${E2E_VALIDATE_CMD:-$KIT_DIR/scripts/r770-validate.sh}"
SCENARIO="${E2E_SCENARIO_CMD:-$KIT_DIR/scripts/r770-scenario.sh}"
SCEN_DIR="${SCENARIO_DIR:-$KIT_DIR/scenarios}"
BUNDLE=""; CAPTURE_IFS=""; LAB_BRIDGE=""; ONLY=""; SKIP_VALIDATE=0; OUT=""
UP=""          # the scenario that is up right now; the EXIT trap takes it down
LOGDIR=""      # every child's output, beside the report
ROWS=()        # "step|verdict|detail", in order
RECS=()        # "scenario|run record"
usage() { usage_from_header 3; exit 0; }

row() {  # row <step> <PASS|WARN|FAIL|SKIP> <detail>
    ROWS+=("$1|$2|$3")
    case "$2" in
        PASS) pass "$1: $3" ;;
        WARN) warn "$1: $3" ;;
        FAIL) fail "$1: $3" ;;
        SKIP) skip "$1: $3" ;;
    esac
}
verdict_of() { case "$1" in 0) echo PASS ;; 2) echo WARN ;; *) echo FAIL ;; esac; }
last_verdict_line() { grep -E '^(READY|NOT READY)' "$1" | tail -1; }
child() {  # child <log-name> <cmd...> — run a child, its output to $LOGDIR/<log-name>.log; returns its exit
    local log="$LOGDIR/$1.log"; shift
    "$@" > "$log" 2>&1
}
teardown() {
    if [ -n "$UP" ]; then
        "$SCENARIO" down "$UP" > "$LOGDIR/down-$UP-on-exit.log" 2>&1 || true
        UP=""
    fi
}

write_report() {
    local f r step verdict detail
    f="$LOGDIR.md"
    {
        echo "# End-to-end run — $(hostname -s 2>/dev/null || echo host) — $(date -Is)"
        echo
        echo "Bundle: \`$BUNDLE\` · child output: \`$LOGDIR/\`"
        echo
        echo "| Step | Verdict | Detail |"
        echo "|---|---|---|"
        for r in "${ROWS[@]}"; do
            IFS='|' read -r step verdict detail <<< "$r"
            printf '| %s | %s | %s |\n' "$step" "$verdict" "$detail"
        done
    } > "$f"
    note "report: $f"
}

# ── arguments ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)        BUNDLE="${2:-}"; shift ;;
        --capture-ifs)   CAPTURE_IFS="${2:-}"; shift ;;
        --lab-bridge)    LAB_BRIDGE="${2:-}"; shift ;;
        --scenarios)     ONLY="${2:-}"; shift ;;
        --skip-validate) SKIP_VALIDATE=1 ;;
        --out)           OUT="${2:-}"; shift ;;
        -h|--help)       usage ;;
        *)               common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
[ -n "$BUNDLE" ] || die "--bundle <dir> is required: the scenarios take their images from it"
if [ "$SKIP_VALIDATE" = "0" ]; then
    [ -n "$CAPTURE_IFS" ] || die "--capture-ifs \"<if ...>\" is required (from discovery; never guessed) — or --skip-validate"
    [ -n "$LAB_BRIDGE" ] || die "--lab-bridge <br> is required (from discovery; never guessed) — or --skip-validate"
fi
ALL=()
for c in "$SCEN_DIR"/*/scenario.conf; do [ -e "$c" ] && ALL+=("$(basename "$(dirname "$c")")"); done
SEL=()
if [ -n "$ONLY" ]; then
    IFS=',' read -ra want <<< "$ONLY"
    for s in "${want[@]}"; do
        case " ${ALL[*]} " in *" $s "*) SEL+=("$s") ;; *) die "no scenario '$s' in $SCEN_DIR (see: r770-scenario.sh list)" ;; esac
    done
else
    SEL=("${ALL[@]}")
fi
[ "${#SEL[@]}" -gt 0 ] || die "no scenarios under $SCEN_DIR"

kit_init "r770-e2e"
need_root
OUT="${OUT:-${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}}"
LOGDIR="$OUT/e2e-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR" || die "cannot create $LOGDIR"
trap teardown EXIT
trap 'exit 130' INT TERM

# ── 1. validate ──────────────────────────────────────────────────────────────
banner "validate — the mirror, Malcolm's capture, GNS3"
if [ "$SKIP_VALIDATE" = "1" ]; then
    note "--skip-validate: no validation areas run"
else
    child validate-network "$VALIDATE" --area network --lab-bridge "$LAB_BRIDGE" --capture-ifs "$CAPTURE_IFS" --out "$LOGDIR"; rc=$?
    row "validate network" "$(verdict_of $rc)" "$(last_verdict_line "$LOGDIR/validate-network.log")"
    for a in capture gns3; do
        child "validate-$a" "$VALIDATE" --area "$a" --out "$LOGDIR"; rc=$?
        row "validate $a" "$(verdict_of $rc)" "$(last_verdict_line "$LOGDIR/validate-$a.log")"
    done
fi

# ── 2. run every scenario: up → traffic → down ───────────────────────────────
banner "scenarios — ${SEL[*]}"
child list "$SCENARIO" list --bundle "$BUNDLE"
notrun=" $(awk '/^[a-z0-9]/ {n = $1} /NOT runnable/ {print n}' "$LOGDIR/list.log" | tr '\n' ' ') "
for s in "${SEL[@]}"; do
    case "$notrun" in
        *" $s "*) row "up $s" SKIP "not runnable with this bundle ($(grep -A1 "^$s " "$LOGDIR/list.log" | grep -o 'NOT runnable.*'))"; continue ;;
    esac
    UP="$s"
    child "up-$s" "$SCENARIO" up "$s" --bundle "$BUNDLE"; rc=$?
    if [ "$rc" -eq 1 ]; then
        row "up $s" FAIL "$(last_verdict_line "$LOGDIR/up-$s.log") — $LOGDIR/up-$s.log"
    else
        row "up $s" "$(verdict_of $rc)" "$(last_verdict_line "$LOGDIR/up-$s.log")"
        child "traffic-$s" "$SCENARIO" traffic "$s"; rc=$?
        row "traffic $s" "$(verdict_of $rc)" "$(last_verdict_line "$LOGDIR/traffic-$s.log")"
        rec=$(sed -n 's/^ *run record: //p' "$LOGDIR/traffic-$s.log" | tail -1)
        [ -n "$rec" ] && RECS+=("$s|$rec")
    fi
    child "down-$s" "$SCENARIO" down "$s"; rc=$?
    UP=""
    row "down $s" "$(verdict_of $rc)" "$(last_verdict_line "$LOGDIR/down-$s.log")"
done
teardown   # nothing is up here; the EXIT trap does the same for a run cut short

# ── 3. judge every run in Malcolm ────────────────────────────────────────────
banner "check — every run, in Malcolm"
for r in "${RECS[@]}"; do
    s=${r%%|*}; rec=${r#*|}
    child "check-$s" "$SCENARIO" check "$s" --run "$rec"; rc=$?
    if [ "$rc" -eq 0 ] && grep -q '^SKIP  ' "$LOGDIR/check-$s.log"; then
        row "check $s" WARN "skipped: $(grep -m1 '^SKIP  ' "$LOGDIR/check-$s.log" | cut -c7-)"
    else
        row "check $s" "$(verdict_of $rc)" "$(last_verdict_line "$LOGDIR/check-$s.log")"
    fi
done

# ── 4. report ────────────────────────────────────────────────────────────────
write_report
footer "e2e"
