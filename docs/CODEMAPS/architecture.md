<!-- Generated: 2026-09-21 | Files scanned: 72 tracked | Token estimate: ~700 -->

# Architecture

Two hosts, one repo. A bundle is the only thing that crosses between them.

```
STAGING HOST (internet)                     R770 (air-gapped, Ubuntu 24.04)
  staging/r770-staging-preflight.sh           scripts/r770-malcolm-deploy.sh full
  staging/r770-offline-fetch.sh  ──┐            scripts/r770-gns3-deploy.sh full
    (the one pin owner)            │            scripts/r770-docs-deploy.sh full
  staging/r770-build-bundle.sh     │            three independent pipelines,
                                   │            no outer orchestrator
  staging/r770-bundle.sh ──────────┤
    (copied INTO the bundle)       │
                                   ▼
                       bundle-YYYYMMDD/ on checksummed ext4 media
                       (the kit travels BESIDE it, not inside)
                                   │
                                   ▼
                       gate: <bundle>/r770-bundle.sh verify
                       PASS/WARN → import · FAIL → re-cut on staging
```

`staging/` never runs on the R770, and `scripts/` never calls `staging/`
(`tests/no-legacy-manifest.bats`). Byte-identity of the four carried files is
guarded by `staging/PROVENANCE.txt` + `tests/staging.bats`.

## Three layers on the R770 side

```
r770-malcolm-deploy.sh full   r770-gns3-deploy.sh full   r770-docs-deploy.sh full
  │ own STEPS array             │ own STEPS array          │ own STEPS array
  │ run_step()/step_index()     │ run_step()/step_index()  │ run_step()/step_index()
  ▼                             ▼                          ▼
                 (independent; each brings its own bundle in from the media)
r770-import-bundle.sh  ◄── shared bundle-prep steps, idempotent in any order
r770-portal-deploy.sh          optional front door, run by hand after Malcolm
r770-validate.sh               read-only checks, run at any point
  │ every one sources ↓
  ▼
scripts/lib/common.sh     the only seam that touches the host
```

`scripts/r770-airgap-check.sh` is read-only and stands outside every pipeline;
`r770-validate.sh` folds its rows in under the `airgap` area.

## Three independent `full` pipelines, one shared prep

`r770-malcolm-deploy.sh full`, `r770-gns3-deploy.sh full` and
`r770-docs-deploy.sh full` each hold their own `STEPS=(...)` array and step
through it with `common.sh`'s `run_step()`/`step_index()` — there is no outer
orchestrator holding a combined stage list. All three begin with the same
bundle-prep steps (`preflight gate copy apt phone-home docker files`, all
against `r770-import-bundle.sh`) before diverging into their own `load` and
pipeline-specific steps. Every one of those shared steps is idempotent
(`copy` stamps, `apt` short-circuits via `cmp -s`, `phone-home` is a no-op on
an already-disabled unit, `docker` install is idempotent by itself, `files`
stamps per category), so running one pipeline's `full` after another has
already run reports "already done" for the shared prefix and moves straight
into its own steps. The only added cost is `gate`'s bundle re-verification
running once per pipeline instead of once total.

The front door (`r770-portal-deploy.sh`: `ca cert htpasswd nginx`) is
never part of any `full` — it is run by hand, after Malcolm, because
`htpasswd` has a hard dependency on Malcolm's `auth` step having already
produced the login material it copies. It serves `docs.lab` but no longer
builds it — `r770-docs-deploy.sh build` does.

## What common.sh owns

| Concern | Function | Why it exists |
|---|---|---|
| Host seams | `KIT_ROOT` `KIT_DRY_RUN` `KIT_YES` `KIT_NON_INTERACTIVE` `KIT_EVIDENCE_DIR` | makes every script dry-runnable and testable against a fake root |
| Gated change | `gate()` | prints current · proposed · rollback, then needs `--yes` or a `y` |
| Bundle trust | `bundle_verify()` | runs the verifier **inside** the bundle; the kit ships none |
| Tool lies | `assert_image_tags()` | `docker load` reports success on an incomplete tag set |
| Interface drift | `help_has_flags()` | a bundled tool's flag vanishing fails by name, not by surprise |
| Templates | `render()` | refuses to write if any `__TOKEN__` survives |
| Shape drift | `assert_edit()` | refuses to edit a file whose format moved |
| Credentials | `secret_file()` | generate once, print the path, never the value |
| Idempotency | `stamp()` / `stamped()` | markers under `/srv/bundles/.kit-stamps` |
| `full`'s step slicing | `step_index()` / `run_step()` | `--from/--to/--only` resolve against a script's own `STEPS` array; `run_step()` applies the uniform 0/2/1 contract around each one |

## Exit contract, everywhere

`0` clean · `2` done with warnings to disposition · `1` refused or failed.
Check lines are `PASS` / `WARN` / `FAIL` / `SKIP`; `footer()` turns the tally
into the exit. `kit_init()` tees every transcript to
`r770-evidence/<script>-<host>-<ts>.log` — gitignored, carried back to the
build repo's `state/inventory/` by hand.

A step that refused names the `--from <step>` to resume `full` with. Every
step is idempotent: copies stamped, loads skip present tags, secrets
generated once, the rebind recognises itself, the CA and certificate reused.

## Owners (do not restate here)

Version pins → `staging/r770-offline-fetch.sh` · config deltas and tokens →
`config/README.md` · test suites → `tests/README.md` · procedure →
`docs/deployment-runbook.md` · phase status → build repo's
`state/BUILD-STATE.md`.
