# What ends an Arkime session for a long-lived flow

Research for issue 28 (map: issue 22), 2026-11-18. Fact-finding only; no kit
code, doc or test was changed, and nothing here was run against a live Malcolm.

**Releases this answers for.** The Malcolm release is the one `MALCOLM_VER`
names in the pin block of `staging/r770-offline-fetch.sh`. That release's
Arkime image pins its Arkime release in `ARKIME_VERSION`
([Dockerfile, line 36][m-docker]). Versions are not restated here
(`tests/no-pins.bats` scans the whole tree); every source link below is a
permalink to the commit those two release tags point at:

- Malcolm: commit `f680217416121bdf9e04759302125c9fcf32c77c`
- Arkime: commit `e05bd95de562d8ab9526cf602b68afe4d1867e61`

## Answer in short

1. **The I5 theory holds, and the mechanism is specific to ESP.** With Arkime's
   defaults, an ESP flow gets **one** session record per in-memory session,
   covering at most its first `maxPackets` packets (10000 here). Everything
   after that is counted in memory and then discarded, not written. For TCP
   and UDP the same cap only *splits* the flow into linked records; nothing is
   lost.
2. **"A tunnel that was already up" is not the real condition.** Arkime keys
   an ESP session on the two IP addresses only, not the SPI, so a new IKE or
   CHILD SA does not start a new session. What starts one is a new capture
   process (in this kit: each PCAP file Arkime is handed) or 600 seconds
   without an ESP packet between that pair. A run's window holds an ESP
   record only if it overlaps the first 10000 ESP packets after one of those
   two events.
3. **It applies to uploads too, with a different symptom.** Each uploaded file
   is a separate capture process, so each file yields exactly one ESP record
   per address pair, covering the file's first 10000 ESP packets. The record
   exists (so a tag search finds it) but its packet and byte counts and its
   end time stop a few seconds into a high-rate run.
4. **The kit's `check` query is not the cause.** `bounding=either` is a true
   overlap test in this Arkime release.
5. **The setting that changes the behaviour is `espSavePackets`** (default
   false), not a timeout and not `maxPackets`.

## 1. What ends or splits a session (Arkime capture)

All settings are `[default]`-section keys of Arkime's `config.ini`.

| Limit | Key | Arkime default | Value in this Malcolm's `config.ini` | Effect |
|---|---|---|---|---|
| Packet cap | `maxPackets` | 10000 (allowed 1 to 65535) | 10000 | a record is written after this many packets since the last save ("mid-save"); the session stays in memory |
| TCP idle | `tcpTimeout` | 480 s | 600 s | session closed and written after this long with no packet |
| TCP periodic | `tcpSaveTimeout` | 480 s | 720 s | a record is written this long after the last save, active or not; TCP only |
| UDP idle | `udpTimeout` | 60 s | 30 s | closed and written |
| ICMP idle | `icmpTimeout` | 10 s | 10 s | closed and written |
| SCTP idle | `sctpTimeout` | 60 s | not set (60 s) | closed and written |
| ESP idle | `espTimeout` | 600 s (min 10) | not set (600 s) | closed and written |
| ESP tracked at all | `trackESP` | false | not set; the kit turns it on | without it there is no ESP session |
| ESP packet saving | `espSavePackets` | false | not set (false) | see section 2 |

