# Offline Deployment Test With a Newer Malcolm — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Malcolm pin to the newest upstream release, cut a fresh bundle on VM 9770, and install it offline from the bare snapshot to INSTALLED, with a rehearsal record and a draft PR.

**Architecture:** One VM plays both hosts in turn. It is rolled back to a snapshot with Docker and internet to cut the bundle; the bundle is carried off to the operator PC; the VM is rolled back to a bare, air-gapped snapshot and the bundle is carried on to its loop media; the bundle's own installer does the rest. Every VM state change goes through `harness/r770-staging-vm.sh`.

**Tech Stack:** bash, bats, shellcheck, ssh/scp, Proxmox `qm` (through the harness), Docker CE on the VM.

**Spec:** `docs/superpowers/specs/2026-11-19-malcolm-refresh-offline-test-design.md`

## Global Constraints

- Branch `malcolm-refresh`. Never commit to `main`.
- `./tests/run.sh` exits 0 before every commit.
- No three-part version number in any tracked file, this plan and the record included (`tests/no-pins.bats` scans the whole tree). Versions are read from the pin block, the bundle and the transcripts. Dotted-quad addresses are fine.
- The pin moves in `staging/r770-offline-fetch.sh`'s pin block and nowhere else.
- **Operator gates.** Stop and ask the operator, every time, before: each snapshot rollback; `airgap off`; starting the cut; the installer's `run --yes`. A yes covers that one action only.
- Never bypass a kit gate. A script's refusal is a finding: one hypothesis, one change, rerun.
- On the VM only kit scripts change the host, except the stand-in actions this plan names (the loop media, the seed, the carried files).
- No secret in git, in chat, on a command line or in the record. Never read a private key file.
- A verdict is written only with its transcript's file name beside it. Never write a result that no transcript shows.
- `curl` and `wget` are denied on the operator PC by `.claude/settings.json`; do not work around it.
- Long commands run detached on the VM and write a log. Poll the log every 10 to 20 minutes; do not hold an SSH session open.
- Commit messages end with the two attribution lines the session gives.

## Names fixed by this plan

| Name | Value |
|---|---|
| Proxmox SSH host | `proxmox` |
| VM id | `9770` |
| VM SSH host | `r770-staging` (user `ubuntu`, through `proxmox`) |
| Internet NIC of the VM | `net0` |
| Probe address | `91.189.92.22:80` (re-checked in Task 2) |
| Cut snapshot | `clean-2026-11-09` |
| Bare snapshot | `bare2b-2026-11-12` |
| Old bundle | `bundle-20261112`, as `/mnt/c/Users/temps/r770-bundles/bundle-20261112.tar` |
| Evidence archive on the PC | `~/r770-rehearsals/2026-11-19-malcolm-refresh/` |
| Kit checkout on the VM | `/home/ubuntu/sim-lab-basic` |
| Bundles on the VM during the cut | `/home/ubuntu/bundles/` |
| Loop media on the bare VM | `/data/staging/media.img`, mounted at `/mnt/media` |

Shell shorthand used below, set once per shell on the PC from the repo root:

```bash
EVD=~/r770-rehearsals/2026-11-19-malcolm-refresh
mkdir -p "$EVD"
VM="env KIT_EVIDENCE_DIR=$EVD ./harness/r770-staging-vm.sh"
PV="--pve proxmox --vmid 9770"
AG="--wan-net net0 --mgmt-host r770-staging --probe 91.189.92.22:80"
```

`NEWB` is the new bundle's directory name, read in Task 3 step 6 (the cut names it for the day it runs). Set `NEWB=<that name>` in the shell afterwards.

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `staging/r770-offline-fetch.sh` | modify one line of the pin block | the Malcolm version |
| `docs/rehearsals/2026-11-19-malcolm-refresh.md` | create | the rehearsal record |
| `docs/backlog.md` | modify only if a finding stays open | open findings |

Kit files change beyond this only as fixes for findings (see "When a step fails").

---

### Task 1: Branch state and the pin move

**Files:**
- Modify: `staging/r770-offline-fetch.sh` (the `MALCOLM_VER=` line of the pin block)

**Interfaces:**
- Produces: branch `malcolm-refresh` with the pin moved; `KITC`, the commit id under test.

- [ ] **Step 1: Confirm the branch and a clean tree.**

