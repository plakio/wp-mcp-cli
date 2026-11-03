#!/usr/bin/env bash
# Security hardening tests for wp-mcp-cli. No WordPress site required.
#
# Covers:
#   - The application password is not in curl/jq argv or the child environment.
#   - Credentials reach curl through a config on STDIN.
#   - Request bodies and response envelopes are passed on STDIN, not argv.
#   - Network failures produce a stable error envelope instead of a raw exit.
#
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WPMCP="${WPMCP:-$ROOT_DIR/wp-mcp.sh}"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wpmcp-hardening.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

if [ ! -x "$WPMCP" ]; then
    echo "Compiling wp-mcp.sh..."
    (cd "$ROOT_DIR" && ./compile.sh >/dev/null)
fi

REAL_JQ=$(command -v jq || true)
REAL_CURL=$(command -v curl || true)
if [ -z "$REAL_JQ" ] || [ -z "$REAL_CURL" ]; then
    echo "jq and curl are required for the hardening tests." >&2
    exit 1
fi

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    echo "  PASS  $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL  $1"
    shift
    local line
    for line in "$@"; do
        echo "        $line"
    done
}

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label" "expected: $expected" "actual:   $actual"
    fi
}

assert_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -Fq -- "$needle" "$file"; then
        pass "$label"
    else
        fail "$label" "missing in $file: $needle"
    fi
}

assert_not_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -Fq -- "$needle" "$file"; then
        fail "$label" "unexpected in $file: $needle"
    else
        pass "$label"
    fi
}

# Fake curl: records argv, environment, stdin (the credential config), and the
# body file. It then returns a canned response. The response format is the
# same "BODY<status>" shape the real CLI expects.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
log_dir="${WPMCP_TEST_CURL_DIR:?WPMCP_TEST_CURL_DIR is required}"
printf '%s\n' "$@" > "$log_dir/argv.txt"
env > "$log_dir/env.txt"

: > "$log_dir/stdin.txt"
while IFS= read -r -t 0.1 line; do
    printf '%s\n' "$line" >> "$log_dir/stdin.txt"
done

body_file=""
for arg in "$@"; do
    case "$arg" in
        @*) body_file="${arg#@}" ;;
    esac
done
if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    cp "$body_file" "$log_dir/body.txt"
fi

if [ "${WPMCP_TEST_CURL_FAIL:-0}" = "1" ]; then
    exit 7
fi

if [ -f "$log_dir/response.txt" ]; then
    cat "$log_dir/response.txt"
else
    printf '{"ok":true}200'
fi
SH
chmod +x "$FAKE_BIN/curl"

# Fake jq: records argv, then delegates to the real jq. This proves large
# payloads stay out of jq's argument list.
cat > "$FAKE_BIN/jq" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$@" >> "\${WPMCP_TEST_JQ_DIR:?}/argv.txt"
env > "\${WPMCP_TEST_JQ_DIR:?}/env.txt"
exec "$REAL_JQ" "\$@"
SH
chmod +x "$FAKE_BIN/jq"

CURL_LOG="$TEST_DIR/curl-log"
JQ_LOG="$TEST_DIR/jq-log"
reset_logs() {
    rm -rf "$CURL_LOG" "$JQ_LOG"
    mkdir -p "$CURL_LOG" "$JQ_LOG"
}

# A disposable WPMCP_HOME with one profile and one application password.
WPMCP_TEST_HOME="$TEST_DIR/wp-mcp-home"
mkdir -p "$WPMCP_TEST_HOME/credentials"
chmod 700 "$WPMCP_TEST_HOME" "$WPMCP_TEST_HOME/credentials"
cat > "$WPMCP_TEST_HOME/sites.json" <<'JSON'
{"version":1,"profiles":{"test":{"name":"test","siteUrl":"https://example.test","origin":"https://example.test","defaultUser":"admin","createdAt":"2026-11-03T00:00:00Z"}}}
JSON
cat > "$WPMCP_TEST_HOME/credentials/test.json" <<'JSON'
{"site":"test","username":"admin","app_password":"super secret pass","created_at":"2026-11-03T00:00:00Z"}
JSON
chmod 600 "$WPMCP_TEST_HOME/sites.json" "$WPMCP_TEST_HOME/credentials/test.json"

USER_HOME="$TEST_DIR/user-home"
mkdir -p "$USER_HOME"

echo "Running wp-mcp-cli hardening tests"

# 1. Credentials never reach curl argv or the child environment.
echo
echo "Credentials"
reset_logs
(
    export PATH="$FAKE_BIN:$PATH"
    export WPMCP_TEST_CURL_DIR="$CURL_LOG"
    WPMCP_ACTIVE_USER="admin"
    WPMCP_ACTIVE_PASS="super secret pass"
    # shellcheck disable=SC1091
    source "$ROOT_DIR/shared/http.sh"
    wpmcp_http_get "https://example.test/wp-json/" >/dev/null
)
assert_not_contains "password not in curl argv" "$CURL_LOG/argv.txt" "super secret pass"
assert_not_contains "password not in curl environment" "$CURL_LOG/env.txt" "super secret pass"
assert_contains "password in curl config stdin" "$CURL_LOG/stdin.txt" 'user = "admin:super secret pass"'
assert_contains "curl uses --config -" "$CURL_LOG/argv.txt" "--config"
assert_contains "curl uses --basic" "$CURL_LOG/argv.txt" "--basic"

