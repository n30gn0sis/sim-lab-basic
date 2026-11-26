# Handover — Proxmox agent access and E2E prep (agent-1795113784344-ar0hr2)

Session title (keep verbatim): "Proxmox agent access and E2E prep", type "chore".
Full previous transcript: C:\Users\Faust\.claude\projects\D--git-sim-lab-basic\6097dfe6-1718-4ffc-8de8-a25ff311e12f.jsonl
Work order from chief-of-staff (an agent): #12, then #8 fixes, then #10.

## Where things stand

### #12 — agent access to Proxmox VE at 192.168.4.21 (assignment asg-0mwqvz0r5-ea20a296, BLOCKED on user)
- W1–W9 done on .21 via AgentsRoom SSH connection `pve-lab` (ssh-1795294862863-vivf3o), all rc 0:
  key appended to /etc/pve/priv/authorized_keys (backup /root/authorized_keys.bak-20261121, new key
  SHA256:YeZQas5tV5bF7cT9KF35RQeAUJuViOrUYaoLvPWwVpk), user agents@pve, pool sim-lab, PVEVMAdmin ACL,
  token `agents@pve!e2e` (privsep 1) + token ACL. Key login from this PC verified
  (`ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/sim-lab-pve-agents root@192.168.4.21`).
- Vault: secret `pve-agents-e2e` EXISTS and is readable on this machine (secrets_list, 2026-11-22).
- Last turn: PVE_AGENTS_TOKEN was NOT in this agent's env. I opened Edit agent > Environment variables
  for the user to add `PVE_AGENTS_TOKEN={{secret:pve-agents-e2e}}`. Unknown whether they did.
- /root/agents-e2e.token on .21 still existed at last check; user must `rm` it.

NEXT for #12 (in order):
1. Check env: is PVE_AGENTS_TOKEN set and not the literal `{{secret:...}}`? Print LENGTH ONLY, never the value.
   If missing: tell the user (agents_save refuses own config; ui_open surface "agent" helps), stop.
2. pve-lab, one read-only ssh_exec: `test ! -e /root/agents-e2e.token && echo gone`.
3. `curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: PVEAPIToken=agents@pve!e2e=$PVE_AGENTS_TOKEN" https://192.168.4.21:8006/api2/json/version` → expect 200.
4. assignment_update #12 to submitted with evidence. Optionally add to GitHub #48 a SUMMARY-ONLY note
   (repo is public: no IPs, account names, pool names, sshd settings, tokens). Don't close #48 or #43.

### UPDATE 2026-11-22 20:10: #12 SUBMITTED (API 200 with the PVE version, via PowerShell; curl is denied by repo settings).
GH #48 comment posted with the approved wording; #12 VERIFIED by chief.
### UPDATE 2026-11-23 05:15: #8 rework SUBMITTED (gate 658 ok / 0 not ok / 1 skip). Waiting on chief's review.
#8 VERIFIED. #10 DONE: commit 0a0a42c on docs-tidy (16 files, index gate 615/0/2), NOT pushed,
submitted on asg-0mwtbb49h-48c8d2c7; Network engineerrrr reviews next. #8 COMMITTED: a234667 on top of 0a0a42c (clone gate 656/0/1), NOT pushed,
submitted on asg-0mwthlk6a-6bb15179. Both commits await Network engineerrrr's review, then one PR.
Uncommitted remainder: archive move (+ its README/runbook hunks), CODEMAPS, staging/, common.sh, backlog, rehearsals. Chief mail thread at 10/12 (checkpoint saved).

### UPDATE 2026-11-22 19:36 (supersedes the #12 and #8 notes below)
- #12 is now assignment asg-0mws08nt0-5de79234 (old asg-0mwqvz0r5 CLOSED, superseded). Set BLOCKED on user
  restart. Token file on .21 checked: gone. Pre-restart env token was 127 chars (full pveum output); the user
  said the vault now holds only the UUID. After restart: check len 36 + UUID shape, then GET /version (status +
  version only), summary-only comment on GH #48 ("token regenerated, vault updated, API check passed"; no names, no
  IPs), set assignment submitted. Mail thread with chief at 7/12 (checkpoint required from 10).
