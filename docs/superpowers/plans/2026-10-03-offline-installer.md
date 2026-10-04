# Offline Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `kit/scripts/r770-install.sh`, shipped inside every bundle, takes an R770 with Ubuntu installed from the bundle media to a proven lab (INSTALLED = every step clean and `r770-e2e.sh` READY) in one gated, re-enterable run.

**Architecture:** A thin bash sequencer over the kit's existing entry points (import, the GNS3/Malcolm/docs pipelines, portal, dashboards, validate, e2e), fed by a parsed (never sourced) `install.conf`. A storage check in the shared import script refuses an image load the root disk cannot hold. The build repo's fetch gains a `kit/` stage, so the bundle carries the kit under its own manifest.

**Tech Stack:** bash ≥ 4.4, coreutils, bats-core, shellcheck. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-03-offline-installer-design.md`

## Global Constraints

- Every rule in `CLAUDE.md` holds, unchanged:
  - discover, never guess, and no executed placeholder;
  - gates print current · proposed · rollback and need `--yes`, and `--non-interactive` without `--yes` stops at the gate;
  - the verifier is the bundle's;
  - one pin owner (`staging/r770-offline-fetch.sh`, edited only in simlab-build);
  - no secrets on argv or in git;
  - 0/2/1 exits and `PASS  `/`WARN  `/`FAIL  `/`SKIP  `;
  - evidence under `r770-evidence/`.
- `./tests/run.sh` is green before every kit commit: shellcheck with **no exclusions**, every suite.
- A new kit script gets: the `KIT_*` seams via `scripts/lib/common.sh`, the 0/2/1 contract, a bats suite, a `README.md` row, and an allow entry in `.claude/settings.json`.
- `staging/` is never edited here; it is resynced from simlab-build and `staging/PROVENANCE.txt` is regenerated.
- Build-repo work happens in a **new worktree off `origin/main`** at `$SB` = `/tmp/claude-0/-root-git-sim-lab-basic/fb31a2ed-91d3-44b8-9d1c-3465d089df03/scratchpad/simlab-kit-in-bundle`, branch `claude/kit-in-bundle`. Never touch `/root/git/simlab-build`'s own checkout: another session's paused work is on it.
- Never push or merge without the operator's go-ahead.
- `$SCRATCH` = `/tmp/claude-0/-root-git-sim-lab-basic/fb31a2ed-91d3-44b8-9d1c-3465d089df03/scratchpad`.
- `install.conf` default path is `/etc/lab/install.conf` (through `p()`); `--conf <file>` overrides it.
- Steps, in order: `import gns3 malcolm docs portal dashboards validate e2e`.
- Verdict words: `INSTALLED` (exit 0); `NOT INSTALLED — finished with warnings` (exit 2); `NOT INSTALLED` with a FAIL (exit 1).
- Containerd expansion factor: **317%** of the archive bytes, plus 20% headroom. Measured on VM 9770 on 2026-10-03: `/var/lib/containerd` held 24,291,046,646 B after loading `bundle-20260929`'s archives, which total 7,669,955,661 B (Malcolm 7,224,342,716 + GNS3 nodes 383,521,786 + monitoring 62,091,159).
- The kit's bundle trees: `scripts config scenarios docs` → `bundle-*/kit/`, plus `kit/KIT_COMMIT` (the full commit hash).

## Review Focus

1. **`plan` on a fresh host, before GNS3's `labnet` exists.** `lab_mirror0` is absent, so Malcolm's `full --dry-run` may refuse the interface. `plan` must report that child's verdict honestly (FAIL is FAIL, never shown as PASS), and the operator reads the reason. Pinned by the Task 6 test "plan reports a child's refusal as FAIL, never PASS".
2. **`install.conf` edited on Windows or by hand: CRLF line endings, trailing spaces, values in double quotes.** These parse to the same values as a clean file. Pinned in Task 2.
3. **A typo in `--from`/`--to`.** It dies naming the valid steps, and no child runs. Pinned in Task 4.
4. **Ctrl-C mid-run.** The summary gets a FAIL row saying "interrupted" and naming the step to rerun with `--from`, and the exit is non-zero. Pinned in Task 4.
5. **Running `run` again after INSTALLED.** The installer doesn't refuse; the children are idempotent, so it ends INSTALLED again. Pinned in Task 4.

---

## Part 1 — the kit (`/root/git/sim-lab-basic`, branch `offline-installer`)

### Task 1: The containerd image-store check

**Files:**
- Modify: `scripts/r770-import-bundle.sh` (header usage, new `image_store_check`, new `cmd_storage`, a call at the end of `cmd_docker`, dispatch)
- Test: `tests/import-bundle.bats`
- Modify: `README.md` (the import script's row mentions `storage`)

**Interfaces:**
- Produces: `r770-import-bundle.sh storage --bundle <dir>`, which is read-only and exits 0/2/1. `image_store_check <bundle-dir>` (a function in the import script) emits PASS/WARN/FAIL/SKIP rows; `cmd_docker` calls it after the data-root assertion.

- [ ] **Step 1: Write the failing tests** (append to `tests/import-bundle.bats` after the docker tests)

```bash
# ── storage — where `docker load` really writes ─────────────────────────────
# A docker stub whose DriverStatus says the containerd snapshotter is on, and a
# findmnt that puts /var/lib/containerd wherever $CTRD_MP says.
snapshotter_host() {
    stub docker 'echo "docker $*" >> "$STUB_LOG"
case "$*" in
  *DriverStatus*) echo "[[\"driver-type\",\"io.containerd.snapshotter.v1\"]]" ;;
  *DockerRootDir*) echo /var/lib/docker ;; *Mirrors*) echo "[]" ;; *Proxy*) echo ;; *) echo 0.0.0-fixture ;;
esac'
    stub findmnt 'case "$*" in *-T\ /var/lib/containerd) echo "$CTRD_MP" ;; *-T\ *) echo "${@: -1}" ;; *) exit 1 ;; esac'
}

@test "storage: no containerd snapshotter means images live under the data root — PASS, nothing else read" {
    run import storage --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  image store is the data root"* ]]
}

@test "storage: the containerd store on its own mount, or on the docker LV, is a PASS" {
    snapshotter_host
    CTRD_MP=/var/lib/containerd run import storage --bundle "$BUNDLE"
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  image store /var/lib/containerd is on its own mount"* ]]
    CTRD_MP=/var/lib/docker run import storage --bundle "$BUNDLE"
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"on the docker volume"* ]]
}

@test "storage: on the root disk with room is a WARN that prints both remedies" {
    snapshotter_host
    stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/sda1 400000000 1 300000000 1%% /\n"'
    CTRD_MP=/ run import storage --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  image store /var/lib/containerd is on / "* ]]
    [[ "$output" == *"mount a volume at /var/lib/containerd"* ]]
    [[ "$output" == *"containerd-snapshotter"* ]]
}

@test "storage: on the root disk without room is a FAIL, and the docker step stops before any load" {
    snapshotter_host
    # the fixture archives are tiny: make one big enough that 1 KiB free is not enough
    truncate -s 10M "$BUNDLE/malcolm/malcolm-images-0.0.0-fixture.tar.gz"
    stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/sda1 400 399 1 99%% /\n"'
    CTRD_MP=/ run import storage --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  image store /var/lib/containerd is on / "* ]]
    CTRD_MP=/ run import docker --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    ! grep -q '^docker load' "$STUB_LOG"
}

