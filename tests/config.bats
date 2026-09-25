#!/usr/bin/env bats
#
# The carried config must stay deployable on the R770 as measured, not as
# remembered: the directive form nginx 1.24 accepts, no staging leftovers,
# only tokens the kit knows how to render, and a compose file whose images
# all come from the bundle-derived .env.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

@test "every vhost uses the listen-line http2 form the bundled nginx accepts" {
    for f in config/nginx/*.lab.conf; do
        grep -q 'listen 443 ssl http2;' "$f" || { echo "$f lacks 'listen 443 ssl http2;'"; false; }
    done
    run grep -rn 'http2 on;' config/nginx
    [ "$status" -ne 0 ]
}

@test "no staging-host leftovers in config/" {
    run grep -rnE '192\.168\.|/home/ubuntu|~/|r770-staging|staging rehearsal|VM 9770' config/ --exclude=README.md
    echo "$output"
    [ "$status" -ne 0 ]
}

@test "every __TOKEN__ in config/ is one the kit renders" {
    known='ADMIN_PW PCAP_NODE_NAME OS_MEMORY LS_MEMORY ARKIME_MANAGE_PCAP ARKIME_FREE_SPACE_G MALCOLM_VER NETWORK_INDEX_PATTERN_ID TAP_NAME TAP_USER PCAP_IFACE CAPTURE_LIVE LIVE_ARKIME LIVE_ZEEK'
    bad=""
    while read -r t; do
        n=${t#__}; n=${n%__}
        case " $known " in *" $n "*) ;; *) bad="$bad $t" ;; esac
    done < <(grep -rhoE '__[A-Z][A-Z0-9_]*__' config/ --exclude=README.md | sort -u)
    echo "unknown:$bad"
    [ -z "$bad" ]
}

@test "the documented token table in config/README.md names every token in use" {
    while read -r t; do
        grep -q -- "\`$t\`" config/README.md || { echo "undocumented token $t"; false; }
    done < <(grep -rhoE '__[A-Z][A-Z0-9_]*__' config/ --exclude=README.md | sort -u)
}

@test "the GNS3 template carries no jwt_secret_key line (measured: not honoured)" {
    run grep -n '^jwt_secret_key' config/gns3/gns3_server.conf.template
    [ "$status" -ne 0 ]
}

@test "the Malcolm config template pins storage to the data volumes and disables what an air gap cannot do" {
    t=config/malcolm/malcolm-config.json.template
    grep -q '"pcapDir": "/data/pcap/raw"' "$t"
    grep -q '"indexDir": "/data/index"' "$t"
    grep -q '"useDefaultStorageLocations": false' "$t"
    grep -q '"autoSuricata": false' "$t"
    grep -q '"zeekPullIntelligenceFeeds": false' "$t"
    grep -q '"version": "__MALCOLM_VER__"' "$t"
}
