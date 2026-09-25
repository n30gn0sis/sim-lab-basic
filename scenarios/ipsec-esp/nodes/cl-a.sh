# cl-a: client behind gw-a
set -e
ip addr replace 10.201.1.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.201.1.1
