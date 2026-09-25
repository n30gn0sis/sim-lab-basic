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
WAIT_SECS="${SCENARIO_WAIT_SECS:-120}"
LAB_TAPS="${GNS3_LAB_TAPS:-4}"
TAPS=""; TAP_A=""; TAP_B=""
usage() { usage_from_header 3; exit 0; }

# ── the pack ─────────────────────────────────────────────────────────────────
# py <program> — run a python3 program over JSON read from stdin as `d`
py() { python3 -c "import json, re, sys; d = json.load(sys.stdin)
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
our_project_state() {  # our_project_state <scenario> — "<id> <status>" of our copy; empty if none; FOREIGN if the name is taken
    api GET /projects | py "
for p in d:
    if p.get('name') != 'lab-scenario-$1':
        continue
    ours = any(v.get('name') == '$MARKER' and v.get('value') == '$1' for v in (p.get('variables') or []))
    print(p['project_id'] + ' ' + (p.get('status') or '') if ours else 'FOREIGN')
    break"
}
our_project() {  # our_project <scenario> — our copy's project id; empty if none; FOREIGN if the name is taken
    local st; st=$(our_project_state "$1") || return 1
    printf '%s' "${st%% *}"
}
nodes() {  # nodes <pid> — TSV: name, node_type, status, container_id, comma-joined kit TAPs (lab-tapN) its ports bind, whatever the port type
    api GET "/projects/$1/nodes" | py "
for n in d:
    pr = n.get('properties') or {}
    taps = ','.join(m.get('interface', '') for m in (pr.get('ports_mapping') or []) if re.fullmatch(r'lab-tap[0-9]+', m.get('interface') or ''))
    print('\t'.join([n.get('name', ''), n.get('node_type', ''), n.get('status', ''), pr.get('container_id') or '', taps]))"
}
container_of() {  # container_of <nodes-tsv> <node> — its container id, or die
    local c; c=$(awk -F'\t' -v n="$2" '$1 == n {print $4}' "$1")
    [ -n "$c" ] || die "GNS3 reports no container for node $2 — is it a docker node, and did it start? — r770-scenario.sh down $NAME"
    printf '%s' "$c"
}
take_down() {  # take_down <pid>
    call POST "/projects/$1/nodes/stop" || warn "stopping the nodes reported an error — deleting the project anyway"
    call DELETE "/projects/$1" || die "GNS3 refused to delete project $1"
}

# ── up ───────────────────────────────────────────────────────────────────────
taps_in_use() {  # taps_in_use — "<tap> <project-name>" for every kit TAP a node of an opened project holds
    local pid pname
    api GET /projects | py "
for p in d:
    if p.get('status') == 'opened':
        print(p['project_id'] + '\t' + p.get('name', ''))" |
    while IFS=$'\t' read -r pid pname; do
        nodes "$pid" | awk -F'\t' -v p="$pname" '$5 != "" { n = split($5, t, ","); for (i = 1; i <= n; i++) print t[i], p }'
    done
}
pick_taps() {  # pick_taps — sets TAP_A and TAP_B: --taps, or the first two free kit TAPs
    local used t i cand="" holder extra=""
    used=$(taps_in_use) || die "could not ask GNS3 which TAPs are in use"
    if [ -n "$TAPS" ]; then
        IFS=, read -r TAP_A TAP_B extra <<< "$TAPS"
        if [ -z "$TAP_A" ] || [ -z "$TAP_B" ] || [ -n "$extra" ] || [ "$TAP_A" = "$TAP_B" ]; then
            die "--taps takes two different kit TAPs, e.g. --taps lab-tap0,lab-tap1"
        fi
        for t in "$TAP_A" "$TAP_B"; do
            [[ "$t" =~ ^lab-tap[0-9]+$ ]] || die "$t is not a kit TAP (lab-tapN, created by r770-gns3-deploy.sh labnet)"
            [ -e "$(p /sys/class/net)/$t" ] || die "$t does not exist — run r770-gns3-deploy.sh labnet"
            holder=$(printf '%s\n' "$used" | awk -v t="$t" '$1 == t {print $2; exit}')
            [ -z "$holder" ] || die "$t is held by GNS3 project $holder"
        done
        return 0
    fi
    for ((i = 0; i < LAB_TAPS; i++)); do
        t="lab-tap$i"
        [ -e "$(p /sys/class/net)/$t" ] || continue
        printf '%s\n' "$used" | awk -v t="$t" '$1 == t {f = 1} END {exit !f}' && continue
        cand="$cand $t"
    done
    read -r TAP_A TAP_B _ <<< "$cand"
    if [ -z "$TAP_B" ]; then
        holder=$(printf '%s\n' "$used" | awk 'NF {print $2}' | sort -u | tr '\n' ' ')
        die "fewer than two free kit TAPs (held by: ${holder:-nothing — create them with r770-gns3-deploy.sh labnet})"
    fi
}
render_project() {  # render_project <scenario> <bundle> <out.gns3> <pid>
    local s=$1 b=$2 out=$3 pid=$4 i
    local -a kv=()
    for i in $(conf "$s" images); do kv+=("$(img_token "$i")=$(image_ref "$b" "$i")"); done
    DRY=0 render "$SCEN_DIR/$s/project/$s.gns3" "$out" "${kv[@]}" \
        "TAP_A=$TAP_A" "TAP_B=$TAP_B" "PROJECT_NAME=lab-scenario-$s" "PROJECT_ID=$pid" "SCENARIO=$s" >/dev/null
}
wait_started() {  # wait_started <pid> — every docker node reports started; writes $WORK/nodes.tsv
    local waited=0 st
    while :; do
        nodes "$1" > "$WORK/nodes.tsv" || die "could not read the project's nodes"
        st=$(awk -F'\t' '$2 == "docker" && $3 != "started" {print $1}' "$WORK/nodes.tsv" | tr '\n' ' ')
        if [ -z "$st" ]; then pass "every node started"; return 0; fi
        if [ "$waited" -ge "$WAIT_SECS" ]; then fail "not started after ${WAIT_SECS}s: ${st% }"; return 1; fi
        sleep 2; waited=$((waited + 2))
    done
}
configure_nodes() {  # configure_nodes <scenario> — feed each node its files, addresses first
    local s=$1 kind f base node cid
    for kind in sh frr.conf swanctl.conf; do
        for f in "$SCEN_DIR/$s/nodes"/*."$kind"; do
            [ -e "$f" ] || continue
            base=$(basename "$f"); node=${base%%.*}
            cid=$(container_of "$WORK/nodes.tsv" "$node") || exit 1
            case "$kind" in
                sh)           run docker exec -i "$cid" sh -s < "$f" ;;
                # the daemons may still be starting: retry the apply (idempotent) for up to ~30s
                frr.conf)     run docker exec -i "$cid" sh -c 'cat > /tmp/lab-frr.conf && i=0; until vtysh -f /tmp/lab-frr.conf; do i=$((i+1)); [ "$i" -ge 15 ] && exit 1; sleep 2; done' < "$f" ;;
                swanctl.conf) run docker exec -i "$cid" sh -c 'mkdir -p /etc/swanctl && cat > /etc/swanctl/swanctl.conf && i=0; until swanctl --load-all; do i=$((i+1)); [ "$i" -ge 15 ] && exit 1; sleep 2; done' < "$f" ;;
            esac || die "configuring $node from $base failed — the nodes are left running for inspection; when done: r770-scenario.sh down $s"
            note "$node configured from $base"
        done
    done
}
ready_check() {  # ready_check <scenario> [<limit-secs>] — the scenario's ready command, retried
    local s=$1 limit=${2:-$WAIT_SECS} spec node cmd cid waited=0
    spec=$(conf "$s" ready); node=${spec%%|*}; cmd=${spec#*|}
    if [ -z "$node" ] || [ -z "$cmd" ] || [ "$node" = "$spec" ]; then die "scenario $s has no ready=<node>|<command> line"; fi
    cid=$(container_of "$WORK/nodes.tsv" "$node") || exit 1
    while :; do
        if docker exec "$cid" sh -c "$cmd" >/dev/null 2>&1; then pass "ready: $node: $cmd"; return 0; fi
        [ "$waited" -ge "$limit" ] && return 1
        sleep 2; waited=$((waited + 2))
    done
}
cmd_up() {
    banner "up — $NAME"
    need_root
    scenario_check "$NAME"
    local b miss i ref loaded pid
    b=$(bundle_dir "$BUNDLE") || exit 1
    miss=$(missing_images "$b" "$NAME")
    [ -z "$miss" ] || die "image(s) not in this bundle's gns3/docker-nodes/image-list.txt: $miss$(ike_hint "$miss")"
    loaded=$(docker_loaded_images)
    for i in $(conf "$NAME" images); do
        ref=$(image_ref "$b" "$i")
        printf '%s\n' "$loaded" | grep -qxF "$(image_norm "$ref")" || die "$ref is not loaded — run r770-gns3-deploy.sh load --bundle <dir>"
    done
    gns3_login
    pid=$(our_project "$NAME") || die "could not list GNS3 projects"
    [ "$pid" != "FOREIGN" ] || die "a GNS3 project named lab-scenario-$NAME exists without the kit's marker ($MARKER) — not ours; rename or remove it by hand"
    if [ -n "$pid" ]; then
        [ "$FORCE" = "1" ] || die "$NAME is already up (project lab-scenario-$NAME) — r770-scenario.sh down $NAME, or up --force"
        take_down "$pid"
    fi
    pick_taps
    note "taps: $TAP_A $TAP_B"
    pid=$(python3 -c 'import uuid; print(uuid.uuid4())')
    render_project "$NAME" "$b" "$WORK/project.gns3" "$pid"
    python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED); z.write(sys.argv[2], "project.gns3"); z.close()' \
        "$WORK/project.zip" "$WORK/project.gns3" || die "could not build the project archive"
    call POST "/projects/$pid/import?name=lab-scenario-$NAME" -H 'Content-Type: application/octet-stream' --data-binary @"$WORK/project.zip" \
        || die "GNS3 refused the import — nothing was started"
    call POST "/projects/$pid/open" || die "GNS3 could not open the imported project — r770-scenario.sh down $NAME"
    call POST "/projects/$pid/nodes/start" || die "starting the nodes failed — r770-scenario.sh down $NAME"
    [ "$DRY" = "1" ] && footer "up"
    if ! wait_started "$pid"; then
        note "the nodes are left as they are for inspection — when done: r770-scenario.sh down $NAME"
        footer "up"
    fi
    configure_nodes "$NAME"
    if ! ready_check "$NAME"; then
        fail "$NAME did not become ready within ${WAIT_SECS}s ($(conf "$NAME" ready))"
        note "the nodes are left running for inspection — when done: r770-scenario.sh down $NAME"
    fi
    footer "up"
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

# ── traffic ──────────────────────────────────────────────────────────────────
cmd_traffic() {
    banner "traffic — $NAME"
    need_root
    scenario_check "$NAME"
    gns3_login
    local pid secs start end n cid taps rec ok=0 okn="" badn=""
    pid=$(our_project "$NAME") || die "could not list GNS3 projects"
    if [ -z "$pid" ] || [ "$pid" = "FOREIGN" ]; then die "$NAME is not up — r770-scenario.sh up $NAME --bundle <dir>"; fi
    nodes "$pid" > "$WORK/nodes.tsv" || die "could not read the project's nodes"
    ready_check "$NAME" 0 || die "$NAME is up but not ready ($(conf "$NAME" ready)) — nothing was generated"
    secs=${SCENARIO_TRAFFIC_SECS:-$(conf "$NAME" traffic_secs)}
    case "$secs" in ''|*[!0-9]*) die "the traffic window must be whole seconds (got '$secs')" ;; esac
    taps=$(awk -F'\t' '$5 != "" {print $5}' "$WORK/nodes.tsv" | paste -sd, -)
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for n in $(conf "$NAME" traffic_nodes); do
        cid=$(container_of "$WORK/nodes.tsv" "$n") || exit 1
        if run docker exec -i "$cid" sh -s "$n" "$secs" < "$SCEN_DIR/$NAME/traffic.sh"; then
            ok=$((ok + 1)); okn="$okn $n"
        else
            badn="$badn $n"
        fi
    done
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ "$DRY" != "1" ]; then
        rec="${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}/scenario-$NAME-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).run"
        mkdir -p "$(dirname "$rec")"
        {
            echo "scenario=$NAME"
            echo "range=$(conf "$NAME" range)"
            echo "project=lab-scenario-$NAME"
            echo "taps=$taps"
            echo "start=$start"
            echo "end=$end"
            echo "secs=$secs"
            echo "nodes_ok=$ok"
            echo "nodes_failed=$(printf '%s' "$badn" | wc -w)"
            echo "expect=scenarios/$NAME/expect.txt"
        } > "$rec"
        note "run record: $rec"
    fi
    if [ -z "$badn" ]; then pass "traffic ran in every node:$okn"
    elif [ "$ok" -gt 0 ]; then warn "traffic failed in:$badn (ran in:$okn)"
    else fail "no traffic generator ran (failed in:$badn)"; fi
    footer "traffic"
}

# ── status ───────────────────────────────────────────────────────────────────
cmd_status() {
    banner "scenario status"
    local c n st state taps last live=0 ev="${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}"
    if curl -sS --max-time 5 --fail http://127.0.0.1:3080/v3/version >/dev/null 2>&1 && [ -s "$(p "$SECRET")" ]; then
        gns3_login; live=1
    else
        note "GNS3 is not answering on 127.0.0.1:3080 (or there is no admin credential) — running state unknown"
    fi
    for c in "$SCEN_DIR"/*/scenario.conf; do
        [ -e "$c" ] || continue
        n=$(basename "$(dirname "$c")"); state="unknown"; taps="-"
        if [ "$live" = "1" ]; then
            # a failed lookup is unobserved, not "down"; only an opened project is up
            if st=$(our_project_state "$n" 2>/dev/null); then
                case "$st" in
                    "")        state="down" ;;
                    FOREIGN)   state="name-taken" ;;
                    *" opened") state="up"; taps=$(nodes "${st%% *}" 2>/dev/null | awk -F'\t' '$5 != "" {print $5}' | paste -sd, -) ;;
                    *)         state="closed" ;;
                esac
            fi
        fi
        last=$(find "$ev" -maxdepth 1 -name "scenario-$n-*.run" 2>/dev/null | sort | tail -1)
        printf '%-16s %-10s taps %-26s last run %s\n' "$n" "$state" "${taps:--}" "${last:-none}"
    done
    return 0
}

# ── dispatch ─────────────────────────────────────────────────────────────────
SUB="${1:-}"; [ $# -gt 0 ] && shift
case "$SUB" in
    up|traffic|down) case "${1:-}" in -*|"") ;; *) NAME=$1; shift ;; esac ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        --taps)    TAPS="${2:-}"; shift ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-scenario"
case "$SUB" in
    list) cmd_list ;;
    up|traffic|down)
        [ -n "$NAME" ] || die "$SUB needs a scenario name (see: r770-scenario.sh list)"
        "cmd_$SUB" ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
