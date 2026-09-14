# CLAUDE.md — sim-lab-basic (R770 offline deployment kit)

You are working in the deployment kit for an air-gapped Ubuntu 24.04
network-lab server. `scripts/` is the **R770 side**: it takes a finished
bundle onto the box and stands the services up. `staging/` is the **staging
side**: the build repo's bundle pipeline, carried byte for byte, run only on
the internet-connected staging host. The design, the hardware inventory and
the phase tracker live in the build repo (`simlab-build`). Read `README.md`
and `docs/deployment-runbook.md` before doing anything.

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
