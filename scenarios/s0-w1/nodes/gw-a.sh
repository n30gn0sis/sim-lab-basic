# gw-a: CE router for site A — LAN on eth0, uplink to isp1 on eth1 (through br-lab)
set -e
ip addr replace 10.210.1.1/24 dev eth0
ip addr replace 198.18.10.2/30 dev eth1
ip link set dev eth0 up; ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace default via 198.18.10.1
