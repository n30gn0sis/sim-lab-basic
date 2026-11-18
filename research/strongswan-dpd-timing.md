# When strongSwan's DPD gives up (IKEv2, swanctl)

Research for wayfinder ticket #30 (map #22). Date: 2026-11-18. Fact-finding
only: nothing here was run against the lab; every claim is from strongSwan's
documentation or source, or from this repo's files, and says which.

**Sources.** "docs" = docs.strongswan.org (latest). "source" = the strongSwan
repository at commit `4d709df8b25fcf3cacb55cb4f28ab81014829ab1`, which is what
the upstream release tag named by the kit's `STRONGSWAN_IMG` pin
(`staging/r770-offline-fetch.sh`) resolves to. Source links below are
permalinks to that commit.

- [D1] swanctl.conf reference: <https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html>
- [D2] Retransmission: <https://docs.strongswan.org/docs/latest/config/retransmission.html>
- [D3] strongswan.conf reference: <https://docs.strongswan.org/docs/latest/config/strongswanConf.html>
- [S1] `task_manager_v2.c` (`retransmit`, `process_message`, `busy`): <https://github.com/strongswan/strongswan/blob/4d709df8b25fcf3cacb55cb4f28ab81014829ab1/src/libcharon/sa/ikev2/task_manager_v2.c>
- [S2] `task_manager.c` (`retransmission_parse_default`, `retransmission_timeout`): <https://github.com/strongswan/strongswan/blob/4d709df8b25fcf3cacb55cb4f28ab81014829ab1/src/libcharon/sa/task_manager.c>
- [S3] `task_manager.h` (default macros and the schedule table): <https://github.com/strongswan/strongswan/blob/4d709df8b25fcf3cacb55cb4f28ab81014829ab1/src/libcharon/sa/task_manager.h>
- [S4] `ike_sa.c` (`send_dpd`, `get_use_time`, `retransmit`, `reestablish`, `destroy`): <https://github.com/strongswan/strongswan/blob/4d709df8b25fcf3cacb55cb4f28ab81014829ab1/src/libcharon/sa/ike_sa.c>
- [S5] `retransmit_job.c`: <https://github.com/strongswan/strongswan/blob/4d709df8b25fcf3cacb55cb4f28ab81014829ab1/src/libcharon/processing/jobs/retransmit_job.c>
- [S6] `vici_config.c` (`parse_action`): <https://github.com/strongswan/strongswan/blob/4d709df8b25fcf3cacb55cb4f28ab81014829ab1/src/libcharon/plugins/vici/vici_config.c>
- [S7] `ike_auth.c` (INITIAL_CONTACT): <https://github.com/strongswan/strongswan/blob/4d709df8b25fcf3cacb55cb4f28ab81014829ab1/src/libcharon/sa/ikev2/tasks/ike_auth.c>

The source files were read through a fetch tool that summarises; the code
fragments quoted here were returned by it as code, but line-exact wording was
not checked against a local checkout.

## The answer in short

In IKEv2, `dpd_delay` only decides **when a liveness probe is sent**. How
long charon then waits before declaring the peer dead is the ordinary IKE
**retransmission schedule**, a daemon-wide `strongswan.conf` setting, not a
connection setting. With the defaults that is **165 s** after the probe was
first sent. So with `dpd_delay = 10s` the peer is declared dead **165 to
175 s after it went silent**, and the last packet charon sends before that is
at **about 89 to 99 s**. A 30 s outage is nowhere near either, which is
finding I6.

## 1. What `dpd_delay` does in IKEv2

- Docs [D1]: "Interval to check the liveness of a peer actively using IKEv2
  INFORMATIONAL exchanges or IKEv1 R_U_THERE messages." and "Active DPD
  checking is only enforced if no IKE or ESP/AH packet has been received for
  the configured DPD delay". Default `0s` (no active probing).
- Source [S4] `send_dpd`: a `send_dpd_job` runs per IKE SA. Each time it
  fires it computes `diff` = now minus the last inbound time. If
  `diff >= delay` it queues an empty INFORMATIONAL request (the probe) and
  reschedules itself `delay` later; otherwise it reschedules itself
  `delay - diff` later. If another exchange is already in flight
  (`task_manager->busy()`), it sends nothing: "an exchange is in the air, no
  need to start a DPD check" — that exchange's own retransmissions are the
  liveness check.