@test "storage: docker not answering yet is a SKIP, not a pass and not a failure" {
    stub docker 'exit 1'
    run import storage --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  image store: docker is not answering"* ]]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/import-bundle.bats --filter 'storage'`
Expected: 5 tests FAIL, with the import script's unknown-subcommand refusal for `storage`.

- [ ] **Step 3: Implement.** In `scripts/r770-import-bundle.sh`:

Header usage, after the `docker` line:

```bash
#   storage      read-only: where `docker load` will write, and whether it fits
```

Above `cmd_docker`:

```bash
# image_store_check <bundle-dir> — where `docker load` will actually write.
# With the containerd image store (the default on a fresh Docker 29 install)
# image content lands in /var/lib/containerd, NOT under the data root asserted
# above — so a guarded /var/lib/docker LV can pass while the root filesystem
# fills (staging VM 9770, 2026-09-29). Reads `docker info`, findmnt and df
# only; it never moves, prunes or reconfigures anything. The remedy is a
# storage-layout decision, so it is printed, never applied.
# CONTAINERD_EXPANSION_PCT: on-disk bytes per archive byte, measured on VM
# 9770 2026-10-03 — /var/lib/containerd 24291046646 B after loading
# bundle-20260929's archives (7669955661 B in all) = 317%.
CONTAINERD_EXPANSION_PCT=317
image_store_check() {
    local b=$1 status mp avail_kb need bytes=0 f
    status=$(docker info --format '{{json .DriverStatus}}' 2>/dev/null || true)
    case "$status" in
        "") skip "image store: docker is not answering — the docker step checks this again once the engine is installed"; return 0 ;;
        *io.containerd.snapshotter*) ;;
        *) pass "image store is the data root (no containerd snapshotter) — covered by the data-root check"; return 0 ;;
    esac
    mp=$(findmnt -n -o TARGET -T /var/lib/containerd 2>/dev/null || true)
    if [ "$mp" = /var/lib/containerd ]; then pass "image store /var/lib/containerd is on its own mount"; return 0; fi
    if [ "$mp" = /var/lib/docker ]; then pass "image store /var/lib/containerd is on the docker volume (/var/lib/docker)"; return 0; fi
    for f in "$b"/*/*images*.tar.gz "$b"/*/*/*images*.tar.gz; do
        [ -f "$f" ] && bytes=$(( bytes + $(stat -c %s "$f") ))
    done
    need=$(( bytes * CONTAINERD_EXPANSION_PCT / 100 * 120 / 100 ))
    avail_kb=$(df -Pk "${mp:-/}" 2>/dev/null | awk 'NR == 2 {print $4}')
    avail_kb=${avail_kb:-0}
    if [ $(( avail_kb * 1024 )) -ge "$need" ]; then
        warn "image store /var/lib/containerd is on ${mp:-?} (not its own volume, not the docker LV): needs ~$(( need / 1073741824 )) GiB, $(( avail_kb / 1048576 )) GiB free — it fits, but the images live outside the guarded volume"
    else
        fail "image store /var/lib/containerd is on ${mp:-?} (not its own volume, not the docker LV): needs ~$(( need / 1073741824 )) GiB, only $(( avail_kb / 1048576 )) GiB free — loading would fill it"
    fi
    note "remedy (a storage-layout decision — choose one, then rerun this step):"
    note "  1. mount a volume at /var/lib/containerd (stop docker and containerd first), then: findmnt /var/lib/containerd"
    note "  2. or turn the containerd image store off — /etc/docker/daemon.json: {\"features\": {\"containerd-snapshotter\": false}} — restart docker, then: docker info --format '{{json .DriverStatus}}'"
}

cmd_storage() {
    banner "storage — where docker load will write, and whether it fits"
    image_store_check "$(bundle_dir "$BUNDLE")"
    footer "storage"
}
```

In `cmd_docker`, between the last `pass "docker ... responding"` line and `footer "docker"`:

```bash
    image_store_check "$(bundle_dir "$BUNDLE")"
```

In the subcommand dispatch, beside `docker)`:

```bash
    storage)    cmd_storage ;;
```

(If the dispatch keeps a list of subcommands that need `--bundle`, add `storage` to it.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/import-bundle.bats`
Expected: every test passes, including the 5 new ones and the two existing docker tests (their docker stubs answer `DriverStatus` with a non-snapshotter value, or with nothing, which is a SKIP).

- [ ] **Step 5: README row, then the gate**

In `README.md`, the `scripts/r770-import-bundle.sh` row: add `storage` (read-only: where `docker load` writes and whether it fits; also run at the end of `docker`) to its subcommand list.

Run: `./tests/run.sh > "$SCRATCH/gate.log" 2>&1; echo $?; grep -E '^not ok' "$SCRATCH/gate.log"`
Expected: `0`, and no `not ok` lines.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-import-bundle.sh tests/import-bundle.bats README.md
git commit -m "r770-import-bundle.sh: storage — refuse an image load the containerd store cannot hold (measured 317%), print the remedy, never apply it"
```

---

### Task 2: `r770-install.sh` — `install.conf` and `discover`

**Files:**
- Create: `scripts/r770-install.sh` (mode 755)
- Create: `tests/install.bats`
- Modify: `README.md` (a new row), `.claude/settings.json` (an allow entry beside its siblings)

**Interfaces:**
- Consumes: `scripts/lib/common.sh` (`kit_init`, `die`, `pass`/`warn`/`fail`/`skip`, `note`, `banner`, `footer`, `p`, `common_flag`, `need_root`, `usage_from_header`, `bundle_dir`, `FORCE`).
- Produces (used by Tasks 3–6):
  - `STEPS=(import gns3 malcolm docs portal dashboards validate e2e)`;
  - `conf_load <file>`, which sets `CONF_<KEY>` for `BUNDLE MEDIA DEVICE CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR VALIDATE_AREAS`;
  - `conf_ready`, which loads `$CONF_PATH`, checks it, resolves `CONF_BUNDLE` to an absolute bundle dir, and dies on any FAIL;
  - `self_bundle`, which echoes the bundle this installer sits in (`$KIT_DIR/..`) or nothing;
  - `host_ifs` and `host_devices`;
  - globals `CONF_PATH`, `FROM`, `TO`, `SUB`;
  - the children `IMPORT GNS3 MALCOLM DOCS PORTAL VALIDATE E2E` (each overridable by `INSTALL_<NAME>_CMD`).

- [ ] **Step 1: Write the failing tests** — `tests/install.bats`:

```bash
#!/usr/bin/env bats
#
# r770-install.sh against stubbed children and a stubbed host: the
# installer's own contract. install.conf is parsed (never sourced) and
# refused on any guess; discovery chooses nothing; each step calls the
# kit entry point it names with arguments from install.conf, in order; the
# verdict is INSTALLED only when every step is clean.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-install.sh"
    export T="$BATS_TEST_TMPDIR"
    make_root "$ROOT"
    BUNDLE="$T/media/bundle-fixture"; make_bundle "$BUNDLE"
    CONF="$T/install.conf"
    stub lsblk 'printf "/dev/sda 400G disk \n/dev/sda1 400G part /\n/dev/sdb 64G disk \n/dev/sdb1 64G part /media/usb\n"'
    stub ip 'case "$*" in
  "-br addr"*)                  printf "lo UNKNOWN 127.0.0.1/8\neno1 UP 192.168.4.78/24\nens2f0 UP \n" ;;
  "-br link show type bridge"*) printf "br-lab UP\n" ;;
  "-br link"*)                  printf "lo UNKNOWN\neno1 UP\nens2f0 UP\nbr-lab UP\nlab_mirror0 UP\n" ;;
esac'
    stub findmnt 'case "$*" in -lno\ TARGET,SOURCE*) printf "/ /dev/sda1\n/media/usb /dev/sdb1\n" ;; *) exit 1 ;; esac'
    for c in import gns3 malcolm docs portal validate e2e; do
        stub "$c-stub" 'echo "'"$c"' $*" >> "$STUB_LOG"; f="$T/rc-'"$c"'"; [ -f "$f" ] && exit "$(cat "$f")"; exit 0'
    done
    export INSTALL_IMPORT_CMD="$BIN/import-stub" INSTALL_GNS3_CMD="$BIN/gns3-stub" INSTALL_MALCOLM_CMD="$BIN/malcolm-stub" \
           INSTALL_DOCS_CMD="$BIN/docs-stub" INSTALL_PORTAL_CMD="$BIN/portal-stub" INSTALL_VALIDATE_CMD="$BIN/validate-stub" \
           INSTALL_E2E_CMD="$BIN/e2e-stub"
}

inst() { kit_run "$SCRIPT" "$@"; }
good_conf() {
    cat > "$CONF" <<EOF
# a filled-in answers file
BUNDLE=$BUNDLE
MEDIA=/media/usb
DEVICE=/dev/sdb1
CAPTURE_IFS=lab_mirror0
LAB_BRIDGE=br-lab
MGMT_IF=eno1
MGMT_CIDR=192.168.4.0/24
EOF
}

@test "discover prints what the host has and writes only the template — every value empty" {
    run inst discover
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/dev/sdb1"* ]]; [[ "$output" == *"eno1"* ]]; [[ "$output" == *"/media/usb"* ]]
    tpl="$ROOT/etc/lab/install.conf.template"
    [ -s "$tpl" ]
    [ ! -e "$ROOT/etc/lab/install.conf" ]
    run grep -E '^[A-Z_]+=.+' "$tpl"
    [ "$status" -ne 0 ]     # no key carries a value
    for k in BUNDLE MEDIA DEVICE CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR VALIDATE_AREAS; do grep -q "^$k=$" "$tpl"; done
}

@test "a missing answers file is refused, naming discover" {
    run inst run --conf "$T/nope.conf" --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"discover"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "install.conf is parsed, never sourced: shell in a value is not executed" {
    good_conf
    printf 'MGMT_CIDR=$(touch %s/pwned)\n' "$T" >> "$CONF"
    run inst run --conf "$CONF" --yes --from gns3 --to gns3
    [ ! -e "$T/pwned" ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"MGMT_CIDR"* ]]
}

@test "install.conf: an unknown key, an empty required key and each placeholder are FAILs, all reported, no child runs" {
    good_conf
    echo "NIC=eno1" >> "$CONF"
    run inst run --conf "$CONF" --yes
    [ "$status" -eq 1 ]; [[ "$output" == *"unknown key NIC"* ]]
    good_conf; sed -i 's#^DEVICE=.*#DEVICE=/dev/sdX#; s#^MGMT_IF=.*#MGMT_IF=#; s#^MEDIA=.*#MEDIA=<mountpoint>#' "$CONF"
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  install.conf: DEVICE is a placeholder"* ]]
    [[ "$output" == *"FAIL  install.conf: MGMT_IF is empty"* ]]
    [[ "$output" == *"FAIL  install.conf: MEDIA is a placeholder"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "install.conf: a device or interface this host does not have is a FAIL; lab_mirror0 and the lab bridge may wait for labnet" {
    good_conf; sed -i 's#^DEVICE=.*#DEVICE=/dev/sdz1#; s#^CAPTURE_IFS=.*#CAPTURE_IFS="lab_mirror0 ens9"#' "$CONF"
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DEVICE /dev/sdz1 is not a block device on this host"* ]]
    [[ "$output" == *"CAPTURE_IFS: ens9 does not exist"* ]]
    stub ip 'case "$*" in "-br link"*) printf "lo UNKNOWN\neno1 UP\n" ;; esac'
    good_conf
    run inst run --conf "$CONF" --yes --from gns3 --to gns3
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lab_mirror0"*"created by the gns3 step"* ]]
}

@test "install.conf with CRLF endings, trailing spaces and quoted values parses the same as a clean one" {
    good_conf
    sed -i 's/$/  \r/; s#^MGMT_CIDR=.*#MGMT_CIDR="192.168.4.0/24"  \r#' "$CONF"
    run inst run --conf "$CONF" --yes --from gns3 --to gns3
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "gns3 full --bundle $BUNDLE" "$STUB_LOG"
}

@test "BUNDLE may be left empty only when the installer sits inside a bundle bundle_dir accepts" {
    good_conf; sed -i 's#^BUNDLE=.*#BUNDLE=#' "$CONF"
    run inst run --conf "$CONF" --yes --from gns3 --to gns3
    [ "$status" -eq 1 ]
    [[ "$output" == *"BUNDLE is empty and this installer is not inside a bundle"* ]]
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    run kit_run "$BUNDLE/kit/scripts/r770-install.sh" run --conf "$CONF" --yes --from gns3 --to gns3
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "gns3 full --bundle $BUNDLE" "$STUB_LOG"
}
```

(Tests that reach a step (`--from gns3 --to gns3` ending in status 0) go GREEN in Task 4. Task 2's GREEN is the four tests that refuse before any step: `discover`, the missing file, never-sourced, and unknown/empty/placeholder. `run` exists here as `conf_ready` followed by `die "run: not implemented yet"`, so those refusals are real now. Task 4 replaces that line.)

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/install.bats`
Expected: every test FAILs (the script does not exist).

- [ ] **Step 3: Implement** — `scripts/r770-install.sh`:

```bash
#!/usr/bin/env bash
#
# r770-install.sh — the offline installer. Takes an R770 with Ubuntu 24.04
# installed, plus the bundle media, to a proven lab in one gated,
# re-enterable run. A thin sequencer: every step is an existing kit entry
# point, called with arguments read from install.conf; no pipeline logic
# lives here, and each pipeline still runs on its own.
#
#   r770-install.sh <subcommand> [options]
#
#   discover   print disks, NICs, addresses, bridges, mounts; write
#              install.conf.template (every value empty: nothing is chosen for you)
#   wizard     pick each value from numbered lists of what discover found;
#              write install.conf
#   plan       check install.conf and the image store, then every gated step
#              under --dry-run: the whole current/proposed/rollback review at once
#   run        import gns3 malcolm docs portal dashboards validate e2e, in order;
#              stops at the first FAIL; re-enter with --from <step>
#   status     which of those steps this host has finished
#
#   --conf FILE              the answers file (default /etc/lab/install.conf)
#   --from STEP / --to STEP  a slice of run's steps
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#                            (run --yes is unattended: it also implies --non-interactive)
#
#   INSTALL_IMPORT_CMD INSTALL_GNS3_CMD INSTALL_MALCOLM_CMD INSTALL_DOCS_CMD
#   INSTALL_PORTAL_CMD INSTALL_VALIDATE_CMD INSTALL_E2E_CMD   the children (tests stub them)
#
#   0  INSTALLED · 2  finished with warnings (never INSTALLED) · 1  refused or failed
#
# Started from the media, `run` imports the bundle (preflight, gate, copy —
# copy WITHOUT --media, so nothing unmounts the media this script is running
# from) and then execs the installer inside the local copy under
# /srv/bundles/<name>/kit, which carries on from gns3. Unmounting the media
# is the operator's last step; the summary prints the command.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

STEPS=(import gns3 malcolm docs portal dashboards validate e2e)
CONF_KEYS="BUNDLE MEDIA DEVICE CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR VALIDATE_AREAS"
REQUIRED_KEYS="MEDIA DEVICE CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR"
LATE_IFS="lab_mirror0"        # created by the gns3 step's labnet, so it may not exist yet
IMPORT="${INSTALL_IMPORT_CMD:-$KIT_DIR/scripts/r770-import-bundle.sh}"
GNS3="${INSTALL_GNS3_CMD:-$KIT_DIR/scripts/r770-gns3-deploy.sh}"
MALCOLM="${INSTALL_MALCOLM_CMD:-$KIT_DIR/scripts/r770-malcolm-deploy.sh}"
DOCS="${INSTALL_DOCS_CMD:-$KIT_DIR/scripts/r770-docs-deploy.sh}"
PORTAL="${INSTALL_PORTAL_CMD:-$KIT_DIR/scripts/r770-portal-deploy.sh}"
VALIDATE="${INSTALL_VALIDATE_CMD:-$KIT_DIR/scripts/r770-validate.sh}"
E2E="${INSTALL_E2E_CMD:-$KIT_DIR/scripts/r770-e2e.sh}"
SUB=""; CONF_PATH=""; FROM=""; TO=""
usage() { usage_from_header 3; exit 0; }

# ── install.conf ─────────────────────────────────────────────────────────────
conf_get() { local n="CONF_$1"; printf '%s' "${!n:-}"; }

# conf_load <file> — KEY=value lines into CONF_<KEY>. Parsed, never sourced:
# operator text is never evaluated. CR, surrounding blanks and one pair of
# double quotes are stripped, so a file edited on Windows reads the same.
conf_load() {
    local f=$1 line key val n=0
    [ -f "$f" ] || die "no answers file at $f — run 'r770-install.sh discover' (or wizard) first, then fill it in"
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%$'\r'}
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "$f:$n: not KEY=value: $line"
        key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        [[ "$val" == \"*\" ]] && { val=${val#\"}; val=${val%\"}; }
        case " $CONF_KEYS " in *" $key "*) ;; *) die "$f:$n: unknown key $key (known: $CONF_KEYS)" ;; esac
        printf -v "CONF_$key" '%s' "$val"
    done < "$f"
}

is_placeholder() {
    case "$1" in *'<'*|*'>'*|*CHANGEME*|*changeme*|/dev/sdX|/dev/sdX[0-9]*) return 0 ;; esac
    return 1
}
host_ifs()     { ip -br link 2>/dev/null | awk '{print $1}' | sed 's/@.*//'; }
host_devices() { lsblk -lpno NAME 2>/dev/null | awk '{print $1}'; }
has_line()     { printf '%s\n' "$2" | grep -qxF -- "$1"; }

# self_bundle — the bundle this installer sits in (kit/scripts/.. /..), or nothing.
self_bundle() {
    local cand; cand=$(cd "$KIT_DIR/.." 2>/dev/null && pwd -P) || return 0
    ( bundle_dir "$cand" ) >/dev/null 2>&1 && printf '%s' "$cand"
    return 0
}

# conf_check — every bad value is its own FAIL row; then one die, so the
# operator fixes the whole file in one pass.
conf_check() {
    local k v ifs devs i bad=0
    for k in $REQUIRED_KEYS; do
        v=$(conf_get "$k")
        if [ -z "$v" ]; then fail "install.conf: $k is empty — fill it from 'discover' output"; bad=1
        elif is_placeholder "$v"; then fail "install.conf: $k is a placeholder ($v) — never executed"; bad=1; fi
    done
    ifs=$(host_ifs); devs=$(host_devices)
    v=$CONF_DEVICE
    if [ -n "$v" ] && ! is_placeholder "$v" && ! has_line "$v" "$devs"; then
        fail "install.conf: DEVICE $v is not a block device on this host (lsblk)"; bad=1
    fi
    v=$CONF_MGMT_IF
    if [ -n "$v" ] && ! is_placeholder "$v" && ! has_line "$v" "$ifs"; then
        fail "install.conf: MGMT_IF $v does not exist on this host (ip -br link)"; bad=1
    fi
    for i in $CONF_CAPTURE_IFS; do
        if has_line "$i" "$ifs"; then continue; fi
        case " $LATE_IFS " in
            *" $i "*) note "CAPTURE_IFS: $i is not here yet — created by the gns3 step's labnet" ;;
            *) fail "install.conf: CAPTURE_IFS: $i does not exist on this host (ip -br link)"; bad=1 ;;
        esac
    done
    if [ -n "$CONF_LAB_BRIDGE" ] && ! has_line "$CONF_LAB_BRIDGE" "$ifs"; then
        note "LAB_BRIDGE: $CONF_LAB_BRIDGE is not here yet — created by the gns3 step's labnet"
    fi
    v=$CONF_MGMT_CIDR
    if [ -n "$v" ] && ! is_placeholder "$v" && ! [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
        fail "install.conf: MGMT_CIDR $v is not a.b.c.d/n"; bad=1
    fi
    if [ -z "$CONF_BUNDLE" ]; then
        CONF_BUNDLE=$(self_bundle)
        if [ -n "$CONF_BUNDLE" ]; then note "BUNDLE: the bundle this installer came in — $CONF_BUNDLE"
        else fail "install.conf: BUNDLE is empty and this installer is not inside a bundle — set BUNDLE=<the bundle directory on the media>"; bad=1; fi
    elif ! ( bundle_dir "$CONF_BUNDLE" ) >/dev/null 2>&1; then
        fail "install.conf: BUNDLE $CONF_BUNDLE is not a bundle (r770-bundle.sh, BUNDLE_NOTES.md, MANIFEST.sha256 at its root)"; bad=1
    else
        CONF_BUNDLE=$(cd "$CONF_BUNDLE" && pwd)
    fi
    [ "$bad" = 0 ] || die "install.conf ($CONF_PATH) refused — fix every FAIL above; nothing ran"
}

