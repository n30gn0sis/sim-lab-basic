# Validation — proving capabilities

**Companion to:** the build repo's success criteria (`PRD.md` §10) and `.claude/agents/validation-runner.md` there · `docs/deployment-runbook.md`
**Date:** 2026-09-14

`scripts/r770-validate.sh` is the R770 side of the success criteria: a
read-only or self-cleaning suite that writes one row per check —
**check · expected · observed · verdict · evidence** — to
`r770-evidence/validation-<host>-<ts>.md`, followed by the SKIPPED list and a
diagnosis for every FAIL.

Exit **0** every executed check passed · **2** warnings · **1** at least one
FAIL. SKIPPED checks never change the exit code, and are never omitted.

## Areas

| Area | Checks | Needs | Opt-in | Touches the host? |
|---|---|---|---|---|
| `host` | sshd active · chrony leap status Normal · the three `.lab` names resolve · APT sources are `file:` only | chrony and dnsmasq installed (else SKIP: Phase 5) | — | no |
| `cpu-ram` | `kvm-ok` · thread count · memory · EDAC error counters zero | `--expect-threads N --expect-ram-gb N` (else SKIP: expectations are arguments, never hard-coded) | — | no |
| `storage` | every layout volume is its own mount point, with its size · SMART health per NVMe · PERC virtual disk optimal | `nvme-cli`, `smartmontools`; `perccli2` from the bundle's `dell/` (else SKIP) | — | no |
| `network` | management interface up with an address · each capture port: **no address**, PROMISC, gro/lro/tso off · with --lab-bridge: bridge in hub mode (ageing_time 0), no physical port, a --capture-ifs interface fed by a bridge port, and that mirror end address-less (link-local included) | `--mgmt-if IF --capture-ifs "a b c"` (else SKIP: interfaces are never guessed) ; --lab-bridge BR (else SKIP: bridges are never guessed) | — | no |
| `virtualization` | a throwaway cirros guest: overlay, define, boot to `running`, destroy, undefine, overlay removed | libvirt (Phase 7), a cirros image under `/srv/vms/base` | `--allow-vm --lab-bridge BR` | self-cleaning (creates and destroys a guest) |
| `gns3` | unit active · `/v3/version` answers · admin login issues a token | Phase 8, the admin secret | — | no |
| `wan` | apply a 40 ms profile, measure, clear | Phase 12 tooling, which lives in the build repo's config repo, not this kit | `--allow-wan` | SKIPs with that reason today |
| `capture` | Zeek `capture_loss` below 0.5 % · optional replay: packets sent by `tcpreplay` into a feed | Malcolm running; a reference PCAP | `--feed IF --pcap FILE` | injects traffic into a capture feed |
| `backup` | restore one file from the latest restic snapshot and compare | Phase 15, `/etc/lab/secrets/restic.pw` | — | writes to a temp dir only |
| `airgap` | the posture report from `scripts/r770-airgap-check.sh`, folded in row by row | — | `--mgmt-cidr` judges resolvers | no |
| `portal` | each of the 3 `.lab` names answers over TLS with the lab CA · no redirect escapes to a loopback port · only nginx owns `0.0.0.0:443` | Phase 13 | — | no |

## What SKIPPED means

A check that cannot run reports SKIP with the reason — a tool not installed, a
phase not built, an opt-in flag not given, an interface not named. It is
listed in the report under its area and again under "SKIPPED". It is never
counted as a pass and never affects the exit code. A report with many SKIPs is
honest about an unfinished build; a report with none on a half-built box would
be lying.

## What a FAIL means

A FAIL drives exit 1 and carries a one-line diagnosis with the single most
likely next step. The suite never attempts a fix: fixing happens one change at
a time under the build repo's phase protocol, and the suite is rerun.

Two verdicts deserve a note:

- **Indexing lag is a WARN, not a FAIL.** On the rehearsal, Zeek logs existed
  on disk while the OpenSearch index was still empty half an hour later. The
  `arkime-count` row therefore asks you to compare in Arkime after the pipeline
  catches up rather than failing the capture area on a pipeline-throughput
  symptom.
- **A capture port with an address is a FAIL** whatever else is true. Capture
  ports never get an IP and never join the lab fabric.

## Mapping to the success criteria

Host · CPU/RAM · Storage · Network · Virtualization · GNS3 · WAN · Capture ·
Backup map one-to-one onto the areas above; `airgap` and `portal`
add the two properties the air gap and the portal integration introduced. The
GNS3 "one QEMU node + one Docker node pass traffic" check and the WAN
measurement are not automated by this kit and are SKIPPED with that reason;
run them by hand and record the result in the build repo's `state/inventory/`.

## Reading a report

```
| Check | Expected | Observed | Verdict | Evidence |
|---|---|---|---|---|
| mount /data/pcap | own mount point | mounted, 3.2T | PASS | findmnt -T /data/pcap |
```

The evidence column is the command whose output constitutes the observation.
Observed values are what the command printed, never a paraphrase.
