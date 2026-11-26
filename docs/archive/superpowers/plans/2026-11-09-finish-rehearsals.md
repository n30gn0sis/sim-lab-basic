# Finish the Rehearsals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run everything built since 2026-10-03 for real on staging VM 9770 — a fresh bundle, the installer acceptance, a look at the lab site, the IPsec/WAN rehearsal — and record the results in this repo.

**Architecture:** One operator-side script, `harness/r770-staging-vm.sh`, drives the VM through `ssh <pve> qm …` (rollback, start, stop, snapshot, air gap by link-down, tunnel). A small PowerShell helper takes the site screenshots. Tasks 1–5 build and test that tooling; Tasks 6–11 are rehearsal tasks that produce transcripts and records, not code.

**Tech Stack:** bash, bats, shellcheck (the kit's own); Proxmox `qm` over SSH; PowerShell 7 and a Chromium browser's DevTools protocol for screenshots.

**Spec:** `docs/superpowers/specs/2026-11-09-finish-rehearsals-design.md`

## Global Constraints

- Branch `finish-rehearsals`. Never commit to `main`. Never push or open a PR without the operator's yes.
- `./tests/run.sh` must be green before every commit (how to run it from this PC: "Running the suite", below).
- shellcheck with **no exclusions**. Exit contract `0 / 2 / 1`. Check lines `PASS  ` / `WARN  ` / `FAIL  ` / `SKIP  `.
- Discover, never guess: VM id, SSH hosts, snapshot names, NIC names, probe addresses and ports are arguments. No script defaults one.
- No three-part version number anywhere in a tracked file (`tests/no-pins.bats` scans the whole tree, this plan included). Dotted-quad addresses are fine.
- No secret in git, in chat, on a command line, or in a record. Evidence transcripts stay out of git.
- The harness never destroys a VM, a disk or a snapshot. Proxmox changes outside Task 6's table need the operator's yes first.
- Each `ssh proxmox` command is ONE simple command: no `;`, `&`, `|`, `$(`, `>`, `<` or backtick inside the remote string (the operator's permission rules stop on those). Pipe and redirect on the local side instead.
- On the VM, only kit scripts change the host, except the stand-ins this plan names. A script's refusal is a finding: one hypothesis, one change, rerun `--from <step>`.
- A verdict is written only with its transcript's file name beside it.
- Commit messages end with `Co-Authored-By: Claude <noreply@anthropic.com>`.

## Names fixed by this plan

| Name | Value |
|---|---|
| Proxmox SSH host / node | `proxmox` / `proxmox` |
| VM id | `9770` |
| Host-only bridge | `vmbr9770`, host address `192.168.97.1/24` (no overlap with the host's `192.168.4.0/22`, `192.0.2.0/24`, `198.51.100.0/24`, `172.17.0.0/16`, `10.1.0.0/16`, nor with the kit's `198.18.0.0/15` and `10.2xx` ranges) |
| VM management address | `192.168.97.70/24` on `net1` |
| VM SSH name on the operator PC | `r770-staging` (user `ubuntu`, `ProxyJump proxmox`) |
| Operator key | `~/.ssh/r770-staging_ed25519` |
| Evidence archive on the operator PC | `~/r770-rehearsals/<date>-<name>/` (outside the repo) |
| Tunnel port on the operator PC | `8443` |

`<date>` everywhere below is the day the step runs, as `YYYY-MM-DD` (`date +%F`).

## Running the suite from this PC

WSL Ubuntu has `bats` and `shellcheck`. This command clones the branch into WSL, lays the working tree's tracked and untracked files over it, and runs whatever is passed. It is called **`KT <cmd>`** below.

```bash
wsl -e bash -lc 'set -e; rm -rf ~/sim-lab-wt; git clone -q "/mnt/c/coding stuff/sim-lab-basic" ~/sim-lab-wt; cd "/mnt/c/coding stuff/sim-lab-basic"; git ls-files -co --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C ~/sim-lab-wt; cd ~/sim-lab-wt; <cmd>'
```

`KT ./tests/run.sh` is the whole gate; `KT bats tests/harness.bats` is one suite.

**Until Task 1 step 5 is done, the working tree has CRLF line endings and `KT` fails with `bash: No such file`.** In Task 1 steps 2 and 4 only, run the gate as **`KT0`** instead, which strips the carriage returns from the files it lays over the clone:

```bash
wsl -e bash -lc 'set -e; rm -rf ~/sim-lab-wt; git clone -q "/mnt/c/coding stuff/sim-lab-basic" ~/sim-lab-wt; cd "/mnt/c/coding stuff/sim-lab-basic"; git status --porcelain | cut -c4- | while read -r f; do mkdir -p ~/sim-lab-wt/"$(dirname "$f")"; tr -d "" < "$f" > ~/sim-lab-wt/"$f"; done; cd ~/sim-lab-wt; ./tests/run.sh'
```

## File Structure

| File | Responsibility |
|---|---|
| `.gitattributes` (create) | every text file checks out with LF, so kit scripts run from the Windows checkout |
| `harness/r770-staging-vm.sh` (create) | the VM driver: `status rollback start stop snapshot airgap wait-ssh tunnel` |
| `harness/r770-site-shot.ps1` (create) | one screenshot of one `.lab` page through the tunnel; operator PC only |
| `tests/harness.bats` (create) | the driver's contract with `ssh` stubbed |
| `tests/lint.bats`, `tests/references.bats` (modify) | lint, parse, executable and path checks cover `harness/` |
| `README.md`, `tests/README.md`, `.claude/settings.json` (modify) | the new script's row and `allow` entry |
| `docs/rehearsals/README.md` (create) | the record format |
| `docs/rehearsals/<date>-installer-acceptance.md`, `docs/rehearsals/<date>-ipsec-wan.md` (create, Tasks 8–10) | the records |
| `docs/deployment-runbook.md` (modify, Task 11) | the IPsec section "as measured"; the installer's rehearsal date |

---

### Task 1: LF line endings, and the pending `CLAUDE.md` trim

The Windows checkout has `core.autocrlf=true`; every script in the working tree has CRLF and will not run in Git Bash. The repository itself stores LF.

**Files:**
- Create: `.gitattributes`
- Commit: `CLAUDE.md` (already modified in the working tree)

- [ ] **Step 1: Confirm the problem.**

Run: `file scripts/r770-wan.sh`
Expected: `... with CRLF line terminators`

- [ ] **Step 2: Commit the pending `CLAUDE.md` trim on its own** (so the re-checkout in step 4 cannot lose it).

Run: `KT0` — Expected: no `not ok` line; exit 0.

```bash
git add CLAUDE.md
git commit -m "CLAUDE.md: common.sh's helper list becomes a pointer to the file

Co-Authored-By: Claude <noreply@anthropic.com>"
```

- [ ] **Step 3: Write `.gitattributes`.**

```
* text=auto eol=lf
*.png binary
```

- [ ] **Step 4: Commit it** (before the re-checkout: `git reset --hard` deletes a file that is staged but not yet committed).

Run: `git add .gitattributes`, then `KT0` — Expected: exit 0.

```bash
git add .gitattributes
git commit -m "gitattributes: LF everywhere, so the kit's scripts run from a Windows checkout

Co-Authored-By: Claude <noreply@anthropic.com>"
```

- [ ] **Step 5: Re-checkout the working tree with LF.**

```bash
git status --short            # expected: empty
git rm -r -q --cached .
git reset -q --hard
git status --short            # expected: empty — no file's stored content changed
file scripts/r770-wan.sh      # expected: no "CRLF"
```

If `git status` shows any path, stop: that file's stored content is not LF. Name it to the operator before going on.

- [ ] **Step 6: Prove a kit script now runs from this checkout, and that `KT` now works.**

Run: `bash scripts/r770-wan.sh --help` — Expected: the usage text, exit 0.
Run: `KT ./tests/run.sh` — Expected: exit 0.

---

### Task 2: `harness/r770-staging-vm.sh` — status, rollback, start, stop, snapshot

**Files:**
- Create: `harness/r770-staging-vm.sh`
- Create: `tests/harness.bats`

**Interfaces:**
- Consumes: `scripts/lib/common.sh` — `kit_init`, `die`, `pass`, `fail`, `note`, `footer`, `run`, `gate <title> <current-fn> <proposed-fn> <rollback-text>`, `common_flag`, `usage_from_header <first-line>`, `$DRY`.
- Produces: `harness/r770-staging-vm.sh <sub> --pve <ssh-host> --vmid <n> [--snapshot <name>] [--description <text>]`; functions `pve`, `pve_run`, `vm_state`, `snap_exists`, `valid`, `need_arg` that Task 3 adds to.

- [ ] **Step 1: Write the failing tests.** Create `tests/harness.bats`:

```bash
#!/usr/bin/env bats
# r770-staging-vm.sh: the operator-side VM driver, with ssh stubbed. No test
# reaches a hypervisor or a guest.
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../harness/r770-staging-vm.sh"
    export QM_CONFIG="$BATS_TEST_TMPDIR/qm.conf" QM_SNAPS="$BATS_TEST_TMPDIR/qm.snaps"
    printf 'memory: 16384\nnet0: virtio=BC:24:11:00:00:01,bridge=vmbr0\nnet1: virtio=BC:24:11:00:00:02,bridge=vmbr9\n' > "$QM_CONFIG"
    printf '%s\n' '`-> clean-a    2026-01-01 00:00:00    a clean base' ' `-> current    You are here!' > "$QM_SNAPS"
    stub ssh '
echo "ssh $*" >> "$STUB_LOG"
case "$*" in
    *"/dev/tcp/"*)          exit "${PROBE_RC:-1}" ;;
    *" qm status "*)        echo "status: ${VM_STATE:-stopped}" ;;
    *" qm config "*)        cat "$QM_CONFIG" ;;
    *" qm listsnapshot "*)  cat "$QM_SNAPS" ;;
    *" qm set "*)           prev=""; for a in "$@"; do
                                case "$prev" in --net*) sed -i "s|^${prev#--}: .*|${prev#--}: $a|" "$QM_CONFIG" ;; esac
                                prev="$a"; done ;;
    *" true")               exit "${GUEST_RC:-0}" ;;
esac
exit 0'
    cd "$BATS_TEST_TMPDIR"
}
vm() { kit_run "$SCRIPT" "$@"; }

@test "every subcommand refuses without --pve and --vmid, and refuses a value that is not a name or a number" {
    run vm status --vmid 9770
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --pve"* ]]
    run vm status --pve pve
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --vmid"* ]]
    run vm status --pve pve --vmid '9770;reboot'
    [ "$status" -eq 1 ]; [[ "$output" == *"--vmid"* ]]
    run vm status --pve 'pve host' --vmid 9770
    [ "$status" -eq 1 ]; [[ "$output" == *"--pve"* ]]
    ! grep -q '^ssh' "$STUB_LOG"
}

@test "status prints the state, the snapshots and the NICs, and changes nothing" {
    VM_STATE=running run vm status --pve pve --vmid 9770
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"running"* && "$output" == *"clean-a"* && "$output" == *"net0: virtio"* ]]
    ! grep -qE ' qm (set|start|shutdown|rollback|snapshot) ' "$STUB_LOG"
}

@test "rollback refuses a snapshot the VM does not have" {
    run vm rollback --pve pve --vmid 9770 --snapshot nope
    [ "$status" -eq 1 ]; [[ "$output" == *"no snapshot 'nope'"* ]]
    ! grep -q ' qm rollback ' "$STUB_LOG"
}

@test "rollback is gated: an unattended run without --yes stops and rolls nothing back" {
    KIT_YES=0 run vm rollback --pve pve --vmid 9770 --snapshot clean-a
    [ "$status" -eq 1 ]
    [[ "$output" == *"-- current --"* && "$output" == *"-- proposed --"* && "$output" == *"-- rollback --"* ]]
    ! grep -q ' qm rollback ' "$STUB_LOG"
}

@test "rollback with --yes runs exactly qm rollback <vmid> <snapshot>" {
    run vm rollback --pve pve --vmid 9770 --snapshot clean-a --yes
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm rollback 9770 clean-a$' "$STUB_LOG"
}

@test "--dry-run prints the command and runs none that changes the VM" {
    run vm rollback --pve pve --vmid 9770 --snapshot clean-a --dry-run
    [ "$status" -eq 0 ]; [[ "$output" == *"DRY-RUN:"*"qm rollback 9770 clean-a"* ]]
    VM_STATE=stopped run vm start --pve pve --vmid 9770 --dry-run
    [ "$status" -eq 0 ]; [[ "$output" == *"DRY-RUN:"*"qm start 9770"* ]]
    ! grep -qE ' qm (start|rollback) ' "$STUB_LOG"
}

@test "start and stop are idempotent" {
    VM_STATE=running run vm start --pve pve --vmid 9770
    [ "$status" -eq 0 ]; [[ "$output" == *"already running"* ]]
    VM_STATE=stopped run vm stop --pve pve --vmid 9770
    [ "$status" -eq 0 ]; [[ "$output" == *"already stopped"* ]]
    ! grep -qE ' qm (start|shutdown) ' "$STUB_LOG"
    VM_STATE=stopped run vm start --pve pve --vmid 9770
    [ "$status" -eq 0 ]; grep -q 'pve qm start 9770$' "$STUB_LOG"
    VM_STATE=running run vm stop --pve pve --vmid 9770
    [ "$status" -eq 0 ]; grep -q 'pve qm shutdown 9770 --timeout 180$' "$STUB_LOG"
}

@test "snapshot never overwrites: an existing name is refused, a new one is taken with its description quoted" {
    run vm snapshot --pve pve --vmid 9770 --snapshot clean-a
    [ "$status" -eq 1 ]; [[ "$output" == *"already exists"* ]]
    ! grep -q ' qm snapshot ' "$STUB_LOG"
    run vm snapshot --pve pve --vmid 9770 --snapshot clean-b --description 'key and second NIC'
    echo "$output"; [ "$status" -eq 0 ]
    grep -qF "pve qm snapshot 9770 clean-b --description 'key and second NIC'" "$STUB_LOG"
    run vm snapshot --pve pve --vmid 9770 --snapshot clean-c --description 'x; reboot'
    [ "$status" -eq 1 ]; [[ "$output" == *"--description"* ]]
}

@test "the script holds no command that destroys a VM, a disk or a snapshot" {
    run grep -nE 'qm (destroy|delsnapshot|unlink)|pct destroy|lvremove|zfs destroy' "$SCRIPT"
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run them to see them fail.**

Run: `KT bats tests/harness.bats`
Expected: every test `not ok` (the script does not exist).

- [ ] **Step 3: Write `harness/r770-staging-vm.sh`.**

```bash
#!/usr/bin/env bash
#
# r770-staging-vm.sh — drive the Proxmox VM that stands in for the R770 during
# a rehearsal. Runs on the OPERATOR'S machine: neither the staging host nor the
# R770. Every change to the VM is one `qm` command sent over ssh to the
# hypervisor; nothing here destroys a VM, a disk or a snapshot.
#
#   r770-staging-vm.sh status    --pve H --vmid N
#   r770-staging-vm.sh rollback  --pve H --vmid N --snapshot NAME        (GATED: discards the VM's state)
#   r770-staging-vm.sh start     --pve H --vmid N
#   r770-staging-vm.sh stop      --pve H --vmid N
#   r770-staging-vm.sh snapshot  --pve H --vmid N --snapshot NAME [--description TEXT]
#
#   --pve H        the hypervisor's ssh host (key login; never a password)
#   --vmid N       the VM
#   --yes / --non-interactive / --dry-run   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# Nothing is defaulted: the VM, the hypervisor and the snapshot are arguments
# the operator takes from `status` and `qm list`, never names this script picks.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

PVE=""; VMID=""; SNAP=""; DESC=""
usage() { usage_from_header 3; exit 0; }

need_arg() {  # need_arg <flag> <value> — die naming the flag when the value is empty
    [ -n "$2" ] || die "$SUB needs $1"
}
valid() {  # valid <flag> <value> <regex> — die when a given value is not of the expected shape
    [ -z "$2" ] && return 0
    [[ "$2" =~ $3 ]] || die "$1 '$2' is not acceptable (expected $3)"
}
pve()     { ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" "$@"; }          # reads
pve_run() { run ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" "$@"; }      # changes; honours --dry-run
vm_state() { pve qm status "$VMID" 2>/dev/null | awk '/^status:/ { print $2 }'; }
snap_exists() {  # snap_exists <name>
    pve qm listsnapshot "$VMID" 2>/dev/null \
        | awk -v n="$1" '{ for (i = 1; i <= NF; i++) if ($i == n) f = 1 } END { exit !f }'
}
state_or_die() {
    STATE=$(vm_state)
    [ -n "$STATE" ] || die "cannot read VM $VMID on $PVE — is the ssh host right, and does the VM exist?"
}

cmd_status() {
    state_or_die
    printf 'vm %s on %s: %s\n' "$VMID" "$PVE" "$STATE"
    pve qm listsnapshot "$VMID"
    pve qm config "$VMID" | grep -E '^(memory|parent|net[0-9]+|ipconfig[0-9]+):'
    return 0
}

rb_current()  { printf 'vm %s is %s\n' "$VMID" "$STATE"; pve qm listsnapshot "$VMID"; }
rb_proposed() { printf 'qm rollback %s %s — disk, config and NICs return to that snapshot\n' "$VMID" "$SNAP"; }
cmd_rollback() {
    need_arg --snapshot "$SNAP"; state_or_die
    snap_exists "$SNAP" || die "VM $VMID has no snapshot '$SNAP' (see: status)"
    gate "roll VM $VMID back to $SNAP" rb_current rb_proposed \
        "none — everything written to the VM since '$SNAP' is lost; take a snapshot first to keep it"
    pve_run qm rollback "$VMID" "$SNAP" || die "qm rollback failed — read the line above; the VM may be locked"
    if [ "$DRY" = "1" ]; then note "DRY-RUN: VM $VMID would be rolled back to $SNAP"
    else pass "VM $VMID rolled back to $SNAP"; fi
    footer "rollback"
}

cmd_start() {
    state_or_die
    if [ "$STATE" = "running" ]; then pass "VM $VMID already running"; footer "start"; fi
    pve_run qm start "$VMID" || die "qm start failed"
    if [ "$DRY" = "1" ]; then note "DRY-RUN: VM $VMID would be started"; else pass "VM $VMID started"; fi
    footer "start"
}

cmd_stop() {
    state_or_die
    if [ "$STATE" = "stopped" ]; then pass "VM $VMID already stopped"; footer "stop"; fi
    pve_run qm shutdown "$VMID" --timeout 180 || die "qm shutdown failed or timed out — the guest did not power off"
    if [ "$DRY" = "1" ]; then note "DRY-RUN: VM $VMID would be shut down"; else pass "VM $VMID shut down"; fi
    footer "stop"
}

cmd_snapshot() {
    need_arg --snapshot "$SNAP"; state_or_die
    snap_exists "$SNAP" && die "snapshot '$SNAP' already exists on VM $VMID — snapshots are never overwritten; choose another name"
    if [ -n "$DESC" ]; then pve_run qm snapshot "$VMID" "$SNAP" --description "'$DESC'" || die "qm snapshot failed"
    else pve_run qm snapshot "$VMID" "$SNAP" || die "qm snapshot failed"; fi
    if [ "$DRY" = "1" ]; then note "DRY-RUN: snapshot $SNAP would be taken"; else pass "snapshot $SNAP taken of VM $VMID ($STATE)"; fi
    footer "snapshot"
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)     usage ;;
        --pve)         PVE="${2:-}"; shift ;;
        --vmid)        VMID="${2:-}"; shift ;;
        --snapshot)    SNAP="${2:-}"; shift ;;
        --description) DESC="${2:-}"; shift ;;
        -*)            common_flag "$1" || die "unknown option: $1 (try --help)" ;;
        *)             die "unexpected argument: $1 (try --help)" ;;
    esac
    shift
