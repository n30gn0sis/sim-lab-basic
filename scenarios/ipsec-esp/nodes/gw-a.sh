# gw-a: 10.201.1.0/24 <-> ESP tunnel to gw-b across br-lab (eth1, 10.201.0.0/24).
# Manually keyed: lab keys, not secrets -- they only ever protect lab traffic.
set -e
ip addr replace 10.201.1.1/24 dev eth0
ip addr replace 10.201.0.1/24 dev eth1
ip link set dev eth0 up
ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace 10.201.2.0/24 via 10.201.0.2
ip xfrm state flush
ip xfrm policy flush
ip xfrm state add src 10.201.0.1 dst 10.201.0.2 proto esp spi 0x201a mode tunnel \
    enc 'cbc(aes)' 0x2010aaaa2010aaaa2010aaaa2010aaaa \
    auth 'hmac(sha256)' 0x2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb2010bbbb
ip xfrm state add src 10.201.0.2 dst 10.201.0.1 proto esp spi 0x201b mode tunnel \
    enc 'cbc(aes)' 0x2010cccc2010cccc2010cccc2010cccc \
    auth 'hmac(sha256)' 0x2010dddd2010dddd2010dddd2010dddd2010dddd2010dddd2010dddd2010dddd
ip xfrm policy add src 10.201.1.0/24 dst 10.201.2.0/24 dir out tmpl src 10.201.0.1 dst 10.201.0.2 proto esp mode tunnel
ip xfrm policy add src 10.201.2.0/24 dst 10.201.1.0/24 dir in tmpl src 10.201.0.2 dst 10.201.0.1 proto esp mode tunnel
ip xfrm policy add src 10.201.2.0/24 dst 10.201.1.0/24 dir fwd tmpl src 10.201.0.2 dst 10.201.0.1 proto esp mode tunnel