# 2. Unusual credentials are escaped in the curl config.
reset_logs
(
    export PATH="$FAKE_BIN:$PATH"
    export WPMCP_TEST_CURL_DIR="$CURL_LOG"
    WPMCP_ACTIVE_USER="admin"
    WPMCP_ACTIVE_PASS='pa"ss\word'
    # shellcheck disable=SC1091
    source "$ROOT_DIR/shared/http.sh"
    wpmcp_http_get "https://example.test/wp-json/" >/dev/null
)
assert_contains "curl config escapes quotes and backslashes" "$CURL_LOG/stdin.txt" 'user = "admin:pa\"ss\\word"'

# 3. auth login: the probe and the credential save keep the password out of
# curl/jq argv and the child environment.
echo
echo "auth login"
AUTH_HOME="$TEST_DIR/auth-home"
reset_logs
printf '{"id":1,"name":"admin"}200' > "$CURL_LOG/response.txt"
auth_rc=0
auth_out=$(
    WPMCP_HOME="$AUTH_HOME" \
        HOME="$USER_HOME" \
        PATH="$FAKE_BIN:$PATH" \
        WPMCP_TEST_CURL_DIR="$CURL_LOG" \
        WPMCP_TEST_JQ_DIR="$JQ_LOG" \
        "$WPMCP" --json auth login https://example.test --name test --user admin --password 'super secret pass' 2>"$TEST_DIR/auth.err"
) || auth_rc=$?
assert_eq "auth login exits 0" "$auth_rc" "0"
assert_eq "auth login envelope is ok" "$(printf '%s' "$auth_out" | jq -r '.ok')" "true"
assert_not_contains "auth password not in curl argv" "$CURL_LOG/argv.txt" "super secret pass"
assert_not_contains "auth password not in curl environment" "$CURL_LOG/env.txt" "super secret pass"
assert_not_contains "auth password not in jq argv" "$JQ_LOG/argv.txt" "super secret pass"
assert_not_contains "auth password not in jq environment" "$JQ_LOG/env.txt" "super secret pass"
assert_contains "auth password in curl config stdin" "$CURL_LOG/stdin.txt" 'user = "admin:super secret pass"'
assert_eq "auth login stores the exact password" "$(jq -r '.app_password' "$AUTH_HOME/credentials/test.json")" "super secret pass"

# 3b. The WPMCP_PASSWORD fallback is removed from the child environment.
AUTH_ENV_HOME="$TEST_DIR/auth-env-home"
reset_logs
printf '{"id":1,"name":"admin"}200' > "$CURL_LOG/response.txt"
auth_env_rc=0
auth_env_out=$(
    WPMCP_HOME="$AUTH_ENV_HOME" \
        HOME="$USER_HOME" \
        PATH="$FAKE_BIN:$PATH" \
        WPMCP_TEST_CURL_DIR="$CURL_LOG" \
        WPMCP_TEST_JQ_DIR="$JQ_LOG" \
        WPMCP_PASSWORD='super secret pass' \
        "$WPMCP" --json auth login https://example.test --name test --user admin 2>"$TEST_DIR/auth-env.err"
) || auth_env_rc=$?
assert_eq "auth env login exits 0" "$auth_env_rc" "0"
assert_eq "auth env login envelope is ok" "$(printf '%s' "$auth_env_out" | jq -r '.ok')" "true"
assert_not_contains "env password not in curl argv" "$CURL_LOG/argv.txt" "super secret pass"
assert_not_contains "env password not in curl environment" "$CURL_LOG/env.txt" "super secret pass"
assert_not_contains "env password not in jq argv" "$JQ_LOG/argv.txt" "super secret pass"
assert_not_contains "env password not in jq environment" "$JQ_LOG/env.txt" "super secret pass"
assert_contains "env password in curl config stdin" "$CURL_LOG/stdin.txt" 'user = "admin:super secret pass"'
assert_eq "auth env login stores the exact password" "$(jq -r '.app_password' "$AUTH_ENV_HOME/credentials/test.json")" "super secret pass"

# 4. Request bodies go through a 0600 temp file, not argv.
echo
echo "Request bodies"
reset_logs
(
    export PATH="$FAKE_BIN:$PATH"
    export WPMCP_TEST_CURL_DIR="$CURL_LOG"
    WPMCP_ACTIVE_USER="admin"
    WPMCP_ACTIVE_PASS="super secret pass"
    # shellcheck disable=SC1091
    source "$ROOT_DIR/shared/http.sh"
    wpmcp_http_post_json "https://example.test/wp-json/" '{"secret":"body data"}' >/dev/null
)
assert_not_contains "request body not in curl argv" "$CURL_LOG/argv.txt" "body data"
assert_contains "request body reaches the temp file" "$CURL_LOG/body.txt" '{"secret":"body data"}'
body_path=$(sed -n 's/^@//p' "$CURL_LOG/argv.txt" | head -n 1)
if [ -n "$body_path" ] && [ ! -e "$body_path" ]; then
    pass "request body temp file is removed"
