# Finish Line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The kit installs the real R770 to INSTALLED once, with evidence, and the project closes.

**Architecture:** Five small kit changes (four open findings and one new gated step for physical capture ports), a wiki pass, then one bundle that is proven on staging VM 9770 from a bare OS through a reboot and carried unchanged to the R770. Tasks 1–6 are code and docs, test-first. Tasks 7–9 are operator tasks that produce transcripts and records, not code.

**Tech Stack:** bash, bats, shellcheck (the kit's own); systemd units and systemd-networkd files; MkDocs for the wiki; Proxmox `qm` over SSH through `harness/r770-staging-vm.sh`.

## Scope decisions this plan carries out (settled 2026-11-10)

| Topic | Decision |
|---|---|
| Finish line | `r770-install.sh run` ends INSTALLED on the real R770, with its transcript |
| In scope | core kit, installer, e2e, dashboards and `check`, physical capture ports (prepared and listening; traffic seen is not required) |
| Frozen | IPsec/WAN increment 1 and `harness/`: stay in the tree and in e2e's ten scenarios; no further work; findings I4–I7 stay open |
| Not built | IPsec spec phases IP5–IP9 |
| A8 | stop shipping the five definitions that have no image |
| A10 | Malcolm returns after a reboot by itself |
| A11 | fix |
| A2 | `plan` prints SKIP rows naming the earlier step |
| Final staging pass | one cut; bare-OS start; reboot; re-entry ends INSTALLED |
| Re-cut rule | every in-scope finding is fixed and re-cut; a finding against frozen code is recorded and never causes a re-cut |
| Frozen scenario fails on the R770 | no code change: the record carries a written disposition beside the NOT INSTALLED verdict |
| Wiki | accuracy pass plus one getting-started page |
| After | `docs/backlog.md`; project closed |

**One deviation from the grilling answer, for the operator to confirm before Task 4:** A10 was answered "a gated kit step installs a systemd unit". The Malcolm config template already carries the installer's own setting for this, `"malcolmRestartPolicy": "no"` (`config/malcolm/malcolm-config.json.template`). Task 4 changes that value to `unless-stopped` instead of adding a unit: same outcome, one line, Malcolm's own mechanism, nothing new to gate. If the VM reboot in Task 7 shows it does not bring the stack back healthy, fall back to the unit.

## Global Constraints

- Tasks 1–6 are on branch `finish-line`, cut from `main` after Task 0. Never commit to `main`. Never push or open a PR without the operator's yes.
- `./tests/run.sh` green before every commit. shellcheck with **no exclusions**. Exit contract `0 / 2 / 1`. Check lines `PASS  ` / `WARN  ` / `FAIL  ` / `SKIP  `.
- Use `scripts/lib/common.sh` helpers (`gate`, `render`, `run`, `p`, `require_pkg`, `footer`); do not reimplement them.
- Discover, never guess: interface names, VM ids, snapshot names and devices are arguments.
- No three-part version number in any tracked file (`tests/no-pins.bats` scans this plan too). Dotted-quad addresses are fine.
- No secret in git, in chat, on a command line or in a record. Evidence stays out of git.
- A new script gets: a bats suite, a row in `README.md`, a row in `tests/README.md`, an `allow` entry in `.claude/settings.json`.
- A new or changed file under `config/` gets its row in `config/README.md`; a new `__TOKEN__` goes in that file's token table and in the `known=` list of `tests/config.bats`.
- On the VM and on the R770, only kit scripts change the host. A refusal is a finding: one hypothesis, one change, rerun `--from <step>`.
- Commit messages end with `Co-Authored-By: Claude <noreply@anthropic.com>`.

## Running the suite from this PC

WSL Ubuntu has `bats` and `shellcheck`. **`KT <cmd>`** below means:

```bash
wsl -e bash -lc 'set -e; rm -rf ~/sim-lab-wt; git clone -q "/mnt/c/coding stuff/sim-lab-basic" ~/sim-lab-wt; cd "/mnt/c/coding stuff/sim-lab-basic"; git ls-files -co --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C ~/sim-lab-wt; cd ~/sim-lab-wt; <cmd>'
```

`KT ./tests/run.sh` is the whole gate; `KT bats tests/install.bats` is one suite.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `staging/r770-offline-fetch.sh` (modify) | `GNS3A_DEFS` lists only definitions whose image the bundle can carry | 1 |
| `config/systemd/r770-capture-offloads@.service` (create) | boot-time `ethtool -K` for one capture interface | 2 |
| `scripts/r770-gns3-deploy.sh` (modify) | `labnet` installs that unit and enables it for `lab_mirror0` | 2 |
| `config/networkd/capture-port.network.template` (create) | a silent, promiscuous physical capture port | 3 |
| `scripts/r770-capture-ports.sh` (create) | `apply` (gated) and `status` for physical capture ports | 3 |
| `tests/capture-ports.bats` (create) | that script's contract | 3 |
| `scripts/r770-malcolm-deploy.sh` (modify) | new `capture` step between `unpack` and `configure` | 3 |
| `config/malcolm/malcolm-config.json.template` (modify) | restart policy | 4 |
| `scripts/r770-install.sh` (modify) | `plan` SKIPs what an earlier step of the same run provides | 5 |
| `docs/wiki/*.md`, `config/docs/mkdocs.yml` (modify), `docs/wiki/getting-started.md` (create) | the analyst wiki | 6 |
| `docs/rehearsals/<date>-final-pass.md`, `docs/rehearsals/<date>-r770-install.md` (create) | the records | 7, 8 |
| `docs/backlog.md` (create) | what was deferred | 9 |

---

### Task 0: Land `finish-rehearsals`, start `finish-line`

**Files:** none changed.

- [ ] **Step 1: Gate.** Run `KT ./tests/run.sh`. Expected: exit 0.
- [ ] **Step 2: Ask the operator for a yes to push and open the PR.** Then:

```bash
git push -u origin finish-rehearsals
gh pr create --base main --head finish-rehearsals --title "Rehearsals: VM harness, installer acceptance, IPsec & WAN on VM 9770" --body "Records: docs/rehearsals/2026-11-10-installer-acceptance.md, docs/rehearsals/2026-11-10-ipsec-wan.md. Open findings A2, A8, A10, A11 are fixed on the next branch (finish-line); I4-I7 stay open against frozen work.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 3: After the operator merges it:**

```bash
git checkout main && git pull --ff-only && git checkout -b finish-line
```

---

### Task 1: A8 — ship no definition without an image

**Files:**
- Modify: `staging/r770-offline-fetch.sh:89-93` (the `GNS3A_DEFS` block), the appliances `README.txt` heredoc near line 869, and the note near line 756
- Modify: `staging/r770-build-bundle.sh` near line 182 (the manual-items text that says the definitions are already staged)
- Test: `tests/staging.bats`

**Interfaces:**
- Produces: a bundle whose `gns3/definitions/` holds seven files (`vyos mikrotik-chr opnsense frr alpine-linux-virt tinycore-linux openwrt`). `scripts/r770-import-bundle.sh` is not changed: its "definition without image" WARN stays as the guard.

- [ ] **Step 1: Write the failing test** — append to `tests/staging.bats`:

```bash
@test "A8: the fetch stages no definition whose image the bundle cannot carry" {
    defs=$(sed -n '/^GNS3A_DEFS=(/,/^)/p' staging/r770-offline-fetch.sh)
    [ -n "$defs" ]
    for d in cisco-iosv cisco-iosvl2 cisco-asav fortigate pan-vm-fw; do
        if grep -qw -- "$d" <<< "$defs"; then echo "still listed: $d"; false; fi
    done
    for d in vyos mikrotik-chr opnsense frr alpine-linux-virt tinycore-linux openwrt; do
        grep -qw -- "$d" <<< "$defs" || { echo "lost: $d"; false; }
    done
}
```

- [ ] **Step 2: Run it.** `KT bats tests/staging.bats --filter A8` — Expected: FAIL, "still listed: cisco-iosv".
- [ ] **Step 3: Change the fetch.** In `staging/r770-offline-fetch.sh`, delete the array line `    cisco-iosv cisco-iosvl2 cisco-asav fortigate pan-vm-fw` and replace the comment above `GNS3A_DEFS=(` with:

```bash
# .gns3a appliance definitions to grab from the GNS3 registry. Only names
# whose image this bundle carries or fetches: a definition without its image
# shows in the GUI, fails at boot, and is warned about by every `files` step,
# so the install can never end clean (acceptance 2026-11-10, finding A8).
# A licensed appliance is added here in the same change that stages its image.
```

  In the line near 756, drop the words `(definitions are free even for licensed appliances)`. In the appliances `README.txt` heredoc (near 869), change `definitions for these are already in ../definitions/` to `no definition is shipped for these: add the name to GNS3A_DEFS when its image is staged`. In `staging/r770-build-bundle.sh` near line 182, read the sentence about `.gns3a` definitions being already staged and change it to say the same thing.

- [ ] **Step 4: Run the suite.** `KT bats tests/staging.bats` — Expected: all pass (the Alpine test at line 145 greps `vyos .* alpine-linux-virt ` on one line; that line is untouched).
- [ ] **Step 5: Gate and commit.**

```bash
KT ./tests/run.sh
git add staging/ tests/staging.bats
git commit -m "fetch: ship no GNS3 definition without its image (A8)"
```

---

### Task 2: A11 — capture offloads stay off after a reboot

The `.link` file already says `TCPSegmentationOffload=no`, yet `ethtool -k lab_mirror0` reported `tcp-segmentation-offload: on` after a reboot. Hypothesis: that summary line is on while any TSO sub-feature is on, and `.link` has keys for only some of them; `ethtool -K <if> tso off` clears all of them. The change: run that exact command at boot, when the device appears.

**Files:**
- Create: `config/systemd/r770-capture-offloads@.service`
- Modify: `scripts/r770-gns3-deploy.sh` (`labnet_proposed`, `cmd_labnet`)
- Modify: `config/README.md` (one row)
- Test: `tests/gns3-deploy.bats`

**Interfaces:**
- Produces: the unit template at `/etc/systemd/system/r770-capture-offloads@.service`; instance name is the interface name (`r770-capture-offloads@lab_mirror0.service`). Task 3 enables further instances and installs the same file with the same `install` line.

- [ ] **Step 1: Measure first (operator's yes needed: `rollback` is gated).** On the VM at snapshot `installed-2026-11-10`, after a reboot, before anything else is run:

```bash
./harness/r770-staging-vm.sh rollback --pve proxmox --vmid 9770 --snapshot installed-2026-11-10
./harness/r770-staging-vm.sh start --pve proxmox --vmid 9770
./harness/r770-staging-vm.sh wait-ssh 300 --mgmt-host r770-staging
ssh r770-staging sudo ethtool -k lab_mirror0 > ~/r770-rehearsals/a11-ethtool-k.txt
grep -E 'segmentation|receive-offload' ~/r770-rehearsals/a11-ethtool-k.txt
```

  Expected if the hypothesis holds: `tx-tcp-segmentation: off` and at least one of `tx-tcp-ecn-segmentation`, `tx-tcp-mangleid-segmentation`, `tx-tcp6-segmentation` on. Write what was seen into the commit message of step 6. If instead `tx-tcp-segmentation` itself is on, the `.link` file is not being applied at all: stop and report that before changing anything.

- [ ] **Step 2: Write the failing tests** — append to `tests/gns3-deploy.bats`, after the existing F3 offload test:

```bash
@test "A11: labnet installs the boot-time offload unit and enables it for lab_mirror0" {
    stub_labnet_host; labnet_user
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 0 ]
    u="$ROOT/etc/systemd/system/r770-capture-offloads@.service"
    [ -f "$u" ]
    grep -qx 'ExecStart=/usr/sbin/ethtool -K %i tso off gso off gro off lro off' "$u"
    grep -qx 'BindsTo=sys-subsystem-net-devices-%i.device' "$u"
    grep -qx 'systemctl enable r770-capture-offloads@lab_mirror0.service' "$STUB_LOG"
    [[ "$output" == *"r770-capture-offloads@lab_mirror0.service"* ]]   # the gate showed it
}

@test "A11: a box whose labnet ran before the offload unit existed gets it on the next labnet" {
    stub_labnet_host; labnet_user
    gns3 labnet >/dev/null
    rm "$ROOT/etc/systemd/system/r770-capture-offloads@.service"; : > "$STUB_LOG"
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'systemctl enable r770-capture-offloads@lab_mirror0.service' "$STUB_LOG"
}
```

- [ ] **Step 3: Run them.** `KT bats tests/gns3-deploy.bats --filter A11` — Expected: both FAIL (no unit file).
- [ ] **Step 4: Create `config/systemd/r770-capture-offloads@.service`:**

```ini
# Offloads off on one capture interface, every time the device appears.
# The .link file covers what systemd.link can name; `ethtool -K <if> tso off`
# also clears the TSO sub-features it cannot (acceptance 2026-11-10, A11).
# Instance = interface name. Installed by r770-gns3-deploy.sh labnet (for
# lab_mirror0) and r770-capture-ports.sh apply (for physical ports).
[Unit]
Description=Capture offloads off on %i (R770 lab kit)
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -K %i tso off gso off gro off lro off

[Install]
WantedBy=sys-subsystem-net-devices-%i.device
```

- [ ] **Step 5: Change `scripts/r770-gns3-deploy.sh`.**

  Beside `NETD="/etc/systemd/network"` add:

```bash
OFFL_UNIT="r770-capture-offloads@.service"
```

  In `labnet_proposed`, after the loop that prints the staged files, add:

```bash
    echo "    install /etc/systemd/system/$OFFL_UNIT, daemon-reload, enable r770-capture-offloads@lab_mirror0.service"
    sed 's/^/    | /' "$KIT_CONFIG_DIR/systemd/$OFFL_UNIT"
```

  In `cmd_labnet`, after the line `if legacy_veth; then changed=1; fi`, add:

```bash
    cmp -s "$KIT_CONFIG_DIR/systemd/$OFFL_UNIT" "$(p /etc/systemd/system)/$OFFL_UNIT" || changed=1
```

  In the gated branch, extend the rollback text: after the `rb=` line add

```bash
        rb="$rb; systemctl disable r770-capture-offloads@lab_mirror0.service; rm /etc/systemd/system/$OFFL_UNIT; systemctl daemon-reload"
```

  and after the loop that installs the staged networkd files (before the stale-file removal) add:

```bash
        run mkdir -p "$(p /etc/systemd/system)" || die "could not create /etc/systemd/system"
        run install -m 0644 "$KIT_CONFIG_DIR/systemd/$OFFL_UNIT" "$(p /etc/systemd/system)/$OFFL_UNIT" || die "could not install $OFFL_UNIT"
        run systemctl daemon-reload || die "daemon-reload failed"
        run systemctl enable "r770-capture-offloads@lab_mirror0.service" || die "could not enable the offload unit for lab_mirror0"
```

  Update the script's header comment where it describes `labnet` to mention the unit. Add the row to `config/README.md`: `systemd/r770-capture-offloads@.service` · new in the kit · offloads return after a reboot without it (A11).

- [ ] **Step 6: Run, gate, commit.**

```bash
KT bats tests/gns3-deploy.bats
KT ./tests/run.sh
git add config/systemd config/README.md scripts/r770-gns3-deploy.sh tests/gns3-deploy.bats
git commit -m "labnet: re-apply capture offloads at boot with a device-bound unit (A11)"
```

  The proof that it works is the reboot in Task 7; until then the finding stays "fixed, not yet verified".

---

### Task 3: Physical capture ports — a gated step

**Files:**
- Create: `config/networkd/capture-port.network.template`
- Create: `scripts/r770-capture-ports.sh` (executable)
- Create: `tests/capture-ports.bats`
- Modify: `scripts/r770-malcolm-deploy.sh` (`STEPS`, a `cmd_capture`, `cmd_full`, dispatch, header)
- Modify: `tests/malcolm-deploy.bats` (the step-order test near line 1025), `tests/config.bats:25` (`known=` gains `CAPTURE_IF`)
- Modify: `README.md`, `tests/README.md`, `config/README.md`, `.claude/settings.json`, `docs/deployment-runbook.md` (Malcolm steps M9–M14 gain `capture`; the "capture ports prepared" cell in "Where this runbook stops today" names this step)

**Interfaces:**
- Consumes: `config/systemd/r770-capture-offloads@.service` and `OFFL_UNIT` naming from Task 2.
- Produces: `r770-capture-ports.sh apply --capture-ifs "<if> ..."` (gated; exit 0/2/1) and `status --capture-ifs "<if> ..."` (read-only). Malcolm's `full` gains the step `capture`; `r770-malcolm-deploy.sh capture --capture-ifs "..."` runs it alone. Token `__CAPTURE_IF__`.

Design notes the implementer needs:
- **No `.link` file for a physical port.** A `.link` that matches a physical NIC replaces the distribution's default one, and the port would lose its predictable name at the next boot. The `.network` file gives silence and promiscuity; the Task 2 unit gives offloads.
- `lab_mirror0` in the list is passed over with a note: `labnet` owns it.
- Refusals, each before any write: the interface does not exist; it is not physical (`net_is_physical`); it has a master (rule 8); it carries a non-link-local address; it is the default route's interface.

- [ ] **Step 1: Create `config/networkd/capture-port.network.template`:**

```ini
# A physical capture port: silent (no address of any kind, no ARP) and
# promiscuous. Rendered per port by r770-capture-ports.sh apply as
# /etc/systemd/network/05-capture-__CAPTURE_IF__.network. Rule 8: it never
# gets an IP and never joins a bridge.
[Match]
Name=__CAPTURE_IF__

[Network]
DHCP=no
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes

[Link]
ARP=no
Promiscuous=yes
RequiredForOnline=no
```

- [ ] **Step 2: Write the failing suite `tests/capture-ports.bats`:**

```bash
#!/usr/bin/env bats
# r770-capture-ports.sh: physical capture ports made silent, promiscuous and
# offload-free, gated, with every refusal before any write.
load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-capture-ports.sh"
    make_root "$ROOT"
    S="$ROOT/sys/class/net"
    mkdir -p "$S/ens2f0/device" "$S/ens2f1/device" "$S/eno1/device" "$S/lab_mirror0" "$S/dummy0" "$ROOT/etc/systemd/network"
    echo 0x1103 > "$S/ens2f0/flags"; echo 0x1103 > "$S/ens2f1/flags"
    export ROOT KIT_YES=1
    stub systemctl 'echo "systemctl $*" >> "$STUB_LOG"; [ "$*" = "is-active systemd-networkd" ] && echo active; exit 0'
    stub_log networkctl
    stub ip 'echo "ip $*" >> "$STUB_LOG"
case "$*" in
  "-o addr show dev eno1")   echo "2: eno1    inet 192.168.4.78/24 brd 192.168.4.255 scope global eno1" ;;
  "route show default")      echo "default via 192.168.4.1 dev eno1 proto static" ;;
