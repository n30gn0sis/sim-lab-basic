<!-- Generated: 2026-09-17 | Files scanned: 72 tracked | Token estimate: ~700 -->

# Architecture

Two hosts, one repo. A bundle is the only thing that crosses between them.

```
STAGING HOST (internet)                     R770 (air-gapped, Ubuntu 24.04)
  staging/r770-staging-preflight.sh           scripts/r770-deploy.sh
  staging/r770-offline-fetch.sh  ──┐            └─ 13 stages, in order
    (the one pin owner)            │               stops at the first refusal
  staging/r770-build-bundle.sh     │
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
r770-deploy.sh            orchestrator — holds no logic of its own
  │ script_for(stage) → one of six scripts; child() wraps each in 0/2/1
  ▼
r770-import-bundle.sh  r770-gns3-deploy.sh  r770-malcolm-deploy.sh
r770-portal-deploy.sh  r770-monitoring-deploy.sh  r770-validate.sh
  │ every one sources ↓
  ▼
scripts/lib/common.sh     the only seam that touches the host
```

`scripts/r770-airgap-check.sh` is read-only and stands outside the stage list;
`r770-validate.sh` folds its rows in under the `airgap` area.

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

## Exit contract, everywhere

`0` clean · `2` done with warnings to disposition · `1` refused or failed.
Check lines are `PASS` / `WARN` / `FAIL` / `SKIP`; `footer()` turns the tally
into the exit. `kit_init()` tees every transcript to
`r770-evidence/<script>-<host>-<ts>.log` — gitignored, carried back to the
build repo's `state/inventory/` by hand.

A stage that refused names the `--from <stage>` to resume with. Every stage is
idempotent: copies stamped, loads skip present tags, secrets generated once,
the rebind recognises itself, the CA and certificate reused.

## Owners (do not restate here)

Version pins → `staging/r770-offline-fetch.sh` · config deltas and tokens →
`config/README.md` · test suites → `tests/README.md` · procedure →
`docs/deployment-runbook.md` · phase status → build repo's
`state/BUILD-STATE.md`.