```bash
git status --short --branch
```
Expected: `## malcolm-refresh`, no other lines.

- [ ] **Step 2: Read the current pin and the newest upstream tag.**

```bash
grep -n '^MALCOLM_VER=' staging/r770-offline-fetch.sh
git ls-remote --tags --refs --sort=-v:refname https://github.com/idaholab/Malcolm 'v*' | head -5
```
Expected: one pin line; the newest tag is two releases ahead of the pin. Take the top tag without its leading `v` as the new version. If the top tag is a pre-release name (letters after the numbers), take the newest plain one.

- [ ] **Step 3: Move the pin.** Edit only the default inside `${MALCOLM_VER:-...}` on that line to the new version. Leave the comment.

```bash
git diff --stat
git diff staging/r770-offline-fetch.sh
```
Expected: one file, one line changed, only the version differs.

- [ ] **Step 4: The gate.**

```bash
./tests/run.sh > /tmp/suite.log 2>&1; echo exit=$?; grep -c '^ok' /tmp/suite.log; grep '^not ok' /tmp/suite.log
```
Expected: `exit=0`, no `not ok` line. A failure in `tests/no-pins.bats` means a version was written somewhere other than the pin block: remove it.

- [ ] **Step 5: Commit.**

```bash
git add staging/r770-offline-fetch.sh
git commit -m "Move the Malcolm pin to the newest release"
git rev-parse HEAD
```
Record the printed id as `KITC`.

---

### Task 2: The staging host — roll back, start, internet on

**Interfaces:**
- Consumes: branch `malcolm-refresh` at `KITC`.
- Produces: VM 9770 running from `clean-2026-11-09` with internet, Docker answering, the kit checkout at `/home/ubuntu/sim-lab-basic` on `KITC`, the old bundle unpacked at `/home/ubuntu/bundles/bundle-20261112`.

- [ ] **Step 1: Look before changing anything.**

```bash
$VM status $PV
ssh proxmox qm list
ssh proxmox free -g
```
Expected: 9770 stopped, parent `bare2b-2026-11-12` or `final-2026-11-12`. If VM 9100 (`gns3`, 16 GB) is running and free memory is under 17 GB, ask the operator whether to shut it down; do not stop it unasked.

- [ ] **Step 2: GATE — ask the operator:** "Roll VM 9770 back to `clean-2026-11-09`? Everything on it since `final-2026-11-12` is discarded; that snapshot itself is kept." On yes:

```bash
$VM rollback $PV --snapshot clean-2026-11-09 --yes
$VM start $PV
$VM wait-ssh 300 --mgmt-host r770-staging
```
Expected: each ends `READY`, exit 0.

- [ ] **Step 3: GATE — ask the operator:** "Turn the air gap off on VM 9770 so it can download?" On yes:

```bash
$VM airgap off $PV $AG
```
Expected: PASS for `link_down` removed and PASS for the guest reaching the probe; exit 0. If the snapshot already had the NIC up, the same command still proves reachability. A probe FAIL: check the address still answers (`ssh r770-staging "getent hosts archive.ubuntu.com"`), choose one of the printed addresses, and rerun with it; record the change.

- [ ] **Step 4: The host is what the snapshot says.**

```bash
ssh r770-staging "lsb_release -ds; docker info --format '{{.ServerVersion}} {{.DockerRootDir}}'; df -h / | tail -1; ls /home/ubuntu"
```
Expected: Ubuntu 24.04; Docker answers; more than 200 GB free on `/` (150 for the preflight, plus the seed and its tar); no `bundles` directory.

- [ ] **Step 5: Send the branch to the VM.** The VM holds no GitHub credential.

```bash
ssh r770-staging "rm -rf /home/ubuntu/kit.git /home/ubuntu/sim-lab-basic && git init -q --bare /home/ubuntu/kit.git"
git push ssh://r770-staging/home/ubuntu/kit.git malcolm-refresh
ssh r770-staging "git clone -q -b malcolm-refresh /home/ubuntu/kit.git /home/ubuntu/sim-lab-basic && git -C /home/ubuntu/sim-lab-basic rev-parse HEAD"
```
Expected: the printed id equals `KITC`.

- [ ] **Step 6: Send the seed.** About 15 GB; run it in the background and wait for it.

