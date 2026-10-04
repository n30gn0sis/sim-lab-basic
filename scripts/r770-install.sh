#!/usr/bin/env bash
#
# r770-install.sh — the offline installer. Takes an R770 with Ubuntu 24.04
# installed, plus the bundle media, to a proven lab in one gated,
# re-enterable run. A thin sequencer: every step is an existing kit entry
# point, called with arguments read from install.conf; no pipeline logic
# lives here, and each pipeline still runs on its own.
#
#   r770-install.sh <subcommand> [options]
#
#   discover   print disks, NICs, addresses, bridges, mounts; write
#              install.conf.template (every value empty: nothing is chosen for you)
#   wizard     pick each value from numbered lists of what discover found;
#              write install.conf
#   plan       check install.conf and the image store, then every gated step
#              under --dry-run: the whole current/proposed/rollback review at once
#   run        import gns3 malcolm docs portal dashboards validate e2e, in order;
#              stops at the first FAIL; re-enter with --from <step>
#   status     which of those steps this host has finished
#
#   --conf FILE              the answers file (default /etc/lab/install.conf)
#   --from STEP / --to STEP  a slice of run's steps
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#                            (run --yes is unattended: it also implies --non-interactive)
#
#   INSTALL_IMPORT_CMD INSTALL_GNS3_CMD INSTALL_MALCOLM_CMD INSTALL_DOCS_CMD
#   INSTALL_PORTAL_CMD INSTALL_VALIDATE_CMD INSTALL_E2E_CMD   the children (tests stub them)
#
#   0  INSTALLED · 2  finished with warnings (never INSTALLED) · 1  refused or failed
#
# Started from the media, `run` imports the bundle (preflight, gate, copy —
# copy WITHOUT --media, so nothing unmounts the media this script is running
# from) and then execs the installer inside the local copy under
# /srv/bundles/<name>/kit, which carries on from gns3. Unmounting the media
# is the operator's last step; the summary prints the command.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

STEPS=(import gns3 malcolm docs portal dashboards validate e2e)
CONF_KEYS="BUNDLE MEDIA DEVICE CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR VALIDATE_AREAS"
REQUIRED_KEYS="MEDIA DEVICE CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR"
LATE_IFS="lab_mirror0"        # created by the gns3 step's labnet, so it may not exist yet
IMPORT="${INSTALL_IMPORT_CMD:-$KIT_DIR/scripts/r770-import-bundle.sh}"
GNS3="${INSTALL_GNS3_CMD:-$KIT_DIR/scripts/r770-gns3-deploy.sh}"
MALCOLM="${INSTALL_MALCOLM_CMD:-$KIT_DIR/scripts/r770-malcolm-deploy.sh}"
DOCS="${INSTALL_DOCS_CMD:-$KIT_DIR/scripts/r770-docs-deploy.sh}"
PORTAL="${INSTALL_PORTAL_CMD:-$KIT_DIR/scripts/r770-portal-deploy.sh}"
VALIDATE="${INSTALL_VALIDATE_CMD:-$KIT_DIR/scripts/r770-validate.sh}"
E2E="${INSTALL_E2E_CMD:-$KIT_DIR/scripts/r770-e2e.sh}"
SUB=""; CONF_PATH=""; FROM=""; TO=""
usage() { usage_from_header 3; exit 0; }

# ── install.conf ─────────────────────────────────────────────────────────────
conf_get() { local n="CONF_$1"; printf '%s' "${!n:-}"; }

# conf_load <file> — KEY=value lines into CONF_<KEY>. Parsed, never sourced:
# operator text is never evaluated. CR, surrounding blanks and one pair of
# double quotes are stripped, so a file edited on Windows reads the same.
conf_load() {
    local f=$1 line key val n=0
    [ -f "$f" ] || die "no answers file at $f — run 'r770-install.sh discover' (or wizard) first, then fill it in"
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%$'\r'}
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "$f:$n: not KEY=value: $line"
        key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        [[ "$val" == \"*\" ]] && { val=${val#\"}; val=${val%\"}; }
        case " $CONF_KEYS " in *" $key "*) ;; *) die "$f:$n: unknown key $key (known: $CONF_KEYS)" ;; esac
        printf -v "CONF_$key" '%s' "$val"
    done < "$f"
}

