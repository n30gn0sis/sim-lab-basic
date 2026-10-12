# gw-a: strongSwan CE for site A — LAN eth0, uplink eth1. Ground truth under /gt
# (charon log, SA snapshots by the harness, ESP/IKE keys if save-keys exists).
set -e
mkdir -p /gt/keys
# save-keys is enabled only when the bundled image carries the plugin — discovered, never assumed
if ls /usr/lib*/ipsec/plugins/libstrongswan-save-keys.so >/dev/null 2>&1; then
    mkdir -p /etc/strongswan.d/charon
    printf 'charon {\n  plugins {\n    save-keys {\n      load = yes\n      esp = yes\n      ike = yes\n      wireshark_keys = /gt/keys\n    }\n  }\n}\n' > /etc/strongswan.d/charon/save-keys.conf
    echo present > /gt/keys.state
else
    echo absent > /gt/keys.state
fi
ip addr replace 10.211.1.1/24 dev eth0
ip addr replace 198.18.11.2/30 dev eth1
ip link set dev eth0 up; ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace default via 198.18.11.1
# the image does not start charon by itself (ipsec-ike, staging 2026-09-25); log to /gt
pgrep -x charon >/dev/null || /usr/libexec/ipsec/charon </dev/null >/gt/charon.log 2>&1 &
