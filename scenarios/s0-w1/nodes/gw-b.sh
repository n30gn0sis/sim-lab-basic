# gw-b: CE router for site B — LAN on eth0, uplink to isp1 on eth1
set -e
ip addr replace 10.210.2.1/24 dev eth0
ip addr replace 198.18.10.6/30 dev eth1
ip link set dev eth0 up; ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace default via 198.18.10.5
