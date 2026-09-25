# Scenario pack: repeatable GNS3 network scenarios

Date: 2026-09-24 · Status: approved design, not yet implemented
Sub-project 3 of "test out the dashboards and network scenarios" (order:
2 mirror feed → 3 scenario pack → review; later 4 dashboards, 5 end-to-end check).
Depends on: `docs/superpowers/specs/2026-09-24-lab-mirror-feed-design.md`
(the kit-created `lab-tapN` interfaces on `br-lab`).

## Goal

A small pack of GNS3 scenarios, built only from bundled images, that an
operator can bring up, drive with known traffic for a known window, and tear
down with one script — so the dashboards (via the live mirror feed) have
repeatable traffic to show, and sub-project 5 has run records to check against.

## Decisions

- **Each scenario = a GNS3 project + a script**, not hand-clicked projects and
  not topologies generated from a description.
- **Configs baked into the project; traffic via `docker exec`.** Node static
  setup ships as GNS3 persistent-volume files / start command; `traffic` runs
  bounded generators inside the nodes with `docker exec` on the containers
  GNS3 created. Rejected: console automation (fragile, hard to test);
  self-starting traffic (no defined window to check against).
- **IPsec two ways.** `ipsec-esp` uses kernel ESP (`ip xfrm`, manually keyed)
  and runs on today's bundle — ESP only, no IKE. `ipsec-ike` uses strongSwan
  for real IKEv2 + ESP and needs a strongSwan image added to the bundle
  upstream (see Prerequisites); until a bundle carries it, the scenario
  refuses.

## The pack

| Scenario | Nodes | Traffic | Segment on `br-lab` | Range |
|---|---|---|---|---|
| `ipsec-esp` | 2 netshoot gateways + 1 netshoot client each side | ping and iperf3 through a static ESP tunnel | gateway ↔ gateway | 10.201.0.0/16 |
| `ipsec-ike` | 2 strongSwan gateways + 1 netshoot client each side | IKEv2 (UDP 500), then ESP | gateway ↔ gateway | 10.202.0.0/16 |
| `ospf` | 3 FRR routers in a line, 1 netshoot at each end | OSPF hellos/LSAs, then end-to-end ping and iperf3 | router ↔ router | 10.203.0.0/16 |
| `bgp` | 2 FRR routers in different ASes, 1 netshoot behind each | eBGP on TCP 179, route exchange, end-to-end traffic | router ↔ router | 10.204.0.0/16 |
| `client-server` | netshoot client, alpine server (busybox httpd) | HTTP GETs, iperf3, ICMP | client ↔ server | 10.205.0.0/16 |

Each scenario puts exactly one link on the mirrored bridge, through two GNS3
Cloud nodes bound to two `lab-tapN`. NAT-T (UDP 4500) is not exercised
(no NAT in the path). DNS is not part of `client-server` (no DNS server is
guaranteed in the bundled images).

## Components

### 1. `scenarios/` — the pack, as kit content

```
scenarios/<name>/
  scenario.conf    key=value: name, description, range, images (repo basenames,
                   e.g. "netshoot frr"), traffic_secs, ready (node + command),
                   traffic_nodes (which nodes run traffic.sh)
  project/         the GNS3 project, unpacked: <name>.gns3 plus each node's
                   persistent-volume files (frr.conf, daemons, swanctl.conf,
                   net.sh setting addresses / routes / xfrm)
  traffic.sh       runs inside a node via docker exec; bounded generators only
                   (iperf3 -t, ping -c, curl loops with a count)
  expect.txt       one "proto|port|src-range|dst-range" per line: what a run
                   should put on the mirror (read by sub-project 5)
```

- Images are named by repository basename, never with a tag. At `up`, each
  `__IMG_<BASENAME>__` token in the project is rendered with the full
  reference read from the bundle's `gns3/docker-nodes/image-list.txt`
  (`image_ref_from_list`), so `scenarios/` carries no pin.
- Cloud nodes reference `__TAP_A__` / `__TAP_B__`, rendered at `up`.
- The project's comment field carries the marker `r770-scenario:<name>`;
  the imported project is named `lab-scenario-<name>`.

### 2. `scripts/r770-scenario.sh`

A kit script: `scripts/lib/common.sh` seams, 0/2/1, PASS/WARN/FAIL/SKIP,
transcript under `r770-evidence/`.

```
r770-scenario.sh list                          the pack; which are runnable
                                               with this bundle's images, and why not
r770-scenario.sh up      <name> --bundle <dir> [--taps a,b] [--force]
r770-scenario.sh traffic <name>
r770-scenario.sh down    <name>
r770-scenario.sh status                        running scenarios, their taps, last runs
```

- GNS3 API at `http://127.0.0.1:3080/v3`, authenticated with the admin
  credential read from `/etc/lab/secrets/gns3-admin.pw` (never printed).
- The project zip is built with `python3 -m zipfile` / `zipfile` (no `zip`
  binary is guaranteed on the box).
- Taps: two kit-owned `lab-tapN` not bound by any Cloud node of an open GNS3
  project (asked of the GNS3 API — discovered, not guessed); `--taps a,b`
  overrides, and each named tap must be a kit tap and free.
- Not gated: it changes only GNS3 projects and containers it created.

### 3. Prerequisites outside this kit

- **strongSwan image** (for `ipsec-ike` only): added to `GNS3_NODE_IMAGES` in
  the build repo's `scripts/r770-offline-fetch.sh` pin block, resynced into
  `staging/`, and carried by the next bundle cut. Recorded in
  `docs/kit-sync.md`. The kit never names its tag.
