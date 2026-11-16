#!/usr/bin/env bash
# Interactive prompt tests for wp-mcp-cli. No WordPress site required.
#
# Covers:
#   - Prompts work when stdin is a TTY but stdout is redirected or piped.
#   - The entered password reaches the CLI and is persisted.
#   - No controlling terminal keeps the current usage_error / exit 2 path.
#   - Prompt UI stays on /dev/tty, never in --json or --quiet stdout.
#   - Destructive confirmations work and still honour a "no" answer.
#   - gum tables stay disabled when stdout is redirected.
#
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WPMCP="${WPMCP:-$ROOT_DIR/wp-mcp.sh}"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wpmcp-interactive.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

if [ ! -x "$WPMCP" ]; then
    echo "Compiling wp-mcp.sh..."
    (cd "$ROOT_DIR" && ./compile.sh >/dev/null)
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for the interactive tests." >&2
    exit 1
fi

PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ]; then
    echo "python3 is required for the interactive tests." >&2
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
    if [ -f "$file" ] && grep -Fq -- "$needle" "$file"; then
        pass "$label"
    else
        fail "$label" "missing in $file: $needle"
    fi
}

assert_not_contains() {
    local label="$1" file="$2" needle="$3"
    if [ -f "$file" ] && grep -Fq -- "$needle" "$file"; then
        fail "$label" "unexpected in $file: $needle"
    else
        pass "$label"
    fi
}

assert_file_missing() {
    local label="$1" file="$2"
    if [ -e "$file" ]; then
        fail "$label" "file should not exist: $file"
    else
        pass "$label"
    fi
}

assert_file_exists() {
    local label="$1" file="$2"
    if [ -e "$file" ]; then
        pass "$label"
    else
        fail "$label" "file should exist: $file"
    fi
}

# Fake gum: renders prompt output on stderr (where real gum puts its TUI) and
# writes the entered value or confirmation status on stdout. Every invocation
# is logged so tests can prove whether a prompt was attempted.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gum" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'gum'; printf ' %s' "$@"; printf '\n'; } >> "${WPMCP_TEST_GUM_LOG:-/dev/null}"

command="${1:-}"
[ "$#" -gt 0 ] && shift

case "$command" in
    input)
        printf 'GUM-UI: input %s\n' "$*" >&2
        value=""
        IFS= read -r value || value=""
        value="${value%$'\r'}"
        printf '%s\n' "$value"
        ;;
    confirm)
        # Real gum takes the prompt as a positional argument; it has no
        # --prompt flag. Reject that flag here so the test catches a
        # regression that would make gum print help and cancel.
        if [ "${1:-}" = "--prompt" ]; then
            printf 'GUM-UI: unknown flag --prompt\n' >&2
            exit 1
        fi
        printf 'GUM-UI: confirm %s\n' "$*" >&2
        answer=""
        IFS= read -r answer || answer=""
        answer="${answer%$'\r'}"
        case "$answer" in
            y|Y|yes|YES|Yes) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    *)
        printf 'GUM-UI: %s %s\n' "$command" "$*" >&2
        ;;
esac
SH

# Fake curl: auth login only needs a successful /users/me probe. Consume the
# credentials document on stdin when curl reads it via --config -.
cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
consume=0
previous=""
for arg in "$@"; do
    if [ "$previous" = "--config" ] && [ "$arg" = "-" ]; then
        consume=1
    fi
    previous="$arg"
done
if [ "$consume" = "1" ]; then
    cat >/dev/null || true
fi
response="${WPMCP_TEST_CURL_RESPONSE:-}"
if [ -z "$response" ]; then
    response='{"id":1,"name":"oscar"}200'
fi
printf '%s' "$response"
SH

chmod +x "$FAKE_BIN/gum" "$FAKE_BIN/curl"

# The CLI prepends common binary directories when they are absent from PATH.
# Keep them present so the fake gum/curl stay first.
TEST_PATH="$FAKE_BIN:/usr/local/bin:/usr/local/sbin:/opt/homebrew/bin:$PATH"
USER_HOME="$TEST_DIR/user-home"
mkdir -p "$USER_HOME"
GUM_LOG="$TEST_DIR/gum.log"