- **Docs and source differ on ESP.** In the source [S4] `get_use_time` takes
  the IKE SA's own inbound timestamp and only folds in CHILD_SA (ESP) usage
  when the SA has a NAT condition (`COND_NAT_ANY`). The IKE timestamp is
  updated in [S1] `process_message` for processed requests, responses and
  retransmitted requests. So **without NAT, received ESP traffic does not
  postpone the probe**: a probe goes out every `dpd_delay` seconds after the
  last IKE message, traffic or not. The docs sentence does not mention this
  condition. Not checked against a capture (see Unconfirmed).

Consequence for timing: after the path breaks, the first unanswered probe is
sent between 0 and `dpd_delay` seconds later (0 to 10 s for the kit's config),
depending on where in the cycle the cut lands. Timestamps and the job are in
whole seconds, so expect about one second of slack.

## 2. Why `dpd_timeout` does not apply

Docs [D1], `connections.<conn>.dpd_timeout` (default `0s`): "Charon by default
uses the normal retransmission mechanism and timeouts to check the liveness of
a peer", "For compatibility reasons, with IKEv1 a custom interval may be
specified. This option has no effect on IKEv2 connections". In IKEv2 every
request must be answered, so an unanswered probe is just an unanswered
request; there is no separate DPD timer to configure.

## 3. The retransmission schedule that decides it

Settings, all in the `charon` section of `strongswan.conf` [D2] [D3], read in
[S2] `retransmission_parse_default` with defaults from [S3]:

| Key | Default | Meaning |
|---|---|---|
| `charon.retransmit_timeout` | 4.0 | seconds before the first retransmit |
| `charon.retransmit_base` | 1.8 | base of the exponential back-off |
| `charon.retransmit_tries` | 5 | retransmits before giving up |
| `charon.retransmit_jitter` | 0 | max percent subtracted at random from each wait (source caps it at 20) |
| `charon.retransmit_limit` | 0 | upper bound in seconds on each wait (0 = none) |

Formula [D2] [S2]: wait after transmission n (n = 0 for the original) =
`retransmit_timeout * retransmit_base ^ n`, capped by `retransmit_limit` if
set, then reduced by a random 0 to `retransmit_jitter` percent.

Give-up rule [S1] `retransmit`: the counter starts at 0; each firing sends and
increments; when it fires with `retransmitted > tries` it logs "giving up
after %d retransmits" and returns `DESTROY_ME`. So the original plus `tries`
retransmits are sent, and give-up comes one more wait after the last one.

Default schedule (docs table [D2], same table in [S3]; exact values computed
from the formula):

| Event | Wait before it | Time since the probe was first sent |
|---|---|---|
| probe sent | — | 0 |
| retransmit 1 | 4 s | 4 s |
| retransmit 2 | 7.2 s | 11.2 s |
| retransmit 3 | 12.96 s | 24.16 s |
| retransmit 4 | 23.33 s | 47.49 s |
| retransmit 5 (the last packet) | 41.99 s | 89.48 s |
| **give up** | 75.58 s | **165.06 s** |

Closed forms, with t = timeout, b = base, n = tries, no jitter or limit:

- last packet sent at `T_last = t * (b^n - 1) / (b - 1)`
- give-up at `T_giveup = t * (b^(n+1) - 1) / (b - 1)`

The settings are per daemon, not per connection, and apply to every IKE
exchange: IKE_SA_INIT, IKE_AUTH, CREATE_CHILD_SA (rekeys) and INFORMATIONAL
alike. A rekey request that goes unanswered gives up on the same schedule.
They are read when an IKE SA's task manager is created [S1] [S2], so a change
affects IKE SAs created afterwards.

## 4. What is on the wire

**While waiting.** Retransmits resend the stored packets [S1]: the same
encrypted INFORMATIONAL request, same IKE SPIs, **same message ID**, on
udp/500 (no NAT, `mobike = no`), at the times in the table.

**Link returns before give-up.** Two cases:

- *Before the last retransmit has been sent:* the next retransmit reaches the
  peer, the peer answers, the response's message ID matches, the exchange
  completes [S1]. **The same IKE SA simply continues** — same SPIs, message
  IDs carry on, no IKE_SA_INIT, CHILD_SAs untouched. On the wire the outage
  shows as a run of identical INFORMATIONAL requests with widening gaps and
  then one response. This is what the I6 run recorded.
- *After the last retransmit but before give-up:* nothing more is sent for
  that request, and a response to it can no longer arrive, so that side still
  gives up on schedule even though the link is back (it will still answer the
  peer's requests meanwhile). Inferred from [S1]; there is no code path that
  cancels a pending give-up on other inbound traffic.

**At give-up.** [S5] the retransmit job calls `ike_sa->retransmit`; on
`DESTROY_ME` it destroys the IKE SA. [S4] `retransmit`, for an established
SA, first calls `reestablish`. `destroy` removes the CHILD_SAs locally and
**sends no DELETE** — the peer is presumed dead, so the old SA vanishes from
the wire without a goodbye.

What `reestablish` does depends on each CHILD_SA's `dpd_action` [S4]. swanctl
maps the words to flags in [S6] `parse_action`: `restart` and `start` are
`ACTION_START`, `trap` and `route` are `ACTION_TRAP`, `clear` and `none` are
`ACTION_NONE`.

| `dpd_action` | Docs [D1] | On the wire after give-up |
|---|---|---|
| `clear` (default) | "closes the CHILD_SA and does not take further action" | nothing. If a trap policy is installed (`start_action` includes `trap`), the next matching packet triggers a new negotiation |
| `trap` | "installs a trap policy, which will catch matching traffic and tries to re-negotiate the tunnel on-demand" (redundant if `start_action` includes `trap`) | nothing until matching traffic; then a new IKE_SA_INIT |
| `restart` | "immediately tries to re-negotiate the CHILD_SA under a fresh IKE_SA" | immediately: a **new IKE_SA_INIT** |

For `restart`, [S4] creates a brand-new IKE SA
(`ike_sa_manager->create_new(..., TRUE)`, i.e. as initiator), gives it the
same peer config and addresses, and queues a child-create for every child
whose action includes start. So the wire shows IKE_SA_INIT with a **new
initiator SPI**, responder SPI zero, message ID 0; then IKE_AUTH carrying the
child; then ESP under **new SPIs**. It is a full new negotiation, not a
resumption.

Further points that follow from the source:

- The new IKE_SA_INIT is itself subject to the same retransmission schedule.
  If the link is still down it is retransmitted at 4, 11.2, 24.16 … s and
  abandoned after 165 s; `keyingtries` (default 1 [D1]: "Number of
  retransmission sequences to perform during initial connect") decides
  whether another sequence follows [S4]. After that only a trap policy, if
  installed, brings the tunnel back.
- `reestablish` also restarts if a child-creating task (for example a CHILD
  rekey) was queued when the SA died [S4].
- INITIAL_CONTACT: the initiator adds it to IKE_AUTH when the remote identity
  has no wildcards, the uniqueness policy is not `never`, and no other IKE SA
  with the same identities exists [S7]. Docs [D1] for the default `unique =
  no`: it "replaces existing connections for the same identity if a new one
  has the INITIAL_CONTACT notify". So a peer that still holds the old SA
  should drop it when the new one authenticates (not traced end to end; see
  Unconfirmed).

**`close_action`** [D1]: "Action to perform after a CHILD_SA gets closed by
the peer", default `none`; values `none`, `trap`, `start`. It reacts to an
explicit close (a DELETE from the peer), not to silence, and the docs warn it
"does not provide any guarantee that the CHILD_SA is kept alive". It plays no
part in a DPD timeout: `reestablish` consults the close action only when the
IKE SA is already in the deleting state, the DPD action otherwise [S4].

**`start_action = trap`** [D1]: installs a trap policy when the config is
loaded, so the first matching packet triggers negotiation. The policy is
independent of any SA, so it also re-triggers negotiation after an SA has
been lost, whatever `dpd_action` says.

## 5. Shortening the give-up time for a lab

Only the `charon.retransmit_*` keys do it; `dpd_delay` only moves the first
probe. They go in `strongswan.conf` or a file it includes. The kit's node
scripts already write a top-level `charon { ... }` section to
`/etc/strongswan.d/gt-log.conf` before starting charon
(`scenarios/s1-w1-ss/nodes/gw-a.sh`), and that file demonstrably took effect
in staging (installer-acceptance finding A5), so the same mechanism would
carry `charon { retransmit_tries = …  retransmit_timeout = …  retransmit_base
= … }`. Runtime reload exists (`swanctl --reload-settings` or SIGHUP [D3]) but
is not needed if the file is written before charon starts.

Worked examples from the closed forms (no jitter, no limit; add the 0 to
`dpd_delay` seconds before the first probe):

| tries / timeout / base | last packet (`T_last`) | give-up (`T_giveup`) |
|---|---|---|
| 5 / 4.0 / 1.8 (default) | 89.48 s | 165.06 s |
| 3 / 2.0 / 1.8 | 12.08 s | 23.74 s |
| 2 / 2.0 / 1.5 | 5 s | 9.5 s |
| 2 / 1.0 / 2.0 | 3 s | 7 s |

Side effects to weigh:

- The same numbers govern every exchange on that daemon, including the
  restart's own IKE_SA_INIT. A very short schedule that gives up *inside* the
  outage means the restart attempt is sent into the dead link and is itself
  abandoned after `T_giveup` (with `keyingtries` at its default of 1); the
  tunnel then returns only through the trap policy on the next traffic.
- A short schedule also makes rekeys less tolerant of an impaired WAN profile
  (loss, delay) applied in the same run.
- Each gateway has its own daemon and its own settings; both of the kit's
  gateways have `dpd_action = restart`, so both act.

## 6. The kit's `s1-w1-ss`, exactly

Read from `scenarios/s1-w1-ss/`:

- `nodes/gw-a.swanctl.conf`, `nodes/gw-b.swanctl.conf`: `version = 2`,
  `mobike = no`, `dpd_delay = 10s` on both; child `s1-net` has `dpd_action =
  restart` on both; `start_action = trap|start` on gw-a, `trap` on gw-b; IKE
  `rekey_time = 600s`, child `rekey_time = 120s`. No `dpd_timeout`, no
  `keyingtries`, no `unique` (defaults).
- `nodes/gw-a.sh`, `nodes/gw-b.sh`: the only `strongswan.conf` content they
  write is the `filelog` section and (if the plugin exists) `save-keys`.
  **No `retransmit_*` key anywhere in the repo**, so the defaults apply
  (unless the image's own `strongswan.conf` sets them — not inspected).
- `events/wan-flap.txt`: `link-down|b` at 90 s, `link-up|b` at 120 s: a 30 s
  outage. `scenario.conf`: `traffic_secs=240`, `idle_secs=40`.

Computed for that config (defaults 4.0 / 1.8 / 5, `dpd_delay` 10 s, d = the
0 to 10 s between the cut and the first unanswered probe):

| Quantity | Time after the cut |
|---|---|
| first unanswered probe | d = 0 to 10 s |
| last packet of the old SA (retransmit 5) | 89.48 + d = **89.5 to 99.5 s** |
| give-up and new IKE_SA_INIT | 165.06 + d = **165 to 175 s** |

- **Minimum outage that forces a restart: about 100 s** (strictly: longer
  than 89.48 s + d on a given gateway). An outage of **under about 89.5 s
  cannot** produce one; between 89.5 and 99.5 s it depends on where each
  gateway's 10 s probe cycle was when the link dropped, and the two gateways
  can differ; **from about 100 s up both gateways give up**. Allow a second or
  two of margin for the whole-second timers.
- The restart itself appears **165 to 175 s after the cut**, regardless of
  whether the link came back at 100 s or is still down. If the link is back,
  the new IKE_SA_INIT is answered at once; if not, it is retransmitted on the
  same schedule.
- Against the current events file: cut at t = 90 s gives a restart at
  t = 255 to 265 s — after the 240 s traffic window, inside the 40 s idle
  tail — and only if `link-up` moves from 120 s to about 190 s or later.
- Why I6 saw no restart: with the link back at 30 s, the old SA's retransmit 3
  (24.16 s + d after the cut) or retransmit 4 (47.49 s + d) got through and
  was answered. Same IKE SA, same SPIs, exactly as recorded
  (`docs/rehearsals/2026-11-10-ipsec-wan.md`, row "S1 flap").
- Since both gateways restart, expect up to two new IKE_SA_INITs, one from
  each side, a few seconds apart; how the duplicate settles was not traced.

## Unconfirmed

- **Nothing was measured.** All timings are computed from docs and source;
  no run on staging VM 9770 confirms them.
- That the charon inside the pinned image is built from exactly the commit
  read here, and that the image's default `strongswan.conf` sets no
  `retransmit_*` key and includes `/etc/strongswan.d/*.conf` at top level
  (A5 is indirect evidence for the include).
- The docs/source difference on ESP traffic and DPD (section 1): the source
  reading says probes go out every 10 s under traffic when there is no NAT;
  the kit's captures could settle it but are not in the repo.
- That a link-down on side b's TAP silences IKE in both directions for both
  gateways (assumed from the topology; I6 is consistent with it).
- How the two simultaneous restarts (both ends have `dpd_action = restart`)
  resolve: one surviving IKE SA or two, and whether INITIAL_CONTACT is sent
  by the restarted SA in this exact sequence.
- The exact trigger path of `close_action` on a peer's DELETE (docs only; the
  child-delete task was not read).
- Line-exact wording of quoted source (read through a summarising fetch).