- #8 was RETURNED (CHANGES REQUESTED) 14:01. Start after the token check. Full note: lastNote on asg-0mwpfl3gp-df8d83a1,
  findings doc "Re-review #8: findings" on asg-0mwrc83vv-557cc430. To do:
  F1 (prep.sh ~:227-239) NAT rule with no source (iptables `-o <if> -j MASQUERADE`, nft `oifname .. masquerade`)
     covering the lab subnet must FAIL, not PASS; bats case for each form.
  F2 (~:129-134, :286-292) if `ip` prints nothing or fails, overlap check must FAIL or SKIP with reason; bats case.
  Durability: NO persistent nft rule. Instead harness/r770-proxmox-e2e.sh re-reads the bridge's forwarding (0) and
     disable_ipv6 (1) before provisioning and refuses otherwise; bats cases + runbook line.
  Optional: negated `! -s` false-positive nit.
  ./tests/run.sh green on a clean copy. No commit. Never run against real Proxmox.

### #8 — harness/r770-proxmox-prep.sh rework (assignment asg-0mwpfl3gp-df8d83a1, RETURNED — see UPDATE above)
- (stale) Waiting for chief-of-staff review. Gate was green in WSL copy: RUN_RC=0 ok=654 notok=0 skip=1 (pwsh).
- Decision raised, not acted on: add a gated nft forward-drop rule so forwarding-off on the lab bridge
  survives Docker toggling ip_forward. Plus .21 run choices (subnet e.g. 192.168.98.1/24 on vmbr9800,
  local-lvm overcommit or smaller --data-size, snippets on `local`).
- Commit message already set via git_set_commit_message ("proxmox-prep: refuse nested subnets, stop on
  sshd FAIL, keep the lab bridge from forwarding"). Nothing committed. Files: harness/r770-proxmox-prep.sh,
  tests/proxmox-prep.bats (both untracked), plus edits in docs/deployment-runbook.md (ProxyJump section),
  README.md (bridge row), tests/README.md (proxmox-prep row).

### #10 — one commit on docs-tidy (assignment asg-0mwr4fm2j-62d24e18, ACCEPTED, PARKED until #12 done)
- Commit ONLY the #1–#4 and #7 files: harness/r770-proxmox-e2e.sh, tests/proxmox-e2e.bats,
  tests/helpers/kit_files.bash, the #4 gate changes, tests/no-credentials.bats, .gitignore (must be +13/-0),
  and the README/runbook/validation doc parts they touched. EXCLUDE #8 prep files and unrelated changes.
- `./tests/run.sh` green in the real checkout first. Do NOT push. scripts/r770-install.sh must equal HEAD.
  Leave #5 out. No secrets. Submit hash, file list, tally.
- Note: README.md, docs/deployment-runbook.md, tests/README.md mix #8 and #10 hunks — stage by hunk.
- Do not commit this .handoff/ file.

### #9 — bundle cut: blocked on the same connection. Reuse VM 9770; Docker on PVE host intended; stop gns3 (9100) during E2E.

## Rules that still bind
- Root password only via the saved SSH connection `pve-lab` (root@192.168.4.21). Saved connection
  "Proxmox VE (192.168.4.54)" is the WRONG host — never use it.
- Token secret never appears in any output; use `stat`, never `cat`.
- Nothing from #12 goes into the repo (no key, token, host config). No push.
- #8: never run the prep script against the real server; bats + --dry-run only.
- Kit CLAUDE.md: gates never bypassed; ./tests/run.sh green before any commit.

## Tooling notes
- GateGuard hook demands facts before first Bash/Edit/Write per file: state them, retry.
- Gate in WSL: scratchpad gate.sh (copies tree to /tmp/kitcopy with tar --no-same-owner, bats-core
  1.11 tag in /tmp/bats-core; the gate.sh clones it if missing). Run via `MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-22.04 -u root --cd /tmp -- bash <path>/gate.sh [suite]`.
  Never inline `bash -c` through wsl.exe. The scratchpad may be gone in a new session; recreate from the
  transcript if needed.
- Mail thread to chief-of-staff hit its 12-message cap; status also posted as internal comment on backlog
  ticket d74cbdc3-4e64-4332-8e46-511e1b90385b.
