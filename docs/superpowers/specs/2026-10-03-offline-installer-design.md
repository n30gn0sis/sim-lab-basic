# Offline installer — design

Date: 2026-10-03. Status: approved in brainstorming, awaiting written-spec review.

## Goal

An operator holding an R770 with Ubuntu 24.04 already installed, and the bundle
media, reaches a **proven** lab — GNS3, Malcolm, docs, portal, dashboards,
validated, every scenario passing end to end — through one guided or unattended
run, with nothing else: no git checkout, no internet.

## Decisions (from the operator)

| Topic | Decision |
|---|---|
| Start point | Ubuntu 24.04 already installed. OS install is out of scope. |
| Canonical R770 code | This kit's `scripts/` is the one deploy path, and it travels **inside the bundle**, covered by the bundle's own verifier. The build repo's `site/scripts` stops being the deploy path (`site/` keeps shipping; deleting it is a separate decision). |
| Interaction | An answers file (`install.conf`) is the core: one plan review, then `run --yes` unattended. A thin wizard only writes `install.conf`. |
| Done means | GNS3, Malcolm, docs, portal, dashboards, validate, then `r770-e2e.sh` across all 8 scenarios. INSTALLED is the same bar as the 2026-09-29 staging test. |
| Docker image storage | Check, and refuse when unsafe, with the fix printed. Never move data. |
| Approach | A thin sequencer over the existing entry points (not a flat cross-pipeline step list, not a self-extracting package). |

## Constraints carried unchanged

Every rule in `CLAUDE.md` holds: discover, never guess (no executed
placeholder); gates print current · proposed · rollback and need `--yes`;
`--non-interactive` without `--yes` stops at the gate; the verifier is the
bundle's; one pin owner; no secrets on argv or in git; 0/2/1 exits and
`PASS`/`WARN`/`FAIL`/`SKIP`; evidence under `r770-evidence/`; `staging/` is
edited only by resync.

## 1. `scripts/r770-install.sh`

### `install.conf`

Plain `KEY=value`, comments with `#`. Each key maps to exactly one flag the
pipelines already accept:

| Key | Feeds | Source |
|---|---|---|
| `BUNDLE` | `--bundle` (every pipeline, e2e) | defaults to the installer's own `kit/..` **only** when `bundle_dir()` accepts it; otherwise required |
| `MEDIA` | `--media` | `findmnt` discovery |
| `DEVICE` | `--device` | `lsblk` discovery |
| `CAPTURE_IFS` | Malcolm `--capture-ifs`, validate, e2e | `lab_mirror0`, plus any physical tap ports |
| `LAB_BRIDGE` | validate, e2e `--lab-bridge` | GNS3's labnet bridge |
| `MGMT_IF`, `MGMT_CIDR` | validate `--mgmt-if`, `--mgmt-cidr` | `ip -br addr` discovery |
| `PORTAL_SANS` | portal `--subject-alt-name` | optional; omitted means the portal's own `.lab` defaults |

The file is parsed, never sourced (no shell evaluation of operator text). FAIL
on: an unknown key; a required key that is empty; a value matching a
placeholder pattern (`/dev/sdX`, `eno1`-style examples, `<...>`, `CHANGEME`); a
`DEVICE` that is not a block device; an interface that does not exist (except
`lab_mirror0` and `LAB_BRIDGE` before GNS3's `labnet` has run, which are
checked by the steps that create them).

### Subcommands

| Subcommand | Does | Changes the host? |
|---|---|---|
| `discover` | Prints disks, NICs, addresses, existing bridges; writes `install.conf.template` with each discovered option as a comment beside its key. Never fills a value. | Writes the template only |
| `wizard` | Reads the same discovery, asks the operator to pick from numbered lists, writes `install.conf`. Nothing else. | Writes `install.conf` only |
| `plan` | Validates `install.conf`, runs the storage check (section 3) read-only, then runs every step with `--dry-run` so every gate's current · proposed · rollback prints in one review. | No |
| `run [--yes] [--from <step>] [--to <step>]` | Runs the steps in order, passing `--yes --non-interactive` when given `--yes`. Without `--yes` it stops at the first gate. Stops at the first FAIL. | Yes |
| `status` | Shows which steps are stamped done (`/srv/bundles/.kit-stamps`). | No |