is_placeholder() {
    case "$1" in *'<'*|*'>'*|*CHANGEME*|*changeme*|/dev/sdX|/dev/sdX[0-9]*) return 0 ;; esac
    return 1
}
host_ifs()     { ip -br link 2>/dev/null | awk '{print $1}' | sed 's/@.*//'; }
host_devices() { lsblk -lpno NAME 2>/dev/null | awk '{print $1}'; }
has_line()     { printf '%s\n' "$2" | grep -qxF -- "$1"; }

# self_bundle — the bundle this installer sits in (kit/scripts/.. /..), or nothing.
self_bundle() {
    local cand; cand=$(cd "$KIT_DIR/.." 2>/dev/null && pwd -P) || return 0
    ( bundle_dir "$cand" ) >/dev/null 2>&1 && printf '%s' "$cand"
    return 0
}

# conf_check — every bad value is its own FAIL row; then one die, so the
# operator fixes the whole file in one pass.
conf_check() {
    local k v ifs devs i bad=0
    for k in $REQUIRED_KEYS; do
        v=$(conf_get "$k")
        if [ -z "$v" ]; then fail "install.conf: $k is empty — fill it from 'discover' output"; bad=1
        elif is_placeholder "$v"; then fail "install.conf: $k is a placeholder ($v) — never executed"; bad=1; fi
    done
    ifs=$(host_ifs); devs=$(host_devices)
    v=$CONF_DEVICE
    if [ -n "$v" ] && ! is_placeholder "$v" && ! has_line "$v" "$devs"; then
        fail "install.conf: DEVICE $v is not a block device on this host (lsblk)"; bad=1
    fi
    v=$CONF_MGMT_IF
    if [ -n "$v" ] && ! is_placeholder "$v" && ! has_line "$v" "$ifs"; then
        fail "install.conf: MGMT_IF $v does not exist on this host (ip -br link)"; bad=1
    fi
    for i in $CONF_CAPTURE_IFS; do
        if has_line "$i" "$ifs"; then continue; fi
        case " $LATE_IFS " in
            *" $i "*) note "CAPTURE_IFS: $i is not here yet — created by the gns3 step's labnet" ;;
            *) fail "install.conf: CAPTURE_IFS: $i does not exist on this host (ip -br link)"; bad=1 ;;
        esac
    done
    if [ -n "$CONF_LAB_BRIDGE" ] && ! has_line "$CONF_LAB_BRIDGE" "$ifs"; then
        note "LAB_BRIDGE: $CONF_LAB_BRIDGE is not here yet — created by the gns3 step's labnet"
    fi
    v=$CONF_MGMT_CIDR
    if [ -n "$v" ] && ! is_placeholder "$v" && ! [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
        fail "install.conf: MGMT_CIDR $v is not a.b.c.d/n"; bad=1
    fi
    if [ -z "$CONF_BUNDLE" ]; then
        CONF_BUNDLE=$(self_bundle)
        if [ -n "$CONF_BUNDLE" ]; then note "BUNDLE: the bundle this installer came in — $CONF_BUNDLE"
        else fail "install.conf: BUNDLE is empty and this installer is not inside a bundle — set BUNDLE=<the bundle directory on the media>"; bad=1; fi
    elif ! ( bundle_dir "$CONF_BUNDLE" ) >/dev/null 2>&1; then
        fail "install.conf: BUNDLE $CONF_BUNDLE is not a bundle (r770-bundle.sh, BUNDLE_NOTES.md, MANIFEST.sha256 at its root)"; bad=1
    else
        CONF_BUNDLE=$(cd "$CONF_BUNDLE" && pwd)
    fi
    [ "$bad" = 0 ] || die "install.conf ($CONF_PATH) refused — fix every FAIL above; nothing ran"
}

