# Lab Mirror Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Traffic crossing a kit-created, hub-mode lab bridge (`br-lab`) reaches Malcolm's live capture through a veth (`lab-mirror0`), so a running GNS3 scenario shows up in Arkime, Zeek and the dashboards within about a minute.

**Architecture:** GNS3's pipeline gains a gated `labnet` step that installs systemd-networkd files for `br-lab` (`AgeingTimeSec=0`), N TAPs owned by the GNS3 user, and a veth pair `lab-mon0` (bridge port) ⇄ `lab-mirror0` (capture end), then asserts the live state from sysfs. Malcolm's `configure` gains `--capture-ifs "<if ...>"`, rendered into four new config tokens that turn on live Arkime and Zeek capture. `r770-validate.sh --area network --lab-bridge BR` gains rows that prove hub mode, no physical port, and the mirror wiring.

**Tech Stack:** bash, systemd-networkd, bats-core ≥ 1.10, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-24-lab-mirror-feed-design.md`

## Global Constraints

- `./tests/run.sh` green before every commit: shellcheck with **no exclusions** (never add `# shellcheck disable`), every `tests/*.bats`. Baseline on branch `lab-mirror-feed`: 192/192.
- Tests never touch the host: stubbed PATH (`kit_test_env`/`kit_run`/`stub`), every path through `p` under `$ROOT`. Sysfs is read as `$(p /sys/class/net)` so suites build a fake one under `$ROOT`.
- Rule 1: interfaces are arguments or kit-created. The kit's own names are exactly `br-lab`, `lab-tap0`…`lab-tap<N-1>`, `lab-mon0`, `lab-mirror0`; nothing else is ever chosen, created, or modified.
- Rule 2: `labnet` is GATED (current · proposed · rollback, `--yes` or `y`).
- Rule 8: `br-lab` never has a physical port; capture interfaces never carry an address.
- Installed networkd file names: `05-br-lab.netdev`, `05-br-lab.network`, `05-lab-tap<i>.netdev`, `05-lab-tap<i>.network`, `05-lab-mirror.netdev`, `05-lab-mon0.network`, `05-lab-mirror0.network`, all under `/etc/systemd/network/` (the `05-` prefix orders them ahead of netplan's generated `10-netplan-*`).
- `GNS3_LAB_TAPS` default `4`; `GNS3_LABNET_WAIT_SECS` default `10`.
- New config tokens, exactly: `__TAP_NAME__`, `__TAP_USER__` (rendered by `r770-gns3-deploy.sh labnet`); `__PCAP_IFACE__`, `__CAPTURE_LIVE__`, `__LIVE_ARKIME__`, `__LIVE_ZEEK__` (rendered by `r770-malcolm-deploy.sh configure`). Without `--capture-ifs` they render to `[]`, `false`, `false`, `false`.
- `liveSuricata` and `tweakIface` stay `false`.
- No version pins; no external URLs; nothing under `staging/` or `docs/wiki/` is edited.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA
  ```

## File map

| File | Task | Responsibility |
|---|---|---|
| `config/networkd/{br-lab.netdev,br-lab.network,lab-tap.netdev.template,lab-tap.network.template,lab-mirror.netdev,lab-mon0.network,lab-mirror0.network}` | 1 | the lab network, declaratively |
| `scripts/r770-gns3-deploy.sh` | 1 | `labnet` step (+ `full`) |
| `tests/gns3-deploy.bats` | 1 | `labnet` suite; `full` test updated |
| `config/malcolm/malcolm-config.json.template` | 2 | four live-capture tokens |
| `scripts/r770-malcolm-deploy.sh` | 2 | `--capture-ifs`, checks, render, status |
| `tests/malcolm-deploy.bats` | 2 | configure with/without `--capture-ifs` |
| `config/README.md`, `tests/config.bats` | 1, 2 | delta + token tables; known-token list |
| `scripts/r770-validate.sh`, `tests/validate.bats` | 3 | lab-bridge rows |
| `docs/deployment-runbook.md`, `docs/rollback.md`, `docs/CODEMAPS/stages.md`, `docs/validation.md`, `docs/kit-sync.md`, `CLAUDE.md`, `README.md` | 4 | docs |

---

### Task 1: `labnet` — the mirrored lab bridge in GNS3's pipeline

**Files:**
- Create: `config/networkd/br-lab.netdev`, `config/networkd/br-lab.network`, `config/networkd/lab-tap.netdev.template`, `config/networkd/lab-tap.network.template`, `config/networkd/lab-mirror.netdev`, `config/networkd/lab-mon0.network`, `config/networkd/lab-mirror0.network`
- Modify: `scripts/r770-gns3-deploy.sh` (header, globals/`STEPS`, new functions before `# ── full`, `cmd_full` case arm, dispatch)
- Modify: `tests/gns3-deploy.bats` (new helpers + tests; the existing `full` test)
- Modify: `config/README.md` (delta row + token rows), `tests/config.bats` (known tokens)

**Interfaces:**
- Consumes (common.sh): `gate`, `render`, `run`, `p`, `pass`, `fail`, `die`, `banner`, `footer`, `need_root`; globals `DRY`, `KIT_CONFIG_DIR`, `GNS3_USER`.
- Produces: `cmd_labnet`; `STEPS` ending `... service labnet`; interfaces `br-lab`, `lab-tap<i>`, `lab-mon0`, `lab-mirror0` (Task 2 and Task 3 refer to `lab-mirror0` and `br-lab` by name).

- [ ] **Step 1: Create the networkd config files**

`config/networkd/br-lab.netdev`:
```ini
# The lab bridge every scenario shares. AgeingTimeSec=0 keeps no MAC table,
# so the bridge floods every frame to every port -- including lab-mon0, whose
# veth peer lab-mirror0 is what Malcolm captures. Installed by
# r770-gns3-deploy.sh labnet as /etc/systemd/network/05-br-lab.netdev.
[NetDev]
Name=br-lab
Kind=bridge

[Bridge]
AgeingTimeSec=0
STP=no
```

`config/networkd/br-lab.network`:
```ini
# br-lab carries no address: it is a lab fabric, never a host interface.
[Match]
Name=br-lab

[Network]
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
```

`config/networkd/lab-tap.netdev.template`:
```ini
# One persistent TAP for a GNS3 Cloud node to bind; owned by the GNS3
# service user so gns3server (via ubridge) can open it.
[NetDev]
Name=__TAP_NAME__
Kind=tap

[Tap]
User=__TAP_USER__
Group=__TAP_USER__
```

`config/networkd/lab-tap.network.template`:
```ini
[Match]
Name=__TAP_NAME__

[Network]
Bridge=br-lab
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
```

`config/networkd/lab-mirror.netdev`:
```ini
# The mirror: lab-mon0 is a port of br-lab, lab-mirror0 is the capture end
# Malcolm sniffs (r770-malcolm-deploy.sh configure --capture-ifs lab-mirror0).
[NetDev]
Name=lab-mon0
Kind=veth

[Peer]
Name=lab-mirror0
```

`config/networkd/lab-mon0.network`:
```ini
[Match]
Name=lab-mon0

[Network]
Bridge=br-lab
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
```

`config/networkd/lab-mirror0.network`:
```ini
# The capture end must be silent: no address of any kind, no ARP, and
# promiscuous so it hands Malcolm every frame the hub floods to lab-mon0.
[Match]
Name=lab-mirror0

[Network]
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes

[Link]
ARP=no
Promiscuous=yes
RequiredForOnline=no
```

- [ ] **Step 2: Write the failing tests**

In `tests/gns3-deploy.bats`, in `setup()` add `export BATS_TEST_TMPDIR` on the line after `export ROOT GNS3_WAIT_SECS=1`, and add `export GNS3_LABNET_WAIT_SECS=1` on the same line block.

Replace the existing test `full runs preflight through service in order: ...` (whole `@test` block) with:

```bash
@test "full runs preflight through labnet in order: r770-import-bundle.sh for the shared steps, this script's own subcommands after" {
    stub_import_bundle
    stub_docker_reporting docker.io/library/alpine:latest quay.io/frrouting/frr:0.0.0-fixture
    # the service user exists once config's useradd has run, as on a real box
    stub useradd 'echo "useradd $*" >> "$STUB_LOG"; touch "$BATS_TEST_TMPDIR/gns3-user"'
    stub getent 'case "$1 $2" in "passwd gns3") [ -e "$BATS_TEST_TMPDIR/gns3-user" ];; "group kvm") exit 0;; "group docker") exit 0;; *) exit 1;; esac'
    stub_labnet_host
    run gns3 full --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(awk '{print $2}' "$IMPORT_LOG" | paste -sd' ')" = "preflight gate copy apt phone-home docker files" ]
    grep -q "^import-bundle preflight --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^import-bundle gate --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^import-bundle copy --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^docker load -i $BUNDLE/gns3/docker-nodes/gns3-node-images.tar.gz" "$STUB_LOG"
    grep -q '^useradd --system' "$STUB_LOG"
    s=$(grep -n '^systemctl enable --now gns3' "$STUB_LOG" | cut -d: -f1)
    r=$(grep -n '^networkctl reload' "$STUB_LOG" | cut -d: -f1)
    [ -n "$s" ] && [ -n "$r" ] && [ "$s" -lt "$r" ]
    [[ "$output" == *"DEPLOYED — every step clean"* ]]
}
```

Append at the end of the file:

```bash
# ── labnet — the mirrored lab bridge ───────────────────────────────────────

NETD_DIR() { echo "$ROOT/etc/systemd/network"; }

# sys_after_reload [ageing_time] [physical-port] [mirror-flags] — what a
# networkctl reload leaves in sysfs, written by the networkctl stub under
# $ROOT. Defaults are the correct state: hub mode, no physical port, mirror
# end up and promiscuous (IFF_PROMISC = 0x100).
sys_after_reload() {
    cat > "$BATS_TEST_TMPDIR/on-reload" <<EOF
#!/usr/bin/env bash
s="$ROOT/sys/class/net"
mkdir -p "\$s/br-lab/bridge" "\$s/br-lab/brif" "\$s/lab-mirror0" "\$s/lab-mon0"
echo "${1:-0}" > "\$s/br-lab/bridge/ageing_time"
for i in 0 1 2 3; do mkdir -p "\$s/lab-tap\$i"; touch "\$s/br-lab/brif/lab-tap\$i"; done
touch "\$s/br-lab/brif/lab-mon0"
echo up > "\$s/lab-mirror0/operstate"
echo "${3:-0x1103}" > "\$s/lab-mirror0/flags"
if [ -n "${2:-}" ]; then mkdir -p "\$s/${2:-}/device"; touch "\$s/br-lab/brif/${2:-}"; fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/on-reload"
}

# stub_labnet_host — networkd active, the service user present, networkctl
# reload "creates" the interfaces, and ip reports an address on lab-mirror0
# only when MIRROR_ADDR is set.
stub_labnet_host() {
    stub systemctl 'echo "systemctl $*" >> "$STUB_LOG"; [ "$*" = "is-active systemd-networkd" ] && echo active; exit 0'
    stub networkctl 'echo "networkctl $*" >> "$STUB_LOG"; [ "$1" = reload ] && [ -x "$BATS_TEST_TMPDIR/on-reload" ] && "$BATS_TEST_TMPDIR/on-reload"; exit 0'
    stub ip 'case "$*" in *"addr show dev lab-mirror0"*) [ -n "${MIRROR_ADDR:-}" ] && echo "9: lab-mirror0    inet6 fe80::1/64 scope link";; esac; exit 0'
    [ -e "$BATS_TEST_TMPDIR/on-reload" ] || sys_after_reload
}
labnet_user() { stub getent 'case "$1 $2" in "passwd gns3") exit 0;; *) exit 1;; esac'; }

@test "labnet is gated: unattended without --yes writes no file and reloads nothing" {
    stub_labnet_host; labnet_user
    unset KIT_YES
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a decision"* ]]
    [[ "$output" == *"-- rollback --"* ]]
    [ -z "$(find "$(NETD_DIR)" -name '05-*' 2>/dev/null)" ]
    ! grep -q '^networkctl' "$STUB_LOG"
}

@test "labnet installs a hub-mode bridge, owned TAPs and a silent mirror end, then proves them" {
    stub_labnet_host; labnet_user
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 0 ]
    d=$(NETD_DIR)
    grep -qx 'AgeingTimeSec=0' "$d/05-br-lab.netdev"
    for i in 0 1 2 3; do
        grep -qx "Name=lab-tap$i" "$d/05-lab-tap$i.netdev"
        grep -qx 'User=gns3' "$d/05-lab-tap$i.netdev"
        grep -qx 'Bridge=br-lab' "$d/05-lab-tap$i.network"
    done
    [ ! -e "$d/05-lab-tap4.netdev" ]
    grep -qx 'Bridge=br-lab' "$d/05-lab-mon0.network"
    grep -qx 'Name=lab-mirror0' "$d/05-lab-mirror.netdev"
    for k in 'LinkLocalAddressing=no' 'IPv6AcceptRA=no' 'ARP=no' 'Promiscuous=yes'; do grep -qx "$k" "$d/05-lab-mirror0.network"; done
    ! grep -rq '^Address=' "$d"
    ! grep -rq '__[A-Z_]*__' "$d"
    grep -q '^networkctl reload' "$STUB_LOG"
    [[ "$output" == *"PASS  br-lab is in hub mode"* ]]
    [[ "$output" == *"PASS  lab-mon0 and 4 TAP(s) are ports of br-lab"* ]]
    [[ "$output" == *"PASS  br-lab has no physical port"* ]]
    [[ "$output" == *"PASS  lab-mirror0 is up and promiscuous"* ]]
    [[ "$output" == *"PASS  lab-mirror0 carries no address"* ]]
}

@test "labnet honours GNS3_LAB_TAPS" {
    stub_labnet_host; labnet_user
    GNS3_LAB_TAPS=2 run gns3 labnet
    echo "$output"
    d=$(NETD_DIR)
    [ -e "$d/05-lab-tap1.netdev" ]
    [ ! -e "$d/05-lab-tap2.netdev" ]
}

@test "labnet refuses when systemd-networkd is not active, and writes nothing" {
    stub_labnet_host; labnet_user
    stub systemctl 'echo inactive; exit 3'
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"systemd-networkd is not active"* ]]
    [ -z "$(find "$(NETD_DIR)" -name '05-*' 2>/dev/null)" ]
}

@test "labnet refuses before the GNS3 service user exists, naming config" {
    stub_labnet_host
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"service user gns3 does not exist"* ]]
    [[ "$output" == *"run config first"* ]]
}

@test "labnet refuses a kit interface name that something else already owns" {
    stub_labnet_host; labnet_user
    mkdir -p "$ROOT/sys/class/net/br-lab"
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"interface br-lab already exists"* ]]
    [ -z "$(find "$(NETD_DIR)" -name '05-*' 2>/dev/null)" ]
}

@test "labnet is idempotent: a second run finds the files in place and skips the gate" {
    stub_labnet_host; labnet_user
    run gns3 labnet
    [ "$status" -eq 0 ]
    : > "$STUB_LOG"
    unset KIT_YES
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in place"* ]]
    [[ "$output" != *"== GATE"* ]]
    ! grep -q '^networkctl reload' "$STUB_LOG"
}

@test "labnet FAILs when the bridge is not in hub mode" {
    stub_labnet_host; labnet_user; sys_after_reload 30000
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  br-lab ageing_time is 30000"* ]]
}

@test "labnet FAILs when a physical interface has joined br-lab (rule 8)" {
    stub_labnet_host; labnet_user; sys_after_reload 0 eno1
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  physical interface(s) on br-lab: eno1"* ]]
}

@test "labnet FAILs when the mirror end carries an address or is not promiscuous" {
    stub_labnet_host; labnet_user; sys_after_reload 0 "" 0x1003
    MIRROR_ADDR=1 run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  lab-mirror0 has 1 address(es)"* ]]
    [[ "$output" == *"FAIL  lab-mirror0 is not up and promiscuous"* ]]
}

@test "labnet --dry-run prints the files and writes nothing" {
    stub_labnet_host; labnet_user
    run gns3 labnet --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"== 05-br-lab.netdev"* ]]
    [[ "$output" == *"DRY-RUN: networkctl reload"* ]]
    [ -z "$(find "$(NETD_DIR)" -name '05-*' 2>/dev/null)" ]
}
```

- [ ] **Step 3: Run them to confirm they fail**

Run: `bats tests/gns3-deploy.bats --filter 'labnet'`
Expected: every labnet test `not ok` (`unknown subcommand: labnet`), including the rewritten `full` test (`networkctl reload` never appears).

- [ ] **Step 4: Implement `labnet` in `scripts/r770-gns3-deploy.sh`**

(a) Header: after the line `#   service    install + enable the systemd unit, assert 127.0.0.1:3080  (GATED)` insert:
```bash
#   labnet     the mirrored lab bridge: br-lab (hub mode), lab-tap0..N-1 for
#              GNS3 Cloud nodes, lab-mon0 <-> lab-mirror0 for Malcolm's
#              capture; systemd-networkd files, then proven from sysfs (GATED)
```
Replace the two lines
```bash
#              that refuses: preflight gate copy apt phone-home docker files
#              load venv secrets config service (see --from/--to/--only)
```
with
```bash
#              that refuses: preflight gate copy apt phone-home docker files
#              load venv secrets config service labnet (see --from/--to/--only)
```
Replace
```bash
#   GNS3_HOME /opt/gns3 · GNS3_USER gns3 · GNS3_ETC /etc/gns3 · GNS3_WAIT_SECS 60
```
with
```bash
#   GNS3_HOME /opt/gns3 · GNS3_USER gns3 · GNS3_ETC /etc/gns3 · GNS3_WAIT_SECS 60
#   GNS3_LAB_TAPS 4 · GNS3_LABNET_WAIT_SECS 10
```

(b) Globals: replace
```bash
STEPS=(preflight gate copy apt phone-home docker files load venv secrets config service)
```
with
```bash
LAB_TAPS="${GNS3_LAB_TAPS:-4}"
LABNET_WAIT_SECS="${GNS3_LABNET_WAIT_SECS:-10}"
NETD="/etc/systemd/network"
LABNET_STAGE=""
STEPS=(preflight gate copy apt phone-home docker files load venv secrets config service labnet)
```

(c) Insert this block directly above the line `# ── full ─────...`:

```bash
# ── labnet — the mirrored lab bridge ─────────────────────────────────────────
# br-lab runs with ageing_time 0, so it keeps no MAC table and floods every
# frame to every port -- including lab-mon0, whose veth peer lab-mirror0 is
# the interface Malcolm captures. A scenario puts a link on the bridge by
# binding a GNS3 Cloud node to a lab-tapN. Declared as systemd-networkd files
# so it survives a reboot and leaves netplan and every existing interface
# alone. The names are the kit's own: it creates them, it never picks one.
lab_names() {  # every interface name this step owns, one per line
    local i
    printf '%s\n' br-lab lab-mon0 lab-mirror0
    for ((i = 0; i < LAB_TAPS; i++)); do printf 'lab-tap%s\n' "$i"; done
}
lab_owner_file() {  # lab_owner_file <ifname> — the installed .netdev that declares it
    case "$1" in
        br-lab)               echo 05-br-lab.netdev ;;
        lab-mon0|lab-mirror0) echo 05-lab-mirror.netdev ;;
        *)                    echo "05-$1.netdev" ;;
    esac
}
labnet_stage() {  # labnet_stage <dir> — every file this step installs, rendered into <dir>
    local d=$1 src="$KIT_CONFIG_DIR/networkd" i
    cp "$src/br-lab.netdev" "$d/05-br-lab.netdev"
    cp "$src/br-lab.network" "$d/05-br-lab.network"
    cp "$src/lab-mirror.netdev" "$d/05-lab-mirror.netdev"
    cp "$src/lab-mon0.network" "$d/05-lab-mon0.network"
    cp "$src/lab-mirror0.network" "$d/05-lab-mirror0.network"
    for ((i = 0; i < LAB_TAPS; i++)); do
        DRY=0 render "$src/lab-tap.netdev.template" "$d/05-lab-tap$i.netdev" "TAP_NAME=lab-tap$i" "TAP_USER=$GNS3_USER" >/dev/null
        DRY=0 render "$src/lab-tap.network.template" "$d/05-lab-tap$i.network" "TAP_NAME=lab-tap$i" >/dev/null
    done
}
labnet_current() {
    local n sys; sys="$(p /sys/class/net)"
    for n in $(lab_names); do
        printf '    %-12s %s\n' "$n" "$([ -e "$sys/$n" ] && echo present || echo absent)"
    done
    printf '    kit files in %s: %s\n' "$NETD" "$(find "$(p "$NETD")" -maxdepth 1 -name '05-*lab*' -printf '%f ' 2>/dev/null)"
}
labnet_proposed() {
    local f
    echo "    install into $NETD, then networkctl reload:"
    for f in "$LABNET_STAGE"/*; do
        echo "    == $(basename "$f")"
        sed 's/^/    | /' "$f"
    done
}
labnet_wait() {  # the reload creates the links asynchronously; give it a moment
    local sys waited=0; sys="$(p /sys/class/net)"
    while [ ! -d "$sys/br-lab/bridge" ] || [ ! -e "$sys/lab-mirror0" ]; do
        [ "$waited" -ge "$LABNET_WAIT_SECS" ] && return 0
        sleep 1; waited=$((waited + 1))
    done
}
labnet_assert() {
    local sys b m n port at flags addrs missing="" phys=""
    sys="$(p /sys/class/net)"; b="$sys/br-lab"; m="$sys/lab-mirror0"
    if [ ! -d "$b/bridge" ]; then
        fail "br-lab did not appear after networkctl reload — networkctl status br-lab; journalctl -u systemd-networkd"
        return 0
    fi
    at=$(cat "$b/bridge/ageing_time" 2>/dev/null || echo unreadable)
    if [ "$at" = "0" ]; then pass "br-lab is in hub mode (ageing_time 0): every frame reaches lab-mon0"
    else fail "br-lab ageing_time is $at, not 0 — frames between two ports would not all reach the mirror"; fi
    for n in $(lab_names); do
        case "$n" in br-lab|lab-mirror0) continue ;; esac
        [ -e "$b/brif/$n" ] || missing="$missing $n"
    done
    if [ -z "$missing" ]; then pass "lab-mon0 and $LAB_TAPS TAP(s) are ports of br-lab"
    else fail "not ports of br-lab:$missing — networkctl status <name>"; fi
    for port in "$b"/brif/*; do
        [ -e "$port" ] || continue
        n=$(basename "$port")
        [ -e "$sys/$n/device" ] && phys="$phys $n"
    done
    if [ -z "$phys" ]; then pass "br-lab has no physical port (rule 8: capture ports never join the lab fabric)"
    else fail "physical interface(s) on br-lab:$phys — remove them; the lab fabric never touches a physical port"; fi
    flags=$(cat "$m/flags" 2>/dev/null || echo 0)
    if [ "$(cat "$m/operstate" 2>/dev/null)" = "up" ] && [ $(( flags & 0x100 )) -ne 0 ]; then pass "lab-mirror0 is up and promiscuous"
    else fail "lab-mirror0 is not up and promiscuous — networkctl status lab-mirror0"; fi
    addrs=$(ip -o addr show dev lab-mirror0 2>/dev/null | grep -c . || true)
    if [ "$addrs" -eq 0 ]; then pass "lab-mirror0 carries no address (IPv4, IPv6 or link-local)"
    else fail "lab-mirror0 has $addrs address(es) — the capture end must be silent; networkctl status lab-mirror0"; fi
}
cmd_labnet() {
    banner "labnet — the mirrored lab bridge"
    need_root
    case "$LAB_TAPS" in ''|*[!0-9]*) die "GNS3_LAB_TAPS must be a whole number (got '$LAB_TAPS')" ;; esac
    [ "$LAB_TAPS" -ge 1 ] || die "GNS3_LAB_TAPS must be at least 1"
    [ "$(systemctl is-active systemd-networkd 2>/dev/null)" = "active" ] \
        || die "systemd-networkd is not active — the lab network is declared as networkd files, which would do nothing without it"
    getent passwd "$GNS3_USER" >/dev/null 2>&1 || die "service user $GNS3_USER does not exist — run config first (the TAPs are owned by it)"
    local n sys netd f i rb changed=0
    sys="$(p /sys/class/net)"; netd="$(p "$NETD")"
    for n in $(lab_names); do
        if [ -e "$sys/$n" ] && [ ! -e "$netd/$(lab_owner_file "$n")" ]; then
            die "interface $n already exists and no kit file ($NETD/$(lab_owner_file "$n")) declares it — something else owns that name; nothing was changed"
        fi
    done
    LABNET_STAGE=$(mktemp -d)
    trap 'rm -rf "$LABNET_STAGE"' EXIT
    labnet_stage "$LABNET_STAGE"
    for f in "$LABNET_STAGE"/*; do cmp -s "$f" "$netd/$(basename "$f")" || changed=1; done
    if [ "$changed" -eq 0 ]; then
        pass "lab network files already in place in $NETD"
    else
        rb="rm $NETD/05-*lab*; networkctl reload; ip link del br-lab; ip link del lab-mon0"
        for ((i = 0; i < LAB_TAPS; i++)); do rb="$rb; ip link del lab-tap$i"; done
        gate "install the mirrored lab bridge (br-lab)" labnet_current labnet_proposed "$rb"
        run mkdir -p "$netd" || die "could not create $NETD"
        for f in "$LABNET_STAGE"/*; do
            run install -m 0644 "$f" "$netd/$(basename "$f")" || die "could not install $(basename "$f")"
        done
        run networkctl reload || die "networkctl reload failed — journalctl -u systemd-networkd"
        [ "$DRY" = "1" ] || pass "$(find "$LABNET_STAGE" -type f | wc -l) networkd files installed into $NETD"
    fi
    [ "$DRY" = "1" ] && footer "labnet"
    labnet_wait
    labnet_assert
    footer "labnet"
}

```

(d) In `cmd_full`, replace
```bash
            service) run_step "$step" cmd_service ;;
```
with
```bash
            service) run_step "$step" cmd_service ;;
            labnet)  run_step "$step" cmd_labnet ;;
```

(e) In the dispatch `case "$SUB" in`, add after `    service) cmd_service ;;`:
```bash
    labnet)  cmd_labnet ;;
```

- [ ] **Step 5: Config tables**

In `config/README.md`, add to the delta table (after the `systemd/gns3.service` row):
```markdown
| `networkd/{br-lab,lab-mirror}.netdev`, `networkd/{br-lab,lab-mon0,lab-mirror0}.network`, `networkd/lab-tap.{netdev,network}.template` | new | — | Phase 11 live mirror: a hub-mode lab bridge whose veth peer Malcolm captures (installed as `/etc/systemd/network/05-*` by `r770-gns3-deploy.sh labnet`) |
```
Add to the token table (after the `__ADMIN_PW__` row):
```markdown
| `__TAP_NAME__`, `__TAP_USER__` | `r770-gns3-deploy.sh labnet` | `lab-tap0`…`lab-tap<N-1>` (`GNS3_LAB_TAPS`, default 4) and the GNS3 service user |
```
In `tests/config.bats`, in the test `every __TOKEN__ in config/ is one the kit renders`, replace the `known=` line with:
```bash
    known='ADMIN_PW PCAP_NODE_NAME OS_MEMORY LS_MEMORY ARKIME_MANAGE_PCAP ARKIME_FREE_SPACE_G MALCOLM_VER NETWORK_INDEX_PATTERN_ID TAP_NAME TAP_USER'
```

- [ ] **Step 6: Run the tests to confirm they pass**

Run: `bats tests/gns3-deploy.bats`
Expected: all `ok` (the old suite plus 11 labnet tests).

Run: `./tests/run.sh`
Expected: all `ok` — including `references.bats` (every `full` step resolves to `cmd_labnet`; every `config/networkd/*` file is named in a script) and `config.bats` (tokens known and documented). If shellcheck flags anything, fix the code; never add a disable.

- [ ] **Step 7: Commit**

```bash
git add config/networkd scripts/r770-gns3-deploy.sh tests/gns3-deploy.bats config/README.md tests/config.bats
git commit -m "Add labnet to GNS3's pipeline: a hub-mode lab bridge mirrored into lab-mirror0

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 2: Malcolm live capture — `configure --capture-ifs`

**Files:**
- Modify: `config/malcolm/malcolm-config.json.template` (four lines)
- Modify: `scripts/r770-malcolm-deploy.sh` (header, globals, a checker, `cmd_configure`, `cmd_status`, option parser)
- Modify: `tests/malcolm-deploy.bats` (new tests after the configure tests)
- Modify: `config/README.md` (token rows, Malcolm delta row), `tests/config.bats` (known tokens)

**Interfaces:**
- Consumes: `lab-mirror0` / `lab-*` naming from Task 1 (only in a refusal message); common.sh `render`, `p`, `die`, `note`.
- Produces: option `--capture-ifs "<if ...>"` (space-separated) on `r770-malcolm-deploy.sh` (used by `configure` and passed through by `full`); rendered keys `"pcapIface"`, `"captureLiveNetworkTraffic"`, `"liveArkime"`, `"liveZeek"`.

- [ ] **Step 1: Write the failing tests**

Append after the test `configure refuses when the bundled installer no longer advertises a flag the kit relies on` in `tests/malcolm-deploy.bats`:

```bash
@test "configure without --capture-ifs keeps live capture off, exactly as before" {
    make_malcolm_tree "$ROOT"
    run malcolm configure --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    r="$ROOT/opt/malcolm/malcolm-config.rendered.json"
    grep -q '"pcapIface": \[\],' "$r"
    grep -q '"captureLiveNetworkTraffic": false,' "$r"
    grep -q '"liveArkime": false,' "$r"
    grep -q '"liveZeek": false,' "$r"
    grep -q '"liveSuricata": false,' "$r"
    grep -q '"tweakIface": false,' "$r"
}

@test "configure --capture-ifs turns on live Arkime and Zeek on exactly those interfaces" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0"
    stub ip 'exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    r="$ROOT/opt/malcolm/malcolm-config.rendered.json"
    grep -q '"pcapIface": \["lab-mirror0"\],' "$r"
    grep -q '"captureLiveNetworkTraffic": true,' "$r"
    grep -q '"liveArkime": true,' "$r"
    grep -q '"liveZeek": true,' "$r"
    grep -q '"liveSuricata": false,' "$r"
    grep -q '"tweakIface": false,' "$r"
    [[ "$output" == *"live capture on: lab-mirror0"* ]]
}