```bash
ssh r770-staging "mkdir -p /home/ubuntu/bundles"
scp /mnt/c/Users/temps/r770-bundles/bundle-20261112.tar r770-staging:/home/ubuntu/bundles/
ssh r770-staging "tar -tf /home/ubuntu/bundles/bundle-20261112.tar | head -3"
ssh r770-staging "tar -xf /home/ubuntu/bundles/bundle-20261112.tar -C /home/ubuntu/bundles && rm /home/ubuntu/bundles/bundle-20261112.tar && ls /home/ubuntu/bundles"
ssh r770-staging "cd /home/ubuntu/bundles/bundle-20261112 && ./r770-bundle.sh verify . | tail -3"
```
Expected: the listing's first entries start `bundle-20261112/` (if they do not, extract into a directory of that name instead); `ls` shows `bundle-20261112` only; `RESULT: PASS`. A seed that does not verify is not used: remove it and cut with `SEED_FROM=none`, and record that.

---

### Task 3: The cut

**Interfaces:**
- Consumes: Task 2's host state.
- Produces: `/home/ubuntu/bundles/$NEWB` on the VM, gated `RESULT: PASS`, carrying kit `KITC`; `cut-1.log` and `preflight.log` in `$EVD`.

- [ ] **Step 1: The staging preflight.**

```bash
ssh r770-staging "cd /home/ubuntu/sim-lab-basic && ./staging/r770-staging-preflight.sh > /home/ubuntu/preflight.log 2>&1; echo exit=\$?; cat /home/ubuntu/preflight.log"
```
Expected: `READY — all checks passed`, `exit=0`. A WARN is dispositioned in the record. A FAIL is a finding about the host: fix the condition it names, not the script.

- [ ] **Step 2: Read the stage plan without downloading.**

```bash
ssh r770-staging "cd /home/ubuntu/sim-lab-basic && SEED_FROM=/home/ubuntu/bundles/bundle-20261112 ./staging/r770-offline-fetch.sh --dry-run | head -40"
```
Expected: the eleven stages listed; the Malcolm stage names the new version.

- [ ] **Step 3: GATE — ask the operator:** "Start the cut on VM 9770? It downloads the new Malcolm images, the apt set and the enrichment data, seeded from `bundle-20261112`." On yes:

```bash
ssh r770-staging "cd /home/ubuntu/sim-lab-basic && nohup env KIT_SRC_ROOT=/home/ubuntu/sim-lab-basic SEED_FROM=/home/ubuntu/bundles/bundle-20261112 ./staging/r770-build-bundle.sh --yes --bundle-dir /home/ubuntu/bundles/bundle-\$(date +%Y%m%d) > /home/ubuntu/cut-1.log 2>&1 < /dev/null &"
```
`--yes` answers the builder's two questions: its manual-items pause (nothing licensed is staged in this rehearsal, as in the final pass) and any preflight warning already dispositioned in step 1.

- [ ] **Step 4: Poll.**

```bash
ssh r770-staging "tail -n 5 /home/ubuntu/cut-1.log | cut -c1-200; pgrep -f r770-build-bundle.sh > /dev/null && echo RUNNING || echo ENDED; df -h / | tail -1"
```
A fetch failure is resumable: rerun step 3's command unchanged; completed items are skipped.

- [ ] **Step 5: Read the result.**

```bash
ssh r770-staging "tail -n 22 /home/ubuntu/cut-1.log"
```
Expected: every gate line `ok`, `RESULT: PASS`, `BUNDLE READY — gated clean`. `BUILT WITH WARNINGS` or a FAIL is a finding (see "When a step fails").

- [ ] **Step 6: Check what the bundle carries.**

```bash
ssh r770-staging "ls /home/ubuntu/bundles"
```
Set `NEWB` to the new directory's name, then:

```bash
ssh r770-staging "cat /home/ubuntu/bundles/$NEWB/kit/KIT_COMMIT; grep -A9 '^## Versions' /home/ubuntu/bundles/$NEWB/BUNDLE_NOTES.md; sed 's/.*://' /home/ubuntu/bundles/$NEWB/malcolm/image-list.txt | sort | uniq -c; ls /home/ubuntu/bundles/$NEWB/malcolm; du -sh /home/ubuntu/bundles/$NEWB"
```
Expected: the commit equals `KITC`; the Versions block names the new Malcolm and the other pins unchanged; the image list carries one tag, the new version's; the `malcolm/` directory holds one install zip and one image tarball, both named for the new version.