esac
exit 0'
    stub ethtool 'echo "ethtool $*" >> "$STUB_LOG"; [ "$1" = -k ] && printf "tcp-segmentation-offload: off\ngeneric-receive-offload: off\nlarge-receive-offload: off [fixed]\n"; exit 0'
}
cap() { kit_run "$SCRIPT" "$@"; }
netf() { echo "$ROOT/etc/systemd/network/05-capture-$1.network"; }

@test "apply needs --capture-ifs; nothing is guessed" {
    run cap apply
    [ "$status" -eq 1 ]; [[ "$output" == *"--capture-ifs"* ]]
}

@test "apply is gated: unattended without --yes writes nothing" {
    unset KIT_YES
    run cap apply --capture-ifs ens2f0 --non-interactive
    echo "$output"
    [ "$status" -eq 1 ]
    [ ! -e "$(netf ens2f0)" ]
    ! grep -q '^systemctl enable' "$STUB_LOG"
}

@test "apply renders one .network per port, enables the offload unit, reloads, applies offloads now, and proves the port" {
    run cap apply --capture-ifs "ens2f0 ens2f1"
    echo "$output"
    [ "$status" -eq 0 ]
    for i in ens2f0 ens2f1; do
        grep -qx "Name=$i" "$(netf "$i")"
        grep -qx 'Promiscuous=yes' "$(netf "$i")"
        grep -qx 'LinkLocalAddressing=no' "$(netf "$i")"
        grep -qx "systemctl enable r770-capture-offloads@$i.service" "$STUB_LOG"
        grep -qx "ethtool -K $i tso off gso off gro off lro off" "$STUB_LOG"
        [[ "$output" == *"PASS  $i: no address, no master, promiscuous, offloads off"* ]]
    done
    [ -f "$ROOT/etc/systemd/system/r770-capture-offloads@.service" ]
    grep -qx 'networkctl reload' "$STUB_LOG"
    [ ! -e "$ROOT/etc/systemd/network/05-capture-ens2f0.link" ]     # never a .link for a physical port
}