@test "configure --capture-ifs renders several interfaces as one JSON list" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0" "$ROOT/sys/class/net/cap0"
    stub ip 'exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs "lab-mirror0 cap0"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '"pcapIface": \["lab-mirror0", "cap0"\],' "$ROOT/opt/malcolm/malcolm-config.rendered.json"
}

@test "configure refuses a capture interface that does not exist, pointing a lab-* name at labnet" {
    make_malcolm_tree "$ROOT"
    run malcolm configure --bundle "$BUNDLE" --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"capture interface lab-mirror0 does not exist"* ]]
    [[ "$output" == *"r770-gns3-deploy.sh labnet"* ]]
    ! grep -q -- '--configure' "$MALCOLM_STUB_LOG"
}

@test "configure refuses a capture interface that carries an address (rule 8)" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/cap0"
    stub ip 'case "$*" in *"addr show dev cap0"*) echo "3: cap0    inet 10.0.0.9/24 scope global cap0";; esac; exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs cap0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"capture interface cap0 carries an address"* ]]
    ! grep -q -- '--configure' "$MALCOLM_STUB_LOG"
}

@test "configure refuses a repeated, empty or malformed --capture-ifs" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0"
    stub ip 'exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs "lab-mirror0 lab-mirror0"
    [ "$status" -eq 1 ]
    [[ "$output" == *"names lab-mirror0 twice"* ]]
    run malcolm configure --bundle "$BUNDLE" --capture-ifs ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"names no interface"* ]]
    run malcolm configure --bundle "$BUNDLE" --capture-ifs 'bad"name'
    [ "$status" -eq 1 ]
    [[ "$output" == *"not an interface name"* ]]
    ! grep -q -- '--configure' "$MALCOLM_STUB_LOG"
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `bats tests/malcolm-deploy.bats --filter 'capture'`
Expected: the `--capture-ifs` tests `not ok` (`unknown option: --capture-ifs`); the "without --capture-ifs" test passes already (the template is unchanged so far) — that is expected, it is a regression guard.

