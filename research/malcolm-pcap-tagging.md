# How Malcolm tags an uploaded PCAP

Research for issue 26 (map: issue 22). Fact-finding only; no decision is made here.

- **Release answered for:** Malcolm `26.08.0`, the value of `MALCOLM_VER` in the pin
  block of `staging/r770-offline-fetch.sh`. That release builds its Arkime image from
  Arkime `6.7.0` ([`Dockerfiles/arkime.Dockerfile` L36](https://github.com/idaholab/Malcolm/blob/v26.08.0/Dockerfiles/arkime.Dockerfile#L36)).
- **Sources:** upstream source and docs read at tag `v26.08.0` of `idaholab/Malcolm`
  (the repository the kit fetches from) and tag `v6.7.0` of `arkime/arkime`.
  Nothing here was run against a live Malcolm; the one executed check is the
  upstream splitting function run verbatim on the kit's file names (section 2).
- **Date:** 2026-11-18.

## 1. Short answer

Malcolm, not Arkime, does the splitting. The `pcap-monitor` container derives the
tag list from the file name with one regular expression, splitting on the five
characters `,` `-` `.` `/` `_`, and hands each piece to Arkime's `capture` as a
separate `-t <tag>`. Arkime adds each `-t` value to every session verbatim.

There is **no per-upload way in this release to hand Malcolm an explicit tag that
contains one of those five characters**: the upload form's tag field is itself
turned into a file-name prefix and goes through the same splitter. A run id
survives as one tag only if it contains none of the five characters. The other
routes to an unbroken `s1-w1-ss-20261110T1435Z` are a global static variable
(`EXTRA_TAGS`), or tagging the sessions in Arkime after ingest.

## 2. The splitting rule and where it lives

`tags_from_filename()` in
[`shared/bin/pcap_utils.py` L24-L29](https://github.com/idaholab/Malcolm/blob/v26.08.0/shared/bin/pcap_utils.py#L24-L29):

```python
def tags_from_filename(filespec):
    # split tags on these characters
    tagSplitterRe = "[,-/_.]+"
    # tags to ignore explicitly
    regex = re.compile(r'^(\d+|p?cap|dmp|log|bro|zeek|suricata|m?tcpdump|m?netsniff)$', re.IGNORECASE)
    return list(filter(lambda i: not regex.search(i), map(str.strip, filter(None, re.split(tagSplitterRe, filespec)))))
```

- Inside the character class, `,-/` is a **range** from `,` (0x2C) to `/` (0x2F),
  which is `,` `-` `.` `/`; `_` and `.` are then listed. The splitter set is
  therefore exactly `,` `-` `.` `/` `_`. This is why `.` splits, although the
  documentation names only comma, dash and underscore
  ([`docs/upload.md` "Tagging"](https://github.com/idaholab/Malcolm/blob/v26.08.0/docs/upload.md#tagging)).
- After splitting: empty pieces are dropped, each piece is whitespace-trimmed, and
  a piece is discarded if it is all digits or is one of `pcap`, `cap`, `dmp`,
  `log`, `bro`, `zeek`, `suricata`, `tcpdump`, `mtcpdump`, `netsniff`,
  `mnetsniff` (case-insensitive). `pcapng` is not in that list, so it becomes a tag.
- The whole relative path including the extension is split; case is preserved.

Run verbatim on the kit's names, it reproduces finding I4 of
`docs/rehearsals/2026-11-10-ipsec-wan.md` exactly:

| File name | Tags |
|---|---|
| `s1-w1-ss-20261110T1435Z,outer.pcapng` | `s1` `w1` `ss` `20261110T1435Z` `outer` `pcapng` |
| `s1-w1-ss-20261110T1435Z,inner-gw-a.pcapng` | `s1` `w1` `ss` `20261110T1435Z` `inner` `gw` `a` `pcapng` |
| `s1w1ss20261110T1435Z,innergwa.pcapng` | `s1w1ss20261110T1435Z` `innergwa` `pcapng` |
| `s1+w1+ss+20261110T1435Z,inner+gw+a.pcapng` | `s1+w1+ss+20261110T1435Z` `inner+gw+a` `pcapng` |

### The path a dropped file takes

1. **Upload watcher** (`pcap-monitor`, program `watch-upload`):
   [`pcap-monitor/scripts/watch-pcap-uploads-folder.py`](https://github.com/idaholab/Malcolm/blob/v26.08.0/pcap-monitor/scripts/watch-pcap-uploads-folder.py)
   watches `<pcap>/upload`, chowns the file, checks its libmagic type and size, and
   moves a PCAP to `<pcap>/processed` under its **unchanged base name** (L62-L78).
   It does no tagging. It is started without `--recursive`
   ([`pcap-monitor/supervisord.conf` L21-L30](https://github.com/idaholab/Malcolm/blob/v26.08.0/pcap-monitor/supervisord.conf#L21-L30)),
   so subdirectories of `upload/` are not watched.
2. **Publisher** (`pcap-monitor`, program `pcap-publisher`):
   [`shared/bin/pcap_watcher.py` L238-L249](https://github.com/idaholab/Malcolm/blob/v26.08.0/shared/bin/pcap_watcher.py#L238-L249)
   watches `<pcap>/processed` (non-recursive, L534), builds
   `tags: tags_from_filename(relativePath)` and publishes it over ZeroMQ. **This is
   the only place the tag list is created**; nothing else can add to the message.
3. **Arkime worker** (`arkime` container):
   [`shared/bin/pcap_processor.py` L187-L231](https://github.com/idaholab/Malcolm/blob/v26.08.0/shared/bin/pcap_processor.py#L187-L231)
   keeps the published tags if `autoTag` is on (minus `USERTAG`, `AUTOARKIME`,
   `AUTOSURICATA`, `AUTOZEEK` and anything starting `NBSITEID`), else starts from
   an empty list; appends `extraTags`; de-duplicates; then runs
   `capture-offline ... -r <file> --node <node>-upload ... -t <tag> -t <tag> ...`.
   Each list element is one argv element, so nothing is re-split here.
4. **Arkime**: `-t` / `--tag` is "Extra tag to add to all packets, can be used
   multiple times"
   ([`capture/main.c` L126](https://github.com/arkime/arkime/blob/v6.7.0/capture/main.c#L126));
   each value is added to every session as given
   ([`capture/parsers.c` L494-L503](https://github.com/arkime/arkime/blob/v6.7.0/capture/parsers.c#L494-L503)).
   Arkime itself does not look at the file name and does not split.

### Zeek and Suricata records re-split a second time

The same published tag list is used by the Zeek and Suricata workers in
`pcap_processor.py`, but those tags travel inside a name and are parsed again:

- **Zeek**: the logs are tarred as `<pcap basename>-<tags joined by _>-<usec>.tar.gz`
  ([`pcap_processor.py` L362-L369](https://github.com/idaholab/Malcolm/blob/v26.08.0/shared/bin/pcap_processor.py#L362-L369)),
  and filebeat's
  [`filebeat-process-zeek-folder.sh` L80-L101](https://github.com/idaholab/Malcolm/blob/v26.08.0/filebeat/scripts/filebeat-process-zeek-folder.sh#L80-L101)
  splits that whole name again with `IFS=",-/_."`. So on Zeek records **every** tag,
  including one from `EXTRA_TAGS`, is cut on the five characters. With
  `AUTO_TAG` not `true` and no `USERTAG` in the name, that script keeps only
  `NBSITEID*` tags, i.e. Zeek records get no name-derived tags at all.
- **Suricata**: output goes to a directory `suricata-<usec>-<worker>-(<tags joined by ,>)`
  ([`pcap_processor.py` L475-L480](https://github.com/idaholab/Malcolm/blob/v26.08.0/shared/bin/pcap_processor.py#L475-L480))
  and Logstash splits the parenthesised part on `,` only
  ([`logstash/pipelines/suricata/11_suricata_logs.conf` L12-L38](https://github.com/idaholab/Malcolm/blob/v26.08.0/logstash/pipelines/suricata/11_suricata_logs.conf#L12-L38)).

## 3. Settings that control auto-tagging

Both live in `config/upload-common.env`
([`config/upload-common.env.example`](https://github.com/idaholab/Malcolm/blob/v26.08.0/config/upload-common.env.example),
documented in
[`docs/malcolm-config.md`](https://github.com/idaholab/Malcolm/blob/v26.08.0/docs/malcolm-config.md)):

| Variable | Default | Effect |
|---|---|---|
| `AUTO_TAG` | `true` | On/off only. `false` drops every file-name tag. There is no setting for the splitter characters; they are hard-coded in two places (section 2). |
| `EXTRA_TAGS` | empty | Comma-separated tags added to **all** data Malcolm generates. Each is sanitised to `[A-Za-z0-9 ._-]` and passed to Arkime unsplit ([`pcap_processor.py` L837-L840](https://github.com/idaholab/Malcolm/blob/v26.08.0/shared/bin/pcap_processor.py#L837-L840)), so a hyphenated value survives whole on Arkime sessions. It is read from the container environment at start ([`arkime/supervisord.conf` L73-L74](https://github.com/idaholab/Malcolm/blob/v26.08.0/arkime/supervisord.conf#L73-L74)), so it is static and global, not per upload. |

The kit does not set either variable (no match for `AUTO_TAG`, `EXTRA_TAGS` or
`upload-common` under `config/`, `scripts/` or `staging/`), so the release
default `AUTO_TAG=true`, `EXTRA_TAGS=` is what increment 1 measured.

## 4. Alternative routes

| Route | What it does in 26.08.0 | One unbroken hyphenated tag? |
|---|---|---|
| **Upload form "tags" field** (`https://<host>/upload/`) | [`file-upload/php/submit.php` L54-L69](https://github.com/idaholab/Malcolm/blob/v26.08.0/file-upload/php/submit.php#L54-L69) renames the file to `<tags>,USERTAG,<original name>`, after stripping every character outside `[a-zA-Z0-9\s_(),-]` (L39-L41). The tags are thus only a file-name prefix and go through the same splitter. `USERTAG` only forces tags to be kept on Zeek logs when `AUTO_TAG` is off. | No |
| **Upload HTTP endpoint** | The form posts to `server/php/` (FilePond) then `server/php/submit.php` with a `tags` field. It is the form's back end, with the behaviour above; the API index ([`docs/api.md`](https://github.com/idaholab/Malcolm/blob/v26.08.0/docs/api.md)) lists no upload or tagging API. | No |
| **SFTP drop** (port 8022, `files/`) | Same `upload/` directory, same watcher ([`docs/upload.md`](https://github.com/idaholab/Malcolm/blob/v26.08.0/docs/upload.md)). No tag input at all. | No |
| **Subdirectory convention** | None. Neither watcher is recursive, and `/` is itself a splitter character. | No |
| **File name with no splitter characters** | A token free of `,` `-` `.` `/` `_` comes through as one tag on Arkime, Zeek and Suricata records. | Unbroken yes; hyphenated no |
| **`EXTRA_TAGS`** | See section 3. | Yes on Arkime sessions only, but the same tag lands on every upload and all live capture until the variable is changed and the containers restarted |
| **Arkime `-t` / `--tag` directly** | Supported by Arkime, takes any string. Malcolm's pipeline is the only thing in the product that calls it; running `capture-offline` by hand in the `arkime` container would bypass the watcher, Zeek and Suricata. | Yes on Arkime sessions only; not a Malcolm-documented route |
| **Arkime "add tags" after ingest** | Arkime viewer action / `POST /api/sessions/addtags` adds tags to sessions matched by id or query; it keeps `[-a-zA-Z0-9_:,]` and splits only on `,` ([`viewer/apiSessions.js` L2688-L2706](https://github.com/arkime/arkime/blob/v6.7.0/viewer/apiSessions.js#L2688-L2706)). | Yes on Arkime sessions only (Zeek and Suricata records are untouched) |

## 5. Which characters survive as one token

For a file placed straight into `upload/`, which is what `ingest` in
`scripts/r770-scenario.sh` does (it moves `<run-id>,<view>.pcapng` into the
drop-off, so the PHP sanitiser is never involved):

- **Always split on:** `,` `-` `.` `/` `_`.
- **Survive in the splitter:** every other character, i.e. letters, digits, and
  punctuation such as `+` `=` `~` `@` `:` `(` `)` and inner spaces.
- **Safe everywhere by reading the code:** letters and digits. `(` and `)` are
  unsafe further on because the Zeek and Suricata tag lists are carried inside
  parentheses in a file or directory name. Whether `+` `=` `~` `@` `:` come
  through the Zeek/Suricata legs and Arkime's search box unharmed was not tested.
- **Dropped even when whole:** a token that is only digits, or one of the reserved
  words in section 2. `20261110T1435Z` survives because of the `T` and `Z`;
  `20261110` alone would vanish.
- **Through the upload form instead:** only `[a-zA-Z0-9]`, whitespace and `(` `)`
  survive both the PHP sanitiser and the splitter.

## 6. What this opens for the follow-on decision

Not decided here; these are the routes the facts leave open.

1. **Keep the file names, change the documentation** to "find a run by its
   timestamp token plus `outer` or `inner`" (the first branch of I4). The
   timestamp token `20261110T1435Z` is already a single tag.
2. **Rename what `ingest` drops** so each intended tag has no splitter character,
   e.g. a compacted run id and view (`s1w1ss20261110T1435Z`, `innergwa`). Works
   for Arkime, Zeek and Suricata records alike. The tag then differs from the
   `run_id` string in `run.conf` and the case directory name unless those change too.
3. **Use a non-splitting separator** in the dropped name (for example `+`). One
   tag by the splitter's rule; needs a staging check first (section 7).
4. **Tag in Arkime after ingest** through `addtags`, giving the exact `run_id`
   with hyphens on Arkime sessions. Needs an authenticated call to Arkime and a
   query that isolates the upload; Zeek and Suricata records keep the short tags.
5. **`EXTRA_TAGS`**: exact hyphenated tag on Arkime sessions, but global and
   static, so it would have to be set and the containers restarted around every
   ingest, and it would also tag live capture meanwhile.
6. **`AUTO_TAG=false`** on its own removes the short tags and adds nothing.

An extra observation relevant to any of them: the extension `pcapng` becomes a
tag on every upload, because only `pcap` and `cap` are in the ignore list.

## 7. Unconfirmed

- **Nothing was run on a Malcolm instance.** All behaviour above is from reading
  source at the pinned tags; only the splitter function was executed, in isolation.
- **Image contents vs. tag source.** The kit loads published container images; it
  was not verified that the `26.08.0` images contain byte-identical copies of the
  files read at git tag `v26.08.0` (the I4 measurement agrees with them).
- **`cisagov/Malcolm`.** That repository also has a `v26.08.0` tag, at a different
  commit id from `idaholab/Malcolm`'s; the two trees were not compared. The kit
  fetches from `idaholab/Malcolm`, which is what was read.
- **Non-alphanumeric separators end to end** (`+`, `=`, `~`, `@`, `:`): one token
  per the regex, but not tested through the Zeek tarball name, the Suricata
  directory name, Logstash, or Arkime's query syntax (`tags == ...`).
- **Arkime search on a hyphenated tag.** That `tags == s1-w1-ss-20261110T1435Z`
  needs no quoting in Arkime 6.7.0's expression language was not checked.
- **`addtags` in Malcolm's deployment.** The endpoint exists in Arkime 6.7.0;
  that it is reachable and permitted through Malcolm's nginx and role mapping for
  the kit's accounts was not checked.
- **Dot-files and partial files in `upload/`.** Whether the watcher ignores a
  dot-file or takes a file before the copy completes was not established (the
  same open point `ingest` already notes in its comments).