conf_ready() {
    local k; for k in $CONF_KEYS; do printf -v "CONF_$k" '%s' ""; done
    conf_load "$CONF_PATH"
    conf_check
}

# ── discover ─────────────────────────────────────────────────────────────────
cmd_discover() {
    banner "discover — what this host has (nothing is chosen for you)"
    local tpl cand
    tpl="${CONF_PATH}.template"
    echo "-- block devices (DEVICE: the transfer media's device) --"; lsblk -lpno NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || echo "   (lsblk unavailable)"
    echo "-- mounts (MEDIA: where the media is mounted) --";            findmnt -lno TARGET,SOURCE 2>/dev/null || echo "   (findmnt unavailable)"
    echo "-- interfaces (MGMT_IF; capture ports for CAPTURE_IFS) --";   ip -br addr 2>/dev/null || echo "   (ip unavailable)"
    echo "-- bridges (LAB_BRIDGE once labnet exists) --";               ip -br link show type bridge 2>/dev/null || true
    cand=$(self_bundle)
    mkdir -p "$(dirname "$tpl")" || die "cannot create $(dirname "$tpl")"
    cat > "$tpl" <<EOF
# install.conf — template written by r770-install.sh discover on $(hostname -s 2>/dev/null || echo host), $(date -Is).
# Fill in every value from the discovery output; nothing has been chosen for you.
# Save the result as $CONF_PATH (or pass --conf), then: r770-install.sh plan
#
# BUNDLE: the bundle directory. Empty means the bundle this installer came in: ${cand:-none found}
BUNDLE=
# MEDIA: where the transfer media is mounted (see "mounts" above)
MEDIA=
# DEVICE: the media's block device, e.g. a partition of the USB disk (see "block devices" above)
DEVICE=
# CAPTURE_IFS: Malcolm's capture interfaces, space separated: lab_mirror0 (the lab mirror) plus any physical tap port
CAPTURE_IFS=
# LAB_BRIDGE: the lab bridge the gns3 step's labnet creates (r770-gns3-deploy.sh: br-lab)
LAB_BRIDGE=
# MGMT_IF: the management interface (see "interfaces" above)
MGMT_IF=
# MGMT_CIDR: the management network, a.b.c.d/n
MGMT_CIDR=
# VALIDATE_AREAS: optional, space separated; empty means every area (r770-validate.sh --list)
VALIDATE_AREAS=
EOF
    pass "template written: $tpl — fill it in and save it as $CONF_PATH"
    footer "discover"
}

# ── arguments ────────────────────────────────────────────────────────────────
[ $# -gt 0 ] || usage
SUB=$1; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --conf)     CONF_PATH="${2:-}"; shift ;;
        --from)     FROM="${2:-}"; shift ;;
        --to)       TO="${2:-}"; shift ;;
        -h|--help)  usage ;;
        *)          common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
CONF_PATH="${CONF_PATH:-$(p /etc/lab/install.conf)}"

kit_init "r770-install"
case "$SUB" in
    discover) cmd_discover ;;
    run)      need_root; conf_ready; die "run: not implemented yet" ;;
    -h|--help|help) usage ;;
    *)        die "unknown subcommand: $SUB (try --help)" ;;
esac
```

- [ ] **Step 4: Run the Task 2 tests to verify they pass**

Run: `bats tests/install.bats --filter 'discover|missing answers|never sourced|unknown key'`
Expected: 4/4 pass. The rest still FAIL on `run: not implemented yet` until Task 4.

- [ ] **Step 5: README row, allow entry, gate**

In `README.md`'s script table, a row beside `r770-e2e.sh`:

```
| `scripts/r770-install.sh` | The offline installer: `discover` (what the host has; a template with nothing chosen), `wizard` (pick from what was found), `plan` (every gated change under `--dry-run`, in one review), `run` (import, gns3, malcolm, docs, portal, dashboards, validate, e2e; INSTALLED only when every step is clean), `status`. Ships in every bundle as `kit/scripts/r770-install.sh` |
```

In `.claude/settings.json`, copy the existing allow entry for `scripts/r770-e2e.sh`, and change the script name to `r770-install.sh`.

Run: `./tests/run.sh > "$SCRATCH/gate.log" 2>&1; echo $?; grep -E '^not ok' "$SCRATCH/gate.log"`
Expected: non-zero, and the only `not ok` lines are the `tests/install.bats` tests that need `run` (Task 4). shellcheck is clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-install.sh tests/install.bats README.md .claude/settings.json
git commit -m "r770-install.sh: install.conf parsed never sourced, refused on any guess; discover writes a template with nothing chosen"
```

---

### Task 3: `wizard`

**Files:**
- Modify: `scripts/r770-install.sh`
- Test: `tests/install.bats`

**Interfaces:**
- Consumes: `self_bundle`, `CONF_PATH`, `host_devices`, `FORCE`.
- Produces: `r770-install.sh wizard [--conf FILE] [--force]`, which writes `install.conf` and nothing else.

Menu order under the suite's stubs:
- MEDIA: `/`, `/media/usb`.
- DEVICE: `/dev/sda`, `/dev/sda1`, `/dev/sdb`, `/dev/sdb1`.
- MGMT_IF: every interface from `ip -br addr` except `lo`, so `eno1`, `ens2f0`.
- Extra capture ports: those interfaces minus MGMT_IF, so with `eno1` picked, `ens2f0`.
- LAB_BRIDGE: the existing bridges plus `br-lab`, deduplicated, so `br-lab`.

- [ ] **Step 1: Write the failing tests** (append)

```bash
@test "wizard writes exactly the values picked from what discovery found, and nothing else" {
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    # media 2 (/media/usb) · device 4 (/dev/sdb1) · mgmt 1 (eno1) · extra capture ports: none · bridge 1 (br-lab)
    run bash -c "printf '2\n4\n1\n\n1\n' | PATH='$KIT_PATH' '$BUNDLE/kit/scripts/r770-install.sh' wizard --conf '$CONF'"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "BUNDLE=$BUNDLE" "$CONF"
    grep -qx "MEDIA=/media/usb" "$CONF"
    grep -qx "DEVICE=/dev/sdb1" "$CONF"
    grep -qx "MGMT_IF=eno1" "$CONF"
    grep -qx "MGMT_CIDR=192.168.4.0/24" "$CONF"
    grep -qx "CAPTURE_IFS=lab_mirror0" "$CONF"
    grep -qx "LAB_BRIDGE=br-lab" "$CONF"
    [ ! -s "$STUB_LOG" ]
}

@test "wizard: extra capture ports are picked by number; an out-of-range answer is asked again" {
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    # device answer 9 is out of range, then 4; extra capture port 1 (ens2f0)
    run bash -c "printf '2\n9\n4\n1\n1\n1\n' | PATH='$KIT_PATH' '$BUNDLE/kit/scripts/r770-install.sh' wizard --conf '$CONF'"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not one of"* ]]
    grep -qx "CAPTURE_IFS=lab_mirror0 ens2f0" "$CONF"
}

@test "wizard refuses a management interface with no address" {
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    run bash -c "printf '2\n4\n2\n' | PATH='$KIT_PATH' '$BUNDLE/kit/scripts/r770-install.sh' wizard --conf '$CONF'"
    [ "$status" -eq 1 ]; [[ "$output" == *"has no IPv4 address"* ]]
    [ ! -e "$CONF" ]
}

@test "wizard never overwrites an existing install.conf without --force, and dies on end of input" {
    good_conf
    run bash -c "printf '' | PATH='$KIT_PATH' '$SCRIPT' wizard --conf '$CONF'"
    [ "$status" -eq 1 ]; [[ "$output" == *"--force"* ]]
    rm -f "$CONF"
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    run bash -c "printf '2\n' | PATH='$KIT_PATH' '$BUNDLE/kit/scripts/r770-install.sh' wizard --conf '$CONF'"
    [ "$status" -eq 1 ]
    [ ! -e "$CONF" ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/install.bats --filter wizard`
Expected: 4 FAIL with `unknown subcommand: wizard`.

- [ ] **Step 3: Implement** (add above `# ── arguments`):

