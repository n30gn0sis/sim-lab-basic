# Standalone Kit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut every tie between this kit and the build repo, so that `staging/`
is the kit's own code and a bundle is cut from a checkout of this repo alone.

**Architecture:** Remove the fetch's `site` and `labimages` stages and the
verifier's checks for them. Simplify `--pack` to the four staging scripts plus
the kit. Make `staging/` lint-clean so it needs no exclusion. Retire the
provenance guard. Replace the build repo's phase numbers with the prerequisite
each check actually needs. Rewrite the live docs as owned here.

**Spec:** `docs/superpowers/specs/2026-10-29-standalone-kit-design.md` (D1–D4),
plus one approved addition: build-repo phase numbers ("Phase 7 not built")
leave script output and docs too (Task 7).

**Tech Stack:** bash, bats-core 1.10, shellcheck 0.9 (no exclusions), one
Python 3 helper (`tests/helpers/lint_scenarios.py`).

## Global Constraints

- `./tests/run.sh` is green at the end of every task (baseline at plan time: 458 tests, all `ok`).
- shellcheck at default severity with **no exclusions** on every script, `staging/` included, from Task 3 on.
- No three-part version number anywhere outside `staging/r770-offline-fetch.sh` (`tests/no-pins.bats`). This includes plan text, comments and test names.
- No raw checksum-check recipe (the `sha256sum` check-mode flag) under `scripts/`, `docs/`, `config/`, `README.md` or `CLAUDE.md` (`tests/no-legacy-manifest.bats`). This plan therefore describes the fetch's checksum lines structurally instead of quoting them.
- Check-line vocabulary: `PASS  ` / `WARN  ` / `FAIL  ` / `SKIP  `. Exit contract: `0` / `2` / `1`.
- Leave the dated files under `docs/superpowers/` unedited (D4), except this plan and its spec.
- Cite repo files as backticked bare paths. `tests/references.bats` checks that every path named in `README.md`, `CLAUDE.md`, `docs/*.md`, `config/README.md`, `tests/README.md` and `staging/README.md` exists.
- One commit per task. End each commit message with the session's attribution lines.

## File map

| File | Change | Task |
|---|---|---|
| `staging/r770-bundle.sh` | drop `check_site`, `check_lab_images`, the lab-images pair | 1 |
| `staging/r770-offline-fetch.sh` | drop `site` and `labimages` stages, rename the shared helpers, renumber, fix header and closing text | 2 |
| `staging/r770-offline-fetch.sh` | fix 6 × SC2012 and 8 × SC2015 | 3 |
| `staging/r770-build-bundle.sh` | `--pack` carries the four scripts plus the kit only; closing messages | 4 |
| `staging/PROVENANCE.txt` | delete | 5 |
| `staging/README.md` | rewrite | 5 |
| `tests/staging.bats` | rewrite around behaviour, not hashes | 1, 2, 4, 5 |
| `tests/lint.bats` | drop `LEGACY_EXCLUDE` | 3 |
| `tests/no-pins.bats` | drop the `PROVENANCE.txt` exclusion; header | 5 |
| `tests/helpers/lint_scenarios.py` | resolve every `$VAR` image; drop `UPSTREAM_PENDING` | 6 |
| `tests/scenarios.bats` | one new test | 6 |
| `scripts/r770-validate.sh`, `scripts/r770-airgap-check.sh`, `scripts/r770-import-bundle.sh`, `scripts/r770-malcolm-deploy.sh` | SKIP reasons, diagnoses and comments name prerequisites, not phases or the build repo | 7 |
| `tests/validate.bats`, `tests/airgap-check.bats` | expectations follow Task 7's wording | 7 |
| `docs/kit-sync.md` | delete | 8 |
| `README.md`, `CLAUDE.md`, `tests/no-legacy-manifest.bats` | rewrite build-repo passages | 8 |
| `config/README.md`, `docs/deployment-runbook.md`, `docs/validation.md`, `docs/rollback.md`, `docs/secrets-locations.md`, `docs/CODEMAPS/*.md`, `tests/README.md`, `.gitignore`, test comments | rewrite build-repo passages | 9 |

---

### Task 1: The verifier stops checking `site/` and the lab images

**Files:**
- Modify: `staging/r770-bundle.sh` (the block from `# site/ carries this repo's reviewed` through the end of `check_lab_images()`; the `check_required` pair list; the `check_kit` comment; `cmd_verify`)
- Test: `tests/staging.bats`

**Interfaces:**
- Consumes: `make_bundle`, `stage_manual` from `tests/helpers/fixtures.bash`; `KIT_REQUIRED_FILES=(…)` from `staging/r770-bundle.sh` (unchanged).
- Produces: `real_bundle <dir>` in `tests/staging.bats`, a fixture bundle as the fetch now leaves it. Tasks 2 and 4 don't use it.

- [ ] **Step 1: Write the failing tests.** In `tests/staging.bats`, replace the whole test `@test "the carried verifier still round-trips a fixture bundle: manifest, then verify PASS" { … }` with:

```bash
# a fixture bundle as the fetch leaves it: the real verifier in the root and
# kit/ carrying what the verifier requires. There is no site/: the fetch no
# longer has that stage.
real_bundle() {
    local B="$1" f
    make_bundle "$B"; stage_manual "$B"
    rm "$B/r770-bundle.sh" "$B/MANIFEST.sha256"          # the fixture's stub verifier and fake manifest
    cp staging/r770-bundle.sh "$B/"                       # what the fetch does: the verifier travels in the root
    for f in $(sed -n 's/^KIT_REQUIRED_FILES=(\(.*\))$/\1/p' staging/r770-bundle.sh); do
        mkdir -p "$B/kit/$(dirname "$f")"; echo '#!/bin/sh' > "$B/kit/$f"
    done
    [ -s "$B/kit/scripts/r770-install.sh" ]
}

@test "the verifier round-trips a bundle with kit/ and no site/: manifest, then verify --strict PASS" {
    B="$BATS_TEST_TMPDIR/bundle-fixture"
    real_bundle "$B"
    run ./staging/r770-bundle.sh manifest "$B"
    echo "$output"
    [ "$status" -eq 0 ]
    run ./staging/r770-bundle.sh verify "$B" --strict
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: PASS"* ]]
    [[ "$output" != *"site/"* ]]
}

@test "an older bundle that still carries site/ verifies: nothing asks about it, the manifest covers it" {
    B="$BATS_TEST_TMPDIR/bundle-fixture"
    real_bundle "$B"
    mkdir -p "$B/site/scripts"; echo '#!/bin/sh' > "$B/site/scripts/anything.sh"
    run ./staging/r770-bundle.sh manifest "$B"
    [ "$status" -eq 0 ]
    run ./staging/r770-bundle.sh verify "$B" --strict
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: PASS"* ]]
}

@test "a bundle without kit/ still fails the strict gate" {
    B="$BATS_TEST_TMPDIR/bundle-fixture"
    real_bundle "$B"
    rm -rf "$B/kit"
    run ./staging/r770-bundle.sh manifest "$B"
    [ "$status" -eq 0 ]
    run ./staging/r770-bundle.sh verify "$B" --strict
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kit/ is missing"* ]]
}
```

- [ ] **Step 2: Run them and confirm the first two fail.**

Run: `bats tests/staging.bats --filter 'site/|without kit'`
Expected: the first two FAIL (`check_site` WARNs "site/ is missing" or "missing expected script(s)", and `--strict` turns that into exit 1). The third PASSes already; it is the regression guard.

- [ ] **Step 3: Remove the checks from `staging/r770-bundle.sh`.**
  1. Delete every line from `# site/ carries this repo's reviewed scripts/, config/ and docs/analyst-wiki/, so the` down to and including the closing `}` of `check_lab_images()`. That covers the comment block, `SITE_REQUIRED_SCRIPTS=…`, `SITE_REQUIRED_FILES=…`, `check_site()`, the lab-images comment, `LAB_IMAGES_REQUIRED=…` and `check_lab_images()`.
  2. Replace the comment above `KIT_REQUIRED_FILES` (it starts `# kit/ carries sim-lab-basic` and refers to `check_site above`) with:

```bash
# kit/ carries sim-lab-basic, the R770 installer (r770-offline-fetch.sh's
# stage_kit). Missing is a WARN here and a FAIL under --strict:
# r770-build-bundle.sh's gate (step 5/5) always runs `verify --strict`, so a
# real build stops on it, while a bundle cut before 2026-10 that legitimately
# has none can still be verified and its WARN dispositioned.
```

  3. In `check_required()`, delete the pair line `"gns3/docker-nodes/lab-images.list|gns3/docker-nodes/lab-images.tar.gz"`, and remove the trailing ` \` from the line above it so the list ends at the `gns3-node-images` pair:

```bash
    for pair in \
        "malcolm/image-list.txt|malcolm/malcolm-images-*.tar.gz" \
        "docker/monitoring-image-list.txt|docker/monitoring-images.tar.gz" \
        "gns3/docker-nodes/image-list.txt|gns3/docker-nodes/gns3-node-images.tar.gz"
    do