@test "apply passes lab_mirror0 over: labnet owns it" {
    run cap apply --capture-ifs "lab_mirror0 ens2f0"
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$(netf lab_mirror0)" ]
    [[ "$output" == *"lab_mirror0"*"labnet"* ]]
    [ -e "$(netf ens2f0)" ]
}

@test "apply with only lab_mirror0 has nothing to do and changes nothing" {
    run cap apply --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  no physical capture port"* ]]
    ! grep -q '^networkctl' "$STUB_LOG"
}

@test "apply refuses, before any write: a missing port, a non-physical one, the default route's port, a port with an address, a port with a master" {
    run cap apply --capture-ifs ens9
    [ "$status" -eq 1 ]; [[ "$output" == *"ens9 does not exist"* ]]
    run cap apply --capture-ifs dummy0
    [ "$status" -eq 1 ]; [[ "$output" == *"dummy0 is not a physical"* ]]
    run cap apply --capture-ifs eno1
    [ "$status" -eq 1 ]; [[ "$output" == *"eno1"*"default route"* ]]
    stub ip 'case "$*" in "-o addr show dev ens2f0") echo "3: ens2f0    inet 10.0.0.5/24 scope global ens2f0" ;; esac; exit 0'
    run cap apply --capture-ifs ens2f0
    [ "$status" -eq 1 ]; [[ "$output" == *"ens2f0 carries an address"* ]]
    stub ip 'exit 0'
    ln -s ../br0 "$S/ens2f1/master"
    run cap apply --capture-ifs "ens2f0 ens2f1"
    [ "$status" -eq 1 ]; [[ "$output" == *"ens2f1 has a master"* ]]
    [ ! -e "$(netf ens2f0)" ]                                       # one bad port stops all of them
}