```bash
# ── wizard ───────────────────────────────────────────────────────────────────
# pick <prompt> <option...> — a numbered menu on stderr; echoes the choice.
# End of input is a refusal, never a default.
pick() {
    local prompt=$1; shift
    local opts=("$@") i a
    [ "${#opts[@]}" -gt 0 ] || die "nothing discovered for: $prompt — write install.conf by hand from 'discover'"
    { echo; echo "$prompt"; for i in "${!opts[@]}"; do printf '  %d) %s\n' $((i + 1)) "${opts[$i]}"; done; } >&2
    while :; do
        read -r -p "choice [1-${#opts[@]}]: " a || die "no answer for: $prompt — nothing written"
        if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#opts[@]}" ]; then printf '%s' "${opts[$((a - 1))]}"; return 0; fi
        echo "  not one of 1-${#opts[@]}" >&2
    done
}
# pick_many <prompt> <option...> — space-separated numbers, empty for none.
pick_many() {
    local prompt=$1; shift
    local opts=("$@") i a n out ok
    [ "${#opts[@]}" -gt 0 ] || return 0
    { echo; echo "$prompt"; for i in "${!opts[@]}"; do printf '  %d) %s\n' $((i + 1)) "${opts[$i]}"; done; } >&2
    while :; do
        read -r -p "numbers, space separated (empty for none): " a || die "no answer for: $prompt — nothing written"
        out=""; ok=1
        for n in $a; do
            if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#opts[@]}" ]; then out="$out ${opts[$((n - 1))]}"; else ok=0; fi
        done
        [ "$ok" = 1 ] && { printf '%s' "${out# }"; return 0; }
        echo "  each must be one of 1-${#opts[@]}" >&2
    done
}

cmd_wizard() {
    banner "wizard — pick each value from what this host has"
    [ ! -e "$CONF_PATH" ] || [ "$FORCE" = "1" ] || die "$CONF_PATH exists — edit it, or rerun with --force to replace it"
    local bundle media device mgmt addr cidr extras bridge
    local -a mounts devs mgmts others bridges
    bundle=$(self_bundle)
    [ -n "$bundle" ] || die "this installer is not inside a bundle — run the one in <media>/<bundle>/kit/scripts/, or write install.conf by hand"
    mapfile -t mounts  < <(findmnt -lno TARGET,SOURCE 2>/dev/null | awk '{print $1}')
    mapfile -t devs    < <(host_devices)
    mapfile -t mgmts   < <(ip -br addr 2>/dev/null | awk '$1 != "lo" {print $1}' | sed 's/@.*//')
    media=$(pick "MEDIA — where the transfer media is mounted:" "${mounts[@]}") || exit 1
    device=$(pick "DEVICE — the media's block device:" "${devs[@]}") || exit 1
    mgmt=$(pick "MGMT_IF — the management interface:" "${mgmts[@]}") || exit 1
    addr=$(ip -br addr 2>/dev/null | awk -v i="$mgmt" '$1 == i {print $3}')
    [ -n "$addr" ] || die "MGMT_IF $mgmt has no IPv4 address — pick the interface the box is managed through"
    cidr=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$addr") || die "cannot read a network from $addr"
    mapfile -t others  < <(printf '%s\n' "${mgmts[@]}" | grep -vxF -- "$mgmt")
    extras=$(pick_many "CAPTURE_IFS — physical tap ports to capture beside lab_mirror0:" "${others[@]}") || exit 1
    mapfile -t bridges < <({ ip -br link show type bridge 2>/dev/null | awk '{print $1}'; echo br-lab; } | awk '!seen[$0]++')
    bridge=$(pick "LAB_BRIDGE — the lab bridge (br-lab is the one the gns3 step's labnet creates):" "${bridges[@]}") || exit 1
    mkdir -p "$(dirname "$CONF_PATH")" || die "cannot create $(dirname "$CONF_PATH")"
    cat > "$CONF_PATH" <<EOF
# install.conf — written by r770-install.sh wizard on $(hostname -s 2>/dev/null || echo host), $(date -Is)
BUNDLE=$bundle
MEDIA=$media
DEVICE=$device
CAPTURE_IFS=lab_mirror0${extras:+ $extras}
LAB_BRIDGE=$bridge
MGMT_IF=$mgmt
MGMT_CIDR=$cidr
VALIDATE_AREAS=
EOF
    pass "written: $CONF_PATH — next: r770-install.sh plan"
    footer "wizard"
}
```

Dispatch: `wizard)  cmd_wizard ;;`

