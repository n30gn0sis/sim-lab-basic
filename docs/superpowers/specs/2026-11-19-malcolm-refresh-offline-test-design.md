# Offline deployment test: a fresh bundle with a newer Malcolm

**Date:** 2026-11-19
**Status:** approved design
**Follows:** the final pass (`docs/rehearsals/2026-11-12-final-pass.md`), which
reached INSTALLED from a bare host with `bundle-20261112`.

## Purpose

Prove that the kit can take a version move end to end: change one pin, cut a
new bundle, and install it offline to INSTALLED on a bare host. Every earlier
rehearsal installed the versions the kit was developed against; none has
shown that a moved pin survives the whole path.

The move under test is the Malcolm pin: from the release `bundle-20261112`
carries to the newest upstream release, two releases later. The exact
versions live in the pin block and in the rehearsal's transcripts, not here
(`tests/no-pins.bats`). No other pin moves.

The apt set and the enrichment data are fetched fresh on every cut, so they
will be newer than in `bundle-20261112`. Everything else that the seed can
supply with a matching hash is reused; the record lists what was reused and
what was fetched.

## Where it runs

| Machine | Role |
|---|---|
| Operator PC (WSL, this checkout) | runs `harness/r770-staging-vm.sh` and ssh; holds the bundle between the two halves; keeps the evidence |
| Proxmox host (`ssh proxmox`) | hypervisor; SSH jump to the VM |
| VM 9770 `r770-staging` | staging host while it has internet, then the R770 stand-in once air-gapped |

As observed 2026-11-19 (harness `status`): VM 9770 is stopped on
`final-2026-11-12`, a child of `bare2b-2026-11-12`; `net0` is link-down (air
gap on); `net1` and `net2` are on `vmbr9770`. The snapshots this test uses:

| Snapshot | State | Used for |
|---|---|---|
| `clean-2026-11-09` | Ubuntu 24.04, operator key, Docker CE, no bundle | the cut |
| `bare2b-2026-11-12` | Docker purged, stand-in volumes, `bundle-20261112` on the loop media, air gap on | the install |

The operator PC holds `bundle-20261112.tar` (14.9 GB) in
`C:\Users\temps\r770-bundles`, with 539 GB free.

## Decisions

| # | Decision | Rejected |
|---|---|---|
| 1 | Test a fresh bundle on VM 9770 | re-running `bundle-20261112`; the real R770 |
| 2 | The bundle carries a version move | a same-version re-cut |
| 3 | Malcolm only, to the newest upstream release | moving every pin at once: a failure would have several candidate causes |
| 4 | Cut on `clean-2026-11-09`, carry the bundle off to the PC, roll back to `bare2b-2026-11-12`, carry it on | purging Docker in place after the cut (repeats a hand step); cutting on an installed snapshot (APT already repointed) |
| 5 | Claude drives; the operator approves each gate | the operator typing every command |
| 6 | A refusal is a finding: fix the kit on the branch, re-cut, rerun | recording the failure and stopping |
| 7 | Seed the fetch from `bundle-20261112` | a full download: seeding reuses only files whose hash matches the old manifest, and logs each reuse |

## Operator gates

Claude stops and asks before each of these, every time, including on a
repeat after a fix:

1. each snapshot rollback (it discards the VM's current state);
2. turning the air gap off;
3. starting the cut's download;
4. the installer's `run --yes`.

The kit's own gates are never bypassed. `run --yes` is the installer's
documented consent for its gated steps, given only after `plan` has been
read.

## Procedure

Each step lists what is run, what a pass looks like, and what is kept.

### 1. Branch and pin

- Branch `malcolm-refresh` from `main`.
- Change `MALCOLM_VER` in the pin block of `staging/r770-offline-fetch.sh`.
  Nothing else restates the version.
- `./tests/run.sh` exits 0. Commit.

### 2. Prepare the staging host

- **Gate:** roll back to `clean-2026-11-09`. Start the VM, `wait-ssh`.
- **Gate:** `airgap off`; the harness probe must show the internet is
  reachable.
- Check before going further: at least 150 GB free, Docker answers.

### 3. Cut

- Copy the branch checkout to the VM. Copy `bundle-20261112.tar` to the VM
  and unpack it as the seed.
- Run the staging preflight. Expect no FAIL.
- **Gate:** `KIT_SRC_ROOT=<checkout> SEED_FROM=<old bundle> ./staging/r770-build-bundle.sh`.
- Pass: `RESULT: PASS` from `verify --strict`, exit 0; `BUNDLE_NOTES.md`
  names the new Malcolm version and the branch's commit as the kit; the
  Malcolm image list carries the new version's tags only.
- Kept: the cut log, the preflight log, the list of seeded files.

### 4. Carry off

- Tar the bundle on the VM, copy it to `C:\Users\temps\r770-bundles`.
- Unpack a copy on the PC's Linux filesystem and run the bundle's own
  `r770-bundle.sh verify`. Pass: `RESULT: PASS`.

### 5. Prepare the R770 stand-in

- **Gate:** roll back to `bare2b-2026-11-12`. Start with the air gap still
  on.
- Copy the new bundle to the VM over the management NIC, replace
  `bundle-20261112` on the loop media with it, and verify it from the media
  with its own verifier.
- Confirm the host is bare: no Docker, no `/etc/lab/install.conf`, the eight
  required mount points present.
- Prove the air gap with the harness probe. Snapshot this state with a
  plain-text description (harness finding F5).

### 6. Install

- `<media>/<bundle>/kit/scripts/r770-install.sh discover`.
- Write `/etc/lab/install.conf` from the final pass's copy, with BUNDLE
  changed to the new bundle and every device, interface and bridge value
  checked against this run's `discover` output.
- `plan`. Pass: READY WITH WARNINGS (exit 2) with only the two first-install
  warnings the runbook describes.
- **Gate:** `run --yes`.
- Pass: every step clean through `e2e`, 40 checks across ten scenarios,
  INSTALLED. Malcolm's running containers carry the new version's tags.

### 7. Prove it holds

- Reboot. Malcolm returns without help; the capture port's offloads are
  still off; the capture port has no address and no master.
- Re-enter from the installed copy: `run --yes --from malcolm`. Pass: clean.

### 8. Record

- Snapshot the installed state.
- Archive the VM's `r770-evidence/` and the harness transcripts to
  `~/r770-rehearsals/2026-11-19-malcolm-refresh/` on the PC.
- Write the rehearsal record under `docs/rehearsals/` in the format of the
  final pass: what was run, the results table, each finding, and what
  changed in the unpinned content.
- `./tests/run.sh` green, commit, push, open a draft PR.

## When a step fails

1. Reproduce it and read the transcript under `r770-evidence/`.
2. One hypothesis, one change.
3. If the cause is in the kit: change it on the branch with a test, suite
   green, commit. The installer runs from the bundle's `kit/`, so a kit fix
   needs a re-cut: back to step 2, seeded from the bundle just cut.
4. If the cause is the stand-in or the harness, not the kit: fix that, note
   it in the record, rerun `--from <step>`.
5. Each failure is a numbered finding in the record, with its transcript.

Known and not counted on first sight: the `up bgp` readiness wait (finding
F6) gets one `run --yes --from e2e` rerun before it counts as a failure.

If the new Malcolm changes something the kit's templates or configure step
depend on, that is the finding this test exists to surface. The fix goes
through `config/README.md`'s delta table like any other config change.

## Done

- INSTALLED in one run from the bare snapshot, with the new Malcolm running.
- Reboot and re-entry clean.
- The rehearsal record written from the transcripts.
- A draft PR carrying the pin move, any fixes, and the record.

## Out of scope

- The other pins (the Ubuntu ISO, strongSwan, CHR). They move in a later
  cut.
- The real R770.
- Findings F4, F6 and F7, unless one blocks the run.
- New Proxmox infrastructure or new harness subcommands.

## To settle in the plan

- Whether `clean-2026-11-09` has the disk for the seed, its tar and a new
  bundle together. If not, the seed tar is streamed and unpacked in one
  pass, or seeding is dropped.
- Which files seeding actually covers, read from
  `staging/r770-offline-fetch.sh`.
- How the loop media was built and mounted in `bare2b-2026-11-12`, read from
  the final pass's evidence, and whether it has room for the new bundle.
- Where the manual items of the cut come from, and whether seeding carries
  them.
