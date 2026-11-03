#!/usr/bin/env bash
# Code mode tests for wp-mcp-cli. No WordPress site required.
#
# The CLI runs a local PHP script; the "site" is a fake wp-mcp executable that
# returns canned run envelopes. This exercises the bootstrap, modes, budgets,
# timeouts and JSON envelope without network access.
#
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WPMCP="${WPMCP:-$ROOT_DIR/wp-mcp.sh}"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wpmcp-code-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

if [ ! -x "$WPMCP" ]; then
    echo "Compiling wp-mcp.sh..."
    (cd "$ROOT_DIR" && ./compile.sh >/dev/null)
fi

REAL_JQ=$(command -v jq || true)
REAL_PHP=$(command -v php || true)
if [ -z "$REAL_JQ" ] || [ -z "$REAL_PHP" ]; then
    echo "jq and PHP are required for the code mode tests." >&2
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
    local label="$1" value="$2" needle="$3"
    if printf '%s' "$value" | grep -Fq -- "$needle"; then
        pass "$label"
    else
        fail "$label" "missing: $needle"
    fi
}

assert_not_contains() {
    local label="$1" value="$2" needle="$3"
    if printf '%s' "$value" | grep -Fq -- "$needle"; then
        fail "$label" "unexpected: $needle"
    else
        pass "$label"
    fi
}

# Disposable WPMCP_HOME. The fake CLI needs a profile and a credential file so
# the real CLI can resolve the site before launching the script.
TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_HOME/credentials"
chmod 700 "$TEST_HOME" "$TEST_HOME/credentials"
cat > "$TEST_HOME/sites.json" <<'JSON'
{"version":1,"profiles":{"test":{"name":"test","siteUrl":"https://example.test","origin":"https://example.test","defaultUser":"admin","createdAt":"2026-11-03T00:00:00Z"}}}
JSON
cat > "$TEST_HOME/credentials/test.json" <<'JSON'
{"site":"test","username":"admin","app_password":"super secret pass","created_at":"2026-11-03T00:00:00Z"}
JSON
chmod 600 "$TEST_HOME/sites.json" "$TEST_HOME/credentials/test.json"

FAKE_CLI="$TEST_DIR/fake-wp-mcp"
cat > "$FAKE_CLI" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# The real CLI invokes: fake-wp-mcp --json run <ability> --input -
if [ "${1:-}" != "--json" ] || [ "${2:-}" != "run" ]; then
    echo "unexpected arguments: $*" >&2
    exit 1
fi
ability="${3:?ability required}"
if [ "${4:-}" != "--input" ] || [ "${5:-}" != "-" ]; then
    echo "unexpected input arguments" >&2
    exit 1
fi
input=$(cat)
home="${WPMCP_HOME:?WPMCP_HOME required}"
executions="$home/code-executions.log"

error() {
    jq -nc --arg code "$1" --arg message "$2" \
        '{ok:false,error:{code:$code,message:$message,retryable:false,remoteCode:"",details:null}}' >&2
    exit "${3:-5}"
}

