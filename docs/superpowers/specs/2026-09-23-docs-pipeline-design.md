# Docs pipeline: the analyst wiki gets its own `full`

Date: 2026-09-23 · Status: approved design, not yet implemented

## Goal

Promote the analyst wiki build from a step of the optional front door
(`r770-portal-deploy.sh docs`) to its own independent pipeline,
`scripts/r770-docs-deploy.sh`, with the same shape as the Malcolm and GNS3
pipelines: its own bundle-in prep, its own `full`, re-enterable with
`--from/--to/--only`. The portal becomes purely the front door (CA, cert,
htpasswd, vhosts); it keeps *serving* `docs.lab`, while *building and
publishing* the site moves to the docs pipeline.

## Non-goals

- Extracting a shared `cmd_full` driver into `scripts/lib/common.sh` (possible
  follow-up; this work adds a third near-copy of GNS3's `cmd_full`).
- Renaming `docker/monitoring-images.tar.gz` / `docker/monitoring-image-list.txt`.
  The bundle verifier hardcodes those names; renaming is a staging change.
- Serving the wiki without the portal (no standalone web server).
- Any change to `r770-validate.sh` (it already probes `docs.lab` via its SANs),
  `r770-import-bundle.sh`, `common.sh`, `staging/` or `config/docs/mkdocs.yml`.

## Components

### New: `scripts/r770-docs-deploy.sh`

Modelled step for step on `scripts/r770-gns3-deploy.sh`.

```
r770-docs-deploy.sh <subcommand> [--bundle <dir>] [options]

  load         docker load docker/monitoring-images.tar.gz, then assert every
               tag in docker/monitoring-image-list.txt (skipped when all are
               present; --force to redo)
  assert-tags  the tag check alone
  build        mkdocs build of the wiki with the bundled image, --network none,
               published atomically to /srv/www/docs
  status       image present?, /srv/www/docs page count and mtime, docs.lab
               vhost enabled? (read-only; when the vhost is absent it says to
               serve the site with r770-portal-deploy.sh)
  full         preflight gate copy apt phone-home docker files load build

  --bundle/--media/--device/--from/--to/--only   exactly as in gns3/malcolm
  --wiki <dir>   wiki source (default: the kit's docs/wiki)
  --yes / --non-interactive / --dry-run / --force   as everywhere in the kit

  0 done · 2 done with warnings · 1 refused or failed
```

- `STEPS=(preflight gate copy apt phone-home docker files load build)`.
- The first seven steps call `r770-import-bundle.sh` through an
  `IMPORT_BUNDLE_CMD` test seam, exactly as GNS3 does. `local_bundle()` and
  the pre-loop `BUNDLE="$(local_bundle)"` resume-path resolution are carried
  over unchanged.
- No gate of its own. Its gated steps are the shared `apt`, `phone-home`,
  `docker` via import-bundle. `build` replaces only a kit-owned directory and
  stays ungated, as `docs` is today.
- `kit_init "r770-docs-deploy"`: transcripts land as
  `r770-evidence/r770-docs-deploy-<host>-<ts>.log`.

### Changed: `scripts/r770-portal-deploy.sh`

- Remove `cmd_docs`, the `docs` subcommand, the `--wiki` and `--bundle`
  options, the `BUNDLE`/`WIKI` variables and their header lines. After this,
  nothing in the portal reads a bundle; `docs` and `--bundle` are rejected as
  unknown. No forwarding shim (precedent: `r770-deploy.sh` was deleted
  outright).
- Keep the `docs.lab` vhost, the `docs.lab` SAN and the post-reload probe.
  Before the site is built, the probe receives 401 from basic auth, which
  already passes, so `nginx` does not depend on the docs pipeline having run.
- Header text: replace "the analyst wiki built offline" with a pointer to
  `r770-docs-deploy.sh`.

## Data flow and error handling

### `load`

1. `docker` absent → `die`, pointing at `r770-import-bundle.sh docker`.
2. Without `--force`, if `assert_image_tags docker/monitoring-image-list.txt`
   already passes → print "every tag already present — load skipped" and
   return 0, so a second `full` is a no-op.
3. Tarball missing or empty → `die`. Otherwise `run docker load -i`, then
   (not in dry-run) `assert_image_tags`; a missing tag → `die`.

This replaces today's `docker image ls | grep` pre-check, which looked only
for mkdocs-material and could miss an incomplete load.

### `build`

1. `need_root`. Wiki = `--wiki` or the kit's `docs/wiki`; no `index.md` →
   `die`. `img=$(image_ref_from_list … mkdocs-material)` refuses on zero or
   two-plus matches.
2. Stage into `mktemp -d`: copy the wiki to `docs/`, install
   `config/docs/mkdocs.yml`, `docker run --rm --network none -v <tmp>:/docs
   <img> build`. A failed build cleans the temp dir and `die`s.
3. No `site/index.html` → clean up and `die`.
4. **Atomic publish** (fixes today's `rm -rf` then `cp`, which leaves
   `docs.lab` empty if the copy fails):
   1. remove any stale `/srv/www/docs.new` and `/srv/www/docs.prev` left by an
      interrupted run;
   2. copy the built site to `/srv/www/docs.new`;
   3. if `/srv/www/docs` exists, rename it to `/srv/www/docs.prev`;
   4. rename `/srv/www/docs.new` to `/srv/www/docs`;
   5. remove `/srv/www/docs.prev`.

   Any failure before step 4 leaves the previous site live and untouched.
5. `pass "wiki built into /srv/www/docs (N pages)"`, `footer "build"`.
6. `--dry-run` prints every command and writes nothing under `/srv/www`.

### `full`

Same control flow as GNS3's `cmd_full`: `--bundle` required; `step_index`
slices; `run_step` per step; stop at the first refusal; `WARNED_STEPS` →
exit 2 with "DEPLOYED WITH WARNINGS"; otherwise exit 0. `--from build` is the
routine "rebuild just the wiki" re-entry once `copy` has landed the bundle
under `/srv/bundles`.

## Testing

### New: `tests/docs-deploy.bats`

Same stubs (`tests/helpers/stubs.bash`) and fixture
(`tests/helpers/fixtures.bash`, which already ships `docker/monitoring-*`) as
`tests/gns3-deploy.bats`. Cases:

- `assert-tags` passes with every tag present; fails naming a missing one.
- `load` runs `docker load` then asserts tags; skips when all present;
  refuses without docker.
- `build` runs `--network none` and publishes `/srv/www/docs/index.html`;
  refuses a list without mkdocs-material; refuses a list with two matches;
  refuses a `--wiki` dir without `index.md`; `--dry-run` writes nothing under
  `/srv/www`.
- Atomic publish: a failing build leaves an existing `/srv/www/docs`
  byte-identical; stale `docs.new`/`docs.prev` are cleared; a successful run
  leaves neither behind.
- `full` runs its steps in order with the shared prefix routed to
  `IMPORT_BUNDLE_CMD`; `--media`/`--device` go to `gate` only and `--media`
  alone to `copy`; `--only` and `--from/--to` slice; reversed or unknown steps
  are refused naming them; a warned step finishes with exit 2.

### Changed tests

- `tests/portal-deploy.bats`: the two `docs` tests move to the new suite;
  add one asserting `docs` and `--bundle` are rejected as unknown.
- `tests/references.bats`: the full-step resolution test adds
  `scripts/r770-docs-deploy.sh` to its loop and is renamed
  "every full step of every pipeline resolves to a subcommand that exists".
- `tests/README.md`: row for `docs-deploy.bats`; drop "offline docs build"
  from the portal row.

Gate: `./tests/run.sh` green, shellcheck with no exclusions.

## Docs and settings

- `README.md`: script-table row for the new script; the command block's
  `r770-portal-deploy.sh docs --bundle …` becomes `r770-docs-deploy.sh full …`
  (and `--from build` for a rebuild); the portal row drops the wiki.
- `docs/CODEMAPS/stages.md`: a Docs pipeline row; `docs` removed from the
  portal rows; `config/docs/mkdocs.yml` owned by `docs-deploy build`.
- `docs/CODEMAPS/architecture.md`: two pipelines → three.
- `docs/deployment-runbook.md`: the wiki section points at the new script.
- `CLAUDE.md`: command block and architecture text updated for three
  pipelines. Its "an `ask` entry in `.claude/settings.json`" wording is
  corrected to match practice: every `r770-*` script sits in `allow` and
  `ask` is empty.
- `.claude/settings.json`: add `Bash(./scripts/r770-docs-deploy.sh:*)` to
  `allow` beside its siblings.
