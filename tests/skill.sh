#!/usr/bin/env bash
# Skill installer tests. No WordPress site and no network required.
#
# Covers:
#   - A released binary installs the SKILL.md from its own version tag.
#   - The installer never falls back to the main branch.
#   - A local checkout wins over the network and matches the edited code.
#   - A failed download exits with network_error and names the version.
#
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WPMCP="${WPMCP:-$ROOT_DIR/wp-mcp.sh}"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wpmcp-skill.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

if [ ! -x "$WPMCP" ]; then
    echo "Compiling wp-mcp.sh..."
    (cd "$ROOT_DIR" && ./compile.sh >/dev/null)
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for the skill tests." >&2
    exit 1
fi

VERSION="$(jq -r '.version' <<<"$("$WPMCP" --json version)")"
EXPECTED_URL="https://raw.githubusercontent.com/plakio/wp-mcp-cli/v${VERSION}/skills/wp-mcp/SKILL.md"

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

# Fake curl: records argv and writes a sentinel to the -o target.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" >> "${WPMCP_TEST_CURL_LOG:?WPMCP_TEST_CURL_LOG is required}"

out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            out="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ "${WPMCP_TEST_CURL_FAIL:-0}" = "1" ]; then
    exit 22
fi
printf '%s\n' "downloaded skill" > "$out"
SH
chmod +x "$FAKE_BIN/curl"

HOME_DIR="$TEST_DIR/home"
mkdir -p "$HOME_DIR/skills-target"
CURL_LOG="$TEST_DIR/curl.log"

# An installed binary: no skills/ next to the script.
INSTALLED_DIR="$TEST_DIR/installed"
mkdir -p "$INSTALLED_DIR"
cp "$WPMCP" "$INSTALLED_DIR/wp-mcp.sh"
chmod +x "$INSTALLED_DIR/wp-mcp.sh"

install_installed() {
    HOME="$HOME_DIR" \
    WPMCP_HOME="$HOME_DIR/.wp-mcp" \
    WPMCP_TEST_CURL_LOG="$CURL_LOG" \
    PATH="$FAKE_BIN:$PATH" \
    "$INSTALLED_DIR/wp-mcp.sh" skill install opencode
}

echo "Running wp-mcp-cli skill installer tests"

# 1. Installed binary downloads from the matching tag.
: > "$CURL_LOG"
set +e
OUT=$(install_installed 2>&1)
RC=$?
set -e

assert_eq "install exits 0" "$RC" "0"
assert_contains "downloads from the version tag" "$CURL_LOG" "$EXPECTED_URL"
assert_not_contains "does not download from main" "$CURL_LOG" "/cli/main/skills/"
assert_contains "reports the destination" <(printf '%s\n' "$OUT") "opencode/skills/wp-mcp/SKILL.md"
assert_eq "installed skill content" \
    "$(cat "$HOME_DIR/.config/opencode/skills/wp-mcp/SKILL.md")" \
    "downloaded skill"

# 2. A failed download is a network error that names the version.
rm -rf "$HOME_DIR/.config"
: > "$CURL_LOG"
set +e
ERR=$(WPMCP_TEST_CURL_FAIL=1 install_installed 2>&1 >/dev/null)
RC=$?
set -e

assert_eq "failed download exits 4" "$RC" "4"
assert_contains "failed download names the version" <(printf '%s\n' "$ERR") "v$VERSION"
assert_eq "failed download installs nothing" \
    "$([ -f "$HOME_DIR/.config/opencode/skills/wp-mcp/SKILL.md" ] && echo yes || echo no)" "no"

# 3. A checkout uses its local skill and never touches the network.
LOCAL_DIR="$TEST_DIR/local"
mkdir -p "$LOCAL_DIR/skills/wp-mcp"
cp "$WPMCP" "$LOCAL_DIR/wp-mcp.sh"
chmod +x "$LOCAL_DIR/wp-mcp.sh"
printf '%s\n' "local checkout skill" > "$LOCAL_DIR/skills/wp-mcp/SKILL.md"
: > "$CURL_LOG"

set +e
HOME="$HOME_DIR" \
WPMCP_HOME="$HOME_DIR/.wp-mcp" \
WPMCP_TEST_CURL_LOG="$CURL_LOG" \
WPMCP_TEST_CURL_FAIL=1 \
PATH="$FAKE_BIN:$PATH" \
"$LOCAL_DIR/wp-mcp.sh" skill install global >/dev/null 2>&1
RC=$?
set -e

assert_eq "local install exits 0" "$RC" "0"
assert_eq "local skill wins" \
    "$(cat "$HOME_DIR/.agents/skills/wp-mcp/SKILL.md")" \
    "local checkout skill"
assert_eq "local install makes no network call" "$(wc -l < "$CURL_LOG" | tr -d ' ')" "0"

# 4. An unknown target fails before downloading anything.
: > "$CURL_LOG"
set +e
install_installed_nope() {
    HOME="$HOME_DIR" \
    WPMCP_HOME="$HOME_DIR/.wp-mcp" \
    WPMCP_TEST_CURL_LOG="$CURL_LOG" \
    PATH="$FAKE_BIN:$PATH" \
    "$INSTALLED_DIR/wp-mcp.sh" skill install nope
}
install_installed_nope >/dev/null 2>&1
RC=$?
set -e

assert_eq "unknown target exits 2" "$RC" "2"
assert_eq "unknown target makes no network call" "$(wc -l < "$CURL_LOG" | tr -d ' ')" "0"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
