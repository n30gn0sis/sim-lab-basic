# End-to-End Runner and Analyser Scenarios Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the whole lab from nothing: Malcolm working with GNS3, from a freshly cut bundle to scenario traffic judged in Malcolm.
- A fresh bundle is cut on a staging VM that has internet (the offline download).
- The VM is air-gapped and every pipeline is deployed from scratch.
- One command, `r770-e2e.sh`, then validates the lab mirror, Malcolm's capture and GNS3, runs every scenario of the pack, and judges each run in Malcolm.
- Three new scenarios (DNS, TLS, SSH) exercise Malcolm's protocol analysers beyond today's HTTP/IPsec/OSPF/BGP pack.

**Architecture:**
- The new scenarios are ordinary pack entries under `scenarios/`, built from the bundled `netshoot` image only. Their dashboards and views generate automatically from `expect.txt`, and `r770-scenario.sh check` judges them with no change to either.
- `scripts/r770-e2e.sh` is a **test runner, not a deploy orchestrator**. It calls the kit's existing scripts (`r770-validate.sh`, `r770-scenario.sh`) and turns their exits into one report. It installs nothing, and it is not gated, because it changes nothing a scenario would not.

**Tech Stack:** bash, bats, POSIX sh (node scripts), python3 stdlib (the DNS responder, inside the netshoot image).

**Spec:** The Design section below, as agreed with the user on 2026-09-28:
- "One-command E2E runner";
- "Add 2-3 new" scenarios;
- "use one of the VM's to perform the offline download and deployment as well".

It builds on `docs/superpowers/specs/2026-09-24-scenario-pack-design.md` and `docs/superpowers/specs/2026-09-26-scenario-dashboards-and-check-design.md`.

## Design (the spec for this plan)

**New scenarios**, each one link on `br-lab` through two kit TAPs, both nodes `netshoot`:

| Scenario | Range | Nodes | What Malcolm should see |
|---|---|---|---|
| `dns` | 10.206.0.0/16 | `cl` 10.206.0.10, `ns` 10.206.0.53 | DNS queries and answers, NOERROR and NXDOMAIN (Zeek `dns.log`, Arkime DNS) |
| `tls` | 10.207.0.0/16 | `cl` 10.207.0.10, `srv` 10.207.0.20 | A TLS handshake with SNI `tls.scenario.lab` and a self-signed certificate (Zeek `ssl.log` / `x509.log`) |
| `ssh` | 10.208.0.0/16 | `cl` 10.208.0.10, `srv` 10.208.0.20 | SSH handshakes that fail authentication (Zeek `ssh.log`: one row per session with the client banner; `auth_success` stays unset, measured 2026-09-29): a password-guessing shape |

**Servers:**
- **`ns`:** a python3 stdlib DNS responder. `A` records under `scenario.lab` answer `10.206.0.99`; anything else is NXDOMAIN.
- **`srv` (tls):** `openssl s_server -www`, with a certificate generated at `up`.
- **`srv` (ssh):** `sshd`, key-only, with host keys generated at `up`.

**`r770-e2e.sh`**, in four phases:
1. **Validate.** Unless `--skip-validate`, run `r770-validate.sh` areas `network` (with the given `--lab-bridge` and `--capture-ifs`), `capture` and `gns3`.
2. **Run.** For each selected scenario: SKIP it if `r770-scenario.sh list --bundle` says it isn't runnable. Otherwise `up`, then `traffic` (keeping its run record), then `down`.
3. **Judge.** `check <s> --run <record>` for every scenario that produced a record. All traffic runs first, so the first `check` absorbs Malcolm's PCAP-rotation wait and nudge, and the rest pass quickly.
4. **Report.** Write one markdown table (step · verdict · detail) under the evidence dir, beside a directory of every child's output. Exit via `footer` (0/2/1).

**The staging run**, on VM 9770, which is this session's own; 9771 belongs to another session and is never touched:
1. Roll the VM back to `clean-2026-09-24`.
2. With internet: cut a fresh bundle with the kit's `staging/`, pointing `SITE_SRC_ROOT` at a simlab-build clone. The licensed appliances are SYNTHETIC placeholders, so this is a test cut.
3. Block the air gap, and write the bundle to a loop-device "media" image.
4. Deploy from scratch through the kit only: GNS3 `full`, Malcolm `full` with live capture, docs `full`, then the portal. The base-OS packages and Phase 3 volumes are stood in for exactly as the 2026-09-26 rehearsal did.
5. Run `r770-e2e.sh`.

## Global Constraints

- **The gate.** `./tests/run.sh` must be green before every commit:
  - shellcheck with no exclusions over `scripts/*.sh scripts/lib/*.sh`;
  - node and traffic scripts shellcheck-clean as POSIX sh (`shellcheck -s sh`);
  - every `tests/*.bats`.
- **Output and exits.** Every check line is `PASS  `/`WARN  `/`FAIL  `/`SKIP  `, and exits follow `footer`'s 0 / 2 / 1.
- **No version numbers anywhere** (`tests/no-pins.bats`). Scenarios name images only by token (`__IMG_NETSHOOT__`), and `images=netshoot`.
- **Ranges.** Each scenario owns one /16: `dns` 10.206, `tls` 10.207, `ssh` 10.208. Every address a scenario names lies in its own range (`tests/helpers/lint_scenarios.py addresses`).
- **Topology.** Each project has exactly two Cloud nodes, `tap-a` and `tap-b`, with TAP-type ports `__TAP_A__`/`__TAP_B__`, and project `revision` 9. Node and link ids use the prefix `00000006` (dns), `00000007` (tls) or `00000008` (ssh); earlier scenarios own 1–5.
- **Node files.** Only `.sh`, `.frr.conf` and `.swanctl.conf` files go in `nodes/` (the lint rejects anything else).
- **Discover, never guess** (CLAUDE.md rule 1). `r770-e2e.sh` takes `--capture-ifs` and `--lab-bridge` as arguments, and never picks an interface or bridge.
- **The runner calls only the kit's own scripts,** through `E2E_VALIDATE_CMD` / `E2E_SCENARIO_CMD` (defaults: the sibling scripts), and never `staging/` (`tests/no-legacy-manifest.bats`).
- **A new script gets** the `KIT_*` seams via `scripts/lib/common.sh`, a bats suite, a `README.md` row, and an `allow` entry in `.claude/settings.json` beside its siblings (CLAUDE.md).
- **Docs.** Cite repo files as backticked bare paths in `docs/*.md`, `README.md` and `CLAUDE.md` (`tests/references.bats`).

