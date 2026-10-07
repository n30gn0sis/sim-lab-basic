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
#   record <name>   traffic, captured: outer on the first kit TAP, inner in
#                   each inner_capture node's netns, an idle tail, and a run
#                   directory (run.conf, drop stats, sha256sums)
#   verify <run-dir> judge a finished run directory with tshark: every row of
#                   the scenario's pcap-expect.txt, decryption (only with
#                   discovered keys), zero kernel drops; writes expected.md
#   down <name>     stop and delete the imported project (idempotent)
#   status          which scenarios are up, their TAPs, their last run record
#   check <name>    judge the newest traffic run in Malcolm: every expect.txt
#                   row must show sessions in Arkime within the run's window
#
#   --bundle <dir>  the bundle (list, up): image references are read from its
#                   gns3/docker-nodes/image-list.txt, never typed here
#   --taps a,b      up: the two kit TAPs to bind (default: two free ones)
#   --force         up: take an existing copy down first
#   --run <file>    check: judge this run record instead of the newest
#   --impair <profile>@a|b   record: shape TAP_A or TAP_B with a WAN profile
#                   (r770-wan.sh) once the captures are open; repeatable
#   --events <file> record: t|action|arg lines run from traffic start, each
#                   logged to events.log (note, wan-apply <profile>@a|b,
#                   wan-clear a|b, link-down a|b, link-up a|b, exec <node>|<cmd>)
#   --yes / --non-interactive / --dry-run   as everywhere in the kit
#
#   SCENARIO_WAIT_SECS 120 · SCENARIO_CHECK_WAIT_SECS (default: this Malcolm's
#   PCAP_ROTATE_MINUTES*60+180, else 180) · SCENARIO_TRAFFIC_SECS (default: the
#   scenario's traffic_secs) · GNS3_LAB_TAPS 4 · GNS3_ADMIN_USER admin ·
#   SCENARIO_CASES_DIR /data/pcap/cases · SCENARIO_CASES_MIN_FREE_MB 10240
#
# record is traffic with captures, an idle tail and a run directory under
# SCENARIO_CASES_DIR; its EXIT trap stops the event scheduler and every
# capture, clears every qdisc it applied and brings up every link an event
# took down. Nothing under the cases directory is ever deleted.
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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/expect.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/expect.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/malcolm-api.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/malcolm-api.sh"

SCEN_DIR="${SCENARIO_DIR:-$KIT_DIR/scenarios}"
ADMIN_USER="${GNS3_ADMIN_USER:-admin}"
SECRET="/etc/lab/secrets/gns3-admin.pw"
MARKER="r770_scenario"
# lab-mon0: the kit's own veth end enslaved to br-lab (created by
# r770-gns3-deploy.sh labnet); its peer lab_mirror0 is Malcolm's capture end.
LAB_MON="lab-mon0"
BUNDLE=""; NAME=""; WORK=""; AUTH_HDR=""
WAIT_SECS="${SCENARIO_WAIT_SECS:-120}"
LAB_TAPS="${GNS3_LAB_TAPS:-4}"
TAPS=""; TAP_A=""; TAP_B=""; RUN_FILE=""
ROTATE_MIN=""  # PCAP_ROTATE_MINUTES, once check_wait_secs has read it; empty otherwise
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
    # /authenticate takes JSON; /login is OAuth2 and wants a form body (422 on
    # JSON) -- measured on staging VM 9770 against the bundled gns3-server
    tok=$(curl -sS --max-time 10 --fail -X POST -H 'Content-Type: application/json' --data @"$body" http://127.0.0.1:3080/v3/access/users/authenticate 2>/dev/null \
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
                # write the file, and only then retry the apply (idempotent) for up to ~30s: the daemons may still be starting.
                # vtysh -f exits 0 while skipping a daemon not yet connected (ospfd lost r3's config that way), so wait for
                # watchfrr to report every daemon it manages Up before applying
                frr.conf)     run docker exec -i "$cid" sh -c 'cat > /tmp/lab-frr.conf && { i=0; until wf=$(vtysh -c "show watchfrr" 2>/dev/null | grep "^  [a-z]") && ! printf "%s\n" "$wf" | grep -qv " Up *$" && vtysh -f /tmp/lab-frr.conf; do i=$((i+1)); [ "$i" -ge 15 ] && exit 1; sleep 2; done; }' < "$f" ;;
                swanctl.conf) run docker exec -i "$cid" sh -c 'mkdir -p /etc/swanctl && cat > /etc/swanctl/swanctl.conf && { i=0; until swanctl --load-all; do i=$((i+1)); [ "$i" -ge 15 ] && exit 1; sleep 2; done; }' < "$f" ;;
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
        printf '%-16s %-36s %s\n' "$n" "$(conf "$n" range)" "$(conf "$n" description)"
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
run_traffic() {  # run_traffic <scenario> <nodes.tsv> <secs> — traffic.sh in every traffic node; sets T_OK T_OKN T_BADN
    local n cid; T_OK=0; T_OKN=""; T_BADN=""
    for n in $(conf "$1" traffic_nodes); do
        cid=$(container_of "$2" "$n") || exit 1
        if run docker exec -i "$cid" sh -s "$n" "$3" < "$SCEN_DIR/$1/traffic.sh"; then T_OK=$((T_OK + 1)); T_OKN="$T_OKN $n"; else T_BADN="$T_BADN $n"; fi
    done
}
write_run_record() {  # write_run_record <start> <end> <secs> <ok> <badn> <taps> [<run-dir>] — the pack's .run record
    [ "$DRY" = "1" ] && return 0
    local rec
    rec="${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}/scenario-$NAME-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).run"
    mkdir -p "$(dirname "$rec")"
    {
        echo "scenario=$NAME"; echo "range=$(conf "$NAME" range)"; echo "project=lab-scenario-$NAME"
        echo "taps=$6"; echo "start=$1"; echo "end=$2"; echo "secs=$3"
        echo "nodes_ok=$4"; echo "nodes_failed=$(printf '%s' "$5" | wc -w)"
        echo "expect=scenarios/$NAME/expect.txt"
        if [ -n "${7:-}" ]; then echo "case=$7"; fi
    } > "$rec"
    note "run record: $rec"
}
cmd_traffic() {
    banner "traffic — $NAME"
    need_root
    scenario_check "$NAME"
    gns3_login
    local pid secs start end taps
    pid=$(our_project "$NAME") || die "could not list GNS3 projects"
    if [ -z "$pid" ] || [ "$pid" = "FOREIGN" ]; then die "$NAME is not up — r770-scenario.sh up $NAME --bundle <dir>"; fi
    nodes "$pid" > "$WORK/nodes.tsv" || die "could not read the project's nodes"
    ready_check "$NAME" 0 || die "$NAME is up but not ready ($(conf "$NAME" ready)) — nothing was generated"
    secs=${SCENARIO_TRAFFIC_SECS:-$(conf "$NAME" traffic_secs)}
    case "$secs" in ''|*[!0-9]*) die "the traffic window must be whole seconds (got '$secs')" ;; esac
    taps=$(awk -F'\t' '$5 != "" {print $5}' "$WORK/nodes.tsv" | paste -sd, -)
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    run_traffic "$NAME" "$WORK/nodes.tsv" "$secs"
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    write_run_record "$start" "$end" "$secs" "$T_OK" "$T_BADN" "$taps"
    if [ -z "$T_BADN" ]; then pass "traffic ran in every node:$T_OKN"
    elif [ "$T_OK" -gt 0 ]; then warn "traffic failed in:$T_BADN (ran in:$T_OKN)"
    else fail "no traffic generator ran (failed in:$T_BADN)"; fi
    footer "traffic"
}

