# cl-b: client behind gw-b
set -e
ip addr replace 10.202.2.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.202.2.1
