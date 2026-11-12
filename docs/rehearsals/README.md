# Rehearsal records

One file per rehearsal: `<date>-<name>.md`. A record is the claim; the
transcripts are the evidence, and they stay out of git. Nothing is written
here without the transcript that shows it.

## What every record holds

1. **Header** — date, VM (hypervisor and id), bundle id, kit commit (the
   bundle's `kit/KIT_COMMIT`), who ran it.
2. **Stand-ins** — everything that differs from the real R770, each with why:
   the media, the storage volumes, where the bundle was cut, anything
   pre-installed.
3. **Steps** — one row per step:

   | Step | Expected | Observed | Verdict | Transcript |
   |---|---|---|---|---|

   Verdict is `PASS`, `WARN`, `FAIL` or `SKIP`. `Transcript` is the file name
   under the evidence archive. A step with no transcript has no verdict.
4. **Findings** — each WARN and FAIL: the one hypothesis, the one change, the
   commit, the bundle the fix first shipped in, the rerun's verdict.
5. **Not exercised** — what this rehearsal did not prove, by name.
6. **Evidence** — where the archive of `r770-evidence/` and the run
   directories is kept.

Screenshots sit in a directory beside the record, named for it. Look at each
before committing: none may show a credential.

Driving the VM: `harness/r770-staging-vm.sh`.