done
case "$SUB" in -h|--help|help|"") usage ;; esac
SELF="r770-staging-vm"
valid --pve "$PVE" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
valid --vmid "$VMID" '^[0-9]+$'
valid --snapshot "$SNAP" '^[A-Za-z][A-Za-z0-9_-]*$'
valid --description "$DESC" '^[A-Za-z0-9 ._,-]+$'
kit_init "r770-staging-vm"
case "$SUB" in
    status|rollback|start|stop|snapshot)
        need_arg --pve "$PVE"; need_arg --vmid "$VMID"; "cmd_$SUB" ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
```

```bash
git add harness/r770-staging-vm.sh tests/harness.bats
git update-index --chmod=+x harness/r770-staging-vm.sh
```

- [ ] **Step 4: Run the suite and shellcheck.**

Run: `KT bats tests/harness.bats` — Expected: all `ok`.
Run: `KT shellcheck -x harness/r770-staging-vm.sh` — Expected: no output, exit 0.

shellcheck reports style and info findings too, and the lint gate fails on any output: fix what it names rather than silence it.

- [ ] **Step 5: Commit.**

Run: `KT ./tests/run.sh` — Expected: exit 0.

```bash
git commit -m "harness: r770-staging-vm.sh — status, gated rollback, start, stop, snapshot; never destroys

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: `airgap`, `wait-ssh`, `tunnel`