else
    fail "request body temp file is removed" "path: ${body_path:-<none>}"
fi

# 5. End-to-end `run`: input, credentials, and envelope stay out of argv.
echo
echo "run command"
reset_logs
printf '{"entries":[],"total":0}200' > "$CURL_LOG/response.txt"
run_rc=0
run_out=$(
    printf '%s' '{"path":"/secret/path"}' | \
        WPMCP_HOME="$WPMCP_TEST_HOME" \
        HOME="$USER_HOME" \
        PATH="$FAKE_BIN:$PATH" \
        WPMCP_TEST_CURL_DIR="$CURL_LOG" \
        WPMCP_TEST_JQ_DIR="$JQ_LOG" \
        "$WPMCP" --json --site test run wp-mcp/list-directory --input - 2>"$TEST_DIR/run.err"
) || run_rc=$?
assert_eq "run exits 0" "$run_rc" "0"
assert_eq "run envelope is ok" "$(printf '%s' "$run_out" | jq -r '.ok')" "true"
assert_eq "run envelope contains the ability result" "$(printf '%s' "$run_out" | jq -r '.data.total')" "0"
assert_not_contains "input not in curl argv" "$CURL_LOG/argv.txt" "/secret/path"
assert_not_contains "input not in jq argv" "$JQ_LOG/argv.txt" "/secret/path"
assert_not_contains "password not in curl environment" "$CURL_LOG/env.txt" "super secret pass"
assert_not_contains "password not in jq environment" "$JQ_LOG/env.txt" "super secret pass"
assert_contains "password in curl config stdin" "$CURL_LOG/stdin.txt" 'user = "admin:super secret pass"'
assert_contains "request body contains the input" "$CURL_LOG/body.txt" '{"input":{"path":"/secret/path"}}'

# 6. A network failure returns the stable error envelope (exit 4), not curl's
# raw exit code.
echo
echo "Network errors"
reset_logs
net_rc=0
net_err=$(
    printf '%s' '{}' | \
        WPMCP_HOME="$WPMCP_TEST_HOME" \
        HOME="$USER_HOME" \
        PATH="$FAKE_BIN:$PATH" \
        WPMCP_TEST_CURL_DIR="$CURL_LOG" \
        WPMCP_TEST_JQ_DIR="$JQ_LOG" \
        WPMCP_TEST_CURL_FAIL=1 \
        "$WPMCP" --json --site test run wp-mcp/list-directory --input - 2>&1 >/dev/null
) || net_rc=$?
assert_eq "network failure exits 4" "$net_rc" "4"
assert_eq "network failure code" "$(printf '%s' "$net_err" | jq -r '.error.code')" "network_error"

# 7. Large ability results are handled through stdin, not jq argv.
echo
echo "Large results"
reset_logs
BIG_FILE="$TEST_DIR/big.txt"
head -c 3000000 /dev/zero | tr '\0' 'x' > "$BIG_FILE"
{
    printf '{"big":"'
    cat "$BIG_FILE"
    printf '"}200'
} > "$CURL_LOG/response.txt"
big_rc=0
big_out=$(
    printf '%s' '{}' | \
        WPMCP_HOME="$WPMCP_TEST_HOME" \
        HOME="$USER_HOME" \
        PATH="$FAKE_BIN:$PATH" \
        WPMCP_TEST_CURL_DIR="$CURL_LOG" \
        WPMCP_TEST_JQ_DIR="$JQ_LOG" \
        "$WPMCP" --json --site test run wp-mcp/list-directory --input - 2>"$TEST_DIR/big.err"
) || big_rc=$?
assert_eq "large response exits 0" "$big_rc" "0"
assert_eq "large response survives the envelope" "$(printf '%s' "$big_out" | jq -r '.data.big | length')" "3000000"
big_needle=$(head -c 64 "$BIG_FILE")
assert_not_contains "response body not in the jq environment" "$JQ_LOG/env.txt" "$big_needle"

# 8. The success envelope keeps JSON null/null, not the string "null".
echo
echo "Envelope types"
null_envelope=$(
    WPMCP_ACTIVE_SITE="test" WPMCP_ACTIVE_ORIGIN="https://example.test" \
        bash -c 'source "$1/shared/output.sh"; wpmcp_output_envelope_ok "null"' _ "$ROOT_DIR"
)
assert_eq "envelope keeps null data" "$(printf '%s' "$null_envelope" | jq -r '.data | type')" "null"
false_envelope=$(
    WPMCP_ACTIVE_SITE="test" WPMCP_ACTIVE_ORIGIN="https://example.test" \
        bash -c 'source "$1/shared/output.sh"; wpmcp_output_envelope_ok "false"' _ "$ROOT_DIR"
)
assert_eq "envelope keeps false data" "$(printf '%s' "$false_envelope" | jq -r '.data | type')" "boolean"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
