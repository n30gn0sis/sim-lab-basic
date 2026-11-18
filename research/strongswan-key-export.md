# Getting ESP and IKE keys out of strongSwan on Ubuntu 24.04

Research for issue 32 (map: issue 22). Fact-finding only; nothing here is built or decided.
Sources were read on 2026-11-18. Every claim cites the source that owns it. Anything read
from source but not run is marked **not run**; anything not established is in
"Unconfirmed" at the end.

No version numbers are restated here: the strongSwan image is "the tag pinned as
`STRONGSWAN_IMG` in the pin block of `staging/r770-offline-fetch.sh`", and upstream
sources are cited by branch or suite name.

## Answer in short

- **No packaged build carries `save-keys`.** Not Ubuntu noble, not Debian, not Alpine,
  not the strongSwan project's own container image. It is a development plugin that
  upstream leaves off by default; the only way to get it is to compile strongSwan with
  `--enable-save-keys`.
- **The source build is small.** The project's image is itself a from-source build in a
  single Dockerfile; adding the plugin is one more configure flag and no new build
  dependency. The cost is not the compile: it is that the kit would own an image build
  for the first time (today it only pulls images).
- **The plugin's output may not decode as written for the kit's cipher.** S1 uses
  AES-GCM for ESP. The plugin writes the ESP table row with an algorithm name that
  current Wireshark treats as deprecated and an authentication column that current
  Wireshark rejects for GCM. Read from both sources, **not run**. If true, X7 would go
  from SKIP to FAIL, not PASS, until the row is rewritten.
- **ESP keys need no plugin.** `ip xfrm state` inside the gateway's namespace prints the
  kernel's ESP keys (key and salt together, the same layout Wireshark wants). That is
  enough to write an `esp_sa` table. It is a snapshot, so SAs rekeyed away before the
  snapshot are missed.
- **IKE keys need either the plugin or level-4 logging.** They never reach the kernel.
  charon prints them at log level 4 (`ike` subsystem) as hex dumps; a converter would
  have to join them with SPIs and algorithm names to make the IKEv2 table.

## What the kit does today

- `scenarios/s1-w1-ss/nodes/gw-a.sh` and `gw-b.sh` look for
  `/usr/lib*/ipsec/plugins/libstrongswan-save-keys.so`. If present they write
  `/etc/strongswan.d/charon/save-keys.conf` (`load = yes`, `esp = yes`, `ike = yes`,
  `wireshark_keys = /gt/keys`) and record `present` in `/gt/keys.state`; otherwise
  `absent`.
- `scripts/r770-scenario.sh`: `gt_keys_state()` folds the nodes' `keys.state` into
  `keys=` in `run.conf`; `decrypt_check()` (X7) SKIPs unless `keys=present`, then copies
  the first `gt/*/keys/esp_sa` into a throwaway Wireshark profile (`profiles/gt/esp_sa`
  under a private `HOME`) and runs
  `tshark -C gt -o esp.enable_encryption_decode:TRUE -Y 'esp && (tcp || udp || icmp)'`
  on the outer capture. It uses `esp_sa` only; nothing consumes an IKE table.
- The S1 proposals are AES-256-GCM with a 16-octet ICV for both IKE and ESP
  (`scenarios/s1-w1-ss/nodes/gw-a.swanctl.conf`: `aes256gcm16-prfsha384-ecp384`,
  `esp_proposals = aes256gcm16-ecp384`).
- The harness already snapshots `swanctl --list-sas` per gateway
  (`scenarios/s1-w1-ss/scenario.conf`, `gt=`), which lists IKE and CHILD SPIs but no keys.
- The image is the strongSwan project's own (`strongx509/strongswan` on Docker Hub),
  pinned as `STRONGSWAN_IMG` in `staging/r770-offline-fetch.sh`.
- Measured: `docs/rehearsals/2026-11-10-ipsec-wan.md`, "O3, keys": absent, X7 SKIP.
- The kit builds no image anywhere today (no `docker build` and no Dockerfile under
  `staging/`, `scripts/` or `config/`).

## 1. Is `save-keys` in any packaged build?

No, in every build checked.

