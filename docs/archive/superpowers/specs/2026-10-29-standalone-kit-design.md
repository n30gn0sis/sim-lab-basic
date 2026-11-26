# Standalone kit: cut the ties to the build repo

**Date:** 2026-10-29
**Status:** approved design, sub-project A of four
**Follow-ons (each gets its own spec):** B, a manual lab-setup guide with the
AWS and Proxmox procedures in separate documents · C, a Proxmox (local) test
harness · D, an AWS (cloud) test harness. A goes first because it changes the
rules for `staging/`, which both harnesses build on.

## Goal

This repo stops depending on, deferring to, or syncing with `simlab-build`.
`staging/` becomes the kit's own code under every kit rule. A bundle is cut
from a checkout of this repo alone.

## Decisions

| # | Decision | Rejected alternatives |
|---|---|---|
| D1 | `staging/` is ordinary kit code. It is edited and tested here, and is shellcheck-clean with **no exclusions** | freezing `staging/` behind a local hash guard with no upstream (friction on every C/D change, a guard with nothing behind it); docs-only rewording (the fetch would still refuse without a `simlab-build` checkout) |
| D2 | The fetch's `site` and `labimages` stages are removed | keeping them pointed at this repo: nothing on the R770 side reads `site/`, and no kit scenario uses `lab/*` images (they use the pinned `netshoot`, `frr` and `strongswan`). This kit already reaches the R770 through the `kit` stage |
| D3 | Phase gating is by discovery: a stage whose prerequisite is not present on the box SKIPs or refuses, with the reason | a hand-kept `docs/phase-status.md` (it drifts) |
| D4 | The dated specs and plans under `docs/superpowers/` stay as written | rewriting history; deleting it |

Unchanged: one pin owner (the fetch's pin block, `tests/no-pins.bats`); the two
hosts (`staging/` never runs on the R770, and `scripts/` never calls `staging/`,
`tests/no-legacy-manifest.bats`); the bundle contract (`bundle_dir()`); the
verifier travelling inside the bundle (rule 3).

## Code

### `staging/r770-offline-fetch.sh`
- Remove `site` and `labimages` from `STAGES` and the `--list` text. Remove
  `stage_site`, `stage_labimages`, `labimages_root`, `labimages_plan`,
  `SITE_TREES`, `LAB_IMAGES`, the `SITE_SRC_ROOT` / `SITE_ARCHIVE` /
  `SITE_COMMIT` handling, and the `labimages` case in the stage-done check.
- The `kit` stage stays (`KIT_SRC_ROOT`, shipped as `bundle-*/kit/`).
- Renumber the stage banners. Drop the "local divergence, NOT from simlab-build"
  header: the monitoring trim is simply how the file works.
- Fix every shellcheck finding (today's legacy list: SC2015, SC2012, SC2010,
  SC1091). Behaviour does not change; each fix is checked against the existing
  dry-run and `--list` output.

### `staging/r770-build-bundle.sh`
- `--pack` stops embedding `site.tar` / `site-commit.txt` and stops exporting
  `SITE_ARCHIVE` / `SITE_COMMIT`. It packs the four staging scripts plus the
  kit archive it already builds for `kit/`.
- A real run needs exactly one source: a clean kit checkout (`KIT_SRC_ROOT`,
  and `BUILD_PACK_ROOT` for `--pack`). The "must be a simlab-build checkout"
  refusal is gone.

### `staging/r770-bundle.sh` (the verifier)
- Remove `check_site`, `SITE_REQUIRED_SCRIPTS`, `SITE_REQUIRED_FILES` and the
  `site/images` against lab-images check, and their call in `verify`.
- `KIT_REQUIRED_FILES` and its check stay: a bundle without `kit/` fails as it
  does today.
- An older bundle that still carries `site/` verifies. Its manifest covers
  whatever is present, and nothing asks about `site/`.

### `staging/r770-staging-preflight.sh`
No build-repo ties. Lint fixes only, if any.

### `scripts/`
Comment-only changes in `scripts/r770-validate.sh` and
`scripts/r770-malcolm-deploy.sh`: "build repo PRD §10" and "behaviour-identical
to the build repo's script" become plain statements of what the code does. No
behaviour change, and the existing suites are the proof.

## Tests

- `tests/staging.bats`: remove the PROVENANCE hash and commit tests and the
  "`--pack` refuses the kit's own tree" test. Add:
  - `--list` names no `site` or `labimages` stage;
  - `--pack` with only a kit checkout produces a builder that passes `bash -n`
    and embeds no `site.tar`;
  - the verify round-trip passes on a fixture bundle with `kit/` and no `site/`;
  - a fixture bundle with a stray `site/` still verifies;
  - a fixture bundle with no `kit/` still fails.
- `tests/lint.bats`: delete `LEGACY_EXCLUDE` and its special case. Every file
  is linted with no exclusions.
- `tests/no-pins.bats`: drop the `PROVENANCE.txt` exclusion. The fetch keeps
  its exclusion as the pin owner.
- `tests/helpers/lint_scenarios.py`: with the pin block owned here,
  `UPSTREAM_PENDING` (pins "added to the build repo, not yet in a bundle") is
  re-examined. strongswan is checked against the fetch's pin block directly;
  the concept is removed if it no longer has a member.
- `tests/helpers/fixtures.bash`, `tests/malcolm-deploy.bats`: comments only.
- `./tests/run.sh` green is the gate, as always.

## Docs

- **Deleted:** `docs/kit-sync.md`, `staging/PROVENANCE.txt`.
- `README.md`: the bundle command no longer needs `SITE_SRC_ROOT`; remove the
  `site`-stage paragraph and the `docs/kit-sync.md` row; reword the `staging/`,
  `config/`, `docs/wiki/` and `tests/` rows and the evidence paragraph.
- `staging/README.md`: edit here, test here. The resync and "don't edit"
  sections go, and so do the runbook pointers into the build repo.
- `config/README.md`: the "Build-repo source" column goes. The table becomes
  file · how it differs from the upstream default · why. Every *why* is kept.
  The token table is unchanged.
- `docs/deployment-runbook.md`: drop the "Companion to" pointer. Phase-status
  checks become D3's discovery rule. The post-run checklist becomes "archive
  `r770-evidence/` off the box next to the bundle it ran against, noting the
  verifier exit, its `RESULT:` line and the WARN dispositions".
- `docs/validation.md`: describe the report format here (check · expected ·
  observed · verdict · evidence) instead of citing the build repo's runner.
  The `wan` row's SKIP reason names the missing tooling, not a repo.
- `docs/CODEMAPS/{architecture,dependencies,stages}.md`, `tests/README.md`,
  `.gitignore`: remove the build-repo sentences.
- `CLAUDE.md`: "What this is", "Two hosts" and "Run context" describe
  `staging/` as the kit's own pipeline. The phase-tracker bullet becomes D3.
  Rule 4: the pin block is edited here. "Working on the kit itself": replace
  the "four files never edited here" bullet with "`staging/` follows every
  kit rule", and drop the carried-file lint exception from Commands.

**Done when** `grep -rnE 'simlab-build|build repo|SITE_SRC_ROOT|PROVENANCE|kit-sync'`
over the tree, excluding `.git` and `docs/superpowers/`, returns nothing, and
`./tests/run.sh` is green.

## Risks

- **The lint cleanup changes behaviour.** Mitigation: fix one class at a time,
  and diff the `--dry-run` and `--list` output before and after each class.
- **A bundle cut before this change.** It still verifies (D2). Its stray
  `site/` is inert.