- [ ] **Step 7: What was reused, what was fetched.**

```bash
ssh r770-staging "grep -c -i 'seed' /home/ubuntu/cut-1.log; grep -i 'seed\|already present\|reused' /home/ubuntu/cut-1.log | cut -c1-160" > "$EVD/seeded.txt"
cat "$EVD/seeded.txt"
```
Keep the file; the record's "what changed" section is written from it.

- [ ] **Step 8: Keep the logs.**

```bash
scp r770-staging:/home/ubuntu/cut-1.log r770-staging:/home/ubuntu/preflight.log "$EVD/"
```

---

### Task 4: Carry the bundle off

**Interfaces:**
- Consumes: `/home/ubuntu/bundles/$NEWB` on the VM.
- Produces: `/mnt/c/Users/temps/r770-bundles/$NEWB.tar` on the PC, verified.

- [ ] **Step 1: Tar it on the VM.**

```bash
ssh r770-staging "tar -cf /home/ubuntu/$NEWB.tar -C /home/ubuntu/bundles $NEWB && ls -l /home/ubuntu/$NEWB.tar"
```

- [ ] **Step 2: Copy it to the PC.**

```bash
df -h /mnt/c/Users/temps/r770-bundles ~ | cat
scp r770-staging:/home/ubuntu/$NEWB.tar /mnt/c/Users/temps/r770-bundles/
ls -l /mnt/c/Users/temps/r770-bundles/
```
Expected: the tar's size equals the size step 1 printed.

- [ ] **Step 3: Verify the copy with the bundle's own verifier.** Unpack on the PC's Linux filesystem (not under `/mnt/c`: file modes matter to the verifier), and only if `~` has room for it.

```bash
mkdir -p ~/r770-bundle-check && tar -xf /mnt/c/Users/temps/r770-bundles/$NEWB.tar -C ~/r770-bundle-check
~/r770-bundle-check/$NEWB/r770-bundle.sh verify ~/r770-bundle-check/$NEWB --strict | tee "$EVD/verify-pc.log" | tail -4
rm -rf ~/r770-bundle-check
```
Expected: `RESULT: PASS`. A failure here means the copy is bad: copy again; do not go on. If the verifier refuses for a tool the PC lacks, that is a SKIP with its reason in the record, and the verify from the media in Task 5 is the proof.

---

### Task 5: The R770 stand-in — bare, the new bundle on the media, air gap on

**Interfaces:**
- Consumes: `/mnt/c/Users/temps/r770-bundles/$NEWB.tar`.
- Produces: VM 9770 from `bare2b-2026-11-12` with `$NEWB` alone on the loop media; snapshot `bare-refresh-2026-11-19`; `DEV`, the media's loop device; `verify-media.log`.

- [ ] **Step 1: GATE — ask the operator:** "Roll VM 9770 back to `bare2b-2026-11-12`? The staging state and the cut on the VM are discarded; the bundle is safe on the PC." On yes:

```bash
$VM stop $PV
$VM rollback $PV --snapshot bare2b-2026-11-12 --yes
$VM status $PV
$VM start $PV
$VM wait-ssh 600 --mgmt-host r770-staging
```
Expected: `status` shows `net0` with `link_down=1`. The boot takes about two minutes longer than usual (finding F4: `systemd-networkd-wait-online` waits on the link-down NIC).

- [ ] **Step 2: The host is bare and offline.**

```bash
ssh r770-staging "command -v docker || echo NO-DOCKER; test -e /etc/lab/install.conf && echo CONF-PRESENT || echo NO-CONF; findmnt -t ext4 -o TARGET | grep -c -E '/data|/srv|/var/lib/(docker|containerd)'; ls /srv/bundles 2>/dev/null; df -h / /data/staging | cat; timeout 5 bash -c '</dev/tcp/91.189.92.22/80' && echo ONLINE || echo OFFLINE"
```
Expected: `NO-DOCKER`, `NO-CONF`, `9`, nothing under `/srv/bundles`, `OFFLINE`. Anything else: stop and tell the operator; the snapshot is not the state the record describes.

