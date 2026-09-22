# Keeping the kit in step with the build repo

**Companion to:** `config/README.md` · the build repo's `OWNERS.md`
**Date:** 2026-09-14

```
simlab-build (design + build side)            sim-lab-basic (R770 side — this kit)
  PRD, buildout plan, hardware of record        deployment runbook, rollback, validation
  simlab-build/scripts/ (4 files)  ======>  staging/  (byte-identical; PROVENANCE.txt)
  r770-offline-fetch.sh  -> the bundle          scripts/r770-import-bundle.sh <- the bundle
  r770-bundle.sh         -> travels IN it       scripts/lib/common.sh calls the bundle's copy
  r770-malcolm-deploy.sh (load, assert-tags)    r770-malcolm-deploy.sh  (same two + the rest)
  config/                (proven on staging)    config/                 (carried, deltas listed)
  simlab-build/docs/analyst-wiki/               docs/wiki/              (carried verbatim)
  state/  (evidence, owned facts)               r770-evidence/          (gitignored; carried back)
```

## Copied, referenced, or neither

| Thing | Relationship | Rule |
|---|---|---|
| The bundle pipeline (`staging/`: preflight, fetch, one-command builder, verifier) | **copied byte for byte** from `simlab-build/scripts/`; identity guarded by `staging/PROVENANCE.txt` | never edited here; `tests/staging.bats` fails on a local change |
| The verifier the R770 side runs (`r770-bundle.sh verify`, as `<bundle>/r770-bundle.sh verify <bundle>`) | **referenced** — the copy the fetch places inside the bundle root, covered by its manifest | `scripts/` never reaches for `staging/r770-bundle.sh` (`tests/no-legacy-manifest.bats`) |
| Version pins | **one owner** — `staging/r770-offline-fetch.sh`'s pin block, as in the build repo; the R770 side reads pins from the bundle (`*/image-list.txt`, filenames, `BUNDLE_NOTES.md`) | no `x.y.z` anywhere else (`tests/no-pins.bats`) |
| `load` / `assert-tags` | **copied** behaviour from the build repo's `r770-malcolm-deploy.sh` | its tests ported into `tests/malcolm-deploy.bats` |
| `config/` | **copied**, with the deltas in `config/README.md` | every hunk of `diff -r` is a listed delta or a change to port |
| `docs/wiki/` | **copied** verbatim from `simlab-build/docs/analyst-wiki/` | resync whenever the wiki changes; it becomes `docs.lab` |
| Hardware of record, phase status | **neither** — the kit takes them as arguments (`--expect-threads`, `--capture-ifs`, ...) | no number restated in the kit |
| Evidence | **carried back** — `r770-evidence/` to the build repo's `state/inventory/` | never committed here |

## Sync checklist (on the staging host, both checkouts present)