conf_ready() {
    local k; for k in $CONF_KEYS; do printf -v "CONF_$k" '%s' ""; done
    conf_load "$CONF_PATH"
    conf_check
}

# ── discover ─────────────────────────────────────────────────────────────────
cmd_discover() {
    banner "discover — what this host has (nothing is chosen for you)"
    local tpl cand
    tpl="${CONF_PATH}.template"
    echo "-- block devices (DEVICE: the transfer media's device) --"; lsblk -lpno NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || echo "   (lsblk unavailable)"
    echo "-- mounts (MEDIA: where the media is mounted) --";            findmnt -lno TARGET,SOURCE 2>/dev/null || echo "   (findmnt unavailable)"
    echo "-- interfaces (MGMT_IF; capture ports for CAPTURE_IFS) --";   ip -br addr 2>/dev/null || echo "   (ip unavailable)"
    echo "-- bridges (LAB_BRIDGE once labnet exists) --";               ip -br link show type bridge 2>/dev/null || true
    cand=$(self_bundle)
    mkdir -p "$(dirname "$tpl")" || die "cannot create $(dirname "$tpl")"
    cat > "$tpl" <<EOF
# install.conf — template written by r770-install.sh discover on $(hostname -s 2>/dev/null || echo host), $(date -Is).
# Fill in every value from the discovery output; nothing has been chosen for you.
# Save the result as $CONF_PATH (or pass --conf), then: r770-install.sh plan
#
# BUNDLE: the bundle directory. Empty means the bundle this installer came in: ${cand:-none found}
BUNDLE=
# MEDIA: where the transfer media is mounted (see "mounts" above)
MEDIA=
# DEVICE: the media's block device, e.g. a partition of the USB disk (see "block devices" above)
DEVICE=
# CAPTURE_IFS: Malcolm's capture interfaces, space separated: lab_mirror0 (the lab mirror) plus any physical tap port
CAPTURE_IFS=
# LAB_BRIDGE: the lab bridge the gns3 step's labnet creates (r770-gns3-deploy.sh: br-lab)
LAB_BRIDGE=
# MGMT_IF: the management interface (see "interfaces" above)
MGMT_IF=
# MGMT_CIDR: the management network, a.b.c.d/n
MGMT_CIDR=
# VALIDATE_AREAS: optional, space separated; empty means every area (r770-validate.sh --list)
VALIDATE_AREAS=
EOF
    pass "template written: $tpl — fill it in and save it as $CONF_PATH"
    footer "discover"
}

# ── wizard ───────────────────────────────────────────────────────────────────
# pick <prompt> <option...> — a numbered menu on stderr; echoes the choice.
# End of input is a refusal, never a default.
pick() {
    local prompt=$1; shift
    local opts=("$@") i a
    [ "${#opts[@]}" -gt 0 ] || die "nothing discovered for: $prompt — write install.conf by hand from 'discover'"
    { echo; echo "$prompt"; for i in "${!opts[@]}"; do printf '  %d) %s\n' $((i + 1)) "${opts[$i]}"; done; } >&2
    while :; do
        read -r -p "choice [1-${#opts[@]}]: " a || die "no answer for: $prompt — nothing written"
        if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#opts[@]}" ]; then printf '%s' "${opts[$((a - 1))]}"; return 0; fi
        echo "  not one of 1-${#opts[@]}" >&2
    done
}
# pick_many <prompt> <option...> — space-separated numbers, empty for none.
pick_many() {
    local prompt=$1; shift
    local opts=("$@") i a n out ok
    [ "${#opts[@]}" -gt 0 ] || return 0
    { echo; echo "$prompt"; for i in "${!opts[@]}"; do printf '  %d) %s\n' $((i + 1)) "${opts[$i]}"; done; } >&2
    while :; do
        read -r -p "numbers, space separated (empty for none): " a || die "no answer for: $prompt — nothing written"
        out=""; ok=1
        for n in $a; do
            if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#opts[@]}" ]; then out="$out ${opts[$((n - 1))]}"; else ok=0; fi
        done
        [ "$ok" = 1 ] && { printf '%s' "${out# }"; return 0; }
        echo "  each must be one of 1-${#opts[@]}" >&2
    done
}

