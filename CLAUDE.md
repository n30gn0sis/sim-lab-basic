# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

The deployment kit for an air-gapped Ubuntu 24.04 network-lab server (a Dell
PowerEdge R770). `scripts/` is the **R770 side**: it takes a finished bundle
onto the box and stands the services up. `staging/` is the **staging side**:
the build repo's bundle pipeline, carried byte for byte, run only on the
internet-connected staging host. The design, the hardware inventory and the
phase tracker live in the build repo (`simlab-build`). Read `README.md` and
`docs/deployment-runbook.md` before doing anything.

## Commands

Everything here is bash + bats; there is no compiled build step. All of it is
offline and read-only — no suite touches a real bundle, a real daemon, or the
R770.

```bash
sudo apt-get install -y shellcheck bats   # once, on any Linux box (not the R770)

./tests/run.sh                            # the whole gate: shellcheck + every tests/*.bats suite
bats tests/common.bats                    # one suite
bats tests/common.bats --filter '<name>'  # one test within a suite (bats-core >= 1.10)
shellcheck scripts/*.sh scripts/lib/common.sh staging/*.sh   # lint alone, no exclusions
                                           # (except the one carried file, staging/r770-offline-fetch.sh)
```

Running the kit itself requires root and real (or `KIT_ROOT`-faked) hardware —
it is not something to invoke casually in this repo:

```bash
sudo ./scripts/r770-malcolm-deploy.sh full \
    --bundle <dir> --media <mnt> --device /dev/<discovered> --dry-run # Malcolm's whole pipeline, print every command, run nothing
sudo ./scripts/r770-gns3-deploy.sh full \
    --bundle <dir> --media <mnt> --device /dev/<discovered> --dry-run # GNS3's whole pipeline, same contract, independent of Malcolm's
sudo ./scripts/r770-portal-deploy.sh nginx --dry-run          # the optional front door, one step at a time, run after Malcolm is up
./staging/r770-build-bundle.sh --dry-run                     # same, staging side
```

## Architecture

- **Two hosts, enforced.** `staging/` (preflight → fetch → build → verify) is
  the build repo's pipeline copied byte for byte — identity guarded by
  `staging/PROVENANCE.txt` and `tests/staging.bats`, never edited here.
  `scripts/` is the R770 side: two independent pipelines plus an optional
  front door. `tests/no-legacy-manifest.bats` and friends prove `scripts/`
  never reaches into `staging/`.
- **Two independent pipelines, no orchestrator.** There is no
  `r770-deploy.sh` any more — it was deleted once each service could stand
  up its own pipeline. `scripts/r770-malcolm-deploy.sh full` and
  `scripts/r770-gns3-deploy.sh full` each run their own bundle-in prep
  (preflight, gate, copy, apt, phone-home, docker, files — the shared logic
  lives in `scripts/r770-import-bundle.sh`, sourced as a library, not called
  as a stage) before their own service-specific steps; run either pipeline
  first, or both back to back — the shared prep steps are idempotent, so the
  second `full` just reports "already done". The optional front door,
  `scripts/r770-portal-deploy.sh` (`ca cert htpasswd nginx docs`), is a
  separate, explicit sequence run after Malcolm is up; it is not part of
  either `full`.
- **`scripts/lib/common.sh` is the one seam every script sources.** It owns:
  `KIT_ROOT`/`KIT_DRY_RUN`/`KIT_YES`/`KIT_NON_INTERACTIVE`/`KIT_EVIDENCE_DIR`
  (what makes every script dry-runnable and testable against a fake root);
  `gate()` (prints current/proposed/rollback, the mechanism behind every
  "GATED" change); `bundle_verify()` (shells out to the verifier that travels
  *inside* the bundle — the kit ships none of its own); `assert_image_tags()`
  (catches `docker load` reporting success on a tag set that's actually
  incomplete); `render()` (token substitution that refuses to write if any
  `__TOKEN__` survives); `secret_file()` (generate-once, print the path
  never the value); `stamp()`/`stamped()` (idempotency markers under
  `/srv/bundles/.kit-stamps`); `run_step()`/`step_index()` (what each
  pipeline's own `full` uses to slice its step sequence for
  `--from/--to/--only` and to re-enter after a failure — the same job the
  retired `r770-deploy.sh`'s `child()`/`stage_index()` did before each
  pipeline carried its own).
- **A "bundle" is a contract, not a convention.** `bundle_dir()` only accepts
  a directory that has `r770-bundle.sh`, `BUNDLE_NOTES.md` and
  `MANIFEST.sha256` at its root. Version pins are never restated: they live
  once in `staging/r770-offline-fetch.sh`'s pin block, and everything
  downstream reads them back out of what the bundle itself carries
  (`*/image-list.txt`, filenames, `BUNDLE_NOTES.md`) — enforced by
  `tests/no-pins.bats`.
