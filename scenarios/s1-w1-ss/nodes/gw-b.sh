# gw-b: strongSwan CE for site B — LAN eth0, uplink eth1. Ground truth under /gt
# (charon log, SA snapshots by the harness, ESP/IKE keys if save-keys exists).
set -e
mkdir -p /gt/keys
# save-keys is enabled only when the bundled image carries the plugin — discovered, never assumed
if ls /usr/lib*/ipsec/plugins/libstrongswan-save-keys.so >/dev/null 2>&1; then
    mkdir -p /etc/strongswan.d/charon
    # strongswan.conf includes strongswan.d/charon/*.conf INSIDE charon { plugins { } }, so the
    # file holds the plugin's own section only (staging 2026-11-10: read from the image)
    printf 'save-keys {\n  load = yes\n  esp = yes\n  ike = yes\n  wireshark_keys = /gt/keys\n}\n' > /etc/strongswan.d/charon/save-keys.conf
    echo present > /gt/keys.state
else
    echo absent > /gt/keys.state
fi
ip addr replace 10.211.2.1/24 dev eth0
ip addr replace 198.18.11.6/30 dev eth1
ip link set dev eth0 up; ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace default via 198.18.11.5
# charon writes nothing to stdout or stderr unless a logger says so (staging 2026-11-10:
# the redirected log stayed empty), so the ground-truth log is a filelog of its own
printf 'charon {\n  filelog {\n    gt {\n      path = /gt/charon.log\n      time_format = %%Y-%%m-%%dT%%H:%%M:%%S\n      default = 1\n      flush_line = yes\n    }\n  }\n}\n' > /etc/strongswan.d/gt-log.conf
# the image does not start charon by itself (ipsec-ike, staging 2026-09-25)
pgrep -x charon >/dev/null || /usr/libexec/ipsec/charon </dev/null >/dev/null 2>&1 &