(`pick` runs in a command substitution, so its `die` ends only the subshell; the `|| exit 1` after each one carries the refusal out. `die` already printed the reason.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/install.bats --filter 'wizard|discover|never sourced|unknown key|missing'`
Expected: all pass.

- [ ] **Step 5: Gate**

Run: `./tests/run.sh > "$SCRATCH/gate.log" 2>&1; grep -E '^not ok' "$SCRATCH/gate.log"`
Expected: only the `run`-dependent `install.bats` tests remain `not ok`; shellcheck is clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-install.sh tests/install.bats
git commit -m "r770-install.sh wizard: numbered menus of what the host has, writes install.conf, refuses end of input and an existing file"
```

---

### Task 4: `run` (steps gns3 → e2e), the summary, and `status`

**Files:**
- Modify: `scripts/r770-install.sh`
- Test: `tests/install.bats`

**Interfaces:**
- Consumes: `conf_ready`, `CONF_*`, and `run_step`/`step_index`/`stamp`/`stamped`/`STAMP_DIR` from `common.sh`.
- Produces:
  - `local_bundle`, which echoes `$(p /srv/bundles)/<basename CONF_BUNDLE>` when that exists, else `CONF_BUNDLE`;
  - `LOGDIR` (taken from `INSTALL_LOGDIR` when set), so Task 5's hand-off keeps one log directory;
  - `summary_row <step> <verdict> <detail>`, which appends to `$LOGDIR.md`;
  - `step_body <step>`;
  - the stamps `install.<step>`.

- [ ] **Step 1: Write the failing tests** (append)

```bash
@test "run --from gns3: every step calls its entry point with install.conf's values, in order, and ends INSTALLED" {
    good_conf
    run inst run --conf "$CONF" --yes --from gns3
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALLED"* ]]; [[ "$output" != *"NOT INSTALLED"* ]]
    logdir=$(ls -d "$KIT_EVIDENCE_DIR"/install-*/ | head -1); logdir=${logdir%/}
    run cat "$STUB_LOG"
    [ "${lines[0]}" = "gns3 full --bundle $BUNDLE" ]
    [ "${lines[1]}" = "malcolm full --bundle $BUNDLE --capture-ifs lab_mirror0" ]
    [ "${lines[2]}" = "docs full --bundle $BUNDLE" ]
    [ "${lines[3]}" = "portal ca" ]
    [ "${lines[4]}" = "portal cert" ]
    [ "${lines[5]}" = "portal htpasswd" ]
    [ "${lines[6]}" = "portal nginx" ]
    [ "${lines[7]}" = "malcolm dashboards" ]
    [ "${lines[8]}" = "malcolm arkime-views" ]
    [ "${lines[9]}" = "validate --capture-ifs lab_mirror0 --lab-bridge br-lab --mgmt-if eno1 --mgmt-cidr 192.168.4.0/24 --out $logdir" ]
    [ "${lines[10]}" = "e2e --bundle $BUNDLE --capture-ifs lab_mirror0 --lab-bridge br-lab --skip-validate --out $logdir" ]
    grep -q '^| e2e | PASS |' "$logdir.md"
    grep -q '^INSTALLED' "$logdir.md"
    grep -q 'umount /media/usb' "$logdir.md"
}

@test "run passes VALIDATE_AREAS as one --area per area, and the local bundle copy once it exists" {
    good_conf; echo 'VALIDATE_AREAS=network gns3' >> "$CONF"
    mkdir -p "$ROOT/srv/bundles/bundle-fixture"
    run inst run --conf "$CONF" --yes --from validate
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q -- '--area network --area gns3' "$STUB_LOG"
    grep -q "^e2e --bundle $ROOT/srv/bundles/bundle-fixture " "$STUB_LOG"
}

@test "the first FAIL stops the run, names the step to rerun with --from, and lands in the summary" {
    good_conf; echo 1 > "$T/rc-malcolm"
    run inst run --conf "$CONF" --yes --from gns3
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--from malcolm"* ]]
    ! grep -q '^docs ' "$STUB_LOG"
    logdir=$(ls -d "$KIT_EVIDENCE_DIR"/install-*/ | head -1); logdir=${logdir%/}
    grep -q '^| malcolm | FAIL |' "$logdir.md"
    grep -q '^NOT INSTALLED' "$logdir.md"
}

@test "a step that warns makes the verdict NOT INSTALLED (exit 2), never INSTALLED" {
    good_conf; echo 2 > "$T/rc-e2e"
    run inst run --conf "$CONF" --yes --from gns3
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"NOT INSTALLED — finished with warnings from: e2e"* ]]
}

@test "run without --yes adds no answer: the child sees no KIT_YES and its gate decides" {
    good_conf
    unset KIT_YES
    stub gns3-stub 'echo "gns3 $* yes=${KIT_YES:-}" >> "$STUB_LOG"; exit 1'
    run inst run --conf "$CONF" --non-interactive --from gns3
    echo "$output"
    [ "$status" -eq 1 ]
    grep -qx "gns3 full --bundle $BUNDLE yes=" "$STUB_LOG"
}

@test "--from/--to: a slice runs alone; a typo names the valid steps and runs nothing" {
    good_conf
    run inst run --conf "$CONF" --yes --from docs --to portal
    [ "$status" -eq 0 ]
    run cut -d' ' -f1 "$STUB_LOG"; [ "${lines[0]}" = docs ]; [ "${#lines[@]}" -eq 5 ]
    : > "$STUB_LOG"
    run inst run --conf "$CONF" --yes --from malcom
    [ "$status" -eq 1 ]
    [[ "$output" == *"import gns3 malcolm docs portal dashboards validate e2e"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "Ctrl-C mid-run: the summary says interrupted and names the step to rerun" {
    good_conf
    stub docs-stub 'echo "docs $*" >> "$STUB_LOG"; pg=$(cut -d" " -f5 /proc/$$/stat); kill -INT -- "-$pg"; sleep 2'
    run inst run --conf "$CONF" --yes --from gns3
    echo "$output"
    [ "$status" -ne 0 ]
    logdir=$(ls -d "$KIT_EVIDENCE_DIR"/install-*/ | head -1); logdir=${logdir%/}
    grep -q '^| docs | FAIL | interrupted' "$logdir.md"
    grep -q -- '--from docs' "$logdir.md"
}

@test "run again after INSTALLED: not refused, INSTALLED again (the children are idempotent)" {
    good_conf
    run inst run --conf "$CONF" --yes --from gns3; [ "$status" -eq 0 ]
    run inst run --conf "$CONF" --yes --from gns3; [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALLED"* ]]
}

@test "status lists each step as done or not, from the installer's own stamps" {
    good_conf
    run inst run --conf "$CONF" --yes --from gns3 --to malcolm
    run inst status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gns3"*"done"* ]]
    [[ "$output" == *"docs"*"not yet"* ]]
}
```

(The interrupt test signals the process group, as `tests/e2e.bats` does, because `run_step` runs the child in a subshell, so `$PPID` would be that subshell. If bats' own process shares the group and the test aborts, run the installer under `setsid` in that test and ledger a Ruling.)

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/install.bats --filter 'run|status|slice|Ctrl-C|again|warns|FAIL stops'`
Expected: FAIL on `run: not implemented yet` / `unknown subcommand: status`.

- [ ] **Step 3: Implement** (add above `# ── arguments`; replace the `run)` dispatch line):

```bash
# ── run ──────────────────────────────────────────────────────────────────────
LOGDIR=""; CUR=""
local_bundle() {  # after import's copy, the bundle lives under /srv/bundles
    local l; l="$(p /srv/bundles)/$(basename "$CONF_BUNDLE")"
    if [ -d "$l" ]; then printf '%s' "$l"; else printf '%s' "$CONF_BUNDLE"; fi
}
summary_row() {  # summary_row <step> <PASS|WARN|FAIL> <detail>
    printf '| %s | %s | %s |\n' "$1" "$2" "$3" >> "$LOGDIR.md"
}
summary_open() {
    [ -s "$LOGDIR.md" ] && return 0
    {
        echo "# Install — $(hostname -s 2>/dev/null || echo host) — $(date -Is)"
        echo
        echo "Bundle: \`$CONF_BUNDLE\` · answers: \`$CONF_PATH\` · each step's output: \`$LOGDIR/\`"
        echo
        echo "| Step | Verdict | Detail |"
        echo "|---|---|---|"
    } > "$LOGDIR.md"
}
# logged <name> <cmd...> — a child's output to the terminal and to $LOGDIR/<name>.log
logged() {
    local name=$1; shift
    "$@" 2>&1 | tee -a "$LOGDIR/$name.log"
    return "${PIPESTATUS[0]}"
}
on_exit() {
    local rc=$? why
    [ -n "$CUR" ] || return 0
    why="see $LOGDIR/$CUR*.log"
    [ "$rc" = 130 ] && why="interrupted"
    summary_row "$CUR" FAIL "$why — fix it, then: r770-install.sh run --yes --from $CUR"
    printf '\nNOT INSTALLED — %s at %s; rerun with --from %s\n' "$why" "$CUR" "$CUR" >> "$LOGDIR.md"
}
step_body() {  # step_body <step> — the children of one step
    local lb s a; lb=$(local_bundle)
    local -a args
    case "$1" in
        gns3)    run_step gns3 logged gns3 "$GNS3" full --bundle "$lb" ;;
        malcolm) run_step malcolm logged malcolm "$MALCOLM" full --bundle "$lb" --capture-ifs "$CONF_CAPTURE_IFS" ;;
        docs)    run_step docs logged docs "$DOCS" full --bundle "$lb" ;;
        portal)  for s in ca cert htpasswd nginx; do run_step portal logged "portal-$s" "$PORTAL" "$s"; done ;;
        dashboards)
                 run_step dashboards logged dashboards "$MALCOLM" dashboards
                 run_step dashboards logged arkime-views "$MALCOLM" arkime-views ;;
        validate)
                 args=(--capture-ifs "$CONF_CAPTURE_IFS" --lab-bridge "$CONF_LAB_BRIDGE" --mgmt-if "$CONF_MGMT_IF" --mgmt-cidr "$CONF_MGMT_CIDR")
                 for a in $CONF_VALIDATE_AREAS; do args+=(--area "$a"); done
                 run_step validate logged validate "$VALIDATE" "${args[@]}" --out "$LOGDIR" ;;
        e2e)     run_step e2e logged e2e "$E2E" --bundle "$lb" --capture-ifs "$CONF_CAPTURE_IFS" --lab-bridge "$CONF_LAB_BRIDGE" --skip-validate --out "$LOGDIR" ;;
    esac
}
cmd_run() {
    need_root
    conf_ready
    local first=0 last=$(( ${#STEPS[@]} - 1 )) i step verdict rc=0 warned
    [ -z "$FROM" ] || first=$(step_index STEPS "$FROM") || die "unknown step: $FROM (steps: ${STEPS[*]})"
    [ -z "$TO" ]   || last=$(step_index STEPS "$TO")    || die "unknown step: $TO (steps: ${STEPS[*]})"
    [ "$first" -le "$last" ] || die "--from $FROM comes after --to $TO"
    if [ "${KIT_YES:-0}" = "1" ]; then KIT_NON_INTERACTIVE=1; export KIT_NON_INTERACTIVE; fi
    LOGDIR="${INSTALL_LOGDIR:-${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}/install-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S)}"
    mkdir -p "$LOGDIR" || die "cannot create $LOGDIR"
    summary_open
    trap on_exit EXIT
    trap 'exit 130' INT TERM
    WARNED_STEPS=""
    for i in $(seq "$first" "$last"); do
        step=${STEPS[$i]}
        banner "$(( i + 1 ))/${#STEPS[@]}  $step"
        CUR=$step
        step_body "$step"
        case " $WARNED_STEPS " in
            *" $step "*) summary_row "$step" WARN "warnings accepted via --yes — disposition each ($LOGDIR/$step*.log)" ;;
            *)           summary_row "$step" PASS "clean" ;;
        esac
        stamp "install.$step"
        CUR=""
    done
    # shellcheck disable=SC2086  # word-split the space-separated step list on purpose
    warned=$(printf '%s\n' $WARNED_STEPS | awk 'NF && !seen[$0]++' | tr '\n' ' ')
    if [ -n "$warned" ]; then verdict="NOT INSTALLED — finished with warnings from: ${warned% }; disposition each, then rerun with --from <step>"; rc=2
    elif [ "$last" -lt $(( ${#STEPS[@]} - 1 )) ]; then verdict="steps ${STEPS[$first]}..${STEPS[$last]} clean — not INSTALLED until e2e has run"
    else verdict="INSTALLED — every step clean and the lab proven end to end"; fi
    { echo; echo "$verdict"; echo; echo "Last step for the operator: remove the media — umount ${CONF_MEDIA}"; } >> "$LOGDIR.md"
    echo; echo "$verdict"; note "summary: $LOGDIR.md"; note "remove the media: umount ${CONF_MEDIA}"
    exit "$rc"
}

# ── status ───────────────────────────────────────────────────────────────────
cmd_status() {
    banner "status — the installer's steps on this host"
    local s
    for s in "${STEPS[@]}"; do
        if stamped "install.$s"; then printf '  %-11s done (%s)\n' "$s" "$(cat "$STAMP_DIR/install.$s")"
        else printf '  %-11s not yet\n' "$s"; fi
    done
    footer "status"
}
```

Dispatch:

```bash
    run)      cmd_run ;;
    status)   cmd_status ;;
```

(`run_step` applies the 0/2/1 contract and dies on a FAIL naming `--from <step>`; `on_exit` then writes the FAIL row. A clean slice that stops before `e2e` exits 0 but says "not INSTALLED until e2e has run", so the word INSTALLED appears only when the whole chain ran.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/install.bats`
Expected: all pass.

- [ ] **Step 5: Gate**

Run: `./tests/run.sh > "$SCRATCH/gate.log" 2>&1; echo $?; grep -E '^not ok' "$SCRATCH/gate.log"`
Expected: `0`, no `not ok`.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-install.sh tests/install.bats
git commit -m "r770-install.sh run: gns3 → e2e with install.conf's values, one summary, INSTALLED only when every step is clean; status"
```

---

### Task 5: The `import` step and the hand-off to the local copy

**Files:**
- Modify: `scripts/r770-install.sh`
- Test: `tests/install.bats`

**Interfaces:**
- Consumes: `cmd_run`'s loop, `step_body`, `LOGDIR`, `TO`.
- Produces: the `import` step. It calls `$IMPORT preflight --bundle B`, then `$IMPORT gate --bundle B --media M --device D`, then `$IMPORT copy --bundle B`. Then `handoff <next>`: unless this installer *is* `$(p /srv/bundles)/<name>/kit/scripts/r770-install.sh`, it `exec`s that one with `run --from <next> --conf CONF_PATH [--to TO] [--yes] [--non-interactive]` and `INSTALL_LOGDIR` exported.

- [ ] **Step 1: Write the failing tests** (append)

```bash
# the import stub's copy lands a local bundle whose kit/ installer only records how it was called
copy_lands_kit() {
    stub import-stub 'echo "import $*" >> "$STUB_LOG"
if [ "$1" = copy ]; then
  d="$KIT_ROOT/srv/bundles/bundle-fixture/kit/scripts"; mkdir -p "$d"
  printf "#!/usr/bin/env bash\necho \"handoff \$* logdir=\$INSTALL_LOGDIR\" >> \"%s\"\n" "$STUB_LOG" > "$d/r770-install.sh"; chmod +x "$d/r770-install.sh"
fi'
}

@test "import from the media: preflight, gate with media and device, copy WITHOUT media, then exec the local copy from gns3" {
    good_conf; copy_lands_kit
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 0 ]
    run cat "$STUB_LOG"
    [ "${lines[0]}" = "import preflight --bundle $BUNDLE" ]
    [ "${lines[1]}" = "import gate --bundle $BUNDLE --media /media/usb --device /dev/sdb1" ]
    [ "${lines[2]}" = "import copy --bundle $BUNDLE" ]
    [[ "${lines[3]}" == "handoff run --from gns3 --conf $CONF --yes --non-interactive logdir=$KIT_EVIDENCE_DIR/install-"* ]]
    [ "${#lines[@]}" -eq 4 ]
}

@test "--to import stops after the copy: no hand-off" {
    good_conf; copy_lands_kit
    run inst run --conf "$CONF" --yes --to import
    [ "$status" -eq 0 ]
    ! grep -q '^handoff' "$STUB_LOG"
}

@test "a copied bundle with no kit/ installer is a FAIL that says how the bundle was cut" {
    good_conf
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"KIT_SRC_ROOT"* ]]
}

@test "already running from the local copy: import continues in-process, no exec" {
    good_conf
    local kit="$ROOT/srv/bundles/bundle-fixture/kit"
    mkdir -p "$kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$kit/"
    run kit_run "$kit/scripts/r770-install.sh" run --conf "$CONF" --yes --to gns3
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "gns3 full --bundle $ROOT/srv/bundles/bundle-fixture" "$STUB_LOG"
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/install.bats --filter 'import|kit/ installer|local copy'`
Expected: FAIL (`import` has no body in `step_body`, and nothing hands off).

- [ ] **Step 3: Implement.** Add to `step_body`'s `case`:

```bash
        import)
                 run_step import logged import-preflight "$IMPORT" preflight --bundle "$CONF_BUNDLE"
                 run_step import logged import-gate "$IMPORT" gate --bundle "$CONF_BUNDLE" --media "$CONF_MEDIA" --device "$CONF_DEVICE"
                 # no --media: copy would unmount it, and this script is running from it
                 run_step import logged import-copy "$IMPORT" copy --bundle "$CONF_BUNDLE" ;;
```

Add above `cmd_run`:

```bash
# handoff <next-step> — carry on in the local copy's own installer, so
# nothing holds the media (bash marks its script descriptor close-on-exec).
handoff() {
    local next=$1 me there
    local -a args
    there="$(p /srv/bundles)/$(basename "$CONF_BUNDLE")/kit/scripts/r770-install.sh"
    me="$(cd "$KIT_DIR/scripts" && pwd -P)/r770-install.sh"
    [ -x "$there" ] || die "the copied bundle has no kit/scripts/r770-install.sh — it was cut without the kit (set KIT_SRC_ROOT at cut time); cut again, or run the pipelines by hand"
    [ "$(cd "$(dirname "$there")" && pwd -P)/r770-install.sh" = "$me" ] && return 0
    args=(run --from "$next" --conf "$CONF_PATH")
    [ -n "$TO" ] && args+=(--to "$TO")
    [ "${KIT_YES:-0}" = "1" ] && args+=(--yes)
    [ "${KIT_NON_INTERACTIVE:-0}" = "1" ] && args+=(--non-interactive)
    note "handing off to the local copy: $there ${args[*]}"
    export INSTALL_LOGDIR="$LOGDIR"
    trap - EXIT
    exec "$there" "${args[@]}"
}
```

In `cmd_run`'s loop, directly after `CUR=""`:

```bash
        if [ "$step" = import ] && [ "$i" -lt "$last" ]; then handoff "${STEPS[$((i + 1))]}"; fi
```

(`import` is stamped and summarised before the hand-off; the exec'd run appends to the same `$LOGDIR.md`. A missing local installer dies while `CUR` is empty, so its record is the die message in the transcript.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/install.bats`
Expected: all pass.

- [ ] **Step 5: Gate**

Run: `./tests/run.sh > "$SCRATCH/gate.log" 2>&1; echo $?; grep -E '^not ok' "$SCRATCH/gate.log"`
Expected: `0`.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-install.sh tests/install.bats
git commit -m "r770-install.sh import: preflight, gate, copy without unmounting the media it runs from, then exec the local copy's installer"
```

---

### Task 6: `plan`

**Files:**
- Modify: `scripts/r770-install.sh`
- Test: `tests/install.bats`

**Interfaces:**
- Consumes: `conf_ready`, the children, `$IMPORT storage` (Task 1).
- Produces: `r770-install.sh plan`. It changes nothing; it exits 0/2/1 from the children's dry-run verdicts.

- [ ] **Step 1: Write the failing tests** (append)

```bash
@test "plan: the storage check, then every gated step under --dry-run; read-only steps are listed, not run" {
    good_conf
    unset KIT_YES
    stub gns3-stub 'echo "gns3 $* yes=${KIT_YES:-} dry=${KIT_DRY_RUN:-}" >> "$STUB_LOG"'
    run inst plan --conf "$CONF"
    echo "$output"
    [ "$status" -eq 0 ]
    run cat "$STUB_LOG"
    [ "${lines[0]}" = "import storage --bundle $BUNDLE" ]
    [ "${lines[1]}" = "import gate --bundle $BUNDLE --media /media/usb --device /dev/sdb1 --dry-run" ]
    [ "${lines[2]}" = "import copy --bundle $BUNDLE --dry-run" ]
    [ "${lines[3]}" = "gns3 full --bundle $BUNDLE --dry-run yes=1 dry=1" ]
    [ "${lines[4]}" = "malcolm full --bundle $BUNDLE --capture-ifs lab_mirror0 --dry-run" ]
    [ "${lines[5]}" = "docs full --bundle $BUNDLE --dry-run" ]
    [ "${lines[6]}" = "portal ca --dry-run" ]
    [ "${lines[9]}" = "portal nginx --dry-run" ]
    [ "${#lines[@]}" -eq 10 ]
    [[ "$output" == *"dashboards"*"after Malcolm is up"* ]]
    [[ "$output" == *"e2e"*"read-only"* ]]
}

@test "plan reports a child's refusal as FAIL, never PASS (e.g. Malcolm before labnet exists)" {
    good_conf; echo 1 > "$T/rc-malcolm"
    run inst plan --conf "$CONF"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  malcolm"* ]]
    grep -q '^docs ' "$STUB_LOG"     # plan reviews everything; it does not stop at the first refusal
}

@test "plan refuses a bad install.conf before any child runs" {
    good_conf; sed -i 's#^DEVICE=.*#DEVICE=/dev/sdX#' "$CONF"
    run inst plan --conf "$CONF"
    [ "$status" -eq 1 ]
    [ ! -s "$STUB_LOG" ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/install.bats --filter plan`
Expected: 3 FAIL with `unknown subcommand: plan`.

- [ ] **Step 3: Implement** (above `# ── arguments`):

```bash
# ── plan ─────────────────────────────────────────────────────────────────────
# Every gated change, once, under --dry-run. The children get KIT_YES so each
# gate prints current/proposed/rollback and goes on to print what it would do
# — nothing executes under dry-run. A refusal is a FAIL row and the review
# carries on, so the operator sees everything in one pass.
plan_child() {  # plan_child <label> <cmd...>
    local label=$1 rc=0; shift
    KIT_YES=1 KIT_NON_INTERACTIVE=1 KIT_DRY_RUN=1 "$@" || rc=$?
    case "$rc" in
        0) pass "$label: would apply cleanly" ;;
        2) warn "$label: would apply with warnings (above)" ;;
        *) fail "$label: refused under --dry-run (above) — fix before run" ;;
    esac
}
cmd_plan() {
    banner "plan — every change this install would make; nothing is applied"
    conf_ready
    local b=$CONF_BUNDLE s
    plan_child "storage" "$IMPORT" storage --bundle "$b"
    plan_child "import gate" "$IMPORT" gate --bundle "$b" --media "$CONF_MEDIA" --device "$CONF_DEVICE" --dry-run
    plan_child "import copy" "$IMPORT" copy --bundle "$b" --dry-run
    plan_child "gns3" "$GNS3" full --bundle "$b" --dry-run
    plan_child "malcolm" "$MALCOLM" full --bundle "$b" --capture-ifs "$CONF_CAPTURE_IFS" --dry-run
    plan_child "docs" "$DOCS" full --bundle "$b" --dry-run
    for s in ca cert htpasswd nginx; do plan_child "portal $s" "$PORTAL" "$s" --dry-run; done
    note "dashboards: installs saved objects and Arkime views after Malcolm is up — idempotent, not gated"
    note "validate, e2e: read-only checks and the scenario run — nothing to review; they prove the result"
    footer "plan"
}
```

Dispatch: `plan)  cmd_plan ;;`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/install.bats`
Expected: all pass.

- [ ] **Step 5: Gate**

Run: `./tests/run.sh > "$SCRATCH/gate.log" 2>&1; echo $?; grep -E '^not ok' "$SCRATCH/gate.log"`
Expected: `0`.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-install.sh tests/install.bats
git commit -m "r770-install.sh plan: the storage check and every gated step under --dry-run, one review, refusals reported not hidden"
```

---

### Task 7: The runbook's installer section and the cut order

**Files:**
- Modify: `docs/deployment-runbook.md` (a new section after "Step 0 — On the media, before anything")
- Modify: `docs/kit-sync.md` (cutting a bundle that carries the kit)
- Test: `tests/references.bats` (existing; it checks every kit path the docs name)

- [ ] **Step 1: Write the section** — insert in `docs/deployment-runbook.md` after Step 0:

````markdown
## The installer: one run, from the media to a proven lab

Every bundle cut since 2026-10 carries this kit at `kit/` (manifest-covered,
so step 0's verify proves it). With Ubuntu 24.04 installed and the media
mounted:

```bash
sudo <media>/<bundle>/kit/scripts/r770-install.sh discover   # what this host has; writes /etc/lab/install.conf.template
sudo <media>/<bundle>/kit/scripts/r770-install.sh wizard     # or fill the template by hand and save it as /etc/lab/install.conf
sudo <media>/<bundle>/kit/scripts/r770-install.sh plan       # every gated change under --dry-run, in one review
sudo <media>/<bundle>/kit/scripts/r770-install.sh run --yes  # import, gns3, malcolm, docs, portal, dashboards, validate, e2e
```

`run` imports the bundle, then carries on in the local copy
(`/srv/bundles/<bundle>/kit/scripts/r770-install.sh`). After a failure,
rerun **that** copy with `run --yes --from <step>`. INSTALLED means every
step was clean and `scripts/r770-e2e.sh` proved every scenario in Malcolm;
anything less is NOT INSTALLED with the step to look at. The summary lands
in `r770-evidence/install-<host>-<ts>.md`. The last action is
`umount <media>`, as the summary prints.

The per-pipeline procedures below stay as the reference for what each step
does, and for running one by hand.
````

- [ ] **Step 2: kit-sync** — append to `docs/kit-sync.md`:

```markdown
## Cutting a bundle that carries this kit (since 2026-10)

The build repo's fetch has a `kit` stage: it copies this repo's tracked,
committed `scripts/ config/ scenarios/ docs/` at `HEAD` into `bundle-*/kit/`
and records the commit in `kit/KIT_COMMIT`. It has no default source. Order:

1. Merge and push this kit; note the commit.
2. On the staging host: `KIT_SRC_ROOT=<a checkout of this kit at that commit> SITE_SRC_ROOT=<simlab-build checkout> ./staging/r770-build-bundle.sh`.
   A packed builder carries the kit when `KIT_SRC_ROOT` is set at `--pack` time.
3. The build's strict gate fails a bundle without `kit/scripts/r770-install.sh`.
```

- [ ] **Step 3: Run the reference check**

Run: `bats tests/references.bats`
Expected: all pass. If it reads `kit/scripts/r770-install.sh` as a kit path and fails, write those occurrences with the `<media>/<bundle>/` prefix (already done above) or with `<bundle>/kit/...`, and ledger a Ruling.

- [ ] **Step 4: Gate and commit**

Run: `./tests/run.sh > "$SCRATCH/gate.log" 2>&1; echo $?`
Expected: `0`.

```bash
git add docs/deployment-runbook.md docs/kit-sync.md
git commit -m "Runbook: the installer — discover, wizard, plan, run from the media; kit-sync: cutting a bundle that carries the kit"
```

---

## Part 2 — the build repo (worktree `$SB`, branch `claude/kit-in-bundle` off `origin/main`)

Setup, once: `git -C /root/git/simlab-build fetch -q origin && git -C /root/git/simlab-build worktree add -b claude/kit-in-bundle "$SB" origin/main`. Its gate is `./tests/run.sh`, run from `$SB`.

### Task 8: The `kit` fetch stage

**Files:**
- Modify: `scripts/r770-offline-fetch.sh` (`STAGES`, the usage text, `kit_validate_source` after `site_validate_source`'s call, `ship_trees` extracted from `stage_site`, `stage_kit`, its dispatch, the stage-marker table)
- Test: `tests/offline-fetch.bats`

**Interfaces:**
- Produces: `bundle-*/kit/` holding the kit's tracked `scripts config scenarios docs`, and `bundle-*/kit/KIT_COMMIT` (the full hash); a note line `kit/: N files from <commit> copied`. Inputs: `KIT_SRC_ROOT`, or `KIT_ARCHIVE` + `KIT_COMMIT`. A real run that includes the stage refuses at startup with neither; `--list`/`--dry-run` only note it.

- [ ] **Step 1: Write the failing tests** (append to `tests/offline-fetch.bats`, after the site tests)

```bash
# ── kit/ — the R770 installer (sim-lab-basic) delivered inside the bundle ──
setup_kit_repo() {
    local src="$1"
    mkdir -p "$src/scripts/lib" "$src/config" "$src/scenarios/demo" "$src/docs/wiki" "$src/tests" "$src/staging"
    printf '#!/usr/bin/env bash\necho install\n' > "$src/scripts/r770-install.sh"; chmod +x "$src/scripts/r770-install.sh"
    echo "# lib" > "$src/scripts/lib/common.sh"
    echo "tpl"   > "$src/config/x.template"
    echo "name=demo" > "$src/scenarios/demo/scenario.conf"
    echo "# page" > "$src/docs/wiki/index.md"
    echo "@test" > "$src/tests/never.bats"            # tests/ never ships
    echo "fetch" > "$src/staging/never.sh"            # staging/ never ships
    echo "SECRET=1" > "$src/config/leak.env"          # excluded, as for site/
    git -C "$src" init -q; gitc -C "$src" add -A; gitc -C "$src" commit -q -m init
}

@test "--only kit ships the kit's tracked scripts/config/scenarios/docs and its commit, never tests/ or staging/" {
    KSRC="$BATS_TEST_TMPDIR/kit-src"; setup_kit_repo "$KSRC"; export KIT_SRC_ROOT="$KSRC"
    run "$SCRIPT" --only kit
    echo "$output"
    [ "$status" -eq 0 ]
    [ -x "$BUNDLE_DIR/kit/scripts/r770-install.sh" ]
    [ -s "$BUNDLE_DIR/kit/scripts/lib/common.sh" ]
    [ -s "$BUNDLE_DIR/kit/scenarios/demo/scenario.conf" ]
    [ -s "$BUNDLE_DIR/kit/docs/wiki/index.md" ]
    [ ! -e "$BUNDLE_DIR/kit/tests" ]; [ ! -e "$BUNDLE_DIR/kit/staging" ]
    [ ! -e "$BUNDLE_DIR/kit/config/leak.env" ]
    [ "$(cat "$BUNDLE_DIR/kit/KIT_COMMIT")" = "$(git -C "$KSRC" rev-parse HEAD)" ]
    grep -qE 'kit/: 5 files from [0-9a-f]{40} copied' "$BUNDLE_DIR/BUNDLE_NOTES.md"
    [ ! -s "$NET" ]
}

@test "a real fetch that includes the kit stage refuses at startup without KIT_SRC_ROOT — there is no default" {
    unset KIT_SRC_ROOT KIT_ARCHIVE KIT_COMMIT
    run "$SCRIPT"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"KIT_SRC_ROOT is not set"* ]]
    [[ "$output" != *"[0/11]"* ]]
    [ ! -s "$NET" ]
}

@test "--list and --dry-run without KIT_SRC_ROOT only note that the kit stage will need one" {
    unset KIT_SRC_ROOT KIT_ARCHIVE KIT_COMMIT
    run "$SCRIPT" --list
    [ "$status" -eq 0 ]; [[ "$output" == *"kit"* ]]
}

@test "KIT_SRC_ROOT that is not sim-lab-basic is refused" {
    mkdir -p "$BATS_TEST_TMPDIR/other"; export KIT_SRC_ROOT="$BATS_TEST_TMPDIR/other"
    run "$SCRIPT" --only kit
    [ "$status" -ne 0 ]; [[ "$output" == *"scripts/r770-install.sh not found"* ]]
}

@test "a tracked symlink in the kit refuses and leaves a previous kit/ untouched" {
    KSRC="$BATS_TEST_TMPDIR/kit-src"; setup_kit_repo "$KSRC"; export KIT_SRC_ROOT="$KSRC"
    run "$SCRIPT" --only kit; [ "$status" -eq 0 ]
    ln -s /etc/passwd "$KSRC/scripts/evil"; gitc -C "$KSRC" add -A; gitc -C "$KSRC" commit -q -m evil
    run "$SCRIPT" --only kit
    [ "$status" -ne 0 ]; [[ "$output" == *"scripts/evil is a symlink"* ]]
    [ -x "$BUNDLE_DIR/kit/scripts/r770-install.sh" ]; [ ! -e "$BUNDLE_DIR/kit.tmp" ]
}

@test "KIT_ARCHIVE + KIT_COMMIT (a packed builder, no checkout) builds kit/ and records the commit" {
    KSRC="$BATS_TEST_TMPDIR/kit-src"; setup_kit_repo "$KSRC"
    local commit; commit=$(git -C "$KSRC" rev-parse HEAD)
    git -C "$KSRC" archive --format=tar HEAD -- scripts config scenarios docs > "$BATS_TEST_TMPDIR/kit.tar"
    unset KIT_SRC_ROOT; export KIT_ARCHIVE="$BATS_TEST_TMPDIR/kit.tar" KIT_COMMIT="$commit"
    run "$SCRIPT" --only kit
    echo "$output"
    [ "$status" -eq 0 ]
    [ -x "$BUNDLE_DIR/kit/scripts/r770-install.sh" ]
    [ "$(cat "$BUNDLE_DIR/kit/KIT_COMMIT")" = "$commit" ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/offline-fetch.bats --filter 'kit'`
Expected: FAIL (`kit` is not a known stage).

- [ ] **Step 3: Implement.**

`STAGES=(preflight apt iso malcolm monitoring gns3 appliances enrichment docs manual site kit manifest)`.

In the usage block, beside `SITE_SRC_ROOT`:

```
             KIT_SRC_ROOT=<dir>   (a sim-lab-basic checkout the "kit" stage copies the R770 installer from. No default: a real run refuses without it, or without KIT_ARCHIVE + KIT_COMMIT.)
```

After the line `want site && site_validate_source`:

```bash
# The "kit" stage ships sim-lab-basic (the R770 installer) as bundle-*/kit/.
# Unlike site/, it has NO default source: which kit checkout ships is a
# release decision, so a real run refuses rather than guess (2026-10-03).
# --list/--dry-run touch nothing, so there it is only a note.
KIT_MODE=""
kit_validate_source() {
    if [ -n "${KIT_ARCHIVE:-}" ]; then
        [ -s "$KIT_ARCHIVE" ] || { echo "FATAL: KIT_ARCHIVE ($KIT_ARCHIVE) is missing or empty" >&2; exit 1; }
        [ -n "${KIT_COMMIT:-}" ] || { echo "FATAL: KIT_ARCHIVE is set but KIT_COMMIT is empty -- both travel together" >&2; exit 1; }
        KIT_MODE="archive"; return 0
    fi
    [ -n "${KIT_SRC_ROOT:-}" ] || {
        echo "FATAL: KIT_SRC_ROOT is not set -- the kit stage ships the R770 installer from a sim-lab-basic checkout and will not guess which. Set KIT_SRC_ROOT=<checkout> (or KIT_ARCHIVE + KIT_COMMIT), or leave the stage out with --skip kit." >&2
        exit 1
    }
    local raw="$KIT_SRC_ROOT"
    KIT_SRC_ROOT="$(cd -- "$raw" 2>/dev/null && pwd -P)" || { echo "FATAL: KIT_SRC_ROOT ($raw) is not a directory that can be entered" >&2; exit 1; }
    [ -f "$KIT_SRC_ROOT/scripts/r770-install.sh" ] || { echo "FATAL: KIT_SRC_ROOT ($KIT_SRC_ROOT) doesn't look like sim-lab-basic -- scripts/r770-install.sh not found there" >&2; exit 1; }
    git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "FATAL: KIT_SRC_ROOT ($KIT_SRC_ROOT) is not a git work tree -- kit/ ships tracked, committed content only" >&2; exit 1; }
    KIT_MODE="worktree"
}
if want kit; then
    if [ "$LIST" = "1" ] || [ "$DRY_RUN" = "1" ]; then
        [ -n "${KIT_SRC_ROOT:-}${KIT_ARCHIVE:-}" ] || echo "NOTE: the kit stage will need KIT_SRC_ROOT (or KIT_ARCHIVE + KIT_COMMIT) on a real run"
    else
        kit_validate_source
    fi
fi
```

(If `LIST`/`DRY_RUN` are not yet set at that point in the file, move this block to just after they are parsed, still before any stage runs, and ledger the placement.)

Replace `stage_site`'s body with a shared `ship_trees`, so site and kit share one implementation; the existing site tests are the safety net:

```bash
# ship_trees <name> <mode> <src-root> <archive> <commit> <tree...> — the one
# implementation behind site/ and kit/: committed content only (HEAD via
# ls-tree + cat-file, or the archive's own entries), symlinks and submodules
# refused, secret-looking files excluded (site_excluded), built in
# $B/<name>.tmp and moved into place only on full success. Sets SHIPPED_COMMIT.
SHIPPED_COMMIT=""
tree_refuse() {  # tree_refuse <name> <message...>
    local name=$1; shift
    echo "FATAL: $*" >&2
    rm -rf "$B/$name.tmp"
    exit 1
}
ship_trees() {
    local name=$1 mode=$2 src=$3 archive=$4 commit=$5; shift 5
    local trees=("$@") top rel dest fmode oid n=0 dirty="" tmp meta
    rm -rf "$B/$name.tmp"; mkdir -p "$B/$name.tmp"
    if [ "$mode" = "archive" ]; then
        tmp="$(mktemp -d)" || tree_refuse "$name" "mktemp failed while extracting the $name archive"
        tar xf "$archive" -C "$tmp" || { rm -rf "$tmp"; tree_refuse "$name" "could not extract $archive"; }
        for top in "${trees[@]}"; do
            [ -d "$tmp/$top" ] || { rm -rf "$tmp"; tree_refuse "$name" "$top is missing from the $name archive -- $name/ needs all of: ${trees[*]}"; }
        done
        while IFS= read -r -d '' rel; do
            rel="${rel#./}"
            if [ -L "$tmp/$rel" ]; then rm -rf "$tmp"; tree_refuse "$name" "$rel is a symlink in the $name archive -- refusing; a symlink in $name/ could point outside the manifest"; fi
            site_excluded "$rel" && continue
            dest="$B/$name.tmp/$rel"; mkdir -p "$(dirname "$dest")"; cp -p "$tmp/$rel" "$dest"; n=$((n + 1))
        done < <(cd "$tmp" && find . \( -type f -o -type l \) -print0)
        rm -rf "$tmp"
    else
        commit="$(sitegit "$src" rev-parse HEAD 2>/dev/null || echo unknown)"
        [ -n "$(sitegit "$src" status --porcelain -- "${trees[@]}" 2>/dev/null)" ] && dirty=1
        for top in "${trees[@]}"; do
            [ -d "$src/$top" ] || tree_refuse "$name" "$src/$top is missing -- $name/ needs all of: ${trees[*]}"
        done
        while IFS=$'\t' read -r -d '' meta rel; do
            fmode="${meta%% *}"
            case "$fmode" in
                120000) tree_refuse "$name" "$rel is a symlink (mode 120000) -- refusing; a symlink in $name/ could point outside the manifest" ;;
                160000) tree_refuse "$name" "$rel is a submodule (mode 160000) -- refusing; $name/ ships plain tracked files only" ;;
            esac
            site_excluded "$rel" && continue
            dest="$B/$name.tmp/$rel"; mkdir -p "$(dirname "$dest")"
            oid="${meta##* }"
            sitegit "$src" cat-file blob "$oid" > "$dest" || tree_refuse "$name" "$rel ($oid) is tracked but unreadable via cat-file -- committed content only ships"
            [ "$fmode" = "100755" ] && chmod +x "$dest"
            n=$((n + 1))
        done < <(sitegit "$src" ls-tree -r -z --full-tree HEAD -- "${trees[@]}")
    fi
    [ "$n" -gt 0 ] || tree_refuse "$name" "$name/ would ship 0 files -- refusing an empty $name/"
    rm -rf "$B/$name"; mv "$B/$name.tmp" "$B/$name"
    [ -n "$dirty" ] && note "WARN: $name/ built from a dirty tree; uncommitted edits NOT shipped"
    note "$name/: $n files from $commit copied"
    SHIPPED_COMMIT="$commit"
}

stage_site() {
echo "==== [10/11] site/ (this repo's scripts, config, docs/analyst-wiki) ===="
ship_trees site "$SITE_MODE" "${SITE_SRC_ROOT:-}" "${SITE_ARCHIVE:-}" "${SITE_COMMIT:-}" "${SITE_TREES[@]}"
}

KIT_TREES=(scripts config scenarios docs)
stage_kit() {
echo "==== [10b/11] kit/ (sim-lab-basic: the R770 installer) ===="
ship_trees kit "$KIT_MODE" "${KIT_SRC_ROOT:-}" "${KIT_ARCHIVE:-}" "${KIT_COMMIT:-}" "${KIT_TREES[@]}"
printf '%s\n' "$SHIPPED_COMMIT" > "$B/kit/KIT_COMMIT"
}
```

Then:
- Delete `site_refuse` if `grep -n site_refuse` shows no other caller; otherwise make it `tree_refuse site "$@"`.
- Add `kit) stage_kit ;;` wherever the dispatch lists `site) stage_site ;;`.
- In the stage-marker table (`site) return 1 ;;   # always refreshed`), add `kit) return 1 ;;` and treat `kit` like `site` in the `m=` line.
- The label `[10b/11]` keeps every other stage's label (and the existing `[0/11]` assertions) unchanged.
- The site note now carries the full commit hash, not `--short`. The existing assertions (`[0-9a-f]{7,40}`, and `from $commit copied` in archive mode) accept it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/offline-fetch.bats`
Expected: all pass, the existing site tests included.

- [ ] **Step 5: Gate and commit**

Run: `./tests/run.sh > "$SCRATCH/sb-gate.log" 2>&1; echo $?; grep -E '^not ok' "$SCRATCH/sb-gate.log"`
Expected: `0`. Any other existing test that runs a **real** (non-`--list`, non-`--dry-run`, non-`--only`) fetch now needs a kit source: give it `setup_kit_repo` + `KIT_SRC_ROOT` (or `--skip kit`), and ledger a Ruling naming each test.

```bash
git add scripts/r770-offline-fetch.sh tests/offline-fetch.bats
git commit -m "r770-offline-fetch.sh: a kit stage ships sim-lab-basic's R770 installer as bundle-*/kit/ (no default source); site/ and kit/ share ship_trees"
```

---

### Task 9: The verifier requires `kit/scripts/r770-install.sh`

**Files:**
- Modify: `scripts/r770-bundle.sh` (`check_kit`, called after `check_site`)
- Modify: `tests/helpers/fixtures.bash` (`make_bundle` gains `kit/`)
- Test: `tests/bundle-verify.bats`

- [ ] **Step 1: Write the failing tests** (append to `tests/bundle-verify.bats`)

```bash
# ── kit/ — the R770 installer delivered with the bundle ──
@test "a fixture bundle with kit/ passes and names the kit commit" {
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"kit/ carries the R770 installer (sim-lab-basic 0000000fixture)"* ]]
}

@test "a bundle with no kit/ warns, and --strict refuses it" {
    rm -rf "$BUNDLE/kit"; "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE"
    [ "$status" -eq 2 ]; [[ "$output" == *"kit/ is missing"* ]]
    run "$SCRIPT" verify "$BUNDLE" --strict
    [ "$status" -eq 1 ]
}

@test "kit/ without its installer or its commit record warns, naming what is missing" {
    rm -f "$BUNDLE/kit/scripts/r770-install.sh" "$BUNDLE/kit/KIT_COMMIT"; "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"kit/scripts/r770-install.sh"* ]]; [[ "$output" == *"kit/KIT_COMMIT"* ]]
}

@test "a modified kit/ file fails verify because the manifest covers it" {
    echo tampered > "$BUNDLE/kit/scripts/r770-install.sh"
    run "$SCRIPT" verify "$BUNDLE"
    [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/bundle-verify.bats --filter 'kit'`
Expected: FAIL. The fixture has no `kit/`, and the verifier has no `check_kit`.

- [ ] **Step 3: Implement.**

`tests/helpers/fixtures.bash`, in `make_bundle` after the site/ lines:

```bash
    # kit/ — sim-lab-basic's R770 installer, as r770-offline-fetch.sh's
    # stage_kit() ships it: the installer, its shared library, and the commit.
    mkdir -p "$d/kit/scripts/lib"
    printf '#!/usr/bin/env bash\necho fixture-install\n' > "$d/kit/scripts/r770-install.sh"
    chmod +x "$d/kit/scripts/r770-install.sh"
    echo "# fixture common" > "$d/kit/scripts/lib/common.sh"
    echo "0000000fixture" > "$d/kit/KIT_COMMIT"
```

`scripts/r770-bundle.sh`, after `check_site`:

```bash
# kit/ carries sim-lab-basic, the R770 installer (r770-offline-fetch.sh's
# stage_kit). Missing is a WARN here and a FAIL under --strict — the same
# severity rule, and the same reasoning, as check_site above: a bundle cut
# before 2026-10 legitimately has none, and the build gate refuses one cut now.
KIT_REQUIRED_FILES=(scripts/r770-install.sh scripts/lib/common.sh KIT_COMMIT)
check_kit() {  # <dir>
    local dir="$1" f missing=()
    if [ ! -d "$dir/kit" ]; then
        warn "kit/ is missing — no R770 installer in this bundle (cut without KIT_SRC_ROOT, or before the kit/ delivery path)"
        return 0
    fi
    for f in "${KIT_REQUIRED_FILES[@]}"; do [ -s "$dir/kit/$f" ] || missing+=("$f"); done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf '      kit/%s\n' "${missing[@]}"
        warn "kit/ is missing required file(s) above — the R770 installer cannot run from this bundle"
    else
        pass "kit/ carries the R770 installer (sim-lab-basic $(head -c 14 "$dir/kit/KIT_COMMIT"))"
    fi
}
```

In `cmd_verify`, after `check_site     "$dir"`: `check_kit      "$dir"`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/bundle-verify.bats`
Expected: all pass, the existing site tests included.

- [ ] **Step 5: Gate and commit**

Run: `./tests/run.sh > "$SCRATCH/sb-gate.log" 2>&1; echo $?`
Expected: `0`.

```bash
git add scripts/r770-bundle.sh tests/helpers/fixtures.bash tests/bundle-verify.bats
git commit -m "r770-bundle.sh verify: kit/ must carry the R770 installer — WARN, so the strict build gate refuses a bundle without it"
```

---

### Task 10: The packed builder carries the kit

**Files:**
- Modify: `scripts/r770-build-bundle.sh` (`cmd_pack`)
- Test: `tests/build-bundle.bats`

- [ ] **Step 1: Write the failing tests** (append after the site pack tests; `extract_payload` is defined there)

```bash
make_kit_src() {  # make_kit_src <dir> — a tiny committed sim-lab-basic stand-in
    mkdir -p "$1"/{scripts,config,scenarios,docs}
    printf '#!/usr/bin/env bash\n' > "$1/scripts/r770-install.sh"
    echo x > "$1/config/c"; echo x > "$1/scenarios/s"; echo x > "$1/docs/d"
    git -C "$1" init -q
    git -C "$1" -c user.name=t -c user.email=t@t.invalid add -A
    git -C "$1" -c user.name=t -c user.email=t@t.invalid commit -q -m k
}

@test "--pack with KIT_SRC_ROOT embeds the kit archive and exports KIT_ARCHIVE/KIT_COMMIT" {
    KSRC="$BATS_TEST_TMPDIR/kit-src"; make_kit_src "$KSRC"
    export KIT_SRC_ROOT="$KSRC"
    run "$SCRIPT" --pack
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/packed.sh"
    grep -q 'export KIT_ARCHIVE="$D/kit.tar"' "$BATS_TEST_TMPDIR/packed.sh"
    grep -q "export KIT_COMMIT=\"$(git -C "$KSRC" rev-parse HEAD)\"" "$BATS_TEST_TMPDIR/packed.sh"
    extract_payload "$BATS_TEST_TMPDIR/packed.sh" "$BATS_TEST_TMPDIR/x"
    tar tf "$BATS_TEST_TMPDIR/x/kit.tar" | grep -qx 'scripts/r770-install.sh'
    run bash -n "$BATS_TEST_TMPDIR/packed.sh"; [ "$status" -eq 0 ]
}

@test "--pack without KIT_SRC_ROOT still packs and carries no kit" {
    unset KIT_SRC_ROOT
    run "$SCRIPT" --pack
    [ "$status" -eq 0 ]
    [[ "$output" != *"export KIT_ARCHIVE="* ]]
}

@test "--pack refuses a dirty kit tree" {
    KSRC="$BATS_TEST_TMPDIR/kit-src"; make_kit_src "$KSRC"
    echo dirty >> "$KSRC/scripts/r770-install.sh"
    export KIT_SRC_ROOT="$KSRC"
    run "$SCRIPT" --pack
    [ "$status" -ne 0 ]; [[ "$output" == *"dirty kit tree"* ]]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/build-bundle.bats --filter 'kit'`
Expected: tests 1 and 3 FAIL; test 2 may already pass.

- [ ] **Step 3: Implement**, in `cmd_pack`, after `site-commit.txt` is written:

```bash
    local kit_files="" kit_commit=""
    if [ -n "${KIT_SRC_ROOT:-}" ]; then
        if [ -n "$(git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" status --porcelain -- scripts config scenarios docs 2>/dev/null)" ]; then
            rm -rf "$tmp"; die "--pack refuses a dirty kit tree at KIT_SRC_ROOT ($KIT_SRC_ROOT) -- commit or stash it first"
        fi
        kit_commit="$(git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" rev-parse HEAD)" || { rm -rf "$tmp"; die "KIT_SRC_ROOT ($KIT_SRC_ROOT) is not a git checkout"; }
        git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" archive --format=tar HEAD -- scripts config scenarios docs > "$tmp/kit.tar" ||
            { rm -rf "$tmp"; die "could not archive the kit at $kit_commit"; }
        kit_files="kit.tar"
    else
        echo "r770-build-bundle: note: --pack without KIT_SRC_ROOT carries no kit; the packed builder's fetch will need KIT_SRC_ROOT (or --skip kit)" >&2
    fi
```

The tar line becomes `... -C "$tmp" site.tar site-commit.txt $kit_files` (intentional word splitting, under the existing `# shellcheck disable=SC2086`). Split the FOOTER heredoc so the conditional export sits before `exec`, keeping every other line byte for byte:

```bash
    cat <<FOOTER
R770_PAYLOAD
chmod +x "\$D"/*.sh
export SITE_ARCHIVE="\$D/site.tar"
export SITE_COMMIT="$commit"
FOOTER
    if [ -n "$kit_commit" ]; then
        printf 'export KIT_ARCHIVE="$D/kit.tar"\nexport KIT_COMMIT="%s"\n' "$kit_commit"
    fi
    cat <<'FOOTER2'
exec "$D/r770-build-bundle.sh" "$@"
FOOTER2
```

(The `printf` format is single-quoted so `$D` stays literal for the packed script; add `# shellcheck disable=SC2016` above it.) Add a line to the header heredoc: `# Also carries sim-lab-basic (the R770 installer) as kit.tar when KIT_SRC_ROOT was set at pack time.`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/build-bundle.bats`
Expected: all pass, including the existing "valid bash" and "four scripts" tests.

- [ ] **Step 5: Gate and commit**

Run: `./tests/run.sh > "$SCRATCH/sb-gate.log" 2>&1; echo $?`
Expected: `0`.

```bash
git add scripts/r770-build-bundle.sh tests/build-bundle.bats
git commit -m "r770-build-bundle.sh --pack: carry the kit (KIT_ARCHIVE + KIT_COMMIT) when KIT_SRC_ROOT is set; refuse a dirty kit tree"
```

---

### Task 11: The build repo's runbook points at the kit's installer

**Files:**
- Modify: `docs/plans/r770-install-runbook.md` (a box directly under the title)

- [ ] **Step 1: Add:**

```markdown
> **Since 2026-10 the R770 install runs from the bundle's `kit/`.** Every
> bundle carries sim-lab-basic at `kit/` (the fetch's `kit` stage, required
> by `r770-bundle.sh verify --strict`). After `./r770-bundle.sh verify .`,
> run `sudo <bundle>/kit/scripts/r770-install.sh discover`, then `plan`, then
> `run --yes`. See sim-lab-basic's `docs/deployment-runbook.md`, "The
> installer". The hand-typed procedure below is the reference for what each
> step does. `site/scripts` is no longer the deploy path.
```

- [ ] **Step 2: Gate and commit**

Run: `./tests/run.sh > "$SCRATCH/sb-gate.log" 2>&1; echo $?`
Expected: `0`. If that repo's references test trips on a path, rephrase it with the `<bundle>/` prefix and ledger a Ruling.

```bash
git add docs/plans/r770-install-runbook.md
git commit -m "Runbook: the R770 install runs from the bundle's kit/ (sim-lab-basic's r770-install.sh)"
```

---

## Part 3 — bringing them together

### Task 12: Resync `staging/` from `claude/kit-in-bundle`

**Files:**
- Modify: `staging/r770-offline-fetch.sh`, `staging/r770-bundle.sh`, `staging/r770-build-bundle.sh`, `staging/r770-staging-preflight.sh` (copied), `staging/PROVENANCE.txt`, `docs/kit-sync.md`
- Test: `tests/staging.bats` and the whole kit gate

- [ ] **Step 1: Capture the kit's local divergence.** In the kit repo:

```bash
OLD=$(sed -n 's/^commit: //p' staging/PROVENANCE.txt)
git -C /root/git/simlab-build show "$OLD:scripts/r770-offline-fetch.sh" > "$SCRATCH/fetch.base"
diff -u "$SCRATCH/fetch.base" staging/r770-offline-fetch.sh > "$SCRATCH/kit-divergence.patch"; echo "diff rc=$?"
```

Expected: `diff rc=1`. The patch holds only the monitoring trim that `staging/PROVENANCE.txt` describes; read it and confirm.

- [ ] **Step 2: Copy and reapply**

```bash
for f in r770-build-bundle.sh r770-bundle.sh r770-staging-preflight.sh r770-offline-fetch.sh; do cp "$SB/scripts/$f" "staging/$f"; done
patch staging/r770-offline-fetch.sh < "$SCRATCH/kit-divergence.patch"
```

Expected: it applies (offsets allowed, no rejects). On a reject, reapply the trim by hand following `PROVENANCE.txt`'s description, and ledger it.

- [ ] **Step 3: Regenerate PROVENANCE** with `docs/kit-sync.md`'s procedure, and the commit set to `git -C "$SB" rev-parse HEAD`. Update the prose under `commit:` to "Resynced 2026-10-03 from that commit (simlab-build branch claude/kit-in-bundle, PR pending; also carries main's #16)", keeping the monitoring-trim paragraph.

- [ ] **Step 4: Run the tests**

Run: `./tests/run.sh > "$SCRATCH/gate.log" 2>&1; echo $?; grep -E '^not ok' "$SCRATCH/gate.log"`
Expected: `0`. A kit test that runs the staging fetch for real (not `--list`/`--dry-run`) now needs `KIT_SRC_ROOT`: point it at the kit's own checkout (`$BATS_TEST_DIRNAME/..`) and ledger a Ruling.

- [ ] **Step 5: Commit**

```bash
git add staging/ docs/kit-sync.md tests/
git commit -m "staging/: resync from simlab-build claude/kit-in-bundle — the kit stage, kit/ in verify, the packed kit; monitoring trim reapplied"
```

---

### Task 13: The final review, then the acceptance rehearsal on VM 9770

This task produces evidence, not code. Each step's Expected is a verdict seen in a transcript.

- [ ] **Step 1: The final whole-branch review**, per the executing skill. Cover both branches: the kit's `offline-installer` (merge-base `origin/main`) and the build repo's `claude/kit-in-bundle`. Do the fix pass for Critical/Important findings test-first.
- [ ] **Step 2: Stop and ask the operator before pushing.** A push is outward-facing. Do not merge.
- [ ] **Step 3: Roll back the VM.** From the build-repo worktree: `STAGING_VMID=9770 ./scripts/r770-staging-vm.sh rollback clean-2026-09-24`, then `start`, then `wait-ssh 300`. Expected: SSH answers.
- [ ] **Step 4: Cut on the VM.** Clone simlab-build at `claude/kit-in-bundle` and sim-lab-basic at `offline-installer`, then run `KIT_SRC_ROOT=~/sim-lab-basic SITE_SRC_ROOT=~/simlab-build ~/simlab-build/scripts/r770-build-bundle.sh`. Expected: `RESULT: PASS` from the strict gate, and `kit/KIT_COMMIT` equals the pushed kit HEAD.
- [ ] **Step 5: Make the VM look like the R770.**
  - `rm -rf ~/sim-lab-basic`, so no kit checkout remains.
  - Stand in the media the way `state/inventory/staging-e2e-2026-09-29.md` records it (the loop-device media).
  - Before Docker is installed, a 40G loop-mounted ext4 at `/var/lib/containerd`: the storage stand-in, recorded as such.
  - Block the air gap with `r770-airgap-sim.sh` (240 min).
- [ ] **Step 6: Run only the bundle's commands.**
  - `<media>/<bundle>/r770-bundle.sh verify <media>/<bundle>` → PASS.
  - `sudo <media>/<bundle>/kit/scripts/r770-install.sh discover` → the template.
  - `wizard` → `install.conf`, then add `VALIDATE_AREAS=network capture gns3 storage portal airgap` (the areas a VM can prove).
  - `plan` → review it. A FAIL there is a finding: one change at a time.
  - `run --yes`.

  Expected: the hand-off line, then `INSTALLED`, with e2e READY for all 8 scenarios.
- [ ] **Step 7: Re-entry proof.** Interrupt a second `run --yes` during `malcolm`, then run `/srv/bundles/<bundle>/kit/scripts/r770-install.sh run --yes --from malcolm` → `INSTALLED`. Then `umount <media>` → clean.
- [ ] **Step 8: The record.** In the build-repo worktree, write `state/inventory/staging-installer-<date>.md`: the cut, the stand-ins, each verdict, and the summary file's contents. Add a `state/BUILD-STATE.md` line, and commit on `claude/kit-in-bundle`. Lift the air gap.
