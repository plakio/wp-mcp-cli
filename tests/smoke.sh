#!/usr/bin/env bash

# Smoke tests for wp-mcp-cli. Runs against a real local Plak site.
# Usage: WPMCP_TEST_URL=https://dev.localhost WPMCP_TEST_USER=admin \
#        WPMCP_TEST_PASSWORD=<app-password> ./tests/smoke.sh

# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_HOME="${WPMCP_TEST_HOME:-/tmp/wp-mcp-smoke}"

WPMCP="${WPMCP:-$ROOT_DIR/wp-mcp.sh}"
WPMCP_TEST_URL="${WPMCP_TEST_URL:-}"
WPMCP_TEST_USER="${WPMCP_TEST_USER:-}"
WPMCP_TEST_PASSWORD="${WPMCP_TEST_PASSWORD:-}"

if [ -z "$WPMCP_TEST_URL" ] || [ -z "$WPMCP_TEST_USER" ] || [ -z "$WPMCP_TEST_PASSWORD" ]; then
    echo "Skipping smoke tests: WPMCP_TEST_URL, WPMCP_TEST_USER, WPMCP_TEST_PASSWORD must be set." >&2
    exit 0
fi

if [ ! -x "$WPMCP" ]; then
    echo "Compiling wp-mcp.sh..."
    (cd "$ROOT_DIR" && ./compile.sh)
fi

export WPMCP_HOME="$TEST_HOME"
rm -rf "$WPMCP_HOME"
mkdir -p "$WPMCP_HOME"

pass=0
fail=0

assert_eq() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass=$((pass + 1))
        echo "  PASS  $label"
    else
        fail=$((fail + 1))
        echo "  FAIL  $label"
        echo "        expected: $expected"
        echo "        actual:   $actual"
    fi
}

run() {
    WPMCP_HOME="$WPMCP_HOME" "$WPMCP" "$@"
}

echo "Running wp-mcp-cli smoke tests against $WPMCP_TEST_URL"

# 1. version
version=$(run --json version | jq -r '.name')
assert_eq "version.name == wp-mcp" "$version" "wp-mcp"

# 2. doctor --offline
doctor_ok=$(run doctor --offline --json | jq -r '.ok')
assert_eq "doctor offline reports OK" "$doctor_ok" "true"

# 3. auth login
login_ok=$(run auth login "$WPMCP_TEST_URL" --name smoke --user "$WPMCP_TEST_USER" --password "$WPMCP_TEST_PASSWORD" --json | jq -r '.ok')
assert_eq "auth login ok" "$login_ok" "true"

# 4. sites list has the smoke profile
sites_ok=$(run --json sites list | jq -r '.data | length')
[ "$sites_ok" -ge 1 ]
assert_eq "sites list contains smoke profile" "$([ "$sites_ok" -ge 1 ] && echo true || echo false)" "true"

# 5. discover returns at least one ability
count=$(run --json discover | jq -r '.data.abilities | length')
assert_eq "discover returns >=1 ability" "$([ "$count" -ge 1 ] && echo true || echo false)" "true"

# 6. describe a known ability
desc_name=$(run --json describe wp-mcp/list-directory | jq -r '.data.name')
assert_eq "describe returns the right ability" "$desc_name" "wp-mcp/list-directory"

# 7. run a readonly ability (non-destructive)
total=$(run run wp-mcp/list-directory --input '{"path":"/Users/oscarhugopaz/Plak/Sites/dev.localhost/public"}' --json | jq -r '.data.total')
assert_eq "list-directory returns >=1 entry" "$([ "$total" -ge 1 ] && echo true || echo false)" "true"

# 8. destructive ability without --yes returns confirmation_required
rc=0
out=$(run run wp-mcp/delete-file --input '{"path":"/tmp/nope"}' </dev/null 2>&1) || rc=$?
assert_eq "destructive op without --yes exits 6" "$rc" "6"

# 9. nonexistent ability returns 404 with wp_mcp_ability_not_found
rc=0
out=$(run --json run wp-mcp/nonexistent-ability 2>&1) || rc=$?
code=$(echo "$out" | jq -r '.error.code' 2>/dev/null || echo "")
assert_eq "nonexistent ability returns exit 2" "$rc" "2"
assert_eq "nonexistent ability returns wp_mcp_ability_not_found" "$code" "wp_mcp_ability_not_found"

# 10. auth logout
logout_ok=$(run --json auth logout | jq -r '.ok')
assert_eq "auth logout ok" "$logout_ok" "true"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