## Review Focus

1. **A scenario whose `up` fails** must still be taken `down`, since `up` leaves failed nodes running for inspection. The remaining scenarios still run, and the runner exits 1 (Task 5, test "a failed up…").
2. **An interrupted run** (Ctrl-C, SIGTERM) must take down the scenario that is up at that moment, not leave a GNS3 project running (Task 5, test "an interrupted run…").
3. **A `check` that exits 0 only because it SKIPped** (Malcolm down, no credential) must be a WARN in the report, never a PASS (Task 5, test "a check that SKIPped…").
4. **An unknown name in `--scenarios`** must be refused before any child script runs (Task 5, test "an unknown --scenarios name…").
5. **A scenario the bundle cannot run** (an image missing from the bundle) is a SKIP with the reason, not a FAIL, and is never `up`ped (Task 5, test "a scenario this bundle cannot run…").

---

### Task 1: A fresh VM, a fresh bundle, and the netshoot facts (controller, on staging)

This task is not bats work: it needs the staging VM, so the controlling session does it. It runs from a simlab-build checkout (for `scripts/r770-staging-vm.sh`) and the kit checkout.

**Destructive step.** Step 1 rolls VM 9770 back to `clean-2026-09-24`. That erases its current deployment, `bundle-20260925` and every earlier evidence file on it. The user approves the rollback when they approve this plan. Do not roll back 9771.

- [ ] **Step 1: Roll back and start.**

```bash
STAGING_VMID=9770 ./scripts/r770-staging-vm.sh rollback clean-2026-09-24
STAGING_VMID=9770 ./scripts/r770-staging-vm.sh start && STAGING_VMID=9770 ./scripts/r770-staging-vm.sh wait-ssh 300
ssh ubuntu@192.168.4.78 'free -g | sed -n 2p; nproc; df -h / | tail -1'
```

- [ ] **Step 2: Memory.**
  - **The problem.** The snapshot's config is 8 GiB, and Malcolm needs 12, so the rollback leaves the VM too small. The session's token has no `VM.Config.Memory`.
  - **Ask the user** to set 12 GiB (12288 MiB, balloon 0) in the Proxmox UI and restart the VM. Then re-run `free -g` and confirm about 11 GiB is usable before going on.

- [ ] **Step 3: Put both repos on the VM.**
  - **simlab-build:** clone the public repo at `main`, recording its commit.
  - **The kit:** carry it from this checkout, since it is private.

```bash
ssh ubuntu@192.168.4.78 'git clone -q https://github.com/n30gn0sis/simlab-build ~/simlab-build && git -C ~/simlab-build rev-parse HEAD'
tar -c staging scripts scenarios config | ssh ubuntu@192.168.4.78 'mkdir -p ~/sim-lab-basic && tar -x -C ~/sim-lab-basic'
```

- [ ] **Step 4: The staging preflight.**

```bash
ssh ubuntu@192.168.4.78 'cd ~/sim-lab-basic && ./staging/r770-staging-preflight.sh'
```

Expected: `READY`, with egress verified. If Docker is missing on the rolled-back image, the preflight names what to install. Follow `simlab-build`'s `state/inventory/staging-vm-9770.md` for its Docker CE install; that is staging-host setup, not the R770.

- [ ] **Step 5: Cut the bundle,** in `tmux` so the SSH session can drop without killing it. It takes hours.

```bash
ssh ubuntu@192.168.4.78 'tmux new -d -s cut "cd ~/sim-lab-basic && SITE_SRC_ROOT=~/simlab-build SEED_FROM=none ./staging/r770-build-bundle.sh --yes --bundle-dir ~/bundles/bundle-$(date +%Y%m%d) 2>&1 | tee ~/cut.log"'
```

At the manual-items pause, stage SYNTHETIC placeholders for the licensed GNS3 appliances with `sudo`, the way `simlab-build`'s `state/inventory/staging-rehearsal-2026-09-25.md` did. The bundle is root-owned, so writing without `sudo` fails. This cut is **not for transfer**.

- [ ] **Step 6: Gate the cut.**
  - **The expected result.** The builder's own `verify --strict` gate FAILs only on the SYNTHETIC placeholders' WARNs. Disposition them as a test cut.
  - **Check it.** Run the bundle's verifier non-strict, the way the R770 does. It must exit 0 or 2. Record every WARN line, and confirm `site/` is present.

```bash
ssh ubuntu@192.168.4.78 'b=$(ls -d ~/bundles/bundle-*/ | tail -1); "$b"r770-bundle.sh verify "$b"; echo "verify exit=$?"; grep -c "" "$b"MANIFEST.sha256; du -sh "$b"; ls "$b"site/scripts | head'
```

- [ ] **Step 7: Check the netshoot image.** The staging Docker still holds the image the cut pulled, so check it offline:

```bash
ssh ubuntu@192.168.4.78 'img=$(docker image ls --format "{{.Repository}}:{{.Tag}}" | grep -m1 netshoot); echo "$img"; docker run --rm --network none --entrypoint sh "$img" -c "for t in python3 sshd ssh ssh-keygen openssl dig curl nc; do printf \"%-10s %s\n\" \$t \"\$(command -v \$t || echo MISSING)\"; done; nc -h 2>&1 | grep -c -- \" -z\""'
```

Expected: a path for every tool, and a non-zero `-z` count.