run_cli_tty() {
    local home="$1" stdout_file="$2" stderr_file="$3"
    local input_file="$4" tty_out_file="$5"
    shift 5
    local args=(--stdout "$stdout_file" --stderr "$stderr_file")
    if [ -n "$input_file" ]; then
        args+=(--input "$input_file")
    fi
    if [ -n "$tty_out_file" ]; then
        args+=(--tty-out "$tty_out_file")
    fi
    (
        unset WPMCP_USERNAME WPMCP_PASSWORD WPMCP_SITE \
            WPMCP_ACTIVE_USER WPMCP_ACTIVE_PASS
        WPMCP_HOME="$home" \
            HOME="$USER_HOME" \
            PATH="$TEST_PATH" \
            WPMCP_TEST_GUM_LOG="$GUM_LOG" \
            "$PYTHON" "$SCRIPT_DIR/pty-run.py" "${args[@]}" -- "$@"
    )
}

run_cli_no_tty() {
    local home="$1" stdout_file="$2" stderr_file="$3"
    shift 3
    (
        unset WPMCP_USERNAME WPMCP_PASSWORD WPMCP_SITE \
            WPMCP_ACTIVE_USER WPMCP_ACTIVE_PASS
        WPMCP_HOME="$home" \
            HOME="$USER_HOME" \
            PATH="$TEST_PATH" \
            WPMCP_TEST_GUM_LOG="$GUM_LOG" \
            "$PYTHON" "$SCRIPT_DIR/pty-run.py" \
            --no-tty \
            --stdout "$stdout_file" \
            --stderr "$stderr_file" \
            -- "$@"
    )
}

echo "Running wp-mcp-cli interactive tests"

# 1. stdin is a TTY, stdout is a file: the password prompt must still run and
#    the typed value must reach auth login.
echo
echo "Prompts with redirected stdout"
AUTH_HOME="$TEST_DIR/auth-home"
OUT="$TEST_DIR/auth.out"
ERR="$TEST_DIR/auth.err"
TTY_OUT="$TEST_DIR/auth.tty"
INPUT="$TEST_DIR/auth.in"
printf 'prompted-app-password\n' > "$INPUT"
: > "$GUM_LOG"
rc=0
run_cli_tty "$AUTH_HOME" "$OUT" "$ERR" "$INPUT" "$TTY_OUT" \
    "$WPMCP" auth login https://support.plak.io --name support-plak-io --user oscar || rc=$?
assert_eq "auth login prompts with stdin TTY and redirected stdout" "$rc" "0"
assert_contains "prompt UI is drawn on the controlling terminal" "$TTY_OUT" "GUM-UI: input"
assert_not_contains "prompt UI is not mixed into stdout" "$OUT" "GUM-UI:"
assert_not_contains "prompt UI is not written to CLI stderr" "$ERR" "GUM-UI:"
assert_contains "auth login reports success on stdout" "$OUT" \
    "Logged in to https://support.plak.io as oscar."
assert_eq "prompted password reaches the CLI" \
    "$(jq -r '.app_password // empty' "$AUTH_HOME/credentials/support-plak-io.json" 2>/dev/null || true)" \
    "prompted-app-password"
assert_contains "auth login used gum input --password" "$GUM_LOG" "input --password"

# 2. All missing values prompt in order: URL, username, password.
echo
echo "Multiple prompts"
MULTI_HOME="$TEST_DIR/multi-home"
OUT="$TEST_DIR/multi.out"
ERR="$TEST_DIR/multi.err"
TTY_OUT="$TEST_DIR/multi.tty"
INPUT="$TEST_DIR/multi.in"
printf 'https://multi.example.test\nmulti-user\nmulti-password\n' > "$INPUT"
: > "$GUM_LOG"
rc=0
run_cli_tty "$MULTI_HOME" "$OUT" "$ERR" "$INPUT" "$TTY_OUT" \
    "$WPMCP" auth login --name multi-site || rc=$?
assert_eq "auth login prompts for every missing value" "$rc" "0"
assert_eq "prompted username reaches the CLI" \
    "$(jq -r '.username // empty' "$MULTI_HOME/credentials/multi-site.json" 2>/dev/null || true)" \
    "multi-user"
