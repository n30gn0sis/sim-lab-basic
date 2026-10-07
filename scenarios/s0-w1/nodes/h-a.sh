# h-a: host behind gw-a (site A)
set -e
ip addr replace 10.210.1.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.210.1.1