cmd_wizard() {
    banner "wizard — pick each value from what this host has"
    [ ! -e "$CONF_PATH" ] || [ "$FORCE" = "1" ] || die "$CONF_PATH exists — edit it, or rerun with --force to replace it"
    local bundle media device mgmt addr cidr extras bridge
    local -a mounts devs mgmts others bridges
    bundle=$(self_bundle)
    [ -n "$bundle" ] || die "this installer is not inside a bundle — run the one in <media>/<bundle>/kit/scripts/, or write install.conf by hand"
    mapfile -t mounts  < <(findmnt -lno TARGET,SOURCE 2>/dev/null | awk '{print $1}')
    mapfile -t devs    < <(host_devices)
    mapfile -t mgmts   < <(ip -br addr 2>/dev/null | awk '$1 != "lo" {print $1}' | sed 's/@.*//')
    media=$(pick "MEDIA — where the transfer media is mounted:" "${mounts[@]}") || exit 1
    device=$(pick "DEVICE — the media's block device:" "${devs[@]}") || exit 1
    mgmt=$(pick "MGMT_IF — the management interface:" "${mgmts[@]}") || exit 1
    addr=$(ip -br addr 2>/dev/null | awk -v i="$mgmt" '$1 == i {print $3}')
    [ -n "$addr" ] || die "MGMT_IF $mgmt has no IPv4 address — pick the interface the box is managed through"
    cidr=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$addr") || die "cannot read a network from $addr"
    mapfile -t others  < <(printf '%s\n' "${mgmts[@]}" | grep -vxF -- "$mgmt")
    extras=$(pick_many "CAPTURE_IFS — physical tap ports to capture beside lab_mirror0:" "${others[@]}") || exit 1
    mapfile -t bridges < <({ ip -br link show type bridge 2>/dev/null | awk '{print $1}'; echo br-lab; } | awk '!seen[$0]++')
    bridge=$(pick "LAB_BRIDGE — the lab bridge (br-lab is the one the gns3 step's labnet creates):" "${bridges[@]}") || exit 1
    mkdir -p "$(dirname "$CONF_PATH")" || die "cannot create $(dirname "$CONF_PATH")"
    cat > "$CONF_PATH" <<EOF
# install.conf — written by r770-install.sh wizard on $(hostname -s 2>/dev/null || echo host), $(date -Is)
BUNDLE=$bundle
MEDIA=$media
DEVICE=$device
CAPTURE_IFS=lab_mirror0${extras:+ $extras}
LAB_BRIDGE=$bridge
MGMT_IF=$mgmt
MGMT_CIDR=$cidr
VALIDATE_AREAS=
EOF
    pass "written: $CONF_PATH — next: r770-install.sh plan"
    footer "wizard"
}