```

  4. In `cmd_verify`, delete the line `    check_site     "$dir"`.

- [ ] **Step 4: Run the suite and lint.**

Run: `bats tests/staging.bats && shellcheck staging/r770-bundle.sh && grep -c 'site' staging/r770-bundle.sh`
Expected: all `ok`; shellcheck silent; the grep prints `0`.

- [ ] **Step 5: Commit.**

```bash
git add staging/r770-bundle.sh tests/staging.bats
git commit -m "verifier: stop checking site/ and the lab images (nothing on the R770 reads them)"
```

---

### Task 2: The fetch loses its `site` and `labimages` stages

**Files:**
- Modify: `staging/r770-offline-fetch.sh`
- Test: `tests/staging.bats`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `STAGES=(preflight apt iso malcolm monitoring gns3 appliances enrichment docs manual kit manifest)`. The helpers `site_excluded`/`sitegit` become `tree_excluded`/`treegit`. `ship_trees` is unchanged. Task 3 lints this file.

- [ ] **Step 1: Write the failing tests.** Append to `tests/staging.bats`:

```bash
@test "the fetch's --list runs from this kit's tree and names no site or labimages stage" {
    BUNDLE_DIR="$BATS_TEST_TMPDIR/b" run ./staging/r770-offline-fetch.sh --list
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"  kit "* ]]
    [[ "$output" != *"site"* ]]
    [[ "$output" != *"labimages"* ]]
}

@test "the fetch's --dry-run plans no lab image build, and the old stage names are unknown" {
    BUNDLE_DIR="$BATS_TEST_TMPDIR/b" run ./staging/r770-offline-fetch.sh --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" != *"lab-images"* ]]
    for s in site labimages; do
        run ./staging/r770-offline-fetch.sh --only "$s" --dry-run
        [ "$status" -eq 1 ]
        [[ "$output" == *"unknown stage '$s'"* ]]
    done
}

@test "the fetch's help names no SITE_ variable" {
    run ./staging/r770-offline-fetch.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"SITE_"* ]]
}
```

- [ ] **Step 2: Run them and confirm they fail.**

Run: `bats tests/staging.bats --filter "fetch's"`
Expected: all three FAIL. `--list` exits 1 with `FATAL: SITE_SRC_ROOT (…) doesn't look like this repo`, because the site check runs at startup even for `--list`. `--only site` is accepted. The help prints `SITE_SRC_ROOT`.

- [ ] **Step 3: Edit `staging/r770-offline-fetch.sh`, top to bottom.**

  1. **Header.** Replace the block from `# [sim-lab-basic local divergence, NOT from simlab-build — reapplied at every` through `#   trim). Everything else in this file is simlab-build's, byte for byte.` with:

```bash
# Monitoring trim (2026-09-21): the kit deploys no Prometheus/Alertmanager/
#   blackbox-exporter/Grafana/cAdvisor, so MONITOR_IMAGES keeps only
#   mkdocs-material (the offline analyst wiki still needs it); the stock
#   nginx and docker-registry v2 images went with them. The array name and the
#   two output filenames (docker/monitoring-image-list.txt,
#   docker/monitoring-images.tar.gz) are deliberately NOT renamed -- see the
#   comment above MONITOR_IMAGES. seed() never reuses a prior bundle's
#   monitoring tarball (it may predate the trim).
```

  2. In the `# Earlier versions …: see \`git log --follow -p -- scripts/r770-offline-fetch.sh\`.` line, change that path's `scripts/` to `staging/`.
  3. Replace the three `# Companion docs:` lines with `# Companion docs: staging/README.md, docs/deployment-runbook.md`.
  4. Change `# Trimmed (sim-lab-basic local divergence, see header above): this kit no` to `# Trimmed (see the monitoring note in the header): this kit no`.
  5. `STAGES=(…)` becomes `STAGES=(preflight apt iso malcolm monitoring gns3 appliances enrichment docs manual kit manifest)`, and the stage list inside `usage()` becomes `  preflight apt iso malcolm monitoring gns3 appliances enrichment docs manual kit manifest`.
  6. In `usage()`, delete the line beginning `             SITE_SRC_ROOT=<dir>`.
  7. Delete from `# Same idea, for the "site" stage: confirm it has something real to ship from` through the line `want site && site_validate_source`, inclusive.
  8. In the kit comment that follows, change `# Unlike site/, it has NO default source: which kit checkout ships is a` to `# It has NO default source: which kit checkout ships is a`.
  9. Delete from `# Lab scenario images (stage_labimages, below; --dry-run prints its plan before any runtime exists)` through the closing `}` of `labimages_plan()`, inclusive.
  10. In `stage_marker()`, delete the `labimages)` line and the `site)` line, and change the `kit)` line to `        kit)        return 1 ;;   # always refreshed -- never "done", see ship_trees()`.
  11. In the `--list` loop, the condition becomes `elif [ "$s" = "preflight" ] || [ "$s" = "kit" ]; then m="runs every time"`.
  12. In the `--dry-run` block, delete the line `    want labimages && labimages_plan`.
  13. Delete the whole `stage_labimages() { … }` function, from `stage_labimages() {` through its closing `}` (it ends just before the `# ═══…` rule above `# 6. GNS3 appliances`).
  14. Replace the section-10 comment block, from the `# ═══…` rule above `# 10. site/ — this repo's reviewed scripts/, config/ and docs/analyst-wiki/,` through the closing `# ═══…` rule, plus the `SITE_TREES=(…)` line after it, with:

```bash
# ═════════════════════════════════════════════════════════════════════════════
# 10. kit/ — this repo (sim-lab-basic, the R770 installer), copied into the
#     bundle so the R770 runs exactly this checkout's TRACKED, COMMITTED
#     scripts/, config/, scenarios/ and docs/ from bundle-*/kit/ -- never a
#     stale copy, an uncommitted edit, or a symlink/submodule that could point
#     outside the manifest. Two sources, resolved once by kit_validate_source()
#     at startup so a doomed run fails in seconds, not after hours of downloads:
#       worktree  KIT_SRC_ROOT is a git work tree with scripts/r770-install.sh.
#       archive   KIT_ARCHIVE (a `git archive --format=tar HEAD` of those
#                 trees) plus KIT_COMMIT -- what r770-build-bundle.sh --pack
#                 embeds, since a packed builder unpacks into a mktemp -d with
#                 no checkout of its own.
#     Content and mode come from the committed tree (ls-tree + cat-file) or
#     the archive's own entries; a tracked symlink or submodule REFUSES and
#     names the path; secret-looking files are excluded. The stage builds into
#     $B/kit.tmp and replaces $B/kit with an atomic mv only on full success.
#     Always refreshed (never stamp-skipped).
# ═════════════════════════════════════════════════════════════════════════════
```

  15. Rename the shared helpers everywhere in the file: `sed -i 's/\bsite_excluded\b/tree_excluded/g; s/\bsitegit\b/treegit/g' staging/r770-offline-fetch.sh`. Then fix their comments:
      - `tree_excluded`'s first comment line becomes `tree_excluded() {  # tree_excluded <path relative to the shipped tree's root>`, and in its body comment change `under the trees this stage ships` to `under the trees the kit stage ships`.
      - Above `treegit`, change `# sitegit <src> <git-args...> -- every git call the site stage makes against a` to `# treegit <src> <git-args...> -- every git call the kit stage makes against a`.
  16. Delete the three-line comment that starts `# site_validate_source() itself lives up near the BUNDLE_TOOL check`.
  17. Above `ship_trees`, change `# implementation behind site/ and kit/: committed content only` to `# implementation behind kit/: committed content only`, and `secret-looking files excluded (site_excluded)` to `secret-looking files excluded (tree_excluded)`.
  18. In `ship_trees`, change the trailing comment on the `label=` line to `# KIT_ARCHIVE, as the operator set it`.
  19. Delete the whole `stage_site() { … }` function (three lines).
  20. In `stage_kit`, the banner becomes `echo "==== [10/11] kit/ (sim-lab-basic: the R770 installer) ===="`.
  21. In `stage_manifest`'s notes, change `per buildout doc"` to `per kit/docs/deployment-runbook.md"`.
  22. In the closing echoes, the two `./scripts/r770-bundle.sh` commands become `$BUNDLE_TOOL`:

```bash
echo "  $BUNDLE_TOOL manifest $B"
echo "then gate it before the media leaves staging:"
echo "  $BUNDLE_TOOL verify $B --strict"
```

- [ ] **Step 4: Prove nothing that should remain was lost.**

Run: `grep -nE 'site|SITE_|labimages|LAB_IMAGES|lab-images|simlab|build repo' staging/r770-offline-fetch.sh`
Expected: exactly three hits, all in the docs-mirror code and none about the old stage: the `wget --mirror … --page-requisites` line (`requisites` contains `site`), `links on the source site` and `defects on the source site`. No `SITE_`, `labimages`, `LAB_IMAGES`, `lab-images`, `simlab` or `build repo`.

Run: `bash -n staging/r770-offline-fetch.sh && bats tests/staging.bats`
Expected: no syntax error; every test `ok`.

- [ ] **Step 5: Commit.**

```bash
git add staging/r770-offline-fetch.sh tests/staging.bats
git commit -m "fetch: drop the site and labimages stages; the kit stage is the one tree it ships"
```

---

### Task 3: `staging/` is shellcheck-clean with no exclusions

**Files:**
- Modify: `staging/r770-offline-fetch.sh` (14 findings; line numbers as of the end of Task 2 will have moved, so find them with shellcheck)
- Modify: `tests/lint.bats`

**Interfaces:**
- Consumes: Task 2's file.
- Produces: helpers `count_glob <paths…>` (prints the count of paths that exist) and `first_glob <paths…>` (prints the first that exists, or nothing; always returns 0), defined right after `note()`.

- [ ] **Step 1: Write the failing test.** In `tests/lint.bats`, replace the header comment and the `LEGACY_EXCLUDE` line (everything above `setup()`) with:

```bash
#!/usr/bin/env bats
#
# Lint gate. Every script in the kit, staging/ included, must be
# shellcheck-clean at default severity with NO exclusions.
```

Then replace the test `"the carried staging scripts lint: three clean, the fetch script with its accepted list only"` with:

```bash
@test "every staging script is shellcheck-clean with no exclusions" {
    run shellcheck staging/*.sh
    echo "$output"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run it and confirm it fails.**

Run: `bats tests/lint.bats --filter 'staging'`
Expected: FAIL, listing 6 × SC2012 and 8 × SC2015, all in `staging/r770-offline-fetch.sh`.

- [ ] **Step 3: Add the two helpers.** Immediately after the line `note() { echo "- $*" >> "$NOTES"; echo ">> $*"; }`, add:

```bash
# count_glob <paths...> -- how many of the (glob-expanded) paths exist. An
# unmatched glob arrives as its literal pattern, which does not exist, so it
# counts 0. Replaces `ls glob | wc -l`, which shellcheck (SC2012) rightly distrusts.
count_glob() { local n=0 f; for f in "$@"; do if [ -e "$f" ]; then n=$((n + 1)); fi; done; echo "$n"; }
# first_glob <paths...> -- the first (glob-expanded, so sorted) path that
# exists, or nothing. Always returns 0. Replaces `ls glob | head -1`.
first_glob() { local f; for f in "$@"; do if [ -e "$f" ]; then printf '%s\n' "$f"; return 0; fi; done; return 0; }
```

- [ ] **Step 4: Fix the six SC2012 lines.** Each `$(ls <glob> 2>/dev/null | wc -l)` becomes `$(count_glob <glob>)`, and each `$(ls <glob> 2>/dev/null | head -1 || true)` becomes `$(first_glob <glob>)`:

```bash
        docs)       [ "$(count_glob "$B/.stamps"/08-docs-*.done)" -ge 3 ] ;;
```
```bash
    note "APT bundle: skipped — complete in a previous run ($(count_glob "$B/apt"/*.deb) debs cached; FORCE=1 to rebuild)"
```
```bash
note "APT bundle: $(count_glob "$B/apt"/*.deb) debs incl. docker-ce, ubridge (GNS3 PPA) + dist-upgrade security debs; Packages, Packages.gz and Release generated (serve as a trivial repo)"
```
```bash
note "GNS3 definitions: $(count_glob "$B/gns3/definitions"/*.gns3a) .gns3a files (definitions are free even for licensed appliances)"
```
```bash
VYOS_EXISTING=$(first_glob "$B/gns3/appliances"/vyos-*-generic-amd64.iso)
```
```bash
ALPINE_EXISTING=$(first_glob "$B/gns3/appliances"/alpine-virt-*-x86_64.iso)
```

- [ ] **Step 5: Fix the eight SC2015 lines.** Each `A && B && note ok || note warn` becomes an `if`/`else` with the same condition and the same two notes. `note` cannot fail, so behaviour is identical.

VyOS (inside `if [ -n "$VYOS_TAG" ]; then`):

```bash
        VYOS_ISO="vyos-${VYOS_TAG}-generic-amd64.iso"
        if fetch "$B/gns3/appliances/$VYOS_ISO" \
                "https://github.com/vyos/vyos-nightly-build/releases/download/${VYOS_TAG}/${VYOS_ISO}" \
            && fetch "$B/gns3/appliances/${VYOS_ISO}.minisig" \
                "https://github.com/vyos/vyos-nightly-build/releases/download/${VYOS_TAG}/${VYOS_ISO}.minisig"; then
            note "VyOS rolling ${VYOS_TAG} ISO + minisig fetched"
        else
            note "WARN: VyOS ${VYOS_TAG} download failed — fetch manually from github.com/vyos/vyos-nightly-build/releases"
        fi
```

MikroTik CHR:

```bash
if fetch "$B/gns3/appliances/chr-${CHR_VER}.img.zip" \
        "https://download.mikrotik.com/routeros/${CHR_VER}/chr-${CHR_VER}.img.zip"; then
    note "MikroTik CHR ${CHR_VER} raw image fetched (unzip on the R770; GNS3/QEMU boots the raw .img directly)"
else
    note "WARN: CHR ${CHR_VER} download failed — check https://mikrotik.com/download/chr"
fi
```

OPNsense verification. The condition is the existing `( cd "$B/gns3/appliances" && grep … | <checksum check> - )` subshell, **moved unchanged** to sit between `if` and `; then`:

```bash
    if ( cd "$B/gns3/appliances" && \
         grep "OPNsense-${OPNSENSE_VER}-dvd-amd64.iso.bz2" "OPNsense-${OPNSENSE_VER}-checksums-amd64.sha256" \
           | <the existing checksum-check command and its trailing "-", unchanged> ); then
        note "OPNsense ${OPNSENSE_VER} dvd ISO verified against its sha256 list"
    else
        note "WARN: OPNsense checksum verification FAILED — do not transfer this file"
    fi
```

Alpine, cached copy. The condition is the existing `( cd "$B/gns3/appliances" && <checksum check of "${ALPINE_ISO}.sha256"> )` subshell, unchanged:

```bash
    if ( cd "$B/gns3/appliances" && <the existing checksum check of "${ALPINE_ISO}.sha256", unchanged> ); then
        note "Alpine virt ISO ${ALPINE_ISO}: already present (re-verified) — skipped"
    else
        note "WARN: cached ${ALPINE_ISO} failed re-verification — delete it and rerun"
    fi
```

Alpine, fresh download. The two `fetch` calls plus the same unchanged checksum subshell form the condition:

```bash
        if fetch "$B/gns3/appliances/$ALPINE_ISO" "${ALPINE_BASE}/${ALPINE_ISO}" \
            && fetch "$B/gns3/appliances/${ALPINE_ISO}.sha256" "${ALPINE_BASE}/${ALPINE_ISO}.sha256" \
            && ( cd "$B/gns3/appliances" && <the existing checksum check of "${ALPINE_ISO}.sha256", unchanged> ); then
            note "Alpine virt ISO ${ALPINE_ISO} fetched + verified"
        else
            note "WARN: Alpine fetch/verify failed — see ${ALPINE_BASE}"
        fi
```

ET Open rules (inside the `elif … [ "$ET_CODE" = "200" ]; then` branch):

```bash
    if fetch "$B/enrichment/emerging.rules.tar.gz" "$ET_URL"; then
        note "ET Open rules (${ET_SURICATA_PATH}) fetched"
    else
        note "WARN: ET Open rules download failed (optional; Suricata disabled by default)"
    fi
```

Zeek docs:

```bash
    if fetch "$B/docs/zeek-docs-htmlzip-current.zip" \
            "https://app.readthedocs.org/projects/zeek-docs/downloads/htmlzip/current/"; then
        note "docs: zeek offline htmlzip (Read the Docs build) fetched"
    else
        note "WARN: zeek docs htmlzip fetch failed (rerun resumes it)"
    fi
