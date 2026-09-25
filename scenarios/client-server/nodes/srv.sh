# srv: a one-page web server on br-lab through tap-b. Stock alpine's busybox
# has no httpd, so a busybox nc loop answers every connection on port 80 with
# a fixed HTTP reply; fully detached, so docker exec returns.
set -e
ip addr replace 10.205.0.20/24 dev eth0
ip link set dev eth0 up
(while :; do printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nlab-scenario client-server\n' | nc -l -p 80; done) </dev/null >/dev/null 2>&1 &