- [ ] **Step 3: Find the media.** Never assume the device name.

```bash
ssh r770-staging "ls -l /data/staging/media.img; sudo losetup -a | grep media.img || sudo losetup -f --show /data/staging/media.img"
ssh r770-staging "sudo losetup -a | grep media.img"
```
Record the `/dev/loopN` at the start of the last line as `DEV`.

- [ ] **Step 4: Replace the old bundle on the media.** Look before deleting.

```bash
ssh r770-staging "sudo mkdir -p /mnt/media && sudo mount $DEV /mnt/media && ls -la /mnt/media && df -h /mnt/media | tail -1"
```
Expected: `bundle-20261112` and `lost+found` only. Then:

```bash
ssh r770-staging "sudo rm -rf /mnt/media/bundle-20261112 && df -BM /mnt/media | tail -1"
ls -l /mnt/c/Users/temps/r770-bundles/$NEWB.tar
```
If the media's free space is less than the tar's size plus 500 MB, grow the image (a stand-in action, recorded): 

```bash
ssh r770-staging "sudo umount /mnt/media && sudo losetup -d $DEV && sudo truncate -s +8G /data/staging/media.img && sudo e2fsck -f -p /data/staging/media.img; sudo resize2fs /data/staging/media.img && sudo losetup -f --show /data/staging/media.img"
```
The last line is the new `DEV`; mount it again as above.

- [ ] **Step 5: Carry the bundle on,** over the management NIC, straight onto the media.

```bash
ssh r770-staging "sudo tar -xf - -C /mnt/media" < /mnt/c/Users/temps/r770-bundles/$NEWB.tar
ssh r770-staging "ls /mnt/media; sudo du -sh /mnt/media/$NEWB; sudo umount /mnt/media && echo UNMOUNTED"
```
Expected: `$NEWB` and `lost+found`; `UNMOUNTED`.

- [ ] **Step 6: Snapshot the bare state,** so a failed install can be retried without another carry. Plain-text description only (finding F5).

```bash
$VM stop $PV
$VM snapshot $PV --snapshot bare-refresh-2026-11-19 --description "bare host, refreshed Malcolm bundle on loop media, air gap on"
$VM status $PV
$VM start $PV
$VM wait-ssh 600 --mgmt-host r770-staging
```
Expected: `status` lists `bare-refresh-2026-11-19`. If it is missing, the snapshot was not taken: rerun with a shorter description.

- [ ] **Step 7: Attach the media again and prove the air gap.**

```bash
ssh r770-staging "sudo losetup -f --show /data/staging/media.img"
$VM airgap on $PV $AG
```
The first line is `DEV` for the rest of the plan. Expected from `airgap on`: the NIC is already link-down, so the harness has no positive control to run; it WARNs and exits 2. That is the expected verdict here; record it as WARN with step 2's `OFFLINE` beside it.

- [ ] **Step 8: Verify from the media, with the bundle's own verifier.**

```bash
ssh r770-staging "sudo mount -o ro $DEV /mnt/media && sudo /mnt/media/$NEWB/r770-bundle.sh verify /mnt/media/$NEWB --strict > /home/ubuntu/verify-media.log 2>&1; echo exit=\$?; tail -4 /home/ubuntu/verify-media.log"
```
Expected: `RESULT: PASS`, `exit=0`. If `verify` wants its arguments in another order, its `--help` says so; use that.

---

### Task 6: Install

`EV=/home/ubuntu/r770-evidence`. Every kit command on the VM runs from `/home/ubuntu` as `sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence <cmd>`.

**Interfaces:**
- Consumes: `$NEWB` mounted read-only at `/mnt/media`; `DEV`.
- Produces: INSTALLED; `discover.log`, `plan.log`, `run-1.log` on the VM; the installed copy at `/srv/bundles/$NEWB`.