| Build | Evidence | Result |
|---|---|---|
| strongSwan upstream default | `configure.ac`: `ARG_ENABL_SET([save-keys], [enable development/debugging plugin that saves IKE and ESP keys in Wireshark format.])`: an opt-in flag. The docs: disabled by default, enabled with `--enable-save-keys`. | off unless asked |
| Ubuntu noble source package | `debian/rules` on the `ubuntu/noble-updates` branch: the configure list has no `--enable-save-keys`, commented or otherwise. | not built |
| Ubuntu noble `libcharon-extra-plugins` | packages.ubuntu.com file list: no path containing `save-keys`. | absent |
| Ubuntu noble `libstrongswan-extra-plugins` | packages.ubuntu.com file list: no path containing `save-keys`. | absent |
| Debian (unstable) | `debian/rules`: no `--enable-save-keys`. | not built |
| strongSwan project image | its Dockerfile: `--disable-defaults` plus an explicit short list of `--enable-*` flags; `save-keys` is not among them. Same list at the Dockerfile revision based on Ubuntu 24.04 and at the current one. | not built |
| Alpine `strongswan` | `APKBUILD` (aports master, GitHub mirror): first part of the configure list read, no `save-keys` seen; the tail of the list was not read. | **unconfirmed**, very likely not built |

The kit's own rehearsal agrees for the pinned tag: the plugin file is not in the image.

Sources:
- https://github.com/strongswan/strongswan/blob/master/configure.ac
- https://docs.strongswan.org/docs/latest/plugins/save-keys.html
- https://git.launchpad.net/ubuntu/+source/strongswan/plain/debian/rules?h=ubuntu/noble-updates
- https://packages.ubuntu.com/noble/amd64/libcharon-extra-plugins/filelist
- https://packages.ubuntu.com/noble/amd64/libstrongswan-extra-plugins/filelist
- https://sources.debian.org/src/strongswan/unstable/debian/rules/
- https://github.com/strongX509/docker/blob/master/strongswan/Dockerfile
- https://github.com/alpinelinux/aports/blob/master/main/strongswan/APKBUILD

## 2. Options, output files, format, and how tshark reads them

### Options

Section `charon.plugins.save-keys` in `strongswan.conf`
(source: `conf/plugins/save-keys.opt`, and `save_keys_listener.c` which reads them):

| Option | Default | Meaning |
|---|---|---|
| `load` | `no` | Whether to load the plugin. |
| `esp` | `no` | Whether to save ESP keys. |
| `ike` | `no` | Whether to save IKE keys. |
| `wireshark_keys` | unset | Directory the tables are written to. |

Notes:
- The shipped default is `load = no`, so building the plugin in is not enough; a config
  must turn it on. The docs say the per-plugin `load` setting works only with
  `charon.load_modular`. The loader source (`plugin_loader.c`, the function that builds
  the list) reads `plugins.<name>.load` in both branches: without `load_modular` it
  filters the compiled-in plugin list by that setting. So the kit's snippet
  (`load = yes` in `strongswan.d/charon/save-keys.conf`) should work either way. Docs
  and source disagree here; **not run**.
- With a path set and either switch on, charon logs
  `!! WARNING: SAVING IKE AND ESP KEYS TO '<dir>'` at level 0 at start-up. That line is
  a cheap proof the plugin is live.
- Nothing is written unless `wireshark_keys` is set and the matching switch is on.
- Files are opened in append mode, one or two lines per derived SA. The directory must
  exist; the plugin does not create it. A failure to open is logged at level 1
  (`failed to open ESP key table ...`).

### Files

Written into the `wireshark_keys` directory (names are constants in
`save_keys_listener.c`):

| File | Content |
|---|---|
| `ikev1_decryption_table` | IKEv1: `<initiator cookie>,<encryption key>` |
| `ikev2_decryption_table` | IKEv2 IKE_SA keys |
| `esp_sa` | ESP CHILD_SA keys, two lines per CHILD_SA (one per direction) |

The docs page has a typo in its prose (`ike2_decryption_table`); the source and the
option file say `ikev2_decryption_table`.

### `ikev2_decryption_table` line

From the plugin's `fprintf`:

```
<SPIi 16 hex>,<SPIr 16 hex>,<SK_ei hex>,<SK_er hex>,"<encryption name>",<SK_ai hex>,<SK_ar hex>,"<integrity name>"
```