assert_eq "prompted password reaches the CLI for multiple prompts" \
    "$(jq -r '.app_password // empty' "$MULTI_HOME/credentials/multi-site.json" 2>/dev/null || true)" \
    "multi-password"
assert_not_contains "multiple prompt UI is not mixed into stdout" "$OUT" "GUM-UI:"

# 3. No controlling terminal: keep the consolidated usage error and exit 2.
echo
echo "No TTY"
NOAUTH_HOME="$TEST_DIR/noauth-home"
OUT="$TEST_DIR/noauth.out"
ERR="$TEST_DIR/noauth.err"
: > "$GUM_LOG"
rc=0
run_cli_no_tty "$NOAUTH_HOME" "$OUT" "$ERR" \
    "$WPMCP" auth login https://support.plak.io --name support-plak-io --user oscar || rc=$?
assert_eq "auth login without a TTY exits 2" "$rc" "2"
assert_contains "no-TTY error keeps the missing-password message" "$ERR" \
    "application password (--password or WPMCP_PASSWORD)"
assert_eq "no-TTY mode never invokes gum" \
    "$(grep -c . "$GUM_LOG" 2>/dev/null || true)" "0"
assert_file_missing "no-TTY mode does not save credentials" \
    "$NOAUTH_HOME/credentials/support-plak-io.json"

# 4. --json: the prompt UI must stay off stdout and the envelope must remain
#    a single parseable object.
echo
echo "JSON output"
JSON_HOME="$TEST_DIR/json-home"
OUT="$TEST_DIR/json.out"
ERR="$TEST_DIR/json.err"
TTY_OUT="$TEST_DIR/json.tty"
INPUT="$TEST_DIR/json.in"
printf 'json-password\n' > "$INPUT"
: > "$GUM_LOG"
rc=0
run_cli_tty "$JSON_HOME" "$OUT" "$ERR" "$INPUT" "$TTY_OUT" \
    "$WPMCP" --json auth login https://support.plak.io --name json-site --user oscar || rc=$?
assert_eq "--json auth login with a prompt exits 0" "$rc" "0"
assert_eq "--json stdout is exactly one JSON document" \
    "$(jq -s 'length' "$OUT" 2>/dev/null || echo invalid)" "1"
assert_eq "--json envelope is ok" \
    "$(jq -r '.ok // false' "$OUT" 2>/dev/null || true)" "true"
assert_eq "--json envelope keeps the profile name" \
    "$(jq -r '.data.name // empty' "$OUT" 2>/dev/null || true)" "json-site"
assert_not_contains "prompt UI is not mixed into --json stdout" "$OUT" "GUM-UI:"
assert_not_contains "prompt text is not mixed into --json stdout" "$OUT" "Application password"
assert_eq "--json prompted password reaches the CLI" \
    "$(jq -r '.app_password // empty' "$JSON_HOME/credentials/json-site.json" 2>/dev/null || true)" \
    "json-password"

# 5. --quiet: prompts still work and stay off stdout.
echo
echo "Quiet output"
QUIET_HOME="$TEST_DIR/quiet-home"
OUT="$TEST_DIR/quiet.out"
ERR="$TEST_DIR/quiet.err"
TTY_OUT="$TEST_DIR/quiet.tty"
INPUT="$TEST_DIR/quiet.in"
printf 'quiet-password\n' > "$INPUT"
: > "$GUM_LOG"
rc=0
run_cli_tty "$QUIET_HOME" "$OUT" "$ERR" "$INPUT" "$TTY_OUT" \
    "$WPMCP" --quiet auth login https://support.plak.io --name quiet-site --user oscar || rc=$?
assert_eq "--quiet auth login with a prompt exits 0" "$rc" "0"
assert_not_contains "prompt UI is not mixed into --quiet stdout" "$OUT" "GUM-UI:"
assert_not_contains "prompt text is not mixed into --quiet stdout" "$OUT" "Application password"
assert_not_contains "prompt UI is not written to --quiet stderr" "$ERR" "GUM-UI:"
assert_eq "--quiet prompted password reaches the CLI" \
    "$(jq -r '.app_password // empty' "$QUIET_HOME/credentials/quiet-site.json" 2>/dev/null || true)" \
    "quiet-password"

