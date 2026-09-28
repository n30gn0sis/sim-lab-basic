# staging/ — the bundle-building side, carried verbatim

These four scripts are the build repo's supply pipeline, copied byte for byte
from `simlab-build/scripts/` (commit and hashes in `PROVENANCE.txt`, checked
by `tests/staging.bats`). They run on the **internet-connected staging host**
and **never on the R770**. Nothing under the kit's `scripts/` calls them.

| Script | Role |
|---|---|
| `r770-staging-preflight.sh` | may THIS host build a bundle? (Ubuntu 24.04 + Docker CE, or RHEL 8 + rootful podman; never LXC; room; egress) |
| `r770-offline-fetch.sh` | the download — **the one owner of every version pin** (its `# ── pins:` block); resumable, proxy-aware, seeds from a previous bundle |
| `r770-build-bundle.sh` | one command, one verified bundle: preflight → fetch → pause for the manual items → manifest → `verify --strict` |
| `r770-bundle.sh` | manifest generation and integrity verification; the fetch copies it **into the bundle root**, and that copy is what the R770 side runs |

## Use

```bash
SITE_SRC_ROOT=<simlab-build checkout> ./staging/r770-build-bundle.sh      # here, on the staging host
BUILD_PACK_ROOT=<simlab-build checkout> ./staging/r770-build-bundle.sh --pack > r770-bundle-builder.sh
```

Since the 2026-09-27 resync the fetch has a `site` stage that ships the
**build repo's** reviewed `simlab-build/scripts/`, `simlab-build/config/` and `simlab-build/docs/analyst-wiki/` as
the bundle's `site/`, and the verifier expects it. It reads them from a
simlab-build git checkout: from this kit's tree it refuses at startup, even
for `--list` and `--dry-run`, rather than guess — so point `SITE_SRC_ROOT`
(and, for `--pack`, `BUILD_PACK_ROOT`) at a clean simlab-build checkout.
`--pack` embeds that checkout's exact commit, and refuses this kit's tree.

Exit **0** bundle built and gated clean · **2** built with warnings to
disposition · **1** failed — do not move the media. The manual category
(licensed GNS3 appliances) is added by hand at the pause; the manifest is
regenerated **after** it so it can see it. Dell firmware is not a bundle item.

The packed builder is gitignored: its base64 payload would hide the pin block
from the guard that keeps pins in one place.

## Changing them

Don't, here. Edit in the build repo (its suite tests them), then resync per
`docs/kit-sync.md` and regenerate `PROVENANCE.txt`. The kit's guards treat
`r770-offline-fetch.sh` as the pin owner and `r770-bundle.sh` as the verifier
that may exist only in this directory; every other rule of the kit applies.

For the runbook that drives these — the staging host set-up, the proxy notes,
the pin review before a cut — see the build repo's
`simlab-build/docs/plans/r770-staging-runbook.md`.