- [ ] **Step 1: `discover`.**

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence /mnt/media/$NEWB/kit/scripts/r770-install.sh discover > /home/ubuntu/discover.log 2>&1; echo exit=\$?; cat /home/ubuntu/discover.log"
ssh r770-staging "sudo cat /etc/lab/install.conf.template"
```
Expected: `exit=0`; disks, NICs, addresses and mounts; `ens20` listed, down, no address; the NIC holding `192.168.97.70`; a template whose values are empty.

- [ ] **Step 2: `install.conf`,** from the final pass's copy, each value checked against step 1's output. The `wizard` needs a terminal and is recorded under "Not exercised".

```bash
cp ~/r770-rehearsals/2026-11-12-final-pass/install.conf "$EVD/install.conf"
cat "$EVD/install.conf"
```
The file must read as below, with `DEVICE` set to `DEV`, `MGMT_IF` set to the NIC `discover` shows holding `192.168.97.70`, and `ens20` confirmed in `discover`'s NIC list. Its keys must be exactly the template's keys. Edit `$EVD/install.conf` where this run's discovery differs, and note each difference for the record.

```
BUNDLE=
MEDIA=/mnt/media
DEVICE=/dev/loop9
CAPTURE_IFS=lab_mirror0 ens20
LAB_BRIDGE=br-lab
MGMT_IF=eth1
MGMT_CIDR=192.168.97.0/24
VALIDATE_AREAS=network capture gns3 storage portal airgap
INDEX_PATTERN=arkime_sessions3-*
```

```bash
scp "$EVD/install.conf" r770-staging:/home/ubuntu/install.conf
ssh r770-staging "sudo install -m 0600 -o root -g root /home/ubuntu/install.conf /etc/lab/install.conf"
```

- [ ] **Step 3: `plan`.**

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence /mnt/media/$NEWB/kit/scripts/r770-install.sh plan > /home/ubuntu/plan.log 2>&1; echo exit=\$?"
ssh r770-staging "grep -E '^(PASS|WARN|FAIL|SKIP)|GATE|READY' /home/ubuntu/plan.log"
ssh r770-staging "cat /home/ubuntu/plan.log"
```
Expected: `exit=2`, READY WITH WARNINGS; 0 FAIL; the only WARNs are the import preflight's two first-install warnings (docker not present yet; no previous bundle); each SKIP names its provider. Read the whole log once: every gate's current, proposed and rollback. A FAIL or a third WARN is a finding.

- [ ] **Step 4: GATE — show the operator the plan's verdict lines and ask:** "Run the install on VM 9770? `run --yes` accepts each gate `plan` listed." On yes:

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence nohup /mnt/media/$NEWB/kit/scripts/r770-install.sh run --yes > /home/ubuntu/run-1.log 2>&1 < /dev/null &"
```

- [ ] **Step 5: Poll,** every 10 to 15 minutes. The final pass took about an hour.

```bash
ssh r770-staging "grep -E '^== |INSTALLED|refused or failed|step .* finished' /home/ubuntu/run-1.log | tail -n 8; pgrep -f r770-install.sh > /dev/null && echo RUNNING || echo ENDED"
```

- [ ] **Step 6: Read the result.**

```bash
ssh r770-staging "tail -n 30 /home/ubuntu/run-1.log; ls /home/ubuntu/r770-evidence | grep '^install-'"
```
Expected: `INSTALLED`; e2e reports 40 checks passed across ten scenarios; an `install-r770-staging-<ts>` report exists. `NOT INSTALLED`: see "When a step fails". If the only failed step is e2e's `up bgp` readiness wait (finding F6), rerun once and record both runs:

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence nohup /srv/bundles/$NEWB/kit/scripts/r770-install.sh run --yes --from e2e > /home/ubuntu/run-1b.log 2>&1 < /dev/null &"
```

- [ ] **Step 7: The running Malcolm is the new one.**

```bash
ssh r770-staging "sudo docker ps --format '{{.Image}}' | grep -i malcolm | sed 's/.*://' | sort | uniq -c; sed 's/.*://' /srv/bundles/$NEWB/malcolm/image-list.txt | sort -u" | tee "$EVD/malcolm-tags.txt"
```
Expected: every running Malcolm container carries the one tag the bundle's image list names.

---

### Task 7: Prove it holds — reboot and re-entry

**Interfaces:**
- Consumes: the installed VM.
- Produces: `reboot-state.log`, `reboot-validate-network.log`, `run-2.log` on the VM.

- [ ] **Step 1: Reboot, then look before running anything.**