# 6. Destructive confirmation with redirected stdout: yes removes, no cancels.
echo
echo "Destructive confirmation"
CONFIRM_HOME="$TEST_DIR/confirm-home"
make_confirm_home() {
    rm -rf "$CONFIRM_HOME"
    mkdir -p "$CONFIRM_HOME/credentials"
    cat > "$CONFIRM_HOME/sites.json" <<'JSON'
{"version":1,"profiles":{"confirm-site":{"name":"confirm-site","siteUrl":"https://example.test","origin":"https://example.test","defaultUser":"oscar","createdAt":"2026-11-03T00:00:00Z"}}}
JSON
    cat > "$CONFIRM_HOME/credentials/confirm-site.json" <<'JSON'
{"site":"confirm-site","username":"oscar","app_password":"secret","created_at":"2026-11-03T00:00:00Z"}
JSON
    chmod 600 "$CONFIRM_HOME/sites.json" "$CONFIRM_HOME/credentials/confirm-site.json"
}

make_confirm_home
OUT="$TEST_DIR/confirm.out"
ERR="$TEST_DIR/confirm.err"
TTY_OUT="$TEST_DIR/confirm.tty"
INPUT="$TEST_DIR/confirm.in"
printf 'y\n' > "$INPUT"
: > "$GUM_LOG"
rc=0
run_cli_tty "$CONFIRM_HOME" "$OUT" "$ERR" "$INPUT" "$TTY_OUT" \
    "$WPMCP" sites remove confirm-site || rc=$?
assert_eq "sites remove confirmation accepts yes" "$rc" "0"
assert_contains "confirmation UI is drawn on the controlling terminal" "$TTY_OUT" "GUM-UI: confirm"
assert_contains "confirmation prompt text is on the controlling terminal" "$TTY_OUT" \
    "Remove profile 'confirm-site' and its credentials?"
assert_contains "sites remove reports the removal" "$OUT" "Removed site profile 'confirm-site'"
assert_eq "confirmed profile is removed from config" \
    "$(jq -r '.profiles["confirm-site"] // "absent"' "$CONFIRM_HOME/sites.json")" "absent"
assert_file_missing "confirmed profile credentials are removed" \
    "$CONFIRM_HOME/credentials/confirm-site.json"

make_confirm_home
OUT="$TEST_DIR/decline.out"
ERR="$TEST_DIR/decline.err"
TTY_OUT="$TEST_DIR/decline.tty"
INPUT="$TEST_DIR/decline.in"
printf 'n\n' > "$INPUT"
: > "$GUM_LOG"
rc=0
run_cli_tty "$CONFIRM_HOME" "$OUT" "$ERR" "$INPUT" "$TTY_OUT" \
    "$WPMCP" sites remove confirm-site || rc=$?
assert_eq "sites remove confirmation accepts no" "$rc" "0"
assert_contains "declined confirmation prints Cancelled" "$OUT" "Cancelled."
assert_eq "declined profile remains in config" \
    "$(jq -r '.profiles["confirm-site"].defaultUser // empty' "$CONFIRM_HOME/sites.json")" "oscar"
assert_file_exists "declined profile credentials remain" \
    "$CONFIRM_HOME/credentials/confirm-site.json"

# 7. Tables are decorative: with stdout redirected they must stay plain TSV.
echo
echo "Tables"
OUT="$TEST_DIR/sites.out"
ERR="$TEST_DIR/sites.err"
: > "$GUM_LOG"
rc=0
run_cli_tty "$AUTH_HOME" "$OUT" "$ERR" "" "" "$WPMCP" sites list || rc=$?
assert_eq "sites list with redirected stdout exits 0" "$rc" "0"
assert_contains "sites list prints plain TSV rows" "$OUT" \
    $'support-plak-io\thttps://support.plak.io\toscar'
assert_not_contains "sites list does not emit gum UI" "$OUT" "GUM-UI:"
assert_eq "sites list does not run gum table when stdout is redirected" \
    "$(grep -c ' table ' "$GUM_LOG" 2>/dev/null || true)" "0"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
