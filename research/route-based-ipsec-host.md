# What route-based IPsec needs from the host

Research for issue 34 (map: issue 22), 2026-11-18. Fact-finding only; nothing
in the kit was changed. Where this note and a transcript disagree, the
transcript wins: nothing here was run on staging VM 9770 or on the R770.

**Question.** What does route-based IPsec with XFRM interfaces need from the
host, for a strongSwan endpoint running as a GNS3 docker node on Ubuntu
24.04's stock kernel?

## Answer

Nothing has to be added to the host for it to work.

- `xfrm_interface` is a module in Ubuntu 24.04's base `linux-modules` package
  (not `linux-modules-extra`), so it is on every installed 24.04 server and
  needs nothing from the bundle.
- The kernel loads it on demand the first time anything runs
  `ip link add ... type xfrm`, including a process inside a container's
  network namespace. That path needs `CAP_NET_ADMIN` only, not
  `CAP_SYS_MODULE`, and the kernel runs the host's `modprobe` itself, so the
  container needs no `/lib/modules`.
- A GNS3 docker node (privileged, all capabilities: O4) can create the
  interface in its own namespace. The underlying `dev` is optional on this
  kernel and can be left out.
- strongSwan ties SAs to the interface with `if_id_in` / `if_id_out`. charon
  does not create the interface and, by default, installs no routes for such
  a child SA; the node script creates the interface and FRR (or a static
  route) supplies the routes.

A preload through `/etc/modules-load.d/` is therefore a policy choice, not a
technical requirement. See "What this means for the kit" below.

Confidence: the kernel and packaging claims are read from source and package
file lists, not measured on the box. The items under "Unconfirmed" say what a
staging run should prove.

## 1. The module: where it lives and how it gets loaded

**Packaging.** The file list of `linux-modules-6.8.0-31-generic` (noble,
amd64) contains
`/lib/modules/6.8.0-31-generic/kernel/net/xfrm/xfrm_interface.ko.zst`. The
same base package carries `ip_vti`, `ip6_vti`, `esp4`, `esp6`, `xfrm_user`,
`xfrm_algo`, `af_key`, `tunnel4` and `ip_tunnel`.
Source: <https://packages.ubuntu.com/noble/amd64/linux-modules-6.8.0-31-generic/filelist>

`linux-image-generic` depends on `linux-modules-extra` as well
(<https://packages.ubuntu.com/noble/linux-image-generic>), but that does not
matter here: every module route-based IPsec needs is in the base package.

The kit's bundle carries the `linux-generic-hwe-24.04` metapackage (see the
apt list in `staging/r770-offline-fetch.sh`), so the R770 may run an HWE
kernel rather than 6.8. Only the 6.8.0-31 file list was read; see
"Unconfirmed".

**Autoload.** In v6.8 `net/core/rtnetlink.c`, `__rtnl_newlink()` does this
when the link kind is unknown:

```c
if (kind[0]) {
        __rtnl_unlock();
        request_module("rtnl-link-%s", kind);
        rtnl_lock();
        ops = rtnl_link_ops_get(kind);
        if (ops)
                goto replay;
}
```

Source: <https://raw.githubusercontent.com/torvalds/linux/v6.8/net/core/rtnetlink.c>

- There is no capability check beside that call and no `CAP_SYS_MODULE`
  anywhere in the file. The only gate is in `rtnetlink_rcv_msg()`:
  `if (kind != RTNL_KIND_GET && !netlink_net_capable(skb, CAP_NET_ADMIN)) return -EPERM;`
  That is `CAP_NET_ADMIN` over the caller's own network namespace.
- Nothing on that path requires the initial network namespace.
- The module declares the alias the request resolves to:
  `MODULE_ALIAS_RTNL_LINK("xfrm");`
  Source: <https://raw.githubusercontent.com/torvalds/linux/v6.8/net/xfrm/xfrm_interface_core.c>