- [ ] **Step 3: Template tokens**

In `config/malcolm/malcolm-config.json.template` replace exactly these four lines (indentation unchanged):
```json
        "captureLiveNetworkTraffic": false,
```
→
```json
        "captureLiveNetworkTraffic": __CAPTURE_LIVE__,
```
```json
        "liveArkime": false,
```
→
```json
        "liveArkime": __LIVE_ARKIME__,
```
```json
        "liveZeek": false,
```
→
```json
        "liveZeek": __LIVE_ZEEK__,
```
```json
        "pcapIface": [],
```
→
```json
        "pcapIface": __PCAP_IFACE__,
```

- [ ] **Step 4: Implement in `scripts/r770-malcolm-deploy.sh`**

(a) Header: after the `--index-pattern` lines (the line ending `it does not guess (run \`inventory\` to see them)`), insert:
```bash
#   --capture-ifs "<if ...>"   live capture (Arkime + Zeek) on these interfaces,
#                              for configure (and full). Each must exist and
#                              carry no address: discovered names, never
#                              guessed -- on staging, the lab mirror
#                              lab-mirror0 (r770-gns3-deploy.sh labnet first).
#                              Without it, live capture stays off.
```

(b) Globals: replace
```bash
BUNDLE=""; FREE_G=""; IDX=""; OSD_NETRC=""
```
with
```bash
BUNDLE=""; FREE_G=""; IDX=""; OSD_NETRC=""
CAPTURE_IFS=""; CAPTURE_SET=0
```

