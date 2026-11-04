# staging/ — the bundle-building side

These four scripts are the kit's supply pipeline. They run on the
**internet-connected staging host** and **never on the R770**. Nothing under
the kit's `scripts/` calls them (`tests/no-legacy-manifest.bats`).

| Script | Role |
|---|---|
| `r770-staging-preflight.sh` | may THIS host build a bundle? (Ubuntu 24.04 + Docker CE, or RHEL 8 + rootful podman; never LXC; room; egress) |
| `r770-offline-fetch.sh` | the download — **the one owner of every version pin** (its `# ── pins:` block); resumable, proxy-aware, seeds from a previous bundle |
| `r770-build-bundle.sh` | one command, one verified bundle: preflight → fetch → pause for the manual items → manifest → `verify --strict` |
| `r770-bundle.sh` | manifest generation and integrity verification; the fetch copies it **into the bundle root**, and that copy is what the R770 side runs (`<bundle>/r770-bundle.sh verify`) |

## Use

```bash
KIT_SRC_ROOT=<this kit's checkout> ./staging/r770-build-bundle.sh                      # here, on the staging host
KIT_SRC_ROOT=<this kit's checkout> ./staging/r770-build-bundle.sh --pack > r770-bundle-builder.sh
```

The fetch's `kit` stage ships this repo's committed `scripts/`, `config/`,
`scenarios/` and `docs/` as the bundle's `kit/`, which the verifier requires.
`KIT_SRC_ROOT` names the checkout to ship; a real run refuses without it rather
than guess, and refuses a tracked symlink or submodule. `--pack` embeds that
checkout's exact commit as `kit.tar` and refuses a dirty tree.

Exit **0** bundle built and gated clean · **2** built with warnings to
disposition · **1** failed — do not move the media. The manual category
(licensed GNS3 appliances) is added by hand at the pause; the manifest is
regenerated **after** it so it can see it. Dell firmware is not a bundle item.

The packed builder is gitignored: its base64 payload would hide the pin block
from the guard that keeps pins in one place.

## Changing them

Edit them here, like any kit script: shellcheck with no exclusions, and
`tests/staging.bats` for behaviour. Two roles are guarded:
`r770-offline-fetch.sh` is the pin owner (`tests/no-pins.bats`), and
`r770-bundle.sh` is the verifier, which may exist only in this directory
(`tests/no-legacy-manifest.bats`). A pin moves in the fetch's pin block and
nowhere else.