**Files:**
- Modify: `harness/r770-staging-vm.sh`
- Modify: `tests/harness.bats`

**Interfaces:**
- Consumes: Task 2's `pve`, `pve_run`, `valid`, `need_arg`, `state_or_die`, the argument loop.
- Produces: `airgap on|off --pve H --vmid N --wan-net netN --mgmt-host H --probe IP:PORT`; `wait-ssh <seconds> --mgmt-host H`; `tunnel --mgmt-host H --local-port N`.

- [ ] **Step 1: Add the failing tests** to the end of `tests/harness.bats`:

```bash
AG=(--pve pve --vmid 9770 --wan-net net0 --mgmt-host guest --probe 192.0.2.1:80)

@test "airgap needs the NIC, the guest and the probe, and refuses a probe that is not address:port" {
    run vm airgap on --pve pve --vmid 9770 --mgmt-host guest --probe 192.0.2.1:80
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --wan-net"* ]]
    run vm airgap on --pve pve --vmid 9770 --wan-net net0 --probe 192.0.2.1:80
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --mgmt-host"* ]]
    run vm airgap on --pve pve --vmid 9770 --wan-net net0 --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --probe"* ]]
    run vm airgap on --pve pve --vmid 9770 --wan-net net0 --mgmt-host guest --probe 'example.com:80'
    [ "$status" -eq 1 ]; [[ "$output" == *"--probe"* ]]
    run vm airgap sideways "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"on or off"* ]]
    ! grep -q ' qm set ' "$STUB_LOG"
}

@test "airgap on sets link_down on the named NIC only, and passes when the guest's probe fails" {
    PROBE_RC=1 run vm airgap on "${AG[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0,link_down=1$' "$STUB_LOG"
    grep -q '^net1: virtio=BC:24:11:00:00:02,bridge=vmbr9$' "$QM_CONFIG"
    [[ "$output" == *"PASS  "*"link_down"* && "$output" == *"PASS  "*"cannot reach 192.0.2.1:80"* ]]
}

@test "airgap on FAILs when the guest can still reach out" {
    PROBE_RC=0 run vm airgap on "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"still reaches 192.0.2.1:80"* ]]
}

@test "airgap on FAILs, never passes, when the guest cannot be asked" {
    GUEST_RC=255 PROBE_RC=1 run vm airgap on "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"probe was not run"* ]]
}

@test "airgap on twice sets nothing the second time; airgap off strips the flag and wants the probe to succeed" {
    PROBE_RC=1 vm airgap on "${AG[@]}" >/dev/null
    : > "$STUB_LOG"
    PROBE_RC=1 run vm airgap on "${AG[@]}"
    [ "$status" -eq 0 ]; [[ "$output" == *"already link-down"* ]]
    ! grep -q ' qm set ' "$STUB_LOG"
    PROBE_RC=0 run vm airgap off "${AG[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0$' "$STUB_LOG"
    PROBE_RC=1 run vm airgap off "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"cannot reach"* ]]
}

@test "airgap --dry-run changes nothing and claims nothing" {
    run vm airgap on "${AG[@]}" --dry-run
    [ "$status" -eq 0 ]; [[ "$output" == *"DRY-RUN:"*"link_down=1"* ]]
    [[ "$output" != *"PASS  "* ]]
    ! grep -q ' qm set ' "$STUB_LOG"
}

@test "wait-ssh passes when the guest answers and fails when the time runs out" {
    GUEST_RC=0 run vm wait-ssh 0 --mgmt-host guest
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "*"guest answers"* ]]
    GUEST_RC=255 run vm wait-ssh 0 --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"did not answer within 0 s"* ]]
    run vm wait-ssh soon --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"seconds"* ]]
}

@test "tunnel forwards a loopback port to the guest's 443 and nothing else" {
    run vm tunnel --mgmt-host guest --local-port 8443 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN:"*"-N"*"127.0.0.1:8443:127.0.0.1:443"*"guest"* ]]
    run vm tunnel --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --local-port"* ]]
}
```

- [ ] **Step 2: Run them to see them fail.**

Run: `KT bats tests/harness.bats`
Expected: Task 2's tests `ok`; the eight new ones `not ok` ("unknown subcommand" or "unknown option").

- [ ] **Step 3: Implement.** In `harness/r770-staging-vm.sh`:

Add to the usage header, after the `snapshot` line:

```bash
#   r770-staging-vm.sh airgap on|off --pve H --vmid N --wan-net netN --mgmt-host G --probe IP:PORT
#   r770-staging-vm.sh wait-ssh SECONDS --mgmt-host G
#   r770-staging-vm.sh tunnel    --mgmt-host G --local-port N           (foreground; Ctrl-C ends it)
```

and, after the `--vmid N` line:

```bash
#   --wan-net netN the VM's internet-facing NIC, as `status` names it; airgap sets it link-down
#   --mgmt-host G  the guest's ssh host, reached on a NIC airgap does not touch
#   --probe IP:PORT an outside address the guest reaches when it is NOT air-gapped
```

and, before the "Nothing is defaulted" paragraph:

```bash
# airgap proves what it did: the flag is read back from the VM's config, and
# the probe is run INSIDE the guest. On: the probe must fail. Off: it must
# succeed. A guest that cannot be asked is a FAIL, never a pass.
```

Change the variable line to:

```bash
PVE=""; VMID=""; SNAP=""; DESC=""; WAN_NET=""; MGMT=""; PROBE=""; LPORT=""
```

Add after `cmd_snapshot`:

```bash
guest() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$MGMT" "$@"; }
net_value() { pve qm config "$VMID" | sed -n "s/^${WAN_NET}: //p"; }

cmd_airgap() {
    local want="${ARGS[0]:-}" cur new ip port now
    case "$want" in on|off) ;; *) die "airgap needs on or off" ;; esac
    need_arg --wan-net "$WAN_NET"; need_arg --mgmt-host "$MGMT"; need_arg --probe "$PROBE"
    cur=$(net_value)
    [ -n "$cur" ] || die "VM $VMID has no $WAN_NET (see: status)"
    [[ "$cur" =~ ^[A-Za-z0-9=:,._-]+$ ]] || die "$WAN_NET's value '$cur' holds a character this script will not send through a shell"
    if [ "$want" = "on" ]; then
        case "$cur" in
            *link_down=1*) note "$WAN_NET already link-down" ;;
            *) pve_run qm set "$VMID" "--$WAN_NET" "${cur},link_down=1" || die "qm set failed" ;;
        esac
    else
        new=${cur//,link_down=1/}
        if [ "$new" = "$cur" ]; then note "$WAN_NET already link-up"
        else pve_run qm set "$VMID" "--$WAN_NET" "$new" || die "qm set failed"; fi
    fi
    if [ "$DRY" = "1" ]; then
        if [ "$want" = "on" ]; then note "DRY-RUN: $WAN_NET would be link-down; nothing was probed"
        else note "DRY-RUN: $WAN_NET would be link-up; nothing was probed"; fi
        footer "airgap $want"
    fi

    now=$(net_value)
    if [ "$want" = "on" ]; then
        case "$now" in *link_down=1*) pass "$WAN_NET has link_down=1 in VM $VMID's config" ;;
                       *) fail "$WAN_NET does not show link_down=1 after qm set" ;; esac
    else
        case "$now" in *link_down=1*) fail "$WAN_NET still shows link_down=1 after qm set" ;;
                       *) pass "$WAN_NET has no link_down in VM $VMID's config" ;; esac
    fi

    ip=${PROBE%:*}; port=${PROBE##*:}
    if ! guest true; then
        fail "guest $MGMT did not answer — the probe was not run, so the air gap is unproven"
    elif guest "timeout 5 bash -c 'exec 3<>/dev/tcp/${ip}/${port}'"; then
        if [ "$want" = "on" ]; then fail "guest still reaches $PROBE — the air gap is NOT in effect"
        else pass "guest reaches $PROBE"; fi
    else
        if [ "$want" = "on" ]; then pass "guest cannot reach $PROBE"
        else fail "guest cannot reach $PROBE although $WAN_NET is link-up"; fi
    fi
    footer "airgap $want"
}

cmd_wait_ssh() {
    local secs="${ARGS[0]:-}" deadline
    [[ "$secs" =~ ^[0-9]+$ ]] || die "wait-ssh needs a number of seconds"
    need_arg --mgmt-host "$MGMT"
    deadline=$((SECONDS + secs))
    while :; do
        if guest true 2>/dev/null; then pass "guest answers on $MGMT"; footer "wait-ssh"; fi
        [ "$SECONDS" -ge "$deadline" ] && break
        sleep 5
    done
    fail "guest $MGMT did not answer within $secs s"
    footer "wait-ssh"
}

cmd_tunnel() {
    need_arg --mgmt-host "$MGMT"; need_arg --local-port "$LPORT"
    note "https on 127.0.0.1:$LPORT -> $MGMT's 443; Ctrl-C ends it"
    run ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -L "127.0.0.1:${LPORT}:127.0.0.1:443" "$MGMT"
}
```

In the argument loop: add `ARGS=()` on the line before `while`, replace the `*) die "unexpected argument: …" ;;` line with `*)             ARGS+=("$1") ;;`, and add before the `-*)` line:

```bash
        --wan-net)     WAN_NET="${2:-}"; shift ;;
        --mgmt-host)   MGMT="${2:-}"; shift ;;
        --probe)       PROBE="${2:-}"; shift ;;
        --local-port)  LPORT="${2:-}"; shift ;;
```

Add after the existing `valid` lines:

```bash
valid --wan-net "$WAN_NET" '^net[0-9]+$'
valid --mgmt-host "$MGMT" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
valid --probe "$PROBE" '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$'
valid --local-port "$LPORT" '^[0-9]{2,5}$'
```

Replace the final `case` with:

```bash
case "$SUB" in
    status|rollback|start|stop|snapshot)
        need_arg --pve "$PVE"; need_arg --vmid "$VMID"; "cmd_$SUB" ;;
    airgap)   need_arg --pve "$PVE"; need_arg --vmid "$VMID"; cmd_airgap ;;
    wait-ssh) cmd_wait_ssh ;;
    tunnel)   cmd_tunnel ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
```

- [ ] **Step 4: Run the suite and shellcheck.**

Run: `KT bats tests/harness.bats` — Expected: all `ok`.
Run: `KT shellcheck -x harness/r770-staging-vm.sh` — Expected: no output.

- [ ] **Step 5: Commit.**

Run: `KT ./tests/run.sh` — Expected: exit 0.

```bash
git add harness/r770-staging-vm.sh tests/harness.bats
git commit -m "harness: airgap by link-down, proven from inside the guest; wait-ssh; tunnel

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Wire `harness/` into the gate and the docs; the record format

**Files:**
- Modify: `tests/lint.bats`, `tests/references.bats`, `README.md`, `tests/README.md`, `.claude/settings.json`
- Create: `docs/rehearsals/README.md`

- [ ] **Step 1: Extend the lint suite first (it must fail if the harness regresses).** In `tests/lint.bats`:

Replace

```bash
    run shellcheck -x scripts/*.sh scripts/lib/*.sh tests/run.sh
```
with
```bash
    run shellcheck -x scripts/*.sh scripts/lib/*.sh harness/*.sh tests/run.sh
```

Replace `for f in scripts/r770-*.sh; do` (the `--help` test) with `for f in scripts/r770-*.sh harness/r770-*.sh; do`.

Replace `for f in scripts/*.sh scripts/lib/*.sh staging/*.sh tests/run.sh; do` (the parse test) with `for f in scripts/*.sh scripts/lib/*.sh staging/*.sh harness/*.sh tests/run.sh; do`.

Replace `for f in scripts/*.sh staging/*.sh tests/run.sh; do` (the executable test) with `for f in scripts/*.sh staging/*.sh harness/*.sh tests/run.sh; do`.

- [ ] **Step 2: Extend the path checks.** In `tests/references.bats`:

Replace `'(?<![\w/.-])(scripts|config|docs|tests|staging)/[A-Za-z0-9_./-]+'` with `'(?<![\w/.-])(scripts|config|docs|tests|staging|harness)/[A-Za-z0-9_./-]+'`.

Replace `for f in scripts/*.sh staging/*.sh tests/run.sh; do [ -x "$f" ]` with `for f in scripts/*.sh staging/*.sh harness/*.sh tests/run.sh; do [ -x "$f" ]`.

Replace `'(?<![\w/.-])(scripts|staging)/r770-[a-z-]+\.sh'` with `'(?<![\w/.-])(scripts|staging|harness)/r770-[a-z-]+\.sh'`.

- [ ] **Step 3: The record format.** Create `docs/rehearsals/README.md`:

```markdown
# Rehearsal records

One file per rehearsal: `<date>-<name>.md`. A record is the claim; the
transcripts are the evidence, and they stay out of git. Nothing is written
here without the transcript that shows it.

## What every record holds

1. **Header** — date, VM (hypervisor and id), bundle id, kit commit (the
   bundle's `kit/KIT_COMMIT`), who ran it.
2. **Stand-ins** — everything that differs from the real R770, each with why:
   the media, the storage volumes, where the bundle was cut, anything
   pre-installed.
3. **Steps** — one row per step:

   | Step | Expected | Observed | Verdict | Transcript |
   |---|---|---|---|---|

   Verdict is `PASS`, `WARN`, `FAIL` or `SKIP`. `Transcript` is the file name
   under the evidence archive. A step with no transcript has no verdict.
4. **Findings** — each WARN and FAIL: the one hypothesis, the one change, the
   commit, the bundle the fix first shipped in, the rerun's verdict.
5. **Not exercised** — what this rehearsal did not prove, by name.
6. **Evidence** — where the archive of `r770-evidence/` and the run
   directories is kept.

Screenshots sit in a directory beside the record, named for it. Look at each
before committing: none may show a credential.

Driving the VM: `harness/r770-staging-vm.sh`.
```

- [ ] **Step 4: README rows and the `allow` entry.**

In `README.md`, add after the `staging/` row of "What's here":

```markdown
| `harness/r770-staging-vm.sh` | Rehearsals only, run on the operator's machine: drives the Proxmox VM that stands in for the R770 through `qm` over ssh — `status`, `rollback` (**gated**), `start`, `stop`, `snapshot` (never overwrites), `airgap on|off` (the internet NIC link-down, proven by a probe from inside the guest), `wait-ssh`, `tunnel`. Destroys nothing; every name is an argument |
| `docs/rehearsals/` | One record per rehearsal: bundle, kit commit, stand-ins, a verdict per step with its transcript's name |
```

In `tests/README.md`, add after the `wan.bats` row:

```markdown
| `harness.bats` | `harness/r770-staging-vm.sh` with `ssh` stubbed: required arguments and their shapes, the rollback gate, dry-run, idempotent start/stop, a snapshot never overwritten, no destroying command in the script, `airgap` failing when the guest still reaches out or cannot be asked, `wait-ssh` timing out, the tunnel bound to loopback |
```

In `.claude/settings.json`, add after the `"Bash(./scripts/r770-e2e.sh:*)",` line, with the same indentation:

```json
      "Bash(./harness/r770-staging-vm.sh:*)",
```

- [ ] **Step 5: Run the gate.**

Run: `KT ./tests/run.sh`
Expected: exit 0. `lint.bats` and `references.bats` now cover `harness/`; a failure there names the file.

- [ ] **Step 6: Commit.**

```bash
git add tests/lint.bats tests/references.bats README.md tests/README.md .claude/settings.json docs/rehearsals/README.md
git commit -m "harness: under the lint and path gates; README rows; docs/rehearsals record format

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: `harness/r770-site-shot.ps1` — one page, one screenshot

Operator-PC only. It is PowerShell because the operator PC is Windows and the DevTools protocol needs a WebSocket client; it has no bats suite, and the rehearsal record says so. It is proven in Task 9 by its first use (`docs.lab`, no login).

**Files:**
- Create: `harness/r770-site-shot.ps1`

**Interfaces:**
- Produces: `pwsh harness/r770-site-shot.ps1 -Browser <exe> -TunnelPort <n> -Url https://<name>.lab:<n>/<path> -Out <absolute.png> [-AuthFile <file holding user:password>] [-WaitSeconds <n>]`. Prints one JSON line: `{"status":<http status>,"title":"...","url":"..."}`.

- [ ] **Step 1: Write the script.**

```powershell
#Requires -Version 7
<#
r770-site-shot.ps1 - one screenshot of one lab page through the rehearsal tunnel.
Operator PC only. Starts a private headless browser whose resolver maps the
three .lab names to 127.0.0.1, so the system hosts file is never edited.

  -Browser     path to msedge.exe or chrome.exe
  -TunnelPort  the local port `r770-staging-vm.sh tunnel` listens on
  -Url         https://malcolm.lab:<port>/..., gns3.lab or docs.lab only
  -Out         absolute path of the PNG to write
  -AuthFile    optional: a file holding user:password on one line. It is sent
               as a Basic Authorization header; the value never reaches a
               command line, the output, or the screenshot's file name.

Certificate errors are ignored here on purpose: the certificate is checked
separately, with a TLS client against the lab CA.
Prints {"status":..,"title":..,"url":..} for the page it captured.
#>
param(
    [Parameter(Mandatory)][string]$Browser,
    [Parameter(Mandatory)][int]$TunnelPort,
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Out,
    [string]$AuthFile,
    [int]$WaitSeconds = 10
)
$ErrorActionPreference = 'Stop'
$names = 'malcolm.lab', 'gns3.lab', 'docs.lab'
$target = [uri]$Url
if ($target.Scheme -ne 'https' -or $names -notcontains $target.Host -or $target.Port -ne $TunnelPort) {
    throw "Url must be https://<$($names -join '|')>:$TunnelPort/..."
}
if (-not [IO.Path]::IsPathRooted($Out)) { throw "-Out must be an absolute path" }
if (-not (Test-Path -LiteralPath $Browser)) { throw "no browser at $Browser" }

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start(); $debugPort = $listener.LocalEndpoint.Port; $listener.Stop()
$profileDir = Join-Path ([IO.Path]::GetTempPath()) ("r770-shot-" + [guid]::NewGuid().ToString('N'))
$rules = ($names | ForEach-Object { "MAP $_ 127.0.0.1" }) -join ', '
$browserArgs = @(
    '--headless=new', "--remote-debugging-port=$debugPort", "--user-data-dir=`"$profileDir`"",
    "--host-resolver-rules=`"$rules`"", '--ignore-certificate-errors', '--window-size=1440,900',
    '--no-first-run', '--disable-extensions', 'about:blank'
)
$proc = Start-Process -FilePath $Browser -ArgumentList $browserArgs -PassThru
$ws = $null
$script:cdpId = 0

function Invoke-Cdp([string]$Method, [hashtable]$Params = @{}) {
    $script:cdpId++
    $json = @{ id = $script:cdpId; method = $Method; params = $Params } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $none = [Threading.CancellationToken]::None
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $none).GetAwaiter().GetResult()
    $buffer = [byte[]]::new(1048576)
    while ($true) {
        $stream = [IO.MemoryStream]::new()
        do {
            $part = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $none).GetAwaiter().GetResult()
            $stream.Write($buffer, 0, $part.Count)
        } until ($part.EndOfMessage)
        $reply = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
        if ($reply.id -eq $script:cdpId) {
            if ($reply.error) { throw "${Method}: $($reply.error.message)" }
            return $reply.result
        }
    }
}

try {
    $page = $null
    foreach ($try in 1..30) {
        try {
            $page = Invoke-RestMethod "http://127.0.0.1:$debugPort/json/list" | Where-Object type -eq 'page' | Select-Object -First 1
        } catch { $page = $null }
        if ($page) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $page) { throw "the browser's debugging port did not answer" }

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $null = Invoke-Cdp 'Network.enable'
    if ($AuthFile) {
        $pair = (Get-Content -LiteralPath $AuthFile -Raw).Trim()
        if ($pair -notmatch '^[^:]+:.+$') { throw "AuthFile does not hold user:password" }
        $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
        $null = Invoke-Cdp 'Network.setExtraHTTPHeaders' @{ headers = @{ Authorization = "Basic $basic" } }
    }
    $null = Invoke-Cdp 'Page.navigate' @{ url = $Url }
    Start-Sleep -Seconds $WaitSeconds
    $expr = "JSON.stringify({status:(performance.getEntriesByType('navigation')[0]||{}).responseStatus,title:document.title,url:location.href})"
    $info = Invoke-Cdp 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true }
    $shot = Invoke-Cdp 'Page.captureScreenshot' @{ format = 'png' }
    [IO.File]::WriteAllBytes($Out, [Convert]::FromBase64String($shot.data))
    $info.result.value
}
finally {
    if ($ws) { $ws.Dispose() }
    if ($proc -and -not $proc.HasExited) { & taskkill /PID $proc.Id /T /F *> $null }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Prove it parses and refuses a foreign URL** (no tunnel needed).

Run (PowerShell): `pwsh -NoProfile -File harness/r770-site-shot.ps1 -Browser "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" -TunnelPort 8443 -Url https://example.com:8443/ -Out C:\Temp\x.png`
Expected: an error containing `Url must be https://<malcolm.lab|gns3.lab|docs.lab>:8443/...`; no browser window; no `x.png`.

- [ ] **Step 3: Add its README row** after the `harness/r770-staging-vm.sh` row:

```markdown
| `harness/r770-site-shot.ps1` | Rehearsals only, operator PC (PowerShell): one screenshot of one `.lab` page through the harness tunnel, in a private headless browser whose resolver maps the three names to loopback — the hosts file is never edited. An optional auth file supplies the login without it reaching a command line. No bats suite; proven by use in the rehearsal record |
```

- [ ] **Step 4: Commit.**

Run: `KT ./tests/run.sh` — Expected: exit 0.

```bash
git add harness/r770-site-shot.ps1 README.md
git commit -m "harness: r770-site-shot.ps1 — one lab page, one screenshot, no hosts-file edit

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: One-time Proxmox preparation

A rehearsal task: every step's output is saved under `~/r770-rehearsals/<date>-prep/` on the operator PC. `VM="./harness/r770-staging-vm.sh"` and `PV="--pve proxmox --vmid 9770"` below; run from the repo root in Git Bash, with `KIT_EVIDENCE_DIR=~/r770-rehearsals/<date>-prep`.

| Change | Undo |
|---|---|
| bridge `vmbr9770`, `192.168.97.1/24`, no ports | `ssh proxmox ifdown vmbr9770`, `ssh proxmox rm /etc/network/interfaces.d/vmbr9770` |
| VM 9770 `net1` on it, `ipconfig1` static | `ssh proxmox qm set 9770 --delete net1,ipconfig1` |
| VM 9770 `sshkeys` → the operator key | `ssh proxmox qm set 9770 --sshkeys /root/r770-staging-previous.pub` (saved in step 2) |
| VM 9770 memory 16384 in the new snapshot (the old snapshot's config has 8192) | `ssh proxmox qm set 9770 --memory 8192` |
| snapshot `clean-<date>` | left in place; `clean-2026-09-24` is untouched |
| VM 9100 shut down | `ssh proxmox qm start 9100` |

- [ ] **Step 1: Record the starting state.**

```bash
mkdir -p ~/r770-rehearsals/$(date +%F)-prep
ssh proxmox qm config 9770 > ~/r770-rehearsals/$(date +%F)-prep/qm-config-before.txt
ssh proxmox qm list        > ~/r770-rehearsals/$(date +%F)-prep/qm-list-before.txt
$VM status $PV
```
Expected: VM 9770 `stopped`, snapshot `clean-2026-09-24` listed.

- [ ] **Step 2: Save the previous key on the host; make the operator key.**

```bash
grep '^sshkeys:' ~/r770-rehearsals/$(date +%F)-prep/qm-config-before.txt | sed 's/^sshkeys: //' | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))' > ~/r770-rehearsals/$(date +%F)-prep/r770-staging-previous.pub
scp ~/r770-rehearsals/$(date +%F)-prep/r770-staging-previous.pub proxmox:/root/r770-staging-previous.pub
[ -f ~/.ssh/r770-staging_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C "r770-staging-operator-$(date +%F)" -f ~/.ssh/r770-staging_ed25519
scp ~/.ssh/r770-staging_ed25519.pub proxmox:/root/r770-staging-operator.pub
```
(If `python3` is not on the PC's PATH, run that one pipeline through `wsl -e`.)

- [ ] **Step 3: The bridge.** Write this to `~/r770-rehearsals/<date>-prep/vmbr9770`:

```
auto vmbr9770
iface vmbr9770 inet static
    address 192.168.97.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```

```bash
ssh proxmox ip -br addr                     # confirm once more: nothing on 192.168.97.0/24
scp ~/r770-rehearsals/$(date +%F)-prep/vmbr9770 proxmox:/etc/network/interfaces.d/vmbr9770
ssh proxmox ifup vmbr9770
ssh proxmox ip -br addr show vmbr9770
```
Expected: `vmbr9770 ... 192.168.97.1/24`. `ifup` is used, not `ifreload -a`, so no other interface's `post-up` rules rerun.

- [ ] **Step 4: Free the memory.**

```bash
ssh proxmox qm shutdown 9100 --timeout 180
ssh proxmox qm status 9100
```
Expected: `status: stopped`.

- [ ] **Step 5: Roll back to the old clean snapshot** (the VM holds October's leftover state).

```bash
$VM rollback $PV --snapshot clean-2026-09-24
```
Read the gate's current/proposed/rollback; answer `y`. Expected: `PASS  VM 9770 rolled back to clean-2026-09-24`.

- [ ] **Step 6: Memory, second NIC, key.**

```bash
ssh proxmox qm set 9770 --memory 16384
ssh proxmox qm set 9770 --net1 virtio,bridge=vmbr9770
ssh proxmox qm set 9770 --ipconfig1 ip=192.168.97.70/24
ssh proxmox qm set 9770 --sshkeys /root/r770-staging-operator.pub
$VM status $PV
```
Expected: `memory: 16384`, a `net1:` line on `vmbr9770`, `ipconfig1: ip=192.168.97.70/24`.

- [ ] **Step 7: The operator PC's SSH entry.** Append to `~/.ssh/config`:

```
Host r770-staging
    HostName 192.168.97.70
    User ubuntu
    IdentityFile ~/.ssh/r770-staging_ed25519
    IdentitiesOnly yes
    ProxyJump proxmox
    UserKnownHostsFile ~/.ssh/known_hosts_r770-staging
    StrictHostKeyChecking accept-new
```

- [ ] **Step 8: Boot and reach it.**

```bash
$VM start $PV
$VM wait-ssh 300 --mgmt-host r770-staging
```
Expected: `PASS  guest answers on r770-staging`.

If it times out, cloud-init did not apply the new key or address. One hypothesis at a time:
- address: `ssh proxmox qm guest cmd 9770 network-get-interfaces` — is `192.168.97.70` there?
- key: push it through the guest agent, then retry `wait-ssh`:
  `ssh proxmox "qm guest exec 9770 --pass-stdin 1 -- tee -a /home/ubuntu/.ssh/authorized_keys" < ~/.ssh/r770-staging_ed25519.pub`

- [ ] **Step 9: Look at the guest.**

```bash
ssh r770-staging "ip -br addr"
ssh r770-staging "free -g"
ssh r770-staging "lsb_release -ds"
ssh r770-staging "docker --version"
ssh r770-staging "df -h /"
```
Expected: two NICs (one DHCP address on `192.168.4.0/22`, one `192.168.97.70/24`); about 15 GiB of memory; Ubuntu 24.04; Docker present; a root filesystem near 400 G. Note the two NIC names — `<wan-if>` (the DHCP one) and `<mgmt-if>` — for Task 8.

- [ ] **Step 10: Prove the air gap mechanism on the real VM.** Discover a probe address; never invent one:

```bash
ssh r770-staging "getent ahostsv4 archive.ubuntu.com"
```
Take the first address as `<probe-ip>`. Then:

```bash
AG="--wan-net net0 --mgmt-host r770-staging --probe <probe-ip>:80"
$VM airgap on  $PV $AG      # expected: PASS link_down=1, PASS guest cannot reach; exit 0
$VM airgap off $PV $AG      # expected: PASS no link_down, PASS guest reaches; exit 0
```
A FAIL either way is a finding in the harness: fix it test-first under Task 3's suite before going on.

- [ ] **Step 11: The new clean snapshot.**

```bash
$VM stop $PV
$VM snapshot $PV --snapshot clean-$(date +%F) --description "clean-2026-09-24 plus operator key, mgmt NIC on vmbr9770, 16 GB"
$VM start $PV
$VM wait-ssh 300 --mgmt-host r770-staging
$VM status $PV
```
Expected: both `clean-2026-09-24` and `clean-<date>` listed.

- [ ] **Step 12: Note the prep** in `~/r770-rehearsals/<date>-prep/NOTES.md`: the table at the top of this task with each row's actual result, `<probe-ip>`, the NIC names. No commit — this feeds the acceptance record's Stand-ins section.

---

### Task 7: The suite on the VM, then the cut

Evidence directory: `~/r770-rehearsals/<date>-acceptance/` on the operator PC. Long commands run detached on the VM and write a log; poll the log, do not hold an SSH session open.

- [ ] **Step 1: Send the branch to the VM** (the VM holds no GitHub credential).

```bash
ssh r770-staging "git init -q --bare /home/ubuntu/kit.git"
git push ssh://r770-staging/home/ubuntu/kit.git finish-rehearsals
ssh r770-staging "git clone -q -b finish-rehearsals /home/ubuntu/kit.git /home/ubuntu/sim-lab-basic"
ssh r770-staging "git -C /home/ubuntu/sim-lab-basic rev-parse HEAD"
git rev-parse HEAD
```
Expected: the two commit ids are equal. Record it as `<kit-commit>`.

- [ ] **Step 2: The offline suite, on Ubuntu 24.04's own shellcheck and bats.**

```bash
ssh r770-staging "sudo apt-get update -qq"
ssh r770-staging "sudo apt-get install -y -qq bats shellcheck"
ssh r770-staging "cd /home/ubuntu/sim-lab-basic && ./tests/run.sh > /home/ubuntu/suite.log 2>&1; echo exit=\$?"
ssh r770-staging "grep -c '^not ok' /home/ubuntu/suite.log"
```
Expected: `exit=0`, `0`. Anything else: `ssh r770-staging "grep -A12 '^not ok' /home/ubuntu/suite.log"`, fix test-first on the PC, `KT ./tests/run.sh`, commit, push to `kit.git`, `git -C ... pull` on the VM, rerun. Nothing below starts on a red suite. These two packages are a stand-in to record.

- [ ] **Step 3: The storage stand-ins, before Docker holds anything from the cut.** `scripts/r770-import-bundle.sh`'s `LVS` names the directories `preflight` requires as mount points; read it rather than trust this list:

```bash
ssh r770-staging "grep -n '^LVS=' /home/ubuntu/sim-lab-basic/scripts/r770-import-bundle.sh"
```
Expected today: `/var/lib/docker /data/pcap /data/index /data/staging /srv/vms /srv/gns3 /srv/work /srv/backup`. Add `/var/lib/containerd` (where the image store really writes; the `storage` step measures it).

Write `~/r770-rehearsals/<date>-acceptance/standin-volumes.sh` on the PC, with the list as read above:

```bash
#!/usr/bin/env bash
# Rehearsal stand-in for the R770's storage layout: one sparse loop-mounted
# ext4 per required mount point. NOT kit code; recorded in the rehearsal record.
set -euo pipefail
sizes=(
    "/var/lib/docker:120G" "/var/lib/containerd:120G" "/data/pcap:40G" "/data/index:40G"
    "/data/staging:80G" "/srv/vms:20G" "/srv/gns3:20G" "/srv/work:10G" "/srv/backup:10G"
)
systemctl stop docker.socket docker containerd
mkdir -p /var/lib/lab-volumes
for e in "${sizes[@]}"; do
    d=${e%%:*}; s=${e##*:}; n=$(echo "${d#/}" | tr / -)
    img=/var/lib/lab-volumes/$n.img
    [ -f "$img" ] || { truncate -s "$s" "$img"; mkfs.ext4 -q -F "$img"; }
    mkdir -p "$d"
    grep -q " $d ext4 " /etc/fstab || echo "$img $d ext4 loop,nofail 0 0" >> /etc/fstab
    findmnt -n "$d" >/dev/null || mount "$d"
done
systemctl start containerd docker
findmnt -t ext4 -o TARGET,SOURCE,SIZE | grep -E 'lab-volumes|loop'
```

```bash
scp ~/r770-rehearsals/$(date +%F)-acceptance/standin-volumes.sh r770-staging:/home/ubuntu/standin-volumes.sh
ssh r770-staging "sudo bash /home/ubuntu/standin-volumes.sh"
ssh r770-staging "docker info --format '{{.DockerRootDir}} {{.Driver}}'"
```
Expected: nine loop mounts listed; Docker answers. The files are sparse: the sizes are ceilings, and the VM's real disk bounds the total — watch `df -h /` during the cut.

- [ ] **Step 4: What does the builder want?**

```bash
ssh r770-staging "cd /home/ubuntu/sim-lab-basic && ./staging/r770-build-bundle.sh --help"
ssh r770-staging "cd /home/ubuntu/sim-lab-basic && ./staging/r770-staging-preflight.sh; echo exit=\$?"
```
Expected: preflight `exit=0` or `exit=2`. Each WARN is dispositioned in the record. `exit=1` is a finding: read it, fix the host condition it names (not the script), rerun.

- [ ] **Step 5: First pass of the cut — the long one.**

```bash
ssh r770-staging "cd /home/ubuntu/sim-lab-basic && nohup env KIT_SRC_ROOT=/home/ubuntu/sim-lab-basic ./staging/r770-build-bundle.sh --yes --bundle-dir /home/ubuntu/bundles/bundle-\$(date +%Y%m%d) > /home/ubuntu/cut-1.log 2>&1 < /dev/null &"
```
Poll every 15–20 minutes, not more often:

```bash
ssh r770-staging "tail -n 5 /home/ubuntu/cut-1.log; pgrep -f r770-build-bundle.sh > /dev/null && echo RUNNING || echo ENDED; df -h / | tail -1"
```
When `ENDED`: `ssh r770-staging "tail -n 40 /home/ubuntu/cut-1.log"`.
Expected: the fetch completed; the gate reports the one known WARN, `gns3/appliances/ holds only README.txt`, and the script's exit is 2 (or 1 if `--strict` turns that WARN into a failure — either is the expected shape for a first pass with nothing staged). A fetch failure is resumable: rerun the same command.

- [ ] **Step 6: Stage the manual category with a SYNTHETIC placeholder** (spec D6), then the second pass regenerates the manifest over it.

```bash
ssh r770-staging "ls -la /home/ubuntu/bundles/"
ssh r770-staging "sudo sh -c 'echo SYNTHETIC-placeholder-rehearsal-cut-not-for-transfer > /home/ubuntu/bundles/<bundle>/gns3/appliances/SYNTHETIC-appliance.qcow2'"
ssh r770-staging "cd /home/ubuntu/sim-lab-basic && nohup env KIT_SRC_ROOT=/home/ubuntu/sim-lab-basic ./staging/r770-build-bundle.sh --yes --bundle-dir /home/ubuntu/bundles/<bundle> > /home/ubuntu/cut-2.log 2>&1 < /dev/null &"
```
`<bundle>` is the directory name the `ls` shows. Poll as in step 5 (this pass skips completed items).
Expected in `cut-2.log`: `RESULT: PASS`, script exit 0.

```bash
ssh r770-staging "cat /home/ubuntu/bundles/<bundle>/kit/KIT_COMMIT"
```
Expected: `<kit-commit>` from step 1. A mismatch is a FAIL: the bundle does not carry the commit under test.

- [ ] **Step 7: Keep the logs.**

```bash
scp r770-staging:/home/ubuntu/suite.log r770-staging:/home/ubuntu/cut-1.log r770-staging:/home/ubuntu/cut-2.log ~/r770-rehearsals/$(date +%F)-acceptance/
ssh r770-staging "du -sh /home/ubuntu/bundles/<bundle>"
```

---

### Task 8: The installer acceptance

`BK=/srv/bundles/<bundle>/kit/scripts` (after import). `EV=/home/ubuntu/r770-evidence`. Every kit command on the VM is run as `sudo KIT_EVIDENCE_DIR=$EV <cmd>` from `/home/ubuntu`.

- [ ] **Step 1: The media** — a loop image, so the kit's `gate` mounts it like real transfer media.

```bash
ssh r770-staging "b=/home/ubuntu/bundles/<bundle>; sz=\$(( \$(du -sm \$b | cut -f1) * 11 / 10 + 1024 )); sudo truncate -s \${sz}M /data/staging/media.img && sudo mkfs.ext4 -q -F /data/staging/media.img && sudo mkdir -p /mnt/media && sudo mount -o loop /data/staging/media.img /mnt/media && sudo cp -a \$b /mnt/media/ && sudo umount /mnt/media && echo MEDIA-BUILT"
```
Expected: `MEDIA-BUILT`.

- [ ] **Step 2: Make the VM look like the R770.** Empty image stores (so `load` is really exercised), no kit checkout, no build copy of the bundle.

```bash
ssh r770-staging "sudo systemctl stop docker.socket docker containerd && sudo umount /var/lib/docker /var/lib/containerd && sudo mkfs.ext4 -q -F /var/lib/lab-volumes/var-lib-docker.img && sudo mkfs.ext4 -q -F /var/lib/lab-volumes/var-lib-containerd.img && sudo mount /var/lib/docker && sudo mount /var/lib/containerd && sudo systemctl start containerd docker && docker images -q | wc -l"
ssh r770-staging "sudo rm -rf /home/ubuntu/sim-lab-basic /home/ubuntu/kit.git /home/ubuntu/bundles"
ssh r770-staging "ls /home/ubuntu; df -h / /data/staging"
```
Expected: `0` images; no `sim-lab-basic`, `kit.git` or `bundles` in the home directory. (`sudo rm -rf` here names three absolute paths under `/home/ubuntu`; check each before pressing enter.)

- [ ] **Step 3: Snapshot the cut**, so a failed install can be retried without another download.

```bash
$VM stop $PV
$VM snapshot $PV --snapshot cut-$(date +%F) --description "bundle on loop media, stand-in volumes, empty image stores, no kit checkout"
$VM start $PV
$VM wait-ssh 300 --mgmt-host r770-staging
ssh r770-staging "findmnt -t ext4 -o TARGET | grep -c -E '/data|/srv|/var/lib/(docker|containerd)'"
```
Expected: `9` — the stand-in volumes came back from `/etc/fstab`.

- [ ] **Step 4: Attach the media and discover its device** — never assume the name.

```bash
ssh r770-staging "sudo losetup -f --show /data/staging/media.img"
ssh r770-staging "lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -E 'loop'"
```
Record the printed `/dev/loopN` as `<dev>`.

- [ ] **Step 5: Air gap on.**

```bash
$VM airgap on $PV --wan-net net0 --mgmt-host r770-staging --probe <probe-ip>:80
```
Expected: two PASS lines, exit 0. Nothing below runs unless this passed.

- [ ] **Step 6: Step 0 of the runbook — verify from the media, with the bundle's own verifier.**

```bash
ssh r770-staging "sudo mount -o ro <dev> /mnt/media && sudo /mnt/media/<bundle>/r770-bundle.sh verify --strict /mnt/media/<bundle>; echo exit=\$?"
```
Expected: `RESULT: PASS`, `exit=0`. (If `verify` wants its arguments in another order, its `--help` says; use that.)

- [ ] **Step 7: `discover`.**

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence /mnt/media/<bundle>/kit/scripts/r770-install.sh discover; echo exit=\$?"
ssh r770-staging "sudo cat /etc/lab/install.conf.template"
```
Expected: the host's disks, NICs, addresses, bridges and mounts; a template whose every value is empty.

- [ ] **Step 8: `install.conf`, filled by hand from what `discover` printed.** The `wizard` needs a terminal; it is recorded under "Not exercised" (it has `tests/install.bats`). Write `~/r770-rehearsals/<date>-acceptance/install.conf` with exactly the keys the template has, using:

```
MEDIA=/mnt/media
DEVICE=<dev>
CAPTURE_IFS=lab_mirror0
LAB_BRIDGE=br-lab
MGMT_IF=<mgmt-if>
MGMT_CIDR=192.168.97.0/24
VALIDATE_AREAS=network capture gns3 storage portal airgap
```
Leave `BUNDLE` and `INDEX_PATTERN` as the template has them unless `plan` asks for a value. `<mgmt-if>` is the NIC holding `192.168.97.70` in `discover`'s output.

```bash
scp ~/r770-rehearsals/$(date +%F)-acceptance/install.conf r770-staging:/home/ubuntu/install.conf
ssh r770-staging "sudo install -m 0600 -o root -g root /home/ubuntu/install.conf /etc/lab/install.conf"
```

- [ ] **Step 9: `plan`.**

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence /mnt/media/<bundle>/kit/scripts/r770-install.sh plan > /home/ubuntu/plan.log 2>&1; echo exit=\$?"
ssh r770-staging "grep -E '^(PASS|WARN|FAIL|SKIP)|GATE|READY' /home/ubuntu/plan.log"
```
Read the whole of `plan.log` once: every gate's current/proposed/rollback. A FAIL is a finding — one change at a time. The storage check refusing the image store means a stand-in volume is too small: enlarge that one image (`truncate`, `resize2fs`), record it, rerun `plan`.

- [ ] **Step 10: `run --yes`.**

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence nohup /mnt/media/<bundle>/kit/scripts/r770-install.sh run --yes > /home/ubuntu/run-1.log 2>&1 < /dev/null &"
```
Poll every 10–15 minutes:

```bash
ssh r770-staging "grep -E '^== |INSTALLED|refused or failed|step .* finished' /home/ubuntu/run-1.log | tail -n 8; pgrep -f r770-install.sh > /dev/null && echo RUNNING || echo ENDED"
```
Expected at the end: the hand-off line (the installer re-executing from `/srv/bundles/<bundle>/kit`), then `INSTALLED`, with the e2e report showing every scenario the bundle can run as proven. `ssh r770-staging "ls /home/ubuntu/r770-evidence"` shows `install-<host>-<ts>.md`.

On `NOT INSTALLED`: read the named step's transcript; one hypothesis; one change. A kit defect: fix test-first on the PC, `KT ./tests/run.sh`, commit; then `$VM airgap off`, `$VM rollback $PV --snapshot clean-<date>`, and redo Task 7 from step 1 (the stand-ins and the fetch repeat; record the re-cut). A host condition (a stand-in too small, a missing group): fix that one thing and rerun the local copy with `run --yes --from <step>`.

- [ ] **Step 11: Re-entry proof.**

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence nohup /srv/bundles/<bundle>/kit/scripts/r770-install.sh run --yes > /home/ubuntu/run-2.log 2>&1 < /dev/null &"
```
Watch for the malcolm step to begin, then interrupt:

```bash
ssh r770-staging "grep -c -i 'malcolm' /home/ubuntu/run-2.log"
ssh r770-staging "sudo pkill -INT -f r770-install.sh; sleep 5; tail -n 5 /home/ubuntu/run-2.log"
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence /srv/bundles/<bundle>/kit/scripts/r770-install.sh status"
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence nohup /srv/bundles/<bundle>/kit/scripts/r770-install.sh run --yes --from malcolm > /home/ubuntu/run-3.log 2>&1 < /dev/null &"
```
Poll `run-3.log` as in step 10. Expected: `INSTALLED`. Then:

```bash
ssh r770-staging "sudo umount /mnt/media && echo UNMOUNTED"
```
Expected: `UNMOUNTED`.

- [ ] **Step 12: Archive the evidence; snapshot the installed lab.**

```bash
ssh r770-staging "sudo tar -C /home/ubuntu -czf /home/ubuntu/acceptance-evidence.tgz r770-evidence plan.log run-1.log run-2.log run-3.log"
scp r770-staging:/home/ubuntu/acceptance-evidence.tgz ~/r770-rehearsals/$(date +%F)-acceptance/
$VM stop $PV
$VM snapshot $PV --snapshot installed-$(date +%F) --description "INSTALLED by r770-install.sh, re-entry proven, air gap on"
$VM start $PV
$VM wait-ssh 300 --mgmt-host r770-staging
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence /srv/bundles/<bundle>/kit/scripts/r770-install.sh status"
```
Expected: every step shown as done; after the reboot Malcolm and GNS3 are up again (`r770-malcolm-deploy.sh status`, `r770-gns3-deploy.sh status` from `$BK`). If a service did not return after the reboot, that is a finding to record — the R770 will reboot too.

- [ ] **Step 13: Write the record.** Create `docs/rehearsals/<date>-installer-acceptance.md` in the shape `docs/rehearsals/README.md` fixes:
  - Header: date; hypervisor `proxmox`, VM 9770; `<bundle>`; `<kit-commit>`.
  - Stand-ins: D6's placeholder; D7 (cut on the same VM: Docker, bats and shellcheck pre-installed, so the gated Docker install reported "already present"); the loop media; the nine sparse loop volumes and their sizes; the image stores emptied before install; `install.conf` filled by hand.
  - Steps: one row each for Task 7 steps 2, 4, 5, 6 and Task 8 steps 5–11, verdicts copied from the transcripts, with the transcript file names inside `acceptance-evidence.tgz`.
  - Findings: each, with its commit.
  - Not exercised: `wizard`; the Docker install from a bare OS; real appliance images; anything `VALIDATE_AREAS` left out.
  - Evidence: `~/r770-rehearsals/<date>-acceptance/` on the operator PC.

Leave the "Site checks" section for Task 9. Do not commit yet.

---

### Task 9: Site checks, with screenshots

`SHOTS="/c/coding stuff/sim-lab-basic/docs/rehearsals/<date>-installer-acceptance"` (a directory beside the record). `EDGE='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'`.

- [ ] **Step 1: Open the tunnel** (in the background; it stays up for this task).

```bash
./harness/r770-staging-vm.sh tunnel --mgmt-host r770-staging --local-port 8443
```
Run it as a background command. Expected: the `+ ssh -N ...` line and no error.

- [ ] **Step 2: The certificate, with a TLS client against the lab CA.** The CA certificate is public material; its key never leaves the VM.

```bash
ssh r770-staging "sudo cat /etc/lab/ca/pki/ca.crt" > ~/r770-rehearsals/$(date +%F)-acceptance/lab-ca.crt
openssl s_client -connect 127.0.0.1:8443 -servername malcolm.lab -CAfile ~/r770-rehearsals/$(date +%F)-acceptance/lab-ca.crt -verify_return_error < /dev/null 2> /dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName
openssl s_client -connect 127.0.0.1:8443 -servername malcolm.lab -CAfile ~/r770-rehearsals/$(date +%F)-acceptance/lab-ca.crt -verify_return_error < /dev/null 2>&1 | grep 'Verify return code'
```
Expected: SANs `DNS:malcolm.lab, DNS:gns3.lab, DNS:docs.lab` (order may differ); the issuer is the lab CA; `Verify return code: 0 (ok)`. If `ca.crt` is elsewhere, `scripts/r770-portal-deploy.sh` names the path.

- [ ] **Step 3: First use of the screenshot helper — `docs.lab`, no login.**

```powershell
New-Item -ItemType Directory -Force "C:\coding stuff\sim-lab-basic\docs\rehearsals\<date>-installer-acceptance" | Out-Null
pwsh -NoProfile -File harness/r770-site-shot.ps1 -Browser $EDGE -TunnelPort 8443 -Url https://docs.lab:8443/ -Out "C:\coding stuff\sim-lab-basic\docs\rehearsals\<date>-installer-acceptance\docs-home.png"
```
Expected: `{"status":200,"title":"<the wiki's title>",...}`. Open the PNG and look: the wiki's home page, styled, with navigation. A blank or error image is a finding in the helper (fix it, commit under Task 5's message style) or in the portal (rerun the portal step).

- [ ] **Step 4: `docs.lab` navigation and search.** From the home page's screenshot, pick one navigation entry and the search URL the theme uses (try `https://docs.lab:8443/search.html?q=ipsec`; if that is 404, the theme searches in-page with `https://docs.lab:8443/?q=ipsec`). Shoot both as `docs-page.png` and `docs-search.png`. Expected: status 200; the page's content; search results listed.

- [ ] **Step 5: `gns3.lab`.**

Shoot `https://gns3.lab:8443/` as `gns3-ui.png`. Expected: the GNS3 web UI (or its login screen) — status 200 after its redirect. The project list is proven on the box, where the credential already lives:

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence /srv/bundles/<bundle>/kit/scripts/r770-scenario.sh list --bundle /srv/bundles/<bundle>"
```
Expected: every scenario listed as runnable.

- [ ] **Step 6: `malcolm.lab` without a login is refused.**

Shoot `https://malcolm.lab:8443/` with no `-AuthFile` as `malcolm-refused.png`. Expected: `"status":401`.

- [ ] **Step 7: The login, never shown.** Build the auth file from the two files on the VM; the output goes to a file, not to the terminal.

```bash
umask 077
A=~/r770-rehearsals/.malcolm-auth
ssh r770-staging "sudo cut -d: -f1 /etc/nginx/lab.htpasswd" | head -n 1 | tr -d '\r\n' > "$A"
printf ':' >> "$A"
ssh r770-staging "sudo cat /etc/lab/secrets/malcolm-admin.pw" | tr -d '\r\n' >> "$A"
wc -c < "$A"
```
Expected: a byte count greater than 10, and nothing else printed. Never `cat` this file. Then, in PowerShell, restrict it: `icacls "$env:USERPROFILE\r770-rehearsals\.malcolm-auth" /inheritance:r /grant:r "$($env:USERNAME):(R,W)"`.

If any of this would put the value on screen, stop: the operator signs in instead, and the record says so (the spec's fallback).

- [ ] **Step 8: `malcolm.lab` logged in.** With `-AuthFile "$env:USERPROFILE\r770-rehearsals\.malcolm-auth"` and `-WaitSeconds 25`, shoot:
  - `https://malcolm.lab:8443/` → `malcolm-home.png` (the landing page; read its links for the next two paths)
  - Dashboards' saved objects (`https://malcolm.lab:8443/dashboards/app/objects`) → `malcolm-saved-objects.png` — expected: the lab's IPsec saved searches by name
  - Arkime sessions (`https://malcolm.lab:8443/arkime/sessions`) → `malcolm-arkime.png` — expected: sessions from the e2e run

Expected: status 200 each. Look at every PNG: the right page, and no credential anywhere in it.

- [ ] **Step 9: Remove the auth file; close the tunnel.**

```bash
rm -f ~/r770-rehearsals/.malcolm-auth && ls -la ~/r770-rehearsals/
```
Expected: `.malcolm-auth` not listed. Stop the background tunnel.

- [ ] **Step 10: Add "Site checks" to the acceptance record** — the spec's table with a verdict, a one-line note and the screenshot's file name per row; the certificate row quotes the SAN line and `Verify return code`. State that `harness/r770-site-shot.ps1` has no bats suite and was proven by these captures.

- [ ] **Step 11: Commit the record and the screenshots.**

Run: `KT ./tests/run.sh` — Expected: exit 0 (`references.bats` reads the record's paths; `no-credentials.bats` reads its text).

```bash
git add docs/rehearsals/
git commit -m "Rehearsal record: installer acceptance on VM 9770 — INSTALLED, re-entry, site checks

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: The IPsec/WAN rehearsal

This is `docs/superpowers/plans/2026-10-07-ipsec-wan-scenarios.md` Task 11, run as written, on the VM as `installed-<date>` left it, air gap on. Open that task and work its checklist line by line; this task fixes only what differs.

**What differs from Task 11's text:**

| Task 11 says | Here |
|---|---|
| a bundle cut "from this kit's commit — `docs/kit-sync.md`" | the bundle from Task 7; `docs/kit-sync.md` is retired |
| write the O3 keys answer, and confirmed carry-backs, into `docs/kit-sync.md` | into the runbook's IPsec & WAN section and `docs/rehearsals/<date>-ipsec-wan.md` |
| scripts run from a kit checkout | `/srv/bundles/<bundle>/kit/scripts/…` (`$BK`), as `sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence-ipsec …` from `/home/ubuntu` |
| H0's `r770-gns3-deploy.sh full` and `r770-malcolm-deploy.sh full` | already done by the installer; H0 is only the `r770-validate.sh` line, `r770-scenario.sh list`, `r770-wan.sh show`, and `command -v tcpdump tshark nsenter tc` |
| the final commit message | this plan's Task 11 commits the docs |

- [ ] **Step 1: H0 — prerequisites.** Run the four H0 checks. Expected: validate all PASS for `network capture gns3`; `s0-w1` and `s1-w1-ss` runnable; every TAP clean; all four tools found. A missing tool is a bundle finding (it must come from the local APT repo, never from upstream — the air gap is on).

- [ ] **Step 2: H1–H7 and the W1 validation**, each line of Task 11 in order, each with its own PASS or FAIL. Two shells means two SSH sessions; captures that must overlap are started detached with `nohup … &` and a `-c` count so they end themselves. For **H6** and carry-in (b) (a real Ctrl-C), send SIGINT to the foreground `record`'s process group from a second session: `ssh r770-staging "sudo pkill -INT -f 'r770-scenario.sh record'"` — and record that it was a signal, not a keyboard.

- [ ] **Step 3: S1** — `up s1-w1-ss`, the SA and `keys.state` check, the negative test, the reference run with `verify`, then `ingest` and `check`, the final-review carry-ins (a)–(d), the flap variant. Follow Task 11's own "if X2 fails / if X5 fails" branches: one hypothesis, one change.

- [ ] **Step 4: A snapshot before anything is changed to fix a finding.**

```bash
$VM stop $PV
$VM snapshot $PV --snapshot ipsec-$(date +%F) --description "after the IPsec and WAN rehearsal runs"
$VM start $PV
$VM wait-ssh 300 --mgmt-host r770-staging
```

- [ ] **Step 5: Archive.**

```bash
mkdir -p ~/r770-rehearsals/$(date +%F)-ipsec-wan
ssh r770-staging "sudo tar -C / -czf /home/ubuntu/ipsec-evidence.tgz home/ubuntu/r770-evidence-ipsec data/pcap/cases --exclude='*.pcapng'"
scp r770-staging:/home/ubuntu/ipsec-evidence.tgz ~/r770-rehearsals/$(date +%F)-ipsec-wan/
```
The captures stay on the VM (they are large and hold key material under `gt/`); the archive carries the transcripts, `run.conf`, `expected.md`, `events.log`, `capture-stats.txt` and `sha256sums` of each run. Never copy a `gt/` directory into the repo.

- [ ] **Step 6: Write `docs/rehearsals/<date>-ipsec-wan.md`** in the fixed shape: header; stand-ins (as the acceptance record, by reference to it); one row per Task 11 line (H0–H7, W1, S1 up, negative, reference, X9, carry-ins a–d, flap) with expected, observed, verdict, transcript; the measured values (S0 baseline RTT and throughput, the `--impair …@b` direction, the O3 keys answer, X1–X9 with run ids); findings; not exercised. Do not commit yet — Task 11 commits it with the runbook.

---

### Task 11: Write-up, the gate, and the host put back

**Files:**
- Modify: `docs/deployment-runbook.md` (the "IPsec & simulated-WAN scenarios" section; "The installer" section)
- Modify: `README.md` (the sentence "its staging rehearsal pending")
- Commit: `docs/rehearsals/<date>-ipsec-wan.md`

- [ ] **Step 1: The runbook's IPsec & WAN section becomes "as measured".**
  - Heading: `## IPsec & simulated-WAN scenarios (rehearsed <date>)`.
  - The status sentence: `Status: rehearsed <date> on VM 9770, bundle <bundle> — docs/rehearsals/<date>-ipsec-wan.md.` Remove "nothing here has yet run against a real GNS3, tcpdump or Malcolm".
  - Replace each "to be measured" with the measurement (the `@b` direction; the baseline RTT and throughput; whether keys were present) and correct any statement a measurement contradicted.
  - Add the X1–X9 pass table with run ids.
  - Only what a transcript shows. A line that FAILed stays described as failing, with its finding.

- [ ] **Step 2: The installer section** gains one sentence after "The summary lands in …": `Rehearsed <date> on VM 9770: docs/rehearsals/<date>-installer-acceptance.md.`

- [ ] **Step 3: `README.md`** — in the IPsec paragraph, replace "its staging rehearsal pending" with "rehearsed <date> (`docs/rehearsals/<date>-ipsec-wan.md`)". If a Task 11 line FAILed and is still open, say "rehearsed <date>, with open findings" instead.

- [ ] **Step 4: If the rehearsals changed kit code,** every such fix is already committed test-first with a green gate (Tasks 8 and 10). List them in both records' Findings with the bundle each first shipped in. A fix made after the last cut is "not yet in a bundle" — say so.

- [ ] **Step 5: The gate, on both shellchecks.**

Run: `KT ./tests/run.sh` — Expected: exit 0.

The VM is air-gapped and has no kit checkout, so the authoritative Ubuntu 24.04 run happens after step 7 lifts the gap; if the final commit differs from the one Task 7 step 2 ran green, rerun there (push to a fresh `kit.git`, clone, `./tests/run.sh`) before calling the work done.

- [ ] **Step 6: Commit.**

```bash
git add docs/deployment-runbook.md README.md docs/rehearsals/
git commit -m "IPsec & WAN scenarios: staging rehearsal — H1–H7, S0 baseline, S1 reference set; docs as measured

Co-Authored-By: Claude <noreply@anthropic.com>"
```

- [ ] **Step 7: Put the host back.**

```bash
$VM airgap off $PV --wan-net net0 --mgmt-host r770-staging --probe <probe-ip>:80
$VM stop $PV
ssh proxmox qm start 9100
ssh proxmox qm list
$VM status $PV
```
Expected: VM 9770 stopped with snapshots `clean-2026-09-24`, `clean-<date>`, `cut-<date>`, `installed-<date>`, `ipsec-<date>`; VM 9100 running; everything else as `qm-list-before.txt` recorded it. The bridge `vmbr9770`, the VM's second NIC and the operator key stay (Task 6's table says how to undo each).

- [ ] **Step 8: Report to the operator and stop.** State, with the record paths: suite exit code; the bundle id and its verify result; INSTALLED or not, and the re-entry result; each site-check row; each Task 11 line; every open finding; what was not exercised. Ask before `git push` and before opening a PR. Tick the boxes this work closed in `docs/superpowers/plans/2026-10-03-offline-installer.md` Task 13 and `docs/superpowers/plans/2026-10-07-ipsec-wan-scenarios.md` Task 11 only if the operator wants the dated plans edited (the standalone-kit spec's D4 keeps them as written).

---

## Self-review

**Spec coverage.** Purpose 1 (suite green) → Task 7 step 2, Task 11 step 5. Purpose 2 (bundle) → Task 7. Purpose 3 (acceptance) → Task 8. Purpose 4 (site) → Task 9. Purpose 5 (IPsec/WAN) → Task 10. Purpose 6 (records) → Task 4 step 3, Tasks 8, 9, 10. D1/D2 → Tasks 2–4. D3 → Task 3, proven on the VM in Task 6 step 10. D4 → Task 6 steps 2, 6, 7. D5 → Task 4. D6 → Task 7 step 6. D7 → recorded in Task 8 step 13. Components: `tunnel` → Task 3; tests and wiring → Tasks 2–4. One-time Proxmox changes → Task 6 (plus memory, which the old snapshot's config held at 8192 — found while planning, added to the table). The run 1–7 → Tasks 6–11. Site checks: hosts file untouched → Task 5's resolver mapping; the credential → Task 9 steps 7 and 9, with the spec's fallback kept. When something fails → Global Constraints, Task 8 step 10. Known limitation → Task 8 step 13. Done-when → Task 11 step 8.

**Beyond the spec, and why.** `.gitattributes` (Task 1): the Windows checkout's scripts were CRLF and could not run, so the harness could not either. Snapshots `cut-<date>`, `installed-<date>`, `ipsec-<date>`: a retry without a second download; the harness still never deletes one. `harness/r770-site-shot.ps1`: the spec's "browser instance with a host-resolver mapping", made repeatable. The GNS3 row's project list is proven on the box by `r770-scenario.sh list`, with the UI screenshot beside it, so no second credential leaves the VM.

**Placeholder scan.** `<date>`, `<bundle>`, `<dev>`, `<kit-commit>`, `<probe-ip>`, `<wan-if>`, `<mgmt-if>` are values discovered during the run, each with the step that produces it; none is a design gap. Task 10 defers to an existing, approved checklist rather than restating it.

**Name consistency.** Flags `--pve --vmid --snapshot --description --wan-net --mgmt-host --probe --local-port`; functions `need_arg valid pve pve_run vm_state snap_exists state_or_die guest net_value cmd_status cmd_rollback cmd_start cmd_stop cmd_snapshot cmd_airgap cmd_wait_ssh cmd_tunnel`; the stub's environment `QM_CONFIG QM_SNAPS VM_STATE PROBE_RC GUEST_RC` — the same in Tasks 2 and 3 and in the commands of Tasks 6–11.