(c) Insert directly above `cmd_configure() {`:
```bash
# capture_json — check --capture-ifs and print it as a JSON list ("[]" when
# not given). Each name must look like an interface, exist, carry no address
# (rule 8), and appear once. Interfaces are given, never guessed.
capture_json() {
    local i seen=" " json="" n=0
    [ "$CAPTURE_SET" = "1" ] || { printf '[]'; return 0; }
    for i in $CAPTURE_IFS; do
        [[ "$i" =~ ^[A-Za-z0-9._-]{1,15}$ ]] || die "--capture-ifs: '$i' is not an interface name"
        case "$seen" in *" $i "*) die "--capture-ifs names $i twice" ;; esac
        seen="$seen$i "
        if [ ! -e "$(p /sys/class/net)/$i" ]; then
            case "$i" in
                lab-*) die "capture interface $i does not exist — create the lab network first: r770-gns3-deploy.sh labnet" ;;
                *)     die "capture interface $i does not exist — capture interfaces come from discovery (ip -br link), never guessed" ;;
            esac
        fi
        [ -z "$(ip -o addr show dev "$i" 2>/dev/null)" ] || die "capture interface $i carries an address — capture interfaces never get one (rule 8)"
        json="$json${json:+, }\"$i\""
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || die "--capture-ifs was given but names no interface"
    printf '[%s]' "$json"
}

```