@test "apply refuses when systemd-networkd is not active" {
    stub systemctl 'echo inactive; exit 3'
    run cap apply --capture-ifs ens2f0
    [ "$status" -eq 1 ]; [[ "$output" == *"systemd-networkd"* ]]
    [ ! -e "$(netf ens2f0)" ]
}

@test "apply is idempotent: files in place means no gate and no reload" {
    cap apply --capture-ifs ens2f0 >/dev/null
    : > "$STUB_LOG"; unset KIT_YES
    run cap apply --capture-ifs ens2f0 --non-interactive
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in place"* ]]
    ! grep -q '^networkctl reload' "$STUB_LOG"
}

@test "apply FAILs a port that is still not promiscuous or still has offloads on" {
    echo 0x1003 > "$S/ens2f0/flags"
    run cap apply --capture-ifs ens2f0
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  ens2f0: not promiscuous"* ]]
    echo 0x1103 > "$S/ens2f0/flags"
    stub ethtool '[ "$1" = -k ] && printf "tcp-segmentation-offload: on\ngeneric-receive-offload: off\n"; exit 0'
    run cap apply --capture-ifs ens2f0 --force
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  ens2f0: 1 offload(s) still on"* ]]
}

@test "apply --dry-run prints the file and writes nothing" {
    run cap apply --capture-ifs ens2f0 --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Name=ens2f0"* ]]
    [ ! -e "$(netf ens2f0)" ]
}

@test "status is read-only and reports each port" {
    run cap status --capture-ifs ens2f0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ens2f0"* ]]
    ! grep -qE '^(networkctl reload|systemctl enable|ethtool -K)' "$STUB_LOG"
}
```

- [ ] **Step 3: Run it.** `KT bats tests/capture-ports.bats` — Expected: every test FAILs (no script).
- [ ] **Step 4: Create `scripts/r770-capture-ports.sh`** and `chmod +x` it (`git update-index --chmod=+x` from Windows):

```bash
#!/usr/bin/env bash
#
# r770-capture-ports.sh — make PHYSICAL capture ports ready for Malcolm:
# silent (no address, no ARP), promiscuous, offloads off, and the same after
# a reboot.
#
#   r770-capture-ports.sh apply  --capture-ifs "<if> [<if> ...]"    (GATED)
#   r770-capture-ports.sh status --capture-ifs "<if> [<if> ...]"    read-only
#
#   --capture-ifs  the ports, from discovery (ip -br link); never guessed.
#                  lab_mirror0 in the list is passed over: labnet owns it.
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# Per port: /etc/systemd/network/05-capture-<if>.network (from the kit's
# config/networkd/capture-port.network.template) and the boot-time unit
# r770-capture-offloads@<if>.service. No .link file: one that matches a
# physical port replaces the distribution's default and the port would lose
# its predictable name at the next boot.
#
# Refuses, before any write, a port that does not exist, is not physical,
# has a master (rule 8), carries an address, or holds the default route.
# Run by r770-malcolm-deploy.sh full as its `capture` step, before configure.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CAPTURE_IFS=""
NETD="/etc/systemd/network"
UNITD="/etc/systemd/system"
OFFL_UNIT="r770-capture-offloads@.service"
TPL="$KIT_CONFIG_DIR/networkd/capture-port.network.template"
KIT_OWNED="lab_mirror0"          # capture ends another step owns
PORTS=()
STAGE=""
usage() { usage_from_header 3; exit 0; }