- **Lab network**: `r770-gns3-deploy.sh labnet` (mirror-feed spec) has run.
- Malcolm is **not** required to run a scenario; without the live mirror feed
  the traffic simply is not captured.

## Data flow and error handling

### `up <name> --bundle <dir>`

1. Refuses (exit 1, nothing imported) when: GNS3 does not answer on
   `127.0.0.1:3080` (names `r770-gns3-deploy.sh service`); the admin
   credential is missing; a required image is absent from the bundle's list
   or not loaded (names it; for `strongswan`, says it arrives with the next
   bundle cut); a project named `lab-scenario-<name>` exists (unless
   `--force`, which runs `down` first); fewer than two free kit taps (names
   the scenario holding them).
2. Renders `project/` into a temp dir (image refs, taps) with `render()` —
   refusing on any surviving `__TOKEN__` — zips it, imports it.
3. Starts every node; polls until all report `started`
   (`SCENARIO_WAIT_SECS`, default 120) — FAIL on timeout.
4. Readiness: runs the scenario's `ready` command with `docker exec`, retried
   until it succeeds or `SCENARIO_WAIT_SECS` passes:

   | Scenario | Ready when |
   |---|---|
   | `ipsec-esp` | client-to-client ping across the tunnel succeeds |
   | `ipsec-ike` | `swanctl --list-sas` shows an INSTALLED child SA |
   | `ospf` | `vtysh -c 'show ip ospf neighbor'` shows every neighbour `Full` |
   | `bgp` | `vtysh -c 'show bgp summary'` shows the session `Established` |
   | `client-server` | an HTTP GET from client to server succeeds |

5. PASS when ready. On readiness failure: FAIL, nodes **left running for
   inspection** (rule 7), and the exact `down` command printed.

### `traffic <name>`

1. Refuses unless the scenario is up and its readiness command passes.
2. Runs `traffic.sh` in each of `traffic_nodes` via `docker exec` for
   `SCENARIO_TRAFFIC_SECS` (default: the scenario's `traffic_secs`, normally
   60); records UTC start and end.
3. Writes `r770-evidence/scenario-<name>-<host>-<ts>.run` (key=value:
   scenario, range, taps, start, end, expect=`scenarios/<name>/expect.txt`).
4. A generator failing in one node: WARN if at least one other ran; FAIL if
   none did.

### `down <name>`

Stops the nodes and deletes the project (GNS3 releases its taps). Idempotent:
not running → PASS "not running". Touches only a project that is both named
`lab-scenario-<name>` and carries the `r770-scenario:<name>` marker.

### Isolation

Scenarios share the hub, so each uses its own /16 and none routes to another's
range. A second scenario running alongside adds frames to the mirror; it
cannot break the first.

## Testing

Offline and stubbed: the GNS3 API is a `curl` stub serving canned JSON,
`docker` is a stub, zipping uses the real `python3` (on the stub allowlist).
The fixture bundle's GNS3 image list gains `netshoot`.

- `tests/scenario.bats` (the script): `list` marks `ipsec-ike` not runnable
  without strongSwan, naming it, and the rest runnable; `up` refusals (GNS3
  down, image missing or not loaded, fewer than two free taps naming the
  holder, already up without `--force`); `up` renders image refs and taps with
  no surviving `__TOKEN__`, skips taps held by an open project, honours
  `--taps`; readiness PASS; readiness timeout leaves nodes up and prints the
  `down` command; `traffic` refuses when not up; `traffic` writes the run
  record with its keys; generator partial failure → WARN, total → FAIL;
  `down` idempotent, and it leaves alone a project with a similar name but no
  marker.
- `tests/scenarios.bats` (the content): each scenario has `scenario.conf`,
  `project/*.gns3`, `traffic.sh`, `expect.txt` and a `ready` key; each `.gns3`
  parses as JSON (`python3 -m json.tool`); Cloud nodes use only
  `__TAP_A__`/`__TAP_B__` and exactly one link attaches to them; images are
  basenames present in the staging fetch's `GNS3_NODE_IMAGES`, or
  `strongswan` flagged upstream-pending; ranges unique; `traffic.sh` and
  `expect.txt` address only their own range; `traffic.sh` is shellcheck-clean.
- `tests/no-pins.bats` and `tests/no-internet.bats` scan `scenarios/` (widened
  if they do not already).
- Not provable offline: FRR convergence, the xfrm tunnel carrying traffic.
  Proven on the staging rehearsal (transcripts as evidence) and, later,
  automatically by sub-project 5.

## Docs and settings

- `README.md`: rows for `scripts/r770-scenario.sh` and `scenarios/`.
- `docs/deployment-runbook.md`: a "Scenarios" section after GNS3's `labnet` —
  `list`, `up`, `traffic`, `down`, and the mirror spec's evidence checks.
- `docs/CODEMAPS/stages.md`: the script as an operator tool outside every
  `full`.
- `tests/README.md`: rows for `scenario.bats` and `scenarios.bats`.
- `.claude/settings.json`: `allow` entry beside the other kit scripts.
- `docs/kit-sync.md`: the upstream strongSwan pin (prerequisite for
  `ipsec-ike`); `docs/wiki/gns3.md` can gain a scenarios section upstream.

## Out of scope

New dashboards for OSPF / BGP / client-server (sub-project 4); automated
checking against Malcolm (sub-project 5); QEMU appliance scenarios (VyOS,
OPNsense, CHR); WAN impairment; NAT-T; the upstream strongSwan pin itself.