(d) In `cmd_configure`, replace
```bash
    local b zip ver os ls rendered exported manage free
```
with
```bash
    local b zip ver os ls rendered exported manage free ifaces live
```
Replace
```bash
    if [ -n "$FREE_G" ]; then manage=true; free="$FREE_G"; else manage=false; free='<MALCOLM_CONFIG_NONE>'; fi
```
with
```bash
    if [ -n "$FREE_G" ]; then manage=true; free="$FREE_G"; else manage=false; free='<MALCOLM_CONFIG_NONE>'; fi
    ifaces=$(capture_json) || exit 1
    if [ "$ifaces" = "[]" ]; then live=false; else live=true; fi
```
After the line `    note "PCAP -> /data/pcap/raw, indexes -> /data/index, Suricata off, no feed pulls; Arkime PCAP management: $manage"` insert:
```bash
    if [ "$live" = "true" ]; then note "live capture on: $CAPTURE_IFS (Arkime + Zeek; Suricata stays off)"; else note "live capture off (no --capture-ifs)"; fi
```
Replace the render call's last line
```bash
        "ARKIME_MANAGE_PCAP=$manage" "ARKIME_FREE_SPACE_G=$free" "MALCOLM_VER=$ver"
```
with
```bash
        "ARKIME_MANAGE_PCAP=$manage" "ARKIME_FREE_SPACE_G=$free" "MALCOLM_VER=$ver" \
        "PCAP_IFACE=$ifaces" "CAPTURE_LIVE=$live" "LIVE_ARKIME=$live" "LIVE_ZEEK=$live"
```

