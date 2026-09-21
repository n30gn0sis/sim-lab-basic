# tests/

One command: `./tests/run.sh`. shellcheck over every script with **no
exclusions** (the one carried file `staging/r770-offline-fetch.sh` keeps the
exclusion list the build repo accepted for it; nothing else may use one), then
every bats suite. Everything is offline and read-only —
every host tool is a stub in a replacement PATH, every write lands in a fake
root under `KIT_ROOT`, every version is `0.0.0-fixture`. Never a real bundle,
never a daemon, never the R770.

Requires `shellcheck` and `bats` (>= 1.10): `sudo apt-get -y install shellcheck bats`.

## Suites

| Suite | Covers |
|---|---|
| `lint.bats` | shellcheck (no exclusions; the carried fetch script with its accepted list) and `bash -n` over every script and helper; scripts executable |
| `staging.bats` | `staging/` is byte-identical to its provenance record; the four scripts run as a set from here (`--help`, `--pack`, a manifest/verify round-trip); the pack output is gitignored |
| `common.bats` | the library's contract: `KIT_ROOT`, dry-run, gates, `render`, `assert_edit`, image lists, `bundle_verify` calling the bundle's own verifier, secrets |
| `import-bundle.bats` | gate on the bundle's verifier, refusals, the APT rewrite and its automatic restore, docker assertions, the incomplete-load regression, file routing |
| `malcolm-deploy.bats` | the seven cases ported from the build repo, plus flag assertion, rendered-config replay, the rebind's idempotence and drift refusal, secrets never printed, start via Malcolm's script |
| `gns3-deploy.bats` | `python3-venv` refusal, `--no-index`, pip-index refusal, the chown of the state dir, the unit gate, loopback assertion |
| `portal-deploy.bats` | the SAN list, file modes, `nginx -t` before reload, gate, probe verdicts, offline docs build |
| `airgap-check.bats` | every false-pass the posture check must not produce; SKIP vs FAIL |
| `validate.bats` | one row per check, SKIP with reason, FAIL diagnosis, arguments-not-facts, interfaces never guessed, indexing lag as WARN |
| `config.bats` | the carried config stays deployable as measured: http2 form, no staging leftovers, only tokens the kit renders (documented in `config/README.md`), the GNS3 template carries no `jwt_secret_key`, the Malcolm template pins storage and disables what an air gap cannot do |
| `no-pins.bats` | no version pin anywhere outside its one owner, `staging/r770-offline-fetch.sh` |
| `no-credentials.bats` | `.gitignore` covers evidence, secrets and bundles; no credential-shaped string tracked |
| `no-legacy-manifest.bats` | no checksum gate of the kit's own; the bundle's verifier referenced by name and invoked from the library; `r770-bundle.sh` exists only under `staging/`, and `scripts/` never reaches for it |
| `no-internet.bats` | no external URL in scripts or config; `pip` always `--no-index`; `docker run` always `--network none` |
| `references.bats` | every kit path named in the docs exists; every `config/` file is installed by some script; every runner stage resolves |

## The stub pattern

`tests/helpers/stubs.bash` — `kit_test_env` builds `$BIN` (stubs) and `$REAL`
(an explicit allowlist of harmless real tools, symlinked), and `kit_run`
executes the script under `PATH=$BIN:$REAL`. Inheriting the runner's PATH
would let a real `docker`, `apt-get` or `systemctl` on GitHub's ubuntu-latest
answer for the host under test — the leak the pattern exists to catch. `stub
<name> <body>` writes a stub; `stub_log <name> [rc]` writes one that records
its argv to `$STUB_LOG`.

`tests/helpers/fixtures.bash` — `make_bundle` (the fetch script's directory
shape with byte-sized payloads and a stub verifier in the root),
`stage_manual`, `make_root` (the fake `/etc /srv /opt /data /var` tree),
`make_malcolm_tree` (an unpacked installer and stack with stub
`install.py`, `auth_setup`, `start`, `stop`).

## Gotchas

- A comment beginning `# shellcheck ` is parsed as a directive, not prose.
- Ownership changes are always stubbed (the suite does not run as root in
  CI); the assertions are on the recorded argv, which is the honest limit.
- `run` in bats swallows a hung process only if you add `timeout`; the
  scripts' poll loops take their step from the `*_WAIT_SECS` seams, which the
  suites set to 1.