```bash
ssh r770-staging "sudo systemctl reboot"
$VM wait-ssh 900 --mgmt-host r770-staging
ssh r770-staging "{ date -Is; sudo docker ps --format '{{.Names}} {{.Status}}'; systemctl --failed --no-legend; for i in lab_mirror0 ens20; do ip -br addr show \$i; sudo ethtool -k \$i | grep -E '^(tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload):'; done; } > /home/ubuntu/reboot-state.log 2>&1; cat /home/ubuntu/reboot-state.log"
```
Expected: the Malcolm containers are up without anyone starting them (all healthy within about five minutes: repeat the `docker ps` once after a wait); both capture interfaces show no address and all three offloads `off`; the only failed unit, if any, is `systemd-networkd-wait-online` (F4).

- [ ] **Step 2: The network validation.**

```bash
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence /srv/bundles/$NEWB/kit/scripts/r770-validate.sh --area network --capture-ifs 'lab_mirror0 ens20' > /home/ubuntu/reboot-validate-network.log 2>&1; echo exit=\$?; tail -6 /home/ubuntu/reboot-validate-network.log"
```
Expected: no FAIL; the capture rows PASS for both interfaces. If the script wants the interfaces passed another way, its `--help` says so.

- [ ] **Step 3: Re-entry from the installed copy.** The loop device is gone after a reboot: attach the media first, and if its device name is no longer the `DEVICE` in `/etc/lab/install.conf`, correct that one value and record it.

```bash
ssh r770-staging "sudo losetup -f --show /data/staging/media.img; sudo grep '^DEVICE=' /etc/lab/install.conf"
ssh r770-staging "cd /home/ubuntu && sudo KIT_EVIDENCE_DIR=/home/ubuntu/r770-evidence nohup /srv/bundles/$NEWB/kit/scripts/r770-install.sh run --yes --from malcolm > /home/ubuntu/run-2.log 2>&1 < /dev/null &"
```
Poll as in Task 6 step 5 with `run-2.log`. Expected: `INSTALLED`, exit 0, no gate reopened. The operator's yes to Task 6 step 4 does not cover this run: **ask again** before starting it.

- [ ] **Step 4: Release the media.**

```bash
ssh r770-staging "findmnt /mnt/media > /dev/null && sudo umount /mnt/media; echo UNMOUNTED"
```

---

### Task 8: Evidence, snapshot, record, PR

**Files:**
- Create: `docs/rehearsals/2026-11-19-malcolm-refresh.md`
- Modify: `docs/backlog.md` (only if a new finding stays open)

**Interfaces:**
- Consumes: every log named above; `$EVD`.
- Produces: the record, committed; a draft PR.

- [ ] **Step 1: Archive the evidence to the PC.**

```bash
ssh r770-staging "cd /home/ubuntu && ls *.log && sudo tar -czf /home/ubuntu/malcolm-refresh-evidence.tgz r770-evidence *.log"
scp r770-staging:/home/ubuntu/malcolm-refresh-evidence.tgz "$EVD/"
tar -tzf "$EVD/malcolm-refresh-evidence.tgz" | wc -l
ls "$EVD"
```
Expected: the archive lists the kit transcripts and `discover.log`, `plan.log`, `run-1.log`, `run-2.log`, `verify-media.log`, `reboot-state.log`, `reboot-validate-network.log`; `$EVD` also holds `cut-1.log`, `preflight.log`, `seeded.txt`, `verify-pc.log`, `malcolm-tags.txt`, `install.conf` and the harness transcripts.

- [ ] **Step 2: Snapshot the installed state.**

```bash
$VM stop $PV
$VM snapshot $PV --snapshot refresh-2026-11-19 --description "INSTALLED from bare with the refreshed Malcolm bundle, reboot and re-entry proven, air gap on"
$VM status $PV
```
Expected: `refresh-2026-11-19` listed. Leave the VM stopped. If VM 9100 was shut down in Task 2, ask the operator whether to start it again.