(e) In `cmd_status`, after the line printing `"auth material"`, insert:
```bash
    local rc live="off"
    rc="$(home)/malcolm-config.rendered.json"
    if [ -f "$rc" ]; then
        if grep -q '"captureLiveNetworkTraffic": true' "$rc"; then
            live="on $(sed -n 's/.*"pcapIface": \(\[.*\]\),*/\1/p' "$rc")"
        fi
        printf '%-28s %s\n' "live capture" "$live"
    fi
```

(f) Option parser: after `        --index-pattern)       IDX="${2:-}"; shift ;;` add:
```bash
        --capture-ifs)         CAPTURE_IFS="${2:-}"; CAPTURE_SET=1; shift ;;
```

- [ ] **Step 5: Config tables**

In `config/README.md` token table, add after the `__MALCOLM_VER__` row:
```markdown
| `__PCAP_IFACE__`, `__CAPTURE_LIVE__`, `__LIVE_ARKIME__`, `__LIVE_ZEEK__` | `r770-malcolm-deploy.sh configure` | `--capture-ifs "<if ...>"`: the JSON list of those interfaces and `true`; without it `[]` and `false` (live capture off) |
```
In the Malcolm template's delta row (`malcolm/malcolm-config.json.template`), extend the tokens list: replace `` `__MALCOLM_VER__` | R770 storage layout`` with `` `__MALCOLM_VER__ __PCAP_IFACE__ __CAPTURE_LIVE__ __LIVE_ARKIME__ __LIVE_ZEEK__` | R770 storage layout`` and append `; live capture opt-in via `--capture-ifs`` inside that row's "Why" cell, just before its closing `|`.

In `tests/config.bats` replace the `known=` line with:
```bash
    known='ADMIN_PW PCAP_NODE_NAME OS_MEMORY LS_MEMORY ARKIME_MANAGE_PCAP ARKIME_FREE_SPACE_G MALCOLM_VER NETWORK_INDEX_PATTERN_ID TAP_NAME TAP_USER PCAP_IFACE CAPTURE_LIVE LIVE_ARKIME LIVE_ZEEK'
```

- [ ] **Step 6: Run the tests to confirm they pass**

Run: `bats tests/malcolm-deploy.bats`
Expected: all `ok` (existing plus 6 new).

Run: `./tests/run.sh`
Expected: all `ok`.

- [ ] **Step 7: Commit**

```bash
git add config/malcolm/malcolm-config.json.template scripts/r770-malcolm-deploy.sh tests/malcolm-deploy.bats config/README.md tests/config.bats
git commit -m "Malcolm configure --capture-ifs: live Arkime and Zeek on given interfaces

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 3: Validate — prove the lab bridge and the mirror wiring

**Files:**
- Modify: `scripts/r770-validate.sh` (`area_network`)
- Modify: `tests/validate.bats` (new tests at the end)

**Interfaces:**
- Consumes: `--lab-bridge BR` and `--capture-ifs "..."` (both already parsed); `row`, `diag`, `p`.
- Produces: rows `lab-bridge <BR> hub`, `lab-bridge <BR> physical ports`, `lab-bridge <BR> mirror`, `lab-mirror <if> address`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/validate.bats`:

```bash
# fake_lab_sys [ageing] [physical-port] — br-lab with lab-mon0 as a port whose
# veth peer is lab-mirror0 (ifindex 21 <-> iflink 21), under $ROOT
fake_lab_sys() {
    local s="$ROOT/sys/class/net"
    mkdir -p "$s/br-lab/bridge" "$s/br-lab/brif" "$s/lab-mon0" "$s/lab-mirror0" "$s/lab-tap0"
    echo "${1:-0}" > "$s/br-lab/bridge/ageing_time"
    touch "$s/br-lab/brif/lab-mon0" "$s/br-lab/brif/lab-tap0"
    echo 21 > "$s/lab-mon0/ifindex"; echo 22 > "$s/lab-mon0/iflink"
    echo 22 > "$s/lab-mirror0/ifindex"; echo 21 > "$s/lab-mirror0/iflink"
    echo 30 > "$s/lab-tap0/ifindex"; echo 30 > "$s/lab-tap0/iflink"
    if [ -n "${2:-}" ]; then mkdir -p "$s/$2/device"; touch "$s/br-lab/brif/$2"; echo 40 > "$s/$2/ifindex"; echo 40 > "$s/$2/iflink"; fi
}

@test "the lab bridge is never guessed: without --lab-bridge its rows SKIP" {
    run validate --area network
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  network/lab-bridge: no --lab-bridge given"* ]]
}

@test "a correct lab bridge PASSes hub mode, no physical port, and the mirror wiring" {
    fake_lab_sys
    stub ip 'case "$*" in *"link show lab-mirror0"*) echo "22: lab-mirror0@lab-mon0: <BROADCAST,NOARP,PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  network/lab-bridge br-lab hub"* ]]
    [[ "$output" == *"PASS  network/lab-bridge br-lab physical ports"* ]]
    [[ "$output" == *"PASS  network/lab-bridge br-lab mirror"* ]]
    [[ "$output" == *"PASS  network/lab-mirror lab-mirror0 address"* ]]
}

@test "a lab bridge that learns MACs, or holds a physical port, is a FAIL with a diagnosis" {
    fake_lab_sys 30000 eno1
    stub ip 'case "$*" in *"link show lab-mirror0"*) echo "22: lab-mirror0@lab-mon0: <PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab hub: ageing_time 30000"* ]]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab physical ports: eno1"* ]]
    run report
    [[ "$output" == *"never touches a physical port"* ]]
}

@test "a mirror capture end with a link-local address is a FAIL; no capture interface fed by the bridge is a FAIL" {
    fake_lab_sys
    stub ip 'case "$*" in *"addr show lab-mirror0"*) echo "22: lab-mirror0    inet6 fe80::1/64 scope link";; *"link show lab-mirror0"*) echo "22: lab-mirror0: <PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-mirror lab-mirror0 address: 1 address(es)"* ]]
    mkdir -p "$ROOT/sys/class/net/cap9"; echo 50 > "$ROOT/sys/class/net/cap9/iflink"
    run validate --area network --lab-bridge br-lab --capture-ifs cap9
    echo "$output"
    [[ "$output" == *"FAIL  network/lab-bridge br-lab mirror: no --capture-ifs interface is fed by a port of br-lab"* ]]
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `bats tests/validate.bats --filter 'lab'`
Expected: `not ok` for all four (no `lab-bridge` rows exist yet).

- [ ] **Step 3: Implement in `scripts/r770-validate.sh`**

In `area_network`, the capture branch currently ends the function early with `return` when `--capture-ifs` is empty. Restructure the end of `area_network` as follows. Replace this line:
```bash
    if [ -z "$CAPTURE_IFS" ]; then row "capture" "no address, promisc, offloads off" "no --capture-ifs given" SKIP "interfaces are never guessed"; return; fi
```
with:
```bash
    area_network_lab
    if [ -z "$CAPTURE_IFS" ]; then row "capture" "no address, promisc, offloads off" "no --capture-ifs given" SKIP "interfaces are never guessed"; return; fi