This is exactly Wireshark's IKEv2 table (fields in `packet-isakmp.c`: Initiator's SPI,
Responder's SPI, SK_ei, SK_er, Encryption algorithm, SK_ai, SK_ar, Integrity
algorithm). For an AEAD IKE proposal the plugin writes empty SK_ai and SK_ar and
`"NONE [RFC4306]"`, with SK_ei and SK_er carrying key plus salt. Wireshark's own test
table has a row of the same shape for
`"AES-GCM-256 with 16 octet ICV [RFC5282]"`, the name the plugin emits for the kit's
IKE proposal, and its dissector takes the salt from the tail of the key. So the IKE
table matches for the kit's proposal.

### `esp_sa` line

From the plugin's `fprintf`, two lines per CHILD_SA:

```
"IPv4","<src>","<dst>","0x<SPI 8 hex>","<encryption name>","0x<key hex>","<authentication name>","0x<key hex>"
```

Eight quoted fields: Protocol, Src IP, Dest IP, SPI, Encryption, Encryption Key,
Authentication, Authentication Key. Those are the eight columns of Wireshark's ESP SA
table in the Wireshark release noble ships (`packet-ipsec.c`, table file name
`esp_sa`). Current Wireshark master has two more trailing columns (sequence-number
length and ESN high bits); its table loader fills trailing columns from defaults when
a table declares them (`uat_load.l`), and whether the ESP table declares them was not
established. **Unconfirmed** for a Wireshark newer than noble's.

Addresses are the IKE endpoints, so the table does not follow MOBIKE (source comment).

### The AES-GCM mismatch (read from source, not run)

For an AEAD ESP proposal the plugin writes:

- Encryption: `"AES-GCM [RFC4106]"` for every GCM ICV length;
- Authentication: `"ANY 128 bit authentication [no checking]"` for a 16-octet ICV
  (64 and 96 for the shorter ones), with an empty key (`"0x"`).