# ── record ───────────────────────────────────────────────────────────────────
# One run, one directory: SCENARIO_CASES_DIR/<name>/<name>-<UTC minute>/ holds
# the outer capture (the first kit TAP: what the ISP side of the lab sees),
# one inner capture per inner_capture=<node>:<iface> (the host's tcpdump run
# inside that container's netns, so no node image needs tcpdump), run.conf,
# capture-stats.txt and sha256sums. The idle tail after traffic keeps the
# captures open for DPD and keepalives.
CASES="${SCENARIO_CASES_DIR:-/data/pcap/cases}"
MIN_FREE_MB="${SCENARIO_CASES_MIN_FREE_MB:-10240}"
RUN_DIR=""; RUN_ID=""
CAP_PIDS=(); CAP_LABELS=()   # running tcpdumps, by label
IMPAIRED_TAPS=()             # TAPs shaped for this run; the trap clears them
# ground truth: what the nodes themselves say happened, kept beside the
# captures under gt/ and never checksummed or ingested (keys may live there)
gt_snapshot() {  # gt_snapshot <scenario> <tag> — each gt= command's output into gt/<node>/sa/<tag>-<UTC>.txt
    # runs in the parent and in the event scheduler's subshell: files only, and
    # never die/exit (a die there would end the scheduler silently)
    local spec entry node cmd cid out
    local -a entries
    spec=$(conf "$1" gt); [ -n "$spec" ] || return 0
    IFS=';' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        node=${entry%%|*}; cmd=${entry#*|}
        cid=$(container_of "$WORK/nodes.tsv" "$node" 2>/dev/null) || continue
        out="$RUN_DIR/gt/$node/sa/$2-$(date -u +%Y%m%dT%H%M%SZ).txt"; mkdir -p "${out%/*}"
        if [ "$DRY" = "1" ]; then echo "DRY-RUN: docker exec $cid sh -c '$cmd' > $out"; continue; fi
        docker exec "$cid" sh -c "$cmd" > "$out" 2>&1 || warn "ground truth: '$cmd' in $node failed (kept: $out)"
    done
    return 0
}
gt_collect() {  # gt_collect <scenario> — docker cp each gt_dirs=node:/path into gt/<node>/
    local pair node path cid
    for pair in $(conf "$1" gt_dirs); do
        node=${pair%%:*}; path=${pair#*:}
        cid=$(container_of "$WORK/nodes.tsv" "$node" 2>/dev/null) || { warn "ground truth: no container for $node — nothing collected from $path"; continue; }
        mkdir -p "$RUN_DIR/gt/$node"
        run docker cp "$cid:$path/." "$RUN_DIR/gt/$node/" || warn "ground truth: could not copy $node:$path"
    done
    return 0
}
gt_keys_state() {  # present if any node's keys.state says so, absent if every node says so, n/a with none
    local f any=0 present=0
    for f in "$RUN_DIR"/gt/*/keys.state; do [ -e "$f" ] || continue; any=1; grep -qx present "$f" && present=1; done
    if [ "$any" -eq 0 ]; then printf 'n/a'; elif [ "$present" -eq 1 ]; then printf 'present'; else printf 'absent'; fi
}
# --impair <profile>@a|b and --events <file>: both checked before anything is
# written, both undone by the trap. a/b are the run's TAP_A/TAP_B, read from the
# project's Cloud nodes in cmd_record, never typed.
IMPAIR=(); EVENTS_FILE=""; EV_PID=""; TAP_A_RUN=""; TAP_B_RUN=""
tap_of_role() { case "$1" in a) printf '%s' "$TAP_A_RUN" ;; b) printf '%s' "$TAP_B_RUN" ;; *) return 1 ;; esac; }
side_check() {  # side_check <a|b> <what> — this project binds a TAP on that side, or die
    [ -n "$(tap_of_role "$1")" ] || die "$2: this project binds no TAP for side $1"
}
impair_check() {  # impair_check <profile@role> — valid shape and an existing profile, or die (before any capture)
    local prof=${1%@*} role=${1##*@}
    { [ "$prof" != "$1" ] && [ -n "$prof" ] && [[ "$role" =~ ^[ab]$ ]]; } || die "--impair takes <profile>@a or <profile>@b (got '$1')"
    [ -f "${WAN_PROFILE_DIR:-$KIT_DIR/config/wan/profiles}/$prof.conf" ] || die "no WAN profile '$prof' (see: r770-wan.sh show, config/wan/profiles/)"
    side_check "$role" "--impair $1"
}
impair_apply() {  # impair_apply <profile@role> — through r770-wan.sh (its PASS line lands in the transcript); remembered for the trap and the manifest
    local prof=${1%@*} role=${1##*@} tap; tap=$(tap_of_role "$role")
    "$KIT_DIR/scripts/r770-wan.sh" apply "$prof" "$tap" || die "r770-wan.sh refused $prof on $tap"
    IMPAIRED_TAPS+=("$tap"); echo "impair=$1:$tap" >> "$RUN_DIR/run.conf"
}
events_check() {  # events_check <file> [<window>] — every line t|action|arg, known action, t non-decreasing and inside the window (lint_scenarios.py events: the same rules)
    local line t act arg prev=-1 n=0
    [ -f "$1" ] || die "no events file $1"
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1)); case "$line" in ''|'#'*) continue ;; esac
        IFS='|' read -r t act arg <<< "$line"
        case "$t" in ''|*[!0-9]*) die "$1 line $n: t must be whole seconds (got '$t')" ;; esac
        [ "$t" -ge "$prev" ] || die "$1 line $n: times must not decrease"; prev=$t
        # past traffic + idle tail no capture is open, and the run would wait for it
        [ -z "${2:-}" ] || [ "$t" -le "$2" ] || die "$1 line $n: t=$t is past this run's window (traffic + idle tail = $2 s)"
        case "$act" in
            note) [ -n "$arg" ] || die "$1 line $n: note needs an argument" ;;
            exec) { [ "${arg#*|}" != "$arg" ] && [ -n "${arg%%|*}" ] && [ -n "${arg#*|}" ]; } || die "$1 line $n: exec takes <node>|<command>" ;;
            wan-apply) impair_check "$arg" ;;
            wan-clear|link-down|link-up) [[ "$arg" =~ ^[ab]$ ]] || die "$1 line $n: $act takes a or b"
                                         side_check "$arg" "$1 line $n" ;;
            *) die "$1 line $n: unknown action '$act' (known: note wan-apply wan-clear link-down link-up exec)" ;;
        esac
    done < "$1"
}
event_run() {  # event_run <t> <action> <arg> — do it, log it, snapshot ground truth after it; a failure is logged, never fatal
    local rc=0 tap node cmd cid
    case "$2" in
        note)      note "event t=$1: $3" ;;
        # its own subshell: a refusal is rc 1 in the log, not the scheduler's death
        wan-apply) ( impair_apply "$3" ) || rc=$? ;;
        wan-clear) tap=$(tap_of_role "$3"); "$KIT_DIR/scripts/r770-wan.sh" clear "$tap" || rc=$? ;;
        link-down|link-up) tap=$(tap_of_role "$3"); run ip link set dev "$tap" "${2#link-}" || rc=$? ;;
        exec)      node=${3%%|*}; cmd=${3#*|}
                   if cid=$(container_of "$WORK/nodes.tsv" "$node"); then run docker exec "$cid" sh -c "$cmd" || rc=$?; else rc=1; fi ;;
    esac
    printf '%s|%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$2" "$3" "$rc" >> "$RUN_DIR/events.log"
    [ "$2" = note ] || gt_snapshot "$NAME" "t$1-$2"
    return 0
}
events_start() {  # events_start — the scheduler, in the background, t counted from now (traffic start)
    [ -n "$EVENTS_FILE" ] || return 0
    echo "events=$EVENTS_FILE" >> "$RUN_DIR/run.conf"; cp "$EVENTS_FILE" "$RUN_DIR/events.txt"
    (
        t0=$(date +%s)
        while IFS='|' read -r t act arg || [ -n "$t" ]; do
            case "$t" in ''|'#'*) continue ;; esac
            while [ $(( $(date +%s) - t0 )) -lt "$t" ]; do sleep 1; done
            event_run "$t" "$act" "$arg"
        done < "$RUN_DIR/events.txt"
    ) & EV_PID=$!
}
tree_of() {  # tree_of <pid> — the pid and every descendant, one per line, children first
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do tree_of "$c"; done
    printf '%s\n' "$1"
}
events_warn() {  # events_warn — one WARN per events.log line whose rc (the LAST field: an arg may hold |) is not 0
    local et ea eg erc
    [ -f "$RUN_DIR/events.log" ] || return 0
    while IFS=$'\t' read -r et ea eg erc; do
        warn "event t=$et $ea $eg exited $erc"
    done < <(awk -F'|' '$NF != "0" { a = $4; for (i = 5; i < NF; i++) a = a "|" $i; print $2 "\t" $3 "\t" a "\t" $NF }' "$RUN_DIR/events.log")
}
# events_stop — wait for the scheduler to reach its last event (the idle tail
# covers it on the box); idempotent, since the trap calls it again
events_stop() { if [ -n "$EV_PID" ]; then wait "$EV_PID" 2>/dev/null || true; EV_PID=""; fi; }
cases_gate() {  # cases_gate <secs> <inner-captures> — refuse when the run could not fit; prints the estimate
    local dir free est
    dir=$(p "$CASES"); mkdir -p "$dir" || die "cannot create $dir"
    free=$(df -Pm "$dir" | awk 'NR == 2 {print $4}')
    # every iperf3 client in the pack is capped at 50 Mbit/s (tests/scenarios.bats), captured once outer and once per inner point: (1 + inner) * 50 Mbit/s * secs / 8
    est=$(( (1 + $2) * 50 * $1 / 8 + 64 ))
    [ "${free:-0}" -ge $((MIN_FREE_MB + est)) ] \
        || die "free space on $dir is ${free:-unknown} MB; this run needs about ${est} MB above the ${MIN_FREE_MB} MB floor (SCENARIO_CASES_MIN_FREE_MB) — nothing was captured"
    note "free space: ${free} MB on $dir (run estimate ${est} MB, floor ${MIN_FREE_MB} MB)"
}
capture_start() {  # capture_start <label> <iface> [<netns-pid>] — a tcpdump into $RUN_DIR/<label>.pcapng
    local out="$RUN_DIR/$1.pcapng" err="$RUN_DIR/.$1.stats"
    # nsenter execs tcpdump in place (no --fork), so $! is tcpdump itself and kill -INT reaches it
    if [ -n "${3:-}" ]; then
        nsenter --net="/proc/$3/ns/net" tcpdump -ni "$2" -s 0 -U -w "$out" 2> "$err" &
    else
        tcpdump -ni "$2" -s 0 -U -w "$out" 2> "$err" &
    fi
    CAP_PIDS+=($!); CAP_LABELS+=("$1")
    note "capture $1: $2${3:+ inside netns of pid $3} -> $out"
}
capture_stop_all() {  # capture_stop_all — SIGINT each tcpdump (it then flushes and prints its counts), wait, keep the counts
    local i n live
    for i in "${!CAP_PIDS[@]}"; do kill -INT "${CAP_PIDS[$i]}" 2>/dev/null || true; done
    # a background job starts with SIGINT ignored until tcpdump installs its own
    # handler, so a SIGINT sent in that first instant (the trap firing right
    # after capture_start) is lost and a bare wait would hang: give it 5 tries,
    # then SIGTERM, which tcpdump handles the same way and nothing ignores
    for ((n = 0; n < 5; n++)); do
        live=0
        for i in "${!CAP_PIDS[@]}"; do kill -0 "${CAP_PIDS[$i]}" 2>/dev/null && live=1; done
        [ "$live" = 0 ] && break
        sleep 1
    done
    for i in "${!CAP_PIDS[@]}"; do kill -TERM "${CAP_PIDS[$i]}" 2>/dev/null || true; done
    for i in "${!CAP_PIDS[@]}"; do
        wait "${CAP_PIDS[$i]}" 2>/dev/null || true
        printf '%s: %s\n' "${CAP_LABELS[$i]}" "$(grep -E 'dropped by kernel|captured' "$RUN_DIR/.${CAP_LABELS[$i]}.stats" 2>/dev/null | paste -sd';' - | sed 's/;/; /g')" >> "$RUN_DIR/capture-stats.txt"
        rm -f "$RUN_DIR/.${CAP_LABELS[$i]}.stats"
    done
    CAP_PIDS=(); CAP_LABELS=()
}
record_cleanup() {  # the EXIT trap: nothing left running, nothing left shaped, the manifest closed
    local t r cleared=" " tree
    # interrupted mid-events: stop the scheduler and everything it started (an
    # r770-wan.sh apply, an ip link, a docker exec ignore the terminal's SIGINT
    # as background children) rather than wait out its schedule. The tree is
    # read before any kill, since a killed parent's children are reparented.
    if [ -n "$EV_PID" ]; then
        mapfile -t tree < <(tree_of "$EV_PID")
        kill "${tree[@]}" 2>/dev/null || true
    fi
    events_stop
    capture_stop_all
    # the scheduler's wan-apply ran in a subshell and could not grow IMPAIRED_TAPS:
    # run.conf's impair= lines name every TAP either path shaped
    if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/run.conf" ]; then
        while IFS= read -r t; do IMPAIRED_TAPS+=("$t"); done < <(sed -n 's/^impair=.*:\(lab-tap[0-9]*\)$/\1/p' "$RUN_DIR/run.conf")
    fi
    for t in "${IMPAIRED_TAPS[@]}"; do
        case "$cleared" in *" $t "*) continue ;; esac; cleared="$cleared$t "
        "$KIT_DIR/scripts/r770-wan.sh" clear "$t" >/dev/null 2>&1 || true
    done
    # a run that could shape or take down a TAP leaves both of its TAPs clean
    # and up, whatever run.conf and events.log managed to record before the
    # interrupt (both idempotent, both TAPs this project's); a run with neither
    # --impair nor --events touches neither
    if [ -n "$EVENTS_FILE" ] || [ "${#IMPAIR[@]}" -gt 0 ]; then
        for t in "$TAP_A_RUN" "$TAP_B_RUN"; do
            [ -n "$t" ] || continue
            case "$cleared" in *" $t "*) ;; *) cleared="$cleared$t "; "$KIT_DIR/scripts/r770-wan.sh" clear "$t" >/dev/null 2>&1 || true ;; esac
            ip link set dev "$t" up 2>/dev/null || true
        done
    fi
    # a link-down event never outlives the run, even when its link-up never came
    if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/events.log" ]; then
        while IFS= read -r r; do
            if t=$(tap_of_role "$r") && [ -n "$t" ]; then ip link set dev "$t" up 2>/dev/null || true; fi
        done < <(awk -F'|' '$3 == "link-down" {print $4}' "$RUN_DIR/events.log" | sort -u)
    fi
    if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/run.conf" ] && ! grep -q '^end=' "$RUN_DIR/run.conf"; then
        echo "end=interrupted $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RUN_DIR/run.conf"
    fi
    cleanup
}
cmd_record() {
    banner "record — $NAME"
    need_root
    scenario_check "$NAME"
    gns3_login
    local pid secs idle start tend istart end taps tap_a tap_b cp node iface cid npid keys i l bad_caps="" seen=" "
    local -a inner=() labels=()   # inner: "<node> <iface> <netns-pid>", resolved before anything is written
    pid=$(our_project "$NAME") || die "could not list GNS3 projects"
    if [ -z "$pid" ] || [ "$pid" = "FOREIGN" ]; then die "$NAME is not up — r770-scenario.sh up $NAME --bundle <dir>"; fi
    nodes "$pid" > "$WORK/nodes.tsv" || die "could not read the project's nodes"
    ready_check "$NAME" 0 || die "$NAME is up but not ready ($(conf "$NAME" ready)) — nothing was recorded"
    secs=${SCENARIO_TRAFFIC_SECS:-$(conf "$NAME" traffic_secs)}; idle=$(conf "$NAME" idle_secs); idle=${idle:-0}
    case "$secs" in ''|*[!0-9]*) die "the traffic window must be whole seconds (got '$secs')" ;; esac
    case "$idle" in *[!0-9]*) die "idle_secs must be whole seconds (got '$idle')" ;; esac
    taps=$(awk -F'\t' '$2 == "cloud" && $5 != "" {print $5}' "$WORK/nodes.tsv" | paste -sd, -)
    IFS=, read -r tap_a tap_b _ <<< "$taps"
    [ -n "$tap_a" ] || die "no kit TAP bound by this project's Cloud nodes — not a pack scenario?"
    TAP_A_RUN=$tap_a; TAP_B_RUN=$tap_b
    # every inner point resolved to a running netns now, so a typo in
    # scenario.conf is refused before anything is written under cases/
    for cp in $(conf "$NAME" inner_capture); do
        node=${cp%%:*}; iface=${cp#*:}
        if [ -z "$node" ] || [ -z "$iface" ] || [ "$node" = "$cp" ]; then die "inner_capture entry '$cp' is not <node>:<iface>"; fi
        # inner-<node>.pcapng is the file name later steps read: one capture per node
        case "$seen" in *" $node "*) die "inner_capture names $node twice — one inner capture per node" ;; esac
        seen="$seen$node "
        cid=$(container_of "$WORK/nodes.tsv" "$node") || exit 1
        npid=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null) || die "docker inspect gave no pid for $node ($cid)"
        case "$npid" in ''|0|*[!0-9]*) die "docker reports no running pid for $node ($cid)" ;; esac
        inner+=("$node $iface $npid")
    done
    # --impair specs and the whole events file, refused here or never
    for i in "${IMPAIR[@]}"; do impair_check "$i"; done
    [ -z "$EVENTS_FILE" ] || events_check "$EVENTS_FILE" $((secs + idle))
    if [ "$DRY" = "1" ]; then
        # a dry run creates no run directory and starts no capture: it only says what would be
        echo "DRY-RUN: tcpdump -ni $tap_a -w $(p "$CASES")/$NAME/$NAME-<UTC>/outer-$tap_a.pcapng"
        for cp in $(conf "$NAME" inner_capture); do echo "DRY-RUN: nsenter --net=/proc/<pid of ${cp%%:*}>/ns/net tcpdump -ni ${cp#*:} -w .../inner-${cp%%:*}.pcapng"; done
        for i in "${IMPAIR[@]}"; do echo "DRY-RUN: r770-wan.sh apply ${i%@*} $(tap_of_role "${i##*@}")"; done
        [ -z "$EVENTS_FILE" ] || echo "DRY-RUN: events from $EVENTS_FILE, t counted from traffic start, logged to .../events.log"
        run_traffic "$NAME" "$WORK/nodes.tsv" "$secs"
        echo "DRY-RUN: idle tail ${idle}s, then run.conf, capture-stats.txt, sha256sums"
        footer "record"
    fi
    cases_gate "$secs" "${#inner[@]}"
    RUN_ID="$NAME-$(date -u +%Y%m%dT%H%MZ)"; RUN_DIR="$(p "$CASES")/$NAME/$RUN_ID"
    [ ! -e "$RUN_DIR" ] || die "$RUN_DIR already exists — one run per minute; nothing under $(p "$CASES") is overwritten"
    mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
    trap record_cleanup EXIT
    {
        echo "scenario=$NAME"; echo "run_id=$RUN_ID"; echo "project=lab-scenario-$NAME"
        echo "taps=$taps"; echo "tap_a=$tap_a"; echo "tap_b=$tap_b"
        echo "secs=$secs"; echo "idle_secs=$idle"; echo "spec=ipsec-scenarios-0.1"
        echo "load_start=$(cut -d' ' -f1 "$(p /proc/loadavg)")"
    } > "$RUN_DIR/run.conf"
    note "run directory: $RUN_DIR"
    capture_start "outer-$tap_a" "$tap_a"; echo "outer=outer-$tap_a.pcapng:$tap_a" >> "$RUN_DIR/run.conf"
    for cp in "${inner[@]}"; do
        read -r node iface npid <<< "$cp"
        capture_start "inner-$node" "$iface" "$npid"; echo "inner=inner-$node.pcapng:$node:$iface" >> "$RUN_DIR/run.conf"
    done
    sleep 2   # the capture files open before the first frame
    # a tcpdump that refused its interface (or an nsenter whose pid just
    # exited) is gone by now: refuse the run rather than PASS without its file
    for i in "${!CAP_PIDS[@]}"; do
        kill -0 "${CAP_PIDS[$i]}" 2>/dev/null \
            || die "capture ${CAP_LABELS[$i]} did not start: $(paste -sd' ' "$RUN_DIR/.${CAP_LABELS[$i]}.stats" 2>/dev/null)"
    done
    labels=("${CAP_LABELS[@]}")
    # shaped only once every capture is open, so the capture holds the change
    for i in "${IMPAIR[@]}"; do impair_apply "$i"; done
    gt_snapshot "$NAME" start
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "start=$start" >> "$RUN_DIR/run.conf"
    events_start "$NAME"
    run_traffic "$NAME" "$WORK/nodes.tsv" "$secs"
    tend=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "traffic_end=$tend" >> "$RUN_DIR/run.conf"
    istart=$(date -u +%s); echo "idle_start=$istart" >> "$RUN_DIR/run.conf"
    if [ "$idle" -gt 0 ]; then note "idle tail: ${idle}s (DPD, keepalives)"; sleep "$idle"; fi
    events_stop
    events_warn   # an event that failed is a run that did not happen as written
    gt_snapshot "$NAME" end
    capture_stop_all
    gt_collect "$NAME"; keys=$(gt_keys_state)
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    { echo "keys=$keys"; echo "load_end=$(cut -d' ' -f1 "$(p /proc/loadavg)")"; echo "end=$end"; } >> "$RUN_DIR/run.conf"
    ( cd "$RUN_DIR" && find . -maxdepth 1 -name '*.pcapng' -printf '%P\n' | sort | xargs -r sha256sum > sha256sums )
    write_run_record "$start" "$end" "$secs" "$T_OK" "$T_BADN" "$taps" "$RUN_DIR"
    for l in "${labels[@]}"; do [ -s "$RUN_DIR/$l.pcapng" ] || bad_caps="$bad_caps $l"; done
    if [ -n "$bad_caps" ]; then fail "recorded $RUN_ID, but capture(s) missing or empty:$bad_caps — $RUN_DIR kept for inspection"
    elif [ -z "$T_BADN" ]; then pass "recorded $RUN_ID: traffic ran in every node:$T_OKN"
    elif [ "$T_OK" -gt 0 ]; then warn "recorded $RUN_ID with traffic failed in:$T_BADN"
    else fail "no traffic generator ran (failed in:$T_BADN) — $RUN_DIR kept for inspection"; fi
    note "next: r770-scenario.sh verify $RUN_DIR · r770-scenario.sh ingest $RUN_DIR · r770-scenario.sh check $NAME"
    footer "record"
}

# ── check ────────────────────────────────────────────────────────────────────
# Each expect.txt row, as the Arkime expression the kit's generated views use
# (scripts/lib/expect.sh), counted over the run record's window through
# Arkime's session API. bounding=either (the session overlaps the window): a
# long-lived session -- BGP, an IKE SA -- starts before the window and is saved
# after it, and Arkime's default (last packet in range) counts it 0; measured
# on staging VM 9770. date= is never sent: date=-1 means all time. Uses only
# the Malcolm netrc (scripts/lib/malcolm-api.sh, which sets the EXIT trap), never
# the GNS3 work dir.
arkime_count() {  # arkime_count <expression> <start-epoch> <stop-epoch> — the count; non-zero with the HTTP status instead
    local body code n
    body=$(arkime_api GET "/api/sessions" -G -w '\n%{http_code}' \
        --data-urlencode "expression=$1" --data-urlencode "startTime=$2" --data-urlencode "stopTime=$3" \
        --data-urlencode "bounding=either" --data-urlencode "length=1" 2>/dev/null) || true
    code=${body##*$'\n'}
    n=$(printf '%s' "$body" | sed -n 's/.*"recordsFiltered":\([0-9][0-9]*\).*/\1/p' | head -1)
    if [ -z "$n" ]; then printf '%s' "${code:-none}"; return 1; fi
    printf '%s' "$n"
}
row_bpf() {  # row_bpf <proto> <port> <src> <dst> — the tcpdump filter that shows one row on the mirror
    local p=$1
    [ "$p" = ospf ] && p="proto ospf"
    printf '%s%s and src net %s and dst net %s' "$p" "${2:+ port $2}" "$3" "$4"
}
# check_wait_secs — SCENARIO_CHECK_WAIT_SECS's default: this Malcolm's own
# PCAP rotation period plus a 180s margin, not a fixed 180s. This Malcolm's
# Arkime is not capturing live (ARKIME_LIVE_CAPTURE=false): netsniff writes
# PCAP that rotates every PCAP_ROTATE_MINUTES (config/pcap-capture.env), and
# Arkime indexes a file only once it closes. Measured on staging VM 9770,
# 2026-09-26: a 10-minute rotation, and an ESP session that took up to 20
# minutes to appear — the fixed 180s default missed it.
#
# Sets CHECK_WAIT_SECS and prints the note as a side effect (never called
# through a $(...) capture: note()'s own output would land in the number).
check_wait_secs() {
    local f m
    f=$(p "${MALCOLM_HOME:-/opt/malcolm}/malcolm/config/pcap-capture.env")
    m=$(sed -n 's/^PCAP_ROTATE_MINUTES=\([0-9][0-9]*\)$/\1/p' "$f" 2>/dev/null | tail -1)
    if [ -n "$m" ]; then
        CHECK_WAIT_SECS=$((m * 60 + 180))
        ROTATE_MIN=$m
        note "waiting up to ${CHECK_WAIT_SECS}s for Arkime: it indexes PCAP when netsniff rotates it (PCAP_ROTATE_MINUTES=$m)"
    else
        CHECK_WAIT_SECS=180
        note "waiting up to 180s (no PCAP_ROTATE_MINUTES in $f)"
    fi
}
# nudge_netsniff <scenario> — netsniff (Malcolm's PCAP writer for
# lab_mirror0) rotates a file only on the next packet after
# PCAP_ROTATE_MINUTES, not on a timer: on a quiet lab bridge a file stays
# open until the next traffic (measured on VM 9770: file start times
# 17:45:38, then 18:15:38), and Arkime indexes a file only once it closes.
# One frame transmitted out of lab-mon0 reaches lab_mirror0 and is enough to
# make netsniff rotate once the interval has passed. Never gives lab-mon0 an
# address or touches its bridge membership (CLAUDE.md rule 8) -- it only
# transmits one frame out of an interface that already exists.
nudge_netsniff() {
    if [ ! -e "$(p "/sys/class/net/$LAB_MON")" ]; then
        note "no lab-mon0 (run r770-gns3-deploy.sh labnet) — cannot nudge netsniff; rows that only Arkime sees wait for the next traffic"
        return 0
    fi
    if python3 - "$LAB_MON" "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import socket
import sys

iface, scenario, ts = sys.argv[1], sys.argv[2], sys.argv[3]
mac = bytes.fromhex(open("/sys/class/net/" + iface + "/address").read().strip().replace(":", ""))
payload = ("r770-kit netsniff rotation nudge " + scenario + " " + ts).encode()
payload += b"\x00" * max(0, 46 - len(payload))
frame = b"\xff\xff\xff\xff\xff\xff" + mac + b"\x88\xb5" + payload
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind((iface, 0))
s.send(frame)
PY
    then
        note "nudged netsniff: one marker frame (ethertype 0x88b5) out of lab-mon0 so it rotates the PCAP holding this run"
    else
        warn "could not send the netsniff nudge (python3 exited $?) — rows that only Arkime sees wait for the next traffic"
    fi
}
cmd_check() {
    banner "check — $NAME"
    need_root
    scenario_check "$NAME"
    local ev="${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}" wait="" waited=0 nudged=0
    local rec start end s e r n proto port src dst why c pending lbl rows=()
    local -A cnt=()
    if [ -n "${SCENARIO_CHECK_WAIT_SECS+x}" ]; then
        wait=$SCENARIO_CHECK_WAIT_SECS
        case "$wait" in ''|*[!0-9]*) die "SCENARIO_CHECK_WAIT_SECS must be whole seconds (got '$wait')" ;; esac
    fi
    [ -f "$SCEN_DIR/$NAME/expect.txt" ] || die "scenarios/$NAME has no expect.txt — nothing to check"
    while IFS= read -r r; do
        IFS='|' read -r n proto port src dst <<< "$r"
        why=$(expect_problem "$proto" "$port" "$src" "$dst")
        [ -z "$why" ] || die "refusing scenarios/$NAME/expect.txt row $n: $why"
        rows+=("$r")
    done < <(expect_rows "$SCEN_DIR/$NAME")
    [ "${#rows[@]}" -gt 0 ] || die "scenarios/$NAME/expect.txt has no rows — nothing to check"
    rec=${RUN_FILE:-$(find "$ev" -maxdepth 1 -name "scenario-$NAME-*.run" 2>/dev/null | sort | tail -1)}
    if [ -z "$rec" ]; then skip "no run record — run r770-scenario.sh traffic $NAME first"; footer "check"; fi
    [ -f "$rec" ] || die "no run record at $rec"
    r=$(sed -n 's/^scenario=//p' "$rec" | head -1)
    [ "$r" = "$NAME" ] || die "$rec is a run of '$r', not $NAME"
    start=$(sed -n 's/^start=//p' "$rec" | head -1); end=$(sed -n 's/^end=//p' "$rec" | head -1)
    { [ -n "$start" ] && [ -n "$end" ]; } || die "$rec has no start= or end= — the traffic run did not finish; rerun r770-scenario.sh traffic $NAME"
    s=$(date -u -d "$start" +%s 2>/dev/null) || die "$rec: start '$start' is not a timestamp"
    e=$(date -u -d "$end" +%s 2>/dev/null) || die "$rec: end '$end' is not a timestamp"
    note "run record: $rec ($start – $end)"
    if [ ! -s "$(p "$MALCOLM_SECRET_FILE")" ]; then
        skip "no Malcolm credential at $MALCOLM_SECRET_FILE — Malcolm is not set up here (r770-malcolm-deploy.sh secrets)"
        footer "check"
    fi
    osd_auth_file
    if ! arkime_api GET "/api/user" --fail >/dev/null 2>&1; then
        skip "Arkime did not answer on 127.0.0.1:8443 — start Malcolm (r770-malcolm-deploy.sh start)"
        footer "check"
    fi
    # the rotation is read even when the wait is set by hand (the nudge below
    # needs it); its default-wait note is shown only when that default is used
    if [ -z "$wait" ]; then
        check_wait_secs; wait=$CHECK_WAIT_SECS
    else
        check_wait_secs > /dev/null
        note "SCENARIO_CHECK_WAIT_SECS sets the wait: up to ${wait}s"
    fi
    # Arkime writes a session when it closes or at its periodic save, so an
    # immediate check can be early: ask again every 10s for rows still at 0
    while :; do
        pending=0
        for r in "${rows[@]}"; do
            IFS='|' read -r n proto port src dst <<< "$r"
            case "${cnt[$n]:-}" in ''|0|ERR*) ;; *) continue ;; esac
            if c=$(arkime_count "$(expect_arkime "$proto" "$port" "$src" "$dst")" "$s" "$e"); then cnt[$n]=$c; else cnt[$n]="ERR$c"; fi
            case "${cnt[$n]}" in 0|ERR*) pending=$((pending + 1)) ;; esac
        done
        [ "$pending" -eq 0 ] && break
        if [ "$nudged" -eq 0 ] && [ -n "$ROTATE_MIN" ] && [ "$waited" -ge "$((ROTATE_MIN * 60))" ]; then
            nudge_netsniff "$NAME"
            nudged=1
        fi
        [ "$waited" -ge "$wait" ] && break
        sleep 10; waited=$((waited + 10))
    done
    for r in "${rows[@]}"; do
        IFS='|' read -r n proto port src dst <<< "$r"
        lbl=$(expect_label "$proto" "$port" "$src" "$dst")
        case "${cnt[$n]}" in
            ERR*) fail "$NAME row $n $lbl: Arkime's answer had no session count (HTTP ${cnt[$n]#ERR}) — is 127.0.0.1:8443 Malcolm, and is the kit's user an Arkime user?" ;;
            0)    fail "$NAME row $n $lbl: 0 sessions after ${waited}s"
                  note "first, is the flow on the mirror while traffic runs? tcpdump -ni lab_mirror0 '$(row_bpf "$proto" "$port" "$src" "$dst")'"
                  note "then, is Malcolm capturing? r770-validate.sh --area capture" ;;
            *)    pass "$NAME row $n $lbl: ${cnt[$n]} session(s) in $start–$end" ;;
        esac
    done
    footer "check"
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

