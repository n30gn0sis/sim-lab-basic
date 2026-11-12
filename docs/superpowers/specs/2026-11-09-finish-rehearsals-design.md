# Finish the rehearsals: a fresh bundle, the installer acceptance, the IPsec/WAN run

**Date:** 2026-11-09
**Status:** approved design
**Closes:** offline-installer plan Task 13 (`docs/superpowers/plans/2026-10-03-offline-installer.md`)
and IPsec/WAN plan Task 11 (`docs/superpowers/plans/2026-10-07-ipsec-wan-scenarios.md`)
**Seeds:** sub-project C of `docs/superpowers/specs/2026-10-29-standalone-kit-design.md`
(the Proxmox test harness). The full harness, sub-projects B and D, and the
IPsec roadmap IP5–IP9 are out of scope.

## Purpose

Everything built since 2026-10-03 has passed only the offline suite. This work
runs it for real on the staging VM and records the result in this repo:

1. the offline suite green on the commit under test;
2. a bundle cut by the standalone `staging/` pipeline;
3. the installer acceptance rehearsal, ending in INSTALLED;
4. a look at the lab site (`malcolm.lab`, `gns3.lab`, `docs.lab`) in a browser;
5. the IPsec/WAN rehearsal;
6. a home in this repo for rehearsal records.

## Where it runs

| Machine | Role |
|---|---|
| Operator PC (Windows, Git Bash) | runs the harness script; holds the SSH key; takes the screenshots |
| Proxmox host (`ssh proxmox`, node `proxmox`) | hypervisor; SSH jump to the VM |
| VM 9770 `r770-staging` (6 cores, 16 GB, 400 G) | staging host while it has internet, then the R770 stand-in once air-gapped |

As observed 2026-11-09: VM 9770 is stopped with one snapshot,
`clean-2026-09-24`; its only SSH key belonged to LXC 101, which no longer
exists; the host has 29 GB of RAM with 15 GB in use. VM 9100 `gns3` (16 GB
allocated) is shut down while 9770 runs and started again afterwards. Nothing
on the host is deleted.

## Decisions

| # | Decision | Rejected |
|---|---|---|
| D1 | VM tooling is one script, `harness/r770-staging-vm.sh`, run on the operator PC and wrapping `ssh <host> qm …` | running it on the hypervisor (the kit would have to be copied there); a hand-typed command list (not repeatable) |
| D2 | A new top-level `harness/` directory: the operator PC is a third machine, neither the staging host nor the R770 | putting it in `staging/` (which means "runs on the staging host") |
| D3 | The air gap is the internet-facing NIC set link-down from the hypervisor; management SSH arrives on a second NIC on a host-only bridge with no physical port | the Proxmox firewall (enabling it risks locking the host out); rules inside the guest (the guest could undo them) |
| D4 | The VM gets a new SSH key generated on the operator PC, set through cloud-init; the operator PC reaches the VM with the Proxmox host as jump | password login; the guest agent only |
| D5 | Rehearsal records live in `docs/rehearsals/`, one file per rehearsal; transcripts stay out of git | records in another repo (the old plans wrote them to `simlab-build`) |
| D6 | The licensed GNS3 appliances are synthetic placeholders at the manual pause, as in September; every scenario uses bundled container images only | sourcing real appliance images |
| D7 | The bundle is cut on the same VM that then plays the R770 | a separate builder VM (left to sub-project C) |

## Components

### `harness/r770-staging-vm.sh`

Subcommands: `status`, `rollback`, `start`, `stop`, `wait-ssh`, `snapshot`,
`airgap on|off`, `tunnel`.

