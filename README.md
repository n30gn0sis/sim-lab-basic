# sim-lab-basic — R770 offline deployment kit

Both sides of the air gap, in one clone. The build repo (`simlab-build`)
designs the lab and owns the bundle pipeline; this kit carries that pipeline
**verbatim** under `staging/` for the internet-connected staging host, and
**takes the bundle onto the air-gapped Dell PowerEdge R770 and stands the
services up** with `scripts/` — verified, gated, idempotent, and with evidence
for every step. Nothing under `scripts/` reaches the internet, and the only
version pins in the kit are in the fetch script's pin block, their one owner.

```
Staging host (internet)      staging/r770-build-bundle.sh → bundle-YYYYMMDD/   (carried from simlab-build)
        │  checksummed ext4 media, carrying the bundle AND this kit side by side
        ▼
R770 (air-gapped, Ubuntu 24.04)   scripts/r770-deploy.sh → 13 stages, each gated and evidenced
        ▲
iDRAC (out-of-band)               recovery path — verified before any networking phase, by the build repo's rules
```

## Cutting a bundle (staging host)

```bash
./staging/r770-build-bundle.sh          # preflight → fetch → manual-items pause → manifest → verify --strict
```

Exit **0** gated clean · **2** built with warnings to disposition · **1**
failed, do not move the media. `staging/README.md` says what each of the four
scripts does and why they are never edited here.

## Quick start

On the R770, as root, with the media mounted (device name **discovered** with
`lsblk`, never assumed):

```bash
sudo ./scripts/r770-deploy.sh \
    --bundle /mnt/bundle/bundle-YYYYMMDD \
    --media /mnt/bundle --device /dev/<discovered> \
    --mgmt-ip <management address>
```

Exit **0** every stage clean · **2** finished with warnings to disposition ·
**1** a stage refused or failed — fix it, then `--from <stage>`.

Every gate prints *current · proposed · rollback* and waits for a `y`, or for
`--yes`. An unattended run (`--non-interactive`) without `--yes` stops at the
first gate on purpose: a gate is a question, and a run that cannot answer must
not assume. `--dry-run` prints every command instead of executing it.

Read `docs/deployment-runbook.md` before the first run; it shows which stages
are ready today and which still wait on their own build-repo phase — iDRAC
and the build repo's Phase 5 don't gate anything in this kit.

## What's here

| Path | What |
|---|---|
| `scripts/r770-deploy.sh` | The runner: 13 stages in order, `--from/--to/--only`, stops at the first refusal. Holds no logic of its own |
| `scripts/r770-import-bundle.sh` | Bundle in: preflight, gate (the verifier **that travels in the bundle**), copy, local APT repo, phone-home neutralised, Docker, image loads with every tag asserted, payload into place |
| `scripts/r770-malcolm-deploy.sh` | Malcolm: load/assert-tags (as in the build repo), unpack, configure by replaying the kit's config template through the installer, secrets, auth, the port rebind, start with Malcolm's own script; then `inventory` (read-only, what Dashboards holds), `dashboards` and `arkime-views` (the lab's IPsec saved searches and views, each asserted back after install) |
| `scripts/r770-gns3-deploy.sh` | GNS3: venv from the wheelhouse (`--no-index`), service user, config owned by that user, systemd unit on 127.0.0.1 |
| `scripts/r770-portal-deploy.sh` | Portal: easy-rsa CA generated here, one five-SAN cert, vhosts (`nginx -t` before reload, probe after), landing page, analyst wiki built offline |
| `scripts/r770-monitoring-deploy.sh` | Prometheus/Alertmanager/Grafana/cAdvisor/blackbox on loopback, images from the bundle's list, `--pull never` |
| `scripts/r770-airgap-check.sh` | Read-only posture report: no APT source, resolver, mirror, proxy, snap or pip index points outside |
| `scripts/r770-validate.sh` | The success-criteria suite as a check · expected · observed · verdict · evidence table; SKIP with a reason, never silence |
| `staging/` | The build repo's bundle pipeline, byte-identical (`staging/PROVENANCE.txt`): preflight, fetch (the pin owner), the one-command builder, and the verifier the fetch places inside every bundle. Runs on the staging host only |
| `scripts/lib/common.sh` | The one set of seams (`KIT_ROOT`, `KIT_DRY_RUN`, `KIT_YES`, `KIT_NON_INTERACTIVE`, `KIT_EVIDENCE_DIR`), gates, rendering, image-list handling, the call into the bundle's verifier |
| `config/` | nginx vhosts, monitoring compose, GNS3 template + unit, Malcolm config template, portal page, mkdocs — carried from the build repo with the deltas in `config/README.md` |
| `docs/deployment-runbook.md` | The R770-side procedure, one step per stage, with the gate you will see and the failure each step prevents |
| `docs/rollback.md` | Per stage: what changed, where the backup is, the exact undo, what is not reversible |
| `docs/validation.md` | Areas, opt-in flags, what SKIPPED means, how a FAIL is handled |
| `docs/kit-sync.md` | How this kit relates to the build repo: copied vs referenced, the sync checklist, the no-pins rule |
| `docs/secrets-locations.md` | Where every generated credential lives, by location and mode only |
| `docs/wiki/` | The analyst wiki source (copied from the build repo), built into `docs.lab` on the R770 |
| `docs/CODEMAPS/` | Token-lean maps for getting oriented fast: `architecture.md` (the two hosts, the three layers, what `common.sh` owns), `stages.md` (stage → script → subcommand → config, and which six are gated), `dependencies.md` (the bundle layout, packages required but never installed, the loopback port map). They name owners rather than restating them |
| `tests/` | `./tests/run.sh` — shellcheck with no exclusions (one carried file keeps the build repo's accepted list), and bats suites that stub every host tool and write into a fake root. Offline, read-only, never a real bundle |
| `.claude/settings.json` | Agent guardrails for a session opened in this kit: destructive disk commands, `curl`/`wget`/`pip install`/`docker pull`/`snap` denied; every deploy script asks |
| `CLAUDE.md` | Operating rules for an agent working in this kit |

## Two rules the kit enforces on itself

- **The verifier is the bundle's.** `r770-bundle.sh verify` ships inside the
  bundle root and is covered by the bundle's manifest; the kit calls that copy
  and ships none of its own. A hand-rolled checksum gate cannot see files added
  after the manifest was written, and `tests/no-legacy-manifest.bats` refuses
  one.
- **One pin owner.** `staging/r770-offline-fetch.sh` carries the pin block,
  as it does in the build repo; nothing else in the kit may restate a version.
  Image tags on the R770 side are read from the bundle's `*/image-list.txt`,
  the Malcolm installer is found by glob and its version derived from its
  filename, the config templates carry tokens. `tests/no-pins.bats` fails on
  any `x.y.z` outside the owner that is not an address or a `0.0.0-fixture`.
  What a bundle carries is in its own `BUNDLE_NOTES.md`.

## Evidence

Every script tees its transcript to `./r770-evidence/<script>-<host>-<ts>.log`
(`KIT_EVIDENCE_DIR` moves it); `r770-validate.sh` also writes
`validation-<host>-<ts>.md`. Carry that directory back to the build repo's
`state/inventory/` when the cycle is recorded — an assertion is not evidence,
a transcript is.

## Tests

```bash
sudo apt-get install -y shellcheck bats     # once, on any Linux box (not the R770)
./tests/run.sh
```

Never commit secrets, keys, evidence, or a bundle to this repo.
