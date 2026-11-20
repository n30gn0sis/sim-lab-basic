# Backlog — what was deferred when the project closed

The finish line (`docs/superpowers/plans/2026-11-10-finish-line.md`) is the
kit installing the real R770 to INSTALLED once, with evidence. Everything the
plan did not need is listed here, one line each, so nothing is lost and
nothing is silently promised. New work starts as its own project with its own
finish line.

## Still to do inside the finish line

- **Task 8, the R770 install** (operator-run, from the bundle proven in
  `docs/rehearsals/2026-11-12-final-pass.md`). Its record has not been written.
- **The R770's logical volumes.** The import preflight requires the eight
  volumes listed in `scripts/r770-import-bundle.sh` (`LVS`). The operator's
  build notes do not show them created on the R770 yet; create them before
  `plan`, or `plan` stops on them.
- **First reboot on the R770:** check `systemctl --failed`. A configured NIC
  with no cable delays boot by two minutes (final pass F4).

## Open findings against in-scope code

- **F6 — the BGP scenario's readiness wait is tight.** On the third clean
  install of 2026-11-12, e2e's `up bgp` failed "did not become ready within
  120s"; `run --from e2e` passed with all 40 checks. Seen once in three
  installs. Either lengthen the wait or make it a retry; rerun `--from e2e` if
  it recurs (`docs/rehearsals/2026-11-12-final-pass.md`).
- **F7 — the lab CA's `basicConstraints` is not marked critical.** It comes
  from easy-rsa's defaults in the `ca` step of `scripts/r770-portal-deploy.sh`.
  Browsers accept it; strict TLS clients (recent Python releases among them)
  reject the chain. Fix by marking the extension critical when the CA is
  built; an existing CA needs `ca --force` and a reissued certificate.

## Open findings against frozen work

From `docs/rehearsals/2026-11-10-ipsec-wan.md` (IPsec/WAN increment 1 and
`harness/` are frozen: kept, run by e2e, not developed further):

- **I4** — upload file names become several short Arkime tags, not
  `<run-id>` and `inner-<node>`.
- **I5** — `check` finds no ESP session for a run recorded on a tunnel that was
  already up (Arkime stops recording a long flow at its packet cap).
- **I6** — the flap scenario's 30-second outage does not force a DPD restart.
- **I7** — kernel drops on two captures in the first 100 Mbit/s run after a
  reboot; not reproduced.
- **F5** — `harness/r770-staging-vm.sh snapshot` takes no snapshot and prints
  no verdict when `--description` holds `;`, `=`, `:` or parentheses.

## Not built

- IPsec spec phases IP5–IP9
  (`docs/superpowers/specs/2026-09-24-ipsec-scenarios-spec.md`).
- Licensed appliance definitions: the fetch ships no definition without its
  image; add one to the fetch together with its image.
- Traffic on a real physical capture port: the gated step exists and was
  proven on a virtual NIC only.
- `CLAUDE.md` rule 2 does not yet list the capture-port step or the
  docker-group grant among its gated changes (wording deferred by the
  operator).

## Deferred minors

From the finish-line and finish-rehearsals reviews. None blocks an install.

Installer and Malcolm:
- `r770-install.sh` restates the child scripts' package lists; no test ties
  them together.
- Package checks use `dpkg -s`, which also succeeds for removed packages whose
  config remains.
- With packages missing and `lab_mirror0` late, `plan` does not print the
  labnet SKIP; the SKIP text also does not name labnet when ethtool is missing.
- No test for "easy-rsa installed, CA absent" or "nginx installed, cert or
  htpasswd absent" in `plan`.
- `auth`'s docker-group grant runs before auth's other preconditions are
  checked; its username match should be fixed-string; a primary group of
  `docker` is not recognised; its refusal test relies on closed stdin.
- The A10 test checks the template only; the restart behaviour is proven by
  the staging reboot.

Capture ports and offloads:
- A partial `apply` (files installed, enable failed) reruns as "already in
  place"; the FAIL text does not name `--force`.
- The default-route refusal is IPv4 only.
- `--dry-run` prints no `DRY-RUN:` lines; `status` cannot report a
  misconfigured port and prints READY with zero checks for `lab_mirror0` alone.
- The post-reload wait also runs on an unchanged rerun and on a dry run.
- Labnet's rollback glob `05-*lab*` would match a capture-port file whose name
  contains "lab".
- No test for a partial-apply rerun, an IPv6 default route, or the capture SKIP
  line in Malcolm's full pipeline.

Docs and wiki:
- `docs/deployment-runbook.md`: the reboot paragraph sits mid-way through the
  configure prose.
- `staging/r770-offline-fetch.sh`: a comment still names "the licensed five".
- Wiki: the Dashboards saved search is titled "... (lab)", not the Arkime
  name; `gns3.md` and the home page keep a "TBD" for licensed appliances; the
  WAN page's RTT comment disagrees with its own one-way-delay note.

Harness (frozen):
- `snap_exists` matches any field of the snapshot listing, descriptions
  included.
- `tunnel` has no footer or 0/2/1 exit; extra arguments are accepted
  silently; several argument and failure paths are untested.
- `r770-site-shot.ps1`: profile removal is silent; the debug port is chosen
  then reused (a race); some error replies are discarded; a redirect to a
  blocked page can screenshot an error page and exit 0.
- The settings check in `tests/references.bats` covers `scripts` and `staging`
  only, and the no-internet and no-credentials suites do not scan `harness/`.