- [ ] **Step 8: Record in the ledger.**
  - **What to record:** the simlab-build commit, the bundle name and size, the verify exit and its WARN lines, and the netshoot facts.
  - **If any netshoot tool is MISSING:** stop, and bring it to the user before Tasks 2–4. Say which scenario it breaks and an alternative, e.g. busybox-extras `nc -l` for a server.

### Task 2: The `dns` scenario

**Files:**
- Create: `scenarios/dns/scenario.conf`, `scenarios/dns/traffic.sh`, `scenarios/dns/expect.txt`, `scenarios/dns/nodes/cl.sh`, `scenarios/dns/nodes/ns.sh`, `scenarios/dns/project/dns.gns3`
- Modify: `tests/scenarios.bats` (the pack test, and a responder test), `README.md` (the `scenarios/` row), `docs/deployment-runbook.md` (the ranges sentence)

**Interfaces:**
- Consumes: the scenario-pack format (read `scenarios/client-server/` for a working example), `tests/helpers/lint_scenarios.py`, and `r770-scenario.sh`, which runs each `nodes/*.sh` inside its node with `docker exec -i <cid> sh -s`.
- Produces: scenario `dns`; later tasks only count it.

- [ ] **Step 1: Write the failing tests.** In `tests/scenarios.bats`, change the pack test to:

```bash
@test "the pack holds the scenarios the kit documents" {
    for s in client-server ipsec-esp ipsec-ike ospf bgp dns; do [ -f "scenarios/$s/scenario.conf" ] || { echo "missing $s"; false; }; done
    [ "$(find scenarios -mindepth 2 -maxdepth 2 -name scenario.conf | wc -l)" -eq 6 ]
}
```

Add, after it:

```bash
@test "the dns scenario's responder answers A under scenario.lab and NXDOMAIN otherwise" {
    prog="$BATS_TEST_TMPDIR/lab-dns.py"
    sed -n "/^cat > \/tmp\/lab-dns.py <<'PY'$/,/^PY$/p" scenarios/dns/nodes/ns.sh | sed '1d;$d' > "$prog"
    [ -s "$prog" ]
    DNS_BIND=127.0.0.1 DNS_PORT=53053 python3 "$prog" & pid=$!
    sleep 1
    run python3 - <<'PY'
import socket, struct
def ask(name, qtype=1):
    q = b"\x12\x34\x01\x00" + struct.pack(">HHHH", 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00" + struct.pack(">HH", qtype, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
    s.sendto(q, ("127.0.0.1", 53053)); r, _ = s.recvfrom(512)
    return r
r = ask("www.scenario.lab")
print("id", r[:2].hex(), "rcode", r[3] & 0x0f, "an", struct.unpack(">H", r[6:8])[0], "ip", socket.inet_ntoa(r[-4:]))
r = ask("nothere.example")
print("id", r[:2].hex(), "rcode", r[3] & 0x0f, "an", struct.unpack(">H", r[6:8])[0])
PY
    kill "$pid"
    echo "$output"
    [ "${lines[0]}" = "id 1234 rcode 0 an 1 ip 10.206.0.99" ]
    [ "${lines[1]}" = "id 1234 rcode 3 an 0" ]
}
```

- [ ] **Step 2: Run the tests; they should fail**

Run: `bats tests/scenarios.bats --filter 'pack holds|responder'`
Expected: both FAIL. There's no `scenarios/dns/`, so "missing dns", and the extracted program is empty.

- [ ] **Step 3: Create the scenario files**

`scenarios/dns/scenario.conf`:

```
name=dns
description=netshoot client resolving names against a netshoot DNS responder across br-lab
range=10.206.0.0/16
images=netshoot
traffic_secs=60
ready=cl|dig +short +time=1 +tries=1 @10.206.0.53 www.scenario.lab | grep -qx 10.206.0.99
traffic_nodes=cl
```

`scenarios/dns/expect.txt`:

```
udp|53|10.206.0.10/32|10.206.0.53/32
```

`scenarios/dns/nodes/cl.sh`:

```sh
# cl: the resolver's client, on br-lab through tap-a
set -e
ip addr replace 10.206.0.10/24 dev eth0
ip link set dev eth0 up
```

`scenarios/dns/nodes/ns.sh`:

```sh
# ns: a small authoritative responder on br-lab through tap-b. The bundle has
# no DNS server image, so a python3 stdlib program answers A records under
# scenario.lab with 10.206.0.99 and everything else with NXDOMAIN: enough for
# Zeek's dns.log and Arkime's DNS parser to see both outcomes. Fully
# detached, so docker exec returns.
set -e
ip addr replace 10.206.0.53/24 dev eth0
ip link set dev eth0 up
cat > /tmp/lab-dns.py <<'PY'
import os, socket, struct
bind = os.environ.get("DNS_BIND", "10.206.0.53")
port = int(os.environ.get("DNS_PORT", "53"))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((bind, port))
while True:
    q, peer = s.recvfrom(512)
    if len(q) < 17:
        continue
    i, labels = 12, []
    while i < len(q) and q[i]:
        n = q[i]
        labels.append(q[i + 1:i + 1 + n].decode("ascii", "replace").lower())
        i += 1 + n
    if i + 5 > len(q):
        continue
    qtype = struct.unpack(">H", q[i + 1:i + 3])[0]
    question = q[12:i + 5]
    name = ".".join(labels)
    if (name == "scenario.lab" or name.endswith(".scenario.lab")) and qtype == 1:
        head = q[:2] + b"\x81\x80" + struct.pack(">HHHH", 1, 1, 0, 0)
        answer = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton("10.206.0.99")
    else:
        head = q[:2] + b"\x81\x83" + struct.pack(">HHHH", 1, 0, 0, 0)
        answer = b""
    s.sendto(head + question + answer, peer)
PY
(python3 /tmp/lab-dns.py) </dev/null >/dev/null 2>&1 &
```

`scenarios/dns/traffic.sh`:

