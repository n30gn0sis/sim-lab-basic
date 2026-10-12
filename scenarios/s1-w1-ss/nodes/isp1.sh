# isp1: the ISP — addresses toward each gateway and forwarding on; it routes to no site
set -e
ip addr replace 198.18.11.1/30 dev eth0
ip addr replace 198.18.11.5/30 dev eth1
ip link set dev eth0 up; ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
