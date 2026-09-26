# Lab mirror feed: live GNS3 traffic into Malcolm

> **Correction (2026-09-25, staging rehearsal):** the capture end is named `lab_mirror0`, not `lab-mirror0`. Malcolm's pcap-capture container runs `export $IFACE` for each capture interface, so the name must be a valid shell identifier; the hyphenated name made netsniff capture fail at start.

Date: 2026-09-24 · Status: approved design, not yet implemented
Sub-project 2 of "test out the dashboards and network scenarios" (order:
2 mirror feed → 3 scenario pack → review; later 4 dashboards, 5 end-to-end check).

## Goal

Traffic from a running GNS3 topology appears in Malcolm (Arkime sessions, Zeek
logs, the kit's dashboards) live — within about a minute — the way the R770 is
meant to work. First exercised on staging VM 9770 in an air-gapped rehearsal
built from a fresh bundle; the same kit then runs unchanged on the R770.

This is the live half of build-repo Phase 11 ("virtual mirror feed").

## Decisions

- **Live, not import.** Malcolm captures a live interface; the imported-PCAP
  workflow is out of scope here.
- **One shared, always-mirrored lab bridge.** A scenario puts the segment it
  wants analysed on that bridge; everything crossing the bridge is captured.
  No per-scenario mirror toggling.
- **Hub-mode Linux bridge plus a capture veth.** `br-lab` runs with
  `ageing_time 0`, so it floods every frame to every port; one end of a veth
  pair is a bridge port, Malcolm sniffs the other end. This replaces the build
  repo's buildout plan §7 mechanism (`tc mirred` per port) — recorded as a
  decision to carry back (see Docs). Rejected: `tc mirred` (needs a udev or
  systemd hook to follow GNS3's ports as they come and go, with a race);
  Open vSwitch (deferred by the build repo, not in the bundle).
- **GNS3 links reach the bridge through kit-created TAPs.** GNS3 node-to-node
  links are ubridge UDP tunnels that no host tool can see; a scenario binds a
  GNS3 Cloud node to a `lab-tapN` to put a link on `br-lab`.
- **Cloud nodes bind `lab-tapN` on the TAP tab, never the Ethernet tab.**
  gns3-server types a Cloud interface as `tap` only when its name starts with
  `tap`; any other name is typed `ethernet` and ubridge opens it with an
  AF_PACKET raw socket. A persistent TAP that no process holds open (its fd
  is what ubridge's TAP binding supplies) drops frames written that way, so
  an Ethernet-tab binding of `lab-tap0` puts nothing on `br-lab`. The kit
  keeps the `lab-tapN` names (they mark the interfaces as the kit's) and every
  instruction and scenario says TAP tab — in a project file, the Cloud's
  `ports_mapping` entry has `"type": "tap"` and `"interface": "lab-tapN"`.
  This was read from gns3-server's master branch, not the bundled release;
  the staging rehearsal confirms it against the bundled GNS3 (evidence: the
  bound `lab-tapN` leaves `NO-CARRIER` while the node runs).

## Components

### 1. `r770-gns3-deploy.sh labnet` (new step, GATED)

Appended to GNS3's `STEPS`, after `service`:
`... load venv secrets config service labnet`.

Installs systemd-networkd files under `/etc/systemd/network/`, rendered from
`config/networkd/`, then `networkctl reload`. Declarative, reboot-safe, and
leaves netplan and every existing interface alone.

| Interface | Kind | Settings |
|---|---|---|
| `br-lab` | bridge | `AgeingTimeSec=0`; no address; `LinkLocalAddressing=no`; IPv6 off; no physical port |
| `lab-tap0` … `lab-tap<N-1>` | TAP | `User=` / `Group=` the GNS3 service user; port of `br-lab`; no address |
| `lab-mon0` | veth (bridge end) | port of `br-lab`; no address |
| `lab-mirror0` | veth (capture end) | no address; `LinkLocalAddressing=no`; IPv6 off; ARP off; promiscuous; not a port of anything |

- N = `GNS3_LAB_TAPS`, default `4`.
- These names are owned by the kit because the kit creates them; no existing
  interface is ever chosen or touched. The step refuses when any of them
  already exists without the kit's own `.netdev` file behind it.
- Gate text: *current* (which of these interfaces and files exist),
  *proposed* (the file list), *rollback*
  (`rm /etc/systemd/network/{br-lab,lab-}*; networkctl reload; ip link del br-lab; ip link del lab-mon0; ip link del lab-tap<i>` for each i).

### 2. `r770-malcolm-deploy.sh configure --capture-ifs "<if ...>"`

New option, space-separated interface names, used by `configure` (and passed
through by `full`). `config/malcolm/malcolm-config.json.template` gains four
tokens, all rendered by `configure`:

| Token | Replaces | With `--capture-ifs` | Without |
|---|---|---|---|
| `__PCAP_IFACE__` | `"pcapIface": []` | JSON list of the names, e.g. `["lab-mirror0"]` | `[]` |
| `__CAPTURE_LIVE__` | `"captureLiveNetworkTraffic": false` | `true` | `false` |
| `__LIVE_ARKIME__` | `"liveArkime": false` | `true` | `false` |
| `__LIVE_ZEEK__` | `"liveZeek": false` | `true` | `false` |

Without `--capture-ifs` the rendered config is byte-identical to today's.
`liveSuricata` stays `false` (Suricata disabled by decision); `tweakIface`
stays `false` (Malcolm must not change offloads on a virtual interface).

On staging: `--capture-ifs lab-mirror0`. On the R770 later, the discovered
physical capture ports join the same list; no design change.

### 3. `r770-validate.sh --area network --lab-bridge BR --capture-ifs "..."`

New rows when `--lab-bridge` is given:

- bridge in hub mode (`/sys/class/net/<BR>/bridge/ageing_time` = `0`)
- the bridge has no physical port (every entry under `brif/` is virtual —
  no `device` link in its sysfs directory); rule 8
- a veth whose peer is in `--capture-ifs` is a port of the bridge
- each `--capture-ifs` interface that belongs to the mirror has no IPv4/IPv6
  address, link-local included (the existing capture row already checks
  address/promisc for all capture interfaces)

Missing `--lab-bridge` keeps today's SKIP ("bridges are never guessed").

### Ordering

GNS3's `labnet` before Malcolm's `configure --capture-ifs lab-mirror0`:
`configure` refuses an interface that does not exist. The two pipelines stay
otherwise independent.

## Data flow

GNS3 node → ubridge → Cloud node bound to `lab-tapN` on its TAP tab
(`"type": "tap"`: ubridge holds the TAP's fd) → `br-lab` (hub: flooded
to every port) → peer TAP (the other side of the scenario's link) and
`lab-mon0` → veth → `lab-mirror0` → Malcolm live Arkime + Zeek (host network,
AF_PACKET) → `/data/pcap/raw` + OpenSearch → Dashboards / Arkime views.

`br-lab` has no physical port and no NAT: lab traffic cannot leave the box.

Every scenario on the hub sees the others' frames, so each scenario in the
scenario pack (sub-project 3) uses its own address range.

## Error handling

### `labnet`

Refuses (exit 1, nothing written) when:
- `systemctl is-active systemd-networkd` is not `active` (the files would do
  nothing);
- the GNS3 service user does not exist (`config` creates it; TAP ownership
  needs it);
- a kit interface name exists without the kit's `.netdev` file for it.

Idempotent: every file identical (`cmp -s`) to what would be rendered → PASS
"already in place", no gate. Any difference → the gate again.

After `networkctl reload`, asserts (FAIL on each miss):
- `br-lab` `ageing_time` reads `0`;
- every `lab-tap<i>` and `lab-mon0` is listed under `/sys/class/net/br-lab/brif/`;
- no physical interface is a port of `br-lab`;
- `lab-mirror0` is up, promiscuous, and has no IPv4 or IPv6 address.

`--dry-run` prints the rendered files and the commands and writes nothing.

### `configure --capture-ifs`

Refuses when:
- a named interface does not exist (for a `lab-*` name, the message points
  at `r770-gns3-deploy.sh labnet`);
- a named interface carries an IPv4 or IPv6 address;
- the list is empty or repeats a name.

`status` additionally reports whether live capture is configured and on which
interfaces.

### Evidence that live works (manual on staging; sub-project 5 automates)

- `tcpdump -c 5 -i lab-mirror0` shows frames while a scenario runs;
- Arkime shows sessions from the scenario's address range within about a
  minute, with matching Zeek logs;
- `r770-validate.sh --area capture` reports `capture_loss` for the interface.

## Testing

All stubbed; `/sys/class/net` is read through `p`, so suites build a fake
sysfs under `KIT_ROOT`; `ip`, `networkctl`, `systemctl`, `getent` are stubs.

- `tests/gns3-deploy.bats` (`labnet`): gate — unattended without `--yes`
  writes nothing; rendered files carry `AgeingTimeSec=0`, TAP `User=` the
  service user, no `Address=` anywhere, and the capture end has link-local,
  IPv6 and ARP off; refusals (networkd inactive, user missing, name
  collision); second run with identical files skips the gate; post-reload
  FAIL when `ageing_time` ≠ 0, when a physical interface is a port, when
  `lab-mirror0` has an address; `full` ends with `labnet`.
- `tests/malcolm-deploy.bats` (`configure`): no `--capture-ifs` → rendered
  config byte-identical to today's; `--capture-ifs lab-mirror0` →
  `"pcapIface": ["lab-mirror0"]` and the three live flags `true`; refusals
  (missing interface naming `labnet`, addressed interface, duplicate).
- `tests/validate.bats`: the new network rows PASS on a correct fake sysfs and
  FAIL on each violation; SKIP without `--lab-bridge`.
- `tests/config.bats`, `tests/references.bats`: cover the new config files
  and tokens with no change to the suites.

## Config and docs

- `config/networkd/`: `br-lab.netdev`, `br-lab.network`,
  `lab-tap.netdev.template`, `lab-tap.network.template` (tokens
  `__TAP_NAME__`, `__TAP_USER__`, rendered once per TAP), `lab-mirror.netdev`,
  `lab-mon0.network`, `lab-mirror0.network`.
- `config/README.md`: delta row for `networkd/` (new — Phase 11 live mirror);
  token rows for `__TAP_NAME__`, `__TAP_USER__` (`gns3-deploy labnet`) and
  `__PCAP_IFACE__`, `__CAPTURE_LIVE__`, `__LIVE_ARKIME__`, `__LIVE_ZEEK__`
  (`malcolm-deploy configure`, from `--capture-ifs`); the Malcolm template's
  delta row lists the four new tokens.
- `docs/deployment-runbook.md`: GNS3 step G10 `labnet` (GATED); Malcolm's
  configure step shows `--capture-ifs lab-mirror0` with "run GNS3's `labnet`
  first"; the manual evidence checks above.
- `docs/rollback.md`: rows for `labnet` and for turning live capture off
  (rerun `configure` without `--capture-ifs`).
- `docs/CODEMAPS/stages.md`: `labnet` 🔒 in GNS3's `full`; the gates list
  gains it. `docs/validation.md`: the new network rows.
- `CLAUDE.md` rule 2: the gated changes gain "the lab network".
- `docs/kit-sync.md`: two items to carry to the build repo — the hub-mode
  bridge replaces buildout plan §7's `tc mirred`; `docs/wiki/gns3.md`'s mirror
  "TBD" can become "bind a Cloud node to a `lab-tapN`". `docs/wiki/` itself is
  build-repo content and is not edited here.

## Out of scope

The scenarios (sub-project 3), new dashboards (4), the automated end-to-end
scenario check (5), physical R770 capture ports (they join `--capture-ifs`
later), the imported-PCAP workflow, and WAN impairment.