```sh
#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl resolves a rotating set of names for the window: names under
# scenario.lab (answered) and names outside it (NXDOMAIN).
node=$1 secs=$2
case "$node" in
    cl)
        dig +short +time=1 +tries=1 @10.206.0.53 www.scenario.lab | grep -qx 10.206.0.99 || exit 1
        end=$(( $(date +%s) + secs ))
        while [ "$(date +%s)" -lt "$end" ]; do
            for n in www.scenario.lab mail.scenario.lab files.scenario.lab nothere.example; do
                dig +time=1 +tries=1 @10.206.0.53 "$n" >/dev/null 2>&1 || true
            done
            sleep 1
        done ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

`scenarios/dns/project/dns.gns3`:

```json
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [], "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000006-0000-4000-8000-000000000001", "name": "cl", "node_type": "docker", "x": -200, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000006-0000-4000-8000-000000000002", "name": "ns", "node_type": "docker", "x": 200, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000006-0000-4000-8000-000000000003", "name": "tap-a", "node_type": "cloud", "x": -60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000006-0000-4000-8000-000000000004", "name": "tap-b", "node_type": "cloud", "x": 60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000006-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000006-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000006-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000006-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000006-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000006-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
```

Run `chmod +x scenarios/dns/traffic.sh` (match the existing `traffic.sh` modes: `ls -l scenarios/*/traffic.sh`).

- [ ] **Step 4: Update the docs.**
  - **`docs/deployment-runbook.md`:** change the sentence starting `Each scenario owns one /16` to:

    ```markdown
    Each scenario owns one /16 (`client-server` 10.205, `ipsec-esp` 10.201,
    `ipsec-ike` 10.202, `ospf` 10.203, `bgp` 10.204, `dns` 10.206), so two can share the hub.
    ```
  - **`README.md`:** in the `scenarios/` row, change `Five repeatable GNS3 scenarios` to `Six repeatable GNS3 scenarios`, and add `` `dns` `` after `` `bgp`, ``.

- [ ] **Step 5: Run the tests; they should pass**

Run: `bats tests/scenarios.bats && ./tests/run.sh`
Expected: every test `ok`, including the lint checks (layout, json, topology, images, addresses, expect) and POSIX shellcheck of the new scripts. The gate exits 0.

- [ ] **Step 6: Commit**

```bash
git add scenarios/dns tests/scenarios.bats README.md docs/deployment-runbook.md
git commit -m "Scenario dns: a python3 stdlib responder for Malcolm's DNS analysers (NOERROR and NXDOMAIN)"
```

---

### Task 3: The `tls` scenario

**Files:**
- Create: `scenarios/tls/scenario.conf`, `scenarios/tls/traffic.sh`, `scenarios/tls/expect.txt`, `scenarios/tls/nodes/cl.sh`, `scenarios/tls/nodes/srv.sh`, `scenarios/tls/project/tls.gns3`
- Modify: `tests/scenarios.bats` (the pack test), `README.md`, `docs/deployment-runbook.md`

**Interfaces:** as in Task 2. This task produces scenario `tls`.

- [ ] **Step 1: Write the failing test.** Change the pack test's list to `client-server ipsec-esp ipsec-ike ospf bgp dns tls`, and its count to `-eq 7`.

- [ ] **Step 2: Run the test; it should fail**

Run: `bats tests/scenarios.bats --filter 'pack holds'`
Expected: FAIL, "missing tls".

- [ ] **Step 3: Create the scenario files**

`scenarios/tls/scenario.conf`:

```
name=tls
description=netshoot client fetching over TLS (SNI tls.scenario.lab, self-signed) from a netshoot openssl server across br-lab
range=10.207.0.0/16
images=netshoot
traffic_secs=60
ready=cl|curl -skf -m 2 -o /dev/null --resolve tls.scenario.lab:443:10.207.0.20 https://tls.scenario.lab/
traffic_nodes=cl
```

`scenarios/tls/expect.txt`:

```
tcp|443|10.207.0.10/32|10.207.0.20/32
```

`scenarios/tls/nodes/cl.sh`:

```sh
# cl: the TLS client, on br-lab through tap-a
set -e
ip addr replace 10.207.0.10/24 dev eth0
ip link set dev eth0 up
```

`scenarios/tls/nodes/srv.sh`:

```sh
# srv: a TLS server on br-lab through tap-b. A self-signed certificate for
# tls.scenario.lab is generated here at up (lab traffic only, not a secret),
# so Zeek's ssl.log/x509.log and Arkime see a real handshake with SNI and a
# certificate subject. openssl s_server -www answers every request; fully
# detached, so docker exec returns.
set -e
ip addr replace 10.207.0.20/24 dev eth0
ip link set dev eth0 up
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=tls.scenario.lab" \
    -keyout /tmp/lab-tls.key -out /tmp/lab-tls.crt >/dev/null 2>&1
(openssl s_server -accept 443 -cert /tmp/lab-tls.crt -key /tmp/lab-tls.key -www -quiet) </dev/null >/dev/null 2>&1 &
```

`scenarios/tls/traffic.sh`:

```sh
#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl fetches the server's status page over TLS, by name (SNI), every half second.
node=$1 secs=$2
case "$node" in
    cl)
        end=$(( $(date +%s) + secs ))
        while [ "$(date +%s)" -lt "$end" ]; do
            curl -skf -m 2 -o /dev/null --resolve tls.scenario.lab:443:10.207.0.20 https://tls.scenario.lab/ || exit 1
            sleep 0.5
        done ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

`scenarios/tls/project/tls.gns3`:

```json
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [], "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000007-0000-4000-8000-000000000001", "name": "cl", "node_type": "docker", "x": -200, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000007-0000-4000-8000-000000000002", "name": "srv", "node_type": "docker", "x": 200, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000007-0000-4000-8000-000000000003", "name": "tap-a", "node_type": "cloud", "x": -60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000007-0000-4000-8000-000000000004", "name": "tap-b", "node_type": "cloud", "x": 60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000007-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000007-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000007-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000007-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000007-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000007-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
```

Run `chmod +x scenarios/tls/traffic.sh`.

- [ ] **Step 4: Update the docs.**
  - **Runbook:** the ranges sentence gains `` `tls` 10.207 `` after `` `dns` 10.206 ``.
  - **README:** the `scenarios/` row says `Seven repeatable GNS3 scenarios` and lists `` `tls` `` after `` `dns` ``.

- [ ] **Step 5: Run the tests; they should pass**

Run: `bats tests/scenarios.bats && ./tests/run.sh`
Expected: all `ok`, and the gate exits 0.

- [ ] **Step 6: Commit**

```bash
git add scenarios/tls tests/scenarios.bats README.md docs/deployment-runbook.md
git commit -m "Scenario tls: an openssl s_server handshake with SNI and a certificate for Malcolm's TLS analysers"
```

---

### Task 4: The `ssh` scenario

**Files:**
- Create: `scenarios/ssh/scenario.conf`, `scenarios/ssh/traffic.sh`, `scenarios/ssh/expect.txt`, `scenarios/ssh/nodes/cl.sh`, `scenarios/ssh/nodes/srv.sh`, `scenarios/ssh/project/ssh.gns3`
- Modify: `tests/scenarios.bats` (the pack test), `README.md`, `docs/deployment-runbook.md`

**Interfaces:** as in Task 2. This task produces scenario `ssh`.

- [ ] **Step 1: Write the failing test.** Change the pack test's list to `client-server ipsec-esp ipsec-ike ospf bgp dns tls ssh`, and its count to `-eq 8`.

- [ ] **Step 2: Run the test; it should fail**

Run: `bats tests/scenarios.bats --filter 'pack holds'`
Expected: FAIL, "missing ssh".

- [ ] **Step 3: Create the scenario files**

`scenarios/ssh/scenario.conf`:

```
name=ssh
description=netshoot client failing key-only SSH logins against a netshoot sshd across br-lab (a password-guessing shape)
range=10.208.0.0/16
images=netshoot
traffic_secs=60
ready=cl|nc -z -w 2 10.208.0.20 22
traffic_nodes=cl
```

`scenarios/ssh/expect.txt`:

```
tcp|22|10.208.0.10/32|10.208.0.20/32
```

`scenarios/ssh/nodes/cl.sh`:

```sh
# cl: the SSH client, on br-lab through tap-a
set -e
ip addr replace 10.208.0.10/24 dev eth0
ip link set dev eth0 up
```

`scenarios/ssh/nodes/srv.sh`:

```sh
# srv: sshd on br-lab through tap-b, key-only with no authorized keys, so
# every login fails authentication after a full handshake: repeated SSH
# sessions from one client, the shape of password guessing. Zeek's ssh.log
# records each with the client banner; it leaves auth_success unset (-),
# since a fast public-key refusal gives it nothing to infer from (measured
# on staging VM 9770, 2026-09-29). Host keys are
# generated here at up; sshd daemonizes itself, so docker exec returns.
set -e
ip addr replace 10.208.0.20/24 dev eth0
ip link set dev eth0 up
ssh-keygen -A >/dev/null
mkdir -p /run/sshd /var/empty
/usr/sbin/sshd -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PermitRootLogin=prohibit-password
```

`scenarios/ssh/traffic.sh`:

```sh
#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl opens an SSH session every second and fails authentication each time
# (no key the server accepts). A failed login is the point, so its exit is
# ignored; the server must still answer, or the window is not traffic.
node=$1 secs=$2
case "$node" in
    cl)
        nc -z -w 2 10.208.0.20 22 || exit 1
        end=$(( $(date +%s) + secs ))
        while [ "$(date +%s)" -lt "$end" ]; do
            ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=3 labuser@10.208.0.20 true >/dev/null 2>&1 || true
            sleep 1
        done ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

`scenarios/ssh/project/ssh.gns3`:

```json
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [], "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000008-0000-4000-8000-000000000001", "name": "cl", "node_type": "docker", "x": -200, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000008-0000-4000-8000-000000000002", "name": "srv", "node_type": "docker", "x": 200, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000008-0000-4000-8000-000000000003", "name": "tap-a", "node_type": "cloud", "x": -60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000008-0000-4000-8000-000000000004", "name": "tap-b", "node_type": "cloud", "x": 60, "y": 0,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000008-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000008-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000008-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000008-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000008-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000008-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
```

Run `chmod +x scenarios/ssh/traffic.sh`.

- [ ] **Step 4: Update the docs.**
  - **Runbook:** the ranges sentence gains `` `ssh` 10.208 `` after `` `tls` 10.207 ``.
  - **README:** the `scenarios/` row says `Eight repeatable GNS3 scenarios` and lists `` `ssh` `` after `` `tls` ``.

- [ ] **Step 5: Run the tests; they should pass**

Run: `bats tests/scenarios.bats && ./tests/run.sh`
Expected: all `ok`, and the gate exits 0.

- [ ] **Step 6: Commit**

```bash
git add scenarios/ssh tests/scenarios.bats README.md docs/deployment-runbook.md
git commit -m "Scenario ssh: failed key-only logins against sshd for Malcolm's SSH analysers"
```

---

### Task 5: `scripts/r770-e2e.sh`, the end-to-end runner

**Files:**
- Create: `scripts/r770-e2e.sh`, `tests/e2e.bats`
- Modify: `README.md` (a row after the `scripts/r770-scenario.sh` row), `.claude/settings.json` (an allow entry), `docs/deployment-runbook.md` (a new section before `## Docs procedure`)

**Interfaces:**
- Consumes, from `scripts/lib/common.sh`: `kit_init`, `need_root`, `pass`/`warn`/`fail`/`skip`/`note`/`banner`/`footer`, `die`, `common_flag`, `usage_from_header`, `KIT_DIR`, and `KIT_EVIDENCE_DIR` (default `$PWD/r770-evidence`).
- Consumes, from the child scripts:
  - `r770-validate.sh --area A [--lab-bridge BR] [--capture-ifs "…"] --out DIR`, exit 0/2/1;
  - `r770-scenario.sh list --bundle B`: a scenario line starts with its name, and a following indented note contains `NOT runnable` when it isn't runnable;
  - `r770-scenario.sh up <s> --bundle B`, `traffic <s>` (prints `      run record: <path>`), `down <s>`, and `check <s> --run <path>`, each exiting 0/2/1. `check` prints a `SKIP  ` line when it could not judge.
- Produces: `r770-e2e.sh --bundle <dir> --capture-ifs "<if …>" --lab-bridge <br> [--scenarios a,b] [--skip-validate] [--out DIR]`. Its report is `<out>/e2e-<host>-<ts>.md`, and each child's output is under `<out>/e2e-<host>-<ts>/`.

- [ ] **Step 1: Write the failing tests.** Create `tests/e2e.bats`:

```bash
#!/usr/bin/env bats
#
# r770-e2e.sh against stubbed children: the runner's own contract. Which
# child runs in which order with which arguments, how each exit becomes a
# report row, and that nothing is left up.

load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-e2e.sh"
    export T="$BATS_TEST_TMPDIR"
    export SCENARIO_DIR="$T/scenarios"
    for s in demo-a demo-b; do mkdir -p "$SCENARIO_DIR/$s"; printf 'name=%s\n' "$s" > "$SCENARIO_DIR/$s/scenario.conf"; done
    printf 'demo-a  10.250.0.0/16  a\n      runnable with this bundle\ndemo-b  10.251.0.0/16  b\n      runnable with this bundle\n' > "$T/list.out"
    mkdir -p "$T/bundle"
    stub validate-stub 'echo "validate $*" >> "$STUB_LOG"; f="$T/rc-validate-$2"; [ -f "$f" ] && exit "$(cat "$f")"; exit 0'
    stub scenario-stub '
echo "scenario $*" >> "$STUB_LOG"
sub=$1; s=${2:-}
case "$sub" in
  list)    cat "$T/list.out" ;;
  traffic) echo "      run record: $T/rec-$s.run"; [ -f "$T/term-traffic-$s" ] && kill -TERM "$PPID" && sleep 5 ;;
  check)   cat "$T/check-$s.out" 2>/dev/null ;;
esac
f="$T/rc-$sub-$s"; [ -f "$f" ] && exit "$(cat "$f")"; exit 0'
    export E2E_VALIDATE_CMD="$BIN/validate-stub" E2E_SCENARIO_CMD="$BIN/scenario-stub"
}

e2e() { kit_run "$SCRIPT" "$@"; }
full() { e2e --bundle "$T/bundle" --capture-ifs lab_mirror0 --lab-bridge br-lab "$@"; }
calls() { sed -n 's/^\(validate\|scenario\) //p' "$STUB_LOG"; }

@test "the whole run: validate areas, then up/traffic/down per scenario, then check each against its own run record" {
    run full
    echo "$output"
    [ "$status" -eq 0 ]
    logdir=$(ls -d "$KIT_EVIDENCE_DIR"/e2e-*/ | head -1); logdir=${logdir%/}
    run calls
    [ "${lines[0]}" = "--area network --lab-bridge br-lab --capture-ifs lab_mirror0 --out $logdir" ]
    [ "${lines[1]}" = "--area capture --out $logdir" ]
    [ "${lines[2]}" = "--area gns3 --out $logdir" ]
    [ "${lines[3]}" = "list --bundle $T/bundle" ]
    [ "${lines[4]}" = "up demo-a --bundle $T/bundle" ]
    [ "${lines[5]}" = "traffic demo-a" ]
    [ "${lines[6]}" = "down demo-a" ]
    [ "${lines[7]}" = "up demo-b --bundle $T/bundle" ]
    [ "${lines[8]}" = "traffic demo-b" ]
    [ "${lines[9]}" = "down demo-b" ]
    [ "${lines[10]}" = "check demo-a --run $T/rec-demo-a.run" ]
    [ "${lines[11]}" = "check demo-b --run $T/rec-demo-b.run" ]
    report="$logdir.md"
    grep -q '^| check demo-b | PASS |' "$report"
    grep -q '^| validate network | PASS |' "$report"
}

