# a router: links up and forwarding on; addresses and OSPF come from its frr.conf
set -e
ip link set dev eth0 up
ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
