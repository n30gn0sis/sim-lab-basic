<!-- Generated: 2026-09-21 | Files scanned: 8 scripts, 20 config files | Token estimate: ~800 -->

# Pipelines → scripts → subcommands

There is no outer orchestrator. `r770-malcolm-deploy.sh full` and
`r770-gns3-deploy.sh full` are two independent entry points, each printed by
that script's own `--help`. Each steps through its own `STEPS=(...)` array in
order, stopping at the first refusal; `--from/--to/--only` slice it. 🔒 =
gated (prints current · proposed · rollback, needs `--yes` or a `y`).

| Pipeline | Script | `full` step sequence | Operator-invoked extras |
|---|---|---|---|
| Malcolm | `scripts/r770-malcolm-deploy.sh` | `preflight` `gate` `copy` `apt` 🔒 `phone-home` 🔒 `docker` 🔒 `files` `load` `unpack` `configure` `secrets` `auth` `rebind` `start` | `assert-tags`, `stop`, `status`, `inventory`, `dashboards`, `arkime-views` |
| GNS3 | `scripts/r770-gns3-deploy.sh` | `preflight` `gate` `copy` `apt` 🔒 `phone-home` 🔒 `docker` 🔒 `files` `load` `venv` `secrets` `config` `service` 🔒 | `assert-tags`, `status` |
| Front door | `scripts/r770-portal-deploy.sh` | none — never part of a `full`; run by hand as `ca` `cert` `htpasswd` `nginx` 🔒 `docs`, in that order, after Malcolm's `auth` step | `status`, `--print-sans` |

The first seven steps of each `full` (`preflight` through `files`) call
`scripts/r770-import-bundle.sh`'s own subcommands of the same names — every
one idempotent, so running both pipelines on the same box costs nothing extra
beyond a second bundle re-verification at `gate`. From `load` on, each script
runs its own commands; `r770-import-bundle.sh` has no `load`/`images`
subcommand of its own — Malcolm and GNS3 each load and tag-assert their own
tarball.

Required arguments: `--bundle <dir>` always for `full`; `--media`/`--device`
for its `gate`/`copy` steps.

## Subcommands NOT in either `full`

Each script has more than `full` calls. These are operator-invoked:

| Script | Extra | Why it is not automatic |
|---|---|---|
| import-bundle | `status` | read-only |
| malcolm | `assert-tags` | the tag check alone |
| malcolm | `stop` `status` | lifecycle / read-only |
| malcolm | `inventory` | read-only; what Dashboards holds now |
| malcolm | `dashboards` `arkime-views` | need a started stack; a failed dashboard import must not fail a deployment that stood every service up |
| gns3 | `assert-tags` `status` | the tag check alone / read-only |
| portal | `ca` `cert` `htpasswd` `nginx` `docs` | the whole front door is optional and hand-run — see above |
| portal | `status`, `--print-sans` | read-only |

## The gates

`apt` (sources rewrite) · `phone-home` (timers, snapd) · `docker` (engine
install) · `gns3 service` (the unit) · `portal nginx` (the site set).
`--non-interactive` without `--yes` stops at the first one, on purpose.

## Config each pipeline installs

Config files are templates; `config/README.md` owns the token table and the
deltas from the build repo. Renderer → destination:

| Config | Installed by |
|---|---|
| `config/gns3/gns3_server.conf.template`, `config/systemd/gns3.service` | `gns3-deploy config` / `service` |
| `config/malcolm/malcolm-config.json.template` | `malcolm-deploy configure` |
| `config/malcolm/dashboards/*.ndjson.template` | `malcolm-deploy dashboards` |
| `config/malcolm/arkime-views/*.views` | `malcolm-deploy arkime-views` |
| `config/nginx/*.lab.conf`, `config/nginx/snippets/*` | `portal-deploy nginx` |
| `config/docs/mkdocs.yml` | `portal-deploy docs` |

`tests/references.bats` fails if a `config/` file no script installs.

## Secrets

Generated once on the box, mode 0600 in a 0700 directory, value never printed:
`/etc/lab/secrets/gns3-admin.pw`, `malcolm-admin.pw`, `restic.pw`. Locations
and modes are documented in `docs/secrets-locations.md`.

## Validation areas

`host cpu-ram storage network virtualization gns3 wan capture backup airgap
portal` — all by default, `--area` to select. Hardware expectations and
interfaces are **arguments** (`--expect-threads`, `--expect-ram-gb`,
`--mgmt-if`, `--capture-ifs`, `--mgmt-cidr`), never discovered by guessing. A
check that cannot run is `SKIP` with its reason and does not change the exit
code. See `docs/validation.md`.