- The kernel runs `modprobe`, not the caller. `call_modprobe()` in
  `kernel/module/kmod.c` execs `modprobe_path` with `-q` through the usermode
  helper, which runs from a kernel workqueue with full root capabilities and
  init's root directory (`kernel/umh.c`). So the module file and `modprobe`
  must be on the host, and nothing is needed inside the container.
  Sources: <https://raw.githubusercontent.com/torvalds/linux/v6.8/kernel/module/kmod.c>,
  <https://raw.githubusercontent.com/torvalds/linux/v6.8/kernel/umh.c>
- For contrast, `dev_load()` (the `netdev-%s` path in
  `net/core/dev_ioctl.c`) does demand `CAP_SYS_MODULE` for a bare module
  name. The rtnl-link path does not.

This is the same mechanism that already works for policy-based IPsec in the
kit (risk R2 in
`docs/superpowers/specs/2026-10-07-ipsec-wan-scenarios-kit-design.md`): `esp4`
and `xfrm_user` are loaded on demand with no host preload.

**What can stop autoload.** Two sysctls
(<https://raw.githubusercontent.com/torvalds/linux/v6.8/Documentation/admin-guide/sysctl/kernel.rst>):
`kernel.modules_disabled=1` (one-way until reboot) and an empty
`kernel.modprobe`. Ubuntu noble's kmod blacklist
(`blacklist-rare-network.conf`) lists only ax25, netrom, x25, rose, decnet,
econet, rds and af_802154; nothing for xfrm, vti or esp
(<https://git.launchpad.net/ubuntu/+source/kmod/plain/debian/modprobe.d/blacklist-rare-network.conf?h=ubuntu/noble>).
AppArmor in v6.8 registers no `kernel_module_request` hook. No script under
`scripts/` sets either sysctl today.

## 2. Creating the interface inside the container

- **Per-namespace.** `xfrm_interface` registers pernet operations and
  `xfrmi_newlink` binds the device to `dev_net(dev)`, the namespace it is
  created in. It can be created directly in a non-init namespace. The SAs
  and policies charon installs live in that same namespace, which is what a
  self-contained gateway node needs.
- **Capabilities.** Docker's `--privileged` "gives all capabilities to the
  container" (<https://docs.docker.com/engine/containers/run/>), so the node
  has `CAP_NET_ADMIN` (and `CAP_SYS_MODULE`, which is not needed).
- **`dev` is optional.** In v6.8 `IFLA_XFRM_LINK` is parsed only if present.
  It was mandatory in v4.19 and optional by v5.3 (commit 22d6552f827e,
  "xfrm interface: fix management of phydev":
  <https://patchwork.ozlabs.org/project/netdev/patch/20190916153627.19458-1-nicolas.dichtel@6wind.com/>).
  When given, it copies headroom and MAC from the lower device and sets the
  output interface for the flow lookup; it does not set the MTU and cannot
  be changed afterwards. strongSwan's docs: "The underlying interface
  currently is optional and doesn't really matter".
- **`if_id` must be non-zero** in v6.8 ("if_id must be non zero"). The
  ip-link man page is stale on both points (it still shows `dev` as
  required and says the key defaults to 0).
- So the command is `ip link add <name> type xfrm if_id <n>`, then
  `ip link set <name> up`. The interface dies with the container's
  namespace, so the node script recreates it on every `up`.

## 3. The strongSwan side

Source for this section unless noted:
<https://docs.strongswan.org/docs/latest/features/routeBasedVpn.html> and
<https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html>.

- **Versions.** "strongSwan supports XFRM interfaces since version 5.8.0";
  kernel 4.19+, iproute2 5.1.0+. The bundled strongSwan image is newer than
  all three thresholds (its tag is in the pin block).
- **`if_id_in` / `if_id_out`** are set per connection or per child in
  `swanctl.conf`, default 0 (off). A fixed number links the SA and policies
  to the interface with the same ID. `%unique` allocates one ID per IKE SA
  (connection level) or per CHILD SA (child level); `%unique-dir` one per
  direction. A fixed ID is the simple case for a site-to-site scenario.
- **Who creates the interface.** Not charon. The docs give manual
  `ip link add <name> type xfrm if_id <id> [dev <underlying>]`, or the
  `xfrmi` utility "if iproute2 can not create the interface", or custom
  vici/updown scripts for dynamic IDs. With a fixed ID the interface can
  exist before the SA does; traffic routed to it with no matching SA is
  dropped by the kernel.
- **Routes.** "By default, the daemon will not install any routes for
  CHILD_SAs with outbound interface ID, so it's not necessary to disable
  the route installation globally." `charon.install_routes` can stay at its
  default. Since 5.9.10 an opt-in,
  `charon.plugins.kernel-netlink.install_routes_xfrmi` (default no), makes
  charon install routes via the interface into table 220; a BGP scenario
  wants it left off so FRR owns the routes.
- **Traffic selectors.** Because policies only affect traffic routed into
  the interface, both ends can negotiate `0.0.0.0/0` and let routing decide
  what is tunnelled. That is the shape BGP over the tunnel needs.
- **Routing-loop trap.** If a route through the tunnel also covers the
  peer's outer address, IKE and ESP loop into the tunnel. The docs give two
  fixes: marks (`charon.plugins.socket-default.fwmark`, the child's
  `set_mark_out`, `charon.plugins.kernel-netlink.fwmark`), or a more
  specific route to the peer. In the kit's addressing the outer addresses
  are in 198.18.0.0/15 and the sites in 10.x, so the loop only appears if a
  default or covering route is advertised over the tunnel.
- **Addresses.** "No tunnel endpoint addresses have to be configured on the
  interfaces. Addresses, if necessary, can be added with ip addr".

**What changes for BGP (FRR) over the tunnel.** Compared with S1's
`scenarios/s1-w1-ss/nodes/gw-a.swanctl.conf`:

- the child gains `if_id_in` / `if_id_out` and its selectors widen to
  `0.0.0.0/0`;
- the node script (the pattern in `scenarios/s1-w1-ss/nodes/gw-a.sh`) adds
  the interface and gives it a /30 or /31 so the BGP peer is directly
  connected;
- `start_action = trap` still works: the trap policy carries the if_id, so
  the first packet routed into the interface (BGP's own TCP SYN) brings the
  tunnel up;
- FRR needs the usual eBGP items: a numbered peer on the tunnel subnet needs
  no `ebgp-multihop`, and `bgp ebgp-requires-policy` is on by default
  (<https://docs.frrouting.org/en/latest/bgp.html>);
- BGP must run in the same network namespace as the xfrm interface if the
  gateway itself is to route on what it learns. The roadmap row IP5-a in
  `docs/superpowers/plans/2026-10-07-ipsec-wan-scenarios.md` already notes
  that the strongSwan image carries no FRR and proposes two nodes. With two
  nodes the FRR router is not on the tunnel interface; it peers *through*
  the gateway (multihop, or loopback peering), and the gateway still needs
  static routes into the xfrm interface. That is a scope and image
  question, not a host question.

The strongSwan docs say nothing about MTU, `rp_filter` or routing protocols
on an XFRM interface. One documented caveat: the netfilter IPsec policy
match does not see output traffic forwarded over an XFRM interface.

## 4. VTI, and why XFRM interfaces are preferred

From the same strongSwan page:

- VTI ties policies to the device through a mark that doubles as the
  tunnel's GRE key; XFRM interfaces use a separate `if_id`: "No awkward
  configuration via GRE keys and XFRM marks."
- VTI devices have mandatory tunnel endpoints, "Only one such device with
  the same local IP may be created" for wildcard remotes, and a 1:1 mapping
  between SAs and devices. XFRM interfaces need no endpoint addresses and
  several peers can share one.
- VTI is one address family per device and tunnel mode only; an XFRM
  interface carries IPv4 and IPv6 SAs and other modes.
- With VTI, "the route installation by the IKE daemon must be disabled"
  (`charon.install_routes = 0`), `disable_policy` should be set on the
  device, and the connmark plugin must be off. None of that applies to XFRM
  interfaces.
- "On newer kernels (4.19+), XFRM interfaces provide a better solution than
  VTI devices".

For the host the two are equal: `ip_vti` ships in the same base package and
has the same kind of rtnl-link alias. VTI buys nothing on this kernel.

## 5. GNS3 docker nodes

- **Privileged, all capabilities** (O4, measured:
  `docs/rehearsals/2026-11-10-ipsec-wan.md`). Enough for everything above.
- **Interfaces attached after container start.** This does not bite, for
  two reasons. The kit configures nodes with `docker exec` from
  `scripts/r770-scenario.sh up`, after GNS3 has started the node and
  attached its links. And the xfrm interface needs no `dev`, so it has no
  dependency on `eth1` existing.
- **The side effect is host-wide.** The first `ip link add ... type xfrm`
  in any node loads `xfrm_interface` into the one shared kernel and it
  stays loaded until reboot or an explicit `modprobe -r`. It is inert
  without interfaces. Every container shares that module state; there is no
  per-node isolation of it.

## What this means for the kit

- **S2 does not need a gated host change to function.** The roadmap's
  planned addition (`r770-gns3-deploy.sh labnet` gains an
  `/etc/modules-load.d/` file, gated, rollback = remove the file) and the
  input spec's 9.1 list (`xfrm_user`, `xfrm_interface`, `esp4`, `esp6`) are
  not required by the kernel. Increment 1 already relies on the same
  on-demand loading for `esp4` and `xfrm_user`.
- **What a preload would buy** is determinism, not function: the module is
  present before the first scenario instead of appearing as a side effect
  of an ungated `up`, and a box hardened with `kernel.modules_disabled`
  would still work. It would also satisfy the letter of the input spec's
  E7 ("No kernel-module loading from inside the container — the host
  preloads"), though the node never calls `modprobe`; the kernel does.
- **If the design does want one**, `labnet` is the natural owner, and its
  gate (`gate "<what>" <current-fn> <proposed-fn> "<rollback>"` in
  `scripts/r770-gns3-deploy.sh`) would print: current = whether the file
  exists and whether the module is loaded; proposed = the file's one line
  and a `modprobe`; rollback = remove the file (and `modprobe -r` with no
  endpoint running).
- **A cheaper alternative** is a check with no host change: a scenario
  prerequisite or a `r770-validate.sh` line that the module file exists
  under `/lib/modules/$(uname -r)` and that `kernel.modules_disabled` is 0,
  which SKIPs or refuses by name, in line with "discover, never guess".
- **Nothing new in the bundle** for the host: the module is in the kernel
  package the box already runs.

## Unconfirmed

Nothing below was contradicted; it was simply not proven.

1. **Not run anywhere.** `ip link add x type xfrm if_id 1` inside a GNS3
   node on staging VM 9770 (then `lsmod | grep xfrm_interface` on the host)
   is the one-line proof of sections 1 and 2. Until a transcript shows it,
   autoload from the container is "read from v6.8 source", not measured.
2. **The R770's actual kernel.** No rehearsal record states `uname -r`. The
   bundle carries the HWE metapackage; only the 6.8.0-31 file list was
   read, and the HWE `linux-modules` list was not. Mainline source was
   read, not Ubuntu's patched tree.
3. **`CONFIG_XFRM_INTERFACE=m`** is inferred from the shipped `.ko.zst`;
   the annotations file was not read. The `linux-modules-extra` file list
   (the negative check) timed out.
4. **Usermode helper namespaces.** That the kernel's `modprobe` runs in the
   host's namespaces is inferred from the comments in `kernel/umh.c`, not
   from an explicit statement.
5. **The bundled strongSwan image's contents**: whether its iproute2
   accepts `type xfrm` (very likely, given its age), whether it ships
   `xfrmi`, and whether it has FRR (the roadmap says no).
6. **charon creating XFRM interfaces itself**: not found in the route-based
   VPN page or the part of the strongswan.conf reference that was read.
   Treated here as "not supported; a script creates it".
7. **`start_action = trap` with an if_id** bringing the tunnel up on BGP's
   first SYN: follows from how trap policies work, but not quoted from the
   docs and not run.
8. **Exact kernel versions** for optional `dev` (between 4.19 and 5.3) and
   for the non-zero `if_id` check (absent in 5.4, present in 6.8). Neither
   matters on 6.8 or later.
9. **MTU and `rp_filter` on the tunnel interface** under BGP: no primary
   source covers it; the underlay validation should measure it.
