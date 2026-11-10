# Installer acceptance — 2026-11-10

**Date:** 2026-11-10 (UTC). **VM:** hypervisor `proxmox`, VM 9770
`r770-staging`. **Bundle:** `bundle-20261110`, cut three times that day (see
Findings). **Kit commit under test:** `15d71135ea23037aa0ff0199d852e16e7c071115`
(the third cut's `kit/KIT_COMMIT`). **Run by:** Claude Code, driving the VM
with `harness/r770-staging-vm.sh` from the operator PC.

**Result.** `r770-install.sh run --yes` reported **INSTALLED** (exit 0) on the
third cut, air gap on, from the media. The re-entry run was interrupted and
resumed as designed but ended **NOT INSTALLED** (exit 2) on one permanent
warning (finding A9, fixed after the cut). `plan` reports NOT READY on a bare
host (finding A2, open).

## Stand-ins

| Stand-in | Instead of | Why |
|---|---|---|
| Three synthetic files in `gns3/appliances/` named for the Cisco, FortiGate and Palo Alto definitions | the licensed appliance images | design decision D6; without them the verdict can never be INSTALLED (finding A8) |
| The bundle was cut on the same VM that then played the R770 (D7) | a separate staging host | Docker, `bats` and `shellcheck` were on the VM before the installer ran, so the gated Docker install reported "already present" |
| A loop-mounted ext4 image as the transfer media | a USB disk | the kit's `gate` mounts and verifies it the same way |
| Nine sparse loop-mounted ext4 volumes (`/var/lib/docker` and `/var/lib/containerd` 120G each, `/data/pcap` and `/data/index` 40G each, `/data/staging` 80G, `/srv/vms` and `/srv/gns3` 20G each, `/srv/work` and `/srv/backup` 10G each) | the R770's logical volumes | `preflight` requires each as its own mount point |
| Image stores emptied (fresh filesystems) before each install | — | so `load` is really exercised |
| `install.conf` filled by hand from `discover`'s output | the `wizard` | the wizard needs a terminal |
| The air gap is the VM's internet NIC set link-down from the hypervisor, proven by a probe before and after | a host with no uplink | management SSH arrives on a second NIC on a host-only bridge |
| The third cut reused the second cut's payload (the builder skips what is present) | a fresh download | only `kit/`, the placeholders and the manifest changed |

## Steps

Transcript names are files in the acceptance evidence directory or inside its `acceptance-evidence.tgz`, unless another archive is named.

| Step | Expected | Observed | Verdict | Transcript |
|---|---|---|---|---|
| Offline suite on the VM (Ubuntu's own `shellcheck` and `bats`) at the kit commit | exit 0 | exit 0; 508 ok, 0 not ok | PASS | `suite-3.log` |
| Staging preflight | READY | READY, all checks passed | PASS | `preflight-3.log` |
| Cut, first pass | strict gate PASS | FAIL (strict): one WARN, the registry has no `alpine-linux` definition | FAIL | `cut-1.log` |
| Cut after fix A1 | `RESULT: PASS` | PASS, exit 0 | PASS | `cut-2.log` |
| Second cut (fixes A3–A7) | `RESULT: PASS`, `kit/KIT_COMMIT` = kit commit | PASS, exit 0, commit matches | PASS | `cut-3.log` |
| Third cut (placeholders staged) | `RESULT: PASS` | first try refused by the staging preflight (could not pull the build image; nothing downloaded); rerun PASS, exit 0, 14 appliance files, commit matches | PASS | `cut-4.log`, `cut-5.log` |
| Air gap on | probe succeeds before, fails after; NIC shows link-down | 3 checks passed | PASS | `r770-staging-vm-host-*.log` |
| Verify from the media, with the bundle's own verifier | `RESULT: PASS`, exit 0 | PASS, exit 0 | PASS | `verify-media.log` |
| `discover` | disks, NICs, addresses, bridges, mounts; an empty template | as expected, exit 0 | PASS | `discover.log` |
| `plan` | every gate reviewed; READY | NOT READY: 6 failures, 1 warning, 1 skipped | FAIL | `plan.log` |
| `run --yes` (first cut) | INSTALLED | stopped at `dashboards` by design (three index patterns, none chosen); after naming the pattern, e2e failed `up s1-w1-ss` | FAIL | `debug-pass.tgz`: `run-1.log`, `run-1b.log` |
| `run --yes` (second cut) | INSTALLED | all 8 steps ran, e2e 40 checks passed; NOT INSTALLED, exit 2: warnings from gns3, malcolm, docs | WARN | `attempt-2/attempt-2.tgz`: `run-1.log` |
| `run --yes` (third cut) | INSTALLED | **INSTALLED — every step clean and the lab proven end to end**, exit 0; e2e 40 checks passed, all ten scenarios | PASS | `run-1.log`, `r770-evidence/install-r770-staging-20261110-162047.md` |
| Re-entry: second `run --yes` from the local copy, Ctrl-C when `malcolm` begins | the run stops; `status` still truthful | exit 130; `status` shows all 8 steps done | PASS | `run-2.log`, `status-2.log` |
| Re-entry: `run --yes --from malcolm` | INSTALLED | every step from `malcolm` ran; NOT INSTALLED, exit 2: one warning, "something listens on 0.0.0.0:443" | WARN | `run-3.log` |
| `umount` the media | clean | UNMOUNTED | PASS | (command output) |
| Services after a reboot | Malcolm, GNS3 and the front door return | GNS3 unit active, nginx active, lab bridge, mirror and TAPs present; every Malcolm container exited; TSO back on on `lab_mirror0` | FAIL | `ipsec-evidence.tgz`: `start-after-reboot.log`, `c/h0-validate.log` |

## Site checks

Reach: `harness/r770-staging-vm.sh tunnel` to the VM's 443;
`harness/r770-site-shot.ps1` for the pages. That helper has no bats suite; it
was proven by the captures below.

| Target | Observed | Verdict | Evidence |
|---|---|---|---|
| Certificate | `X509v3 Subject Alternative Name: DNS:malcolm.lab, DNS:gns3.lab, DNS:docs.lab`; issuer `CN=R770 Lab CA` (generated on the VM); `Verify return code: 0 (ok)` against that CA | PASS | read with `openssl s_client` through the tunnel |
| `malcolm.lab`, no login | status 401 | PASS | the helper's JSON line (the page is blank, so no image is kept) |
| `docs.lab`, no login | status 401 — the wiki is behind the same login | PASS | as above |
| `gns3.lab` | status 200, the GNS3 web UI's login screen | PASS | `2026-11-10-installer-acceptance/gns3-ui.png` |
| `gns3.lab` projects | every scenario listed as runnable (10) | PASS | `sitecheck.log` |
| `malcolm.lab`, logged in | **no screenshot.** Read on the VM instead: landing page 200, title "Malcolm"; Dashboards lists 14 IPsec saved objects (one dashboard, 13 searches); Arkime holds 4473 sessions and the kit's views | PASS (content), SKIP (screenshot) | `sitecheck.log` |
| `docs.lab`, logged in | **no screenshot.** Read on the VM: home 200, title "Analyst Guide — R770 Network Lab"; the search index holds 49 documents, 8 mentioning IPsec | PASS (content), SKIP (screenshot) | `sitecheck.log` |

The logged-in screenshots were not taken: copying Malcolm's login from the VM
to the operator PC was refused by the session's safety policy, and it was not
worked around. The design's fallback applies — the operator signs in and takes
them. Browser navigation and the search box were therefore not exercised.

## Findings

| # | Finding | Change | Commit | First bundle | Rerun |
|---|---|---|---|---|---|
| A1 | The GNS3 registry no longer has the `alpine-linux` definition (404); one WARN fails the strict gate | fetch `alpine-linux-virt` | `4e8f039` | first cut, second pass | PASS |
| A2 | `plan` on a bare host is NOT READY: Malcolm `unpack` and the four portal steps refuse under dry-run because their packages, the lab CA and the login file come from earlier steps of the same run. `run` is unaffected | **open** — needs the operator's choice: SKIP rows naming the earlier step, or dry-run tolerance in each step | — | — | — |
| A3 | `s1-w1-ss`: two settings on one line of `swanctl.conf`; strongSwan discarded the connection | one setting per line | `10f714e` | second cut | PASS |
| A4 | `s1-w1-ss`: the initiator's single load-time attempt ran before its peer was configured (`NO_PROPOSAL_CHOSEN`) and was never retried | `start_action = trap\|start` | `10f714e` | second cut | PASS |
| A5 | `s1-w1-ss`: `/gt/charon.log` was always empty | a filelog of its own | `10f714e` | second cut | PASS |
| A6 | `s1-w1-ss`: the save-keys snippet was nested wrongly (latent: the bundled image has no such plugin) | the plugin's own section | `10f714e` | second cut | not verifiable on this image |
| A7 | `tshark` shipped in `apt/` and nothing installed it | `tcpdump tshark` in the base package list; the install is non-interactive | `10f714e` | second cut | PASS |
| A8 | "definition without image" is warned by the `files` step of all three pipelines on every run, so without an image per definition the verdict can never be INSTALLED | **open** — rehearsed with D6's placeholders; on the real R770 this needs a decision | — | — | — |
| A9 | Malcolm `start` warned on any listener on the wildcard 443; on an installed host that is the front door, so a re-entry can never be clean | judge the listener by its owner | `ee01899` | **not yet in a bundle** | `start` from a working copy on the VM: PASS, exit 0; a full re-entry was not rerun |
| A10 | Malcolm does not return after a reboot (restart policy "no"); `r770-malcolm-deploy.sh start` brought all 27 services back | **open** — auto-restart, or a runbook line | — | — | — |
| A11 | After a reboot `tcp-segmentation-offload` is on again on `lab_mirror0` (the `.link` file turned GSO and GRO off, not TSO), so `r770-validate.sh --area network` FAILs | **open** | — | — | — |
| A12 | The first `run` stops at `dashboards` when the stack has more than one index pattern | by design; `INDEX_PATTERN=arkime_sessions3-*` named in `install.conf` | — | — | PASS |

## Not exercised

- `wizard` (needs a terminal; covered by `tests/install.bats`).
- The Docker install from a bare OS (D7).
- Real licensed appliance images (D6).
- A re-entry that ends INSTALLED (A9's fix is not in a bundle; A11 would also
  stop a post-reboot rerun at `validate`).
- Logged-in screenshots, wiki navigation and the search box in a browser.
- `VALIDATE_AREAS` was `network capture gns3 storage portal airgap`; within
  those, `storage/smart`, `storage/perc-vd`, `airgap/dnsmasq`,
  `airgap/ubuntu pro`, `capture/tcpreplay` and `gns3/node-boot` SKIPped.

## Evidence

Operator PC, outside git: `~/r770-rehearsals/2026-11-09-acceptance/`
(`acceptance-evidence.tgz`, the cut and suite logs, harness transcripts,
`install.conf`, `sitecheck.log`, `attempt-2/`) and
`~/r770-rehearsals/2026-11-10-debug-pass/debug-pass.tgz` (the first cut's
install). VM snapshots: `cut-2026-11-10`, `cut2-2026-11-10`,
`cut3-2026-11-10`, `installed-2026-11-10`.