```
Then insert this function directly above `area_network() {`:

```bash
# The lab bridge (Phase 11 live mirror): hub mode, no physical port, and a
# veth port whose peer is one of --capture-ifs. A veth's iflink is its peer's
# ifindex; a physical NIC has a device link in sysfs, a virtual one does not.
area_network_lab() {
    if [ -z "$LAB_BRIDGE" ]; then row "lab-bridge" "hub mode, no physical port, mirrored" "no --lab-bridge given" SKIP "bridges are never guessed"; return; fi
    local sys b at port n phys="" fed="" i pidx
    sys="$(p /sys/class/net)"; b="$sys/$LAB_BRIDGE"
    if [ ! -d "$b/bridge" ]; then
        row "lab-bridge $LAB_BRIDGE" "a bridge" "absent or not a bridge" FAIL "/sys/class/net/$LAB_BRIDGE/bridge"
        diag "lab-bridge $LAB_BRIDGE" "the lab bridge does not exist — r770-gns3-deploy.sh labnet creates it"
        return
    fi
    at=$(cat "$b/bridge/ageing_time" 2>/dev/null || echo unreadable)
    if [ "$at" = "0" ]; then row "lab-bridge $LAB_BRIDGE hub" "ageing_time 0" "ageing_time 0" PASS "cat /sys/class/net/$LAB_BRIDGE/bridge/ageing_time"
    else row "lab-bridge $LAB_BRIDGE hub" "ageing_time 0" "ageing_time $at" FAIL "cat /sys/class/net/$LAB_BRIDGE/bridge/ageing_time"; diag "lab-bridge $LAB_BRIDGE hub" "a learning bridge forwards port-to-port frames past the mirror — rerun r770-gns3-deploy.sh labnet"; fi
    for port in "$b"/brif/*; do
        [ -e "$port" ] || continue
        n=$(basename "$port")
        [ -e "$sys/$n/device" ] && phys="$phys $n"
    done
    if [ -z "$phys" ]; then row "lab-bridge $LAB_BRIDGE physical ports" "none" "none" PASS "ls /sys/class/net/$LAB_BRIDGE/brif"
    else row "lab-bridge $LAB_BRIDGE physical ports" "none" "${phys# }" FAIL "ls /sys/class/net/$LAB_BRIDGE/brif"; diag "lab-bridge $LAB_BRIDGE physical ports" "rule 8: the lab fabric never touches a physical port — remove it from the bridge"; fi
    for i in $CAPTURE_IFS; do
        pidx=$(cat "$sys/$i/iflink" 2>/dev/null || true)
        [ -n "$pidx" ] || continue
        for port in "$b"/brif/*; do
            [ -e "$port" ] || continue
            n=$(basename "$port")
            [ "$(cat "$sys/$n/ifindex" 2>/dev/null)" = "$pidx" ] && [ "$n" != "$i" ] && fed="$fed $i"
        done
    done
    if [ -n "$fed" ]; then row "lab-bridge $LAB_BRIDGE mirror" "a capture interface fed by a bridge port" "${fed# }" PASS "cat /sys/class/net/<if>/iflink vs brif/*/ifindex"
    else row "lab-bridge $LAB_BRIDGE mirror" "a capture interface fed by a bridge port" "no --capture-ifs interface is fed by a port of $LAB_BRIDGE" FAIL "cat /sys/class/net/<if>/iflink vs brif/*/ifindex"; diag "lab-bridge $LAB_BRIDGE mirror" "Malcolm would see nothing from the lab — pass lab-mirror0 in --capture-ifs, and rerun labnet if the veth is missing"; fi
    local cnt
    for i in $fed; do
        cnt=$(ip -o addr show "$i" 2>/dev/null | grep -E ' inet6? ' | grep -c . || true)
        if [ "$cnt" -eq 0 ]; then row "lab-mirror $i address" "none, link-local included" "none" PASS "ip -o addr show $i"
        else row "lab-mirror $i address" "none, link-local included" "$cnt address(es)" FAIL "ip -o addr show $i"; diag "lab-mirror $i address" "the mirror's capture end must be silent — its networkd file sets LinkLocalAddressing=no; networkctl status $i"; fi
    done
}

```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `bats tests/validate.bats`
Expected: all `ok` (existing plus 4 new). Note: the existing capture rows still run for `lab-mirror0` (promisc etc.); the fake ip stubs above satisfy them.

Run: `./tests/run.sh`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-validate.sh tests/validate.bats
git commit -m "Validate the lab bridge: hub mode, no physical port, mirror wiring

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 4: Docs

**Files:** `docs/deployment-runbook.md`, `docs/rollback.md`, `docs/CODEMAPS/stages.md`, `docs/validation.md`, `docs/kit-sync.md`, `CLAUDE.md`, `README.md`

**Interfaces:** documentation only; `tests/references.bats` requires every backticked kit path named to exist.

- [ ] **Step 1: `docs/deployment-runbook.md`**

(a) In the phase table, replace the GNS3 row's step list `` `load` `venv` `secrets` `config` `service` `` with `` `load` `venv` `secrets` `config` `service` `labnet` ``.

(b) Insert this section directly above `### GNS3 — validate note`:

````markdown
### Step G10 — labnet  *(GATED)*

```bash
sudo ./scripts/r770-gns3-deploy.sh labnet     # br-lab (hub mode), lab-tap0..3, lab-mon0 <-> lab-mirror0
```

The lab bridge every scenario shares, mirrored into Malcolm by construction:
`br-lab` runs with `ageing_time 0`, so it floods every frame to every port —
including `lab-mon0`, whose veth peer `lab-mirror0` is what Malcolm captures.
A scenario puts a link on the bridge by binding a GNS3 Cloud node to a
`lab-tapN` (owned by the `gns3` user). The step installs
`/etc/systemd/network/05-*lab*` files and runs `networkctl reload`; it refuses
while systemd-networkd is inactive, before `config` has created the service
user, and when one of its names already belongs to something else. After the
reload it proves hub mode, the ports, that no physical interface joined the
bridge (rule 8), and that `lab-mirror0` is up, promiscuous and address-less.
`GNS3_LAB_TAPS` changes the TAP count (default 4). Nothing on `br-lab` is
bridged to a physical port or NATed: lab traffic cannot leave the box.

Then turn Malcolm's live capture on (Malcolm procedure, `configure`):
`r770-malcolm-deploy.sh configure --bundle $B --capture-ifs lab-mirror0`.

Evidence that the feed is live, once a scenario runs:
`tcpdump -c 5 -i lab-mirror0` shows frames; Arkime shows sessions from the
scenario's address range within about a minute, with matching Zeek logs;
`r770-validate.sh --area network --lab-bridge br-lab --capture-ifs lab-mirror0`
and `--area capture` report the wiring and `capture_loss`.

````

(c) In the Malcolm procedure's code block (Steps M9–M14), replace the `configure` line
```
sudo ./scripts/r770-malcolm-deploy.sh configure --bundle $B    # renders the kit's config template, replays it through install.py
```
with
```
sudo ./scripts/r770-malcolm-deploy.sh configure --bundle $B    # renders the kit's config template, replays it through install.py
#   add --capture-ifs lab-mirror0 for live capture of the lab (run GNS3's labnet first)
```
and in the paragraph after that block, after the sentence ending `the default is off.` (it is the sentence about `--arkime-free-space-g N`, wrapped across two lines — "…Phase 10 sets that from measured feed rates, so / the default is off."), insert: `` `--capture-ifs "<if ...>"` turns on live Arkime and Zeek capture on those interfaces (each must exist and carry no address); without it live capture stays off. ``

- [ ] **Step 2: `docs/rollback.md`**

Add two rows directly after the `gns3` row:
```markdown
| gns3 labnet | `/etc/systemd/network/05-*lab*`; interfaces `br-lab`, `lab-tap0..N-1`, `lab-mon0`/`lab-mirror0` | — | `rm /etc/systemd/network/05-*lab*; networkctl reload; ip link del br-lab; ip link del lab-mon0; ip link del lab-tap<i>` (each) | a running scenario loses its link on the bridge |
| malcolm live capture | `pcapIface` / `captureLiveNetworkTraffic` / `liveArkime` / `liveZeek` in the rendered config | the exported config `/opt/malcolm/malcolm-config.exported.json` | rerun `r770-malcolm-deploy.sh configure` without `--capture-ifs`, then restart the stack | — |
```

- [ ] **Step 3: `docs/CODEMAPS/stages.md`**

(a) GNS3 row: replace `` `config` `service` 🔒 `` with `` `config` `service` 🔒 `labnet` 🔒 ``.
(b) The gates paragraph: replace `` `gns3 service` (the unit) `` with `` `gns3 service` (the unit) · `gns3 labnet` (the lab bridge) ``.
(c) Config table: add a row
```markdown
| `config/networkd/*` | `gns3-deploy labnet` |
```

- [ ] **Step 4: `docs/validation.md`**

In the `network` row, append to the "checks" cell: ` · with --lab-bridge: bridge in hub mode (ageing_time 0), no physical port, a --capture-ifs interface fed by a bridge port, and that mirror end address-less (link-local included)`, and to the "needs" cell: ` ; --lab-bridge BR (else SKIP: bridges are never guessed)`.

- [ ] **Step 5: `CLAUDE.md`, `README.md`, `docs/kit-sync.md`**

(a) `CLAUDE.md` rule 2: replace `the GNS3 unit and a volume purge` with `the GNS3 unit, the lab network and a volume purge`.

(b) `README.md` GNS3 row: replace `systemd unit on 127.0.0.1 |` with `systemd unit on 127.0.0.1, then `labnet`: the hub-mode lab bridge whose mirror (`lab-mirror0`) Malcolm captures with `--capture-ifs` |`.

(c) `docs/kit-sync.md`, section "Follow-ups recorded here, not silently added": append two bullets:
```markdown
- **Lab mirror mechanism (to carry to the build repo).** The kit mirrors lab
  traffic with a hub-mode bridge (`br-lab`, `ageing_time 0`) and a veth
  (`lab-mon0` ⇄ `lab-mirror0`) instead of the buildout plan §7's `tc mirred`
  per port: no per-port rules to follow GNS3's ports as they come and go.
  Record the decision in the build repo's buildout plan §7.
- **Wiki mirror procedure (to carry to the build repo).** `docs/wiki/gns3.md`'s
  "mirror … TBD" can now read: bind a GNS3 Cloud node to a `lab-tapN`;
  everything on `br-lab` reaches Malcolm. `docs/wiki/` is build-repo content
  and is edited there.
```

- [ ] **Step 6: Verify and run the gate**

Run: `grep -rn 'labnet' README.md CLAUDE.md docs/*.md docs/CODEMAPS/stages.md | wc -l`
Expected: at least 6.

Run: `./tests/run.sh`
Expected: all `ok`.

- [ ] **Step 7: Commit**

```bash
git add docs/deployment-runbook.md docs/rollback.md docs/CODEMAPS/stages.md docs/validation.md docs/kit-sync.md CLAUDE.md README.md
git commit -m "Document the lab mirror feed: labnet, --capture-ifs, rollback and validation

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```
