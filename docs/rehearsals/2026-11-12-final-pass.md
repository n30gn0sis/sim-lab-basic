# Final pass — 2026-11-12

**Date:** 2026-11-12 (UTC). **VM:** hypervisor `proxmox`, VM 9770
`r770-staging`. **Bundle:** `bundle-20261112`, cut twice that day (see
Findings). **Kit commit under test:** `650be15bd634fe6e8888ca5fbb5370b1f627d27a`
(the second cut's `kit/KIT_COMMIT`). **Run by:** Claude Code, driving the VM
with `harness/r770-staging-vm.sh` from the operator PC.

**Result.** From a host with no Docker, `r770-install.sh run --yes` reported
**INSTALLED** (exit 0) in one run, air gap on, from the media. After a reboot
Malcolm returned unaided and the capture interfaces kept their offloads off.
A re-entry (`run --yes --from malcolm`) reported **INSTALLED** again. This is
the bundle for the R770.

## Stand-ins

| Stand-in | Instead of | Why |
|---|---|---|
| Docker purged in place (packages, stores, `/etc/docker`, the apt source and key, the `docker` group), then verified absent | a host Docker was never installed on | no snapshot of the VM predates Docker; the operator chose the purge over a new VM |
| The bundle was cut on the same VM that then played the R770 | a separate staging host | as on 2026-11-10; `bats` and `shellcheck` stayed installed |
| A loop-mounted ext4 image as the transfer media | a USB disk | the kit's `gate` mounts and verifies it the same way |
| Nine sparse loop-mounted ext4 volumes, sizes as on 2026-11-10 | the R770's logical volumes | `preflight` requires each as its own mount point |
| One extra virtio NIC (`net2`, on the host-only management bridge; `ens20` in the guest) | a physical capture port | the R770 has no TAP or SPAN cabled yet; this is the only place the `capture` step is exercised |
| `install.conf` filled by hand from `discover`'s output; `INDEX_PATTERN` taken from the 2026-11-10 rehearsal's inventory | the `wizard`, and a pattern read after Malcolm is up | the wizard needs a terminal; the pattern cannot be discovered before the stack runs |
| The air gap is the VM's internet NIC set link-down from the hypervisor, proven by a probe before and after | a host with no uplink | management SSH arrives on a second NIC on a host-only bridge |

## Steps

Transcript names are files in the evidence directory, or inside
`final-pass-2-evidence.tgz` (second pass) or `final-pass-1-evidence.tgz`
(first pass) where a row says so.

| Step | Expected | Observed | Verdict | Transcript |
|---|---|---|---|---|
| Offline suite on the VM (Ubuntu's own `shellcheck` and `bats`), kit `aa4da2b` | exit 0 | exit 1: 544 ok, 1 not ok, the lint gate on `scripts/r770-capture-ports.sh` (F1) | FAIL | `suite-1.log` |
| Suite after F1, kit `b0a20fb` | exit 0 | exit 0; 546 ok | PASS | `suite.log` |
| Staging preflight | READY | READY, all checks passed | PASS | `preflight.log` |
| First cut, kit `b0a20fb`, no placeholders | `RESULT: PASS`, seven definitions, commit matches | PASS, exit 0, no WARN, seven definitions each with its image, commit matches | PASS | `cut-1.log` |
| First pass: `plan` on the bare host | no FAIL; SKIP rows naming providers | READY WITH WARNINGS, exit 2: 0 FAIL, 7 SKIP, the import preflight's two first-install warnings | WARN | pass 1: `plan.log` |
| First pass: `run --yes` | INSTALLED | stopped at Malcolm `auth`: the stack's owner is not in the `docker` group (F2) | FAIL | pass 1: `run-1.log` |
| First pass, after `usermod` by hand: `run --yes --from malcolm`, reboot, re-entry | INSTALLED; services return; re-entry INSTALLED | INSTALLED, exit 0; 27 containers healthy unaided; offloads off; re-entry INSTALLED, exit 0 | PASS | pass 1: `run-1b.log`, `reboot-*.log`, `run-2.log` |
| Suite after F2, kit `650be15` | exit 0 | exit 0; 555 ok | PASS | `suite-2.log` |
| Second cut, kit `650be15` | `RESULT: PASS`, commit matches | PASS, exit 0, no WARN, seven definitions, commit matches | PASS | `cut-2.log` |
| Air gap on | probe succeeds before, fails after; NIC shows link-down | 3 checks passed | PASS | `r770-staging-vm-host-*.log` |
| Verify from the media, with the bundle's own verifier | `RESULT: PASS`, exit 0 | PASS, exit 0 | PASS | pass 2: `verify-media.log` |
| `discover` | disks, NICs, addresses, mounts; an empty template | as expected, exit 0; the stand-in port listed, down, no address | PASS | pass 2: `discover.log` |
| `plan` on the bare host (A2) | no FAIL; SKIP rows naming providers; READY WITH WARNINGS on a first install | exit 2: 0 FAIL, 7 SKIP each naming its provider, `malcolm capture: would apply cleanly`, the two first-install warnings | PASS | pass 2: `plan.log` |
| `run --yes` from the media | the Docker gate runs for real; `capture` PASSes the stand-in port; no "definition without image" (A8); INSTALLED | Docker installed from the bundle; the `docker` group gate shown and accepted (F2); `ens20: no address, no master, promiscuous, offloads off`; no definition warning; **INSTALLED**, exit 0; e2e 40 checks passed, all ten scenarios | PASS | pass 2: `run-1.log`, `r770-evidence/install-r770-staging-20261112-151337.md` |
| Reboot, then look before running anything (A10, A11) | Malcolm returns unaided; offloads off on both capture interfaces | 27 containers up at first look, all healthy four minutes later; both `r770-capture-offloads@` units finished; every TSO sub-feature, GSO, GRO off on `lab_mirror0` and `ens20`; both promiscuous, no address | PASS | pass 2: `reboot-state.log`, `reboot-malcolm-status.log` |
| `r770-validate.sh --area network` after the reboot | capture rows PASS for both interfaces | 13 checks passed, 1 skipped (no `--mgmt-if` given) | PASS | pass 2: `reboot-validate-network.log` |
| Re-entry: `run --yes --from malcolm` (A9) | INSTALLED | **INSTALLED**, exit 0; e2e 40 checks passed; no gate reopened | PASS | pass 2: `run-2.log`, `r770-evidence/install-r770-staging-20261112-161507.md` |
| `umount` the media | clean | UNMOUNTED | PASS | (command output) |
| Third pass, late 2026-11-12: the same bundle, from `bare2b-2026-11-12` again, one `run --yes` | INSTALLED | NOT INSTALLED, exit 1: every step clean except e2e, `up bgp` "did not become ready within 120s" (F6) | FAIL | pass 3: `run-manual.log`, `r770-evidence/install-r770-staging-20261112-235603/` |
| Third pass: `run --yes --from e2e`, nothing changed | INSTALLED | **INSTALLED**, exit 0; e2e 40 checks passed | PASS | pass 3: `run-e2e2.log`, `r770-evidence/install-r770-staging-20261113-004909/` |
| The bundle copied to the operator PC and verified there with its own verifier | `RESULT: PASS` | PASS | PASS | (command output) |
| 2026-11-13, browser pane on the operator PC through the harness tunnel and a loopback proxy | each site answers | GNS3's web UI loaded to its login form; Malcolm answered 401 (sign-in left to the operator); the wiki, built locally by the bundle's own MkDocs image, rendered with no build warning | PASS | (screenshots in the session) |

## Findings

| # | Finding | Change | Commit | First bundle | Rerun |
|---|---|---|---|---|---|
| F1 | Ubuntu's `shellcheck` is newer than the operator PC's and reported the two gate callbacks of `scripts/r770-capture-ports.sh` as unreachable: every branch of the script's dispatch ended in an exit | `usage` returns, so the help branch reaches the end of the script; behaviour unchanged, the four help forms pinned by a test | `b0a20fb` | first cut | suite on the VM: PASS |
| F2 | On a host where the kit installs Docker, Malcolm's owner is not in the `docker` group, and the group does not exist before the kit's own `docker` step: a first `run` always stopped at `auth` | `auth` adds the owner at a gate (current, proposed, rollback; membership is root-equivalent); `start` and `stop` still refuse and name `auth` | `fb5fffe` | second cut | one `run --yes` from bare: INSTALLED |
| F3 | `plan` on a first install exits 2 (READY WITH WARNINGS): the import preflight warns that docker is not present yet and that there is no previous bundle | none — the operator's ruling is that this is the expected verdict; the runbook says so | `650be15` (runbook only) | second cut | as expected |
| F4 | After each reboot `systemd-networkd-wait-online` failed after its two-minute timeout, delaying Docker and the offload units by that long | none — the interface it waited for is the one the air gap holds link-down (a stand-in). On the R770: a configured NIC with no cable would do the same; check `systemctl --failed` after the first reboot | — | — | — |
| F5 | `harness/r770-staging-vm.sh snapshot` twice took no snapshot and printed no verdict when `--description` held `;`, `=`, `:` or parentheses | none — `harness/` is frozen; **open**. Plain descriptions work | — | — | — |
| F6 | Third pass: e2e's `up bgp` did not become ready within its 120 s wait; `--from e2e` with no change passed. Once in three installs of this bundle | none — **open** in `docs/backlog.md`; on the R770, rerun `--from e2e` if it recurs | — | — | pass 3: INSTALLED |
| F7 | The lab CA built by `scripts/r770-portal-deploy.sh ca` (easy-rsa defaults) does not mark `basicConstraints` critical; browsers accept it, strict TLS clients reject the chain | none — **open** in `docs/backlog.md` | — | — | — |

Operator slips, recorded because they shaped the snapshots: the snapshot
`bare-2026-11-12` was taken live after `discover` (F5 lost the first attempt);
`bare2-2026-11-12` was taken with Docker still installed (the purge had not
run) and was mislabelled, so it was later deleted;
`bare2b-2026-11-12` is the real start of the second and third passes.

## Not exercised

- `wizard` (needs a terminal; covered by `tests/install.bats`).
- A host Docker was never installed on (the purge is a stand-in).
- A real physical capture port and its link-settle time: the virtio stand-in
  settles faster than a server NIC will. The `capture` step waits a bounded
  time for it; that wait was never the deciding factor here.
- A boot without the air gap's link-down NIC (F4).
- Real licensed appliance images; none are shipped or claimed.
- Signed-in site checks in a browser: on 2026-11-13 the sites were reached
  (see Steps) but no one signed in through Claude.
- `VALIDATE_AREAS` was `network capture gns3 storage portal airgap`, with the
  same SKIPs inside those areas as on 2026-11-10.
- The IPsec and WAN scenario scripts beyond what `e2e` runs; that code is
  frozen.

## Evidence

Operator PC, outside git: `~/r770-rehearsals/2026-11-12-final-pass/`
(`final-pass-3-evidence.tgz`, `final-pass-2-evidence.tgz`,
`final-pass-1-evidence.tgz`, the suite and cut
logs, `preflight.log`, harness transcripts, `install.conf`,
`standin-volumes.sh`) and `~/r770-rehearsals/a11-ethtool-k.txt` (the A11
measurement of 2026-11-11). VM snapshots: `bare-2026-11-12`,
`pass1-2026-11-12`, `bare2b-2026-11-12`, `final-2026-11-12`. The bundle itself is on the VM at `final-2026-11-12`:
`/srv/bundles/bundle-20261112` and the loop media `/data/staging/media.img`.