- [ ] `( cd staging && for f in r770-*.sh; do diff -q "$f" <simlab-build>/scripts/"$f"; done )` — empty; if not, copy the four files over, then regenerate the record: `( cd staging && { grep -v '^[0-9a-f]\{64\}  \|^commit:' PROVENANCE.txt; echo "commit: $(git -C <simlab-build> rev-parse HEAD)"; sha256sum r770-*.sh; } > PROVENANCE.new && mv PROVENANCE.new PROVENANCE.txt )`
- [ ] `diff -r <simlab-build>/config config/` — every hunk is in `config/README.md`'s delta table, or is a change to port (port it, then add its row if it is a new delta)
- [ ] `diff -r <simlab-build>/docs/analyst-wiki docs/wiki` — empty
- [ ] `diff <simlab-build>/scripts/r770-malcolm-deploy.sh scripts/r770-malcolm-deploy.sh` — the `load`/`assert-tags` behaviour still matches (the kit's version is a superset)
- [ ] The bundle layout the import script expects (`apt/ docker/ malcolm/ gns3/{wheelhouse,appliances,definitions,docker-nodes} images/ enrichment/ docs/ dell/`, the three list/payload pairs) still matches what `simlab-build/scripts/r770-offline-fetch.sh` writes
- [ ] `./tests/run.sh` green here; the build repo's suite green there
- [ ] Tag the kit with the bundle date it was rehearsed against, and name that tag in the build repo's cycle log

## Local divergence: `staging/r770-offline-fetch.sh` (2026-09-21)

**This is a deliberate, one-time, user-approved exception to the byte-for-byte
carry rule above** — the only one in this repo. `staging/r770-offline-fetch.sh`
was hand-edited here (not resynced from `simlab-build`) to trim `MONITOR_IMAGES`
down to just `mkdocs-material`, dropping the Prometheus/Alertmanager/blackbox-
exporter/Grafana-OSS/cAdvisor monitoring images plus the confirmed-unused
stock-nginx and docker-registry-v2 images, as part of cutting monitoring from
this kit. `mkdocs-material` stays because the offline analyst wiki
(`docs.lab`, built by `scripts/r770-portal-deploy.sh docs`) still needs it.
The array's name and its two output paths
(`docker/monitoring-image-list.txt` / `docker/monitoring-images.tar.gz`) were
kept unchanged: `staging/r770-bundle.sh`'s `check_required()` — itself still
provenance-locked and untouched — hardcodes those exact filenames as a
matched list/payload pair, and renaming either would make the verifier
silently stop checking that category instead of failing loudly.

`staging/PROVENANCE.txt` records this: the hash for `r770-offline-fetch.sh`
was recomputed and no longer corresponds to any single `simlab-build` commit,
while the other three carried scripts' hashes are untouched. `staging/r770-bundle.sh`,
`staging/r770-build-bundle.sh` and `staging/r770-staging-preflight.sh` remain
byte-for-byte and provenance-locked; only the fetch script diverged.

**Reconciling this upstream (porting the trim back into `simlab-build`, or
re-carrying a future upstream fetch script over this local edit) is out of
scope for this repo.** A future sync pass on `staging/r770-offline-fetch.sh`
must not silently overwrite this local edit — diff it against this file
first, and re-apply the monitoring trim (or fold it upstream and re-carry)
rather than blindly copying `simlab-build`'s current version over it.

**Addendum (2026-09-22):** an external PR review on the trim above caught
that `seed()` would still reuse a stale prior bundle's untrimmed
`docker/monitoring-images.tar.gz` (the pre-trim payload, with the removed
monitoring images) even after the list file was correctly regenerated as
`mkdocs-material`-only — the seeded payload and the freshly written list
would silently disagree. `seed()` now excludes
`docker/monitoring-images.tar.gz` from prior-bundle reuse, the same way it
already excludes `apt/*`/`enrichment/*`. `staging/PROVENANCE.txt`'s hash
for `r770-offline-fetch.sh` was recomputed again for this change.

## The no-pins rule

The build repo keeps one owner per fact (`OWNERS.md` there): every version pin
lives in the fetch script's pin block. The kit carries that script verbatim
under `staging/`, so the owner is the same file in both repos, and nothing
else in the kit may restate a value: a copy would be one nothing updates on
the next bump, and it would break at the air gap, where there is no way to
look the value up. The R770 side reads what it needs from the bundle at run
time or takes it as an argument, and the flag set it passes to Malcolm's tools
is asserted against those tools' `--help` before use.

## Follow-ups recorded here, not silently added

- **Malcolm at boot.** The kit starts Malcolm once with its own script and
  installs no unit for it; the rehearsal decided "start once". The R770 will
  want a unit that runs Malcolm's `start` after Docker — a build-repo Phase 10
  decision.
- **`__LAB_DOMAIN__`.** The `.lab` names are literal in `config/` because they
  are a decision of record. Tokenising them was deliberately not done.
- **GNS3 node boot and WAN measurement** are manual in `r770-validate.sh`
  (SKIPPED with the reason) until the Phase 12 tooling exists somewhere the
  kit can call.
- **Installer fallback.** `configure` requires the bundled installer to accept
  a config-file import. If a future installer drops that, the fallback is the
  build repo's runbook procedure (`--defaults --configure`) plus the same
  rebind; the kit dies naming the flag rather than guessing.
