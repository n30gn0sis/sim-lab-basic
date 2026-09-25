#!/usr/bin/env bash
#
# r770-scenario.sh — run a scenario from the kit's pack: a GNS3 project built
# only from bundled images, brought up, driven with known traffic for a known
# window, and torn down. Each scenario puts one link on br-lab through two
# kit TAPs (GNS3 Cloud nodes, TAP type), so with the live mirror feed on its
# traffic reaches Malcolm.
#
#   r770-scenario.sh <subcommand> [<name>] [options]
#
#   list            the pack, and which scenarios this bundle can run
#   up <name>       import the project into GNS3, start its nodes, apply each
#                   node's config with docker exec, wait until it is ready
#   traffic <name>  run the scenario's traffic for its window; write a run
#                   record (UTC start/end, range, TAPs) under r770-evidence/
#   down <name>     stop and delete the imported project (idempotent)
#   status          which scenarios are up, their TAPs, their last run record
#
#   --bundle <dir>  the bundle (list, up): image references are read from its
#                   gns3/docker-nodes/image-list.txt, never typed here
#   --taps a,b      up: the two kit TAPs to bind (default: two free ones)
#   --force         up: take an existing copy down first
#   --yes / --non-interactive / --dry-run   as everywhere in the kit
#
#   SCENARIO_WAIT_SECS 120 · SCENARIO_TRAFFIC_SECS (default: the scenario's
#   traffic_secs) · GNS3_LAB_TAPS 4 · GNS3_ADMIN_USER admin
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# Not gated: it creates and deletes only GNS3 projects it imported itself --
# named lab-scenario-<name> AND carrying the project variable
# r770_scenario=<name> -- and the containers GNS3 made for them. There is no
# jq on the box; JSON is read with python3, which Malcolm's installer already
# needs. The admin credential never reaches argv or the transcript.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SCEN_DIR="${SCENARIO_DIR:-$KIT_DIR/scenarios}"
ADMIN_USER="${GNS3_ADMIN_USER:-admin}"
SECRET="/etc/lab/secrets/gns3-admin.pw"
MARKER="r770_scenario"
BUNDLE=""; NAME=""; WORK=""; AUTH_HDR=""
usage() { usage_from_header 3; exit 0; }

