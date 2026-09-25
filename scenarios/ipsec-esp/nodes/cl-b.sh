# cl-b: client behind gw-b
set -e
ip addr replace 10.201.2.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.201.2.1
