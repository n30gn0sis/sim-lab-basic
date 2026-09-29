# srv: a TLS server on br-lab through tap-b. A self-signed certificate for
# tls.scenario.lab is generated here at up (lab traffic only, not a secret),
# so Zeek's ssl.log/x509.log and Arkime see a real handshake with SNI and a
# certificate subject. openssl s_server -www answers every request; fully
# detached, so docker exec returns.
set -e
ip addr replace 10.207.0.20/24 dev eth0
ip link set dev eth0 up
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=tls.scenario.lab" \
    -keyout /tmp/lab-tls.key -out /tmp/lab-tls.crt >/dev/null 2>&1
(openssl s_server -accept 443 -cert /tmp/lab-tls.crt -key /tmp/lab-tls.key -www -quiet) </dev/null >/dev/null 2>&1 &