# ── the pack ─────────────────────────────────────────────────────────────────
# py <program> — run a python3 program over JSON read from stdin as `d`
py() { python3 -c "import json, sys; d = json.load(sys.stdin)
$1"; }
conf() { sed -n "s/^$2=//p" "$SCEN_DIR/$1/scenario.conf" | head -1; }  # conf <scenario> <key>
scenario_check() {  # scenario_check <name> — refuse a malformed or unknown name
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "'$1' is not a scenario name"
    [ -f "$SCEN_DIR/$1/scenario.conf" ] || die "no scenario '$1' in $SCEN_DIR (see: r770-scenario.sh list)"
}
img_token() { printf 'IMG_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; }
# image_ref <bundle> <basename> — the full reference, or non-zero. A subshell:
# image_ref_from_list dies (exits) when the name is absent.
image_ref() { ( image_ref_from_list "$1/gns3/docker-nodes/image-list.txt" "$2" ) 2>/dev/null; }
missing_images() {  # missing_images <bundle> <scenario> — basenames the bundle's list lacks
    local i miss=""
    for i in $(conf "$2" images); do image_ref "$1" "$i" >/dev/null || miss="$miss $i"; done
    printf '%s' "${miss# }"
}
ike_hint() { case " $1 " in *" strongswan "*) printf ' — strongSwan arrives with the next bundle cut' ;; esac; }

# ── the GNS3 API ─────────────────────────────────────────────────────────────
cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK"; fi; return 0; }
work() { if [ -z "$WORK" ]; then WORK=$(mktemp -d); trap cleanup EXIT; fi; }
gns3_login() {
    work
    curl -sS --max-time 5 --fail http://127.0.0.1:3080/v3/version >/dev/null 2>&1 \
        || die "GNS3 does not answer on 127.0.0.1:3080 — start it: r770-gns3-deploy.sh service"
    [ -s "$(p "$SECRET")" ] || die "no GNS3 admin credential at $SECRET — run r770-gns3-deploy.sh secrets and config"
    local body="$WORK/login.json" tok
    ( umask 077
      python3 -c 'import json, sys; print(json.dumps({"username": sys.argv[1], "password": open(sys.argv[2]).readline().strip()}))' \
          "$ADMIN_USER" "$(p "$SECRET")" > "$body" )
    tok=$(curl -sS --max-time 10 --fail -X POST -H 'Content-Type: application/json' --data @"$body" http://127.0.0.1:3080/v3/access/users/login 2>/dev/null \
          | py 'print(d["access_token"])' 2>/dev/null) \
        || die "GNS3 refused the admin login — rerun r770-gns3-deploy.sh config, then restart the unit"
    rm -f "$body"
    AUTH_HDR="$WORK/auth.hdr"
    ( umask 077; printf 'Authorization: Bearer %s\n' "$tok" > "$AUTH_HDR" )
}
api() {  # api <METHOD> <path> [extra args...] — response body on stdout; non-zero on any HTTP error
    local m=$1 path=$2; shift 2
    curl -sS --max-time 60 --fail -X "$m" -H @"$AUTH_HDR" "$@" "http://127.0.0.1:3080/v3$path"
}
call() {  # call <METHOD> <path> [extra args...] — shown, then made (only shown under --dry-run)
    if [ "$DRY" = "1" ]; then echo "DRY-RUN: $1 $2"; return 0; fi
    echo "+ $1 $2"
    api "$@" >/dev/null
}
our_project() {  # our_project <scenario> — our copy's project id; empty if none; FOREIGN if the name is taken
    api GET /projects | py "
for p in d:
    if p.get('name') != 'lab-scenario-$1':
        continue
    ours = any(v.get('name') == '$MARKER' and v.get('value') == '$1' for v in (p.get('variables') or []))
    print(p['project_id'] if ours else 'FOREIGN')
    break"
}
nodes() {  # nodes <pid> — TSV: name, node_type, status, container_id, comma-joined TAP interfaces
    api GET "/projects/$1/nodes" | py "
for n in d:
    pr = n.get('properties') or {}
    taps = ','.join(m.get('interface', '') for m in (pr.get('ports_mapping') or []) if m.get('type') == 'tap')
    print('\t'.join([n.get('name', ''), n.get('node_type', ''), n.get('status', ''), pr.get('container_id') or '', taps]))"
}
container_of() {  # container_of <nodes-tsv> <node> — its container id, or die
    local c; c=$(awk -F'\t' -v n="$2" '$1 == n {print $4}' "$1")
    [ -n "$c" ] || die "GNS3 reports no container for node $2 — is it a docker node, and did it start?"
    printf '%s' "$c"
}
take_down() {  # take_down <pid>
    call POST "/projects/$1/nodes/stop" || warn "stopping the nodes reported an error — deleting the project anyway"
    call DELETE "/projects/$1" || die "GNS3 refused to delete project $1"
}

# ── list ─────────────────────────────────────────────────────────────────────
cmd_list() {
    banner "scenario pack ($SCEN_DIR)"
    local c n b="" miss
    if [ -n "$BUNDLE" ]; then b=$(bundle_dir "$BUNDLE") || exit 1; fi
    for c in "$SCEN_DIR"/*/scenario.conf; do
        [ -e "$c" ] || continue
        n=$(basename "$(dirname "$c")")
        printf '%-16s %-16s %s\n' "$n" "$(conf "$n" range)" "$(conf "$n" description)"
        if [ -z "$b" ]; then note "images: $(conf "$n" images) (pass --bundle to check them)"; continue; fi
        miss=$(missing_images "$b" "$n")
        if [ -z "$miss" ]; then note "runnable with this bundle"
        else note "NOT runnable: missing $miss$(ike_hint "$miss")"; fi
    done
    return 0
}

# ── down ─────────────────────────────────────────────────────────────────────
cmd_down() {
    banner "down — $NAME"
    need_root
    scenario_check "$NAME"
    gns3_login
    local pid
    pid=$(our_project "$NAME") || die "could not list GNS3 projects"
    case "$pid" in
        "")      pass "$NAME is not running"; footer "down" ;;
        FOREIGN) die "the project named lab-scenario-$NAME has no kit marker ($MARKER) — not ours, left alone" ;;
    esac
    take_down "$pid"
    pass "$NAME taken down (project lab-scenario-$NAME deleted; its TAPs are free)"
    footer "down"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
SUB="${1:-}"; [ $# -gt 0 ] && shift
case "$SUB" in
    up|traffic|down) case "${1:-}" in -*|"") ;; *) NAME=$1; shift ;; esac ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-scenario"
case "$SUB" in
    list) cmd_list ;;
    down)
        [ -n "$NAME" ] || die "$SUB needs a scenario name (see: r770-scenario.sh list)"
        cmd_down ;;
    -h|--help|help|"") usage ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