# ── run ──────────────────────────────────────────────────────────────────────
LOGDIR=""; CUR=""
local_bundle() {  # after import's copy, the bundle lives under /srv/bundles
    local l; l="$(p /srv/bundles)/$(basename "$CONF_BUNDLE")"
    if [ -d "$l" ]; then printf '%s' "$l"; else printf '%s' "$CONF_BUNDLE"; fi
}
summary_row() {  # summary_row <step> <PASS|WARN|FAIL> <detail>
    printf '| %s | %s | %s |\n' "$1" "$2" "$3" >> "$LOGDIR.md"
}
summary_open() {
    [ -s "$LOGDIR.md" ] && return 0
    {
        echo "# Install — $(hostname -s 2>/dev/null || echo host) — $(date -Is)"
        echo
        echo "Bundle: \`$CONF_BUNDLE\` · answers: \`$CONF_PATH\` · each step's output: \`$LOGDIR/\`"
        echo
        echo "| Step | Verdict | Detail |"
        echo "|---|---|---|"
    } > "$LOGDIR.md"
}
# logged <name> <cmd...> — a child's output to the terminal and to $LOGDIR/<name>.log
# shellcheck disable=SC2317  # reached only through run_step "$@", which shellcheck cannot follow
logged() {
    local name=$1; shift
    "$@" 2>&1 | tee -a "$LOGDIR/$name.log"
    return "${PIPESTATUS[0]}"
}
on_exit() {
    local rc=$? why
    [ -n "$CUR" ] || return 0
    why="see $LOGDIR/$CUR*.log"
    [ "$rc" = 130 ] && why="interrupted"
    summary_row "$CUR" FAIL "$why — fix it, then: r770-install.sh run --yes --from $CUR"
    printf '\nNOT INSTALLED — %s at %s; rerun with --from %s\n' "$why" "$CUR" "$CUR" >> "$LOGDIR.md"
}
step_body() {  # step_body <step> — the children of one step
    local lb s a; lb=$(local_bundle)
    local -a args
    case "$1" in
        import)
                 run_step import logged import-preflight "$IMPORT" preflight --bundle "$CONF_BUNDLE"
                 run_step import logged import-gate "$IMPORT" gate --bundle "$CONF_BUNDLE" --media "$CONF_MEDIA" --device "$CONF_DEVICE"
                 # no --media: copy would unmount it, and this script is running from it
                 run_step import logged import-copy "$IMPORT" copy --bundle "$CONF_BUNDLE" ;;
        gns3)    run_step gns3 logged gns3 "$GNS3" full --bundle "$lb" ;;
        malcolm) run_step malcolm logged malcolm "$MALCOLM" full --bundle "$lb" --capture-ifs "$CONF_CAPTURE_IFS" ;;
        docs)    run_step docs logged docs "$DOCS" full --bundle "$lb" ;;
        portal)  for s in ca cert htpasswd nginx; do run_step portal logged "portal-$s" "$PORTAL" "$s"; done ;;
        dashboards)
                 run_step dashboards logged dashboards "$MALCOLM" dashboards
                 run_step dashboards logged arkime-views "$MALCOLM" arkime-views ;;
        validate)
                 args=(--capture-ifs "$CONF_CAPTURE_IFS" --lab-bridge "$CONF_LAB_BRIDGE" --mgmt-if "$CONF_MGMT_IF" --mgmt-cidr "$CONF_MGMT_CIDR")
                 for a in $CONF_VALIDATE_AREAS; do args+=(--area "$a"); done
                 run_step validate logged validate "$VALIDATE" "${args[@]}" --out "$LOGDIR" ;;
        e2e)     run_step e2e logged e2e "$E2E" --bundle "$lb" --capture-ifs "$CONF_CAPTURE_IFS" --lab-bridge "$CONF_LAB_BRIDGE" --skip-validate --out "$LOGDIR" ;;
    esac
}
# handoff <next-step> — carry on in the local copy's own installer, so
# nothing holds the media (bash marks its script descriptor close-on-exec).
handoff() {
    local next=$1 me there
    local -a args
    there="$(p /srv/bundles)/$(basename "$CONF_BUNDLE")/kit/scripts/r770-install.sh"
    me="$(cd "$KIT_DIR/scripts" && pwd -P)/r770-install.sh"
    [ -x "$there" ] || die "the copied bundle has no kit/scripts/r770-install.sh — it was cut without the kit (set KIT_SRC_ROOT at cut time); cut again, or run the pipelines by hand"
    [ "$(cd "$(dirname "$there")" && pwd -P)/r770-install.sh" = "$me" ] && return 0
    args=(run --from "$next" --conf "$CONF_PATH")
    [ -n "$TO" ] && args+=(--to "$TO")
    [ "${KIT_YES:-0}" = "1" ] && args+=(--yes)
    [ "${KIT_NON_INTERACTIVE:-0}" = "1" ] && args+=(--non-interactive)
    note "handing off to the local copy: $there ${args[*]}"
    export INSTALL_LOGDIR="$LOGDIR"
    trap - EXIT
    exec "$there" "${args[@]}"
}
cmd_run() {
    need_root
    conf_ready
    local first=0 last=$(( ${#STEPS[@]} - 1 )) i step verdict rc=0 warned
    [ -z "$FROM" ] || first=$(step_index STEPS "$FROM") || die "unknown step: $FROM (steps: ${STEPS[*]})"
    [ -z "$TO" ]   || last=$(step_index STEPS "$TO")    || die "unknown step: $TO (steps: ${STEPS[*]})"
    [ "$first" -le "$last" ] || die "--from $FROM comes after --to $TO"
    if [ "${KIT_YES:-0}" = "1" ]; then KIT_NON_INTERACTIVE=1; export KIT_NON_INTERACTIVE; fi
    LOGDIR="${INSTALL_LOGDIR:-${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}/install-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S)}"
    mkdir -p "$LOGDIR" || die "cannot create $LOGDIR"
    summary_open
    trap on_exit EXIT
    trap 'exit 130' INT TERM
    WARNED_STEPS=""
    for i in $(seq "$first" "$last"); do
        step=${STEPS[$i]}
        banner "$(( i + 1 ))/${#STEPS[@]}  $step"
        CUR=$step
        step_body "$step"
        case " $WARNED_STEPS " in
            *" $step "*) summary_row "$step" WARN "warnings accepted via --yes — disposition each ($LOGDIR/$step*.log)" ;;
            *)           summary_row "$step" PASS "clean" ;;
        esac
        stamp "install.$step"
        CUR=""
        if [ "$step" = import ] && [ "$i" -lt "$last" ]; then handoff "${STEPS[$((i + 1))]}"; fi
    done
    on_exit   # a no-op here (no step is running); the EXIT trap does the same for a run cut short
    # shellcheck disable=SC2086  # word-split the space-separated step list on purpose
    warned=$(printf '%s\n' $WARNED_STEPS | awk 'NF && !seen[$0]++' | tr '\n' ' ')
    if [ -n "$warned" ]; then verdict="NOT INSTALLED — finished with warnings from: ${warned% }; disposition each, then rerun with --from <step>"; rc=2
    elif [ "$last" -lt $(( ${#STEPS[@]} - 1 )) ]; then verdict="steps ${STEPS[$first]}..${STEPS[$last]} clean — not INSTALLED until e2e has run"
    else verdict="INSTALLED — every step clean and the lab proven end to end"; fi
    { echo; echo "$verdict"; echo; echo "Last step for the operator: remove the media — umount ${CONF_MEDIA}"; } >> "$LOGDIR.md"
    echo; echo "$verdict"; note "summary: $LOGDIR.md"; note "remove the media: umount ${CONF_MEDIA}"
    exit "$rc"
}

# ── status ───────────────────────────────────────────────────────────────────
cmd_status() {
    banner "status — the installer's steps on this host"
    local s
    for s in "${STEPS[@]}"; do
        if stamped "install.$s"; then printf '  %-11s done (%s)\n' "$s" "$(cat "$STAMP_DIR/install.$s")"
        else printf '  %-11s not yet\n' "$s"; fi
    done
    footer "status"
}

# ── arguments ────────────────────────────────────────────────────────────────
[ $# -gt 0 ] || usage
SUB=$1; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --conf)     CONF_PATH="${2:-}"; shift ;;
        --from)     FROM="${2:-}"; shift ;;
        --to)       TO="${2:-}"; shift ;;
        -h|--help)  usage ;;
        *)          common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
CONF_PATH="${CONF_PATH:-$(p /etc/lab/install.conf)}"

kit_init "r770-install"
case "$SUB" in
    discover) cmd_discover ;;
    wizard)   cmd_wizard ;;
    run)      cmd_run ;;
    status)   cmd_status ;;
    -h|--help|help) usage ;;
    *)        die "unknown subcommand: $SUB (try --help)" ;;
esac
