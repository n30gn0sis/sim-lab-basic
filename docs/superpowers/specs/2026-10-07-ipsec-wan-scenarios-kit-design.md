# IPsec & simulated-WAN scenarios: carrying the spec out with the kit as built

Date: 2026-10-07 · Status: approved design, not yet implemented
Spec: `docs/superpowers/specs/2026-09-24-ipsec-scenarios-spec.md` (the build repo's 0.1 draft, filed with its pins redacted)
Plan: `docs/superpowers/plans/2026-10-07-ipsec-wan-scenarios.md`
Builds on: `docs/superpowers/specs/2026-09-24-lab-mirror-feed-design.md` (hub `br-lab`, kit TAPs, `lab_mirror0`) and
`docs/superpowers/specs/2026-09-24-scenario-pack-design.md` (`scenarios/<name>/`, `r770-scenario.sh`).

## Goal

The spec's scenarios — plaintext baseline, then IPsec over simulated WANs —
run on the R770 **from the kit's existing scenario pack**, each run leaving a
reference set (outer and inner PCAP, ground truth, manifest, checksums) that
is judged by tshark on the box and by Malcolm. First increment: S0 and S1
over W1 with strongSwan (spec IP0–IP4). Later increments are a roadmap in the
plan, entered only once the first increment's open items are dispositioned
on staging.

## What the spec assumes that the kit does not have

| Spec assumes | Kit as built | Decision |
|---|---|---|
| `br-lab-tNN` (outer, mirrored) and `br-lab-iNN` (inner, not mirrored) bridges from `lab-transit.sh` | one hub bridge `br-lab`, always mirrored to `lab_mirror0`; GNS3 reaches it through `lab-tap0..3` (`r770-gns3-deploy.sh labnet`) | **Outer** = the gateway's uplink on `br-lab` through two kit TAPs — exactly how every pack scenario already puts a link on the mirror. **Inner** = never on a host bridge: the host's `tcpdump` runs *inside the gateway container's network namespace* (`nsenter --net`) on its LAN interface. Same host, same clock; and because the inner side never touches `br-lab`, live Malcolm sees only the outer view (spec R4 solved by construction, no `-inner` suppression needed). `lab-transit.sh` and the two-bridge model stay a build-repo question; recorded as a carry-back in `docs/kit-sync.md`. |
| `wan-apply` / `wan-show` / `wan-clear` (buildout Phase 12) | nothing; `docs/wiki/wan.md` says the install path is TBD | A kit script, `r770-wan.sh apply|show|clear`, that shapes **only kit TAPs** (`lab-tapN`): the guard list is the refusal of any other name. Profiles are files under `config/wan/profiles/`, one key=value file per profile, carrying the wiki's values. Mechanism M1 only; M2 (`wan-emu` node) needs a new image and waits for the build repo; M3 (GNS3 link filters) is not used for reference runs, as the spec says. |
| `scen-prep` / `scen-run` / `scen-ingest` / `scen-clear` under `scripts/scenarios/` | `r770-scenario.sh up / traffic / down / check` | No parallel harness. `r770-scenario.sh` gains `record` (traffic with captures, impairment, events, ground truth, manifest), `verify` (tshark checks over a run directory) and `ingest` (PCAPs into Malcolm's upload drop-off, never `gt/`). `prep` is `up`'s refusals plus `record`'s free-space gate; `clear` is `record`'s EXIT trap plus `r770-wan.sh clear --all`. |
| `run.yaml`, `events/*.yaml` | no YAML parser is guaranteed on the box (python3 is, PyYAML is not) | `run.conf` (key=value, like the pack's `.run` records) and `events.txt` (`t|action|arg` per line). |
| per-scenario addressing: 198.18.*n*.0/30 per site, 10.200.*site*.0/24, one shared plan | one unique range per scenario, every address inside it, enforced by `tests/scenarios.bats` | `range=` becomes a space-separated **list** of CIDRs, each unique across the pack; the lint checks every address against the union. Each WAN scenario owns one 198.18.*k*.0/24 slice (uplinks are /30s inside it) and one 10.2*xx*.0.0/16 for its sites, so two scenarios can still share the hub. S0: `198.18.10.0/24 10.210.0.0/16`; S1-ss: `198.18.11.0/24 10.211.0.0/16`. The spec's O1 (final addressing against `lab-fabric.md`) is closed *for the kit* by this rule; the build repo reconciles its own plan. |
| spec X2: "no NAT → IKE stays on UDP 500" | the pack's `ipsec-ike` rehearsal measured strongSwan **floating to 4500 with no NAT in the path** (`docs/deployment-runbook.md`, Scenarios) | That float is MOBIKE (on by default in strongSwan), not NAT detection. S1 sets `mobike = no` on both gateways so X2 holds as written and 4500 is reserved for the NAT-T scenario (S3). Confirmed on staging before the first reference run; `ipsec-ike` keeps its default and its `udp/4500` row. |
| save-keys plugin (O3) | unknown for the bundled strongSwan image | Discovered at run time, never assumed: the gateway's node script enables `save-keys` only when the plugin file is present, and `record` writes `keys=present|absent` into the manifest. With keys, `verify` runs the decryption check (X7); without, X7 is SKIP and the inner capture is the plaintext truth, as the spec allows. |
| `/data/pcap/cases/` exempt from retention, Phase-10 free-space floor | `/data/pcap/raw` is Malcolm's; the floor value lives in the build repo | Run directories under `SCENARIO_CASES_DIR` (default `/data/pcap/cases`); `record` refuses when free space on that filesystem is below `SCENARIO_CASES_MIN_FREE_MB` (default 10240) plus the run's own estimate (rate cap × window). No ring files: a wrapped capture would lose IKE_SA_INIT. |

## Scenario naming

Spec IDs become pack names, lower-case, carrying underlay and variant:
`s0-w1` (plaintext baseline), `s1-w1-ss` (site-to-site IKEv2 PSK, strongSwan).
Later: `s2-w2-ss`, `s3-w4-ss`, `s1-w1-vy`, … The pack's existing `ipsec-ike`
(gateways adjacent on `br-lab`, no ISP) stays as it is; `r770-e2e.sh` keeps
running it.

## The W1 topology, as a pack scenario

```
 [h-a]──[gw-a]──(Cloud TAP_A) br-lab (Cloud TAP_B)──[isp1]──[gw-b]──[h-b]
```

One mirrored link: gw-a's uplink. `isp1` is FRR with interfaces on both /30s.
In `s0-w1` it also holds static routes to both site LANs (otherwise there is
no baseline); in `s1-w1-ss` it holds **none** — the ISP never knows the sites,
which is what makes plaintext leakage detectable (spec §11.1). gw-b's uplink
and both LAN links are plain GNS3 links (ubridge), invisible to the host —
inner capture reaches them from inside the gateway's namespace, not from a
bridge. The second access link is captured only in later underlays (W2
asymmetry); S1's X1–X9 need one outer point.

| Link | s0-w1 | s1-w1-ss |
|---|---|---|
| gw-a uplink | 198.18.10.0/30 (isp1 .1, gw-a .2) | 198.18.11.0/30 (isp1 .1, gw-a .2) |
| gw-b uplink | 198.18.10.4/30 (isp1 .5, gw-b .6) | 198.18.11.4/30 (isp1 .5, gw-b .6) |
| site A | 10.210.1.0/24 (gw-a .1, h-a .10) | 10.211.1.0/24 (gw-a .1, h-a .10) |
| site B | 10.210.2.0/24 (gw-b .1, h-b .10) | 10.211.2.0/24 (gw-b .1, h-b .10) |

## `record`: one run, one directory

```
$SCENARIO_CASES_DIR/<name>/<name>-<UTC yyyymmddThhmmZ>/
├── run.conf             scenario, run_id, taps, outer/inner capture points, impairment, keys=, start/end, idle_start
├── outer-<TAP_A>.pcapng tcpdump on the kit TAP nearest gw-a
├── inner-gw-a.pcapng    host tcpdump inside gw-a's netns, its LAN interface
├── inner-gw-b.pcapng
├── gt/<node>/           swanctl --list-sas snapshots (start, after each event, end), charon.log, keys/ if present
├── events.log           every executed event, UTC with milliseconds
├── capture-stats.txt    tcpdump's "packets dropped by kernel" per capture
└── sha256sums
```

Order inside `record`: free-space gate → captures start → ground-truth
snapshot → traffic (the scenario's `traffic.sh`, as `traffic` runs it) with
the event scheduler alongside → idle tail (`idle_secs`, so DPD shows) →
captures stop → ground truth collected → stats, `sha256sums`, the pack's
usual `.run` record (so `check` works unchanged). An EXIT trap stops every
capture and clears every qdisc the run applied, on success, failure or
Ctrl-C (spec H6). Captures start **before** `traffic.sh` tears the IKE SA
down, so IKE_SA_INIT is in the file.

Impairment is a run parameter, not scenario content: `--impair <profile>@a|b`
applies the profile to `TAP_A` or `TAP_B`. A frame from gw-a to isp1 enters
the host through `TAP_A` and leaves through `TAP_B`, so `@b` shapes site A →
site B and `@a` the reverse — asymmetry without IFB. Measured on staging
before it is written as fact in the runbook (harness test H7, plan Task 11).

## `verify`: the expected observations, on the box

`scenarios/<name>/pcap-expect.txt`, one check per line:
`<file>|<mode>|<tshark display filter>|<expectation>|<label>` where mode is
`count` (expectation `0` or `>0`) or `distinct <field>` (expectation `>=N`).
Tokens from `run.conf` are rendered first (`__IDLE_START__`, the epoch when
the idle tail began). S1's rows are the spec's X1–X6 verbatim (X2 with
`mobike = no`); X7 is the decryption check (tshark with a Wireshark profile
built from `gt/<node>/keys/`, SKIP when `keys=absent`); X8 reads
`capture-stats.txt`; X9 is `check` after `ingest`.

## `ingest`: into Malcolm, never the keys

Copies `outer-*.pcapng` and `inner-*.pcapng` into Malcolm's upload drop-off
(`<stack>/pcap/upload/`, owned 1000:1000 — measured on the 2026-09 rehearsal)
as `<run-id>,<view>.pcapng`, which Malcolm tags from the filename. `gt/` is
never read by `ingest`; a test proves the run directory's `gt/` leaves no
file in the drop-off.

## Risks carried from the spec, with the kit's answer

| Spec | Kit |
|---|---|
| R1 Docker's FORWARD DROP on bridged traffic | already settled: `br-lab` carries the pack's traffic today; `r770-validate.sh --area network` stays the check |
| R2 endpoints negotiate but pass no traffic | already measured: the pack's `ipsec-esp` and `ipsec-ike` carried ESP through containers on this kernel (2026-09-26 rehearsal), so policy-based IPsec needs no host module preload; `xfrm_interface` (route-based, S2) is a gated `labnet` addition in the roadmap. `ip xfrm state` inside the node is the check (plan Task 11) |
| R3 bridge capture misses frames | outer capture is on the TAP (the member port), not the bridge; H1 compares both on staging |
| R5 keys into Git or Malcolm | `*/gt/` gitignored; `ingest` copies by explicit pattern and a test proves `gt/` never lands in the drop-off |
| R6 `cases/` fills `/data/pcap` | free-space gate; no auto-deletion |
| R8 MTU surprises | the W1 validation in `s0-w1`'s `traffic.sh` includes `ping -M do -s 1472`; recorded in the manifest |
| R9 host load | `run.conf` records 1-min load at start and end |

## Out of scope for the first increment

W2–W7, S2–S9, appliances (VyOS, OPNsense, CHR), the `wan-emu` node, lane B
replay, lane C physical ingress, certificates and the IPsec lab CA. Each is a
roadmap entry in the plan with its entry criteria.