### Steps (the names `--from`/`--to` accept)

1. `gns3` — `r770-gns3-deploy.sh full`
2. `malcolm` — `r770-malcolm-deploy.sh full` (after `gns3`: Malcolm's `configure` needs `labnet`)
3. `docs` — `r770-docs-deploy.sh full`
4. `portal` — `r770-portal-deploy.sh` `ca`, `cert`, `htpasswd`, `nginx`, in that order
5. `dashboards` — `r770-malcolm-deploy.sh dashboards` then `r770-malcolm-deploy.sh arkime-views` (both outside Malcolm's `full`; both idempotent and assert their objects back)
6. `validate` — `r770-validate.sh` with every area (no `--area` given), plus `--capture-ifs`, `--lab-bridge`, `--mgmt-if`, `--mgmt-cidr` from `install.conf`
7. `e2e` — `r770-e2e.sh --skip-validate` (validate already ran as step 6)

`run_step`/`step_index` from `scripts/lib/common.sh` slice the sequence. The
installer adds no pipeline logic; each pipeline keeps its own contract and can
still run alone.

### Verdict

- **INSTALLED** (exit 0): every step READY and e2e READY.
- **WARN** (exit 2): any step ended WARN. Never INSTALLED.
- **FAIL** (exit 1): the first FAIL, with the step name and a `run --yes --from <step>` hint.

The transcript goes to `r770-evidence/install-<host>-<ts>.log` through
`kit_init()`, and a one-page summary to `r770-evidence/install-<host>-<ts>.md`
(each step, its verdict, its own evidence log).

## 2. The kit inside the bundle (simlab-build, then resynced)

A new fetch stage in `staging/r770-offline-fetch.sh`, written in simlab-build,
mirroring stage 10 (`site/`):

- **Source:** `KIT_SRC_ROOT=<a sim-lab-basic checkout>`. No default — without
  it the stage refuses rather than guess which checkout ships.
- **Content:** `scripts/`, `config/`, `scenarios/`, `docs/` — tracked,
  committed files at `HEAD` only, to `bundle-*/kit/`. `staging/` and `tests/`
  are left out (they never run on the R770). Refuses symlinks, submodules and
  an empty result. Commit to `kit/KIT_COMMIT`. A dirty tree is a WARN, as for
  `site/`.
- **Packed builder:** `cmd_pack` carries a matching `KIT_ARCHIVE` +
  `KIT_COMMIT` pair, mirroring `SITE_ARCHIVE` + `SITE_COMMIT`.
- **Integrity:** the stage runs before Manifest, so `MANIFEST.sha256` covers
  every kit file and `<bundle>/r770-bundle.sh verify` proves it. The kit adds
  no checksum of its own.
- **Strict gate:** the bundle verifier lists `kit/scripts/r770-install.sh` as a
  required file, so a bundle without the installer fails `--strict`.
- **Build-repo runbook** points at `kit/scripts/r770-install.sh`.

Kit side: resync `staging/`, regenerate `staging/PROVENANCE.txt`, update
`docs/kit-sync.md` with the cut order (push the kit, then cut with
`KIT_SRC_ROOT` at that commit).

Operator's first two commands on the R770:

```
<media>/<bundle>/r770-bundle.sh verify
sudo <media>/<bundle>/kit/scripts/r770-install.sh discover
```

## 3. The storage check

Lives in the shared `docker` step of `scripts/r770-import-bundle.sh`, beside the
existing data-root assertion, so every pipeline gets it; `install plan` runs it
read-only first.

1. **Image store.** `docker info` says whether the containerd snapshotter is
   active. If not, images live under the data root, which the existing
   assertion covers — PASS.
2. **Where `/var/lib/containerd` lives** (`findmnt -T`): its own mount point,
   or the same filesystem as the `/var/lib/docker` LV — PASS. Otherwise it is
   on the root disk; go to 3.
3. **Room.** Needed = the sum of the bundle's image archive sizes × an
   expansion factor + 20% headroom. The factor is **measured** on staging (the
   on-disk size after load divided by the archive size, from the VM 9770
   rehearsal) and recorded in the code with a comment citing its evidence.
   - Free ≥ needed — WARN (fits, but outside the guarded volume); the run ends WARN.
   - Free < needed — FAIL, and the step refuses before any `docker load`.

On WARN or FAIL it prints the two known remedies — an LV mounted at
`/var/lib/containerd`, or the containerd snapshotter turned off in
`daemon.json` — with the commands to check afterwards. It never applies
either. It reads only `docker info`, `findmnt` and `df`.

## 4. Testing and acceptance

### Offline (in `./tests/run.sh`)

- `tests/install.bats`:
  - `install.conf` parsing: unknown key, empty required key, each placeholder pattern → FAIL; the file is never sourced;
  - `discover` writes only the template, with no value filled in;
  - `wizard` with scripted stdin writes exactly the chosen values;
  - `plan` invokes every step with `--dry-run` and nothing else;
  - `run` without `--yes` stops at the first gate;
  - step order; stop on the first FAIL; `--from`/`--to`;
  - a WARN step makes the verdict WARN;
  - `BUNDLE` defaults from `kit/..` only when `bundle_dir()` accepts it.
- `tests/import-bundle.bats`: snapshotter off → PASS; containerd store on its own mount → PASS; on root with room → WARN; on root without room → FAIL, with no `docker load` invoked; the remedy text is printed.
- Build repo: tests for the `kit/` stage (refuses without `KIT_SRC_ROOT`, tracked files only, refuses symlinks); `--strict` fails without `kit/scripts/r770-install.sh`.
- Kit side: `tests/staging.bats` proves the resync byte for byte; shellcheck with no exclusions; a `README.md` row; a `.claude/settings.json` allow entry; `tests/references.bats` for every new path in the docs.

### Acceptance rehearsal (VM 9770)

1. Roll back to `clean-2026-09-24`.
2. Push the kit, then cut a fresh bundle with `KIT_SRC_ROOT` at that commit. `--strict` must PASS.
3. Lift the media onto the VM and turn the air gap on. No kit checkout is on the VM.
4. Run only the bundle's commands: `r770-bundle.sh verify`, then `kit/scripts/r770-install.sh discover`, `wizard`, `plan`, `run --yes`.
5. The pass mark is INSTALLED, with all 8 scenarios READY in e2e.
6. Re-entry proof: kill the run during `malcolm`, then `run --yes --from malcolm` → INSTALLED.

**Staging stand-in:** the VM's containerd store is on its root disk, so
section 3 WARNs or FAILs there, as designed. For the rehearsal, one printed
remedy (a loop-mounted volume at `/var/lib/containerd`) is applied on the VM,
the same way Phase 3 volumes are stood in, and recorded in the rehearsal
record. It is never kit code.

## Deliverables

- Kit PR: `scripts/r770-install.sh`, the storage check, `tests/install.bats`
  and the `tests/import-bundle.bats` additions, `README.md`,
  `docs/deployment-runbook.md` (a new "Install" section at the top; the
  per-pipeline procedures stay as the reference), `.claude/settings.json`,
  the `staging/` resync and `docs/kit-sync.md`.
- simlab-build PR: the `kit/` fetch stage, the `--strict` requirement, the
  runbook pointer, and the rehearsal record.

## Out of scope

- Installing the OS (autoinstall or a bootable ISO).
- Moving or relocating Docker or containerd data.
- Deleting the build repo's `site/`.
- The deferred e2e minors (M-1 to M-10) and the liveArkime→netsniff question.
