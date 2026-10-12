# h-b: host behind gw-b (site B)
set -e
ip addr replace 10.210.2.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.210.2.1
