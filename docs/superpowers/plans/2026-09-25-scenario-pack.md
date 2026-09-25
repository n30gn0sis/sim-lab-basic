# Scenario Pack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five repeatable GNS3 network scenarios (`client-server`, `ipsec-esp`, `ospf`, `bgp`, `ipsec-ike`) and a script, `scripts/r770-scenario.sh list|up|traffic|down|status`, that imports one into GNS3, configures its nodes, drives known traffic for a known window across the mirrored `br-lab`, and tears it down.

**Architecture:** Each scenario is a directory under `scenarios/`: a `.gns3` project template (image references and TAP names as tokens), per-node config files applied with `docker exec` after the nodes start, a `traffic.sh` run inside named nodes, and an `expect.txt` for the later end-to-end check. `r770-scenario.sh` talks to the GNS3 v3 API on `127.0.0.1:3080` with `curl` (the admin credential goes through a 0600 file, never argv), reads JSON with `python3` (there is no `jq`), and builds the portable-project zip with `python3 zipfile`. Tests drive the script against a fake GNS3 controller (`tests/helpers/fake_gns3.py`) behind a `curl` stub, and a stubbed `docker`.

**Tech Stack:** bash, python3 (stdlib only), GNS3 v3 REST API, bats-core ≥ 1.10, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-24-scenario-pack-design.md` (depends on `docs/superpowers/specs/2026-09-24-lab-mirror-feed-design.md`).

## Refinements to the spec (decided while planning)

These keep the spec's intent. The implementer follows the plan; the spec is not edited.

1. **Node config is applied at `up` by `docker exec`, not baked into GNS3 persistent volumes.** GNS3's per-node persistence depends on image internals (ifupdown, volume paths); feeding each node's file over `docker exec -i ... sh -s` works for every image, is testable with a stubbed `docker`, and keeps "configs ship with the scenario, never hand-typed". Layout: `scenarios/<name>/nodes/<node>.sh` (addresses, routes, `ip xfrm`), `<node>.frr.conf` (applied with `vtysh -f`), `<node>.swanctl.conf` (installed, then `swanctl --load-all`).
2. **The kit's marker is a GNS3 project variable** `r770_scenario=<name>` (GNS3 projects have `variables`, not a comment field).
3. **`client-server` drops iperf3.** The bundled alpine image has busybox `httpd` but no `iperf3`; the scenario generates HTTP GETs and ICMP only.
   *Correction (final review, F1):* stock alpine's busybox is built without `httpd` (it lives in busybox-extras). The server is a detached busybox `nc` loop answering every connection on port 80 with a fixed HTTP reply; the image, the readiness check and the traffic are unchanged.
4. **Readiness for `ospf` and `bgp` is an end-to-end ping** from one host to the other: it only succeeds once routes have converged, which is a stronger proof than a neighbour state.
5. **Project files carry no `"version"` field** (`tests/no-pins.bats` forbids three-part version numbers); `"revision": 9` identifies the file format.

## Assumptions only the staging rehearsal can prove

The tests prove the kit's side against a fake controller. On VM 9770, against the bundled GNS3, check (the runbook section lists these):
- login: `POST /v3/access/users/login` with JSON `{"username","password"}` returns `access_token` (the same call `r770-validate.sh --area gns3` already makes);
- import: `POST /v3/projects/{id}/import?name=...` accepts a zip whose root holds `project.gns3`; then `POST .../open`, `POST .../nodes/start`, `GET .../nodes` (docker nodes report `properties.container_id`), `POST .../nodes/stop`, `DELETE /v3/projects/{id}`;
- Cloud ports with `"type": "tap"` open the persistent `lab-tapN`;
- GNS3 docker nodes run privileged enough for `ip addr`, `sysctl`, `ip xfrm`;
- the FRR image's `start_command` (enable `ospfd`/`bgpd` in `/etc/frr/daemons`, then `exec /usr/lib/frr/docker-start`) brings the daemons up;
- the strongSwan image (not yet in the bundle) starts charon by itself and carries `swanctl` and `iproute2`.

## Global Constraints

- `./tests/run.sh` green before every commit: shellcheck with **no exclusions** (never add `# shellcheck disable`), every `tests/*.bats`. Baseline on branch `docs-pipeline` (this plan's base): 229/229.
- Tests never touch the host or a network: stubbed PATH (`kit_test_env`/`kit_run`/`stub`), paths via `p` under `$ROOT`, `curl` stubbed to `tests/helpers/fake_gns3.py`.
- Every `curl` line in `scripts/` names `127.0.0.1` literally (`tests/no-internet.bats`); the GNS3 API base is exactly `http://127.0.0.1:3080/v3`.
- The admin credential (`/etc/lab/secrets/gns3-admin.pw`) is never in argv, never printed; the bearer token lives only in a 0600 header file inside a temp dir removed on exit.
- No version pins anywhere in `scripts/`, `scenarios/`, `tests/` (except `0.0.0-fixture`); image references come from the bundle's `gns3/docker-nodes/image-list.txt` via `image_ref_from_list`, as tokens `__IMG_<BASENAME>__` (basename upper-cased, `-`→`_`).
- Kit names: projects `lab-scenario-<name>`; project variable `r770_scenario=<name>`; TAPs `lab-tap<i>` (`GNS3_LAB_TAPS`, default 4); a Cloud port is `{"interface": "__TAP_A__" | "__TAP_B__", "name": same, "port_number": 0, "type": "tap"}`.
- Scenario names match `^[a-z0-9][a-z0-9-]*$`. Ranges: `client-server` 10.205.0.0/16, `ipsec-esp` 10.201.0.0/16, `ipsec-ike` 10.202.0.0/16, `ospf` 10.203.0.0/16, `bgp` 10.204.0.0/16.
- `r770-scenario.sh` is not gated; it deletes only projects that are named `lab-scenario-<name>` **and** carry the marker.
- Env: `SCENARIO_DIR` (default `$KIT_DIR/scenarios`, test seam), `SCENARIO_WAIT_SECS` 120, `SCENARIO_TRAFFIC_SECS` (default the scenario's `traffic_secs`), `GNS3_LAB_TAPS` 4, `GNS3_ADMIN_USER` admin.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA
  ```

## File map

| File | Task | Responsibility |
|---|---|---|
| `tests/helpers/fake_gns3.py` | 1 | fake GNS3 v3 controller for the suite |
| `scripts/r770-scenario.sh` | 1, 2, 3 | the script: helpers + `list` + `down` (1), `up` (2), `traffic` + `status` (3) |
| `tests/scenario.bats` | 1, 2, 3 | the script's suite, against a fixture scenario |
| `scenarios/client-server/`, `scenarios/ipsec-esp/` | 4 | first two scenarios |
| `tests/helpers/lint_scenarios.py`, `tests/scenarios.bats` | 4 | content lint |
| `tests/no-internet.bats` | 4 | URLs in `scenarios/` stay in lab ranges |
| `scenarios/ospf/`, `scenarios/bgp/`, `scenarios/ipsec-ike/` | 5 | the other three |
| `README.md`, `docs/deployment-runbook.md`, `docs/CODEMAPS/stages.md`, `tests/README.md`, `.claude/settings.json`, `docs/kit-sync.md` | 6 | docs and settings |

---

### Task 1: The fake controller, the script's core, `list` and `down`

**Files:**
- Create: `tests/helpers/fake_gns3.py`
- Create: `scripts/r770-scenario.sh` (mode 0755)
- Create: `tests/scenario.bats`

**Interfaces:**
- Consumes (common.sh): `kit_init`, `die`, `pass`, `warn`, `fail`, `note`, `banner`, `footer`, `need_root`, `p`, `common_flag`, `usage_from_header`, `bundle_dir`, `image_ref_from_list`; globals `DRY`, `FORCE`, `KIT_DIR`.
- Produces (used by Tasks 2, 3): shell functions `py <program>`, `conf <scenario> <key>`, `scenario_check <name>`, `img_token <basename>`, `image_ref <bundle-dir> <basename>`, `missing_images <bundle-dir> <scenario>`, `work`, `gns3_login`, `api <METHOD> <path> [curl-args…]`, `call <METHOD> <path> [curl-args…]`, `our_project <scenario>` (prints project id, empty, or `FOREIGN`), `nodes <project-id>` (TSV: name, node_type, status, container_id, comma-joined tap interfaces), `container_of <nodes-tsv> <node>`, `take_down <project-id>`; globals `SCEN_DIR`, `SECRET`, `MARKER`, `BUNDLE`, `NAME`, `WORK`, `AUTH_HDR` (Task 2 adds `WAIT_SECS`, `LAB_TAPS`, `TAPS`, `TAP_A`, `TAP_B` and `--taps`). Test helpers `scenario()`, `make_demo_scenario`, `seed_project`, and the docker stub's files `$BATS_TEST_TMPDIR/images.txt`, `stdin-<cid>`, `rc-exec-<cid>`, `rc-execi-<cid>`.

- [ ] **Step 1: Create the fake controller**

`tests/helpers/fake_gns3.py`:

```python
#!/usr/bin/env python3
"""A fake GNS3 v3 controller that answers the kit's curl calls.

tests/scenario.bats installs `curl` as a stub that execs this file, so every
request r770-scenario.sh makes lands here instead of on a network. State is a
directory, $FAKE_GNS3:

  projects.json   the controller's projects (a list; topology kept inside)
  requests.log    one "METHOD PATH" line per request, in order
  down            if present: /version is unreachable (curl exit 7)
  login-refused   if present: the login fails
  import-fails    if present: the import fails
  never-starts    if present: docker nodes stay "stopped" after nodes/start

Only the calls the kit makes are implemented; anything else fails. Like
`curl --fail`, a failure prints nothing and exits 22.
"""
import io
import json
import os
import re
import sys
import zipfile

STATE = os.environ["FAKE_GNS3"]
TOKEN = "fixture-token"


def path(name):
    return os.path.join(STATE, name)


def flag(name):
    return os.path.exists(path(name))


def load():
    try:
        with open(path("projects.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        return []


def save(projects):
    with open(path("projects.json"), "w") as f:
        json.dump(projects, f)


def reply(obj):
    sys.stdout.write(json.dumps(obj))
    return 0


def parse(argv):
    method, url, data, headers = "GET", None, None, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "-X":
            method = argv[i + 1]
            i += 1
        elif a == "-H":
            headers.append(argv[i + 1])
            i += 1
        elif a in ("--data", "--data-binary", "-d"):
            data = argv[i + 1]
            i += 1
        elif a == "--max-time":
            i += 1
        elif "://" in a:
            url = a
        i += 1
    return method, url, data, headers


def header_lines(headers):
    out = []
    for h in headers:
        if h.startswith("@"):
            with open(h[1:]) as f:
                out += [line.strip() for line in f if line.strip()]
        else:
            out.append(h)
    return out


def body_of(data):
    if data is None:
        return b""
    if data.startswith("@"):
        with open(data[1:], "rb") as f:
            return f.read()
    return data.encode()


def public(p):
    return {k: v for k, v in p.items() if k != "topology"}


def node_view(n):
    props = dict(n.get("properties") or {})
    if n.get("node_type") == "docker":
        props["container_id"] = "cid-" + n["name"]
    return {"node_id": n["node_id"], "name": n["name"], "node_type": n["node_type"],
            "status": n.get("status", "stopped"), "properties": props}


def main():
    method, url, data, headers = parse(sys.argv[1:])
    route = re.sub(r"^https?://[^/]+", "", url or "")
    with open(path("requests.log"), "a") as f:
        f.write(f"{method} {route}\n")
    if route == "/v3/version":
        return 7 if flag("down") else reply({"version": "fixture"})
    if route == "/v3/access/users/login" and method == "POST":
        creds = json.loads(body_of(data) or b"{}")
        if flag("login-refused") or not creds.get("username") or not creds.get("password"):
            return 22
        return reply({"access_token": TOKEN, "token_type": "bearer"})
    if f"Authorization: Bearer {TOKEN}" not in header_lines(headers):
        return 22
    projects = load()
    base, _, query = route.partition("?")
    m = re.fullmatch(r"/v3/projects(?:/([^/]+))?(/.*)?", base)
    if not m:
        return 22
    pid, rest = m.group(1), m.group(2) or ""
    if pid is None:
        return reply([public(p) for p in projects]) if method == "GET" else 22
    proj = next((p for p in projects if p["project_id"] == pid), None)
    if rest == "/import" and method == "POST":
        if flag("import-fails") or proj is not None:
            return 22
        name = dict(kv.split("=", 1) for kv in query.split("&") if "=" in kv).get("name", "")
        with zipfile.ZipFile(io.BytesIO(body_of(data))) as z:
            topo = json.loads(z.read("project.gns3"))
        projects.append({"project_id": pid, "name": name, "status": "closed",
                         "variables": topo.get("variables") or [],
                         "topology": topo["topology"]})
        save(projects)
        return reply(public(projects[-1]))
    if proj is None:
        return 22
    if rest == "/open" and method == "POST":
        proj["status"] = "opened"
        save(projects)
        return reply(public(proj))
    if rest == "/nodes" and method == "GET":
        if proj["status"] != "opened":
            return 22
        return reply([node_view(n) for n in proj["topology"]["nodes"]])
    if rest in ("/nodes/start", "/nodes/stop") and method == "POST":
        if proj["status"] != "opened":
            return 22
        state = "started" if rest.endswith("start") and not flag("never-starts") else "stopped"
        for n in proj["topology"]["nodes"]:
            if n.get("node_type") == "docker":
                n["status"] = state
        save(projects)
        return reply({})
    if rest == "" and method == "DELETE":
        projects.remove(proj)
        save(projects)
        return reply({})
    return 22


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Write the failing suite**

`tests/scenario.bats`:

```bash
#!/usr/bin/env bats
#
# r770-scenario.sh against a fake GNS3 controller (tests/helpers/fake_gns3.py
# behind a curl stub) and a stubbed docker. The scenarios here are fixtures
# under $BATS_TEST_TMPDIR; the real pack is linted by tests/scenarios.bats.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-scenario.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle-fixture"
    make_bundle "$BUNDLE"
    make_root "$ROOT"
    echo 'docker.io/nicolaka/netshoot:0.0.0-fixture' >> "$BUNDLE/gns3/docker-nodes/image-list.txt"
    export ROOT BATS_TEST_TMPDIR
    export SCENARIO_DIR="$BATS_TEST_TMPDIR/scenarios" SCENARIO_WAIT_SECS=4
    export FAKE_GNS3="$BATS_TEST_TMPDIR/gns3"
    mkdir -p "$FAKE_GNS3" "$ROOT/etc/lab/secrets"
    echo fixture-pw > "$ROOT/etc/lab/secrets/gns3-admin.pw"
    for i in 0 1 2 3; do mkdir -p "$ROOT/sys/class/net/lab-tap$i"; done
    make_demo_scenario
    stub curl "echo \"curl \$*\" >> \"\$STUB_LOG\"; exec python3 \"$BATS_TEST_DIRNAME/helpers/fake_gns3.py\" \"\$@\""
    stub sleep 'exit 0'
    stub hostname 'echo fixturehost'
    echo 'docker.io/nicolaka/netshoot:0.0.0-fixture' > "$BATS_TEST_TMPDIR/images.txt"
    # docker: image ls reads images.txt; exec -i appends stdin to stdin-<cid>;
    # exec exits per rc-exec-<cid> (no -i) or rc-execi-<cid> (-i), default 0
    stub docker 'echo "docker $*" >> "$STUB_LOG"
case "$1" in
  image) [ "$2" = ls ] && cat "$BATS_TEST_TMPDIR/images.txt" ;;
  exec)
    shift; mode=exec
    if [ "$1" = -i ]; then mode=execi; shift; fi
    cid=$1
    [ "$mode" = execi ] && cat >> "$BATS_TEST_TMPDIR/stdin-$cid"
    f="$BATS_TEST_TMPDIR/rc-$mode-$cid"
    [ -f "$f" ] && exit "$(cat "$f")" ;;
esac
exit 0'
}

scenario() { kit_run "$SCRIPT" "$@"; }

# make_demo_scenario — "demo": two netshoot nodes a and b, each on one of the
# two Cloud TAP ports; "needs-ike": the same shape, but also needs strongswan.
make_demo_scenario() {
    local s
    for s in demo needs-ike; do
        local d="$SCENARIO_DIR/$s"
        mkdir -p "$d/project" "$d/nodes"
        cat > "$d/project/$s.gns3" <<'EOF'
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [], "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000009-0000-4000-8000-000000000001", "name": "a", "node_type": "docker", "x": -100, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000009-0000-4000-8000-000000000002", "name": "b", "node_type": "docker", "x": 100, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000009-0000-4000-8000-000000000003", "name": "tap-a", "node_type": "cloud", "x": -100, "y": 100,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000009-0000-4000-8000-000000000004", "name": "tap-b", "node_type": "cloud", "x": 100, "y": 100,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000009-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000009-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000009-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000009-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000009-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000009-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
EOF
        printf 'ip addr replace 10.209.0.1/24 dev eth0\n' > "$d/nodes/a.sh"
        printf 'ip addr replace 10.209.0.2/24 dev eth0\n' > "$d/nodes/b.sh"
        printf '#!/bin/sh\nexit 0\n' > "$d/traffic.sh"
        printf 'icmp||10.209.0.0/24|10.209.0.0/24\n' > "$d/expect.txt"
        cat > "$d/scenario.conf" <<EOF
name=$s
description=two netshoot nodes across br-lab
range=10.209.0.0/16
images=netshoot
traffic_secs=5
ready=a|true
traffic_nodes=b a
EOF
    done
    sed -i 's/^images=netshoot$/images=netshoot strongswan/' "$SCENARIO_DIR/needs-ike/scenario.conf"
}

# seed_project <id> <name> <status> <marker-or-empty> [<tap>...] — put a
# project into the fake controller; each tap becomes a Cloud port of it
seed_project() {
    local id=$1 name=$2 st=$3 marker=$4; shift 4
    python3 - "$FAKE_GNS3/projects.json" "$id" "$name" "$st" "$marker" "$@" <<'PY'
import json, os, sys
f, pid, name, st, marker, *taps = sys.argv[1:]
projects = json.load(open(f)) if os.path.exists(f) else []
nodes = [{"node_id": f"n{i}", "name": f"cloud{i}", "node_type": "cloud",
          "properties": {"ports_mapping": [{"interface": t, "name": t, "port_number": 0, "type": "tap"}]}}
         for i, t in enumerate(taps)]
projects.append({"project_id": pid, "name": name, "status": st,
                 "variables": [{"name": "r770_scenario", "value": marker}] if marker else [],
                 "topology": {"nodes": nodes, "links": []}})
json.dump(projects, open(f, "w"))
PY
}

# ── list ───────────────────────────────────────────────────────────────────

@test "list without --bundle names every scenario and asks for a bundle to check images" {
    run scenario list
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"demo"*"10.209.0.0/16"* ]]
    [[ "$output" == *"needs-ike"* ]]
    [[ "$output" == *"pass --bundle to check them"* ]]
}

@test "list --bundle marks a scenario runnable, and one needing strongswan not runnable, naming it" {
    run scenario list --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"runnable with this bundle"* ]]
    [[ "$output" == *"NOT runnable: missing strongswan — strongSwan arrives with the next bundle cut"* ]]
}

# ── login and the controller ───────────────────────────────────────────────

@test "a GNS3 that does not answer is a refusal naming the service step" {
    touch "$FAKE_GNS3/down"
    run scenario down demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GNS3 does not answer on 127.0.0.1:3080"* ]]
    [[ "$output" == *"r770-gns3-deploy.sh service"* ]]
}

@test "a refused login is a refusal naming config" {
    touch "$FAKE_GNS3/login-refused"
    run scenario down demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GNS3 refused the admin login"* ]]
}

@test "the admin credential never reaches argv or the transcript" {
    run scenario down demo
    [ "$status" -eq 0 ]
    ! grep -q fixture-pw "$STUB_LOG"
    [[ "$output" != *"fixture-pw"* ]]
    [[ "$output" != *"fixture-token"* ]]
    grep -q 'POST /v3/access/users/login' "$FAKE_GNS3/requests.log"
}

@test "an unknown or malformed scenario name is refused" {
    run scenario down nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"no scenario 'nope'"* ]]
    run scenario down 'Bad_Name'
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a scenario name"* ]]
    run scenario down
    [ "$status" -eq 1 ]
    [[ "$output" == *"down needs a scenario name"* ]]
}

# ── down ───────────────────────────────────────────────────────────────────

@test "down on a scenario that is not up PASSes and deletes nothing" {
    run scenario down demo
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  demo is not running"* ]]
    ! grep -q '^DELETE' "$FAKE_GNS3/requests.log"
}

@test "down stops and deletes our project, and only ours" {
    seed_project p1 lab-scenario-demo opened demo lab-tap0 lab-tap1
    seed_project p2 other-project opened ""
    run scenario down demo
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^POST /v3/projects/p1/nodes/stop$' "$FAKE_GNS3/requests.log"
    grep -q '^DELETE /v3/projects/p1$' "$FAKE_GNS3/requests.log"
    ! grep -q 'p2' "$FAKE_GNS3/requests.log"
    ! grep -q '"p1"' "$FAKE_GNS3/projects.json"
    grep -q '"p2"' "$FAKE_GNS3/projects.json"
    [[ "$output" == *"PASS  demo taken down"* ]]
}

@test "down refuses a same-named project without the kit's marker" {
    seed_project p9 lab-scenario-demo opened ""
    run scenario down demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no kit marker"* ]]
    ! grep -q '^DELETE' "$FAKE_GNS3/requests.log"
}
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `bats tests/scenario.bats`
Expected: every test `not ok` (the script does not exist, exit 127).

- [ ] **Step 4: Write the script**

`scripts/r770-scenario.sh`:

```bash
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
```

Then `chmod 0755 scripts/r770-scenario.sh`.

- [ ] **Step 5: Run the suite, then the gate**

Run: `bats tests/scenario.bats`
Expected: 9 tests, all `ok`.

Run: `./tests/run.sh`
Expected: all `ok` — including `lint.bats` (shellcheck clean; `--help` prints the whole header; executable) and `no-internet.bats` (every `curl` line names `127.0.0.1`). `references.bats`'s settings check passes because no doc names the script yet.

- [ ] **Step 6: Commit**

```bash
git add tests/helpers/fake_gns3.py scripts/r770-scenario.sh tests/scenario.bats
git commit -m "Add r770-scenario.sh: GNS3 API core, list and down, tested against a fake controller

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 2: `up` — import, start, configure, wait until ready

**Files:**
- Modify: `scripts/r770-scenario.sh` (new functions and `cmd_up` above `# ── dispatch`; dispatch arm)
- Modify: `tests/scenario.bats` (append)

**Interfaces:**
- Consumes: everything Task 1 produces (see its Interfaces block).
- Produces: `taps_in_use` (lines `"<tap> <project-name>"`), `pick_taps` (sets `TAP_A`/`TAP_B`), `render_project <scenario> <bundle> <out> <pid>`, `wait_started <pid>` (writes `$WORK/nodes.tsv`), `configure_nodes <scenario>`, `ready_check <scenario> [<limit-secs>]` (0 ready / 1 not), `cmd_up`.

- [ ] **Step 1: Append the failing tests**

Append to `tests/scenario.bats`:

```bash
# ── up ─────────────────────────────────────────────────────────────────────

@test "up imports the rendered project, opens it, starts it, configures each node and waits until ready" {
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    r=$(grep -nE '^POST /v3/projects/[^/]+/import\?name=lab-scenario-demo$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    o=$(grep -nE '^POST /v3/projects/[^/]+/open$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    s=$(grep -nE '^POST /v3/projects/[^/]+/nodes/start$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    [ -n "$r" ] && [ -n "$o" ] && [ -n "$s" ] && [ "$r" -lt "$o" ] && [ "$o" -lt "$s" ]
    python3 - "$FAKE_GNS3/projects.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))[0]
assert p["name"] == "lab-scenario-demo", p["name"]
assert {"name": "r770_scenario", "value": "demo"} in p["variables"]
nodes = {n["name"]: n for n in p["topology"]["nodes"]}
assert nodes["a"]["properties"]["image"] == "docker.io/nicolaka/netshoot:0.0.0-fixture"
assert nodes["tap-a"]["properties"]["ports_mapping"][0]["interface"] == "lab-tap0"
assert nodes["tap-b"]["properties"]["ports_mapping"][0]["interface"] == "lab-tap1"
assert nodes["tap-a"]["properties"]["ports_mapping"][0]["type"] == "tap"
PY
    grep -q '^docker exec -i cid-a sh -s$' "$STUB_LOG"
    grep -q '^docker exec -i cid-b sh -s$' "$STUB_LOG"
    grep -q '10.209.0.1/24' "$BATS_TEST_TMPDIR/stdin-cid-a"
    [[ "$output" == *"PASS  every node started"* ]]
    [[ "$output" == *"PASS  ready: a: true"* ]]
}

@test "up refuses an image the bundle does not carry, naming it, and imports nothing" {
    run scenario up needs-ike --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"strongswan"* ]]
    [[ "$output" == *"strongSwan arrives with the next bundle cut"* ]]
    ! grep -q import "$FAKE_GNS3/requests.log" 2>/dev/null
}

@test "up refuses an image that is in the bundle but not loaded" {
    : > "$BATS_TEST_TMPDIR/images.txt"
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"docker.io/nicolaka/netshoot:0.0.0-fixture is not loaded"* ]]
}

@test "up refuses a scenario that is already up, and --force takes it down first" {
    seed_project p1 lab-scenario-demo opened demo
    run scenario up demo --bundle "$BUNDLE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"demo is already up"* ]]
    run scenario up demo --bundle "$BUNDLE" --force
    echo "$output"
    [ "$status" -eq 0 ]
    d=$(grep -n '^DELETE /v3/projects/p1$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    i=$(grep -n '/import?name=lab-scenario-demo$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    [ -n "$d" ] && [ -n "$i" ] && [ "$d" -lt "$i" ]
}

@test "up refuses a same-named project without the kit's marker" {
    seed_project p9 lab-scenario-demo opened ""
    run scenario up demo --bundle "$BUNDLE" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"without the kit's marker"* ]]
    ! grep -q '^DELETE' "$FAKE_GNS3/requests.log"
}

@test "up skips TAPs an opened project holds, and refuses when fewer than two are free, naming the holder" {
    seed_project p2 other-lab opened "" lab-tap0 lab-tap1
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"taps: lab-tap2 lab-tap3"* ]]
    rm -f "$FAKE_GNS3/projects.json"
    seed_project p2 other-lab opened "" lab-tap0 lab-tap1 lab-tap2
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"fewer than two free kit TAPs (held by: other-lab"* ]]
}

@test "up --taps binds the named TAPs, and refuses one that is held or is not a kit TAP" {
    run scenario up demo --bundle "$BUNDLE" --taps lab-tap3,lab-tap1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"taps: lab-tap3 lab-tap1"* ]]
    run scenario down demo
    seed_project p2 other-lab opened "" lab-tap2
    run scenario up demo --bundle "$BUNDLE" --taps lab-tap2,lab-tap0
    [ "$status" -eq 1 ]
    [[ "$output" == *"lab-tap2 is held by GNS3 project other-lab"* ]]
    run scenario up demo --bundle "$BUNDLE" --taps eth0,lab-tap0
    [ "$status" -eq 1 ]
    [[ "$output" == *"eth0 is not a kit TAP"* ]]
    run scenario up demo --bundle "$BUNDLE" --taps lab-tap0
    [ "$status" -eq 1 ]
    [[ "$output" == *"--taps takes two different kit TAPs"* ]]
}

@test "up FAILs when the scenario never becomes ready, leaves the nodes up, and prints the down command" {
    echo 1 > "$BATS_TEST_TMPDIR/rc-exec-cid-a"
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  demo did not become ready within 4s"* ]]
    [[ "$output" == *"r770-scenario.sh down demo"* ]]
    ! grep -q '^DELETE' "$FAKE_GNS3/requests.log"
}

@test "up FAILs when the nodes never start, and says how to take them down" {
    touch "$FAKE_GNS3/never-starts"
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  not started after 4s: a b"* ]]
    [[ "$output" == *"r770-scenario.sh down demo"* ]]
}

@test "up dies when GNS3 refuses the import, and starts nothing" {
    touch "$FAKE_GNS3/import-fails"
    run scenario up demo --bundle "$BUNDLE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GNS3 refused the import"* ]]
    ! grep -q '/nodes/start' "$FAKE_GNS3/requests.log"
}

@test "up --dry-run prints the calls and imports nothing" {
    run scenario up demo --bundle "$BUNDLE" --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: POST /projects/"*"/import?name=lab-scenario-demo"* ]]
    [ ! -s "$FAKE_GNS3/projects.json" ] || ! grep -q lab-scenario-demo "$FAKE_GNS3/projects.json"
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `bats tests/scenario.bats --filter 'up'`
Expected: the 11 `up` tests `not ok` (`unknown subcommand: up`).

- [ ] **Step 3: Implement `up`**

Insert directly above the line `# ── dispatch ─────...` in `scripts/r770-scenario.sh`:

```bash
# ── up ───────────────────────────────────────────────────────────────────────
taps_in_use() {  # taps_in_use — "<tap> <project-name>" for every TAP a Cloud node of an opened project holds
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
                frr.conf)     run docker exec -i "$cid" sh -c 'cat > /tmp/lab-frr.conf && vtysh -f /tmp/lab-frr.conf' < "$f" ;;
                swanctl.conf) run docker exec -i "$cid" sh -c 'mkdir -p /etc/swanctl && cat > /etc/swanctl/swanctl.conf && swanctl --load-all' < "$f" ;;
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
    loaded=$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
    for i in $(conf "$NAME" images); do
        ref=$(image_ref "$b" "$i")
        printf '%s\n' "$loaded" | grep -qxF "$ref" || die "$ref is not loaded — run r770-gns3-deploy.sh load --bundle <dir>"
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

```

Add the globals `up` needs: replace
```bash
BUNDLE=""; NAME=""; WORK=""; AUTH_HDR=""
```
with
```bash
BUNDLE=""; NAME=""; WORK=""; AUTH_HDR=""
WAIT_SECS="${SCENARIO_WAIT_SECS:-120}"
LAB_TAPS="${GNS3_LAB_TAPS:-4}"
TAPS=""; TAP_A=""; TAP_B=""
```
and in the option parser, after `        --bundle)  BUNDLE="${2:-}"; shift ;;` add:
```bash
        --taps)    TAPS="${2:-}"; shift ;;
```

In the dispatch, replace
```bash
    down)
        [ -n "$NAME" ] || die "$SUB needs a scenario name (see: r770-scenario.sh list)"
        cmd_down ;;
```
with
```bash
    up|down)
        [ -n "$NAME" ] || die "$SUB needs a scenario name (see: r770-scenario.sh list)"
        "cmd_$SUB" ;;
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `bats tests/scenario.bats`
Expected: 20 tests, all `ok`.

Run: `./tests/run.sh`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-scenario.sh tests/scenario.bats
git commit -m "r770-scenario.sh up: import, start, configure with docker exec, wait until ready

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 3: `traffic` and `status`

**Files:**
- Modify: `scripts/r770-scenario.sh` (functions above `# ── dispatch`; dispatch arms)
- Modify: `tests/scenario.bats` (append)

**Interfaces:**
- Consumes: Task 1's helpers; Task 2's `ready_check`, `$WORK/nodes.tsv` convention.
- Produces: `cmd_traffic`, `cmd_status`; run record file `${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}/scenario-<name>-<host>-<YYYYmmdd-HHMMSS>.run` with keys `scenario range project taps start end secs nodes_ok nodes_failed expect`.

- [ ] **Step 1: Append the failing tests**

Append to `tests/scenario.bats`:

```bash
# ── traffic / status ───────────────────────────────────────────────────────

up_demo() { run scenario up demo --bundle "$BUNDLE"; [ "$status" -eq 0 ]; : > "$STUB_LOG"; }

@test "traffic refuses a scenario that is not up" {
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"demo is not up"* ]]
}

@test "traffic runs traffic.sh in each traffic node, in order, and writes a run record" {
    up_demo
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 0 ]
    b=$(grep -n '^docker exec -i cid-b sh -s b 5$' "$STUB_LOG" | cut -d: -f1)
    a=$(grep -n '^docker exec -i cid-a sh -s a 5$' "$STUB_LOG" | cut -d: -f1)
    [ -n "$b" ] && [ -n "$a" ] && [ "$b" -lt "$a" ]
    rec=$(find "$KIT_EVIDENCE_DIR" -name 'scenario-demo-fixturehost-*.run')
    [ -n "$rec" ]
    for k in scenario=demo range=10.209.0.0/16 project=lab-scenario-demo taps=lab-tap0,lab-tap1 secs=5 nodes_ok=2 nodes_failed=0 expect=scenarios/demo/expect.txt; do
        grep -qx "$k" "$rec"
    done
    grep -qE '^start=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$rec"
    grep -qE '^end=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$rec"
    [[ "$output" == *"PASS  traffic ran in every node: b a"* ]]
}

@test "SCENARIO_TRAFFIC_SECS overrides the scenario's window" {
    up_demo
    SCENARIO_TRAFFIC_SECS=9 run scenario traffic demo
    [ "$status" -eq 0 ]
    grep -q '^docker exec -i cid-a sh -s a 9$' "$STUB_LOG"
}

@test "traffic WARNs when one node's generator fails and FAILs when none ran" {
    up_demo
    echo 1 > "$BATS_TEST_TMPDIR/rc-execi-cid-b"
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  traffic failed in: b (ran in: a)"* ]]
    echo 1 > "$BATS_TEST_TMPDIR/rc-execi-cid-a"
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  no traffic generator ran (failed in: b a)"* ]]
}

@test "traffic refuses when the scenario is up but not ready, and generates nothing" {
    up_demo
    echo 1 > "$BATS_TEST_TMPDIR/rc-exec-cid-a"
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"up but not ready"* ]]
    ! grep -q 'sh -s b' "$STUB_LOG"
}

@test "status lists each scenario's state, TAPs and last run record" {
    up_demo
    run scenario traffic demo
    run scenario status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"demo"*"up"*"lab-tap0,lab-tap1"*"scenario-demo-fixturehost-"* ]]
    [[ "$output" == *"needs-ike"*"down"*"none"* ]]
}

@test "status without a reachable GNS3 still lists the pack, state unknown" {
    touch "$FAKE_GNS3/down"
    run scenario status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"running state unknown"* ]]
    [[ "$output" == *"demo"*"unknown"* ]]
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `bats tests/scenario.bats --filter 'traffic|status'`
Expected: the 7 new tests `not ok` (`unknown subcommand`).

- [ ] **Step 3: Implement**

Insert directly above the line `# ── dispatch ─────...`:

```bash
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
    local c n pid state taps last live=0 ev="${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}"
    if curl -sS --max-time 5 --fail http://127.0.0.1:3080/v3/version >/dev/null 2>&1 && [ -s "$(p "$SECRET")" ]; then
        gns3_login; live=1
    else
        note "GNS3 is not answering on 127.0.0.1:3080 (or there is no admin credential) — running state unknown"
    fi
    for c in "$SCEN_DIR"/*/scenario.conf; do
        [ -e "$c" ] || continue
        n=$(basename "$(dirname "$c")"); state="unknown"; taps="-"
        if [ "$live" = "1" ]; then
            pid=$(our_project "$n") || pid=""
            case "$pid" in
                "")      state="down" ;;
                FOREIGN) state="name-taken" ;;
                *)       state="up"; taps=$(nodes "$pid" 2>/dev/null | awk -F'\t' '$5 != "" {print $5}' | paste -sd, -) ;;
            esac
        fi
        last=$(find "$ev" -maxdepth 1 -name "scenario-$n-*.run" 2>/dev/null | sort | tail -1)
        printf '%-16s %-10s taps %-26s last run %s\n' "$n" "$state" "${taps:--}" "${last:-none}"
    done
    return 0
}

```

In the dispatch, replace
```bash
    up|down)
        [ -n "$NAME" ] || die "$SUB needs a scenario name (see: r770-scenario.sh list)"
        "cmd_$SUB" ;;
```
with
```bash
    up|traffic|down)
        [ -n "$NAME" ] || die "$SUB needs a scenario name (see: r770-scenario.sh list)"
        "cmd_$SUB" ;;
    status) cmd_status ;;
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `bats tests/scenario.bats`
Expected: 27 tests, all `ok`.

Run: `./tests/run.sh`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-scenario.sh tests/scenario.bats
git commit -m "r770-scenario.sh traffic and status: a bounded window and a run record per run

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 4: The first two scenarios and the content lint

**Files:**
- Create: `scenarios/client-server/{scenario.conf,project/client-server.gns3,nodes/cl.sh,nodes/srv.sh,traffic.sh,expect.txt}`
- Create: `scenarios/ipsec-esp/{scenario.conf,project/ipsec-esp.gns3,nodes/cl-a.sh,nodes/gw-a.sh,nodes/gw-b.sh,nodes/cl-b.sh,traffic.sh,expect.txt}`
- Create: `tests/helpers/lint_scenarios.py`, `tests/scenarios.bats`
- Modify: `tests/no-internet.bats` (one new test)

**Interfaces:**
- Consumes: the scenario file contract Tasks 1–3 read (`scenario.conf` keys `name description range images traffic_secs ready traffic_nodes`; `project/<name>.gns3` with tokens `__PROJECT_NAME__ __PROJECT_ID__ __SCENARIO__ __TAP_A__ __TAP_B__ __IMG_<X>__`; `nodes/<node>.{sh,frr.conf,swanctl.conf}`; `traffic.sh <node> <secs>`; `expect.txt` lines `proto|port|src|dst`).
- Produces: `tests/helpers/lint_scenarios.py <check>` with checks `layout json topology images addresses expect` (Task 5 relies on it unchanged).

- [ ] **Step 1: Write the lint and its suite**

`tests/helpers/lint_scenarios.py`:

```python
#!/usr/bin/env python3
"""Lint the kit's scenario pack (scenarios/<name>/...). Usage: lint_scenarios.py <check>

Checks: layout json topology images addresses expect. Prints one line per
problem and exits 1 if there are any. Run from the repo root.
"""
import ipaddress
import json
import os
import re
import sys

ROOT = "scenarios"
KEYS = ["name", "description", "range", "images", "traffic_secs", "ready", "traffic_nodes"]
UPSTREAM_PENDING = {"strongswan"}  # added to the build repo's pin block, not yet in a bundle
PROTOS = {"tcp", "udp", "icmp", "esp", "ospf"}


def scenarios():
    return sorted(d for d in os.listdir(ROOT) if os.path.isfile(os.path.join(ROOT, d, "scenario.conf")))


def conf(s):
    out = {}
    with open(os.path.join(ROOT, s, "scenario.conf")) as f:
        for line in f:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out.setdefault(k, v)
    return out


def project(s):
    with open(os.path.join(ROOT, s, "project", s + ".gns3")) as f:
        return json.load(f)


def bundled_images():
    names = set()
    with open("staging/r770-offline-fetch.sh") as f:
        text = f.read()
    block = re.search(r"GNS3_NODE_IMAGES=\((.*?)\)", text, re.S).group(1)
    for ref in re.findall(r'"([^"]+)"', block):
        if ref.startswith("$"):
            ref = re.search(r'FRR_IMG="\$\{FRR_IMG:-([^}]+)\}"', text).group(1)
        names.add(ref.split("/")[-1].split(":")[0])
    return names


def check_layout(s, c, errs):
    for k in KEYS:
        if not c.get(k):
            errs.append(f"{s}: scenario.conf lacks {k}=")
    if c.get("name") != s:
        errs.append(f"{s}: name= is {c.get('name')!r}, not the directory name")
    for f in ("traffic.sh", "expect.txt", os.path.join("project", s + ".gns3")):
        if not os.path.isfile(os.path.join(ROOT, s, f)):
            errs.append(f"{s}: missing {f}")
    if "|" not in c.get("ready", ""):
        errs.append(f"{s}: ready= must be <node>|<command>")
    if not c.get("traffic_secs", "").isdigit():
        errs.append(f"{s}: traffic_secs= must be whole seconds")


def check_json(s, c, errs):
    try:
        p = project(s)
    except (OSError, ValueError) as e:
        errs.append(f"{s}: project does not parse: {e}")
        return
    if p.get("name") != "__PROJECT_NAME__" or p.get("project_id") != "__PROJECT_ID__":
        errs.append(f"{s}: project name/project_id must be __PROJECT_NAME__/__PROJECT_ID__")
    if {"name": "r770_scenario", "value": "__SCENARIO__"} not in (p.get("variables") or []):
        errs.append(f"{s}: project lacks the r770_scenario=__SCENARIO__ variable")
    if "version" in p:
        errs.append(f"{s}: project carries a version field (no pins; revision identifies the format)")


def check_topology(s, c, errs):
    p = project(s)
    nodes = p["topology"]["nodes"]
    clouds = [n for n in nodes if n["node_type"] == "cloud"]
    ports = sorted(m.get("interface") for n in clouds for m in n["properties"].get("ports_mapping", []))
    if ports != ["__TAP_A__", "__TAP_B__"]:
        errs.append(f"{s}: Cloud ports must be exactly __TAP_A__ and __TAP_B__ (got {ports})")
    for n in clouds:
        for m in n["properties"].get("ports_mapping", []):
            if m.get("type") != "tap":
                errs.append(f"{s}: Cloud {n['name']} port {m.get('interface')} is not \"type\": \"tap\"")
    ids = {n["node_id"] for n in nodes}
    cloud_ids = {n["node_id"] for n in clouds}
    on_clouds = 0
    for link in p["topology"]["links"]:
        ends = [e["node_id"] for e in link["nodes"]]
        if any(e not in ids for e in ends):
            errs.append(f"{s}: link {link['link_id']} names an unknown node")
        on_clouds += any(e in cloud_ids for e in ends)
    if on_clouds != 2:
        errs.append(f"{s}: exactly two links attach to the Clouds (got {on_clouds})")
    docker = {n["name"] for n in nodes if n["node_type"] == "docker"}
    named = {c["ready"].split("|", 1)[0]} | set(c["traffic_nodes"].split())
    for f in os.listdir(os.path.join(ROOT, s, "nodes")) if os.path.isdir(os.path.join(ROOT, s, "nodes")) else []:
        named.add(f.split(".", 1)[0])
    for n in sorted(named - docker):
        errs.append(f"{s}: {n} is named in the scenario but is not a docker node of the project")


def check_images(s, c, errs):
    known = bundled_images() | UPSTREAM_PENDING
    listed = c.get("images", "").split()
    for i in listed:
        if i not in known:
            errs.append(f"{s}: image {i} is neither bundled (GNS3_NODE_IMAGES) nor upstream-pending")
    want = {"__IMG_" + i.upper().replace("-", "_") + "__" for i in listed}
    for n in project(s)["topology"]["nodes"]:
        if n["node_type"] == "docker" and n["properties"].get("image") not in want:
            errs.append(f"{s}: node {n['name']} image {n['properties'].get('image')!r} is not one of {sorted(want)}")


def check_addresses(s, c, errs):
    net = ipaddress.ip_network(c["range"])
    files = ["traffic.sh", "expect.txt", "scenario.conf"]
    nd = os.path.join(ROOT, s, "nodes")
    if os.path.isdir(nd):
        files += [os.path.join("nodes", f) for f in os.listdir(nd)]
    for f in files:
        with open(os.path.join(ROOT, s, f)) as fh:
            text = fh.read()
        for a in re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", text):
            ip = ipaddress.ip_address(a)
            if ip in net or ip.is_multicast or ip == ipaddress.ip_address("0.0.0.0"):
                continue
            errs.append(f"{s}: {f} names {a}, outside {net}")


def check_expect(s, c, errs):
    net = ipaddress.ip_network(c["range"])
    with open(os.path.join(ROOT, s, "expect.txt")) as f:
        lines = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    if not lines:
        errs.append(f"{s}: expect.txt is empty")
    for line in lines:
        parts = line.split("|")
        if len(parts) != 4:
            errs.append(f"{s}: expect.txt line {line!r} is not proto|port|src|dst")
            continue
        proto, port, src, dst = parts
        if proto not in PROTOS:
            errs.append(f"{s}: expect.txt proto {proto!r} not in {sorted(PROTOS)}")
        if port and not port.isdigit():
            errs.append(f"{s}: expect.txt port {port!r} is not a number")
        for r in (src, dst):
            n = ipaddress.ip_network(r)
            if not (n.subnet_of(net) or n.is_multicast):
                errs.append(f"{s}: expect.txt range {r} is outside {net}")


def main():
    check = sys.argv[1]
    errs = []
    names = scenarios()
    if check == "layout" and not names:
        errs.append("no scenarios under scenarios/")
    ranges = {}
    for s in names:
        c = conf(s)
        if check == "layout":
            check_layout(s, c, errs)
            ranges.setdefault(c.get("range"), []).append(s)
        else:
            globals()["check_" + check](s, c, errs)
    for r, ss in ranges.items():
        if len(ss) > 1:
            errs.append(f"range {r} is shared by {ss}")
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
```

`tests/scenarios.bats`:

```bash
#!/usr/bin/env bats
#
# The scenario pack's content, linted offline: layout, project JSON, the two
# TAP-type Cloud ports, images the bundle can carry, addresses that stay in
# each scenario's own range, and shell that shellcheck accepts. Whether FRR
# converges or a tunnel carries traffic is proven on the staging rehearsal.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

lint() { run python3 tests/helpers/lint_scenarios.py "$1"; echo "$output"; [ "$status" -eq 0 ]; }

@test "the pack holds the scenarios the kit documents" {
    for s in client-server ipsec-esp; do [ -f "scenarios/$s/scenario.conf" ] || { echo "missing $s"; false; }; done
}

@test "every scenario has its files and a complete scenario.conf, and ranges are unique" { lint layout; }
@test "every project parses as JSON and carries the kit's name, id and marker tokens" { lint json; }
@test "every project has exactly two TAP-type Cloud ports and the nodes the scenario names" { lint topology; }
@test "every image is bundled or upstream-pending, and nodes use only the scenario's image tokens" { lint images; }
@test "every address a scenario names lies in its own range" { lint addresses; }
@test "every expect.txt line is proto|port|src|dst inside the scenario's range" { lint expect; }

@test "every traffic.sh and node script is shellcheck-clean as POSIX sh" {
    run shellcheck -s sh scenarios/*/traffic.sh scenarios/*/nodes/*.sh
    echo "$output"
    [ "$status" -eq 0 ]
}
```

In `tests/no-internet.bats`, append:

```bash
@test "scenario traffic stays inside the lab ranges" {
    bad=$(grep -rnoE 'https?://[A-Za-z0-9._:-]+' scenarios/ | grep -vE '://10[.]20[1-5][.][0-9]+[.][0-9]+(:|/|$)' || true)
    echo "outside the lab: $bad"
    [ -z "$bad" ]
}
```

- [ ] **Step 2: Run the suite to confirm it fails**

Run: `bats tests/scenarios.bats`
Expected: `not ok` for all (no `scenarios/` directory yet — the lint raises).

- [ ] **Step 3: Create `scenarios/client-server/`**

`scenarios/client-server/scenario.conf`:
```
name=client-server
description=netshoot client and alpine web server on either side of br-lab
range=10.205.0.0/16
images=netshoot alpine
traffic_secs=60
ready=cl|curl -sf -m 2 -o /dev/null http://10.205.0.20/
traffic_nodes=cl
```

`scenarios/client-server/project/client-server.gns3`:
```json
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [],
    "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000005-0000-4000-8000-000000000001", "name": "cl", "node_type": "docker", "x": -200, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000005-0000-4000-8000-000000000002", "name": "srv", "node_type": "docker", "x": 200, "y": 0,
       "properties": {"image": "__IMG_ALPINE__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000005-0000-4000-8000-000000000003", "name": "tap-a", "node_type": "cloud", "x": -60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000005-0000-4000-8000-000000000004", "name": "tap-b", "node_type": "cloud", "x": 60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000005-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000005-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000005-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000005-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000005-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000005-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
```

`scenarios/client-server/nodes/cl.sh`:
```sh
# cl: the client, on br-lab through tap-a
set -e
ip addr replace 10.205.0.10/24 dev eth0
ip link set dev eth0 up
```

`scenarios/client-server/nodes/srv.sh`:
```sh
# srv: busybox httpd serving one page, on br-lab through tap-b
set -e
ip addr replace 10.205.0.20/24 dev eth0
ip link set dev eth0 up
mkdir -p /www
echo "lab-scenario client-server" > /www/index.html
httpd -p 80 -h /www
```

`scenarios/client-server/traffic.sh`:
```sh
#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl pings the server, then fetches its page every half second for the window.
node=$1 secs=$2
case "$node" in
    cl)
        ping -c 3 10.205.0.20 || exit 1
        end=$(( $(date +%s) + secs ))
        while [ "$(date +%s)" -lt "$end" ]; do
            curl -sf -m 2 -o /dev/null http://10.205.0.20/ || exit 1
            sleep 0.5
        done ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

`scenarios/client-server/expect.txt`:
```
icmp||10.205.0.10/32|10.205.0.20/32
tcp|80|10.205.0.10/32|10.205.0.20/32
```

- [ ] **Step 4: Create `scenarios/ipsec-esp/`**

`scenarios/ipsec-esp/scenario.conf`:
```
name=ipsec-esp
description=static kernel ESP tunnel (ip xfrm) between two gateways across br-lab
range=10.201.0.0/16
images=netshoot
traffic_secs=60
ready=cl-a|ping -c 1 -W 2 10.201.2.10
traffic_nodes=cl-b cl-a
```

`scenarios/ipsec-esp/project/ipsec-esp.gns3`:
```json
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [],
    "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000001-0000-4000-8000-000000000001", "name": "cl-a", "node_type": "docker", "x": -400, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000001-0000-4000-8000-000000000002", "name": "gw-a", "node_type": "docker", "x": -200, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 2, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000001-0000-4000-8000-000000000003", "name": "gw-b", "node_type": "docker", "x": 200, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 2, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000001-0000-4000-8000-000000000004", "name": "cl-b", "node_type": "docker", "x": 400, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000001-0000-4000-8000-000000000005", "name": "tap-a", "node_type": "cloud", "x": -60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000001-0000-4000-8000-000000000006", "name": "tap-b", "node_type": "cloud", "x": 60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000001-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000001-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000001-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000001-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000001-0000-4000-8000-000000000002", "adapter_number": 1, "port_number": 0},
        {"node_id": "00000001-0000-4000-8000-000000000005", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000001-0000-4000-9000-000000000003", "nodes": [
        {"node_id": "00000001-0000-4000-8000-000000000006", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000001-0000-4000-8000-000000000003", "adapter_number": 1, "port_number": 0}]},
      {"link_id": "00000001-0000-4000-9000-000000000004", "nodes": [
        {"node_id": "00000001-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000001-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
```

`scenarios/ipsec-esp/nodes/cl-a.sh`:
```sh
# cl-a: client behind gw-a
set -e
ip addr replace 10.201.1.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.201.1.1
```

`scenarios/ipsec-esp/nodes/cl-b.sh`:
```sh
# cl-b: client behind gw-b
set -e
ip addr replace 10.201.2.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.201.2.1
```

`scenarios/ipsec-esp/nodes/gw-a.sh`:
```sh
# gw-a: 10.201.1.0/24 <-> ESP tunnel to gw-b across br-lab (eth1, 10.201.0.0/24).
# Manually keyed: lab keys, not secrets -- they only ever protect lab traffic.
set -e
ip addr replace 10.201.1.1/24 dev eth0
ip addr replace 10.201.0.1/24 dev eth1
ip link set dev eth0 up
ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace 10.201.2.0/24 via 10.201.0.2
ip xfrm state flush
ip xfrm policy flush
ip xfrm state add src 10.201.0.1 dst 10.201.0.2 proto esp spi 0x201a mode tunnel \
    enc 'cbc(aes)' 0x2010aaaa2010aaaa2010aaaa2010aaaa \
    auth 'hmac(sha256)' 0x2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb
ip xfrm state add src 10.201.0.2 dst 10.201.0.1 proto esp spi 0x201b mode tunnel \
    enc 'cbc(aes)' 0x2010cccc2010cccc2010cccc2010cccc \
    auth 'hmac(sha256)' 0x2010dddd2010dddd2010dddd2010dddd2010dddd2010dddd2010dddd2010dddd
ip xfrm policy add src 10.201.1.0/24 dst 10.201.2.0/24 dir out tmpl src 10.201.0.1 dst 10.201.0.2 proto esp mode tunnel
ip xfrm policy add src 10.201.2.0/24 dst 10.201.1.0/24 dir in tmpl src 10.201.0.2 dst 10.201.0.1 proto esp mode tunnel
ip xfrm policy add src 10.201.2.0/24 dst 10.201.1.0/24 dir fwd tmpl src 10.201.0.2 dst 10.201.0.1 proto esp mode tunnel
```

`scenarios/ipsec-esp/nodes/gw-b.sh`:
```sh
# gw-b: 10.201.2.0/24 <-> ESP tunnel to gw-a across br-lab (eth1). The mirror
# image of gw-a: same SAs, directions swapped.
set -e
ip addr replace 10.201.2.1/24 dev eth0
ip addr replace 10.201.0.2/24 dev eth1
ip link set dev eth0 up
ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace 10.201.1.0/24 via 10.201.0.1
ip xfrm state flush
ip xfrm policy flush
ip xfrm state add src 10.201.0.1 dst 10.201.0.2 proto esp spi 0x201a mode tunnel \
    enc 'cbc(aes)' 0x2010aaaa2010aaaa2010aaaa2010aaaa \
    auth 'hmac(sha256)' 0x2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb
ip xfrm state add src 10.201.0.2 dst 10.201.0.1 proto esp spi 0x201b mode tunnel \
    enc 'cbc(aes)' 0x2010cccc2010cccc2010cccc2010cccc \
    auth 'hmac(sha256)' 0x2010dddd2010dddd2010dddd2010dddd2010dddd2010dddd2010dddd2010dddd
ip xfrm policy add src 10.201.2.0/24 dst 10.201.1.0/24 dir out tmpl src 10.201.0.2 dst 10.201.0.1 proto esp mode tunnel
ip xfrm policy add src 10.201.1.0/24 dst 10.201.2.0/24 dir in tmpl src 10.201.0.1 dst 10.201.0.2 proto esp mode tunnel
ip xfrm policy add src 10.201.1.0/24 dst 10.201.2.0/24 dir fwd tmpl src 10.201.0.1 dst 10.201.0.2 proto esp mode tunnel
```

`scenarios/ipsec-esp/traffic.sh`:
```sh
#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl-b serves one iperf3 run; cl-a pings through the tunnel, then pushes iperf3.
node=$1 secs=$2
case "$node" in
    cl-b) iperf3 -s -D -1 ;;
    cl-a) ping -c 5 -i 0.2 10.201.2.10 && iperf3 -c 10.201.2.10 -t "$secs" ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

`scenarios/ipsec-esp/expect.txt`:
```
esp||10.201.0.1/32|10.201.0.2/32
esp||10.201.0.2/32|10.201.0.1/32
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `bats tests/scenarios.bats`
Expected: 8 tests, all `ok`.

Run: `./tests/run.sh`
Expected: all `ok` (including `no-pins.bats` over `scenarios/` and the new `no-internet.bats` test).

- [ ] **Step 6: Commit**

```bash
git add scenarios tests/helpers/lint_scenarios.py tests/scenarios.bats tests/no-internet.bats
git commit -m "Add the client-server and ipsec-esp scenarios and a lint for the pack

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 5: `ospf`, `bgp` and `ipsec-ike`

**Files:**
- Create: `scenarios/ospf/{scenario.conf,project/ospf.gns3,nodes/h-a.sh,nodes/h-b.sh,nodes/r1.sh,nodes/r2.sh,nodes/r3.sh,nodes/r1.frr.conf,nodes/r2.frr.conf,nodes/r3.frr.conf,traffic.sh,expect.txt}`
- Create: `scenarios/bgp/{scenario.conf,project/bgp.gns3,nodes/h-a.sh,nodes/h-b.sh,nodes/r1.sh,nodes/r2.sh,nodes/r1.frr.conf,nodes/r2.frr.conf,traffic.sh,expect.txt}`
- Create: `scenarios/ipsec-ike/{scenario.conf,project/ipsec-ike.gns3,nodes/cl-a.sh,nodes/cl-b.sh,nodes/gw-a.sh,nodes/gw-b.sh,nodes/gw-a.swanctl.conf,nodes/gw-b.swanctl.conf,traffic.sh,expect.txt}`
- Modify: `tests/scenarios.bats` (the pack test)

**Interfaces:**
- Consumes: the scenario file contract and `tests/helpers/lint_scenarios.py` from Task 4, unchanged.
- Produces: the full five-scenario pack.

- [ ] **Step 1: Make the pack test fail**

In `tests/scenarios.bats`, replace
```bash
    for s in client-server ipsec-esp; do [ -f "scenarios/$s/scenario.conf" ] || { echo "missing $s"; false; }; done
```
with
```bash
    for s in client-server ipsec-esp ipsec-ike ospf bgp; do [ -f "scenarios/$s/scenario.conf" ] || { echo "missing $s"; false; }; done
    [ "$(find scenarios -mindepth 2 -maxdepth 2 -name scenario.conf | wc -l)" -eq 5 ]
```

Run: `bats tests/scenarios.bats --filter 'pack holds'`
Expected: `not ok` (`missing ipsec-ike`).

- [ ] **Step 2: Create `scenarios/ospf/`**

`scenarios/ospf/scenario.conf`:
```
name=ospf
description=three FRR routers in a line running OSPF area 0; r2-r3 crosses br-lab
range=10.203.0.0/16
images=netshoot frr
traffic_secs=60
ready=h-a|ping -c 1 -W 2 10.203.3.10
traffic_nodes=h-b h-a
```

`scenarios/ospf/project/ospf.gns3`:
```json
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [],
    "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000003-0000-4000-8000-000000000001", "name": "h-a", "node_type": "docker", "x": -500, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000003-0000-4000-8000-000000000002", "name": "r1", "node_type": "docker", "x": -300, "y": 0,
       "properties": {"image": "__IMG_FRR__", "adapters": 2, "start_command": "sh -c \"sed -i -e 's/^ospfd=no/ospfd=yes/' -e 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons && exec /usr/lib/frr/docker-start\"", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000003-0000-4000-8000-000000000003", "name": "r2", "node_type": "docker", "x": -100, "y": 0,
       "properties": {"image": "__IMG_FRR__", "adapters": 2, "start_command": "sh -c \"sed -i -e 's/^ospfd=no/ospfd=yes/' -e 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons && exec /usr/lib/frr/docker-start\"", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000003-0000-4000-8000-000000000004", "name": "r3", "node_type": "docker", "x": 300, "y": 0,
       "properties": {"image": "__IMG_FRR__", "adapters": 2, "start_command": "sh -c \"sed -i -e 's/^ospfd=no/ospfd=yes/' -e 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons && exec /usr/lib/frr/docker-start\"", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000003-0000-4000-8000-000000000005", "name": "h-b", "node_type": "docker", "x": 500, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000003-0000-4000-8000-000000000006", "name": "tap-a", "node_type": "cloud", "x": 40, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000003-0000-4000-8000-000000000007", "name": "tap-b", "node_type": "cloud", "x": 160, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000003-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000003-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000003-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000003-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000003-0000-4000-8000-000000000002", "adapter_number": 1, "port_number": 0},
        {"node_id": "00000003-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000003-0000-4000-9000-000000000003", "nodes": [
        {"node_id": "00000003-0000-4000-8000-000000000003", "adapter_number": 1, "port_number": 0},
        {"node_id": "00000003-0000-4000-8000-000000000006", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000003-0000-4000-9000-000000000004", "nodes": [
        {"node_id": "00000003-0000-4000-8000-000000000007", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000003-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000003-0000-4000-9000-000000000005", "nodes": [
        {"node_id": "00000003-0000-4000-8000-000000000004", "adapter_number": 1, "port_number": 0},
        {"node_id": "00000003-0000-4000-8000-000000000005", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
```

`scenarios/ospf/nodes/h-a.sh`:
```sh
# h-a: host behind r1
set -e
ip addr replace 10.203.1.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.203.1.1
```

`scenarios/ospf/nodes/h-b.sh`:
```sh
# h-b: host behind r3
set -e
ip addr replace 10.203.3.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.203.3.1
```

`scenarios/ospf/nodes/r1.sh`, `scenarios/ospf/nodes/r2.sh` and `scenarios/ospf/nodes/r3.sh` (identical content; addresses come from each router's frr.conf):
```sh
# a router: links up and forwarding on; addresses and OSPF come from its frr.conf
set -e
ip link set dev eth0 up
ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
```

`scenarios/ospf/nodes/r1.frr.conf`:
```
frr defaults traditional
hostname r1
!
interface eth0
 ip address 10.203.1.1/24
 ip ospf area 0
!
interface eth1
 ip address 10.203.12.1/24
 ip ospf area 0
!
router ospf
 ospf router-id 10.203.0.1
 passive-interface eth0
!
```

`scenarios/ospf/nodes/r2.frr.conf`:
```
frr defaults traditional
hostname r2
!
interface eth0
 ip address 10.203.12.2/24
 ip ospf area 0
!
interface eth1
 ip address 10.203.23.2/24
 ip ospf area 0
!
router ospf
 ospf router-id 10.203.0.2
!
```

`scenarios/ospf/nodes/r3.frr.conf`:
```
frr defaults traditional
hostname r3
!
interface eth0
 ip address 10.203.23.3/24
 ip ospf area 0
!
interface eth1
 ip address 10.203.3.1/24
 ip ospf area 0
!
router ospf
 ospf router-id 10.203.0.3
 passive-interface eth1
!
```

`scenarios/ospf/traffic.sh`:
```sh
#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# h-b serves one iperf3 run; h-a pings across the OSPF path, then pushes iperf3.
node=$1 secs=$2
case "$node" in
    h-b) iperf3 -s -D -1 ;;
    h-a) ping -c 5 -i 0.2 10.203.3.10 && iperf3 -c 10.203.3.10 -t "$secs" ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

`scenarios/ospf/expect.txt`:
```
ospf||10.203.23.0/24|224.0.0.5/32
icmp||10.203.1.0/24|10.203.3.0/24
tcp|5201|10.203.1.0/24|10.203.3.0/24
```

- [ ] **Step 3: Create `scenarios/bgp/`**

`scenarios/bgp/scenario.conf`:
```
name=bgp
description=eBGP between two FRR routers in different ASes across br-lab
range=10.204.0.0/16
images=netshoot frr
traffic_secs=60
ready=h-a|ping -c 1 -W 2 10.204.2.10
traffic_nodes=h-b h-a
```

`scenarios/bgp/project/bgp.gns3`:
```json
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [],
    "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000004-0000-4000-8000-000000000001", "name": "h-a", "node_type": "docker", "x": -400, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000004-0000-4000-8000-000000000002", "name": "r1", "node_type": "docker", "x": -200, "y": 0,
       "properties": {"image": "__IMG_FRR__", "adapters": 2, "start_command": "sh -c \"sed -i -e 's/^ospfd=no/ospfd=yes/' -e 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons && exec /usr/lib/frr/docker-start\"", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000004-0000-4000-8000-000000000003", "name": "r2", "node_type": "docker", "x": 200, "y": 0,
       "properties": {"image": "__IMG_FRR__", "adapters": 2, "start_command": "sh -c \"sed -i -e 's/^ospfd=no/ospfd=yes/' -e 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons && exec /usr/lib/frr/docker-start\"", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000004-0000-4000-8000-000000000004", "name": "h-b", "node_type": "docker", "x": 400, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000004-0000-4000-8000-000000000005", "name": "tap-a", "node_type": "cloud", "x": -60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000004-0000-4000-8000-000000000006", "name": "tap-b", "node_type": "cloud", "x": 60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000004-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000004-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000004-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000004-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000004-0000-4000-8000-000000000002", "adapter_number": 1, "port_number": 0},
        {"node_id": "00000004-0000-4000-8000-000000000005", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000004-0000-4000-9000-000000000003", "nodes": [
        {"node_id": "00000004-0000-4000-8000-000000000006", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000004-0000-4000-8000-000000000003", "adapter_number": 1, "port_number": 0}]},
      {"link_id": "00000004-0000-4000-9000-000000000004", "nodes": [
        {"node_id": "00000004-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000004-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
```

`scenarios/bgp/nodes/h-a.sh`:
```sh
# h-a: host behind r1 (AS 64601)
set -e
ip addr replace 10.204.1.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.204.1.1
```

`scenarios/bgp/nodes/h-b.sh`:
```sh
# h-b: host behind r2 (AS 64602)
set -e
ip addr replace 10.204.2.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.204.2.1
```

`scenarios/bgp/nodes/r1.sh` and `scenarios/bgp/nodes/r2.sh` (identical):
```sh
# a router: links up and forwarding on; addresses and BGP come from its frr.conf
set -e
ip link set dev eth0 up
ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
```

`scenarios/bgp/nodes/r1.frr.conf`:
```
frr defaults traditional
hostname r1
!
interface eth0
 ip address 10.204.1.1/24
!
interface eth1
 ip address 10.204.0.1/24
!
router bgp 64601
 bgp router-id 10.204.0.1
 no bgp ebgp-requires-policy
 neighbor 10.204.0.2 remote-as 64602
 address-family ipv4 unicast
  network 10.204.1.0/24
 exit-address-family
!
```

`scenarios/bgp/nodes/r2.frr.conf`:
```
frr defaults traditional
hostname r2
!
interface eth0
 ip address 10.204.2.1/24
!
interface eth1
 ip address 10.204.0.2/24
!
router bgp 64602
 bgp router-id 10.204.0.2
 no bgp ebgp-requires-policy
 neighbor 10.204.0.1 remote-as 64601
 address-family ipv4 unicast
  network 10.204.2.0/24
 exit-address-family
!
```

`scenarios/bgp/traffic.sh`:
```sh
#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# h-b serves one iperf3 run; h-a pings across the eBGP-learned route, then iperf3.
node=$1 secs=$2
case "$node" in
    h-b) iperf3 -s -D -1 ;;
    h-a) ping -c 5 -i 0.2 10.204.2.10 && iperf3 -c 10.204.2.10 -t "$secs" ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

`scenarios/bgp/expect.txt`:
```
tcp|179|10.204.0.0/24|10.204.0.0/24
icmp||10.204.1.0/24|10.204.2.0/24
tcp|5201|10.204.1.0/24|10.204.2.0/24
```

- [ ] **Step 4: Create `scenarios/ipsec-ike/`**

`scenarios/ipsec-ike/scenario.conf`:
```
name=ipsec-ike
description=IKEv2 + ESP between two strongSwan gateways across br-lab (needs strongswan in the bundle)
range=10.202.0.0/16
images=netshoot strongswan
traffic_secs=60
ready=gw-a|swanctl --list-sas | grep -q INSTALLED
traffic_nodes=cl-b cl-a
```

*Correction (final review, F2):* as shipped, `ipsec-ike`'s readiness is `ready=cl-a|ping -c 1 -W 2 10.202.2.10` and both gateways use `start_action = trap`. With gw-a on `start`, its IKE_SA_INIT can reach gw-b before gw-b's config is loaded; gw-b answers NO_PROPOSAL_CHOSEN and strongSwan does not retry. With both on `trap`, each ping retry re-fires the trap, the same end-to-end readiness as the other scenarios.

`scenarios/ipsec-ike/project/ipsec-ike.gns3`:
```json
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [],
    "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000002-0000-4000-8000-000000000001", "name": "cl-a", "node_type": "docker", "x": -400, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000002-0000-4000-8000-000000000002", "name": "gw-a", "node_type": "docker", "x": -200, "y": 0,
       "properties": {"image": "__IMG_STRONGSWAN__", "adapters": 2, "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000002-0000-4000-8000-000000000003", "name": "gw-b", "node_type": "docker", "x": 200, "y": 0,
       "properties": {"image": "__IMG_STRONGSWAN__", "adapters": 2, "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000002-0000-4000-8000-000000000004", "name": "cl-b", "node_type": "docker", "x": 400, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000002-0000-4000-8000-000000000005", "name": "tap-a", "node_type": "cloud", "x": -60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000002-0000-4000-8000-000000000006", "name": "tap-b", "node_type": "cloud", "x": 60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000002-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000002-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000002-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000002-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000002-0000-4000-8000-000000000002", "adapter_number": 1, "port_number": 0},
        {"node_id": "00000002-0000-4000-8000-000000000005", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000002-0000-4000-9000-000000000003", "nodes": [
        {"node_id": "00000002-0000-4000-8000-000000000006", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000002-0000-4000-8000-000000000003", "adapter_number": 1, "port_number": 0}]},
      {"link_id": "00000002-0000-4000-9000-000000000004", "nodes": [
        {"node_id": "00000002-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000002-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
```

`scenarios/ipsec-ike/nodes/cl-a.sh`:
```sh
# cl-a: client behind gw-a
set -e
ip addr replace 10.202.1.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.202.1.1
```

`scenarios/ipsec-ike/nodes/cl-b.sh`:
```sh
# cl-b: client behind gw-b
set -e
ip addr replace 10.202.2.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.202.2.1
```

`scenarios/ipsec-ike/nodes/gw-a.sh`:
```sh
# gw-a: addresses and forwarding; the tunnel itself comes from gw-a.swanctl.conf
set -e
ip addr replace 10.202.1.1/24 dev eth0
ip addr replace 10.202.0.1/24 dev eth1
ip link set dev eth0 up
ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace 10.202.2.0/24 via 10.202.0.2
```

`scenarios/ipsec-ike/nodes/gw-b.sh`:
```sh
# gw-b: addresses and forwarding; the tunnel itself comes from gw-b.swanctl.conf
set -e
ip addr replace 10.202.2.1/24 dev eth0
ip addr replace 10.202.0.2/24 dev eth1
ip link set dev eth0 up
ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace 10.202.1.0/24 via 10.202.0.1
```

`scenarios/ipsec-ike/nodes/gw-a.swanctl.conf`:
```
# gw-a: IKEv2 with a lab pre-shared key (lab traffic only, not a secret)
connections {
    lab {
        version = 2
        local_addrs = 10.202.0.1
        remote_addrs = 10.202.0.2
        proposals = aes128-sha256-modp2048
        local {
            auth = psk
            id = gw-a
        }
        remote {
            auth = psk
            id = gw-b
        }
        children {
            net {
                local_ts = 10.202.1.0/24
                remote_ts = 10.202.2.0/24
                esp_proposals = aes128-sha256
                start_action = start
            }
        }
    }
}
secrets {
    ike-lab {
        id-a = gw-a
        id-b = gw-b
        secret = "lab-scenario-ipsec-ike"
    }
}
```

`scenarios/ipsec-ike/nodes/gw-b.swanctl.conf`:
```
# gw-b: IKEv2 with a lab pre-shared key (lab traffic only, not a secret)
connections {
    lab {
        version = 2
        local_addrs = 10.202.0.2
        remote_addrs = 10.202.0.1
        proposals = aes128-sha256-modp2048
        local {
            auth = psk
            id = gw-b
        }
        remote {
            auth = psk
            id = gw-a
        }
        children {
            net {
                local_ts = 10.202.2.0/24
                remote_ts = 10.202.1.0/24
                esp_proposals = aes128-sha256
                start_action = trap
            }
        }
    }
}
secrets {
    ike-lab {
        id-a = gw-a
        id-b = gw-b
        secret = "lab-scenario-ipsec-ike"
    }
}
```

`scenarios/ipsec-ike/traffic.sh`:
```sh
#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl-b serves one iperf3 run; cl-a pings through the IKE-keyed tunnel, then iperf3.
node=$1 secs=$2
case "$node" in
    cl-b) iperf3 -s -D -1 ;;
    cl-a) ping -c 5 -i 0.2 10.202.2.10 && iperf3 -c 10.202.2.10 -t "$secs" ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

`scenarios/ipsec-ike/expect.txt`:
```
udp|500|10.202.0.1/32|10.202.0.2/32
esp||10.202.0.1/32|10.202.0.2/32
esp||10.202.0.2/32|10.202.0.1/32
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `bats tests/scenarios.bats`
Expected: 8 tests, all `ok`.

Run: `./tests/run.sh`
Expected: all `ok`.

- [ ] **Step 6: Commit**

```bash
git add scenarios tests/scenarios.bats
git commit -m "Add the ospf, bgp and ipsec-ike scenarios

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 6: Docs and settings

**Files:** `README.md`, `docs/deployment-runbook.md`, `docs/CODEMAPS/stages.md`, `tests/README.md`, `.claude/settings.json`, `docs/kit-sync.md`

**Interfaces:** documentation only; `tests/references.bats` requires every backticked kit path named to exist and every script named in `.claude/settings.json` to exist.

- [ ] **Step 1: `.claude/settings.json`**

Add directly after `"Bash(./scripts/r770-docs-deploy.sh:*)",`:
```json
      "Bash(./scripts/r770-scenario.sh:*)",
```

- [ ] **Step 2: `README.md`**

(a) In the "What's here" table, add after the `scripts/r770-docs-deploy.sh` row:
```markdown
| `scripts/r770-scenario.sh` | The scenario pack's driver: `list`, `up` (import into GNS3, start, configure each node, wait until ready), `traffic` (a bounded window and a run record under `r770-evidence/`), `down`, `status`. Not gated: it touches only the projects it imported |
| `scenarios/` | Five repeatable GNS3 scenarios built from bundled images (`client-server`, `ipsec-esp`, `ospf`, `bgp`, and `ipsec-ike`, which waits for a strongSwan image upstream), each with one link on the mirrored `br-lab` |
```

(b) After the front-door code block (the one ending with `sudo ./scripts/r770-portal-deploy.sh nginx`), add:

````markdown
With GNS3's `labnet` done (and Malcolm's live capture on, to see the traffic),
a scenario from the pack is three commands:

```bash
sudo ./scripts/r770-scenario.sh up ipsec-esp --bundle /srv/bundles/bundle-YYYYMMDD
sudo ./scripts/r770-scenario.sh traffic ipsec-esp     # 60 s of known traffic, a run record in r770-evidence/
sudo ./scripts/r770-scenario.sh down ipsec-esp
```
````

- [ ] **Step 3: `docs/deployment-runbook.md`**

Insert this section directly above `## Docs procedure`:

````markdown
## Scenarios (after GNS3's `labnet`)

```bash
B=/srv/bundles/bundle-YYYYMMDD
sudo ./scripts/r770-scenario.sh list --bundle $B        # which scenarios this bundle can run
sudo ./scripts/r770-scenario.sh up ospf --bundle $B     # import, start, configure, wait until ready
sudo ./scripts/r770-scenario.sh traffic ospf            # known traffic for traffic_secs; run record in r770-evidence/
sudo ./scripts/r770-scenario.sh status                  # what is up, on which TAPs, last run
sudo ./scripts/r770-scenario.sh down ospf               # stop and delete the imported project
```

Each scenario under `scenarios/` is a GNS3 project built only from bundled
images, with exactly one link on `br-lab` through two Cloud nodes bound to
kit TAPs (TAP type, picked free by `up`, or `--taps lab-tapN,lab-tapM`).
`up` configures every node from the scenario's `nodes/` files over
`docker exec` and waits for the scenario's readiness check; if that never
passes, the nodes are left running for inspection and `down` removes them.
`traffic` runs only when the scenario is ready and writes
`scenario-<name>-<host>-<ts>.run` (UTC start/end, range, TAPs) beside the
transcript. `ipsec-ike` refuses until a bundle carries a strongSwan image.
Each scenario owns one /16 (`client-server` 10.205, `ipsec-esp` 10.201,
`ipsec-ike` 10.202, `ospf` 10.203, `bgp` 10.204), so two can share the hub.

What only the staging rehearsal proves — check each once on VM 9770:
the admin login and the project import answer as the kit expects; a Cloud
bound through the TAP tab brings `lab-tapN` to carrier; GNS3's docker nodes
allow `ip addr`, `sysctl` and `ip xfrm`; the FRR nodes' `ospfd`/`bgpd` start
(`vtysh -c 'show ip ospf neighbor'`, `show bgp summary`); with Malcolm's live
capture on, a run's window shows up in Arkime from the scenario's range.

---

````

- [ ] **Step 4: `docs/CODEMAPS/stages.md`**

In the "Subcommands NOT in any `full`" table, add a row after the `docs` row:
```markdown
| scenario | `list` `up` `traffic` `down` `status` | an operator tool, not a deployment step: runs the scenario pack on a deployed GNS3 (after `labnet`); not gated — it touches only the GNS3 projects it imported |
```

- [ ] **Step 5: `tests/README.md`**

Add after the `docs-deploy.bats` row:
```markdown
| `scenario.bats` | `r770-scenario.sh` against a fake GNS3 controller (`helpers/fake_gns3.py`): list, login refusals, the credential kept out of argv, up (render, TAP choice, import/open/start order, node config, readiness), traffic (order, window, run record, WARN/FAIL), down (ours only), status |
| `scenarios.bats` | the scenario pack's content via `helpers/lint_scenarios.py`: layout, project JSON and tokens, two TAP-type Cloud ports, images bundled or upstream-pending, addresses inside each range, `expect.txt` shape, shellcheck on node and traffic scripts |
```

- [ ] **Step 6: `docs/kit-sync.md`**

In "Follow-ups recorded here, not silently added", append:
```markdown
- **strongSwan image (to add in the build repo).** `scenarios/ipsec-ike` needs
  a strongSwan image in `GNS3_NODE_IMAGES` (the pin block in
  `staging/r770-offline-fetch.sh`, edited in the build repo and resynced).
  Until a bundle carries it, `r770-scenario.sh up ipsec-ike` refuses by name.
  The image must start charon by itself and carry `swanctl` and `iproute2`.
- **Wiki scenarios section (to carry to the build repo).** `docs/wiki/gns3.md`
  can gain a "Scenario pack" section pointing analysts at
  `r770-scenario.sh list|up|traffic|down`.
```

- [ ] **Step 7: Verify and run the gate**

Run: `./tests/run.sh`
Expected: all `ok`.

- [ ] **Step 8: Commit**

```bash
git add README.md docs/deployment-runbook.md docs/CODEMAPS/stages.md tests/README.md .claude/settings.json docs/kit-sync.md
git commit -m "Document the scenario pack: runbook section, script and suites, upstream strongSwan pin

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```