Sources: defaults in [config.c lines 1290-1292 and 1323][a-config], and in each
parser's registration ([tcp.c][a-tcp], [udp.c][a-udp], [icmp.c][a-icmp],
[sctp.c][a-sctp], [esp.c lines 91-100][a-esp]); documented meanings in the
Arkime settings page source ([capture.yml][a-settings], rendered at
<https://arkime.com/settings>); Malcolm's values in its
[arkime/etc/config.ini][m-config] (lines 23, 36, 58-60; it has no `esp*`,
`sctpTimeout` or `trackESP` key).

How the limits act, from the source:

- **Idle timeout.** Each packet thread closes the oldest session of a protocol
  when `lastPacket + sessionTimeout < lastPacketSecs`
  ([session.c line 1211][a-session-timeout]). `lastPacketSecs` is the timestamp
  of the packet being processed ([packet.c line 239][a-packet-clock]); only
  live capture also advances it by wall clock (line 547). So when reading a
  file, timeouts run on packet time: a gap in the file longer than the timeout
  ends the session, and a short file never times anything out.
- **Packet cap.** After `maxPackets` packets, `arkime_session_mid_save` writes
  a record, zeroes the packet and byte counters and the packet-position list,
  and keeps the session ([packet.c lines 363-365][a-packet-cap],
  [session.c lines 848-895][a-midsave]). The records of one flow share a
  `rootId`, which the viewer uses to link segments. `firstPacket` is set only
  when the session is created ([packet.c line 263][a-packet-first]) and is not
  reset by a mid-save, so every later segment carries the original start time
  and its own `lastPacket`.
- **TCP periodic save.** Only sessions on the TCP write queue are mid-saved on
  `tcpSaveTimeout` ([session.c lines 1219-1228][a-session-timeout]). No other
  protocol has a time-based mid-save in this release. (The settings page says
  a per-protocol `[protocol-settings]` section with `packets:` and `save:`
  arrives in the next major release; it is not in this one.)
- **End of input.** When capture exits, every open session is flushed and
  written ([session.c lines 1351-1382][a-flush]). In offline mode that is the
  end of each file.

So a long-lived TCP or UDP flow becomes a chain of records of at most 10000
packets each (TCP also at least one per 720 s here). Nothing is dropped.

## 2. Why ESP is different

Three pieces of source combine:

1. **Session key.** The ESP parser builds the session id from source address,
   destination address, VLAN and VNI, with both ports zero
   ([esp.c lines 26-56][a-esp]). The SPI is not part of it. All SAs between two
   gateways, in both directions, across rekeys and re-initiations, are one
   session.
2. **Packet saving is off for ESP.** On a new ESP session, unless
   `espSavePackets` is true, the parser sets `session->stopSaving = 1`
   ([esp.c lines 64-68][a-esp]). Only the first packet's file position is
   recorded for the session ([packet.c lines 325-361][a-packet-cap]).
3. **A record with no packet positions is not written.** The save routine
   returns early when the position list is empty: `/* No Packets */ if
   (!config.dryRun && !session->filePosArray->len) return;`
   ([db.c lines 663-665][a-db]).

Sequence for one ESP flow: packet 1 is recorded with its position; packets
2 to 10000 are counted; at 10000 the mid-save writes one record (it has one
position, so it passes the guard), empties the position list and the caller
sets `stopSaving = 0` ([packet.c lines 372-375][a-packet-cap]). From then on
no packet adds a position, so every later mid-save and the final save hit the
"No Packets" guard and write nothing. The flow is recorded again only after
the in-memory session ends: 600 s with no ESP packet between the pair, or the
capture process exiting.

If the flow never reaches 10000 packets, its single record is written at the
idle timeout or at exit and covers the whole flow.

This matches what the rehearsal measured: the upload of a run with several
hundred thousand ESP packets showed "ESP 1" session, while udp/500 (ordinary
UDP, 30 s idle timeout, DPD gaps longer than that) showed 51
(`docs/rehearsals/2026-11-10-ipsec-wan.md`, row S1 X9).

## 3. Where this is set in a Malcolm deployment

- **`config.ini`.** Malcolm ships `arkime/etc/config.ini` inside the Arkime
  image ([file][m-config]). The limits above are plain keys in its `[default]`
  section.
- **Environment overrides.** Arkime capture reads every environment variable
  that starts `ARKIME_`: `ARKIME_<section>__<key>=<value>` overrides one key,
  and `ARKIME__<key>` means the default section
  ([config.c lines 1082-1101][a-config-env]). Malcolm's Arkime containers load
  `config/arkime.env`, so a line there reaches capture. This is how the kit
  already sets `ARKIME_default__trackESP=true` (`track_esp` in
  `scripts/r770-malcolm-deploy.sh`, re-applied after every installer run).
- **Malcolm's own knobs do not cover session limits.** The env examples
  ([arkime.env][m-env], [arkime-offline.env][m-env-off],
  [pcap-capture.env][m-env-pcap]) expose index rotation, PCAP management,
  `ARKIME_ROTATED_PCAP`, `ARKIME_AUTO_ANALYZE_PCAP_FILES` and netsniff rotation
  (`PCAP_ROTATE_MINUTES=10`, `PCAP_ROTATE_MEGABYTES=4096`), but none of
  `maxPackets`, the timeouts, `trackESP` or `espSavePackets`.
- **How files reach Arkime.** Malcolm's `pcap_processor.py` runs one
  `capture-offline --quiet ... -r <file> --node <name> --scheme -t <tag>...`
  per PCAP file ([lines 210-233][m-proc]); `capture-offline` is a copy of
  Arkime's `capture` binary ([Dockerfile line 195][m-docker-copy]). Uploads get
  `-upload` appended to the node name. Session state never carries from one
  file to the next.

## 4. How the kit asks, and why that is not the cause

`check` in `scripts/r770-scenario.sh` (`arkime_count`) calls Arkime's
`/api/sessions` with `expression`, `startTime`, `stopTime` (the run record's
window), `bounding=either` and `length=1`, and reads `recordsFiltered`. The
expression comes from `expect_arkime` in `scripts/lib/expect.sh`; for the ESP
rows of `scenarios/s1-w1-ss/expect.txt` it is
`ip.protocol == 50 && ((ip.src == A && ip.dst == B) || (ip.src == B && ip.dst == A && packets.dst > 0))`.

In this Arkime release `bounding=either` adds two filters:
`firstPacket <= stopTime` and `lastPacket >= startTime`
([buildQuery.js lines 378-381][a-bounding]). That is an overlap test, as the
kit's comment says. A record that spans the whole window is counted. The
query can only return 0 when no ESP record overlaps the window, which is what
section 2 produces.

The kit's Malcolm does not run Arkime as a live sniffer: netsniff writes
rotating PCAP files and Arkime indexes each closed file (comment above
`check_wait_secs` in `scripts/r770-scenario.sh`; `docs/deployment-runbook.md`).
So both paths, the live mirror and `ingest`, are "one capture process per
file".

## 5. The theory, tested

| Claim | Verdict |
|---|---|
| Arkime stops recording a long-lived ESP flow at its packet cap | **Holds**, for ESP only and only while `espSavePackets` is false. The cap is `maxPackets`; the loss comes from `stopSaving = 1` plus the "No Packets" guard. |
| So a later window holds no ESP session | **Holds on the live mirror**, with a correction: "later" is measured from the start of the PCAP file Arkime was handed (or from a 600 s ESP silence), not from when the tunnel came up. |
| A run meant for `check` should follow a fresh `up` | **Not supported by the source.** A fresh `up`, a new IKE SA or new SPIs do not start a new Arkime ESP session; `scenarios/s1-w1-ss/traffic.sh` already re-initiates the SA inside every run. A fresh `up` helps only by coincidence, when no ESP packets precede the run in the current netsniff file. |
| Same for uploaded PCAPs | **Partly.** The cap applies in full, but each file is its own capture process, so an upload always gets one ESP record per address pair starting at the file's first ESP packet. A search by tag or by the run's window finds it; its counts and `lastPacket` cover only the first 10000 ESP packets. |
| In a true live-capture Arkime (not this kit's mode) | The session survives as long as ESP packets are less than 600 s apart, so a busy tunnel would get one record for its first 10000 packets and then nothing, indefinitely. This is the reading closest to I5 as written. |

Likely reading of the increment-1 result (inference, not confirmed from
transcripts): the reference run at 14:35 passed because it held the first ESP
packets of its netsniff file; its iperf traffic at tens of Mbit/s used up
10000 ESP packets within seconds of whichever file was open afterwards, so
the flap run at 14:45 fell after the single ESP record of its file.

## 6. Options this opens for the follow-on decision

Not decided here.

- **A. Turn on `espSavePackets`** beside `trackESP`, by the same env override
  (`ARKIME_default__espSavePackets=true`). By the source, ESP sessions then
  keep their packet positions, so every 10000 packets writes a linked record
  and no part of the flow is unrecorded. Cost to measure on staging: about one
  ESP record per 10000 packets (several per second at lane-A rates) in the
  sessions index; in this kit's read-in-place mode no second copy of the PCAP
  should be written.
- **B. Leave Arkime as it is and change what the ESP rows mean**: document
  that the live view holds one ESP record per address pair per PCAP file, and
  have `check` judge ESP rows over a wider window, or treat a zero as WARN or
  SKIP with that reason.
- **C. Move the ESP proof off the live window**: the run's own capture
  already proves ESP (`pcap-expect.txt` row X3 via `verify`), and an ingested
  run always has its ESP record under the run's tags.
- **D. Make the run start on a fresh PCAP file**: force a netsniff rotation
  just before the window. Netsniff rotates only once `PCAP_ROTATE_MINUTES` has
  passed, so this needs a wait or a lower rotation period; it also leaves the
  record covering only the first seconds of the run.
- **E. Reword I5 only**: the cause is the per-file ESP record and the packet
  cap, not tunnel age; "follow a fresh `up`" is not a dependable remedy.

Raising `maxPackets` is not an option: the ceiling is 65535, the settings page
says only 10000 is tested, and it would only move the edge by seconds.

## 7. Unconfirmed

- **Nothing was measured.** Every statement about behaviour comes from reading
  source at the two commits above. The effect of `espSavePackets=true` in
  Malcolm's offline mode (record count, index growth, whether packets open in
  the viewer) is untested.
- **Why one run passed and the next failed** in increment 1: the netsniff file
  boundaries for 2026-11-10 are in evidence archives outside the repo and were
  not read.
- **The actual `PCAP_ROTATE_MINUTES`** on VM 9770 was not read; 10 is Malcolm's
  example default and what the kit's comment records as measured.
- **Whether Malcolm's entrypoint scripts rewrite `config.ini` keys** at
  container start was not checked; only the shipped `config.ini` and the env
  examples were read. None of the session-limit keys appears in the env
  examples.
- **That the shipped Arkime package matches the tagged source** is assumed
  from the Dockerfile's download URL.
- **Zeek and Suricata** were not examined; the kit's ESP rows rely on Arkime's
  own session records.
- **Segment start times**: that mid-saved TCP and UDP records all carry the
  flow's original `firstPacket` is read from the source and was not checked
  against a live index.

[m-docker]: https://github.com/idaholab/Malcolm/blob/f680217416121bdf9e04759302125c9fcf32c77c/Dockerfiles/arkime.Dockerfile#L36
[m-docker-copy]: https://github.com/idaholab/Malcolm/blob/f680217416121bdf9e04759302125c9fcf32c77c/Dockerfiles/arkime.Dockerfile#L195
[m-config]: https://github.com/idaholab/Malcolm/blob/f680217416121bdf9e04759302125c9fcf32c77c/arkime/etc/config.ini
[m-env]: https://github.com/idaholab/Malcolm/blob/f680217416121bdf9e04759302125c9fcf32c77c/config/arkime.env.example
[m-env-off]: https://github.com/idaholab/Malcolm/blob/f680217416121bdf9e04759302125c9fcf32c77c/config/arkime-offline.env.example
[m-env-pcap]: https://github.com/idaholab/Malcolm/blob/f680217416121bdf9e04759302125c9fcf32c77c/config/pcap-capture.env.example
[m-proc]: https://github.com/idaholab/Malcolm/blob/f680217416121bdf9e04759302125c9fcf32c77c/shared/bin/pcap_processor.py#L210-L233
[a-esp]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/parsers/esp.c#L26-L100
[a-tcp]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/parsers/tcp.c#L572-L579
[a-udp]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/parsers/udp.c#L109
[a-icmp]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/parsers/icmp.c#L152
[a-sctp]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/parsers/sctp.c#L435
[a-config]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/config.c#L1290-L1323
[a-config-env]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/config.c#L1082-L1101
[a-packet-clock]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/packet.c#L239
[a-packet-first]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/packet.c#L261-L263
[a-packet-cap]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/packet.c#L325-L377
[a-midsave]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/session.c#L848-L895
[a-session-timeout]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/session.c#L1200-L1228
[a-flush]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/session.c#L1351-L1382
[a-db]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/capture/db.c#L663-L665
[a-bounding]: https://github.com/arkime/arkime/blob/e05bd95de562d8ab9526cf602b68afe4d1867e61/viewer/buildQuery.js#L378-L381
[a-settings]: https://github.com/arkime/arkimeweb/blob/5e561ef1049f7cfdc47c6f443d616ef87740c506/_data/settings/capture.yml
