# Keeping the kit in step with the build repo

**Companion to:** `config/README.md` · the build repo's `OWNERS.md`
**Date:** 2026-09-14

```
simlab-build (design + build side)            sim-lab-basic (R770 side — this kit)
  PRD, buildout plan, hardware of record        deployment runbook, rollback, validation
  r770-offline-fetch.sh  -> the bundle          r770-import-bundle.sh   <- the bundle
  r770-bundle.sh         -> travels IN it       lib/common.sh calls the bundle's copy
  r770-malcolm-deploy.sh (load, assert-tags)    r770-malcolm-deploy.sh  (same two + the rest)
  config/                (proven on staging)    config/                 (carried, deltas listed)
  simlab-build/docs/analyst-wiki/               docs/wiki/              (carried verbatim)
  state/  (evidence, owned facts)               r770-evidence/          (gitignored; carried back)
```

## Copied, referenced, or neither

| Thing | Relationship | Rule |
|---|---|---|
| The verifier (`r770-bundle.sh verify`, run as `<bundle>/r770-bundle.sh verify <bundle>`) | **referenced** — the copy inside the bundle root, covered by its manifest | the kit ships no file by that name (`tests/no-legacy-manifest.bats`) |
| Version pins | **neither** — read from the bundle (`*/image-list.txt`, filenames, `BUNDLE_NOTES.md`) | no `x.y.z` in the kit (`tests/no-pins.bats`) |
| `load` / `assert-tags` | **copied** behaviour from the build repo's `r770-malcolm-deploy.sh` | its tests ported into `tests/malcolm-deploy.bats` |
| `config/` | **copied**, with the deltas in `config/README.md` | every hunk of `diff -r` is a listed delta or a change to port |
| `docs/wiki/` | **copied** verbatim from `simlab-build/docs/analyst-wiki/` | resync whenever the wiki changes; it becomes `docs.lab` |
| Hardware of record, phase status | **neither** — the kit takes them as arguments (`--expect-threads`, `--capture-ifs`, ...) | no number restated in the kit |
| Evidence | **carried back** — `r770-evidence/` to the build repo's `state/inventory/` | never committed here |

## Sync checklist (on the staging host, both checkouts present)

- [ ] `diff -r <simlab-build>/config config/` — every hunk is in `config/README.md`'s delta table, or is a change to port (port it, then add its row if it is a new delta)
- [ ] `diff -r <simlab-build>/docs/analyst-wiki docs/wiki` — empty
- [ ] `diff <simlab-build>/scripts/r770-malcolm-deploy.sh scripts/r770-malcolm-deploy.sh` — the `load`/`assert-tags` behaviour still matches (the kit's version is a superset)
- [ ] The bundle layout the import script expects (`apt/ docker/ malcolm/ gns3/{wheelhouse,appliances,definitions,docker-nodes} images/ enrichment/ docs/ dell/`, the three list/payload pairs) still matches what `simlab-build/scripts/r770-offline-fetch.sh` writes
- [ ] `./tests/run.sh` green here; the build repo's suite green there
- [ ] Tag the kit with the bundle date it was rehearsed against, and name that tag in the build repo's cycle log

## The no-pins rule, and why the kit is stricter than the build repo

The build repo keeps one owner per fact and lets `state/` restate values as
evidence. The kit has no owner for any pin and no evidence tree, so it carries
**none**: a pin here would be a copy nothing updates on the next bump, and it
would break at the air gap, where there is no way to look the value up.
Anything that needs a value reads it from the bundle at run time, or takes it
as an argument, and the flag set the kit passes to Malcolm's tools is asserted
against those tools' `--help` before use.

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