```

GNS3 server docs:

```bash
    if fetch "$B/docs/gns3-server-docs.tar.gz" \
            "https://github.com/GNS3/gns3-server/archive/refs/tags/v${GNS3_VER}.tar.gz"; then
        note "docs: gns3-server v${GNS3_VER} source tarball (includes docs/) fetched"
    else
        note "WARN: gns3-server source tarball fetch failed"
    fi
```

- [ ] **Step 6: Check the helpers behave like what they replace.** Run this throwaway check (nothing is committed):

```bash
d=$(mktemp -d); touch "$d/a.deb" "$d/b.deb"
eval "$(sed -n '/^count_glob()/p; /^first_glob()/p' staging/r770-offline-fetch.sh)"
[ "$(count_glob "$d"/*.deb)" = 2 ] && [ "$(count_glob "$d"/*.none)" = 0 ] \
  && [ "$(first_glob "$d"/*.deb)" = "$d/a.deb" ] && [ -z "$(first_glob "$d"/*.none)" ] && echo helpers-ok
rm -rf "$d"
```
Expected: `helpers-ok`.

- [ ] **Step 7: Run lint, the staging suite and the fetch's dry paths.**

Run: `shellcheck staging/*.sh && bats tests/lint.bats tests/staging.bats && BUNDLE_DIR=$(mktemp -d) ./staging/r770-offline-fetch.sh --list`
Expected: shellcheck silent; every test `ok`; `--list` prints the 12 stages with exit 0 (`docs  -` on an empty bundle).

- [ ] **Step 8: Commit.**

```bash
git add staging/r770-offline-fetch.sh tests/lint.bats
git commit -m "staging: shellcheck-clean with no exclusions (count_glob/first_glob; if/else for A && B || C)"
```

---

### Task 4: `--pack` carries the four scripts and the kit, nothing else

**Files:**
- Modify: `staging/r770-build-bundle.sh` (`SITE_TREES`, the pack comment block, `cmd_pack`, the test-overrides line, the two closing messages)
- Test: `tests/staging.bats`

**Interfaces:**
- Consumes: the fetch's `KIT_ARCHIVE`/`KIT_COMMIT` contract (Task 2, unchanged).
- Produces: a packed builder whose payload is `r770-build-bundle.sh r770-staging-preflight.sh r770-offline-fetch.sh r770-bundle.sh`, plus `kit.tar` when `KIT_SRC_ROOT` was set, and which exports only `KIT_ARCHIVE`/`KIT_COMMIT`. `BUILD_PACK_ROOT` stops existing.

- [ ] **Step 1: Write the failing tests.** In `tests/staging.bats`, delete `fake_build_repo()` (with its comment), the test `"--pack refuses the kit's own tree: …"` and the test `"--pack emits a valid self-extracting builder carrying all four scripts"`. Put this in their place:

```bash
# a kit-shaped checkout: what KIT_SRC_ROOT names when --pack embeds the kit
fake_kit() {
    local r="$BATS_TEST_TMPDIR/kit"
    mkdir -p "$r/scripts/lib" "$r/config" "$r/scenarios" "$r/docs"
    echo '#!/bin/sh' > "$r/scripts/r770-install.sh"; echo '#!/bin/sh' > "$r/scripts/lib/common.sh"
    echo 'x' > "$r/config/x.conf"; echo 'x' > "$r/scenarios/x.conf"; echo '# doc' > "$r/docs/index.md"
    git -C "$r" init -q && git -C "$r" add -A && git -C "$r" -c user.email=t@t -c user.name=t commit -qm fixture
    printf '%s' "$r"
}

# payload_list <packed builder> -- the file names inside its base64 payload
payload_list() {
    sed -n "/^base64 -d <<'R770_PAYLOAD'/,/^R770_PAYLOAD$/p" "$1" | sed '1d;$d' | base64 -d | tar tz
}

@test "--pack with a kit checkout emits a valid builder: the four scripts and kit.tar, no site/" {
    KIT_SRC_ROOT=$(fake_kit) run ./staging/r770-build-bundle.sh --pack
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/packed.sh"
    run bash -n "$BATS_TEST_TMPDIR/packed.sh"
    [ "$status" -eq 0 ]
    run payload_list "$BATS_TEST_TMPDIR/packed.sh"
    echo "$output"
    [ "$status" -eq 0 ]
    for f in r770-build-bundle.sh r770-staging-preflight.sh r770-offline-fetch.sh r770-bundle.sh kit.tar; do
        [[ $'\n'"$output"$'\n' == *$'\n'"$f"$'\n'* ]] || { echo "payload lacks $f"; false; }
    done
    [[ "$output" != *"site"* ]]
    grep -q '^export KIT_ARCHIVE=' "$BATS_TEST_TMPDIR/packed.sh"
    run grep -c 'SITE_' "$BATS_TEST_TMPDIR/packed.sh"
    [ "$output" = "0" ]
}

@test "--pack from this kit's tree without KIT_SRC_ROOT packs the four scripts and says it carries no kit" {
    run ./staging/r770-build-bundle.sh --pack
    [ "$status" -eq 0 ]
    [[ "$output" == *"carries no kit"* ]]
    [[ "$output" == *"R770_PAYLOAD"* ]]
}
```

- [ ] **Step 2: Run them and confirm they fail.**

Run: `bats tests/staging.bats --filter -- '--pack'`
Expected: both FAIL. The first test's output has `site.tar` and `SITE_ARCHIVE`. The second exits non-zero, because `git archive` cannot find `docs/analyst-wiki` in this kit.

- [ ] **Step 3: Rewrite the pack path in `staging/r770-build-bundle.sh`.**
  1. Delete the line `SITE_TREES=(scripts config docs/analyst-wiki scenarios images)`.
  2. In the test-overrides comment, change `# BUILD_VERIFY_CMD, BUILD_BUNDLE_DIR, BUILD_ASSUME_YES, BUILD_PACK_ROOT.` to `# BUILD_VERIFY_CMD, BUILD_BUNDLE_DIR, BUILD_ASSUME_YES.`
  3. Replace everything from `# ── pack: emit a single file carrying all four scripts, PLUS a git archive of` through the closing `}` of `cmd_pack()` with:

```bash
# ── pack: emit a single file carrying all four scripts, plus a git archive of
# the kit at the exact commit it was packed from (when KIT_SRC_ROOT is set) ──
# The payload rides in a quoted heredoc so the emitted file is inert to a
# syntax check and cannot be mistaken for code. Note it is base64: a packed
# builder must never be committed, because base64 hides the version pins from
# the ownership guard that keeps them living in exactly one place. .gitignore
# carries the name for that reason.
#
# A packed builder unpacks flat into a mktemp -d with no checkout of its own,
# so the fetch's kit stage cannot read a work tree there. When KIT_SRC_ROOT
# names a kit checkout at pack time, --pack embeds `git archive HEAD` of its
# scripts/ config/ scenarios/ docs/ plus the commit, refusing a dirty tree: a
# pack is a release artifact and must be traceable to one exact commit.
# Without KIT_SRC_ROOT the pack carries no kit, and the packed builder's fetch
# then needs KIT_SRC_ROOT (or --skip kit) like any other run.
cmd_pack() {
    local tmp kit_commit="" payload=()
    tmp="$(mktemp -d)" || die "mktemp failed"
    if [ -n "${KIT_SRC_ROOT:-}" ]; then
        if [ -n "$(git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" status --porcelain -- scripts config scenarios docs 2>/dev/null)" ]; then
            rm -rf "$tmp"; die "--pack refuses a dirty kit tree at KIT_SRC_ROOT ($KIT_SRC_ROOT) -- commit or stash it first"
        fi
        kit_commit="$(git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" rev-parse HEAD)" || { rm -rf "$tmp"; die "KIT_SRC_ROOT ($KIT_SRC_ROOT) is not a git checkout"; }
        git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" archive --format=tar HEAD -- scripts config scenarios docs > "$tmp/kit.tar" ||
            { rm -rf "$tmp"; die "could not archive the kit at $kit_commit"; }
    else
        echo "r770-build-bundle: note: --pack without KIT_SRC_ROOT carries no kit; the packed builder's fetch will need KIT_SRC_ROOT (or --skip kit)" >&2
    fi

    read -ra payload <<< "$CONTENTS"
    payload=(-C "$HERE" "${payload[@]}")
    if [ -n "$kit_commit" ]; then payload+=(-C "$tmp" kit.tar); fi
    if ! tar czf "$tmp/payload.tgz" "${payload[@]}"; then
        rm -rf "$tmp"
        die "could not pack: ${payload[*]}"
    fi

    cat <<HEADER
#!/usr/bin/env bash
#
# R770 self-extracting bundle builder — generated $(date -Is)
#
# Carries, and runs:
#   r770-build-bundle.sh        the orchestrator
#   r770-staging-preflight.sh   host fitness gate
#   r770-offline-fetch.sh       the fetch (owner of every version pin)
#   r770-bundle.sh              manifest + integrity gate
#
# Also carries sim-lab-basic (the R770 installer) as kit.tar when KIT_SRC_ROOT
# was set at pack time.
#
# Copy to a staging host and run it. On RHEL 8 use rootful podman:
#   sudo -E bash ${PACKED_NAME}
#
# Regenerate this file whenever a pin moves or the kit changes — it is a
# snapshot, not a source. Never commit it: the payload is base64, which hides
# the pins from the guard that keeps them in one place.
set -euo pipefail
D="\$(mktemp -d)"; trap 'rm -rf "\$D"' EXIT
base64 -d <<'R770_PAYLOAD' | tar xz -C "\$D"
HEADER
    base64 "$tmp/payload.tgz"
    cat <<'FOOTER'
R770_PAYLOAD
chmod +x "$D"/*.sh
FOOTER
    if [ -n "$kit_commit" ]; then
        # shellcheck disable=SC2016  # $D stays literal: it is the packed script's own variable
        printf 'export KIT_ARCHIVE="$D/kit.tar"\nexport KIT_COMMIT="%s"\n' "$kit_commit"
    fi
    cat <<'FOOTER2'
exec "$D/r770-build-bundle.sh" "$@"
FOOTER2
    rm -rf "$tmp"
}
```

  4. In the closing `case "$vrc"`, the `0)` branch's third echo becomes `echo "FROM the media, then follow kit/docs/deployment-runbook.md on the R770."`. The `2)` branch's two message lines become:

```bash
        echo "Disposition every warning in writing, in the cycle record kept with"
        echo "the bundle (kit/docs/deployment-runbook.md, Record the cycle), before the media moves."
```

- [ ] **Step 4: Run lint and the suite.**

Run: `shellcheck staging/r770-build-bundle.sh && bats tests/staging.bats && ./staging/r770-build-bundle.sh --help | head -3`
Expected: shellcheck silent; every test `ok`; the help's first lines are unchanged (`r770-build-bundle.sh — one command, one verified bundle.`).

- [ ] **Step 5: Commit.**

```bash
git add staging/r770-build-bundle.sh tests/staging.bats
git commit -m "build-bundle: --pack carries the four scripts and the kit; no site archive"
```

---

### Task 5: Retire the provenance guard; `staging/` is edited here

**Files:**
- Delete: `staging/PROVENANCE.txt`
- Modify: `tests/staging.bats` (header, the hash test), `tests/no-pins.bats` (header, `EXCL`), `staging/README.md` (rewrite)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: nothing that later tasks call.

- [ ] **Step 1: Delete the hash test and the record.** In `tests/staging.bats`, delete the test `"every carried file matches the hash recorded in PROVENANCE.txt"` and replace the header comment (the lines above `load helpers/fixtures`) with:

```bash
#!/usr/bin/env bats
#
# staging/ is the kit's own bundle pipeline: preflight, fetch, the one-command
# builder and the verifier. What this suite proves: they run as a set from this
# directory, the fetch ships the kit as its one tree, --pack carries only
# themselves and the kit, and the verifier gates a bundle as the fetch leaves it.
# tests/no-legacy-manifest.bats proves the R770 side never calls them.
```

Then run `git rm staging/PROVENANCE.txt`.

- [ ] **Step 2: Fix `tests/no-pins.bats`.** Replace the header comment (from `# The kit carries NO version pins outside their one owner.` through `# image \`ubuntu:24.04\` the preflight names is a decision of record, not a pin.`) with:

```bash
# The kit carries NO version pins outside their one owner,
# staging/r770-offline-fetch.sh and its pin block. Everywhere else a pin would
# be a copy nothing updates on the next bump. Fixtures use 0.0.0-fixture, IPs
# are not versions, and the clean build image `ubuntu:24.04` the preflight
# names is a decision of record, not a pin.
```

and change the `EXCL` line to:

```bash
EXCL=(--exclude-dir=.git --exclude-dir=r770-evidence --exclude=r770-offline-fetch.sh)
```

- [ ] **Step 3: Rewrite `staging/README.md`** in full:

````markdown
# staging/ — the bundle-building side

These four scripts are the kit's supply pipeline. They run on the
**internet-connected staging host** and **never on the R770**. Nothing under
the kit's `scripts/` calls them (`tests/no-legacy-manifest.bats`).

| Script | Role |
|---|---|
| `r770-staging-preflight.sh` | may THIS host build a bundle? (Ubuntu 24.04 + Docker CE, or RHEL 8 + rootful podman; never LXC; room; egress) |
| `r770-offline-fetch.sh` | the download — **the one owner of every version pin** (its `# ── pins:` block); resumable, proxy-aware, seeds from a previous bundle |
| `r770-build-bundle.sh` | one command, one verified bundle: preflight → fetch → pause for the manual items → manifest → `verify --strict` |
| `r770-bundle.sh` | manifest generation and integrity verification; the fetch copies it **into the bundle root**, and that copy is what the R770 side runs |

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
````

- [ ] **Step 4: Run the suites that touch these files.**

Run: `bats tests/staging.bats tests/no-pins.bats tests/references.bats tests/lint.bats`
Expected: every test `ok`. (`tests/references.bats` reads `staging/README.md`; every path it names exists.)

- [ ] **Step 5: Commit.**

```bash
git add -A staging/ tests/staging.bats tests/no-pins.bats
git commit -m "staging: retire PROVENANCE — the pipeline is the kit's own, edited and tested here"
```

---

### Task 6: The scenario lint resolves every bundled image; no "upstream pending"

**Files:**
- Modify: `tests/helpers/lint_scenarios.py:15` (`UPSTREAM_PENDING`), `:50-59` (`bundled_images`), `:164-168` (its use)
- Test: `tests/scenarios.bats`

**Interfaces:**
- Consumes: `GNS3_NODE_IMAGES` and each `NAME="${NAME:-ref}"` pin line in `staging/r770-offline-fetch.sh`.
- Produces: `bundled_images()` returns the image short names, with every `"$VAR"` entry resolved through its own pin line.

- [ ] **Step 1: Write the failing test.** Append to `tests/scenarios.bats`:

```bash
@test "every \$VAR entry in GNS3_NODE_IMAGES resolves through its own pin line (strongswan, not frr twice)" {
    run python3 -c 'import sys; sys.path.insert(0, "tests/helpers"); import lint_scenarios as l; print(" ".join(sorted(l.bundled_images())))'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ " $output " == *" strongswan "* ]]
    [[ " $output " == *" frr "* ]]
    [[ " $output " == *" netshoot "* ]]
}
```

- [ ] **Step 2: Run it and confirm it fails.**

Run: `bats tests/scenarios.bats --filter 'VAR entry'`
Expected: FAIL. The output lacks `strongswan`, because `"$STRONGSWAN_IMG"` is resolved through `FRR_IMG`'s pin line.

- [ ] **Step 3: Fix the resolution and drop the workaround.** In `tests/helpers/lint_scenarios.py`:
  1. Delete the line `UPSTREAM_PENDING = {"strongswan"}  # added to the build repo's pin block, not yet in a bundle`.
  2. Replace `bundled_images()` with:

```python
def bundled_images():
    names = set()
    with open("staging/r770-offline-fetch.sh") as f:
        text = f.read()
    block = re.search(r"GNS3_NODE_IMAGES=\((.*?)\)", text, re.S).group(1)
    for ref in re.findall(r'"([^"]+)"', block):
        if ref.startswith("$"):
            var = ref.strip("${}")
            ref = re.search(r"^" + var + r'="\$\{' + var + r":-([^}]+)\}\"", text, re.M).group(1)
        names.add(ref.split("/")[-1].split(":")[0])
    return names
```

  3. Where `known = bundled_images() | UPSTREAM_PENDING` is used, it becomes `known = bundled_images()`, and the error message becomes `f"{s}: image {i} is not bundled (GNS3_NODE_IMAGES in staging/r770-offline-fetch.sh)"`.

- [ ] **Step 4: Run the scenario suites.**

Run: `bats tests/scenarios.bats tests/expect.bats`
Expected: every test `ok`. In particular, `ipsec-ike` and `s1-w1-ss`, which list `strongswan`, now lint clean on the bundled set alone.

- [ ] **Step 5: Commit.**

```bash
git add tests/helpers/lint_scenarios.py tests/scenarios.bats
git commit -m "scenario lint: resolve each \$VAR image through its own pin; strongswan is bundled, not pending"
```

---

### Task 7: SKIP reasons and diagnoses name the prerequisite, not a build-repo phase

**Files:**
- Modify: `scripts/r770-validate.sh` (header lines 3–6, 17, 24–27; lines 73, 78, 91, 117, 134, 195, 198, 210, 230, 245, 276, 278, 306, 331)
- Modify: `scripts/r770-airgap-check.sh:110`, `scripts/r770-import-bundle.sh:66,444`, `scripts/r770-malcolm-deploy.sh:39,111,405,932`
- Test: `tests/validate.bats:26,44,46,48,49,53,188`, `tests/airgap-check.bats:28,34`

**Interfaces:**
- Consumes: nothing.
- Produces: the new SKIP strings, which Task 9's `docs/validation.md` describes. Each one has the shape `<observed> (<needs …>)`.

| Row | Old evidence | New evidence |
|---|---|---|
| host/chrony | `Phase 5 not built` | `needs chrony` |
| host/lab-dns | `Phase 5 not built` | `needs dnsmasq, the .lab resolver` |
| virtualization/throwaway-vm | `Phase 7 not built` | `needs libvirt: virt-install and virsh` |
| gns3/unit | `Phase 8 not built (systemctl is-active gns3)` | `needs the gns3 unit: r770-gns3-deploy.sh service` |
| wan/impairment (opted in) | two rows on `wan-apply` | observed `not automated by this suite`, evidence `impair with r770-wan.sh and measure by hand` |
| backup/restore (no restic) | `Phase 15 not built` | `needs restic` |
| backup/restore (no repo) | `Phase 15 not built` | `needs a restic repo under /srv/backup and /etc/lab/secrets/restic.pw` |
| portal/vhosts | `Phase 13 not built` | `needs the lab CA: r770-portal-deploy.sh ca` |
| airgap-check dnsmasq | `dnsmasq: not installed (Phase 5 not built) — …` | `dnsmasq: not installed — .lab authority and no-resolv cannot be checked` |

- [ ] **Step 1: Update the tests to the new wording (they then fail).** In `tests/validate.bats`:
  - In `setup`, the airgap stub's SKIP line becomes `echo "SKIP  dnsmasq: not installed — .lab authority and no-resolv cannot be checked"`.
  - The skip test's assertions become:

```bash
    [[ "$output" == *"SKIP  host/chrony: chronyc not installed (needs chrony)"* ]]
    [[ "$output" == *"SKIP  cpu-ram/threads: 64 (--expect-threads not given)"* ]]
    [[ "$output" == *"SKIP  gns3/unit: inactive (needs the gns3 unit: r770-gns3-deploy.sh service)"* ]]
    [[ "$output" == *"SKIP  wan/impairment: not opted in"* ]]
    [[ "$output" == *"SKIP  backup/restore: restic not installed (needs restic)"* ]]
    [[ "$output" == *"SKIP  portal/vhosts: no /etc/nginx/ssl/ca.crt (needs the lab CA: r770-portal-deploy.sh ca)"* ]]
```

  and its report assertion becomes `[[ "$output" == *"| chrony | Leap status Normal | chronyc not installed | SKIP | needs chrony |"* ]]`.
  - In the airgap-area test, the assertion becomes `[[ "$output" == *"SKIP  airgap/dnsmasq: not installed — .lab authority"* ]]`.
  - Add a test for the opted-in WAN row:

```bash
@test "an opted-in wan area SKIPs as not automated, pointing at r770-wan.sh" {
    run validate --area wan --allow-wan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  wan/impairment: not automated by this suite (impair with r770-wan.sh and measure by hand)"* ]]
}
```

In `tests/airgap-check.bats`, the test name becomes `"an air-gapped host passes, with the missing prerequisites SKIPPED by name"` and its dnsmasq assertion becomes `[[ "$output" == *"SKIP  dnsmasq: not installed — .lab authority and no-resolv cannot be checked"* ]]`.

- [ ] **Step 2: Run them and confirm they fail.**

Run: `bats tests/validate.bats tests/airgap-check.bats`
Expected: the skip test, the airgap-area test, the new WAN test and the airgap-check test FAIL on the old "Phase N not built" text.

- [ ] **Step 3: Change `scripts/r770-validate.sh`.**
  - Lines 3–6 (header) become:

```bash
# r770-validate.sh — prove capabilities, do not assume them: a read-only or
# self-cleaning suite that writes a check · expected · observed · verdict ·
# evidence table.
```

  - The `--allow-wan` usage line becomes `#   --allow-wan                                 (not automated: impair with r770-wan.sh, measure by hand)`.
  - In the comment block that starts `# A check that cannot run`, change `(tool missing, phase not built, opt-in not given)` to `(tool missing, prerequisite not set up, opt-in not given)`, and `fix attempt: fixing happens under the phase protocol.` to `fix attempt: fixing happens one change at a time, then the suite is rerun.`
  - In each `row … SKIP "<old>"` call, replace the last argument per the table above. For example, line 73 ends `SKIP "needs chrony"; fi`, and line 230 becomes `if [ "$st" != "active" ]; then row "unit" "active" "$st" SKIP "needs the gns3 unit: r770-gns3-deploy.sh service"; return; fi`.
  - Line 245 (the `if command -v wan-apply …; else …; fi` pair) becomes the single line:

```bash
    row "impairment" "+40 ms then baseline" "not automated by this suite" SKIP "impair with r770-wan.sh and measure by hand"
```

  - Diagnoses: line 91, `(Phase 2)` is removed: `"VT-x/VT-d disabled in BIOS or the kvm module is missing"`. Line 117, `— Phase 3 layout incomplete;` becomes `— the storage layout is incomplete;`. Line 195's diagnosis text becomes `"not promiscuous: capture-port prep has not run on this port"`. Line 198, `capture-prep (Phase 9) turns them off` becomes `capture-port prep turns them off`.
  - Line 134 comment: `# The lab bridge (Phase 11 live mirror): hub mode,` becomes `# The lab bridge (the live mirror, r770-gns3-deploy.sh labnet): hub mode,`.
  - Line 331: `echo "Format per the build repo's validation-runner: check · expected · observed · verdict · evidence. Areas: ${AREAS}."` becomes `echo "Format: check · expected · observed · verdict · evidence. Areas: ${AREAS}."`.

- [ ] **Step 4: Change the other three scripts.**
  - `scripts/r770-airgap-check.sh:110`: `skip "dnsmasq: not installed — .lab authority and no-resolv cannot be checked"; return; fi`.
  - `scripts/r770-import-bundle.sh:66`: drop ` (Phase 3)` from the end of the message, so it ends `mount the LV first"`. Line 444: `note "qemu-img not installed — image formats are not confirmed"`.
  - `scripts/r770-malcolm-deploy.sh:39`: `#                              (set it from measured feed rates;`. Line 405: `# root-owned mount points. The directories are the ones the`. Line 111: `# ── load / assert-tags ─────────────────────────────────────────────────────`. Line 932: the trailing comment becomes `# bare <bundle-dir>, kept for older call sites`.

- [ ] **Step 5: Run lint and the touched suites; confirm no phase number is left.**

Run: `shellcheck -x scripts/*.sh scripts/lib/*.sh && bats tests/validate.bats tests/airgap-check.bats tests/import-bundle.bats tests/malcolm-deploy.bats tests/lint.bats && grep -nE 'Phase [0-9]|build repo|phase protocol' scripts/`
Expected: shellcheck silent; every test `ok`; the grep prints nothing.

- [ ] **Step 6: Commit.**

```bash
git add scripts/ tests/validate.bats tests/airgap-check.bats
git commit -m "scripts: SKIP reasons and diagnoses name the prerequisite, not a build-repo phase"
```

---

### Task 8: `README.md`, `CLAUDE.md` and `docs/kit-sync.md`

**Files:**
- Delete: `docs/kit-sync.md`
- Modify: `README.md`, `CLAUDE.md`, `tests/no-legacy-manifest.bats:15`

**Interfaces:**
- Consumes: Tasks 1–7 (the docs describe what the code now does).
- Produces: nothing called by later tasks.

- [ ] **Step 1: Make the guard test stop naming the file, then delete it.** In `tests/no-legacy-manifest.bats`, change `for f in README.md CLAUDE.md docs/deployment-runbook.md docs/kit-sync.md; do` to `for f in README.md CLAUDE.md docs/deployment-runbook.md staging/README.md; do`. Then add the verifier's name to `staging/README.md` so that test still holds there: in its `r770-bundle.sh` table row, change `and that copy is what the R770 side runs` to `and that copy is what the R770 side runs (\`<bundle>/r770-bundle.sh verify\`)`. Then `git rm docs/kit-sync.md`.

Run: `bats tests/no-legacy-manifest.bats tests/references.bats`
Expected: `no-legacy-manifest` all `ok`. `references` FAILs, because `README.md` and `CLAUDE.md` still name `docs/kit-sync.md` and `staging/PROVENANCE.txt`. The next two steps fix that.

- [ ] **Step 2: `README.md`.**
  - Opening paragraph, from `Both sides of the air gap, in one clone.` through `version pins in the kit are in the fetch script's pin block, their one owner.`:

```markdown
Both sides of the air gap, in one clone. `staging/` builds the bundle on the
internet-connected staging host; `scripts/` **takes the bundle onto the
air-gapped Dell PowerEdge R770 and stands the services up** — verified, gated,
idempotent, and with evidence for every step. Nothing under `scripts/` reaches
the internet, and the only version pins in the kit are in the fetch script's
pin block, their one owner.
```

  - In the diagram, drop `   (carried from simlab-build)` from the staging line, and change the iDRAC line to `iDRAC (out-of-band)               recovery path — prove it before any change to management networking`.
  - Replace the `## Cutting a bundle (staging host)` code block and the paragraph after it (`The fetch's \`site\` stage ships …`) with:

````markdown
```bash
KIT_SRC_ROOT=<this kit's checkout> ./staging/r770-build-bundle.sh   # preflight → fetch → manual-items pause → manifest → verify --strict
```

The fetch's `kit` stage ships this kit's committed tree into the bundle as
`kit/`, so it needs `KIT_SRC_ROOT` to name the checkout (`staging/README.md`).
````

  - In the next paragraph, change `says what each of the four scripts does and why they are never edited here.` to `says what each of the four scripts does and how to change them.`
  - Replace `are ready today and which still wait on their own build-repo phase — iDRAC` / `and the build repo's Phase 5 don't gate anything in this kit.` with `need what on the box first — each step checks its own prerequisites and refuses by name.`
  - In the `scripts/r770-malcolm-deploy.sh` row, change `load/assert-tags (as in the build repo),` to `load/assert-tags,`.
  - The `staging/` row: `| \`staging/\` | The bundle pipeline: preflight, fetch (the pin owner), the one-command builder, and the verifier the fetch places inside every bundle. Runs on the staging host only |`
  - The `config/` row: `… mkdocs — the deltas from upstream defaults are in \`config/README.md\` |`
  - Delete the `docs/kit-sync.md` row.
  - The `docs/wiki/` row: `| \`docs/wiki/\` | The analyst wiki source, built by \`scripts/r770-docs-deploy.sh\` and served at \`docs.lab\` on the R770 |`
  - The `tests/` row: `… shellcheck with no exclusions, and bats suites that stub …`
  - In "One pin owner", delete `  as it does in the build repo;` so the line reads `staging/r770-offline-fetch.sh\` carries the pin block; nothing else in the kit may restate a version.`
  - Evidence paragraph, last sentence: `Archive that directory off the box, next to the bundle it ran against, when the cycle is recorded — an assertion is not evidence, a transcript is.`

- [ ] **Step 3: `CLAUDE.md`.**
  - "What this is", the second paragraph from `` `staging/` is the **staging side**: `` to the end:

```markdown
onto the box and stands the services up. `staging/` is the **staging side**:
the kit's bundle pipeline, run only on the internet-connected staging host.
Read `README.md` and `docs/deployment-runbook.md` before doing anything.
```

  - Commands: delete the line `                                           # (except the one carried file, staging/r770-offline-fetch.sh)`, and replace the `SITE_SRC_ROOT=…` line with `./staging/r770-offline-fetch.sh --dry-run   # the staging side's stage plan; touches nothing`. (The old line ran the builder with `--dry-run`, which the builder does not accept: its flags are `--pack`, `--only`/`--skip`, `--yes`, `--non-interactive` and `--bundle-dir`. The fetch's `--dry-run` is the real dry path.)
  - Architecture, "Two hosts, enforced.":

```markdown
- **Two hosts, enforced.** `staging/` (preflight → fetch → build → verify) is
  the kit's own bundle pipeline, run only on the staging host; it ships this
  repo into the bundle as `kit/`. `scripts/` is the R770 side: three
  independent pipelines plus an optional front door.
  `tests/no-legacy-manifest.bats` and friends prove `scripts/` never reaches
  into `staging/`.
```

  - Architecture, "`config/` holds templates": change `Files are carried from the build repo with deltas tracked in \`config/README.md\`;` to `How each file differs from the upstream default, and why, is tracked in \`config/README.md\`;`.
  - Run context, the phase-tracker bullet:

```markdown
- What a box is ready for is discovered, never assumed: a stage whose
  prerequisite is not on the box SKIPs or refuses, naming what is missing —
  never guesses.
```

  - Rule 4: `4. **One pin owner.** \`staging/r770-offline-fetch.sh\` holds the pin block; a version moves there and nowhere else. Nothing else restates a` (the rest of the rule is unchanged).
  - "Working on the kit itself", the config/staging bullet:

```markdown
- Config changes go through `config/README.md`'s delta table. `staging/`
  follows every kit rule: shellcheck with no exclusions, behaviour tested in
  `tests/staging.bats`.
```

- [ ] **Step 4: Run the reference and guard suites.**

Run: `bats tests/references.bats tests/no-legacy-manifest.bats tests/no-pins.bats && grep -nE 'simlab-build|build repo|SITE_SRC_ROOT|PROVENANCE|kit-sync|BUILD-STATE' README.md CLAUDE.md`
Expected: every test `ok`; the grep prints nothing.

- [ ] **Step 5: Commit.**

```bash
git add -A README.md CLAUDE.md docs/kit-sync.md tests/no-legacy-manifest.bats staging/README.md
git commit -m "docs: README and CLAUDE.md describe a standalone kit; kit-sync.md retired"
```

---

### Task 9: The rest of the live docs and comments

**Files:**
- Modify: `config/README.md`, `docs/deployment-runbook.md`, `docs/validation.md`, `docs/rollback.md:36`, `docs/secrets-locations.md:15`, `docs/CODEMAPS/architecture.md`, `docs/CODEMAPS/dependencies.md`, `docs/CODEMAPS/stages.md:58`, `tests/README.md`, `.gitignore:1-3`, `tests/helpers/fixtures.bash:73`, `tests/malcolm-deploy.bats:44,66,108`, `tests/references.bats:22`

**Interfaces:**
- Consumes: Task 7's SKIP wording (for `docs/validation.md`).
- Produces: nothing called later.

- [ ] **Step 1: `config/README.md`.**
  - Intro paragraph: `Every file here was proven on the staging rehearsal of 2026-09-12 and altered only where a value was staging-specific. The kit renders \`__TOKEN__\` placeholders at deploy time; \`.lab\` names stay literal because they are a decision of record, not a variable.`
  - The table loses its "Build-repo source" column. The header becomes `| Kit file | Delta | Why |` / `|---|---|---|`, and each row keeps its other three cells. For example: `| \`nginx/{docs,gns3}.lab.conf\` | none | proven vhosts |` and `| \`systemd/gns3.service\` | new | a server started from a shell outlived its tmux session |`. Three cell texts also change:
    - the `wan/profiles/*.conf` row's Delta is `new`, and its Why ends at `read by \`scripts/r770-wan.sh\``, dropping the carry-back clause;
    - the networkd row's Why starts `the live mirror: a hub-mode lab bridge …` instead of `Phase 11 live mirror: …`;
    - the `malcolm/malcolm-config.json.template` row's Delta keeps its flag list unchanged.
  - Token table, the `__ARKIME_MANAGE_PCAP__` row: `(else \`false\` / none: set the floor from measured feed rates)`.

- [ ] **Step 2: `docs/deployment-runbook.md`.**
  - Line 3: `**Companion to:** \`docs/rollback.md\` · \`docs/validation.md\``
  - The "Owned facts" paragraph's last sentences: `` `BUNDLE_NOTES.md`; the hardware of record arrives as arguments (`--expect-threads`, `--capture-ifs`, …), and what a box is ready for is discovered by each step. This runbook names no version and no measurement. ``
  - The "Where this runbook stops today" table:

```markdown
| Steps | Needs on the box |
|---|---|
| Bundle-in prep: `preflight` `gate` `copy` `apt` `phone-home` `docker` `files` (shared by all three pipelines) | the storage layout's volumes mounted — `preflight` refuses otherwise |
| GNS3 pipeline: `load` `venv` `secrets` `config` `service` `labnet` | bundle-in prep done; `python3-venv`, `python3-pip-whl` and `ubridge` installed from the local repo |
| Malcolm pipeline: `load` `unpack` `configure` `secrets` `auth` `rebind` `start` | bundle-in prep done; `python3-ruamel.yaml` and `python3-dotenv` from the local repo; capture ports prepared (no address, promiscuous, offloads off) before `configure --capture-ifs` |
| Docs pipeline: `load` `build` | bundle-in prep done |
| Front door: `ca` `cert` `htpasswd` `nginx` | `easy-rsa` and `nginx` from the local repo, and Malcolm's `auth` step already run |
| validate | runs at any point; SKIPs what is not set up, naming it |
```

  - The paragraph after it, from `Proving iDRAC as a recovery path is a` through `before assuming one is ready. The shared bundle-prep steps can run now`, becomes: `Proving iDRAC as a recovery path is a prerequisite for management-networking work outside this kit, not for anything these steps do — it does not gate the GNS3, Malcolm, docs or front-door steps here. What gates them is what the box has: each step checks its own prerequisites and refuses by name when one is missing (the table above). The shared bundle-prep steps can run now`. The text that follows is unchanged.
  - The `apt` paragraph: `installed from that repo by the build repo's base-OS phase, and each step` becomes `installed by hand from that repo (\`apt-get install\` against the local source, the only one there is), and each step`. The rehearsal sentence after it is deleted.
  - The files table: `` `qemu-img info` once Phase 7 tools exist `` becomes `` `qemu-img info` when `qemu-img` is installed ``.
  - The stop note: `**Stop here (\`--to files\`) until the GNS3, Malcolm and front-door steps' prerequisites are on the box (the table at the top) — none of them need iDRAC proven first.**`
  - The Malcolm configure paragraph: `Phase 10 sets that from measured feed rates, so the default is off.` becomes `set it from measured feed rates; the default is off.`
  - The IPsec section: `The build repo's IPsec & WAN scenario spec is filed in the kit as` becomes `The IPsec & WAN scenario spec is filed as`, and `that live in the build repo's unbuilt phases.` becomes `that the kit does not have.`
  - "Record the cycle":

```markdown
- [ ] Copy `r770-evidence/` off the box and archive it next to the bundle it ran against (the transcripts and the validation report are the evidence)
- [ ] Record the cycle with it: verifier exit code and `RESULT:` line, WARN dispositions, courier, whether it imported
- [ ] Keep the previous bundle under `/srv/bundles` until this one has validated end to end
```

  - "If it goes wrong", the SSH row: `| SSH lost during a networking step | iDRAC is the recovery path — prove it before any networking change |`.

- [ ] **Step 3: `docs/validation.md`, `docs/rollback.md`, `docs/secrets-locations.md`.**
  - `docs/validation.md` line 3: `**Companion to:** \`docs/deployment-runbook.md\``.
  - Areas table, "Needs" cells: host `chrony and dnsmasq installed (else SKIP, naming the package)`; virtualization `libvirt (\`virt-install\`, \`virsh\`), a cirros image under \`/srv/vms/base\``; gns3 `the gns3 unit (\`r770-gns3-deploy.sh service\`), the admin secret`; backup `restic, a repo under \`/srv/backup\`, \`/etc/lab/secrets/restic.pw\``; portal `the lab CA (\`r770-portal-deploy.sh ca\`)`. The wan row becomes `| \`wan\` | apply a 40 ms profile, measure, clear | not automated by this suite: impair with \`scripts/r770-wan.sh\` and measure by hand | \`--allow-wan\` | SKIPs with that reason |`.
  - `fixing happens one change at a time under the build repo's phase protocol, and the suite is rerun.` becomes `fixing happens one change at a time (reproduce, one hypothesis, one change), and the suite is rerun.`
  - `run them by hand and record the result in the build repo's \`state/inventory/\`.` becomes `run them by hand and record the result with the cycle's evidence (\`docs/deployment-runbook.md\`, Record the cycle).`
  - `docs/rollback.md:36`: `Netplan, the default route, the firewall policy. Those are outside this kit,` / `with their own procedures; if a kit script appears to need one of them, the script` / `is wrong.` (reflow the paragraph to the same three lines).
  - `docs/secrets-locations.md:15`: `| \`/etc/lab/secrets/restic.pw\` | the backup setup (not this kit) | …` (the other cells are unchanged).

- [ ] **Step 4: `docs/CODEMAPS/*`, `tests/README.md`, `.gitignore` and the test comments.**
  - `docs/CODEMAPS/architecture.md`: delete the sentence `Byte-identity of the four carried files is guarded by \`staging/PROVENANCE.txt\` + \`tests/staging.bats\`.`. Change `— gitignored, carried back to the build repo's \`state/inventory/\` by hand.` to `— gitignored, archived off the box next to its bundle by hand.` Change the Owners line's end from `\`docs/deployment-runbook.md\` · phase status → build repo's\n\`state/BUILD-STATE.md\`.` to `\`docs/deployment-runbook.md\`.`
  - `docs/CODEMAPS/dependencies.md`: delete the `## Cross-repo` heading and its paragraph (four lines).
  - `docs/CODEMAPS/stages.md:58`: `deltas from the build repo. Renderer → destination:` becomes `deltas from upstream defaults. Renderer → destination:`.
  - `tests/README.md` lines 3–5: `One command: \`./tests/run.sh\`. shellcheck over every script with **no exclusions**, then every bats suite.` (reflow, keeping the following sentence). The `lint.bats` row: `shellcheck (no exclusions, \`staging/\` included) and \`bash -n\` …`. The `malcolm-deploy.bats` row: `the seven load/assert-tags cases, plus …`. The `config.bats` row: `the config stays deployable as measured: …`. The `staging.bats` row (if present) describes Task 5's header: `staging/ runs as a set: the fetch's stages and \`--list\`, \`--pack\` (four scripts + kit), the verifier round trip with and without kit/`.
  - `.gitignore` lines 1–3:

```
# Evidence written on the R770 by every kit script (transcripts, validation
# reports). It is archived off the box next to its bundle by hand; a copy here
# would be a second evidence tree nothing keeps in step.
```

  - `tests/helpers/fixtures.bash:73-74`: `# The verifier that ships inside a real bundle is staging/r770-bundle.sh,` / `# copied in by the fetch. Here it is a stub: it records that it was called,`.
  - `tests/malcolm-deploy.bats`: line 44's comment `# docker image ls prints the given tags`; line 66 `# ── load / assert-tags ──────────────────────────────────────────────────────`; the test at line 108 is renamed `"a bare bundle path still works, as older call sites pass it"`.
  - `tests/references.bats:22`: delete the trailing comment `# docs/wiki is the build repo's content`.

- [ ] **Step 5: Run the whole gate.**

Run: `./tests/run.sh 2>&1 | tail -3; ./tests/run.sh >/dev/null 2>&1; echo exit=$?`
Expected: `exit=0`, with 464 tests: the baseline 458, minus the 4 removed (the provenance hash test, the `--pack` refusal, the old `--pack` emit and the old round trip), plus the 10 added (Task 1: 3, Task 2: 3, Task 4: 2, Task 6: 1, Task 7: 1). The lint test Task 3 replaced counts once either way.

- [ ] **Step 6: Commit.**

```bash
git add -A config/README.md docs/ .gitignore tests/
git commit -m "docs: the rest of the live docs describe a standalone kit; prerequisites, not phases"
```

---

### Task 10: The "done when" sweep

**Files:** none expected. Fix whatever the sweep finds, in the file it names.

- [ ] **Step 1: Run the spec's done-when search.**

Run: `grep -rnE 'simlab-build|build repo|SITE_SRC_ROOT|PROVENANCE|kit-sync' --exclude-dir=.git --exclude-dir=superpowers .`
Expected: no output. Fix each hit in the file it names, wording it as the earlier tasks did, then rerun.

- [ ] **Step 2: Search for the phase vocabulary outside the dated docs.**

Run: `grep -rnE 'Phase [0-9]+|BUILD-STATE|state/inventory|phase protocol' --exclude-dir=.git --exclude-dir=superpowers .`
Expected: no output.

- [ ] **Step 3: Run the whole gate one last time.**

Run: `./tests/run.sh >/dev/null 2>&1; echo exit=$?`
Expected: `exit=0`.

- [ ] **Step 4: Commit, only if steps 1–2 changed anything.**

```bash
git add -A
git commit -m "sweep: the last build-repo references"
```