data=""
case "$ability" in
    wp-mcp/get-ability-info)
        target=$(printf '%s' "$input" | jq -r '.ability_name // empty')
        no_annotations=0
        case "$target" in
            wp-mcp/content-list-posts)
                readonly=true
                destructive=false
                ;;
            wp-mcp/content-update-post|wp-mcp/write-file)
                readonly=false
                destructive=false
                ;;
            wp-mcp/content-delete-post)
                readonly=false
                destructive=true
                ;;
            wp-mcp/no-annotations)
                no_annotations=1
                ;;
            *)
                error "wp_mcp_ability_not_found" "Ability '$target' is not registered." 2
                ;;
        esac
        if [ "$no_annotations" = "1" ]; then
            data=$(jq -nc --arg name "$target" \
                '{name:$name,label:$name,description:"test ability",category:"test",input_schema:{type:"object"},output_schema:{type:"object"},meta:{}}')
        else
            data=$(jq -nc \
                --arg name "$target" \
                --argjson readonly "$readonly" \
                --argjson destructive "$destructive" \
                '{name:$name,label:$name,description:"test ability",category:"test",input_schema:{type:"object"},output_schema:{type:"object"},meta:{annotations:{readonly:$readonly,destructive:$destructive,idempotent:false}}}')
        fi
        ;;
    mcp-adapter/discover-abilities)
        data=$(jq -nc '{
            mode:"search",
            abilities:[{
                name:"wp-mcp/content-list-posts",
                label:"List Posts",
                summary:"List posts.",
                category:"content",
                source:"wp-mcp",
                readonly:true,
                destructive:false,
                requires_confirmation:false
            }],
            total:1,
            next_cursor:null
        }')
        ;;
    wp-mcp/content-list-posts)
        printf '%s\n' "$ability" >> "$executions"
        data=$(jq -nc '{posts:[{id:1,title:"Hello"}],total:1}')
        ;;
    wp-mcp/content-update-post)
        printf '%s\n' "$ability" >> "$executions"
        data=$(jq -nc '{updated:true}')
        ;;
    wp-mcp/content-delete-post)
        printf '%s\n' "$ability" >> "$executions"
        data=$(jq -nc '{deleted:true}')
        ;;
    wp-mcp/write-file)
        printf '%s\n' "$ability" >> "$executions"
        data=$(jq -nc '{written:true}')
        ;;
    wp-mcp/no-annotations)
        printf '%s\n' "$ability" >> "$executions"
        data=$(jq -nc '{executed:true}')
        ;;
    *)
        error "wp_mcp_ability_not_found" "Ability '$ability' is not registered." 2
        ;;
esac

jq -nc --argjson data "$data" '{ok:true,data:$data,meta:{site:"test",http_status:200}}'
SH
chmod +x "$FAKE_CLI"

CODE_OUT=""
CODE_ERR=""
CODE_RC=0

run_code() {
    local mode="$1"
    shift
    CODE_RC=0
    rm -f "$TEST_DIR/stderr.txt"
    if [ "$mode" = "json" ]; then
        CODE_OUT=$(WPMCP_HOME="$TEST_HOME" WPMCP_CODE_CLI="$FAKE_CLI" \
            "$WPMCP" --json --site test code "$@" 2>"$TEST_DIR/stderr.txt") || CODE_RC=$?
    else
        CODE_OUT=$(WPMCP_HOME="$TEST_HOME" WPMCP_CODE_CLI="$FAKE_CLI" \
            "$WPMCP" --site test code "$@" 2>"$TEST_DIR/stderr.txt") || CODE_RC=$?
    fi
    CODE_ERR=$(cat "$TEST_DIR/stderr.txt")
}

json_field() {
    printf '%s' "$1" | jq -r "$2"
}

reset_executions() {
    rm -f "$TEST_HOME/code-executions.log"
}

executed() {
    grep -Fq -- "$1" "$TEST_HOME/code-executions.log" 2>/dev/null
}

not_executed() {
    ! executed "$1"
}

script() {
    local name="$1"
    cat > "$TEST_DIR/$name.php"
}

# --- scripts ---------------------------------------------------------------

script read <<'PHP'
<?php
$r = wp_mcp_call('wp-mcp/content-list-posts', ['per_page' => 1]);
echo $r['posts'][0]['title'];
PHP

script update <<'PHP'
<?php
$r = wp_mcp_call('wp-mcp/content-update-post', ['id' => 1, 'status' => 'publish', 'confirm_update' => true]);
echo isset($r['__wp_mcp_skipped']) ? 'skipped' : 'executed';
PHP

script delete <<'PHP'
<?php
wp_mcp_call('wp-mcp/content-delete-post', ['id' => 1, 'confirm_delete' => true]);
echo 'deleted';
PHP

script dry <<'PHP'
<?php
$r = wp_mcp_call('wp-mcp/content-list-posts', []);
echo isset($r['__wp_mcp_dry_run']) ? 'stub' : 'executed';
PHP

script two <<'PHP'
<?php
wp_mcp_call('wp-mcp/content-list-posts', []);
wp_mcp_call('wp-mcp/content-list-posts', []);
echo 'done';
PHP

script search <<'PHP'
<?php
$rows = wp_mcp_search('post', 5);
echo $rows[0]['name'];
PHP

script describe <<'PHP'
<?php
$d = wp_mcp_describe('wp-mcp/content-list-posts');
echo $d['meta']['annotations']['readonly'] ? 'readonly' : 'write';
PHP

