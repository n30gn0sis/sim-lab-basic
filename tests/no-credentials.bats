#!/usr/bin/env bats
# Secret protection lives IN the repo. Evidence transcripts, generated
# credentials and bundles must be ignored by the kit's own .gitignore, and no
# credential-shaped string may be tracked.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

ignored() { env GIT_CONFIG_GLOBAL=/dev/null git -c core.excludesFile=/dev/null check-ignore -q "$1"; }

@test "a .gitignore exists in the repo" { [ -f .gitignore ]; }

@test "evidence, secrets, rendered files, bundles and local agent settings are ignored by the REPO" {
    ignored r770-evidence/
    ignored r770-evidence/import-bundle-host-0.log
    ignored etc/lab/secrets/malcolm-admin.pw
    ignored grafana-admin.env
    ignored something.rendered
    ignored bundle-20260908/
    ignored .claude/settings.local.json
}

@test "no credential-shaped string is tracked" {
    run grep -rnE 'sshpass -p [^$]|BEGIN [A-Z ]*PRIVATE KEY|GF_SECURITY_ADMIN_PASSWORD=[A-Za-z0-9]{8,}' --exclude-dir=.git --exclude-dir=tests .
    echo "$output"
    [ "$status" -ne 0 ]
}

@test "no script echoes a secret it read" {
    # secret_read results must never be interpolated into echo/note/pass lines
    run grep -nE '(echo|note|pass|warn|fail) .*\$\{?pw\}?' scripts/*.sh
    echo "$output"
    [ "$status" -ne 0 ]
}
