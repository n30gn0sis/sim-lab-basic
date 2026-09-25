# gw-b: addresses and forwarding; the tunnel itself comes from gw-b.swanctl.conf
set -e
ip addr replace 10.202.2.1/24 dev eth0
ip addr replace 10.202.0.2/24 dev eth1
ip link set dev eth0 up
ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace 10.202.1.0/24 via 10.202.0.1