script log <<'PHP'
<?php
wp_mcp_log('log line');
echo 'done';
PHP

script unknown <<'PHP'
<?php
wp_mcp_call('wp-mcp/unknown-ability', []);
PHP

script invalid <<'PHP'
<?php
wp_mcp_call('../etc/passwd', []);
PHP

script noannotations <<'PHP'
<?php
wp_mcp_call('wp-mcp/no-annotations', []);
echo 'executed';
PHP

script parse <<'PHP'
<?php
this is not php
PHP

script exit1 <<'PHP'
<?php
exit(1);
PHP

script timeout <<'PHP'
<?php
while (true) {}
PHP

script quiet <<'PHP'
<?php
echo 'quiet output';
PHP

script site <<'PHP'
<?php
echo wp_mcp_site()['name'];
PHP

script jsonout <<'PHP'
<?php
echo json_encode(['value' => 42]);
PHP

script jsonstream <<'PHP'
<?php
echo "1\n2\n";
PHP

script binary <<'PHP'
<?php
echo "\xFF\xFE";
PHP

script stderr <<'PHP'
<?php
fwrite(STDERR, "script stderr\n");
echo 'ok';
PHP

echo "Running wp-mcp-cli code mode tests"

# --- command surface -------------------------------------------------------

echo
echo "Command surface"
CODE_RC=0
CODE_OUT=$("$WPMCP" code --help 2>&1) || CODE_RC=$?
assert_eq "code --help exits 0" "$CODE_RC" "0"
assert_contains "help mentions --read-only" "$CODE_OUT" "--read-only"
assert_contains "help mentions --dry-run" "$CODE_OUT" "--dry-run"

run_code json "$TEST_DIR/missing.php"
assert_eq "missing script exits 2" "$CODE_RC" "2"
assert_eq "missing script code" "$(json_field "$CODE_ERR" '.error.code')" "usage_error"

run_code json "$TEST_DIR/read.php" --dry-run --yes
assert_eq "dry-run with yes exits 2" "$CODE_RC" "2"

run_code json "$TEST_DIR/read.php" --read-only --yes
assert_eq "read-only with yes exits 2" "$CODE_RC" "2"

run_code json "$TEST_DIR/read.php" --max-calls 0
assert_eq "max-calls 0 exits 2" "$CODE_RC" "2"

run_code json "$TEST_DIR/read.php" --timeout 0
assert_eq "timeout 0 exits 2" "$CODE_RC" "2"

CODE_RC=0
rm -f "$TEST_DIR/stderr.txt"
CODE_OUT=$(printf '%s' '<?php echo "stdin";' | \
    WPMCP_HOME="$TEST_HOME" WPMCP_CODE_CLI="$FAKE_CLI" \
    "$WPMCP" --json --site test code - 2>"$TEST_DIR/stderr.txt") || CODE_RC=$?
CODE_ERR=$(cat "$TEST_DIR/stderr.txt")
assert_eq "stdin script exits 0" "$CODE_RC" "0"
assert_eq "stdin script output" "$(json_field "$CODE_OUT" '.data.output')" "stdin"

# --- read mode -------------------------------------------------------------

echo
echo "Modes"
reset_executions
run_code json "$TEST_DIR/read.php"
assert_eq "read exits 0" "$CODE_RC" "0"
assert_eq "read output" "$(json_field "$CODE_OUT" '.data.output')" "Hello"
assert_eq "read call status" "$(json_field "$CODE_OUT" '.data.calls[] | select(.kind == "call") | .status')" "ok"
assert_eq "read calls include metadata and execution" "$(json_field "$CODE_OUT" '.data.calls | length')" "2"
assert_eq "read executes the ability" "$(executed wp-mcp/content-list-posts && echo yes || echo no)" "yes"

run_code json "$TEST_DIR/read.php" --read-only
assert_eq "read-only executes readonly abilities" "$(json_field "$CODE_OUT" '.data.output')" "Hello"

# A non-destructive write is still a write. --read-only must stub it.
reset_executions
run_code json "$TEST_DIR/update.php" --read-only
assert_eq "read-only exits 0" "$CODE_RC" "0"
assert_eq "read-only stubs non-destructive write" "$(json_field "$CODE_OUT" '.data.output')" "skipped"
assert_eq "read-only call status" "$(json_field "$CODE_OUT" '.data.calls[] | select(.kind == "call") | .status')" "skipped"
assert_eq "read-only does not execute the write" "$(not_executed wp-mcp/content-update-post && echo yes || echo no)" "yes"