- `--vmid`, `--pve` (the SSH host) and, where used, `--snapshot`, `--wan-net`
  (the NIC `airgap` toggles) and `--mgmt-host` (the VM's SSH name) are
  required arguments. Nothing is defaulted and no placeholder is executed.
- It sources `scripts/lib/common.sh` for `KIT_DRY_RUN`, the
  `PASS`/`WARN`/`FAIL`/`SKIP` lines, the `0 / 2 / 1` exit and the evidence
  transcript.
- `rollback` discards the VM's state, so it goes through `gate()`: current
  (the VM's status and parent snapshot), proposed, rollback ("none — state
  after the snapshot is lost"), and it needs `--yes` or a `y`.
- `airgap on` sets `link_down=1` on the named NIC, then proves it: `qm config`
  shows the flag, and an outbound probe run in the guest fails. `airgap off`
  reverses it and proves the probe succeeds. A probe that contradicts the
  requested state is a FAIL.
- `wait-ssh <seconds>` polls until the VM answers or the time runs out.
- `tunnel --local-port <n>` forwards a local port to the VM's 443 for the
  site checks and stays in the foreground.
- It never destroys a VM, a disk or a snapshot.

### Tests and wiring

- `tests/harness.bats`: `ssh` stubbed through `tests/helpers/stubs.bash`;
  covers the required-argument refusals, the rollback gate (stops under
  `--non-interactive` without `--yes`), dry-run printing every command and
  running none, `airgap on` failing when the probe still succeeds, and
  `wait-ssh` timing out.
- `tests/run.sh` shellchecks `harness/*.sh` with no exclusions.
- A row in `README.md`; an `allow` entry in `.claude/settings.json`.

### `docs/rehearsals/`

`docs/rehearsals/README.md` fixes the record's shape:

- date, VM, bundle id, kit commit (`kit/KIT_COMMIT`);
- stand-ins (D6, D7, the loop-device media, anything else that differs from
  the R770);
- one row per step: expected, observed, verdict, the transcript's file name;
- WARN dispositions and findings, each with what was changed;
- where the evidence archive (`r770-evidence/`, run directories) is kept.

Records: `docs/rehearsals/<date>-installer-acceptance.md` and
`docs/rehearsals/<date>-ipsec-wan.md`. The site checks' screenshots sit in a
directory beside the acceptance record, after a look that none shows a
credential.

## One-time Proxmox changes

Each is gated by asking the operator if it is not in this table.

| Change | Undo |
|---|---|
| A host-only bridge with no physical port, on a subnet chosen after reading the host's existing networks, the host holding one address on it | remove the stanza, `ifreload -a` |
| VM 9770: a second NIC on that bridge, static address through cloud-init | remove the NIC and its `ipconfig` |
| VM 9770: `sshkeys` replaced with a key generated on the operator PC; an SSH config entry on the operator PC with `ProxyJump proxmox` | restore the previous `sshkeys` value, recorded before the change |
| A new clean snapshot after the two changes above; `clean-2026-09-24` kept | delete the new snapshot |
| VM 9100 shut down for the duration | start it |

## The run

1. **Prepare.** Branch; commit the harness, its tests and wiring, and the
   pending `CLAUDE.md` trim. Roll back to the new clean snapshot, start,
   `wait-ssh`. Push the branch to a bare repository on the VM over SSH and
   clone it there, so the VM holds no GitHub credential.
2. **Offline suite.** On the VM, install `shellcheck` and `bats`, run
   `./tests/run.sh`. Expected: exit 0. Nothing proceeds on anything else.
3. **Cut.** `KIT_SRC_ROOT=<the clone> ./staging/r770-build-bundle.sh`;
   placeholders at the manual pause (D6). Expected: `RESULT: PASS` from
   `verify --strict`, and `kit/KIT_COMMIT` equal to the branch head.
4. **Acceptance** (Task 13 steps 5–7).
   - Remove the kit clone; put the bundle on loop-device ext4 media; the
     containerd storage stand-in as Task 13 records it; `airgap on`.
   - Only the bundle's commands: `r770-bundle.sh verify`, then
     `kit/scripts/r770-install.sh` `discover`, `wizard`, `plan`, `run --yes`,
     with `VALIDATE_AREAS` limited to what a VM can prove.
   - Expected: the hand-off line, then INSTALLED, with every scenario the
     bundle can run judged in Malcolm by `scripts/r770-e2e.sh`.
   - Re-entry: interrupt a second `run --yes` during `malcolm`, then
     `run --yes --from malcolm` from the local copy → INSTALLED; `umount` the
     media clean.
   - Snapshot `installed-<date>`.
5. **Site checks** (below).
6. **IPsec/WAN** (Task 11, as written): H0–H7, the W1 validation, S1 up, the
   negative test, the reference run with `verify` and `ingest`, the
   final-review carry-ins, the flap variant. Where Task 11 writes an answer
   to the retired `docs/kit-sync.md`, it goes to the runbook's IPsec section
   and the rehearsal record instead.
7. **Write up.** The two records; the runbook's IPsec & WAN section rewritten
   "as measured" (status, baseline RTT and throughput, the keys answer, the
   `--impair` direction, the X1–X9 table with run ids); the installer section
   gains its rehearsal date. `./tests/run.sh` green on the final commit.
   `airgap off`, VM 9770 stopped, VM 9100 started. Pushing and opening a PR
   wait for the operator's yes.

## Site checks

After INSTALLED and before the IPsec run. `r770-validate.sh`'s portal area
proves each vhost answers; this proves the pages are the right ones.

**Reach.** `harness/r770-staging-vm.sh tunnel` forwards a local port to the
VM's 443. A browser instance on the operator PC is started with a
host-resolver mapping for the three `.lab` names to that port, so the system
hosts file is not edited.

**Checks,** each with a verdict, a note and a screenshot in the acceptance
record:

| Target | Confirmed |
|---|---|
| Certificate | one certificate, SANs `malcolm.lab`, `gns3.lab`, `docs.lab`, issued by the lab CA generated on the VM (read with a TLS client, not from the browser's warning) |
| `malcolm.lab`, no login | refused (401) |
| `malcolm.lab`, logged in | Dashboards loads; the lab's IPsec saved searches are listed; Arkime shows sessions from the e2e run |
| `gns3.lab` | the GNS3 web UI loads and lists the scenario projects |
| `docs.lab` | the wiki renders; navigation works; search returns results |

**The credential.** Malcolm's login is generated on the VM and is never
printed, pasted into chat, put on a command line, or written into the record.
It is read from its file (`docs/secrets-locations.md`) into a mode-0600
temporary file on the operator PC, handed to the browser from there, and the
file is deleted when the checks end. If that cannot be done without exposing
the value, the logged-in row is done by the operator signing in, and the
record says so.

**A failing page** is a finding: one hypothesis, one change, rerun the
portal step, check again.

## When something fails

- Rule 7: reproduce, read the transcript, one hypothesis, one controlled
  change, rerun `--from <step>`.
- A kit defect is fixed test-first on the branch, with `./tests/run.sh` green
  before the commit. The kit travels in the bundle, so the fix is followed by
  a re-cut (the fetch seeds from the previous bundle) and the affected steps
  rerun. The record lists each fix and the bundle it first appeared in.
- A script's refusal is the finding. No gate is bypassed and no step is
  replaced by hand-typed commands.
- No verdict is written without its transcript.

## Known limitation

D7: Docker and the test tools are on the VM before the installer runs, so the
gated Docker install reports "already present" and is not exercised from a
bare OS. The September rehearsals had the same stand-in. Each record states
it.

## Done when

- `./tests/run.sh` exits 0 on the final commit.
- A bundle cut from that commit passed `verify --strict`.
- `r770-install.sh run` reported INSTALLED and the re-entry proof passed.
- The site checks are in the acceptance record with screenshots, every row
  PASS or a finding with its disposition.
- Every Task 11 line is PASS or a recorded finding with its disposition.
- Both records and the runbook update are committed.
- The Proxmox host is back as it was, plus the changes in "One-time Proxmox
  changes".