- **`config/` holds templates, not config.** Files are carried from the build
  repo with deltas tracked in `config/README.md`; each `__TOKEN__` is
  rendered by exactly one script from exactly one source (also tabulated
  there), and `render()` refuses a partial substitution rather than ship one.
- **Evidence and vocabulary are uniform across the kit.** `kit_init()` tees
  every script's transcript to `r770-evidence/<script>-<host>-<ts>.log`;
  every check line is `PASS`/`WARN`/`FAIL`/`SKIP`, and `footer()` turns the
  tally into the same 0/2/1 exit every stage and every runner uses.
- **Tests never see the real host.** `tests/helpers/stubs.bash` builds a
  synthetic `PATH` (`kit_test_env`/`kit_run`) so a script under test can
  never reach CI's real `docker`/`apt-get`/`systemctl`, and every write goes
  through `KIT_ROOT` into a fake root tree built by `tests/helpers/fixtures.bash`.

## Run context

- **The R770 has no internet, ever.** Never `apt install` from upstream, `pip
  install`, `docker pull`, `curl` or `wget` anything outside `127.0.0.1` or a
  `.lab` name. Software reaches the box only through the bundle; the kit's
  scripts are the only sanctioned way to install it.
- **Two directories, two hosts.** `staging/` never runs on the R770 and
  `scripts/` never calls `staging/` (a test proves it). Cutting a bundle is
  `./staging/r770-build-bundle.sh` on the staging host, gated by its own
  preflight. Check which box you are on before assuming either.
- **Run the kit's scripts, not hand-typed commands.** Each subcommand encodes a
  trap the staging rehearsal hit. If a script refuses, the refusal is the
  finding — fix the cause, don't route around the script.
- The build repo's phase tracker (`state/BUILD-STATE.md` there) decides what
  may be deployed. Stages that need an unbuilt phase must SKIP or refuse, never
  guess.

## Non-negotiable rules

1. **Discover, never guess.** Block devices, interfaces, bridges and addresses
   are arguments (`--device`, `--mgmt-ip`, `--capture-ifs`, `--lab-bridge`) that
   the operator supplies from discovery output. No script picks one, and no
   placeholder like `/dev/sdX` or `eno1` is ever executed.
2. **Gated changes.** APT sources, phone-home services, Docker install, the
   nginx site set, the GNS3 unit and a volume purge each print *current ·
   proposed · rollback* and need `--yes` or a `y`. `--non-interactive` without
   `--yes` stops at the gate. Never bypass a gate to make a run "go".
3. **The verifier is the bundle's** (`<bundle>/r770-bundle.sh verify`). Never
   add a checksum routine to this kit, never gate on a raw checksum command.
4. **One pin owner.** `staging/r770-offline-fetch.sh` holds the pin block and
   is edited only in the build repo, then resynced. Nothing else restates a
   version: tags come from the bundle's image lists, filenames by glob,
   config values by token. `tests/no-pins.bats` enforces it; do not weaken it.
5. **No secrets in git.** Credentials are generated once under
   `/etc/lab/secrets/` and printed never. Evidence directories are gitignored.
6. **Never fabricate results.** A stage is done when its transcript under
   `r770-evidence/` shows it; `r770-validate.sh` writes SKIP with a reason for
   anything it could not prove.
7. **One change at a time** when something fails: reproduce, read the
   transcript, one hypothesis, one controlled change, rerun `--from <stage>`.
8. Capture ports never get an IP and are never bridged to the lab fabric.
   `r770-validate.sh --area network --capture-ifs ...` fails on either.

## Working on the kit itself

- `./tests/run.sh` must be green before any commit: shellcheck with **no
  exclusions**, and every suite under `tests/` (stubbed PATH, fake root under
  `KIT_ROOT`, synthetic `0.0.0-fixture` versions only).
- A new script gets: the `KIT_*` seams via `scripts/lib/common.sh`, the
  `0 / 2 / 1` exit contract, `PASS  / WARN  / FAIL  / SKIP  ` vocabulary, a
  bats suite, a row in `README.md`, and an `ask` entry in `.claude/settings.json`.
- Config changes go through `config/README.md`'s delta table and
  `docs/kit-sync.md`; the build repo remains the source those files are synced
  from. The four files under `staging/` are never edited here: change them in
  the build repo, resync, and regenerate `staging/PROVENANCE.txt`
  (`tests/staging.bats` fails on a local edit).
- Cite repo files as backticked bare paths; `tests/references.bats` checks
  that every kit path named in the docs exists.

When docs and a transcript disagree, the transcript wins — then fix the docs.