reset_executions
run_code json "$TEST_DIR/update.php"
assert_eq "default mode executes non-destructive write" "$(json_field "$CODE_OUT" '.data.output')" "executed"
assert_eq "default mode executes the write" "$(executed wp-mcp/content-update-post && echo yes || echo no)" "yes"

reset_executions
run_code json "$TEST_DIR/dry.php" --dry-run
assert_eq "dry-run exits 0" "$CODE_RC" "0"
assert_eq "dry-run returns a stub" "$(json_field "$CODE_OUT" '.data.output')" "stub"
assert_eq "dry-run call status" "$(json_field "$CODE_OUT" '.data.calls[] | select(.kind == "call") | .status')" "dry_run"
assert_eq "dry-run does not execute the ability" "$(not_executed wp-mcp/content-list-posts && echo yes || echo no)" "yes"

# Destructive default: exit 6 without --yes; --yes executes.
reset_executions
run_code json "$TEST_DIR/delete.php"
assert_eq "destructive without yes exits 6" "$CODE_RC" "6"
assert_eq "destructive error code" "$(json_field "$CODE_ERR" '.error.code')" "confirmation_required"
assert_eq "destructive without yes does not execute" "$(not_executed wp-mcp/content-delete-post && echo yes || echo no)" "yes"

reset_executions
run_code json "$TEST_DIR/delete.php" --yes
assert_eq "destructive with yes exits 0" "$CODE_RC" "0"
assert_eq "destructive with yes output" "$(json_field "$CODE_OUT" '.data.output')" "deleted"
assert_eq "destructive with yes executes" "$(executed wp-mcp/content-delete-post && echo yes || echo no)" "yes"

# --- search / describe / log ----------------------------------------------

echo
echo "Script API"
reset_executions
run_code json "$TEST_DIR/search.php"
assert_eq "search exits 0" "$CODE_RC" "0"
assert_eq "search returns a row" "$(json_field "$CODE_OUT" '.data.output')" "wp-mcp/content-list-posts"
assert_eq "search does not execute an ability" "$(not_executed wp-mcp/content-list-posts && echo yes || echo no)" "yes"

reset_executions
run_code json "$TEST_DIR/describe.php"
assert_eq "describe exits 0" "$CODE_RC" "0"
assert_eq "describe returns annotations" "$(json_field "$CODE_OUT" '.data.output')" "readonly"

reset_executions
run_code json "$TEST_DIR/log.php"
assert_eq "log exits 0" "$CODE_RC" "0"
assert_eq "log output" "$(json_field "$CODE_OUT" '.data.output')" "done"
assert_eq "log message is in the envelope" "$(json_field "$CODE_OUT" '.data.logs[0]')" "log line"
assert_eq "log does not pollute CLI stderr" "$CODE_ERR" ""

run_code json "$TEST_DIR/site.php"
assert_eq "site helper returns the profile name" "$(json_field "$CODE_OUT" '.data.output')" "test"

# --- errors / budgets / timeout -------------------------------------------

echo
echo "Errors and limits"
run_code json "$TEST_DIR/unknown.php"
assert_eq "unknown ability exits 2" "$CODE_RC" "2"
assert_eq "unknown ability code" "$(json_field "$CODE_ERR" '.error.code')" "ability_not_found"
assert_eq "unknown ability remote code" "$(json_field "$CODE_ERR" '.error.remoteCode')" "wp_mcp_ability_not_found"

run_code json "$TEST_DIR/invalid.php"
assert_eq "invalid ability name exits 2" "$CODE_RC" "2"
assert_eq "invalid ability name code" "$(json_field "$CODE_ERR" '.error.code')" "usage_error"

reset_executions
run_code json "$TEST_DIR/noannotations.php"
assert_eq "missing annotations exit 6" "$CODE_RC" "6"
assert_eq "missing annotations code" "$(json_field "$CODE_ERR" '.error.code')" "confirmation_required"
assert_eq "missing annotations fail closed" "$(not_executed wp-mcp/no-annotations && echo yes || echo no)" "yes"