ports_resolve() {  # fill PORTS with the physical ports named, after every refusal
    local i sys a; sys="$(p /sys/class/net)"
    [ -n "$CAPTURE_IFS" ] || die "--capture-ifs \"<if> ...\" is required — take the names from ip -br link (try --help)"
    PORTS=()
    for i in $CAPTURE_IFS; do
        case " $KIT_OWNED " in *" $i "*) note "$i: passed over — r770-gns3-deploy.sh labnet owns it"; continue ;; esac
        [ -e "$sys/$i" ] || die "$i does not exist on this host (ip -br link)"
        net_is_physical "$i" || die "$i is not a physical interface — this step prepares hardware ports only"
        if [ -e "$sys/$i/master" ] || [ -L "$sys/$i/master" ]; then
            die "$i has a master ($(basename "$(readlink "$sys/$i/master" 2>/dev/null || echo unknown)")) — rule 8: a capture port is never bridged"
        fi
        if ip route show default 2>/dev/null | grep -qw "dev $i"; then
            die "$i holds the default route — that is the management path, not a capture port"
        fi
        a=$(ip -o addr show dev "$i" 2>/dev/null | grep -E ' inet6? ' | grep -vc 'scope link' || true)
        [ "$a" -eq 0 ] || die "$i carries an address — a capture port never has one; remove it from the host's network config first (ip -o addr show dev $i)"
        PORTS+=("$i")
    done
}
ports_stage() {  # render every port's file into STAGE
    local i
    for i in "${PORTS[@]}"; do
        DRY=0 render "$TPL" "$STAGE/05-capture-$i.network" "CAPTURE_IF=$i" >/dev/null
    done
}
ports_current() {
    local i
    for i in "${PORTS[@]}"; do
        printf '    %-10s %s\n' "$i" "$(ip -br link show dev "$i" 2>/dev/null | awk '{print $2, $3}' || true)"
        printf '    %-10s file: %s\n' "" "$([ -e "$(p "$NETD")/05-capture-$i.network" ] && echo present || echo absent)"
    done
}
ports_proposed() {
    local f i
    echo "    install into $NETD, then networkctl reload:"
    for f in "$STAGE"/*; do echo "    == $(basename "$f")"; sed 's/^/    | /' "$f"; done
    echo "    install $UNITD/$OFFL_UNIT, daemon-reload, and enable:"
    for i in "${PORTS[@]}"; do echo "    r770-capture-offloads@$i.service"; done
}
port_assert() {  # port_assert <if> — one PASS, or one FAIL per fault
    local i=$1 sys bad=0 a flags offl; sys="$(p /sys/class/net)"
    a=$(ip -o addr show dev "$i" 2>/dev/null | grep -E ' inet6? ' | grep -vc 'scope link' || true)
    [ "$a" -eq 0 ] || { fail "$i: carries an address (ip -o addr show dev $i)"; bad=1; }
    if [ -e "$sys/$i/master" ] || [ -L "$sys/$i/master" ]; then fail "$i: has a master (rule 8)"; bad=1; fi
    flags=$(cat "$sys/$i/flags" 2>/dev/null || echo 0)
    (( flags & 0x100 )) || { fail "$i: not promiscuous — networkctl status $i"; bad=1; }
    if command -v ethtool >/dev/null 2>&1; then
        offl=$(ethtool -k "$i" 2>/dev/null | grep -E '^(generic-receive-offload|large-receive-offload|tcp-segmentation-offload):' | grep -c ': on' || true)
        [ "$offl" -eq 0 ] || { fail "$i: $offl offload(s) still on — ethtool -k $i"; bad=1; }
    else
        skip "$i: offloads unchecked: ethtool not installed"
    fi
    [ "$bad" -eq 0 ] && pass "$i: no address, no master, promiscuous, offloads off"
    return 0
}

cmd_apply() {
    banner "capture ports — silent, promiscuous, offloads off, across reboots"
    need_root
    ports_resolve
    if [ "${#PORTS[@]}" -eq 0 ]; then skip "no physical capture port named — nothing to prepare"; footer "capture ports"; fi
    [ "$(systemctl is-active systemd-networkd 2>/dev/null)" = "active" ] \
        || die "systemd-networkd is not active — this step installs networkd files; nothing was written"
    local netd unitd f i changed=0 rb
    netd="$(p "$NETD")"; unitd="$(p "$UNITD")"
    STAGE=$(mktemp -d)
    trap 'rm -rf "$STAGE"' EXIT
    ports_stage
    for f in "$STAGE"/*; do cmp -s "$f" "$netd/$(basename "$f")" || changed=1; done
    cmp -s "$KIT_CONFIG_DIR/systemd/$OFFL_UNIT" "$unitd/$OFFL_UNIT" || changed=1
    [ "$FORCE" = "1" ] && changed=1
    if [ "$changed" -eq 0 ]; then
        pass "capture port files already in place in $NETD"
    else
        rb="networkctl reload after:"
        for i in "${PORTS[@]}"; do rb="$rb rm $NETD/05-capture-$i.network; systemctl disable r770-capture-offloads@$i.service;"; done
        gate "prepare physical capture ports (${PORTS[*]})" ports_current ports_proposed "$rb"
        if [ "$DRY" = "1" ]; then footer "capture ports"; fi
        run mkdir -p "$netd" "$unitd" || die "could not create $NETD or $UNITD"
        for f in "$STAGE"/*; do
            run install -m 0644 "$f" "$netd/$(basename "$f")" || die "could not install $(basename "$f")"
        done
        run install -m 0644 "$KIT_CONFIG_DIR/systemd/$OFFL_UNIT" "$unitd/$OFFL_UNIT" || die "could not install $OFFL_UNIT"
        run systemctl daemon-reload || die "daemon-reload failed"
        for i in "${PORTS[@]}"; do
            run systemctl enable "r770-capture-offloads@$i.service" || die "could not enable the offload unit for $i"
        done
        run networkctl reload || die "networkctl reload failed — journalctl -u systemd-networkd"
        if command -v ethtool >/dev/null 2>&1; then
            for i in "${PORTS[@]}"; do
                run ethtool -K "$i" tso off gso off gro off lro off || warn "ethtool -K $i failed — the check below says which offloads are still on"
            done
        fi
    fi
    for i in "${PORTS[@]}"; do port_assert "$i"; done
    footer "capture ports"
}

cmd_status() {
    banner "capture ports — status"
    ports_resolve
    local i
    for i in "${PORTS[@]}"; do port_assert "$i"; done
    footer "capture ports"
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --capture-ifs) CAPTURE_IFS="${2:-}"; shift ;;
        -h|--help)     usage ;;
        *)             common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-capture-ports"
case "$SUB" in
    apply)  cmd_apply ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
```

  Two things to check against `scripts/lib/common.sh` while implementing, and adjust the script (not the helper) if they differ: that `footer` exits (every other script relies on it), and that `render` with `DRY=0` in front writes the file even under `--dry-run` (the gate has to show the rendered text in a dry run; the stage directory is temporary).

- [ ] **Step 5: Run the suite.** `KT bats tests/capture-ports.bats` — Expected: all pass. Fix the script, never the assertions, unless an assertion contradicts the design notes above.
- [ ] **Step 6: Wire it into Malcolm — failing test first.** In `tests/malcolm-deploy.bats`, in the test "full runs preflight through start in order…" (near line 1025) add before `run malcolm full`:

```bash
    stub capture-stub 'echo "capture-ports $*" >> "$STUB_LOG"'
    export CAPTURE_PORTS_CMD="$BIN/capture-stub"
```

  and add a new test after it:

```bash
@test "full runs the capture step between unpack and configure, handing it --capture-ifs; with none given the step SKIPs" {
    make_malcolm_tree "$ROOT"
    stub_import_bundle
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture
    stub capture-stub 'echo "capture-ports $*" >> "$STUB_LOG"'
    export CAPTURE_PORTS_CMD="$BIN/capture-stub"
    run malcolm full --bundle "$BUNDLE" --only capture
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  no --capture-ifs given"* ]]
    ! grep -q '^capture-ports' "$STUB_LOG"
    mkdir -p "$ROOT/sys/class/net/ens2f0"
    run malcolm full --bundle "$BUNDLE" --only capture --capture-ifs "ens2f0"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'capture-ports apply --capture-ifs ens2f0' "$STUB_LOG"
}
```

  Run `KT bats tests/malcolm-deploy.bats --filter 'capture step'` — Expected: FAIL (unknown step: capture).

- [ ] **Step 7: Change `scripts/r770-malcolm-deploy.sh`.**

  `STEPS` becomes:

```bash
STEPS=(preflight gate copy apt phone-home docker files load unpack capture configure secrets auth rebind start)
```

  Beside `IMPORT_BUNDLE_CMD=` add:

```bash
# test seam, as IMPORT_BUNDLE_CMD above
CAPTURE_PORTS_CMD="${CAPTURE_PORTS_CMD:-$KIT_DIR/scripts/r770-capture-ports.sh}"
```

  Before `cmd_configure` add:

```bash
# capture — physical capture ports made ready before configure names them
# (r770-capture-ports.sh; lab_mirror0 is labnet's and is passed over there).
cmd_capture() {
    if [ "$CAPTURE_SET" != "1" ] || [ -z "$CAPTURE_IFS" ]; then
        banner "capture — physical capture ports"
        skip "no --capture-ifs given: no capture port to prepare"
        footer "capture"
    fi
    "$CAPTURE_PORTS_CMD" apply --capture-ifs "$CAPTURE_IFS"
}
```

  In `cmd_full`'s `case` add `capture)   run_step "$step" cmd_capture ;;` between `unpack` and `configure`. In the dispatch `case` add `capture)     cmd_capture ;;`. Add `capture` to the header's usage text. Fix any existing test that asserts the step count or the numbered banners (`N/14` becomes `N/15`): run the whole suite to find them.

- [ ] **Step 8: Docs and registration.**
  - `README.md` "What's here": a row for `scripts/r770-capture-ports.sh` — "Physical capture ports: `apply` (gated) renders one silent, promiscuous `.network` per port you name and enables the boot-time offload unit; `status` proves a port. Run by Malcolm's `full` as its `capture` step". In the Malcolm row add `capture` to the step list.
  - `tests/README.md`: a row for `capture-ports.bats`.
  - `config/README.md`: a row for `networkd/capture-port.network.template`, and `__CAPTURE_IF__` · `r770-capture-ports.sh apply` · each physical name in `--capture-ifs` in the token table.
  - `tests/config.bats:25`: append ` CAPTURE_IF` to `known=`.
  - `.claude/settings.json`: `"Bash(./scripts/r770-capture-ports.sh:*)"` beside its siblings.
  - `docs/deployment-runbook.md`: "Steps M9–M14" becomes M9–M15 with `capture` second, marked *(GATED)* with two sentences on what it writes and how to undo it; in "Where this runbook stops today" replace "capture ports prepared (no address, promiscuous, offloads off) before `configure --capture-ifs`" with "physical capture ports named in `--capture-ifs` (the `capture` step prepares them; it refuses a port with an address, a master or the default route)". `CLAUDE.md` rule 2's list of gated changes gains "physical capture ports" — that file is the operator's: propose the edit, do not make it without a yes.

- [ ] **Step 9: Gate and commit.**

```bash
KT ./tests/run.sh
git add scripts/r770-capture-ports.sh scripts/r770-malcolm-deploy.sh config/ tests/ README.md docs/deployment-runbook.md .claude/settings.json
git commit -m "capture ports: a gated step that prepares physical capture ports, run by Malcolm's full before configure"
```

---

### Task 4: A10 — Malcolm returns after a reboot

**Files:**
- Modify: `config/malcolm/malcolm-config.json.template:99`
- Modify: `config/README.md` (the `malcolm/malcolm-config.json.template` row)
- Modify: `docs/deployment-runbook.md` (the Malcolm section: one paragraph on reboots)
- Test: `tests/config.bats`

- [ ] **Step 1: Confirm the deviation with the operator** (see "One deviation" at the top). On a no, stop and write the unit-based task instead.
- [ ] **Step 2: Write the failing test** — append to `tests/config.bats`:

```bash
@test "A10: the Malcolm config template has the stack restart with the Docker daemon" {
    run grep -cE '^[[:space:]]*"malcolmRestartPolicy": "unless-stopped",?$' config/malcolm/malcolm-config.json.template
    [ "$output" = "1" ]
}
```

- [ ] **Step 3: Run it.** `KT bats tests/config.bats --filter A10` — Expected: FAIL (count 0).
- [ ] **Step 4: Change the template.** Line 99: `"malcolmRestartPolicy": "no",` becomes `"malcolmRestartPolicy": "unless-stopped",`. In `config/README.md` add `malcolmRestartPolicy=unless-stopped` to that row's delta list and "the stack returns after a reboot without an operator (A10)" to its reason.
- [ ] **Step 5: Runbook.** In the Malcolm procedure, after the `start` text, add: "After a reboot the stack comes back by itself (restart policy `unless-stopped`, set at `configure`). `r770-malcolm-deploy.sh stop` takes it down until the next `start`. A box configured before this change needs `configure`, `rebind` and `start` rerun once."
- [ ] **Step 6: Gate and commit.**

```bash
KT ./tests/run.sh
git add config/ tests/config.bats docs/deployment-runbook.md
git commit -m "malcolm: restart policy unless-stopped, so the stack returns after a reboot (A10)"
```

  Verified only by the reboot in Task 7.

---

### Task 5: A2 — `plan` on a bare host SKIPs what the run itself provides

The transcript (`plan.log`, acceptance 2026-11-10) shows six FAIL rows, all one cause: a step's prerequisite is created by an earlier step of the same run. `gns3` stopped at `venv` (package `python3-venv`), `malcolm` at `unpack` (two packages), `portal ca` and `portal nginx` on a package each, `portal cert` on the CA, `portal htpasswd` on Malcolm's login file. On a host with no Docker yet, `load` would refuse the same way.

**Files:**
- Modify: `scripts/r770-install.sh` (`cmd_plan` and two helpers above it)
- Test: `tests/install.bats`

**Interfaces:**
- Produces: `plan` exit 0 on a bare host with a correct `install.conf`; each withheld review is one `SKIP` line naming the step that provides the prerequisite.

- [ ] **Step 1: Make the suite's default host an installed one.** In `tests/install.bats` `setup()`, after the `findmnt` stub, add:

```bash
    stub dpkg 'exit 0'; stub docker 'exit 0'
    mkdir -p "$ROOT/etc/lab/ca/pki" "$ROOT/opt/malcolm/malcolm/nginx" "$ROOT/etc/nginx/ssl"
    touch "$ROOT/etc/lab/ca/pki/ca.crt" "$ROOT/opt/malcolm/malcolm/nginx/htpasswd" \
          "$ROOT/etc/nginx/ssl/lab.crt" "$ROOT/etc/nginx/lab.htpasswd"
```

  (`: > file` would leave them empty; the checks below use `-e`, so `touch` is enough.) Run `KT bats tests/install.bats` — Expected: still all pass.

- [ ] **Step 2: Write the failing test** — add after the I5 test:

```bash
@test "A2: plan on a bare host reviews what it can and SKIPs the rest, naming the step that provides it — READY, not FAIL" {
    good_conf
    unstub docker; stub dpkg 'exit 1'
    rm -rf "$ROOT/etc/lab/ca" "$ROOT/opt/malcolm" "$ROOT/etc/nginx/ssl/lab.crt" "$ROOT/etc/nginx/lab.htpasswd"
    run inst plan --conf "$CONF"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^gns3 full --bundle $BUNDLE --to files --dry-run" "$STUB_LOG"
    grep -q "^malcolm full --bundle $BUNDLE --to files --dry-run" "$STUB_LOG"
    grep -q "^docs full --bundle $BUNDLE --to files --dry-run" "$STUB_LOG"
    ! grep -q '^portal ' "$STUB_LOG"
    [[ "$output" == *"SKIP  gns3 after files"*"docker"*"import"* ]]
    [[ "$output" == *"SKIP  malcolm after files"*"docker"* ]]
    [[ "$output" == *"SKIP  portal ca"*"easy-rsa"*"import"* ]]
    [[ "$output" == *"SKIP  portal cert"*"portal ca"* ]]
    [[ "$output" == *"SKIP  portal htpasswd"*"malcolm"*"auth"* ]]
    [[ "$output" == *"SKIP  portal nginx"* ]]
    [[ "$output" != *"FAIL  "* ]]
}

@test "A2: with Docker present but the apt packages absent, the pipelines are reviewed up to load" {
    good_conf
    stub dpkg 'exit 1'
    run inst plan --conf "$CONF"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^gns3 full --bundle $BUNDLE --to load --dry-run" "$STUB_LOG"
    grep -q "^malcolm full --bundle $BUNDLE --to load --dry-run" "$STUB_LOG"
    grep -q "^docs full --bundle $BUNDLE --dry-run" "$STUB_LOG"
    [[ "$output" == *"SKIP  gns3 after load"*"python3-venv"* ]]
    [[ "$output" == *"SKIP  malcolm after load"*"python3-ruamel.yaml"* ]]
}
```

  Run `KT bats tests/install.bats --filter A2` — Expected: both FAIL.

- [ ] **Step 3: Implement.** In `scripts/r770-install.sh`, above `cmd_plan`, add:

```bash
# A step whose prerequisite an EARLIER step of this same run creates cannot be
# reviewed before that step has run; plan says so with a SKIP naming the
# provider instead of reporting the child's refusal (acceptance 2026-11-10, A2).
pkg_missing() {  # pkg_missing <pkg...> — prints " <pkg>" for each one not installed
    local k m=""
    for k in "$@"; do dpkg -s "$k" >/dev/null 2>&1 || m="$m $k"; done
    printf '%s' "$m"
}
# plan_horizon <pipeline> — "<last reviewable step>|<what is missing and who provides it>",
# or nothing when the whole pipeline can be reviewed on this host as it stands.
plan_horizon() {
    local m=""
    if ! command -v docker >/dev/null 2>&1; then
        printf 'files|docker — installed by the import steps (docker)'; return 0
    fi
    case "$1" in
        gns3)    m=$(pkg_missing python3-venv python3-pip-whl ubridge) ;;
        malcolm) m=$(pkg_missing python3-ruamel.yaml python3-dotenv) ;;
    esac
    [ -z "$m" ] || printf 'load|package(s)%s — installed by the import steps (apt)' "$m"
}
# plan_pipeline <label> <cmd> <bundle> [args...] — review as far as the horizon allows
plan_pipeline() {
    local label=$1 cmd=$2 b=$3 h; shift 3
    h=$(plan_horizon "$label")
    if [ -n "$h" ]; then
        plan_child "$label (to ${h%%|*})" "$cmd" full --bundle "$b" --to "${h%%|*}" --dry-run
        skip "$label after ${h%%|*}: needs ${h#*|}; run reviews the rest at its own gates"
        return 1
    fi
    return 0
}
```

  Then in `cmd_plan` replace the `gns3`, `malcolm`, `docs` and portal lines with:

```bash
    plan_pipeline gns3 "$GNS3" "$b" && plan_child "gns3" "$GNS3" full --bundle "$b" --dry-run
    local i late=""
    for i in $CONF_CAPTURE_IFS; do case " $LATE_IFS " in *" $i "*) has_line "$i" "$(host_ifs)" || late="$late $i" ;; esac; done
    if plan_pipeline malcolm "$MALCOLM" "$b"; then
        if [ -n "$late" ]; then
            plan_child "malcolm (to unpack)" "$MALCOLM" full --bundle "$b" --to unpack --dry-run
            skip "malcolm capture, configure, secrets, auth, rebind, start: need${late} — created by the gns3 step's labnet; run reviews them at their own gates"
        else
            plan_child "malcolm" "$MALCOLM" full --bundle "$b" --capture-ifs "$CONF_CAPTURE_IFS" --dry-run
        fi
    fi
    plan_pipeline docs "$DOCS" "$b" && plan_child "docs" "$DOCS" full --bundle "$b" --dry-run
    local m
    m=$(pkg_missing easy-rsa)
    if [ -n "$m" ]; then skip "portal ca: needs package(s)$m — installed by the import steps (apt)"
    else plan_child "portal ca" "$PORTAL" ca --dry-run; fi
    if [ -e "$(p /etc/lab/ca/pki/ca.crt)" ]; then plan_child "portal cert" "$PORTAL" cert --dry-run
    else skip "portal cert: needs the lab CA — created by portal ca"; fi
    if [ -e "$(p /opt/malcolm/malcolm/nginx/htpasswd)" ]; then plan_child "portal htpasswd" "$PORTAL" htpasswd --dry-run
    else skip "portal htpasswd: needs Malcolm's login file — created by the malcolm step's auth"; fi
    m=$(pkg_missing nginx)
    if [ -n "$m" ]; then skip "portal nginx: needs package(s)$m — installed by the import steps (apt)"
    elif [ ! -e "$(p /etc/nginx/ssl/lab.crt)" ] || [ ! -e "$(p /etc/nginx/lab.htpasswd)" ]; then
        skip "portal nginx: needs the certificate and the login file — created by portal cert and portal htpasswd"
    else plan_child "portal nginx" "$PORTAL" nginx --dry-run; fi
```

  `docs` has no entry in `plan_horizon`'s `case`, so only a missing Docker shortens it. The existing I5 test asserts `SKIP  malcolm configure`; the SKIP text now begins `malcolm capture, configure`: change that assertion to `*"SKIP  malcolm capture, configure"*"labnet"*`.

- [ ] **Step 4: Run, gate, commit.**

```bash
KT bats tests/install.bats
KT ./tests/run.sh
git add scripts/r770-install.sh tests/install.bats
git commit -m "install plan: SKIP, naming the provider, what an earlier step of the same run creates (A2)"
```

  Also update the runbook's installer section: one sentence that `plan` on a bare host prints SKIP rows for what the run itself will provide, and reads READY.

---

### Task 6: The analyst wiki — accuracy pass and a getting-started page

**Files:**
- Modify: `docs/wiki/index.md`, `docs/wiki/wan.md`, `docs/wiki/cli-tools.md`, `docs/wiki/access.md`, `docs/wiki/malcolm.md`, `docs/wiki/gns3.md`, `docs/wiki/scenarios.md`
- Create: `docs/wiki/getting-started.md`
- Modify: `config/docs/mkdocs.yml` (nav)
- Test: `tests/docs-deploy.bats` (one test)

The rule for the accuracy pass: every command, name and URL on a page must exist on an installed box. Where it does not, either replace it with the thing that does exist or delete the sentence. No new sections.

- [ ] **Step 1: Write the failing test** — append to `tests/docs-deploy.bats`:

```bash
@test "the wiki names no tool the kit does not put on the box, and every page is in the nav" {
    cd "$BATS_TEST_DIRNAME/.."
    run grep -rnE '\bwan-apply\b|\bwan-emu\b|lab-transit\.sh|br-lab-[ti][0-9N]' docs/wiki
    echo "$output"
    [ "$status" -ne 0 ]
    for f in docs/wiki/*.md; do
        grep -q "$(basename "$f")" config/docs/mkdocs.yml || { echo "not in nav: $f"; false; }
    done
    grep -q 'Getting started: getting-started.md' config/docs/mkdocs.yml
}
```

  Run `KT bats tests/docs-deploy.bats --filter 'wiki names'` — Expected: FAIL (`wan-apply` in `index.md` and `wan.md`).

- [ ] **Step 2: Known fixes.**
  - `docs/wiki/wan.md` lines 12 and 47 and `docs/wiki/index.md` line 26: `wan-apply <profile> <interface>` becomes `sudo r770-wan.sh apply <profile> <lab-tapN>`; add `sudo r770-wan.sh show` and `sudo r770-wan.sh clear <lab-tapN>`; say it shapes kit TAPs only and that the profiles are the files under the kit's `config/wan/profiles/` (list their names by reading that directory, do not invent any).
  - `docs/wiki/cli-tools.md` tcpreplay section: `r770-validate.sh` SKIPped `capture/tcpreplay` on the VM. Check the bundle's package list (the `apt` stage's curated list in `staging/r770-offline-fetch.sh`) for `tcpreplay`: if it is there keep the section, if not delete the section and the row in `index.md` line 30.
- [ ] **Step 3: Read all seven pages end to end** against the installed state as the records describe it (`docs/rehearsals/2026-11-10-installer-acceptance.md`): URLs are `https://malcolm.lab`, `https://gns3.lab`, `https://docs.lab`; one shared analyst login for Malcolm and the wiki; GNS3 has its own admin login; GeoIP absent; Suricata off; ten scenarios in the pack (list from `scenarios/`). Fix each claim that does not match; keep a list of what changed for the commit message.
- [ ] **Step 4: Write `docs/wiki/getting-started.md`.** One page, in this order, each section a few sentences and at most one command block:
  1. *What this lab is* — GNS3 builds networks, the lab bridge mirrors their traffic, Malcolm captures and indexes it.
  2. *The three addresses* — the table of three URLs and which login each asks for; where the lab CA certificate comes from so the browser trusts them (point to `access.md`).
  3. *See traffic in ten minutes* — an operator runs `sudo r770-scenario.sh up client-server --bundle <bundle>`, then `traffic client-server`, then `down client-server`; the analyst opens Arkime at `malcolm.lab`, sets the time range to the last 15 minutes and sees the sessions. Take the exact command forms from the runbook's "Scenarios" section.
  4. *Where to look next* — links to `malcolm.md`, `gns3.md`, `scenarios.md`.
  5. *What the lab does not have* — no internet, no GeoIP, no IDS alerts, data only as fresh as the last bundle.
  No credential, no address outside `.lab` names and documentation ranges, no version number.
- [ ] **Step 5: Nav.** In `config/docs/mkdocs.yml` add `  - Getting started: getting-started.md` directly under `Home`, and add any page the test reports as missing from the nav.
- [ ] **Step 6: Gate and commit.**

```bash
KT ./tests/run.sh
git add docs/wiki config/docs tests/docs-deploy.bats
git commit -m "wiki: accuracy pass against the installed box, and a getting-started page for analysts"
```

---

### Task 7: The final cut and the final VM pass

Operator task. Every Proxmox change and every `rollback` needs the operator's yes. The procedure, names and stand-ins are those of `docs/superpowers/plans/2026-11-09-finish-rehearsals.md` Tasks 6–8; what differs is listed here.

**Files:**
- Create: `docs/rehearsals/<date>-final-pass.md` (format: `docs/rehearsals/README.md`)
- Modify: `docs/rehearsals/2026-11-10-installer-acceptance.md` (findings A2, A8, A9, A10, A11: commit, bundle, rerun verdict)

- [ ] **Step 1: Gate on Ubuntu.** `KT ./tests/run.sh` exit 0, then push `finish-line` (operator's yes).
- [ ] **Step 2: Cut.** On the staging host, from the pushed commit: `KIT_SRC_ROOT=<checkout> ./staging/r770-build-bundle.sh`. **No synthetic appliance placeholders this time** (Task 1 removed the need). Expected: `RESULT: PASS EXIT=0`, `gns3/definitions/` holds seven files, `kit/KIT_COMMIT` equals the pushed commit. Keep the transcript.
- [ ] **Step 3: A bare-OS VM.** Roll VM 9770 back to the snapshot taken before Docker was ever installed. Find it with `./harness/r770-staging-vm.sh status --pve proxmox --vmid 9770`; if none predates Docker, ask the operator before making one from the clean snapshot. Add one spare NIC to the VM, on a bridge with no uplink, as the stand-in physical capture port (operator's yes: it is a Proxmox change). Attach the new media. `airgap on` and keep its PASS lines.
- [ ] **Step 4: Install.** On the VM, from the media: `discover`; write `install.conf` with `CAPTURE_IFS=lab_mirror0 <the spare NIC's name from discover>`; `plan`; `run --yes`. Expected:
  - `plan`: READY, exit 0, SKIP rows for docker, the packages and the portal chain (A2).
  - `run`: the Docker gate runs for real; Malcolm's `capture` step PASSes the spare NIC; no "definition without image" line anywhere (A8); verdict INSTALLED, exit 0.
- [ ] **Step 5: Reboot, then prove, with no command run first.**

```bash
ssh r770-staging sudo systemctl reboot
./harness/r770-staging-vm.sh wait-ssh 600 --mgmt-host r770-staging
ssh r770-staging sudo /srv/bundles/<bundle>/kit/scripts/r770-malcolm-deploy.sh status
ssh r770-staging sudo /srv/bundles/<bundle>/kit/scripts/r770-validate.sh --area network --capture-ifs "lab_mirror0 <nic>" --lab-bridge br-lab
```

  Expected: every Malcolm service running or healthy without `start` having been run (A10; allow the ten minutes the first start took); the capture rows for both interfaces PASS, offloads included (A11).
- [ ] **Step 6: Re-entry.** `r770-install.sh run --yes --from malcolm`. Expected: INSTALLED, exit 0 (A9).
- [ ] **Step 7: Findings rule.** A finding against in-scope code: one hypothesis, one change, test-first on `finish-line`, re-cut, and rerun from step 3. A finding against frozen code (`ipsec-ike`, `s0-w1`, `s1-w1-ss`, `r770-wan.sh`, `record`/`verify`/`ingest`, `harness/`): write it into the record as open, do not fix, do not re-cut.
- [ ] **Step 8: Record and snapshot.** Snapshot the VM (`final-<date>`). Write `docs/rehearsals/<date>-final-pass.md` with every step's transcript name. Update the five findings in the acceptance record. Archive the evidence under `~/r770-rehearsals/<date>-final-pass/`. Commit. `airgap off`, stop the VM, start whatever the operator had running before.
- [ ] **Step 9: Merge.** With the operator's yes: PR `finish-line` into `main`, merge. The bundle from the last clean cut is **the** bundle for the R770; its media is not rebuilt after this.

---

### Task 8: Install on the real R770

Operator task; Claude assists from transcripts the operator brings back (the R770 is air-gapped and this PC is not on it).

**Files:**
- Create: `docs/rehearsals/<date>-r770-install.md`

- [ ] **Step 1: Before leaving the staging host.** The media verifies there: `<bundle>/r770-bundle.sh verify`. Write down the bundle id and `kit/KIT_COMMIT`.
- [ ] **Step 2: On the R770, discovery first.** iDRAC console open as the recovery path. Mount the media (device from `lsblk`), then `sudo <media>/<bundle>/kit/scripts/r770-install.sh discover`. From its output choose: the media device, the management interface and CIDR, the lab bridge name, and the physical capture ports. Nothing is typed that discovery did not print.
- [ ] **Step 3: `wizard` or a hand-written `install.conf`, then `plan`.** Read every gate's current/proposed/rollback. Expected: READY. A refusal here is a finding: stop.
- [ ] **Step 4: `run`** (interactive, answering each gate, or `--yes` once `plan` has been read). On a refusal: read the transcript under `r770-evidence/`, fix the cause, `run --from <step>`. Never route around a script.
- [ ] **Step 5: Verdict.**
  - INSTALLED, exit 0: done.
  - NOT INSTALLED and the only failures are frozen scenarios in e2e: write the disposition (scenario, the failing check line, transcript name, "frozen work, recorded as open") in the record. The finish line is met by that written disposition.
  - Anything else: an in-scope finding. Fix on a branch from `main`, re-cut, verify the cut on the VM from snapshot `final-<date>` with `run --from <the step>`, and bring the new media.
- [ ] **Step 6: Reboot the R770 once** and repeat Task 7 step 5's two checks.
- [ ] **Step 7: Evidence and record.** Copy `r770-evidence/` off the box by the media path. Write `docs/rehearsals/<date>-r770-install.md`: header, no stand-ins, steps with transcripts, findings, not exercised (at least: traffic on the physical capture ports). Commit on a branch, PR, merge.

---

### Task 9: Backlog and close

**Files:**
- Create: `docs/backlog.md`
- Modify: `README.md` (one status paragraph at the top), `docs/deployment-runbook.md` (the installer's date and "as installed" notes)

- [ ] **Step 1: Write `docs/backlog.md`.** Sections, each a short list, citing only files that exist:
  - *Open findings against frozen work*: I4, I5, I6, I7 with one line each, pointing at `docs/rehearsals/2026-11-10-ipsec-wan.md`.
  - *Not built*: IPsec spec phases IP5–IP9 (`docs/superpowers/specs/2026-09-24-ipsec-scenarios-spec.md`); licensed appliance definitions (add to the fetch with their image).
  - *Deferred minors*: the harness and reviewer minors listed in the finish-rehearsals progress notes, copied in as plain lines (that ledger is not tracked).
  - *Not exercised on the R770*: from the Task 8 record.
  - A closing line: new work starts as its own project with its own finish line.
- [ ] **Step 2: README status.** Under the title: installed on the R770 on `<date>` (record path), and that the repo is closed to new scope (`docs/backlog.md`).
- [ ] **Step 3: Gate, commit, PR, merge.**

```bash
KT ./tests/run.sh
git add docs/backlog.md README.md docs/deployment-runbook.md
git commit -m "Close: backlog of what was deferred; installed on the R770 <date>"
```

- [ ] **Step 4: Remote branches.** List the merged remote branches (`git branch -r --merged origin/main`) and ask the operator which to delete; delete none without a yes.
