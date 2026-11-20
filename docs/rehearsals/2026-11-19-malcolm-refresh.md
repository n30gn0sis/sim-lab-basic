# Malcolm refresh — 2026-11-19

**Date:** 2026-11-19 (operator PC time; the VM's clock is UTC and reads
2026-11-20 from the install onward). **VM:** hypervisor `proxmox`, VM 9770
`r770-staging`. **Bundle:** `bundle-20261119b`, the second cut of the day (see
Findings). **Kit commit under test:** `1ec5c9979b02369def6d877a4d543aba80cfc4ea`
(the bundle's `kit/KIT_COMMIT`). **Run by:** Claude Code, driving the VM with
`harness/r770-staging-vm.sh` from the operator PC; the operator approved each
rollback, each cut and each `run --yes`.

**Result.** With the Malcolm pin moved to the newest upstream release and
nothing else re-pinned, a fresh bundle installed offline from a bare host:
`r770-install.sh run --yes` reported **INSTALLED** (exit 0) in one run, air gap
on, from the media, and every running Malcolm container carries the new
release's tag. After a reboot Malcolm returned unaided and the capture
interfaces kept their offloads off. A re-entry (`run --yes --from malcolm`)
reported **INSTALLED** again. The first cut of the day was wrong and its gate
did not see it (F8); the fix shipped in the second cut.

The design and the plan: `docs/superpowers/specs/2026-11-19-malcolm-refresh-offline-test-design.md`,
`docs/superpowers/plans/2026-11-19-malcolm-refresh-offline-test.md`.

## Stand-ins

| Stand-in | Instead of | Why |
|---|---|---|
| One VM as both hosts: cut on snapshot `clean-2026-11-09`, then rolled back to `bare2b-2026-11-12` to install; the bundle carried between the two through the operator PC as a tar | a staging host and a separate R770 | one VM is available; the rollback puts the install on a host the cut never touched |
| The bare host is `bare2b-2026-11-12`: Docker purged in place and verified absent on 2026-11-12 | a host Docker was never installed on | as in `docs/rehearsals/2026-11-12-final-pass.md` |
| The fetch was seeded from `bundle-20261112` | a full download | shorter cut; every reuse is hash-checked against the old manifest and logged. This is what exposed F8 |
| A loop-mounted ext4 image as the transfer media, the one built on 2026-11-12, with the old bundle removed and the new one unpacked onto it | a USB disk | the kit's `gate` mounts and verifies it the same way |
| Nine sparse loop-mounted ext4 volumes, as left in the bare snapshot | the R770's logical volumes | `preflight` requires each as its own mount point |
| One extra virtio NIC (`net2`; `ens20` in the guest) | a physical capture port | the only place the `capture` step is exercised |
| `install.conf` reused unchanged from the final pass after each value was checked against this run's `discover` output | the `wizard` | the wizard needs a terminal |
| The air gap is the VM's internet NIC set link-down from the hypervisor | a host with no uplink | management SSH arrives on a second NIC on a host-only bridge |
| Nothing was staged in the manual category | licensed appliance images | none are shipped or claimed |

## Steps

Transcript names are files in the evidence directory, or inside
`malcolm-refresh-evidence.tgz` where a row says "archive". Harness transcripts
are `r770-staging-vm-Samael-<timestamp>.log`.

| Step | Expected | Observed | Verdict | Transcript |
|---|---|---|---|---|
| Offline suite on the operator PC after the pin move, kit `779c59f` | exit 0 | exit 0; 555 ok | PASS | (command output; not kept) |
| Roll back to `clean-2026-11-09`, start | rolled back; guest answers | 3 checks passed | PASS | harness `162241`, `162244`, `162246` |
| `airgap off` | no link-down; probe succeeds | the snapshot's NIC was already up; 2 checks passed | PASS | harness `162427` |
| The seed, `bundle-20261112`, verified on the staging host with its own verifier | `RESULT: PASS` | PASS | PASS | (command output; not kept) |
| Staging preflight | READY | READY, all nine checks passed | PASS | `preflight.log` |
| First cut, kit `779c59f`, seeded | `RESULT: PASS`; the Malcolm image list carries the new release only | `RESULT: PASS`, exit 0, but all 23 image references carry the previous release's tag, inside a tarball named for the new one (F8) | FAIL | `cut-1.log`, `seeded.txt` |
| Suite after F8, kit `1ec5c99` | exit 0 | exit 0; 556 ok | PASS | (command output; not kept) |
| Second cut, kit `1ec5c99`, seeded, to `bundle-20261119b` | `RESULT: PASS`; commit matches; new release only | PASS, exit 0, no WARN; commit matches; 23 image references, all the new release's tag; 81 files reused, none under `malcolm/` | PASS | `cut-2.log`, `seeded-2.txt` |
| The bundle copied to the operator PC and verified there with its own verifier | `RESULT: PASS` | PASS, 1811 entries | PASS | `verify-pc.log` |
| Roll back to `bare2b-2026-11-12`, start; look at the host | no Docker, no `install.conf`, nine volumes, offline | as expected; the probe address unreachable | PASS | harness `191811`, `191816`, `191818`; (host look: command output) |
| The media: old bundle removed, new bundle unpacked, unmounted | only the new bundle on it | `bundle-20261119b` and `lost+found`; 1053 MB left free | PASS | (command output) |
| Snapshot `bare-refresh-2026-11-19` | taken | taken, VM stopped | PASS | harness `192643` |
| `airgap on` | link-down in the live config; the probe fails | both PASS; one WARN: the NIC was already link-down, so no positive control could be run. The same probe had succeeded on this VM at `162427` | WARN | harness `192907` |
| Verify from the media, with the bundle's own verifier | `RESULT: PASS`, exit 0 | PASS, exit 0 | PASS | archive: `verify-media.log` |
| `discover` | disks, NICs, addresses, mounts; an empty template | as expected, exit 0; media on the device the final pass used; `ens20` listed, down, no address | PASS | archive: `discover.log` |
| `plan` on the bare host | READY WITH WARNINGS; no FAIL; only the two first-install warnings | exit 2: 0 FAIL, 7 SKIP each naming its provider, `malcolm capture: would apply cleanly`, the two first-install warnings | PASS | archive: `plan.log` |
| `run --yes` from the media | INSTALLED; e2e 40 checks | **INSTALLED**, exit 0; e2e 40 checks passed, all ten scenarios; no BGP readiness failure (F6 did not recur) | PASS | archive: `run-1.log`, `r770-evidence/install-r770-staging-20261120-003110.md` |
| The running Malcolm | every container on the tag the bundle's image list names | 27 containers running, all on the new release's tag; the list names that one tag | PASS | `malcolm-tags.txt` |
| Reboot, then look before running anything | Malcolm returns unaided; offloads off on both capture interfaces | 27 containers starting at first look two minutes after boot, all 27 healthy about two minutes later; TSO, GSO, GRO off and no address on `lab_mirror0` and `ens20`; one failed unit, `systemd-networkd-wait-online` (final pass F4) | PASS | archive: `reboot-state.log` |
| `r770-validate.sh --area network` after the reboot | capture rows PASS for both interfaces | 8 checks passed, 2 skipped (no `--mgmt-if`, no `--lab-bridge` given) | PASS | archive: `reboot-validate-network.log` |
| Re-entry: `run --yes --from malcolm` from the installed copy | INSTALLED | **INSTALLED**, exit 0; e2e 40 checks passed; the gates it met were shown and accepted again by `--yes` | PASS | archive: `run-2.log`, `r770-evidence/install-r770-staging-20261120-015641.md` |
| `umount` the media | clean | UNMOUNTED | PASS | (command output) |
| Snapshot `refresh-2026-11-19` | taken | taken, VM stopped | PASS | harness `211624`, `211704` |

## What changed in the bundle

Compared with `bundle-20261112`, from the two cut logs and `seeded-2.txt`:

| Content | In `bundle-20261119b` |
|---|---|
| Malcolm install package, compose file, 23 images | moved to the new release; fetched fresh |
| APT set | fetched fresh; 863 packages, was 859 |
| Enrichment data | fetched fresh |
| Docs build image | pulled fresh (never seeded) |
| Ubuntu ISO and its checksums, the two base cloud images | unchanged; reused |
| GNS3 server wheelhouse, the seven appliance definitions and their images | unchanged; reused |
| GNS3 docker-node images, `latest` tags included | unchanged; reused, so not refreshed |
| Docs mirrors | unchanged; reused |
| Manifest | 1811 files, was 1803 |

## Findings

Numbered on from the final pass, which ended at F7.

| # | Finding | Change | Commit | First bundle | Rerun |
|---|---|---|---|---|---|
| F8 | A seeded cut after a Malcolm pin move shipped the previous release's images. The fetch reused `malcolm/docker-compose.yml` from the previous bundle: its name carries no version, so the seed's hash check accepted it. The image list is built from that file, so the 23 old images were pulled and saved under the new release's file name, beside the new release's install package. `verify --strict` passed: every file matched the manifest | the compose file is never seeded; a test in `tests/staging.bats` runs the fetch's own `seed` function and proves it, with a seeded control file beside it | `1ec5c99` | `bundle-20261119b` | second cut: PASS, new release only; installed: INSTALLED |
| F9 | The strict gate cannot see F8's condition: nothing checks that the Malcolm image list, the image tarball and the install package belong to one release | none — **open** in `docs/backlog.md` | — | — | — |

Operator-side slips, recorded because they cost time: the first watcher for
the cut matched its own command line and never returned, so the first cut's
result was read about two hours after it finished; the launch command's SSH
session stayed attached to the detached build until it timed out. Neither
touched the VM's state. Later launches used `setsid` and a pattern that cannot
match itself.

The evidence archive also holds `cut-2.log` and `suite-2.log` dated
2026-11-12: they were in the home directory of the bare snapshot and belong to
the final pass. This rehearsal's `cut-2.log` is the one beside the archive.

## Not exercised

- `wizard` (needs a terminal; covered by `tests/install.bats`).
- A host Docker was never installed on (the purge is a stand-in).
- An unseeded cut. The reused content is byte-identical to `bundle-20261112`,
  which the final pass installed.
- Any pin other than Malcolm's. The Ubuntu ISO, strongSwan and CHR have newer
  upstream releases; they were left for a later cut.
- An upgrade: the new Malcolm was installed on a bare host, not over a lab
  already running the previous release.
- A real physical capture port and its link-settle time.
- A boot without the air gap's link-down NIC (final pass F4).
- Real licensed appliance images; none are shipped or claimed.
- Site checks in a browser, signed in or not.
- `VALIDATE_AREAS` was `network capture gns3 storage portal airgap`, as on
  2026-11-12.
- The Ubuntu ISO's GPG signature check that the builder's closing message asks
  for.

## Evidence

Operator PC, outside git: `~/r770-rehearsals/2026-11-19-malcolm-refresh/`
(`malcolm-refresh-evidence.tgz`, `cut-1.log`, `cut-2.log`, `preflight.log`,
`seeded.txt`, `seeded-2.txt`, `verify-pc.log`, `malcolm-tags.txt`,
`install.conf`, and the harness transcripts). VM snapshots:
`bare-refresh-2026-11-19` (bare, the new bundle on the media, air gap on) and
`refresh-2026-11-19` (installed; the VM was left stopped on it). The bundle:
`C:\Users\temps\r770-bundles\bundle-20261119b.tar` on the operator PC, and on
the VM at `refresh-2026-11-19` under `/srv/bundles/` and on the loop media.
The first cut, `bundle-20261119`, was discarded with the staging state and
must not be used.