reset_executions
run_code json "$TEST_DIR/noannotations.php" --yes
assert_eq "missing annotations with yes exits 0" "$CODE_RC" "0"
assert_eq "missing annotations with yes executes" "$(executed wp-mcp/no-annotations && echo yes || echo no)" "yes"

reset_executions
run_code json "$TEST_DIR/two.php" --max-calls 1
assert_eq "call budget exits 5" "$CODE_RC" "5"
assert_eq "call budget code" "$(json_field "$CODE_ERR" '.error.code')" "call_budget_exceeded"
assert_eq "call budget executes only the first call" "$(wc -l < "$TEST_HOME/code-executions.log" | tr -d ' ')" "1"

run_code json "$TEST_DIR/parse.php"
assert_eq "parse error exits 5" "$CODE_RC" "5"
assert_eq "parse error code" "$(json_field "$CODE_ERR" '.error.code')" "script_error"
assert_contains "parse error keeps stderr" "$(json_field "$CODE_ERR" '.error.details.stderr')" "syntax error"

run_code json "$TEST_DIR/exit1.php"
assert_eq "exit(1) exits 5" "$CODE_RC" "5"
assert_eq "exit(1) code" "$(json_field "$CODE_ERR" '.error.code')" "script_error"
assert_contains "exit(1) message" "$(json_field "$CODE_ERR" '.error.message')" "status 1"

run_code json "$TEST_DIR/timeout.php" --timeout 1
assert_eq "timeout exits 5" "$CODE_RC" "5"
assert_eq "timeout code" "$(json_field "$CODE_ERR" '.error.code')" "script_error"
assert_contains "timeout message" "$(json_field "$CODE_ERR" '.error.message')" "timed out"

# --- envelope / quiet ------------------------------------------------------

echo
echo "Envelope"
run_code json "$TEST_DIR/read.php"
assert_eq "envelope ok" "$(json_field "$CODE_OUT" '.ok')" "true"
assert_eq "envelope script hash length" "$(printf '%s' "$(json_field "$CODE_OUT" '.meta.script_sha256')" | wc -c | tr -d ' ')" "64"
assert_eq "envelope output type" "$(json_field "$CODE_OUT" '.data.output_type')" "text"
assert_eq "envelope is not dry-run" "$(json_field "$CODE_OUT" '.data.dry_run')" "false"

run_code json "$TEST_DIR/jsonout.php"
assert_eq "JSON output type" "$(json_field "$CODE_OUT" '.data.output_type')" "json"
assert_eq "JSON output value" "$(json_field "$CODE_OUT" '.data.output.value')" "42"

run_code json "$TEST_DIR/jsonstream.php"
assert_eq "JSON stream is text" "$(json_field "$CODE_OUT" '.data.output_type')" "text"
assert_eq "JSON stream preserves raw output" "$(json_field "$CODE_OUT" '.data.output')" $'1\n2'

run_code json "$TEST_DIR/binary.php"
assert_eq "binary output is base64" "$(json_field "$CODE_OUT" '.data.output_encoding')" "base64"
assert_eq "binary output payload" "$(json_field "$CODE_OUT" '.data.output')" "//4="

run_code json "$TEST_DIR/stderr.php"
assert_eq "script stderr does not break success" "$(json_field "$CODE_OUT" '.data.output')" "ok"
assert_contains "script stderr is captured" "$(json_field "$CODE_OUT" '.data.stderr')" "script stderr"

run_code json "$TEST_DIR/read.php" --quiet
assert_eq "json quiet still emits the envelope" "$(json_field "$CODE_OUT" '.ok')" "true"

run_code human "$TEST_DIR/read.php" --verbose
assert_eq "verbose exits 0" "$CODE_RC" "0"
assert_contains "verbose prints the call log" "$CODE_ERR" "[wp-mcp] #"

run_code human "$TEST_DIR/quiet.php" --quiet
assert_eq "quiet exits 0" "$CODE_RC" "0"
assert_eq "quiet suppresses stdout" "$CODE_OUT" ""
assert_eq "quiet suppresses summary" "$CODE_ERR" ""

run_code human "$TEST_DIR/stderr.php" --quiet
assert_eq "quiet suppresses script stderr" "$CODE_ERR" ""

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
