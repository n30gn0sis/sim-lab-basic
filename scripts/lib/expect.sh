#!/usr/bin/env bash
#
# expect.sh — one scenario expect.txt row (proto|port|src|dst), as the queries
# that find it. Sourced after common.sh by r770-malcolm-deploy.sh (the
# generated saved searches and Arkime views) and r770-scenario.sh (check), so
# what a dashboard shows and what the check proves are the same query.
#
# The protocol set is closed on purpose: a protocol this file does not know is
# a refusal (expect_problem), never a guess. Adding one is a line in
# expect_iana or the named list, and a test.

# expect_rows <scenario-dir> — "<n>|<proto>|<port>|<src>|<dst>" per data line
# of its expect.txt; n counts data lines only (comments and blank lines are
# skipped). '|' and not a tab: bash's read collapses an empty field between
# tabs, and the port is often empty.
expect_rows() {
    local f="$1/expect.txt" line n=0 proto port src dst
    [ -f "$f" ] || die "no expect.txt in $1"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        n=$((n + 1))
        IFS='|' read -r proto port src dst <<< "$line"
        printf '%s|%s|%s|%s|%s\n' "$n" "$proto" "$port" "$src" "$dst"
    done < "$f"
}

# expect_cidr <string> — 0 for an IPv4 CIDR a.b.c.d/len (octets 0-255, len 0-32)
expect_cidr() {
    local o
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    for o in 1 2 3 4; do [ "$((10#${BASH_REMATCH[$o]}))" -le 255 ] || return 1; done
    [ "$((10#${BASH_REMATCH[5]}))" -le 32 ]
}

# expect_iana <proto> — the IP protocol number of a protocol matched by number
expect_iana() {
    case "$1" in
        esp)  echo 50 ;;
        ah)   echo 51 ;;
        ospf) echo 89 ;;
        *)    return 1 ;;
    esac
}

# expect_problem <proto> <port> <src> <dst> — why this row cannot be
# translated; empty when it can. Callers name the file and row around it.
expect_problem() {
    local proto=$1 port=$2 src=$3 dst=$4
    case "$proto" in
        tcp|udp) ;;
        icmp|esp|ah|ospf)
            if [ -n "$port" ]; then printf '%s carries no port (got %s)' "$proto" "$port"; return 0; fi ;;
        *)  printf "unknown protocol '%s' (known: tcp udp icmp esp ah ospf)" "$proto"; return 0 ;;
    esac
    if [ -n "$port" ]; then
        if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
            printf "port '%s' is not 1-65535" "$port"; return 0
        fi
    fi
    expect_cidr "$src" || { printf "src '%s' is not an IPv4 CIDR" "$src"; return 0; }
    expect_cidr "$dst" || { printf "dst '%s' is not an IPv4 CIDR" "$dst"; return 0; }
    return 0
}

# expect_arkime <proto> <port> <src> <dst> — the Arkime expression. A port
# matches either side: IKE is 500<->500, and a reply's source port is the
# request's destination.
expect_arkime() {
    local proto=$1 port=$2 src=$3 dst=$4 q
    case "$proto" in
        tcp|udp|icmp) q="ip.protocol == $proto" ;;
        *)            q="ip.protocol == $(expect_iana "$proto")" ;;
    esac
    [ -z "$port" ] || q="$q && port == $port"
    printf '%s && ip.src == %s && ip.dst == %s' "$q" "$src" "$dst"
}

# expect_kql <proto> <port> <src> <dst> — the Dashboards query (KQL, the
# language the kit's IPsec searches use), over Malcolm's ECS field names
expect_kql() {
    local proto=$1 port=$2 src=$3 dst=$4 q
    case "$proto" in
        tcp|udp|icmp) q="network.transport:$proto" ;;
        *)            q="network.iana_number:$(expect_iana "$proto")" ;;
    esac
    [ -z "$port" ] || q="$q and (source.port:$port or destination.port:$port)"
    printf '%s and source.ip:"%s" and destination.ip:"%s"' "$q" "$src" "$dst"
}

# expect_label <proto> <port> <src> <dst> — "<proto>[/<port>] <src> -> <dst>"
expect_label() {
    printf '%s%s %s -> %s' "$1" "${2:+/$2}" "$3" "$4"
}