- [ ] **Step 3: Write the record,** in the shape `docs/rehearsals/README.md` fixes and in the manner of `docs/rehearsals/2026-11-12-final-pass.md`:

  - **Header:** date; hypervisor `proxmox`, VM 9770; the bundle's name; the kit commit from the bundle's `kit/KIT_COMMIT`; run by Claude Code with the harness.
  - **Result:** one paragraph, the outcome first.
  - **Stand-ins:** the final pass's table, checked row by row against this run, plus: the bundle was cut on one snapshot and installed on another of the same VM, carried between them through the operator PC; the fetch was seeded from `bundle-20261112`; nothing licensed was staged.
  - **Steps:** one row per step of Tasks 1 to 7 that has a transcript, with Expected, Observed, Verdict and the transcript's file name. Verdicts are copied from the transcripts.
  - **What changed in the bundle:** from `seeded.txt` and the two bundles' `BUNDLE_NOTES.md`: reused, fetched fresh, and the file and package counts of each bundle. No version numbers: name the component and say "moved" or "unchanged".
  - **Findings:** each WARN and FAIL, numbered from F8 (F1 to F7 belong to the final pass): the hypothesis, the change, the commit, the first bundle with the fix, the rerun's verdict. If F6 recurred, say so and give the count.
  - **Not exercised:** the final pass's list, checked against this run.
  - **Evidence:** `$EVD` and its file names; the snapshots `bare-refresh-2026-11-19` and `refresh-2026-11-19`; where the bundle is kept.

  Every claim in the record has a file in `$EVD` or the archive behind it. If a step has no transcript, it has no verdict.

- [ ] **Step 4: The gate, then commit.**

```bash
./tests/run.sh > /tmp/suite.log 2>&1; echo exit=$?; grep '^not ok' /tmp/suite.log
git add docs/rehearsals/2026-11-19-malcolm-refresh.md
git status --short
git commit -m "Rehearsal record: the Malcolm refresh, installed offline from a bare host"
```
Expected: `exit=0`. `tests/references.bats` reads the record: every repo path it names must exist. `tests/no-pins.bats` reads it too.

- [ ] **Step 5: Push and open a draft PR.**

```bash
git push -u origin malcolm-refresh
gh pr create --draft --base main --title "Malcolm refresh: pin move, offline install rehearsal" --body-file /tmp/pr-body.md
```
Write `/tmp/pr-body.md` first: what moved, the rehearsal's result in two sentences, the findings and their commits, what stays open, and the session's PR attribution lines. If `gh` is not installed or not signed in, push the branch and give the operator the compare URL instead.

---

## When a step fails

1. Stop. Copy the failing log to `$EVD` before changing anything.
2. Read the transcript the failing script names under `r770-evidence/`.
3. State one hypothesis to the operator, with the lines that support it.
4. **Kit defect:** on the PC, write a failing test in the suite that owns the script (`tests/staging.bats` for `staging/`, the script's own suite otherwise), make the one change, `./tests/run.sh` green, commit. A config template change also goes through `config/README.md`'s delta table. Then re-cut: the installer runs from the bundle's `kit/`, so the fix must ship in a bundle. Return to Task 2 step 2 (all gates asked again), seeding from the bundle just cut by sending its tar from the PC in place of the old one, and name the new bundle directory with a suffix so the two cuts stay distinct: pass `--bundle-dir /home/ubuntu/bundles/bundle-<date>b`.
5. **Stand-in or harness condition** (a volume too small, the loop device renamed, the probe address moved): fix that one thing, record it as a stand-in note, and rerun from the failed step: `run --yes --from <step>` from `/srv/bundles/$NEWB/kit/scripts/` once the import step has copied the bundle, from the media before that.
6. **An upstream change in the new Malcolm** (a renamed setting, a new required variable, a changed compose service) is the finding this test exists for. It is a kit defect: handle it as item 4.
7. Three failed fixes for the same step: stop and bring the evidence to the operator before a fourth.

To retry an install without a re-cut, ask the operator, then roll back to `bare-refresh-2026-11-19` and continue from Task 5 step 7.

## Self-review

- Spec coverage: branch and pin (Task 1); staging host (Task 2); cut with seeding (Task 3); carry off and verify (Task 4); bare stand-in, media, snapshot, air gap (Task 5); discover, conf, plan, run (Task 6); reboot and re-entry (Task 7); snapshot, archive, record, PR (Task 8); the failure loop and F6 rule (above); the four operator gates (Tasks 2, 3, 5, 6, and again in Task 7 step 3).
- The spec's four open points: disk room is checked in Task 2 step 4 (the snapshot had 373 GB free on 2026-11-12); what seeding covers is read from the cut log in Task 3 step 7; the loop media's handling is Task 5 steps 3 to 5; the manual category is empty in this rehearsal (Task 3 step 3).
- No version number appears in this file.
