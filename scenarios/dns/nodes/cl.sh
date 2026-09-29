# cl: the resolver's client, on br-lab through tap-a
set -e
ip addr replace 10.206.0.10/24 dev eth0
ip link set dev eth0 up