@test "--capture-ifs, --lab-bridge and --bundle are required; nothing is guessed and no child runs" {
    run e2e --bundle "$T/bundle" --lab-bridge br-lab
    [ "$status" -eq 1 ]; [[ "$output" == *"--capture-ifs"* ]]
    run e2e --bundle "$T/bundle" --capture-ifs lab_mirror0
    [ "$status" -eq 1 ]; [[ "$output" == *"--lab-bridge"* ]]
    run e2e --capture-ifs lab_mirror0 --lab-bridge br-lab
    [ "$status" -eq 1 ]; [[ "$output" == *"--bundle"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "--skip-validate runs no validation, and needs no interface or bridge" {
    run e2e --bundle "$T/bundle" --skip-validate
    echo "$output"
    [ "$status" -eq 0 ]
    run grep -c '^validate ' "$STUB_LOG"
    [ "$output" = 0 ]
}

@test "an unknown --scenarios name is refused before any child runs" {
    run full --scenarios demo-a,nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"no scenario 'nope'"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "--scenarios runs only the named ones, in the order given" {
    run full --scenarios demo-b
    [ "$status" -eq 0 ]
    run grep -c 'demo-a' "$STUB_LOG"
    [ "$output" = 0 ]
    grep -q '^scenario check demo-b --run ' "$STUB_LOG"
}

@test "a failed up is a FAIL, the scenario is still taken down, and the others still run" {
    echo 1 > "$T/rc-up-demo-a"
    run full
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  up demo-a"* ]]
    grep -q '^scenario down demo-a' "$STUB_LOG"
    ! grep -q '^scenario traffic demo-a' "$STUB_LOG"
    ! grep -q '^scenario check demo-a' "$STUB_LOG"
    grep -q '^scenario check demo-b --run ' "$STUB_LOG"
}

@test "a scenario this bundle cannot run is a SKIP with the reason, and is never up" {
    printf 'demo-a  10.250.0.0/16  a\n      runnable with this bundle\ndemo-b  10.251.0.0/16  b\n      NOT runnable: missing strongswan\n' > "$T/list.out"
    run full
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  up demo-b: not runnable with this bundle"* ]]
    ! grep -q '^scenario up demo-b' "$STUB_LOG"
}

@test "a check that SKIPped (Malcolm not answering) is a WARN in the report, never a PASS" {
    printf 'SKIP  Arkime did not answer on 127.0.0.1:8443 — start Malcolm\n\nREADY — check: 0 check(s) passed, 1 skipped\n' > "$T/check-demo-a.out"
    run full
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  check demo-a: skipped: Arkime did not answer"* ]]
}

@test "a failing check makes the run exit 1, and the report says which" {
    echo 1 > "$T/rc-check-demo-b"
    run full
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  check demo-b"* ]]
}

@test "an interrupted run takes down the scenario that is up at that moment" {
    touch "$T/term-traffic-demo-a"
    run full
    echo "$output"
    [ "$status" -ne 0 ]
    grep -q '^scenario down demo-a' "$STUB_LOG"
    ! grep -q '^scenario up demo-b' "$STUB_LOG"
}
```

- [ ] **Step 2: Run the tests; they should fail**

Run: `bats tests/e2e.bats`
Expected: every test FAILs, because `scripts/r770-e2e.sh` does not exist.

- [ ] **Step 3: Write `scripts/r770-e2e.sh`** and make it executable (`chmod +x`):

```bash
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
```

A note for the implementer: `kit_test_env` exports `KIT_EVIDENCE_DIR` (`$BATS_TEST_TMPDIR/evidence`), `KIT_ROOT` (so `need_root` passes) and `KIT_NO_TEE=1`. The first test finds the run by its `e2e-*/` directory under `KIT_EVIDENCE_DIR`.

- [ ] **Step 4: Run the tests; they should pass**

Run: `bats tests/e2e.bats && shellcheck -x scripts/r770-e2e.sh`
Expected: every test `ok`, and shellcheck silent.

- [ ] **Step 5: Register and document the script.**
  - **`.claude/settings.json`:** add `"Bash(./scripts/r770-e2e.sh:*)",` directly after the `"Bash(./scripts/r770-scenario.sh:*)",` line.
  - **`README.md`:** directly after the `scripts/r770-scenario.sh` row, add:

    ```markdown
    | `scripts/r770-e2e.sh` | The whole lab end to end in one command: validates the mirror, Malcolm's capture and GNS3, runs every scenario (up → traffic → down), then judges every run in Malcolm with `check`; one report under `r770-evidence/`. A test runner, not a deploy step — not gated |
    ```
  - **`docs/deployment-runbook.md`:** directly before `## Docs procedure`, add:

    ````markdown
    ## End to end (after Malcolm and GNS3 are up)

    ```bash
    sudo ./scripts/r770-e2e.sh --bundle /srv/bundles/bundle-YYYYMMDD \
        --capture-ifs lab_mirror0 --lab-bridge br-lab     # both from discovery, never guessed
    ```

    One command proves Malcolm working with GNS3. It validates the lab mirror,
    Malcolm's capture and GNS3 (`r770-validate.sh` areas `network`, `capture`,
    `gns3`), runs every scenario the bundle can run (`up`, `traffic`, `down`),
    then judges every run in Malcolm with `r770-scenario.sh check`. All
    traffic runs first, so only the first check waits for Malcolm's PCAP
    rotation. The report is `r770-evidence/e2e-<host>-<ts>.md`, with every
    child's output in the directory beside it; `--scenarios a,b` narrows the
    run, `--skip-validate` skips the first phase. A scenario that fails `up`
    is still taken down, an interrupted run takes down the one that is up,
    and a check that could not judge (Malcolm not answering) is a WARN, not
    a PASS.
    ````

- [ ] **Step 6: Run the gate and commit**

Run: `./tests/run.sh`
Expected: exit 0 (references, lint and no-legacy-manifest included).

```bash
git add scripts/r770-e2e.sh tests/e2e.bats README.md .claude/settings.json docs/deployment-runbook.md
git commit -m "r770-e2e.sh: validate, run every scenario, judge every run in Malcolm — one command, one report"
```

---

### Task 6: Air-gapped deployment from scratch (controller, on staging)

This task needs the VM, so the controlling session does it. It runs on VM 9770 after Tasks 1–5, and uses only the kit's scripts: CLAUDE.md, "Run the kit's scripts, not hand-typed commands". The two stand-ins are for build-repo phases the kit doesn't own; each is named where it happens.

- [ ] **Step 1: Sync the finished kit and block the air gap.** Give the gap enough time for the whole deploy and the e2e run (360 minutes). It reverts by itself.

```bash
tar -c scripts scenarios config staging | ssh ubuntu@192.168.4.78 'tar -x -C ~/sim-lab-basic'
ssh ubuntu@192.168.4.78 'sudo ~/simlab-build/scripts/r770-airgap-sim.sh block --minutes 360 && sudo ~/simlab-build/scripts/r770-airgap-sim.sh status'
```

- [ ] **Step 2: Phase 3 volumes (stand-in).** The kit's `preflight` refuses Phase 3 directories that aren't their own mount points. Give each one a loop-mounted ext4 file in `/etc/fstab`, as the 2026-09-26 rehearsal did:
  - directories: `/var/lib/docker`, `/data/pcap`, `/data/index`, `/data/staging`, `/srv/vms`, `/srv/gns3`, `/srv/work`, `/srv/backup`;
  - backing files: `/var/lib/lab-volumes/<name>.img`, sized to fit the VM's disk. Record the sizes.

  Afterwards `findmnt` shows each one mounted.

- [ ] **Step 3: The media.** A loop-device image carries the bundle, so the kit's `gate` mounts it read-only like real transfer media. Discover the device; never guess it.

```bash
ssh ubuntu@192.168.4.78 'b=$(ls -d ~/bundles/bundle-*/ | tail -1); sz=$(( $(du -sm "$b" | cut -f1) * 11 / 10 + 1024 )); sudo truncate -s ${sz}M /data/staging/media.img && sudo mkfs.ext4 -q /data/staging/media.img && sudo mkdir -p /mnt/media && sudo mount -o loop /data/staging/media.img /mnt/media && sudo cp -a "$b" /mnt/media/ && sudo umount /mnt/media && sudo losetup -f --show /data/staging/media.img'
```

Record the `/dev/loopN` it prints as `<dev>`, and the bundle's directory name as `bundle-<date>`.

- [ ] **Step 4: Shared prep.** The first pipeline brings the bundle in, stopping after `files`:

```bash
ssh ubuntu@192.168.4.78 'cd ~/sim-lab-basic && sudo ./scripts/r770-gns3-deploy.sh full --bundle /mnt/media/bundle-<date> --media /mnt/media --device <dev> --yes --to files'
```

Expected: `preflight`, `gate`, `copy`, `apt`, `phone-home`, `docker` and `files` all PASS. APT now points only at `file:/srv/repo/apt`.

- [ ] **Step 5: Base-OS packages (stand-in).** The build repo's base-OS phase installs these, and the kit's steps refuse by name without them. Install from the bundle's local repo only:

```bash
ssh ubuntu@192.168.4.78 'sudo apt-get install -y python3-venv python3-pip-whl python3-ruamel.yaml python3-dotenv easy-rsa nginx ubridge'
```

- [ ] **Step 6: GNS3, then Malcolm with live capture, then docs.**

```bash
ssh ubuntu@192.168.4.78 'cd ~/sim-lab-basic && B=/srv/bundles/bundle-<date>; sudo ./scripts/r770-gns3-deploy.sh full --bundle $B --media /mnt/media --device <dev> --yes --from load'
ssh ubuntu@192.168.4.78 'cd ~/sim-lab-basic && B=/srv/bundles/bundle-<date>; sudo ./scripts/r770-malcolm-deploy.sh full --bundle $B --media /mnt/media --device <dev> --capture-ifs lab_mirror0 --yes --from load'
ssh ubuntu@192.168.4.78 'cd ~/sim-lab-basic && B=/srv/bundles/bundle-<date>; sudo ./scripts/r770-docs-deploy.sh full --bundle $B --media /mnt/media --device <dev> --yes --from load'
```

Expected:
- **GNS3:** DEPLOYED, `labnet` all PASS.
- **Malcolm:** DEPLOYED, every service healthy, live capture on `lab_mirror0`, and `trackESP turned on`.
- **Docs:** DEPLOYED.

If `full` doesn't accept `--capture-ifs`, run Malcolm's `configure --capture-ifs lab_mirror0` step on its own, then `full --from secrets`.

Each FAIL is a finding. Handle it one change at a time (CLAUDE.md rule 7): read the transcript under `r770-evidence/`, fix the kit test-first on this branch, re-sync, then rerun `--from <step>`.

- [ ] **Step 7: The front door and the generated objects.**

```bash
ssh ubuntu@192.168.4.78 'cd ~/sim-lab-basic && for s in ca cert htpasswd nginx; do sudo ./scripts/r770-portal-deploy.sh $s --yes || break; done'
ssh ubuntu@192.168.4.78 'cd ~/sim-lab-basic && sudo ./scripts/r770-malcolm-deploy.sh inventory && sudo ./scripts/r770-malcolm-deploy.sh dashboards --index-pattern "arkime_sessions3-*" && sudo ./scripts/r770-malcolm-deploy.sh arkime-views'
```

Expected: every portal step PASSes. `dashboards` and `arkime-views` are READY, with every scenario's objects read back, the new `dns`, `tls` and `ssh` included. If the stack holds a different sessions pattern, use the one `inventory` lists.

---

### Task 7: The end-to-end run and the record (controller, on staging)

This task needs the VM, so the controlling session does it.

- [ ] **Step 1: The full run.** In `tmux`, since it takes over half an hour:

```bash
ssh ubuntu@192.168.4.78 'tmux new -d -s e2e "cd ~/sim-lab-basic && sudo ./scripts/r770-e2e.sh --bundle /srv/bundles/bundle-<date> --capture-ifs lab_mirror0 --lab-bridge br-lab 2>&1 | tee ~/e2e.out"'
```

Expected:
- READY (exit 0), or READY WITH WARNINGS with each warning explained;
- every scenario's `up`, `traffic`, `down` and `check` rows PASS: all eight, `dns`, `tls` and `ssh` included, with ESP both ways.

Any FAIL is a finding. Handle it one change at a time (CLAUDE.md rule 7): read that child's log under the report's directory, and for a `check` FAIL, start with the tcpdump filter it prints.

- [ ] **Step 2: Confirm the analysers fired,** beyond session counts. In Zeek's live logs, the new scenarios must appear in `dns.log` (both NOERROR and NXDOMAIN), `ssl.log` (`server_name` `tls.scenario.lab`) and `ssh.log` (one row per session with the client banner; `auth_success` stays unset):

```bash
ssh ubuntu@192.168.4.78 'cd /opt/malcolm/malcolm/zeek-logs/live/spool/logger-1 && for f in dns ssl ssh; do echo "== $f.log"; sudo grep -h -E "10\.20(6|7|8)\." $f.log | tail -2; done'
```

- [ ] **Step 3: Take the air gap down,** and confirm it:

```bash
ssh ubuntu@192.168.4.78 'sudo ~/simlab-build/scripts/r770-airgap-sim.sh unblock; sudo ~/simlab-build/scripts/r770-airgap-sim.sh status'
```

- [ ] **Step 4: Carry the record back.**
  - **Build repo:** add `state/inventory/staging-e2e-<date>.md` to simlab-build, on a branch, holding:
    - the cut (commit, size, verify result);
    - the stand-ins;
    - each pipeline's result;
    - the e2e report's table;
    - the Zeek evidence;
    - every finding and its fix.

    Add one `state/BUILD-STATE.md` log line, and open a PR there.
  - **Kit:** push this branch, and open its PR.
