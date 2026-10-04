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

## Local divergence: `staging/r770-offline-fetch.sh` (since 2026-09-21)

**The one deliberate, user-approved exception to the byte-for-byte carry rule
above.** The kit trims `MONITOR_IMAGES` to `mkdocs-material` alone (it no
longer deploys Prometheus/Alertmanager/blackbox-exporter/Grafana-OSS/cAdvisor,
and the stock nginx and docker-registry v2 images had no consumer);
`mkdocs-material` stays because `docs.lab` is built by
`scripts/r770-docs-deploy.sh build`. The array's name and its two output
paths (`docker/monitoring-image-list.txt` / `docker/monitoring-images.tar.gz`)
are unchanged: `staging/r770-bundle.sh`'s `check_required()` pairs exactly
those filenames, and renaming either would make the verifier silently stop
checking that category. `seed()` also never reuses a prior bundle's
monitoring tarball (it may predate the trim), and stage 4 is labelled "Docs
build image".

**How a resync handles it** (last done 2026-10-03, from `simlab-build`
`4e13d82` on branch `claude/kit-in-bundle` — the kit stage, PR pending; before
that 2026-09-27 from `6ee96d2` — the stage-4 relabel reads `[4/11]`; the diff
is taken against the previously recorded commit and `patch`ed onto the new one): copy all four scripts from the build repo's commit, then reapply
exactly this divergence to `r770-offline-fetch.sh` — its header says so, and
`diff` against the upstream file shows only these hunks. Record the commit in
`staging/PROVENANCE.txt` and regenerate the four hashes; the other three
scripts are that commit byte for byte. Bundles cut by the build repo itself
still carry the full monitoring set; the kit reads only `mkdocs-material` out
of that list, so either kind of bundle works here.

## The 2026-09-27 resync: the build repo now ships its own `site/`

`simlab-build` `6ee96d2` adds a `site` stage to the fetch: the bundle carries
that repo's reviewed `simlab-build/scripts/`, `simlab-build/config/` and `simlab-build/docs/analyst-wiki/` as
`site/`, at an exact commit. Carrying it here, byte for byte, means:

- **Cutting a bundle needs a simlab-build checkout.** The fetch refuses at
  startup — even `--list` and `--dry-run` — unless `SITE_SRC_ROOT` points at
  one (or `SITE_ARCHIVE` + `SITE_COMMIT` from a packed builder); from this
  kit's tree it would otherwise guess what belongs in `site/`. `--pack` reads
  the same tree through `BUILD_PACK_ROOT` and refuses this kit's own tree
  (`tests/staging.bats`).
- **The verifier expects `site/`.** A bundle without it, or missing one of
  the verifier's `SITE_REQUIRED_SCRIPTS`, is a WARN — so `--strict` (the
  builder's gate) fails it. The kit's R770 side runs `<bundle>/r770-bundle.sh
  verify` non-strict, so an older bundle imports with that WARN to
  disposition; nothing in `scripts/` reads `site/`.

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
- **Carried to the build repo 2026-09-25 (simlab-build PR #11).** The
  hub-mode lab mirror (buildout §4.3/§7.2, PRD §5); the wiki's mirror
  procedure (Cloud node, **TAP** tab — never the Ethernet tab, which gns3-server
  opens with a raw socket whose frames an unheld TAP drops) and its
  scenario-pack section, carried back into `docs/wiki/gns3.md`; and the
  strongSwan pin (`STRONGSWAN_IMG` in `GNS3_NODE_IMAGES`, resynced into
  `staging/r770-offline-fetch.sh`).
- **strongSwan does not start charon by itself** — settled on the staging
  rehearsal: `scenarios/ipsec-ike`'s gateway scripts start
  `/usr/libexec/ipsec/charon`; the image carries `swanctl` and `iproute2`.
- **ubridge** comes from GNS3's PPA in the APT set, and the node-image
  archive is reused only when its list matches the pins — both carried in
  the 2026-09-27 resync (`simlab-build` `6ee96d2`).
- **Upstream `config/` changes since `f66d71b`, not ported (2026-09-27).**
  The build repo's analyst-stack work added `simlab-build/config/nginx/00-default-reject.conf`,
  `conf.d/lab-connection-upgrade.conf`, `snippets/lab-headers.conf`,
  `portal.lab.conf`, security-header and websocket edits to `malcolm.lab.conf`
  and `docs.lab.conf`, and a rendered `simlab-build/config/malcolm/malcolm-config.json`.
  They are rendered by that repo's own `site/scripts` (`r770-portal.sh`,
  `r770-lab-ca.sh`, `r770-malcolm-deploy.sh`), a second R770 deploy path
  beside this kit's `scripts/`. Whether to port them depends on which path
  is canonical; until that is decided they are recorded here, not copied.

## Cutting a bundle that carries this kit (since 2026-10)

The build repo's fetch has a `kit` stage: it copies this repo's tracked,
committed `scripts/ config/ scenarios/ docs/` at `HEAD` into `bundle-*/kit/`
and records the commit in `kit/KIT_COMMIT`. It has no default source. Order:

1. Merge and push this kit; note the commit.
2. On the staging host: `KIT_SRC_ROOT=<a checkout of this kit at that commit> SITE_SRC_ROOT=<simlab-build checkout> ./staging/r770-build-bundle.sh`.
   A packed builder carries the kit when `KIT_SRC_ROOT` is set at `--pack` time.
3. The build's strict gate fails a bundle without `kit/scripts/r770-install.sh`.