# ── verify ───────────────────────────────────────────────────────────────────
# A judge of files: tshark over a finished run directory. No GNS3, no root.
RUN_DIR_ARG=""
rc_get() { sed -n "s/^$2=//p" "$1/run.conf" | head -1; }   # rc_get <run-dir> <key>
expected_row() {  # expected_row <PASS|FAIL|SKIP> <text> — the verdict, in the transcript and in expected.md
    case "$1" in PASS) pass "$2" ;; FAIL) fail "$2" ;; SKIP) skip "$2" ;; esac
    printf -- '- %s  %s\n' "$1" "$2" >> "$RUN_DIR_ARG/expected.md"
}
pcap_file() {  # pcap_file <run-dir> <outer|inner-node> — the capture's path from run.conf, or die
    local f
    case "$2" in
        outer)   f=$(rc_get "$1" outer); f=${f%%:*} ;;
        inner-*) f=$(sed -n "s/^inner=\(inner-${2#inner-}\.pcapng\):.*/\1/p" "$1/run.conf" | head -1) ;;
        *)       die "pcap-expect.txt names '$2'; a row's file is outer or inner-<node>" ;;
    esac
    if [ -z "$f" ] || [ ! -s "$1/$f" ]; then die "run has no capture '$2' (run.conf names: $(grep -E '^(outer|inner)=' "$1/run.conf" | cut -d= -f2 | cut -d: -f1 | tr '\n' ' '))"; fi
    printf '%s' "$1/$f"
}
tshark_run() {  # tshark_run <args…> — stdout to $WORK/tshark.out; on failure returns 1, first stderr line in TSHARK_ERR
    local rc=0 err="$WORK/tshark.err"
    tshark "$@" >"$WORK/tshark.out" 2>"$err" || rc=$?
    if [ "$rc" -ne 0 ]; then TSHARK_ERR=$(head -1 "$err"); TSHARK_ERR=${TSHARK_ERR:-exit $rc}; return 1; fi
}
pcap_check() {  # pcap_check <run-dir> <file> <mode> <filter> <expect> <label> — one row -> PASS/FAIL
    local pc n field want=$5
    pc=$(pcap_file "$1" "$2") || exit 1
    case "$3" in
        count)
            tshark_run -r "$pc" -Y "$4" || { expected_row FAIL "$6: tshark failed: $TSHARK_ERR"; return 0; }
            n=$(grep -c '^' "$WORK/tshark.out")
            case "$want" in
                0)    if [ "$n" -eq 0 ]; then expected_row PASS "$6"; else expected_row FAIL "$6: $n packet(s) match '$4', expected none"; fi ;;
                '>0') if [ "$n" -gt 0 ]; then expected_row PASS "$6 ($n packets)"; else expected_row FAIL "$6: 0 packets match '$4'"; fi ;;
                *)    die "pcap-expect.txt: count expects 0 or >0 (got '$want')" ;;
            esac ;;
        "distinct "*)
            field=${3#distinct }
            [[ "$want" =~ ^\>=([0-9]+)$ ]] || die "pcap-expect.txt: distinct expects >=N (got '$want')"
            tshark_run -r "$pc" -Y "$4" -T fields -e "$field" || { expected_row FAIL "$6: tshark failed: $TSHARK_ERR"; return 0; }
            n=$(grep -v '^$' "$WORK/tshark.out" | sort -u | wc -l)
            if [ "$n" -ge "${BASH_REMATCH[1]}" ]; then expected_row PASS "$6 ($n distinct $field)"; else expected_row FAIL "$6: $n distinct $field, expected $want"; fi ;;
        *)  die "pcap-expect.txt: unknown mode '$3' (count | distinct <field>)" ;;
    esac
}
decrypt_check() {  # decrypt_check <run-dir> — X7: outer ESP decrypts with the node's keys
    local keys prof esp_sa n pc
    keys=$(rc_get "$1" keys)
    if [ "$keys" != present ]; then expected_row SKIP "X7 decryption: keys=$keys — the inner capture is the plaintext truth"; return 0; fi
    esp_sa=$(find "$1/gt" -path '*/keys/esp_sa' 2>/dev/null | head -1)
    if [ -z "$esp_sa" ]; then expected_row FAIL "X7 decryption: keys=present but no gt/*/keys/esp_sa"; return 0; fi
    prof="$WORK/.config/wireshark/profiles/gt"; mkdir -p "$prof"; cp "$esp_sa" "$prof/esp_sa"
    pc=$(pcap_file "$1" outer) || exit 1
    # a decrypted ESP packet dissects to its inner protocol; count ESP frames that also carry tcp/udp/icmp
    HOME="$WORK" XDG_CONFIG_HOME='' tshark_run -C gt -o esp.enable_encryption_decode:TRUE -r "$pc" -Y 'esp && (tcp || udp || icmp)' \
        || { expected_row FAIL "X7 decryption: tshark failed: $TSHARK_ERR"; return 0; }
    n=$(grep -c '^' "$WORK/tshark.out")
    if [ "$n" -gt 0 ]; then expected_row PASS "X7 decryption: $n ESP packets decode with the run's keys"
    else expected_row FAIL "X7 decryption: keys present but no ESP packet decoded — compare esp_sa's SPIs with the outer capture"; fi
}
drops_check() {  # drops_check <run-dir> — X8
    local bad
    if [ ! -s "$1/capture-stats.txt" ]; then expected_row FAIL "X8 drops: no capture-stats.txt"; return 0; fi
    bad=$(grep -v ' 0 packets dropped by kernel' "$1/capture-stats.txt" | cut -d: -f1 | tr '\n' ' ')
    if [ -z "$bad" ]; then expected_row PASS "X8 drops: 0 packets dropped by kernel on every capture"
    else expected_row FAIL "X8 drops: kernel drops on: ${bad% }"; fi
}
cmd_verify() {
    banner "verify — $RUN_DIR_ARG"
    local d=$RUN_DIR_ARG s f line n rows file mode filt want label istart
    if [ -z "$d" ] || [ ! -f "$d/run.conf" ]; then die "${d:-verify} has no run.conf — not a run directory (see: r770-scenario.sh status)"; fi
    s=$(rc_get "$d" scenario); scenario_check "$s"; NAME=$s
    grep -q '^end=20' "$d/run.conf" || warn "run.conf has no clean end= — the run was interrupted; judging what is there"
    work
    f="$SCEN_DIR/$s/pcap-expect.txt"
    istart=$(rc_get "$d" idle_start)
    { echo "# expected observations — $(rc_get "$d" run_id)"; echo; } > "$d/expected.md"
    if [ -f "$f" ]; then
        n=0; rows=0
        while IFS= read -r line; do
            n=$((n + 1)); case "$line" in ''|'#'*) continue ;; esac
            rows=$((rows + 1))
            IFS='|' read -r file mode filt want label <<< "$line"
            [ -n "$label" ] || die "$f line $n: need <file>|<mode>|<filter>|<expectation>|<label>"
            pcap_check "$d" "$file" "$mode" "${filt//__IDLE_START__/$istart}" "$want" "$label"
        done < "$f"
        [ "$rows" -gt 0 ] || skip "scenarios/$s/pcap-expect.txt has no rows — only the built-in checks"
    else
        skip "scenarios/$s has no pcap-expect.txt — only the built-in checks"
    fi
    decrypt_check "$d"
    drops_check "$d"
    note "X9 (Malcolm): r770-scenario.sh ingest $d, then r770-scenario.sh check $s"
    footer "verify"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
SUB="${1:-}"; [ $# -gt 0 ] && shift
case "$SUB" in
    up|traffic|down|check|record) case "${1:-}" in -*|"") ;; *) NAME=$1; shift ;; esac ;;
    verify) case "${1:-}" in -*|"") ;; *) RUN_DIR_ARG=$1; shift ;; esac ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        --taps)    TAPS="${2:-}"; shift ;;
        --run)     [ -n "${2:-}" ] || die "--run needs a run record path (see: r770-scenario.sh status)"
                   RUN_FILE=$2; shift ;;
        --impair)  IMPAIR+=("${2:-}"); shift ;;
        --events)  [ -n "${2:-}" ] || die "--events needs a file of t|action|arg lines"
                   EVENTS_FILE=$2; shift ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-scenario"
case "$SUB" in
    list) cmd_list ;;
    up|traffic|down|check|record)
        [ -n "$NAME" ] || die "$SUB needs a scenario name (see: r770-scenario.sh list)"
        "cmd_$SUB" ;;
    verify) cmd_verify ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