The plugin's last GCM change is from February 2021. Wireshark's ESP dissector was
reworked in June 2021 (commits "add encryption types for AES-GCM with 8,12,16 octet
ICV", "implement ICV verification for AEAD ciphers"). In that code, as shipped in
noble's Wireshark and on master:

- `"AES-GCM [RFC4106]"` is kept as "deprecated; (no ICV length specified)" and sets
  the ICV length to 0, overriding what the authentication column said;
- the new names are `"AES-GCM with 8 octet ICV [RFC4106]"`, `... 12 ...`,
  `... 16 ...`;
- when decrypting AES-GCM with an authentication algorithm other than `NULL`, the
  dissector raises
  `<ESP Preferences> Error: AES-GCM encryption can only be used with NULL authentication`.

So the row the plugin writes for the kit's S1 proposal looks unusable as written in
noble's tshark; the row Wireshark's source expects for it is
`"AES-GCM with 16 octet ICV [RFC4106]"` with authentication `"NULL"` and the same
key (key followed by the 4-byte salt; the dissector strips the last 4 bytes as salt).
This was derived by reading both sources and **was not run**. No upstream strongSwan
issue about it was found. It matters to the decision because the plugin alone might
turn X7 from SKIP into FAIL. A non-AEAD ESP proposal (AES-CBC with HMAC-SHA2) is not
affected: those names are unchanged in Wireshark.

### How tshark consumes the tables

- Both tables are Wireshark "user accessible tables": plain files in the personal
  configuration directory, or in `profiles/<name>/` under it, read when that profile
  is selected (`tshark -C <name>`). File names: `esp_sa`,
  `ikev2_decryption_table`, `ikev1_decryption_table` (Wireshark User's Guide,
  "User Accessible Tables"; names in `packet-ipsec.c` and `packet-isakmp.c`).
- ESP additionally needs the preference `esp.enable_encryption_decode` set to TRUE
  (`packet-ipsec.c`); without it the table is ignored.
- The IKEv2 table needs no preference; a matching SPI pair is enough.
- The kit's X7 already does this for `esp_sa` with a private `HOME` and profile `gt`.
  Dropping `ikev2_decryption_table` into the same profile directory is all an IKE
  check would need on the tshark side.
- The plugin docs' own example points `wireshark_keys` straight at root's Wireshark
  config directory, which confirms the files are meant to be used unmodified.

Sources:
- https://github.com/strongswan/strongswan/blob/master/conf/plugins/save-keys.opt
- https://github.com/strongswan/strongswan/blob/master/src/libcharon/plugins/save_keys/save_keys_listener.c
- https://github.com/strongswan/strongswan/blob/master/src/libstrongswan/plugins/plugin_loader.c
- https://docs.strongswan.org/docs/latest/plugins/save-keys.html
- https://github.com/wireshark/wireshark/blob/master/epan/dissectors/packet-ipsec.c
- https://github.com/wireshark/wireshark/blob/master/epan/dissectors/packet-isakmp.c
- https://github.com/wireshark/wireshark/blob/master/epan/uat_load.l
- https://github.com/wireshark/wireshark/blob/master/test/config/ikev2_decryption_table.tmpl
- https://github.com/wireshark/wireshark/blob/master/test/config/esp_sa.tmpl
- https://github.com/wireshark/wireshark/blob/master/doc/wsug_src/wsug_customize.adoc
- https://packages.ubuntu.com/noble/tshark (which Wireshark release noble ships)

## 3. What a source build with `--enable-save-keys` involves

### What the plugin needs

Nothing beyond what charon already needs. `save_keys_listener.c` includes only the C
library and the daemon's own header; `configure.ac` registers it for charon only
(`ADD_PLUGIN([save-keys], [c])`) and attaches no library check to it. The build
produces `libstrongswan-save-keys.so` in the plugin directory, which is the file the
kit's node scripts already test for, and installs a `save-keys.conf` snippet with
`load = no`.

### Route A: the project's Dockerfile plus one flag

The project's image is a single-stage source build, and the recipe is short
(https://github.com/strongX509/docker/blob/master/strongswan/Dockerfile):

1. Start from an Ubuntu base. The recipe revision that the pinned tag's release line
   was cut from uses the Ubuntu 24.04 base (inferred from the Dockerfile history, not
   from inspecting the image).
2. Install build packages: `wget bzip2 make gcc libssl-dev` (the current revision adds
   `pkg-config`). Runtime packages kept: `iproute2 iputils-ping nano`.
3. Fetch the release tarball from download.strongswan.org and unpack it.
4. `./configure --prefix=/usr --sysconfdir=/etc --disable-defaults` plus about twenty
   `--enable-*` flags (charon, ikev2, openssl, swanctl, vici, kernel-netlink,
   socket-default and so on). **Add `--enable-save-keys` here.**
5. `make all && make install`, then remove the build packages.

Cost, judged from that recipe:
- one extra configure flag, no extra package;
- a compile of a deliberately minimal strongSwan (minutes, not hours; **not timed**);
- network at build time for the base image, the apt packages and the tarball, so it
  can only happen on the staging host, never on the R770;
- the release tarball version would be a pin. It would have to live in the pin block
  and nowhere else, like every other pin; a Dockerfile that hard-codes it (as
  upstream's `ENV VERSION=` does) would restate it;
- the kit would own an image build and a Dockerfile for the first time. Today the
  fetch stage only pulls and saves images. The map already says "the kit supplies its
  own new images, through the pin block", so this is in the direction the map points,
  but it is new machinery (build, tag, save, load, a test);
- paths stay as the node scripts expect (`/usr/libexec/ipsec/charon`,
  `/usr/lib/ipsec/plugins/`), because the configure prefix is unchanged.

A released tarball builds with the plain `./configure`, `make`, `make install`
sequence; the install docs say a git checkout needs "additional tools and steps" and
point to the repository's `HACKING` file (not read). Upstream's recipe uses the
tarball.

### Route B: rebuild the Ubuntu noble package with the flag

`apt-get source strongswan`, `apt-get build-dep strongswan`, add the flag to
`debian/rules`, `dpkg-buildpackage`. This drags in the package's full build-dependency
set (it enables some forty plugins), and the new plugin file must also be listed in
one of the package's install lists or the build stops on an uninstalled file
(**unconfirmed**: the install lists were not read). It yields a patched distro package
the kit would have to carry and re-cut on every noble security update. More cost than
Route A for the same plugin, and the kit's gateways are container nodes, not host
packages.

Sources:
- https://github.com/strongX509/docker/blob/master/strongswan/Dockerfile (and its history)
- https://github.com/strongswan/strongswan/blob/master/configure.ac
- https://docs.strongswan.org/docs/latest/install/install.html
- https://git.launchpad.net/ubuntu/+source/strongswan/plain/debian/rules?h=ubuntu/noble-updates

## 4. Alternatives that need no plugin

### `ip xfrm state`: ESP keys from the kernel

- strongSwan's default IPsec backend installs CHILD_SAs into the kernel through
  netlink (`kernel-netlink`, which the image builds in). `ip xfrm state` in the
  gateway's network namespace lists them: endpoints, SPI, mode, and the algorithm
  lines with their keys in hex. For the kit's proposal the line is
  `aead rfc4106(gcm(aes)) 0x<hex> 128`.
- The image keeps `iproute2`, and the first-cut scenario `scenarios/ipsec-esp/` already
  drives `ip xfrm` in these nodes; the rehearsal counts xfrm states on the gateways.
- **Privilege.** The dump needs the same network-admin capability in that namespace
  that charon needs to install the SAs, so a node that can run the tunnel can dump it.
  `ip xfrm state list nokeys` exists to suppress keys, so keys are the default.
- **Lockdown.** The kernel redacts SA secrets from dumps when lockdown is in
  confidentiality mode (`xfrm_redact()` in `net/xfrm/xfrm_user.c`,
  `LOCKDOWN_XFRM_SECRET`). Containers share the host kernel, so this is a property of
  the R770 and of staging VM 9770. The rehearsal counted xfrm states but did not
  record whether the key fields were populated. **Unconfirmed on the kit's hosts**,
  and which lockdown mode noble selects under Secure Boot was not looked up.
- **AEAD salt.** For `rfc4106(gcm(aes))` the kernel's key material is the AES key
  followed by a 4-byte salt (`crypto_rfc4106_setkey()` in `crypto/gcm.c` takes the
  last 4 bytes as the nonce). The hex that `ip xfrm state` prints is therefore key
  plus salt: 36 bytes for AES-256. Wireshark's ESP table wants exactly that: its
  dissector treats the last 4 bytes of the configured key as the salt. So the hex goes
  into the table unchanged; nothing is stripped or appended. The trailing number is
  the ICV length in bits and selects the Wireshark name (128 means the 16-octet
  variant). The same key-plus-salt layout applies to AES-CTR and ChaCha20-Poly1305.
- **Non-AEAD.** `enc cbc(aes) 0x<key>` and `auth-trunc hmac(sha256) 0x<key> 128` map
  to the encryption and authentication columns; the truncation length picks the name.
- **Enough for `esp_sa`?** Yes. Every column (family, src, dst, SPI, algorithm, key)
  is in the output; a short converter has to translate kernel algorithm names to
  Wireshark's names. Writing the current GCM names directly also sidesteps the
  mismatch in section 2.
- **Caveats.**
  - It is a snapshot. An SA that was rekeyed and deleted before the snapshot is gone,
    and with it the key for the packets it carried. A scenario that rekeys would need
    a snapshot per SA generation (or `ip xfrm monitor`, whose output for new SAs was
    not checked: **unconfirmed**). The plugin, by contrast, appends every key as it
    is derived.
  - It gives ESP only. IKE keys are never in the kernel.
  - It only works for kernel SAs. A gateway using the userspace backend
    (`kernel-libipsec`) has nothing in xfrm; the kit's image does not build that
    backend.
  - UDP-encapsulated ESP (NAT-T) shows as `encap type espinudp`; the Wireshark row
    is the same, keyed by outer addresses and SPI.

### charon log level 4: IKE keys (and CHILD keys) from the log

- strongSwan's log levels (docs, "Logger Configuration"): level 3 adds raw hex dumps,
  level 4 "Also include sensitive material in dumps, e.g. keys". Levels are set per
  subsystem in a `filelog` section; the kit's gateways already write a `filelog`
  (`/gt/charon.log`, `default = 1`), so this is `ike = 4` (and `chd = 4`) in that
  section.
- What level 4 prints, from `src/libcharon/sa/ikev2/keymat_v2.c`:
  - `ike` subsystem: `Sk_d secret`, `Sk_ai secret`, `Sk_ar secret`, `Sk_ei secret`,
    `Sk_er secret`, `Sk_pi secret`, `Sk_pr secret`, plus `SKEYSEED`, the key-exchange
    shared secret and the nonces;
  - `chd` subsystem: `encryption initiator key`, `encryption responder key`,
    `integrity initiator key`, `integrity responder key`, and the CHILD key-exchange
    secret.
- **Enough for the IKEv2 table?** The key bytes are all there (SK_ei, SK_er, SK_ai,
  SK_ar), and for AEAD the SK_e values include the salt as the table wants. What the
  key lines do not carry is the SPI pair and the negotiated algorithm names; those
  must be joined from elsewhere: the `swanctl --list-sas` snapshot the harness
  already takes prints the IKE SPIs and proposals, and the log names the SA on
  neighbouring lines. So yes, with a converter that (a) parses charon's multi-line
  hex-dump format, (b) associates each key block with an IKE_SA and its SPIs, and
  (c) maps strongSwan's proposal to Wireshark's algorithm strings. The exact line
  layout of the dump and the association across an IKE rekey were not captured from
  a real log. **Unconfirmed in detail**; the plugin's listener does the same three
  things in about thirty lines of C and is the reference for the mapping tables.
- **Enough for `esp_sa`?** Also yes in principle (`chd = 4` gives the same keys the
  plugin writes), with the same join problem for SPIs. `ip xfrm state` is the simpler
  route for ESP because SPI, addresses and key arrive on adjacent lines.
- **Side effects.** Level 4 also writes the PSK-derived values and the DH secret into
  `charon.log`, which the harness collects as ground truth. Level 3 and 4 on `ike`
  make the log much larger. Both are tolerable in a lab that already means to export
  keys, but the log becomes a secret-bearing file, which the plugin's separate key
  directory avoids.

Sources:
- https://docs.strongswan.org/docs/latest/config/logging.html
- https://github.com/strongswan/strongswan/blob/master/src/libcharon/sa/ikev2/keymat_v2.c
- https://manpages.ubuntu.com/manpages/noble/en/man8/ip-xfrm.8.html
- https://github.com/iproute2/iproute2/blob/main/ip/ipxfrm.c
- https://github.com/torvalds/linux/blob/master/crypto/gcm.c
- https://github.com/torvalds/linux/blob/master/net/xfrm/xfrm_user.c
- https://github.com/wireshark/wireshark/blob/master/epan/dissectors/packet-ipsec.c

## What each route yields

| Route | ESP table | IKEv2 table | Survives rekey | New kit machinery |
|---|---|---|---|---|
| `save-keys` in a kit-built image | yes, but the GCM row likely needs rewriting (not run) | yes, as written | yes (appends per SA) | an image build on staging; a row fix-up if the GCM finding holds |
| `ip xfrm state` snapshot | yes, via a small converter | no | only SAs alive at snapshot time | a ground-truth command and a converter; no image change |
| charon level-4 log | yes, via a converter | yes, via a converter | yes (logged as derived) | a log-level change and a hex-dump parser; secrets land in `charon.log` |
| xfrm for ESP plus level-4 log for IKE | yes | yes | ESP: snapshot only | both of the above, no image change |

These are options for the follow-on decision, not a recommendation.

## Unconfirmed

1. **The AES-GCM row mismatch** between what `save-keys` writes and what noble's
   Wireshark accepts: derived from reading both sources, not run. One decrypt of an
   S1 capture with a hand-written `esp_sa` row would settle it.
2. **Whether `load = yes` works without `charon.load_modular`**: the docs say it
   needs it, the loader source reads the setting either way. Not run.
3. **Kernel lockdown on the R770 and VM 9770**: whether `ip xfrm state` shows key
   hex there. One `ip xfrm state` in a gateway node answers it.
4. **Alpine**: only the first part of the configure list was read.
5. **Wireshark newer than noble's**: whether an eight-column `esp_sa` row still loads
   now that the table has ten columns.
6. **charon's level-4 dump layout** and how key blocks associate with SPIs across an
   IKE rekey: read from the `DBG4` calls, not from a real log.
7. **`ip xfrm monitor`** as a way to catch every SA generation: not checked.
8. **Route B's packaging detail** (install lists) and **Route A's build time**: not
   read, not timed.
9. **Which Dockerfile revision the pinned tag was built from**: inferred from the
   recipe's commit history, not from the image.
