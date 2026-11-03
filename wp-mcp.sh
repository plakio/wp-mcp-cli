#!/usr/bin/env bash

# wp-mcp - Bash entrypoint
# Source file for the compiled wp-mcp.sh distribution script.

# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

# Never inherit an exported application password from a parent process.
# Older releases exported it; keep it out of child environments.
unset WPMCP_ACTIVE_PASS

# Capture the auth-login password fallback and remove it from the environment
# so it cannot reach child processes (curl, jq, PHP). The value stays in a
# non-exported shell variable for `auth login`.
WPMCP_PASSWORD_INPUT="${WPMCP_PASSWORD:-}"
unset WPMCP_PASSWORD

WPMCP_NAME="wp-mcp"
WPMCP_VERSION="0.2.0"
WPMCP_HOME="${WPMCP_HOME:-$HOME/.wp-mcp}"

# Ensure common user-managed binary locations are available when launched
# from restricted environments such as cron, launchd, or GUI shells.
for _wpmcp_bin in /opt/homebrew/bin /usr/local/bin /usr/local/sbin "$HOME/.local/bin"; do
    if [ -d "$_wpmcp_bin" ] && [[ ":$PATH:" != *":$_wpmcp_bin:"* ]]; then
        PATH="$_wpmcp_bin:$PATH"
    fi
done
unset _wpmcp_bin
export PATH

wpmcp_setup_environment() {
    local os_name
    os_name=$(uname -s)

    case "$os_name" in
        Darwin) WPMCP_OS="macos" ;;
        Linux)  WPMCP_OS="linux" ;;
        *)      WPMCP_OS="unsupported" ;;
    esac

    export WPMCP_OS
}

wpmcp_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

wpmcp_has_tty() {
    [ -t 0 ] && [ -t 1 ]
}

wpmcp_require_command() {
    if ! wpmcp_command_exists "$1"; then
        echo "Error: '$1' is required for this command." >&2
        echo "Install it and ensure it is on your PATH." >&2
        exit 1
    fi
}

wpmcp_require_gum() {
    wpmcp_require_command gum
    if ! wpmcp_has_tty; then
        echo "Error: this command needs an interactive terminal." >&2
        exit 1
    fi
}

wpmcp_require_jq() {
    wpmcp_require_command jq
}

wpmcp_require_curl() {
    wpmcp_require_command curl
}

wpmcp_show_help() {
    cat <<'HELP'
wp-mcp CLI

Usage:
  wp-mcp <command> [arguments]

Commands:
  auth        Authenticate against a WP-MCP site
  sites       Manage saved site profiles
  discover    List available abilities on the active site
  describe    Show an ability's schema and metadata
  run         Execute an ability on the active site
  code        Run a local PHP script that calls abilities
  doctor      Diagnose wp-mcp-cli and target site connectivity
  skill       Install the wp-mcp agent skill
  version     Show wp-mcp-cli version
  help        Show this help

Global flags (must appear before the command):
  --json              Force JSON output for commands that support it
  --quiet             Suppress success output on STDOUT
  --site <name>       Override the active site profile (or set WPMCP_SITE)
  --version           Show wp-mcp-cli version
  --help              Show help for any command

Selection order for the active site:
  1. --site <name>
  2. WPMCP_SITE environment variable
  3. The single configured profile (implicit)
  4. Error: site_required (when multiple profiles exist without a selector)

Examples:
  wp-mcp auth login
  wp-mcp --json sites list
  wp-mcp --json discover
  wp-mcp describe wp-mcp/list-directory
  wp-mcp run wp-mcp/list-directory --input '{"path":"/Users"}'
  wp-mcp code audit.php --read-only
  wp-mcp --json doctor

HELP
}

wpmcp_display_command_help() {
    local command="${1:-}"

    case "$command" in
        auth)
            cat <<'HELP'
Usage:
  wp-mcp auth <action> [args]

Actions:
  login [<url>] [--name <name>]    Save (or rotate) credentials for a WP-MCP site
  status                            Show credential summary for every saved profile
                                   (or just the active one with --site <name>)
  logout                            Remove credentials for the active site
  help                              Show this help

Auth uses WordPress Application Passwords (HTTP Basic). No browser flow is
required. Generate an application password from the WP-MCP → Configuration
admin page in your WordPress dashboard.
HELP
            ;;
        sites)
            cat <<'HELP'
Usage:
  wp-mcp sites <action> [args]

Actions:
  list                              List saved site profiles (or use --json)
  remove <name> [--yes]             Remove a saved site profile and its credentials
  rename <name> <new-name>          Rename a profile and migrate its credentials
  help                              Show this help
HELP
            ;;
        discover)
            cat <<'HELP'
Usage:
  wp-mcp discover [--site <name>]

Lists every ability registered on the active site that exposes
show_in_rest=true. Use --json for a stable machine-readable envelope.
HELP
            ;;
        describe)
            cat <<'HELP'
Usage:
  wp-mcp describe <ability> [--site <name>]

Prints the ability record including input_schema, output_schema, and
annotations (readonly, destructive, idempotent).
HELP
            ;;
        run)
            cat <<'HELP'
Usage:
  wp-mcp run <ability> [--input <json|@file|->] [--site <name>] [--yes]

The --input flag accepts:
  - inline JSON string
  - @<path>         read JSON from a file
  - "-"             read JSON from STDIN
  - omitted         input defaults to null

Use --yes to skip the destructive-operation prompt. Use --json for a
stable envelope on STDOUT.
HELP
            ;;
        code)
            cat <<'HELP'
Usage:
  wp-mcp code <file|-> [flags]

Runs a local PHP script that calls WP-MCP abilities through the CLI's
existing REST path. The script runs on your machine; it is not a sandbox.

Modes:
  (default)       execute reads and non-destructive writes. Destructive
                  abilities require --yes.
  --read-only     execute only abilities marked readonly=true; stub writes.
  --dry-run       stub every ability call; metadata search/describe still run.
  --yes, -y       allow destructive abilities. It does not inject the
                  ability's confirm_* arguments; pass them explicitly.

Flags:
  --max-calls <n>  Maximum ability calls (1-1000, default 100).
  --timeout <sec>  Wall-clock limit (1-3600, default 120).
  --verbose        Print one line per call in human mode.
  --help, -h       Show this help.

Script API:
  wp_mcp_call($ability, $input = null)
  wp_mcp_search($query, $limit = 10, $cursor = null)
  wp_mcp_discover($options = [])
  wp_mcp_describe($ability)
  wp_mcp_log($message)
  wp_mcp_is_dry_run()
  wp_mcp_is_read_only()
  wp_mcp_site()

Examples:
  wp-mcp code audit.php --read-only
  wp-mcp code migrate.php --dry-run
  wp-mcp code migrate.php --yes
HELP
            ;;
        doctor)
            cat <<'HELP'
Usage:
  wp-mcp doctor [--site <name>] [--offline]

Runs ordered health checks against the CLI environment and the target
site. --offline skips network calls.
HELP
            ;;
        skill)
            cat <<'HELP'
Usage:
  wp-mcp skill install [codex|claude-code|opencode|hermes|pi|global|all]

Installs the wp-mcp agent skill to the requested agent's skills directory.
"all" installs agent-specific targets only (codex, claude-code, opencode,
hermes, pi). Use "global" to install into ~/.agents/skills/ explicitly.
HELP
            ;;
        version)
            echo "Usage: wp-mcp version"
            ;;
        *)
            wpmcp_show_help
            ;;
    esac
}

main() {
    wpmcp_setup_environment

    WPMCP_QUIET=0
    WPMCP_JSON=0
    WPMCP_SITE_FLAG=""
    WPMCP_VERSION_REQUEST=0
    local new_args=()

    # Strip global flags first. --json / --quiet / --site are handled via
    # env vars so commands never see them and don't need to special-case
    # them in their own flag parsers.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json)
                WPMCP_JSON=1
                shift
                ;;
            --quiet|-q)
                WPMCP_QUIET=1
                shift
                ;;
            --site)
                if [ -n "${2:-}" ]; then
                    WPMCP_SITE_FLAG="$2"
                    shift 2
                else
                    wpmcp_error_usage "--site requires a profile name"
                fi
                ;;
            --site=*)
                WPMCP_SITE_FLAG="${1#--site=}"
                shift
                ;;
            --version)
                WPMCP_VERSION_REQUEST=1
                shift
                ;;
            --help|-h)
                # Defer to the command so it can show focused help.
                new_args+=("--help")
                shift
                ;;
            *)
                new_args+=("$1")
                shift
                ;;
        esac
    done

    export WPMCP_QUIET WPMCP_JSON
    if [ -n "$WPMCP_SITE_FLAG" ]; then
        export WPMCP_SITE
        WPMCP_SITE="$WPMCP_SITE_FLAG"
    fi

    if [ "$WPMCP_VERSION_REQUEST" = "1" ]; then
        wpmcp_version
        exit 0
    fi

    set -- "${new_args[@]}"

    local command="${1:-help}"
    if [ "$#" -gt 0 ]; then
        shift
    fi

    case "$command" in
        auth)
            wpmcp_auth "$@"
            ;;
        sites)
            wpmcp_sites "$@"
            ;;
        discover)
            wpmcp_discover "$@"
            ;;
        describe)
            wpmcp_describe "$@"
            ;;
        run)
            wpmcp_run "$@"
            ;;
        code)
            wpmcp_code "$@"
            ;;
        doctor)
            wpmcp_doctor "$@"
            ;;
        skill)
            wpmcp_skill "$@"
            ;;
        version|-v)
            wpmcp_version "$@"
            ;;
        help)
            wpmcp_show_help
            ;;
        *)
            echo "Error: unknown command '$command'" >&2
            echo ""
            wpmcp_show_help
            exit 1
            ;;
    esac
}


# --- Shared Helpers ---
# Source: shared/auth.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Credential storage. Application Passwords only (HTTP Basic).
# Each site stores its credentials in a file keyed by the site name,
# with chmod 0600 and owner-only access enforced.

wpmcp_auth_cred_path() {
    local site="$1"
    wpmcp_paths_ensure
    echo "$WPMCP_CREDS_DIR/$site.json"
}

wpmcp_auth_save() {
    # wpmcp_auth_save <site> <username> <app_password>
    local site="$1"
    local user="$2"
    local pass="$3"
    wpmcp_paths_ensure
    local cred_path
    cred_path=$(wpmcp_auth_cred_path "$site")
    local tmp="${cred_path}.tmp.$$"
    umask 077
    # Feed the password to jq on STDIN (-Rs reads it as one raw string) so it
    # never appears in jq's argv.
    local rc=0
    printf '%s' "$pass" | jq -Rs \
        --arg user "$user" \
        --arg site "$site" \
        '{site:$site,username:$user,app_password:.,created_at:now|todate}' \
        > "$tmp" || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        return "$rc"
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$cred_path"
}

wpmcp_auth_load() {
    # wpmcp_auth_load <site> → JSON object
    local site="$1"
    local cred_path
    cred_path=$(wpmcp_auth_cred_path "$site")
    if [ ! -f "$cred_path" ]; then
        return 1
    fi
    cat "$cred_path"
}

wpmcp_auth_remove() {
    local site="$1"
    local cred_path
    cred_path=$(wpmcp_auth_cred_path "$site")
    if [ -f "$cred_path" ]; then
        rm -f "$cred_path"
    fi
}

wpmcp_auth_check() {
    # Quick sanity check: verifies the file exists and parses as JSON.
    local site="$1"
    local cred_path
    cred_path=$(wpmcp_auth_cred_path "$site")
    if [ ! -f "$cred_path" ]; then
        return 1
    fi
    if ! jq -e '.' "$cred_path" >/dev/null 2>&1; then
        return 2
    fi
    return 0
}

wpmcp_auth_require() {
    # Resolves the active site and verifies credentials exist.
    # Sets WPMCP_ACTIVE_USER and WPMCP_ACTIVE_PASS.
    wpmcp_config_resolve_site
    if ! wpmcp_auth_check "$WPMCP_ACTIVE_SITE"; then
        wpmcp_error_auth_required "$WPMCP_ACTIVE_SITE"
    fi
    local cred
    cred=$(wpmcp_auth_load "$WPMCP_ACTIVE_SITE")
    WPMCP_ACTIVE_USER=$(printf '%s' "$cred" | jq -r '.username')
    WPMCP_ACTIVE_PASS=$(printf '%s' "$cred" | jq -r '.app_password')
    # Keep the application password in this shell only. Command substitutions
    # and subshells still see it, but external processes (curl, jq, PHP) do not.
    export -n WPMCP_ACTIVE_PASS 2>/dev/null || true
    export WPMCP_ACTIVE_USER
}

# Source: shared/code.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Code mode helpers: PHP bootstrap extraction, execution and rendering.
# The user script runs locally. It is not a sandbox.

# Bump this whenever the embedded PHP bootstrap changes so existing
# installations rewrite $WPMCP_HOME/lib/code-bootstrap.php.
WPMCP_CODE_BOOTSTRAP_VERSION="1"
WPMCP_CODE_OUTPUT_LIMIT=1048576
WPMCP_CODE_WORK_DIR=""
WPMCP_CODE_PHP_PID=""
WPMCP_CODE_WATCHDOG_PID=""

wpmcp_code_cleanup() {
    if [ -n "${WPMCP_CODE_PHP_PID:-}" ] && kill -0 "$WPMCP_CODE_PHP_PID" 2>/dev/null; then
        kill -TERM -- "-$WPMCP_CODE_PHP_PID" 2>/dev/null || kill "$WPMCP_CODE_PHP_PID" 2>/dev/null || true
    fi
    if [ -n "${WPMCP_CODE_WATCHDOG_PID:-}" ] && kill -0 "$WPMCP_CODE_WATCHDOG_PID" 2>/dev/null; then
        kill -TERM -- "-$WPMCP_CODE_WATCHDOG_PID" 2>/dev/null || kill "$WPMCP_CODE_WATCHDOG_PID" 2>/dev/null || true
    fi
    if [ -n "${WPMCP_CODE_WORK_DIR:-}" ]; then
        rm -rf "$WPMCP_CODE_WORK_DIR"
    fi
}

wpmcp_code_require_php() {
    wpmcp_command_exists php || wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
        "PHP is required for 'wp-mcp code'."
    if ! php -r 'exit(PHP_VERSION_ID >= 80000 ? 0 : 1);' >/dev/null 2>&1; then
        wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
            "PHP >= 8.0 is required for 'wp-mcp code'."
    fi
    if ! php -r 'exit(function_exists("proc_open") ? 0 : 1);' >/dev/null 2>&1; then
        wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
            "PHP proc_open() is disabled; 'wp-mcp code' requires it."
    fi
}

wpmcp_code_cli_path() {
    local cli="${BASH_SOURCE[0]:-$0}"
    case "$cli" in
        /*) printf '%s' "$cli" ;;
        *) printf '%s/%s' "$(cd "$(dirname "$cli")" && pwd)" "$(basename "$cli")" ;;
    esac
}

wpmcp_code_sha256() {
    local file="$1"
    if wpmcp_command_exists sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif wpmcp_command_exists shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
            "No SHA-256 tool is available."
    fi
}

wpmcp_code_bootstrap_path() {
    wpmcp_paths_init
    printf '%s/lib/code-bootstrap.php' "$WPMCP_HOME"
}

wpmcp_code_extract_bootstrap() {
    local lib_dir="$WPMCP_HOME/lib"
    local target="$lib_dir/code-bootstrap.php"
    local version_file="$lib_dir/code-bootstrap.version"
    local tmp="$target.tmp.$$"

    mkdir -p "$lib_dir" || wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
        "Cannot create $lib_dir."
    chmod 700 "$lib_dir" 2>/dev/null || true

    if [ -f "$target" ] && [ -f "$version_file" ] &&
        [ "$(cat "$version_file" 2>/dev/null)" = "$WPMCP_CODE_BOOTSTRAP_VERSION" ]; then
        return 0
    fi

    cat > "$tmp" <<'WPMCP_CODE_BOOTSTRAP'
<?php
// wp-mcp-cli code bootstrap (AGPL-3.0-or-later)
// Version: 1

if (defined('WPMCP_CODE_BOOTSTRAP')) {
    return;
}
define('WPMCP_CODE_BOOTSTRAP', '1');

final class WPMCP_Code_Error extends RuntimeException
{
    public string $errorCode;
    public int $exitCode;
    public ?int $httpStatus;
    public ?string $remoteCode;
    public array $details;

    public function __construct(
        string $errorCode,
        string $message,
        int $exitCode = 5,
        ?int $httpStatus = null,
        ?string $remoteCode = null,
        array $details = []
    ) {
        parent::__construct($message);
        $this->errorCode = $errorCode;
        $this->exitCode = $exitCode;
        $this->httpStatus = $httpStatus;
        $this->remoteCode = $remoteCode;
        $this->details = $details;
    }
}

function wp_mcp_code_env(string $key, string $default = ''): string
{
    $value = getenv($key);
    return $value === false ? $default : $value;
}

function wp_mcp_code_started_at(): float
{
    return $GLOBALS['wpmcp_code_started_at'];
}

function wp_mcp_code_remaining(): int
{
    $timeout = (int) wp_mcp_code_env('WPMCP_CODE_TIMEOUT', '120');
    $elapsed = microtime(true) - wp_mcp_code_started_at();
    return max(1, $timeout - (int) floor($elapsed));
}

function wp_mcp_code_json_flags(): int
{
    return JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE;
}

function wp_mcp_code_json_bytes(mixed $value): int
{
    $json = json_encode($value, wp_mcp_code_json_flags());
    return $json === false ? 0 : strlen($json);
}

function wp_mcp_code_log_event(string $type, array $data = []): void
{
    $log = wp_mcp_code_env('WPMCP_CODE_LOG');
    if ($log === '') {
        return;
    }
    $event = ['type' => $type] + $data;
    $line = json_encode($event, wp_mcp_code_json_flags());
    if ($line === false) {
        return;
    }
    @file_put_contents($log, $line . "\n", FILE_APPEND | LOCK_EX);
}

function wp_mcp_code_next_seq(): int
{
    return ++$GLOBALS['wpmcp_code_seq'];
}

function wp_mcp_code_count_call(): void
{
    $max = (int) wp_mcp_code_env('WPMCP_CODE_MAX_CALLS', '100');
    $totalMax = max(50, $max * 3);
    $GLOBALS['wpmcp_code_total_calls']++;
    if ($GLOBALS['wpmcp_code_total_calls'] > $totalMax) {
        throw new WPMCP_Code_Error(
            'call_budget_exceeded',
            "Total call budget exceeded (max $totalMax).",
            5,
            null,
            null,
            ['max_total_calls' => $totalMax]
        );
    }
}

function wp_mcp_code_count_execution(): void
{
    $max = (int) wp_mcp_code_env('WPMCP_CODE_MAX_CALLS', '100');
    $GLOBALS['wpmcp_code_executions']++;
    if ($GLOBALS['wpmcp_code_executions'] > $max) {
        throw new WPMCP_Code_Error(
            'call_budget_exceeded',
            "Call budget exceeded (max $max).",
            5,
            null,
            null,
            ['max_calls' => $max]
        );
    }
}

function wp_mcp_code_valid_ability(string $ability): bool
{
    return preg_match('#^[a-z0-9-]+(?:/[a-z0-9-]+)+$#', $ability) === 1;
}

function wp_mcp_is_dry_run(): bool
{
    return wp_mcp_code_env('WPMCP_CODE_DRY_RUN') === '1';
}

function wp_mcp_is_read_only(): bool
{
    return wp_mcp_code_env('WPMCP_CODE_READ_ONLY') === '1';
}

function wp_mcp_site(): array
{
    return [
        'name' => wp_mcp_code_env('WPMCP_CODE_SITE'),
        'url' => wp_mcp_code_env('WPMCP_CODE_SITE_URL'),
        'origin' => wp_mcp_code_env('WPMCP_CODE_ORIGIN'),
    ];
}

function wp_mcp_log(string $message): void
{
    wp_mcp_code_log_event('log', ['message' => $message]);
}

function wp_mcp_code_write_all($stream, string $data): void
{
    $length = strlen($data);
    $offset = 0;
    while ($offset < $length) {
        $written = @fwrite($stream, substr($data, $offset));
        if ($written === false || $written === 0) {
            throw new WPMCP_Code_Error('internal_error', 'Failed to write to the wp-mcp child process.', 1);
        }
        $offset += $written;
    }
}

function wp_mcp_code_execute(string $ability, mixed $input): array
{
    $cli = wp_mcp_code_env('WPMCP_CODE_CLI');
    if ($cli === '' || !is_file($cli)) {
        throw new WPMCP_Code_Error('internal_error', 'The wp-mcp CLI path is missing.', 1);
    }

    // Keep child temp files inside the CLI's work directory so the cleanup
    // trap removes them even if this PHP process is killed.
    $workDir = dirname(wp_mcp_code_env('WPMCP_CODE_LOG'));
    if ($workDir === '' || $workDir === '.') {
        $workDir = sys_get_temp_dir();
    }
    $out = tempnam($workDir, 'child-out-');
    $err = tempnam($workDir, 'child-err-');
    if ($out === false || $err === false) {
        if (is_string($out)) {
            @unlink($out);
        }
        if (is_string($err)) {
            @unlink($err);
        }
        throw new WPMCP_Code_Error('internal_error', 'Could not create temporary files.', 1);
    }
    chmod($out, 0600);
    chmod($err, 0600);

    $remaining = wp_mcp_code_remaining();
    $httpTimeout = (int) wp_mcp_code_env('WPMCP_HTTP_TIMEOUT', '30');
    if ($httpTimeout < 1) {
        $httpTimeout = 30;
    }
    $env = [
        'PATH' => wp_mcp_code_env('PATH'),
        'HOME' => wp_mcp_code_env('HOME'),
        'WPMCP_HOME' => wp_mcp_code_env('WPMCP_HOME'),
        'WPMCP_SITE' => wp_mcp_code_env('WPMCP_CODE_SITE'),
        'WPMCP_REST_PLAIN' => wp_mcp_code_env('WPMCP_REST_PLAIN', '0'),
        'WPMCP_HTTP_TIMEOUT' => (string) max(1, min($httpTimeout, 30, $remaining)),
        'WPMCP_QUIET' => '0',
    ];
    foreach ([
        'TMPDIR', 'LANG', 'LC_ALL', 'TZ',
        'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY',
        'http_proxy', 'https_proxy', 'no_proxy',
        'SSL_CERT_FILE', 'SSL_CERT_DIR', 'CURL_CA_BUNDLE',
    ] as $key) {
        $value = getenv($key);
        if ($value !== false && $value !== '') {
            $env[$key] = $value;
        }
    }
    // Child temp bodies and logs stay inside the work directory so the CLI
    // cleanup removes them even after a kill.
    $env['TMPDIR'] = $workDir;

    $cmd = is_executable($cli)
        ? [$cli, '--json', 'run', $ability, '--input', '-']
        : ['bash', $cli, '--json', 'run', $ability, '--input', '-'];
    $spec = [
        0 => ['pipe', 'r'],
        1 => ['file', $out, 'w'],
        2 => ['file', $err, 'w'],
    ];
    $proc = proc_open($cmd, $spec, $pipes, null, $env);
    if (!is_resource($proc)) {
        @unlink($out);
        @unlink($err);
        throw new WPMCP_Code_Error('internal_error', 'Could not start the wp-mcp child process.', 1);
    }

    try {
        $payload = json_encode($input, wp_mcp_code_json_flags());
        if ($payload === false) {
            throw new WPMCP_Code_Error('script_error', 'The ability input is not JSON-encodable.', 5);
        }
        wp_mcp_code_write_all($pipes[0], $payload);
        fclose($pipes[0]);
        $exit = proc_close($proc);
    } catch (Throwable $e) {
        if (isset($pipes[0]) && is_resource($pipes[0])) {
            fclose($pipes[0]);
        }
        @proc_terminate($proc);
        @unlink($out);
        @unlink($err);
        throw $e;
    }

    $stdout = (string) file_get_contents($out);
    $stderr = (string) file_get_contents($err);
    @unlink($out);
    @unlink($err);

    $envelope = json_decode($stdout, true);
    if ($exit === 0 && is_array($envelope) && ($envelope['ok'] ?? false) === true) {
        $status = isset($envelope['meta']['http_status']) ? (int) $envelope['meta']['http_status'] : 200;
        return ['data' => $envelope['data'] ?? null, 'http_status' => $status];
    }

    $error = null;
    $decoded = json_decode($stderr, true);
    if (is_array($decoded) && isset($decoded['error']) && is_array($decoded['error'])) {
        $error = $decoded['error'];
    }

    $code = is_array($error) ? (string) ($error['code'] ?? 'script_error') : 'script_error';
    $message = is_array($error)
        ? (string) ($error['message'] ?? 'The wp-mcp child process failed.')
        : 'The wp-mcp child process failed.';
    $remote = is_array($error) && isset($error['remoteCode']) && $error['remoteCode'] !== ''
        ? (string) $error['remoteCode']
        : null;
    $details = is_array($error) && isset($error['details']) && is_array($error['details'])
        ? $error['details']
        : [];
    if ($remote === null && str_starts_with($code, 'wp_mcp_')) {
        $remote = $code;
    }

    $map = [
        'wp_mcp_ability_not_found' => ['ability_not_found', 2],
        'wp_mcp_ability_hidden' => ['ability_not_found', 2],
        'wp_mcp_invalid_input' => ['schema_validation_failed', 5],
        'wp_mcp_missing_field' => ['schema_validation_failed', 5],
        'wp_mcp_forbidden' => ['auth_denied', 3],
        'wp_mcp_disabled' => ['auth_denied', 3],
    ];
    $exitCode = $exit > 0 ? $exit : 5;
    if (isset($map[$code])) {
        [$code, $exitCode] = $map[$code];
    }

    if (!is_array($error)) {
        $details['stderr'] = substr($stderr, -2000);
    }

    throw new WPMCP_Code_Error($code, $message, $exitCode, null, $remote, $details);
}

function wp_mcp_code_execute_logged(
    string $ability,
    mixed $input,
    string $kind,
    ?int $seq = null,
    ?bool $readonly = null,
    ?bool $destructive = null
): mixed {
    $seq = $seq ?? wp_mcp_code_next_seq();
    $start = microtime(true);
    $bytes = wp_mcp_code_json_bytes($input);
    wp_mcp_code_log_event('call_start', [
        'seq' => $seq,
        'ability' => $ability,
        'kind' => $kind,
        'readonly' => $readonly,
        'destructive' => $destructive,
        'request_bytes' => $bytes,
    ]);

    try {
        $result = wp_mcp_code_execute($ability, $input);
        wp_mcp_code_log_event('call_end', [
            'seq' => $seq,
            'ability' => $ability,
            'kind' => $kind,
            'status' => 'ok',
            'http_status' => $result['http_status'],
            'duration_ms' => (int) round((microtime(true) - $start) * 1000),
            'request_bytes' => $bytes,
            'response_bytes' => wp_mcp_code_json_bytes($result['data']),
            'error_code' => null,
            'readonly' => $readonly,
            'destructive' => $destructive,
        ]);
        return $result['data'];
    } catch (WPMCP_Code_Error $e) {
        wp_mcp_code_log_event('call_end', [
            'seq' => $seq,
            'ability' => $ability,
            'kind' => $kind,
            'status' => 'error',
            'http_status' => $e->httpStatus,
            'duration_ms' => (int) round((microtime(true) - $start) * 1000),
            'request_bytes' => $bytes,
            'response_bytes' => 0,
            'error_code' => $e->errorCode,
            'readonly' => $readonly,
            'destructive' => $destructive,
        ]);
        throw $e;
    }
}

function wp_mcp_code_log_stub(
    int $seq,
    string $ability,
    string $status,
    bool $readonly,
    bool $destructive,
    mixed $input
): void {
    $bytes = wp_mcp_code_json_bytes($input);
    wp_mcp_code_log_event('call_start', [
        'seq' => $seq,
        'ability' => $ability,
        'kind' => 'call',
        'readonly' => $readonly,
        'destructive' => $destructive,
        'request_bytes' => $bytes,
    ]);
    wp_mcp_code_log_event('call_end', [
        'seq' => $seq,
        'ability' => $ability,
        'kind' => 'call',
        'status' => $status,
        'http_status' => null,
        'duration_ms' => 0,
        'request_bytes' => $bytes,
        'response_bytes' => 0,
        'error_code' => null,
        'readonly' => $readonly,
        'destructive' => $destructive,
    ]);
}

function wp_mcp_code_annotations(string $ability): array
{
    if (isset($GLOBALS['wpmcp_code_definitions'][$ability])) {
        return $GLOBALS['wpmcp_code_definitions'][$ability]['meta']['annotations'] ?? [];
    }
    if (isset($GLOBALS['wpmcp_code_annotations'][$ability])) {
        return $GLOBALS['wpmcp_code_annotations'][$ability];
    }
    $definition = wp_mcp_describe($ability);
    return $definition['meta']['annotations'] ?? [];
}

function wp_mcp_code_cache_annotations(array $rows): void
{
    foreach ($rows as $row) {
        if (!is_array($row) || !isset($row['name']) || !is_string($row['name'])) {
            continue;
        }
        if (array_key_exists('readonly', $row) || array_key_exists('destructive', $row)) {
            $GLOBALS['wpmcp_code_annotations'][$row['name']] = [
                'readonly' => ($row['readonly'] ?? false) === true,
                // Fail closed when the discovery row does not say.
                'destructive' => array_key_exists('destructive', $row)
                    ? (bool) $row['destructive']
                    : true,
            ];
        }
    }
}

function wp_mcp_discover(array $options = []): array
{
    wp_mcp_code_count_call();
    $result = wp_mcp_code_execute_logged(
        'mcp-adapter/discover-abilities',
        $options,
        'search',
        null,
        true,
        false
    );
    if (!is_array($result)) {
        throw new WPMCP_Code_Error('script_error', 'The discovery result was not an object.', 5);
    }
    wp_mcp_code_cache_annotations($result['abilities'] ?? []);
    return $result;
}

function wp_mcp_search(string $query, int $limit = 10, ?string $cursor = null): array
{
    $limit = max(1, min(50, $limit));
    $key = md5(json_encode([$query, $limit, $cursor], wp_mcp_code_json_flags()) ?: '');
    if (isset($GLOBALS['wpmcp_code_search_cache'][$key])) {
        return $GLOBALS['wpmcp_code_search_cache'][$key];
    }
    $options = ['query' => $query, 'limit' => $limit];
    if ($cursor !== null && $cursor !== '') {
        $options['cursor'] = $cursor;
    }
    $result = wp_mcp_discover($options);
    $rows = is_array($result['abilities'] ?? null) ? $result['abilities'] : [];
    $GLOBALS['wpmcp_code_search_cache'][$key] = $rows;
    return $rows;
}

function wp_mcp_describe(string $ability): array
{
    if (isset($GLOBALS['wpmcp_code_definitions'][$ability])) {
        return $GLOBALS['wpmcp_code_definitions'][$ability];
    }
    wp_mcp_code_count_call();
    $definition = wp_mcp_code_execute_logged(
        'wp-mcp/get-ability-info',
        ['ability_name' => $ability, 'detail' => 'full'],
        'describe',
        null,
        true,
        false
    );
    if (!is_array($definition)) {
        throw new WPMCP_Code_Error('script_error', 'The ability definition was not an object.', 5);
    }
    $GLOBALS['wpmcp_code_definitions'][$ability] = $definition;
    $annotations = $definition['meta']['annotations'] ?? null;
    if (is_array($annotations)) {
        $GLOBALS['wpmcp_code_annotations'][$ability] = $annotations;
    }
    return $definition;
}

function wp_mcp_call(string $ability, mixed $input = null): mixed
{
    if (!wp_mcp_code_valid_ability($ability)) {
        throw new WPMCP_Code_Error(
            'usage_error',
            "Invalid ability name: $ability",
            2,
            null,
            null,
            ['ability' => $ability]
        );
    }

    wp_mcp_code_count_call();
    wp_mcp_code_count_execution();

    $annotations = wp_mcp_code_annotations($ability);
    $readonly = ($annotations['readonly'] ?? false) === true;
    $destructive = array_key_exists('destructive', $annotations)
        ? (bool) $annotations['destructive']
        : true;

    $seq = wp_mcp_code_next_seq();

    if (wp_mcp_is_dry_run()) {
        wp_mcp_code_log_stub($seq, $ability, 'dry_run', $readonly, $destructive, $input);
        return ['__wp_mcp_dry_run' => true, 'ability' => $ability, 'input' => $input];
    }

    if (wp_mcp_is_read_only() && !$readonly) {
        wp_mcp_code_log_stub($seq, $ability, 'skipped', $readonly, $destructive, $input);
        return ['__wp_mcp_skipped' => true, 'ability' => $ability, 'reason' => 'not_readonly'];
    }

    if ($destructive && wp_mcp_code_env('WPMCP_CODE_ALLOW_DESTRUCTIVE') !== '1') {
        wp_mcp_code_log_stub($seq, $ability, 'blocked', $readonly, $destructive, $input);
        throw new WPMCP_Code_Error(
            'confirmation_required',
            "Ability '$ability' is destructive. Re-run with --yes.",
            6,
            null,
            null,
            ['ability' => $ability, 'seq' => $seq]
        );
    }

    return wp_mcp_code_execute_logged($ability, $input, 'call', $seq, $readonly, $destructive);
}

$GLOBALS['wpmcp_code_started_at'] = microtime(true);
$GLOBALS['wpmcp_code_seq'] = 0;
$GLOBALS['wpmcp_code_executions'] = 0;
$GLOBALS['wpmcp_code_total_calls'] = 0;
$GLOBALS['wpmcp_code_definitions'] = [];
$GLOBALS['wpmcp_code_annotations'] = [];
$GLOBALS['wpmcp_code_search_cache'] = [];

$wpmcp_code_log = wp_mcp_code_env('WPMCP_CODE_LOG');
if ($wpmcp_code_log === '' || !is_file($wpmcp_code_log) || !is_writable($wpmcp_code_log)) {
    fwrite(STDERR, "wp-mcp code: the call log is not writable.\n");
    exit(1);
}
wp_mcp_code_log_event('start', [
    'started_at' => $GLOBALS['wpmcp_code_started_at'],
    'pid' => getmypid(),
]);

set_exception_handler(static function (Throwable $e): void {
    $code = $e instanceof WPMCP_Code_Error ? $e->errorCode : 'script_error';
    $exit = $e instanceof WPMCP_Code_Error ? $e->exitCode : 5;
    $remote = $e instanceof WPMCP_Code_Error ? $e->remoteCode : null;
    $details = $e instanceof WPMCP_Code_Error ? $e->details : [];
    wp_mcp_code_log_event('error', [
        'code' => $code,
        'message' => $e->getMessage(),
        'exit_code' => $exit,
        'remote_code' => $remote,
        'details' => (object) $details,
        'file' => $e->getFile(),
        'line' => $e->getLine(),
    ]);
    exit($exit);
});

register_shutdown_function(static function (): void {
    $last = error_get_last();
    $fatal = [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR];
    if ($last !== null && in_array($last['type'], $fatal, true)) {
        wp_mcp_code_log_event('error', [
            'code' => 'script_error',
            'message' => $last['message'],
            'exit_code' => 5,
            'remote_code' => null,
            'details' => ['file' => $last['file'], 'line' => $last['line']],
        ]);
    }
    wp_mcp_code_log_event('end', [
        'duration_ms' => (int) round((microtime(true) - $GLOBALS['wpmcp_code_started_at']) * 1000),
        'memory_peak' => memory_get_peak_usage(true),
    ]);
});
WPMCP_CODE_BOOTSTRAP

    chmod 600 "$tmp"
    if ! php -l "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
            "The bundled PHP bootstrap failed syntax validation."
    fi
    mv -f "$tmp" "$target"
    printf '%s\n' "$WPMCP_CODE_BOOTSTRAP_VERSION" > "$version_file"
    chmod 600 "$version_file"
}

wpmcp_code_ensure_newline() {
    # Keep the human summary/error from running into script output that does
    # not end with a newline. Only STDERR is touched; the script's STDOUT is
    # preserved exactly for pipelines.
    local file="$1"
    [ -s "$file" ] || return 0
    local last=""
    last=$(tail -c 1 "$file" 2>/dev/null || true)
    if [ -n "$last" ]; then
        printf '\n' >&2
    fi
}

wpmcp_code_read_log() {
    local log="$1"
    if [ ! -s "$log" ]; then
        printf '[]'
        return 0
    fi
    jq -Rsc 'split("\n") | map(select(length > 0) | (fromjson? // empty))' "$log" 2>/dev/null || printf '[]'
}

wpmcp_code_run_php() {
    # wpmcp_code_run_php <script> <bootstrap> <out> <err> <timeout> <timeout_flag>
    local script="$1"
    local bootstrap="$2"
    local out="$3"
    local err="$4"
    local timeout="$5"
    local timeout_flag="$6"
    local status=0

    set -m
    php -d auto_prepend_file="$bootstrap" \
        -d max_execution_time="$timeout" \
        -d display_errors=stderr \
        -d html_errors=0 \
        -d log_errors=0 \
        -d memory_limit=256M \
        "$script" >"$out" 2>"$err" &
    local pid=$!
    WPMCP_CODE_PHP_PID="$pid"

    (
        sleep "$timeout"
        if kill -0 "$pid" 2>/dev/null; then
            : > "$timeout_flag"
            kill -TERM -- "-$pid" 2>/dev/null || true
            sleep 2
            kill -KILL -- "-$pid" 2>/dev/null || true
        fi
    ) &
    local watchdog=$!
    WPMCP_CODE_WATCHDOG_PID="$watchdog"
    # The processes already have their own process groups. Disable monitor
    # mode before they exit so Bash does not print job-control notices to
    # the CLI's stderr (which must stay clean for the JSON error envelope).
    set +m

    wait "$pid" || status=$?
    kill -TERM -- "-$watchdog" 2>/dev/null || kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    WPMCP_CODE_PHP_PID=""
    WPMCP_CODE_WATCHDOG_PID=""

    return "$status"
}

wpmcp_code_render() {
    # wpmcp_code_render <entries> <out_file> <err_file> <status> <timed_out> <dry_run> <read_only> <timeout> <site> <origin> <sha>
    local entries="$1"
    local out_file="$2"
    local err_file="$3"
    local status="$4"
    local timed_out="$5"
    local dry_run="$6"
    local read_only="$7"
    local timeout_seconds="$8"
    local site="$9"
    local origin="${10}"
    local sha="${11}"

    local work_dir
    work_dir=$(dirname "$out_file")
    local out_trunc="$work_dir/out.trunc"
    local err_trunc="$work_dir/err.trunc"
    local output_json="$work_dir/output.json"
    local stderr_json="$work_dir/stderr.json"
    local calls_file="$work_dir/calls.json"
    local logs_file="$work_dir/logs.json"

    local running_status="unknown"
    if [ "$timed_out" = "1" ]; then
        running_status="timeout"
    elif [ "$status" -ne 0 ]; then
        running_status="error"
    fi

    calls_json=$(printf '%s' "$entries" | jq -c --arg running "$running_status" '
        reduce .[] as $e ({};
            if $e.type == "call_start" then
                .[($e.seq|tostring)] = {
                    seq: $e.seq,
                    ability: $e.ability,
                    kind: $e.kind,
                    readonly: ($e.readonly // false),
                    destructive: ($e.destructive // false),
                    status: "running",
                    http_status: null,
                    duration_ms: null,
                    request_bytes: ($e.request_bytes // 0),
                    response_bytes: null,
                    error_code: null
                }
            elif $e.type == "call_end" then
                .[($e.seq|tostring)] = (
                    (.[($e.seq|tostring)] // {
                        seq: $e.seq,
                        ability: $e.ability,
                        kind: $e.kind,
                        readonly: ($e.readonly // false),
                        destructive: ($e.destructive // false)
                    }) + {
                        status: $e.status,
                        http_status: $e.http_status,
                        duration_ms: $e.duration_ms,
                        request_bytes: ($e.request_bytes // 0),
                        response_bytes: ($e.response_bytes // 0),
                        error_code: $e.error_code
                    }
                )
            else . end
        ) | [.[]] | sort_by(.seq) | map(if .status == "running" then .status = $running else . end)
    ')

    logs_json=$(printf '%s' "$entries" | jq -c '[.[] | select(.type == "log") | .message]')
    printf '%s' "$calls_json" > "$calls_file"
    printf '%s' "$logs_json" > "$logs_file"
    local error_json
    error_json=$(printf '%s' "$entries" | jq -c '[.[] | select(.type == "error")] | last // null')
    local end_json
    end_json=$(printf '%s' "$entries" | jq -c '[.[] | select(.type == "end")] | last // null')
    local start_json
    start_json=$(printf '%s' "$entries" | jq -c '[.[] | select(.type == "start")] | last // null')

    local duration_ms=0
    if [ "$end_json" != "null" ]; then
        duration_ms=$(printf '%s' "$end_json" | jq -r '.duration_ms // 0')
    elif [ "$start_json" != "null" ]; then
        duration_ms=$(printf '%s' "$start_json" | jq -r --argjson now "$(date +%s)" \
            '((($now - .started_at) * 1000) | floor)')
    fi

    head -c "$WPMCP_CODE_OUTPUT_LIMIT" "$out_file" > "$out_trunc" 2>/dev/null || : > "$out_trunc"
    head -c "$WPMCP_CODE_OUTPUT_LIMIT" "$err_file" > "$err_trunc" 2>/dev/null || : > "$err_trunc"

    local out_size err_size
    out_size=$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')
    err_size=$(wc -c < "$err_file" 2>/dev/null | tr -d ' ')
    out_size=${out_size:-0}
    err_size=${err_size:-0}
    local truncated="false"
    local stderr_truncated="false"
    [ "$out_size" -gt "$WPMCP_CODE_OUTPUT_LIMIT" ] && truncated="true"
    [ "$err_size" -gt "$WPMCP_CODE_OUTPUT_LIMIT" ] && stderr_truncated="true"

    local output_encoding="utf8"
    if wpmcp_command_exists iconv; then
        if ! iconv -f UTF-8 -t UTF-8 "$out_trunc" >/dev/null 2>&1; then
            output_encoding="base64"
        fi
    fi

    local output_type="text"
    if [ ! -s "$out_trunc" ]; then
        printf '""' > "$output_json"
    elif [ "$output_encoding" = "base64" ]; then
        if wpmcp_command_exists base64; then
            base64 < "$out_trunc" | tr -d '\n' | jq -Rsc . > "$output_json"
        else
            jq -Rsc . "$out_trunc" > "$output_json"
            output_encoding="utf8"
        fi
    elif jq -c . "$out_trunc" > "$output_json" 2>/dev/null && [ -s "$output_json" ] &&
        [ "$(jq -s 'length' "$output_json" 2>/dev/null || echo 0)" -eq 1 ]; then
        output_type="json"
    else
        jq -Rsc . "$out_trunc" > "$output_json"
    fi

    jq -Rsc . "$err_trunc" > "$stderr_json"

    local error_code="" error_message="" error_exit=5 error_remote="" details_json="{}"
    if [ "$error_json" != "null" ]; then
        error_code=$(printf '%s' "$error_json" | jq -r '.code // "script_error"')
        error_message=$(printf '%s' "$error_json" | jq -r '.message // "Script failed."')
        error_exit=$(printf '%s' "$error_json" | jq -r '.exit_code // 5')
        error_remote=$(printf '%s' "$error_json" | jq -r '.remote_code // ""')
        local calls_count
        calls_count=$(printf '%s' "$calls_json" | jq 'length')
        local stderr_tail
        stderr_tail=$(tail -c 2000 "$err_file" 2>/dev/null | jq -Rsc .)
        details_json=$(printf '%s' "$error_json" | jq -c \
            --argjson calls "$calls_count" \
            --argjson stderr "$stderr_tail" \
            '((.details | if type == "object" then . else {} end)) + {calls: $calls, stderr: $stderr}')
    elif [ "$timed_out" = "1" ]; then
        error_code="script_error"
        error_message="Script timed out after ${timeout_seconds}s."
        error_exit=5
        local calls_count
        calls_count=$(printf '%s' "$calls_json" | jq 'length')
        details_json=$(jq -nc --argjson calls "$calls_count" --argjson timeout "$timeout_seconds" \
            '{calls: $calls, timeout: $timeout, reason: "timeout"}')
    elif [ "$status" -ne 0 ]; then
        error_code="script_error"
        error_message="Script exited with status $status."
        error_exit=5
        local calls_count
        calls_count=$(printf '%s' "$calls_json" | jq 'length')
        local stderr_tail
        stderr_tail=$(tail -c 2000 "$err_file" 2>/dev/null | jq -Rsc .)
        details_json=$(jq -nc --argjson calls "$calls_count" --argjson status "$status" --argjson stderr "$stderr_tail" \
            '{calls: $calls, exit_code: $status, stderr: $stderr}')
    fi

    if [ -n "$error_code" ]; then
        if [ "$WPMCP_JSON" = "1" ]; then
            wpmcp_output_envelope_err "$error_code" "$error_message" false "$error_remote" "$details_json" >&2
        else
            if [ "$WPMCP_QUIET" != "1" ]; then
                cat "$out_file" 2>/dev/null || true
                wpmcp_code_ensure_newline "$out_file"
            fi
            if [ "$WPMCP_CODE_VERBOSE" = "1" ] && [ -s "$err_file" ]; then
                cat "$err_file" >&2
                wpmcp_code_ensure_newline "$err_file"
            fi
            echo "Error: $error_message" >&2
        fi
        return "$error_exit"
    fi

    if [ "$WPMCP_JSON" = "1" ]; then
        jq -cs \
            --arg site "$site" \
            --arg origin "$origin" \
            --arg sha "$sha" \
            --arg output_type "$output_type" \
            --arg output_encoding "$output_encoding" \
            --argjson dry_run "$([ "$dry_run" = "1" ] && echo true || echo false)" \
            --argjson read_only "$([ "$read_only" = "1" ] && echo true || echo false)" \
            --argjson duration_ms "$duration_ms" \
            --argjson truncated "$truncated" \
            --argjson stderr_truncated "$stderr_truncated" \
            '.[0] as $output | .[1] as $calls | .[2] as $logs | .[3] as $stderr |
             {ok: true,
              data: {
                output: $output,
                output_type: $output_type,
                output_encoding: $output_encoding,
                stderr: $stderr,
                stderr_truncated: $stderr_truncated,
                calls: $calls,
                logs: $logs,
                dry_run: $dry_run,
                read_only: $read_only,
                duration_ms: $duration_ms,
                truncated: $truncated
              },
              meta: {site: $site, origin: $origin, script_sha256: $sha}}' \
            "$output_json" "$calls_file" "$logs_file" "$stderr_json"
        return 0
    fi

    if [ "$WPMCP_QUIET" != "1" ]; then
        cat "$out_file" 2>/dev/null || true
        wpmcp_code_ensure_newline "$out_file"
    fi
    if [ "$WPMCP_QUIET" != "1" ] && [ -s "$err_file" ]; then
        cat "$err_file" >&2
        wpmcp_code_ensure_newline "$err_file"
    fi

    if [ "$WPMCP_QUIET" != "1" ]; then
        local log_line
        while IFS= read -r log_line; do
            [ -z "$log_line" ] && continue
            printf '[wp-mcp] %s\n' "$log_line" >&2
        done < <(printf '%s' "$logs_json" | jq -r '.[]')
    fi

    if [ "$WPMCP_CODE_VERBOSE" = "1" ]; then
        printf '%s' "$calls_json" | jq -r '.[] | "[wp-mcp] #\(.seq) \(.kind) \(.ability) \(.status) \(.duration_ms // 0)ms req=\(.request_bytes // 0)B resp=\(.response_bytes // 0)B"' >&2
    fi

    if [ "$WPMCP_QUIET" != "1" ]; then
        local calls_count reads writes skipped dry meta
        calls_count=$(printf '%s' "$calls_json" | jq 'length')
        reads=$(printf '%s' "$calls_json" | jq '[.[] | select(.kind == "call" and .readonly == true)] | length')
        writes=$(printf '%s' "$calls_json" | jq '[.[] | select(.kind == "call" and .readonly == false and .status == "ok")] | length')
        skipped=$(printf '%s' "$calls_json" | jq '[.[] | select(.status == "skipped")] | length')
        dry=$(printf '%s' "$calls_json" | jq '[.[] | select(.status == "dry_run")] | length')
        meta=$(printf '%s' "$calls_json" | jq '[.[] | select(.kind == "search" or .kind == "describe")] | length')
        printf '%s calls: %s read, %s write, %s skipped, %s dry-run, %s metadata' \
            "$calls_count" "$reads" "$writes" "$skipped" "$dry" "$meta" >&2
        if [ "$dry_run" = "1" ]; then
            printf ' (dry-run)' >&2
        elif [ "$read_only" = "1" ]; then
            printf ' (read-only)' >&2
        fi
        printf '\n' >&2
    fi

    return 0
}

# Source: shared/config.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Load and save the sites.json profile registry.
# Atomic writes via temp file + rename; permissive lock file per profile.

wpmcp_config_load() {
    wpmcp_paths_init
    if [ ! -f "$WPMCP_CONFIG_FILE" ]; then
        echo '{"version":1,"profiles":{}}'
        return 0
    fi
    cat "$WPMCP_CONFIG_FILE"
}

wpmcp_config_save() {
    # wpmcp_config_save <json>
    local json="$1"
    wpmcp_paths_ensure
    local tmp="${WPMCP_CONFIG_FILE}.tmp.$$"
    umask 077
    printf '%s\n' "$json" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$WPMCP_CONFIG_FILE"
}

wpmcp_config_list_profiles() {
    wpmcp_config_load | jq -r '.profiles | keys[]'
}

wpmcp_config_get_profile() {
    # wpmcp_config_get_profile <name> → JSON object (single line) or empty
    local name="$1"
    wpmcp_config_load | jq -r --arg n "$name" '.profiles[$n] // empty'
}

wpmcp_config_upsert_profile() {
    # wpmcp_config_upsert_profile <name> <profile_json_object>
    local name="$1"
    local profile_json="$2"
    local current
    current=$(wpmcp_config_load)
    echo "$current" | jq --arg n "$name" --argjson p "$profile_json" \
        '.profiles[$n] = $p' | wpmcp_config_save_stdin
}

wpmcp_config_remove_profile() {
    local name="$1"
    wpmcp_config_load | jq --arg n "$name" 'del(.profiles[$n])' | wpmcp_config_save_stdin
}

wpmcp_config_save_stdin() {
    wpmcp_paths_ensure
    local tmp="${WPMCP_CONFIG_FILE}.tmp.$$"
    umask 077
    cat > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$WPMCP_CONFIG_FILE"
}

wpmcp_config_resolve_site() {
    # Resolve the active site name using --site / WPMCP_SITE / single-implicit.
    # Sets WPMCP_ACTIVE_SITE and WPMCP_ACTIVE_ORIGIN. Exits with site_required
    # if ambiguous or unknown.

    wpmcp_paths_init
    local explicit=""
    if [ -n "${WPMCP_SITE:-}" ]; then
        explicit="$WPMCP_SITE"
    fi

    local config
    config=$(wpmcp_config_load)
    local count
    count=$(echo "$config" | jq -r '.profiles | keys | length')

    if [ -n "$explicit" ]; then
        local exists
        exists=$(echo "$config" | jq -r --arg n "$explicit" '(.profiles[$n] // null) | type')
        if [ "$exists" != "object" ]; then
            local known
            known=$(echo "$config" | jq -c '[.profiles | keys[]]')
            wpmcp_error_site_not_found "$explicit" "$known"
        fi
        WPMCP_ACTIVE_SITE="$explicit"
        WPMCP_ACTIVE_ORIGIN=$(echo "$config" | jq -r --arg n "$explicit" '.profiles[$n].origin // .profiles[$n].siteUrl // ""')
        export WPMCP_ACTIVE_SITE WPMCP_ACTIVE_ORIGIN
        return 0
    fi

    if [ "$count" -eq 0 ]; then
        wpmcp_error_usage "No site profiles configured. Run: wp-mcp auth login <url>"
    fi

    if [ "$count" -eq 1 ]; then
        WPMCP_ACTIVE_SITE=$(echo "$config" | jq -r '.profiles | keys[0]')
        WPMCP_ACTIVE_ORIGIN=$(echo "$config" | jq -r --arg n "$WPMCP_ACTIVE_SITE" '.profiles[$n].origin // .profiles[$n].siteUrl // ""')
        export WPMCP_ACTIVE_SITE WPMCP_ACTIVE_ORIGIN
        return 0
    fi

    # Multiple profiles without explicit selector.
    local profiles_json
    profiles_json=$(echo "$config" | jq -c '[.profiles | keys[]]')
    wpmcp_error_site_required "$profiles_json"
}

# Source: shared/errors.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Stable error catalog. Mirrors the spirit of novamira-cli's errors.ts.
# Each code maps to a documented exit code and a recognizable message
# prefix so agents can branch on `error.code` instead of strings.

# Exit codes (kept stable across versions):
#   0  success
#   1  internal_error
#   2  usage_error | site_required | site_not_found | ability_not_found
#   3  auth_required | auth_denied | auth_expired
#   4  network_error | rest_error | server_unsupported
#   5  ability_execution_failed | schema_validation_failed
#   6  confirmation_required

WPMCP_ERROR_USAGE=2
WPMCP_ERROR_AUTH=3
WPMCP_ERROR_NETWORK=4
WPMCP_ERROR_EXECUTION=5
WPMCP_ERROR_CONFIRMATION=6
WPMCP_ERROR_INTERNAL=1

wpmcp_error_print() {
    # wpmcp_error_print <code> <exit_code> <message>
    local code="$1"
    local exit_code="$2"
    shift 2
    local message="$*"
    if [ "${WPMCP_JSON:-0}" = "1" ]; then
        wpmcp_output_envelope_err "$code" "$message" false "" "" >&2
    else
        echo "Error: $message" >&2
    fi
    exit "$exit_code"
}

wpmcp_error_usage() {
    wpmcp_error_print "usage_error" "$WPMCP_ERROR_USAGE" "$@"
}

wpmcp_error_site_required() {
    local profiles_json="$1"
    local msg="Select a site profile with --site or WPMCP_SITE."
    if [ "$WPMCP_JSON" = "1" ]; then
        echo "{\"ok\":false,\"error\":{\"code\":\"site_required\",\"message\":\"$msg\",\"details\":{\"profiles\":$profiles_json}}}" >&2
    else
        echo "Error: $msg" >&2
        if [ -n "$profiles_json" ] && [ "$profiles_json" != "[]" ]; then
            echo "Known profiles:" >&2
            echo "$profiles_json" | jq -r '.[] | "  - " + .' >&2
        fi
    fi
    exit "$WPMCP_ERROR_USAGE"
}

wpmcp_error_site_not_found() {
    local name="$1"
    local known="$2"
    wpmcp_error_print "site_not_found" "$WPMCP_ERROR_USAGE" \
        "Site profile '$name' not found. Known profiles: $known"
}

wpmcp_error_auth_required() {
    local site="$1"
    wpmcp_error_print "auth_required" "$WPMCP_ERROR_AUTH" \
        "No credentials for site '$site'. Run: wp-mcp auth login"
}

# Source: shared/http.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# HTTP client wrapper around curl. Uses HTTP Basic auth with WordPress
# Application Passwords. Returns:
#   - body text on stdout
#   - status code on a fd or via the helper function
# Errors are classified via shared/errors.sh and emit stable envelopes.

WPMCP_HTTP_DEFAULT_TIMEOUT=30

wpmcp_http_request() {
    # wpmcp_http_request <method> <url> [<json_body_file>]
    # Echoes "STATUS<TAB>BODY" so callers can split easily without
    # subshell overhead. Use `wpmcp_http_status` / `wpmcp_http_body`.
    #
    # Credentials are passed to curl through `--config -`, which reads a
    # temporary config from STDIN. This keeps the application password out
    # of argv (visible in `ps`) and out of the process environment.
    local method="$1"
    local url="$2"
    local body_file="${3:-}"

    local timeout="${WPMCP_HTTP_TIMEOUT:-$WPMCP_HTTP_DEFAULT_TIMEOUT}"

    local curl_args=(
        --silent --show-error
        --max-time "$timeout"
        --output -                    # body to stdout
        --write-out '%{http_code}'    # status appended
        -X "$method"
        -H 'Accept: application/json'
    )

    if [ -n "$body_file" ]; then
        curl_args+=(-H 'Content-Type: application/json' --data-binary "@$body_file")
    fi

    if [ "${WPMCP_HTTP_VERBOSE:-0}" = "1" ]; then
        curl_args+=(--verbose)
    fi

    local rc=0
    if [ -n "${WPMCP_ACTIVE_USER:-}" ] && [ -n "${WPMCP_ACTIVE_PASS:-}" ]; then
        # Escape backslashes and double quotes so unusual credentials do not
        # break curl's config parser. `printf` is a shell builtin, so the
        # password is not exposed in a child process argument list.
        local pair="${WPMCP_ACTIVE_USER}:${WPMCP_ACTIVE_PASS}"
        pair="${pair//\\/\\\\}"
        pair="${pair//\"/\\\"}"
        curl_args+=(--basic --config -)
        printf 'user = "%s"\n' "$pair" | curl "${curl_args[@]}" "$url" 2>/dev/null || rc=$?
    else
        curl "${curl_args[@]}" "$url" 2>/dev/null || rc=$?
    fi
    return $rc
}

wpmcp_http_get() {
    # GET <url> → emits STATUS<TAB>BODY (use wpmcp_http_split)
    wpmcp_http_request GET "$1"
}

wpmcp_http_post_json() {
    # POST <url> <json_string> → emits STATUS<TAB>BODY
    # The body goes through a 0600 temporary file so large payloads never
    # hit ARG_MAX and are not visible in the curl/jq process arguments.
    local url="$1"
    local json="$2"
    local tmp
    tmp=$(mktemp) || return 1
    chmod 600 "$tmp"
    printf '%s' "$json" > "$tmp"
    local rc=0
    wpmcp_http_request POST "$url" "$tmp" || rc=$?
    rm -f "$tmp"
    return $rc
}

wpmcp_http_split() {
    # Splits a "STATUS<TAB>BODY" response into globals WPMCP_HTTP_STATUS
    # and WPMCP_HTTP_BODY. Returns non-zero if the body is empty or the
    # response shape is unexpected.
    local raw="$1"
    # The last 3 characters are the status code (HTTP/1.1 3-digit).
    # We rely on curl's --write-out to append the code after the body
    # with no separator. Split by reading the last 3 chars.
    local len=${#raw}
    if [ "$len" -lt 3 ]; then
        return 1
    fi
    WPMCP_HTTP_STATUS="${raw: -3}"
    WPMCP_HTTP_BODY="${raw:0:$((len - 3))}"
    # Keep the response in this shell. Exporting it puts potentially large
    # (and sensitive) bodies in every child's environment and can trigger
    # E2BIG on the next jq/curl call.
    export -n WPMCP_HTTP_STATUS WPMCP_HTTP_BODY 2>/dev/null || true
}

wpmcp_http_classify_wp_error() {
    # Parses a WordPress REST error envelope ({"code","message","data":{...}}).
    # Maps the code to a stable CLI error category via wpmcp_error_print.
    local body="$1"
    local code message
    code=$(echo "$body" | jq -r '.code // "unknown"')
    message=$(echo "$body" | jq -r '.message // "Unknown error"')
    local wp_status
    wp_status=$(echo "$body" | jq -r '.data.status // empty')

    case "$code" in
        wp_mcp_disabled|wp_mcp_forbidden|wp_mcp_sandbox_violation|wp_mcp_sandbox_only|wp_mcp_path_blocked)
            wpmcp_error_print "$code" "$WPMCP_ERROR_AUTH" "$message"
            ;;
        wp_mcp_ability_not_found|wp_mcp_ability_hidden|wp_mcp_path_missing|wp_mcp_path_unreadable|wp_mcp_invalid_id)
            wpmcp_error_print "$code" "$WPMCP_ERROR_USAGE" "$message"
            ;;
        wp_mcp_invalid_input|wp_mcp_missing_field)
            wpmcp_error_print "$code" "$WPMCP_ERROR_EXECUTION" "$message"
            ;;
        *)
            # Unknown WP-side error: surface the original code.
            wpmcp_error_print "$code" "$WPMCP_ERROR_EXECUTION" "$message"
            ;;
    esac
}

wpmcp_http_call() {
    # wpmcp_http_call <method> <url> [<json_body>]
    # Performs a request, classifies errors, and emits a normalized
    # envelope to STDOUT (when --json) or pretty (when human mode).
    # Always returns the response body to stdout on success.
    local method="$1"
    local url="$2"
    local body="${3:-}"

    local raw rc=0
    if [ "$method" = "GET" ]; then
        raw=$(wpmcp_http_get "$url") || rc=$?
    else
        raw=$(wpmcp_http_post_json "$url" "$body") || rc=$?
    fi
    if [ $rc -ne 0 ]; then
        wpmcp_error_print "network_error" "$WPMCP_ERROR_NETWORK" \
            "HTTP request failed (curl exit $rc)"
    fi

    wpmcp_http_split "$raw"
    if [ "$WPMCP_HTTP_STATUS" -ge 400 ]; then
        wpmcp_http_classify_wp_error "$WPMCP_HTTP_BODY"
    fi

    if [ "$WPMCP_JSON" = "1" ]; then
        wpmcp_output_envelope_ok "$WPMCP_HTTP_BODY"
    else
        printf '%s\n' "$WPMCP_HTTP_BODY"
    fi
}

# Source: shared/output.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Output rendering. The CLI emits two stable contracts:
#
#   Success envelope (always one JSON object on STDOUT):
#     {"ok":true,"data":<value>,"meta":{"site":"...","origin":"..."}}
#
#   Error envelope (always one JSON object on STDERR when --json):
#     {"ok":false,"error":{"code":"...","message":"...","retryable":bool,
#                          "remoteCode":"...","details":{...}}}
#
# In human mode (no --json), the body is printed pretty-printed.

wpmcp_output_envelope_ok() {
    # wpmcp_output_envelope_ok <body>
    # The body is passed to jq on stdin so it never appears in jq's argv.
    local body="$1"
    local site origin
    site="${WPMCP_ACTIVE_SITE:-}"
    origin="${WPMCP_ACTIVE_ORIGIN:-}"

    if [ -z "$body" ]; then
        printf 'null' | jq -c \
            --arg site "$site" \
            --arg origin "$origin" \
            '{ok:true,data:.,meta:{site:$site,origin:$origin}}'
    elif printf '%s' "$body" | jq -c . >/dev/null 2>&1; then
        printf '%s' "$body" | jq -c \
            --arg site "$site" \
            --arg origin "$origin" \
            '{ok:true,data:.,meta:{site:$site,origin:$origin}}'
    else
        printf '%s' "$body" | jq -Rsc \
            --arg site "$site" \
            --arg origin "$origin" \
            '{ok:true,data:.,meta:{site:$site,origin:$origin}}'
    fi
}

wpmcp_output_envelope_err() {
    # wpmcp_output_envelope_err <code> <message> [<retryable>] [<remote_code>] [<details_json>]
    local code="$1"
    local message="$2"
    local retryable="${3:-false}"
    local remote_code="${4:-}"
    local details="${5:-}"

    local detail_obj="null"
    if [ -n "$details" ]; then
        detail_obj=$(echo "$details" | jq -c . 2>/dev/null || jq -n --arg s "$details" '$s')
    fi

    jq -nc \
        --arg code "$code" \
        --arg msg "$message" \
        --argjson retryable "$retryable" \
        --arg remote "$remote_code" \
        --argjson details "$detail_obj" \
        '{ok:false,error:{code:$code,message:$msg,retryable:$retryable,remoteCode:$remote,details:$details}}'
}

wpmcp_output_human() {
    # Pretty-print the body if it is JSON, otherwise print as-is.
    local body="$1"
    if echo "$body" | jq -e . >/dev/null 2>&1; then
        echo "$body" | jq .
    else
        printf '%s\n' "$body"
    fi
}

wpmcp_output_silent() {
    # In --quiet mode, suppress success output but keep errors.
    [ "$WPMCP_QUIET" = "1" ] && return 0
    cat
}

# Source: shared/paths.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# XDG-style filesystem locations used by every wp-mcp-cli command.
# Override WPMCP_HOME for tests or non-standard layouts.

wpmcp_paths_init() {
    : "${WPMCP_HOME:="$HOME/.wp-mcp"}"
    export WPMCP_HOME

    WPMCP_CONFIG_FILE="$WPMCP_HOME/sites.json"
    WPMCP_CREDS_DIR="$WPMCP_HOME/credentials"
    WPMCP_CACHE_DIR="$WPMCP_HOME/cache"
    WPMCP_LOCK_DIR="$WPMCP_HOME/locks"

    export WPMCP_CONFIG_FILE
    export WPMCP_CREDS_DIR
    export WPMCP_CACHE_DIR
    export WPMCP_LOCK_DIR
}

wpmcp_paths_ensure() {
    wpmcp_paths_init
    for dir in "$WPMCP_HOME" "$WPMCP_CREDS_DIR" "$WPMCP_CACHE_DIR" "$WPMCP_LOCK_DIR"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            chmod 700 "$dir"
        fi
    done
}

# Source: shared/ui.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# gum wrappers. Every helper checks for a TTY first and falls back to
# stdin/flags/env when no TTY is available, so commands remain usable
# in CI and from coding agents.
#
# The second positional argument is the "flag hint" — a short string
# (e.g. "--user", "WPMCP_USERNAME") that the error message includes so
# the caller knows exactly which mechanism to use in non-TTY mode.

wpmcp_ui_input() {
    # wpmcp_ui_input <prompt> <flag_hint> [<default>] [env_var]
    #   flag_hint: short hint like "--user" or "WPMCP_USERNAME" shown
    #              in the non-TTY error.
    #   env_var:   optional environment variable to read as a fallback
    #              before falling back to gum.
    local prompt="$1"
    local flag_hint="$2"
    local default="${3:-}"
    local env_var="${4:-}"

    if [ -n "$env_var" ] && [ -n "${!env_var:-}" ]; then
        printf '%s' "${!env_var}"
        return 0
    fi

    if ! wpmcp_has_tty; then
        wpmcp_error_usage "Missing $prompt. Pass '$flag_hint' as a flag${env_var:+ or set $env_var}."
    fi
    wpmcp_require_gum
    local args=(--prompt "$prompt" --prompt.foreground 212)
    if [ -n "$default" ]; then
        args+=(--value "$default")
    fi
    gum input "${args[@]}"
}

wpmcp_ui_password() {
    # wpmcp_ui_password <prompt> <flag_hint> [env_var]
    local prompt="$1"
    local flag_hint="$2"
    local env_var="${3:-}"

    if [ -n "$env_var" ] && [ -n "${!env_var:-}" ]; then
        printf '%s' "${!env_var}"
        return 0
    fi

    if ! wpmcp_has_tty; then
        wpmcp_error_usage "Missing $prompt. Pass '$flag_hint' as a flag${env_var:+ or set $env_var}."
    fi
    wpmcp_require_gum
    gum input --password --prompt "$prompt" --prompt.foreground 212
}

wpmcp_ui_confirm() {
    # wpmcp_ui_confirm <prompt> [<default_yes>]
    local prompt="$1"
    local default_yes="${2:-true}"
    if ! wpmcp_has_tty; then
        wpmcp_error_print "confirmation_required" "$WPMCP_ERROR_CONFIRMATION" \
            "$prompt (pass --yes to confirm)"
    fi
    wpmcp_require_gum
    local args=(--prompt "$prompt" --affirmative "Yes" --negative "No")
    if [ "$default_yes" = "true" ]; then
        args+=(--default=true)
    else
        args+=(--default=false)
    fi
    gum confirm "${args[@]}"
}

wpmcp_ui_choose() {
    # wpmcp_ui_choose <prompt> <flag_hint> <newline_separated_options>
    local prompt="$1"
    local flag_hint="$2"
    shift 2
    if ! wpmcp_has_tty; then
        wpmcp_error_usage "Missing $prompt. Pass '$flag_hint' as a flag."
    fi
    wpmcp_require_gum
    printf '%s\n' "$@" | gum choose --prompt "$prompt" --header "$prompt"
}

wpmcp_ui_table() {
    # wpmcp_ui_table <tsv_data> [<columns_comma_separated>]
    local tsv="$1"
    local columns="${2:-}"
    if ! wpmcp_has_tty; then
        # In non-TTY contexts, print TSV plain for piping into other tools.
        printf '%s\n' "$tsv"
        return 0
    fi
    wpmcp_require_gum
    local args=()
    # gum's --columns flag expects a single comma-separated string,
    # not one argv entry per column name.
    if [ -n "$columns" ]; then
        args+=(--columns "$columns")
    fi
    # gum's --separator flag sets the field separator. The flag is
    # documented with a comma as its example value, which makes it
    # ambiguous whether the default is comma or auto-detected tab.
    # Pass tab explicitly so the field split is unambiguous and works
    # the same on every gum version.
    printf '%s\n' "$tsv" | gum table "${args[@]}" --separator $'\t' --border rounded --print
}

wpmcp_ui_spin() {
    # wpmcp_ui_spin <title> <command...> → runs command, suppressing gum output if non-TTY
    local title="$1"
    shift
    if ! wpmcp_has_tty; then
        "$@"
        return $?
    fi
    wpmcp_require_gum
    gum spin --title "$title" --spinner dot -- "$@"
}

# Source: shared/url.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# URL helpers. Pretty permalinks are assumed (Plak default). Set
# WPMCP_REST_PLAIN=1 to fall back to ?rest_route=... for sites that
# haven't enabled pretty permalinks.

wpmcp_rest_url_for() {
    # wpmcp_rest_url_for <route> → absolute URL
    local route="$1"
    local site_url
    site_url=$(wpmcp_config_get_profile "$WPMCP_ACTIVE_SITE" | jq -r '.siteUrl')
    if [ -z "$site_url" ] || [ "$site_url" = "null" ]; then
        wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
            "Active site has no siteUrl: $WPMCP_ACTIVE_SITE"
    fi
    site_url="${site_url%/}"

    if [ "${WPMCP_REST_PLAIN:-0}" = "1" ]; then
        printf '%s/index.php?rest_route=%s' "$site_url" "$route"
    else
        printf '%s/wp-json%s' "$site_url" "$route"
    fi
}

wpmcp_url_path_encode() {
    # Percent-encode a single path segment. Uses jq + @uri which handles
    # RFC 3986 unreserved chars correctly.
    printf '%s' "$1" | jq -sRr @uri
}

# Source: shared/version.sh
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp-cli version reporting.

wpmcp_version_print() {
    echo "$WPMCP_NAME v$WPMCP_VERSION"
}

wpmcp_version_json() {
    jq -nc \
        --arg name "$WPMCP_NAME" \
        --arg version "$WPMCP_VERSION" \
        --arg os "$WPMCP_OS" \
        '{name:$name,version:$version,os:$os}'
}

wpmcp_version() {
    if [ "$WPMCP_JSON" = "1" ]; then
        wpmcp_version_json
    else
        wpmcp_version_print
    fi
}

# --- Command Functions ---
# Source: commands/auth
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp auth login | status | logout

wpmcp_auth() {
    local action="${1:-help}"
    [ "$#" -gt 0 ] && shift

    case "$action" in
        login)
            wpmcp_auth_login "$@"
            ;;
        status)
            wpmcp_auth_status "$@"
            ;;
        logout)
            wpmcp_auth_logout "$@"
            ;;
        help|--help|-h)
            wpmcp_display_command_help auth
            ;;
        *)
            wpmcp_error_usage "Unknown auth action: $action"
            ;;
    esac
}

wpmcp_auth_login() {
    wpmcp_paths_ensure

    local url=""
    local name=""
    local user=""
    local pass=""

    # Parse flags after the action.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name)
                name="$2"
                shift 2
                ;;
            --user)
                user="$2"
                shift 2
                ;;
            --password)
                pass="$2"
                shift 2
                ;;
            --url)
                url="$2"
                shift 2
                ;;
            --help|-h)
                wpmcp_display_command_help auth
                return 0
                ;;
            *)
                # First non-flag is the URL.
                if [ -z "$url" ]; then
                    url="$1"
                    shift
                else
                    wpmcp_error_usage "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    # Pre-resolve everything we can from flags + env, then collect the
    # list of values that still need to come from gum (interactive) or
    # the user (a clearer error in non-TTY mode). This collapses the
    # error path to a single message listing every missing input.

    if [ -z "$user" ] && [ -n "${WPMCP_USERNAME:-}" ]; then
        user="$WPMCP_USERNAME"
    fi
    if [ -z "$pass" ] && [ -n "${WPMCP_PASSWORD_INPUT:-}" ]; then
        pass="$WPMCP_PASSWORD_INPUT"
    fi

    local missing=()
    [ -z "$url" ]  && missing+=("site URL (positional argument or --url)")
    [ -z "$user" ] && missing+=("WordPress username (--user or WPMCP_USERNAME)")
    [ -z "$pass" ] && missing+=("application password (--password or WPMCP_PASSWORD)")

    if [ "${#missing[@]}" -gt 0 ]; then
        if ! wpmcp_has_tty; then
            printf 'Error: missing required values for auth login:\n' >&2
            for m in "${missing[@]}"; do
                printf '  - %s\n' "$m" >&2
            done
            exit "$WPMCP_ERROR_USAGE"
        fi

        # Interactive fallback: prompt for whatever is still missing.
        if [ -z "$url" ]; then
            url=$(wpmcp_ui_input "Site URL (e.g. https://dev.localhost)" "url")
        fi
        if [ -z "$user" ]; then
            user=$(wpmcp_ui_input "WordPress username" "--user")
        fi
        if [ -z "$pass" ]; then
            pass=$(wpmcp_ui_password "Application password" "--password")
        fi
    fi

    # Do not let a password supplied through the environment reach the
    # child processes (curl, jq) used by the probe and the credential save.
    unset WPMCP_PASSWORD

    url=$(printf '%s' "$url" | sed 's:/*$::')

    # Derive origin (scheme://host[:port]) and default name.
    local origin
    origin=$(printf '%s' "$url" | sed -E 's#^(https?://[^/]+).*#\1#')
    if [ -z "$name" ]; then
        name=$(printf '%s' "$origin" | sed -E 's#^https?://##; s#[^a-zA-Z0-9.-]+#-#g; s#^-+##; s#-+$##')
        if [ -z "$name" ]; then
            name="default"
        fi
    fi

    # Quick connectivity check before persisting.
    WPMCP_ACTIVE_USER="$user"
    WPMCP_ACTIVE_PASS="$pass"
    # Keep the application password out of child environments; the probe
    # sends it through curl's config-on-STDIN path.
    export -n WPMCP_ACTIVE_PASS 2>/dev/null || true
    export WPMCP_ACTIVE_USER
    WPMCP_ACTIVE_SITE="$name"
    WPMCP_ACTIVE_ORIGIN="$origin"
    export WPMCP_ACTIVE_SITE WPMCP_ACTIVE_ORIGIN

    local probe_url="$url/wp-json/wp/v2/users/me"
    local probe_raw probe_rc=0
    probe_raw=$(wpmcp_http_get "$probe_url") || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
        wpmcp_error_print "network_error" "$WPMCP_ERROR_NETWORK" \
            "Failed to reach $probe_url (curl exit $probe_rc)"
    fi
    wpmcp_http_split "$probe_raw"
    if [ "${WPMCP_HTTP_STATUS:-000}" -ge 400 ]; then
        wpmcp_error_print "auth_denied" "$WPMCP_ERROR_AUTH" \
            "WordPress rejected the credentials (HTTP $WPMCP_HTTP_STATUS)"
    fi

    # Persist credentials.
    wpmcp_auth_save "$name" "$user" "$pass"

    # Upsert the site profile.
    local profile_json
    profile_json=$(jq -nc \
        --arg name "$name" \
        --arg url "$url" \
        --arg origin "$origin" \
        --arg user "$user" \
        '{name:$name,siteUrl:$url,origin:$origin,defaultUser:$user,createdAt:now|todate}')
    wpmcp_config_upsert_profile "$name" "$profile_json"

    if [ "$WPMCP_JSON" = "1" ]; then
        jq -nc \
            --arg name "$name" \
            --arg url "$url" \
            --arg origin "$origin" \
            '{ok:true,data:{name:$name,siteUrl:$url,origin:$origin},meta:{}}'
    else
        echo "Logged in to $url as $user. Profile name: $name"
    fi
}

wpmcp_auth_status() {
    # No site selection is required. Status is informative even when
    # multiple profiles exist; we report on every saved profile by
    # default, and narrow to --site <name> / WPMCP_SITE if requested.

    wpmcp_paths_init
    local config
    config=$(wpmcp_config_load)

    # WPMCP_SITE comes from --site <name> / WPMCP_SITE env (set by main).
    # WPMCP_ACTIVE_SITE comes from a previous wpmcp_config_resolve_site
    # call. Either is fine; --site takes priority.
    local target="${WPMCP_SITE:-${WPMCP_ACTIVE_SITE:-}}"
    local entries
    if [ -n "$target" ]; then
        entries=$(echo "$config" | jq -c --arg n "$target" '
            if .profiles[$n] then [{site:$n, profile:.profiles[$n]}]
            else [] end')
        if [ "$entries" = "[]" ]; then
            wpmcp_error_site_not_found "$target" "$(echo "$config" | jq -c '[.profiles | keys[]]')"
        fi
    else
        entries=$(echo "$config" | jq -c '[.profiles | to_entries[] | {site:.key, profile:.value}]')
    fi

    # Annotate each entry with credential presence and metadata.
    entries=$(echo "$entries" | jq -c '
        map(. + {
            credentialFile: ("'$WPMCP_CREDS_DIR'/" + .site + ".json"),
            credential: false,
            credentialCreatedAt: null
        } | if .credentialFile | startswith("/") then . else . end)')

    local annotated="[]"
    local site cred_path has_cred
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        site=$(echo "$entry" | jq -r '.site')
        cred_path="$WPMCP_CREDS_DIR/$site.json"
        if [ -f "$cred_path" ]; then
            has_cred=true
            annotated=$(echo "$annotated" | jq -c \
                --argjson e "$entry" \
                '. + [$e + {credential:true, credentialCreatedAt:(($e.profile.createdAt) // null)}]')
        else
            has_cred=false
            annotated=$(echo "$annotated" | jq -c --argjson e "$entry" '. + [$e + {credential:false}]')
        fi
    done < <(echo "$entries" | jq -c '.[]')

    if [ "$WPMCP_JSON" = "1" ]; then
        printf '%s' "$annotated" | jq -c '{ok:true,data:.,meta:{}}'
        return 0
    fi

    echo "wp-mcp auth status"
    echo "================="
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local s u cred_str
        s=$(echo "$entry" | jq -r '.site')
        u=$(echo "$entry" | jq -r '.profile.defaultUser // "-"')
        if [ "$(echo "$entry" | jq -r '.credential')" = "true" ]; then
            cred_str="present"
        else
            cred_str="missing"
        fi
        printf "  %-15s user=%-12s credentials=%s\n" "$s" "$u" "$cred_str"
    done < <(echo "$annotated" | jq -c '.[]')
}

wpmcp_auth_logout() {
    wpmcp_config_resolve_site
    wpmcp_auth_remove "$WPMCP_ACTIVE_SITE"
    if [ "$WPMCP_JSON" = "1" ]; then
        jq -nc --arg site "$WPMCP_ACTIVE_SITE" \
            '{ok:true,data:{site:$site,removed:true},meta:{}}'
    else
        echo "Removed credentials for $WPMCP_ACTIVE_SITE"
    fi
}

# Source: commands/code
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp code <file|-> [flags]
# Runs a local PHP script that calls WP-MCP abilities through the CLI's
# existing `run` command. The script runs on the operator's machine; it is
# not a sandbox.

wpmcp_code() {
    local script=""
    local dry_run=0
    local read_only=0
    local yes=0
    local max_calls=100
    local timeout=120
    local verbose=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            --read-only)
                read_only=1
                shift
                ;;
            --yes|-y)
                yes=1
                shift
                ;;
            --max-calls)
                if [ "$#" -lt 2 ]; then
                    wpmcp_error_usage "--max-calls requires a value"
                fi
                max_calls="$2"
                shift 2
                ;;
            --max-calls=*)
                max_calls="${1#--max-calls=}"
                shift
                ;;
            --timeout)
                if [ "$#" -lt 2 ]; then
                    wpmcp_error_usage "--timeout requires a value"
                fi
                timeout="$2"
                shift 2
                ;;
            --timeout=*)
                timeout="${1#--timeout=}"
                shift
                ;;
            --verbose)
                verbose=1
                shift
                ;;
            --help|-h)
                wpmcp_display_command_help code
                return 0
                ;;
            --)
                shift
                if [ "$#" -gt 0 ]; then
                    script="$1"
                    shift
                fi
                if [ "$#" -gt 0 ]; then
                    wpmcp_error_usage "Unexpected argument: $1"
                fi
                ;;
            -)
                if [ -z "$script" ]; then
                    script="$1"
                    shift
                else
                    wpmcp_error_usage "Unexpected argument: $1"
                fi
                ;;
            -*)
                wpmcp_error_usage "Unknown code flag: $1"
                ;;
            *)
                if [ -z "$script" ]; then
                    script="$1"
                    shift
                else
                    wpmcp_error_usage "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    if [ -z "$script" ]; then
        wpmcp_error_usage "Usage: wp-mcp code <file|-> [flags]"
    fi
    case "$max_calls" in
        ''|*[!0-9]*)
            wpmcp_error_usage "--max-calls must be an integer between 1 and 1000"
            ;;
    esac
    max_calls=$((10#$max_calls))
    if [ "$max_calls" -lt 1 ] || [ "$max_calls" -gt 1000 ]; then
        wpmcp_error_usage "--max-calls must be between 1 and 1000"
    fi
    case "$timeout" in
        ''|*[!0-9]*)
            wpmcp_error_usage "--timeout must be an integer between 1 and 3600"
            ;;
    esac
    timeout=$((10#$timeout))
    if [ "$timeout" -lt 1 ] || [ "$timeout" -gt 3600 ]; then
        wpmcp_error_usage "--timeout must be between 1 and 3600"
    fi
    if [ "$dry_run" = "1" ] && [ "$read_only" = "1" ]; then
        wpmcp_error_usage "--dry-run and --read-only are mutually exclusive"
    fi
    if [ "$yes" = "1" ] && { [ "$dry_run" = "1" ] || [ "$read_only" = "1" ]; }; then
        wpmcp_error_usage "--yes cannot be combined with --dry-run or --read-only"
    fi

    wpmcp_paths_init
    wpmcp_config_resolve_site
    if ! wpmcp_auth_check "$WPMCP_ACTIVE_SITE"; then
        wpmcp_error_auth_required "$WPMCP_ACTIVE_SITE"
    fi

    local site_url
    site_url=$(wpmcp_config_get_profile "$WPMCP_ACTIVE_SITE" | jq -r '.siteUrl // empty')
    if [ -z "$site_url" ]; then
        wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
            "Active site has no siteUrl: $WPMCP_ACTIVE_SITE"
    fi

    wpmcp_code_require_php
    wpmcp_code_extract_bootstrap
    local bootstrap
    bootstrap=$(wpmcp_code_bootstrap_path)

    local work_dir
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wpmcp-code.XXXXXX") || \
        wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
            "Could not create a temporary directory."
    chmod 700 "$work_dir"
    WPMCP_CODE_WORK_DIR="$work_dir"
    trap wpmcp_code_cleanup EXIT
    trap 'wpmcp_code_cleanup; exit 130' INT
    trap 'wpmcp_code_cleanup; exit 143' TERM

    local script_path
    if [ "$script" = "-" ]; then
        script_path="$work_dir/stdin.php"
        if ! cat > "$script_path"; then
            wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                "Could not read the script from STDIN."
        fi
        chmod 600 "$script_path"
    else
        if [ ! -f "$script" ] || [ ! -r "$script" ]; then
            wpmcp_error_usage "Script not found or not readable: $script"
        fi
        script_path="$script"
    fi

    local out_file="$work_dir/stdout"
    local err_file="$work_dir/stderr"
    local log_file="$work_dir/calls.jsonl"
    local timeout_flag="$work_dir/timed-out"
    : > "$out_file"
    : > "$err_file"
    : > "$log_file"
    chmod 600 "$out_file" "$err_file" "$log_file"

    local sha
    sha=$(wpmcp_code_sha256 "$script_path")

    if [ "$WPMCP_JSON" != "1" ] && [ "$WPMCP_QUIET" != "1" ]; then
        local display="$script"
        [ "$script" = "-" ] && display="<stdin>"
        printf 'Script: %s (sha256 %s)\n' "$display" "$sha" >&2
    fi

    export WPMCP_CODE_CLI="${WPMCP_CODE_CLI:-$(wpmcp_code_cli_path)}"
    export WPMCP_CODE_SITE="$WPMCP_ACTIVE_SITE"
    export WPMCP_CODE_SITE_URL="$site_url"
    export WPMCP_CODE_ORIGIN="${WPMCP_ACTIVE_ORIGIN:-}"
    export WPMCP_CODE_LOG="$log_file"
    export WPMCP_CODE_DRY_RUN="$dry_run"
    export WPMCP_CODE_READ_ONLY="$read_only"
    export WPMCP_CODE_ALLOW_DESTRUCTIVE="$yes"
    export WPMCP_CODE_MAX_CALLS="$max_calls"
    export WPMCP_CODE_TIMEOUT="$timeout"
    export WPMCP_CODE_VERBOSE="$verbose"
    if [ -n "${WPMCP_HTTP_TIMEOUT:-}" ]; then
        export WPMCP_HTTP_TIMEOUT
    fi

    local status=0
    wpmcp_code_run_php "$script_path" "$bootstrap" "$out_file" "$err_file" "$timeout" "$timeout_flag" || status=$?

    local timed_out=0
    [ -f "$timeout_flag" ] && timed_out=1

    local entries
    entries=$(wpmcp_code_read_log "$log_file")

    wpmcp_code_render \
        "$entries" "$out_file" "$err_file" "$status" "$timed_out" \
        "$dry_run" "$read_only" "$timeout" "$WPMCP_ACTIVE_SITE" \
        "${WPMCP_ACTIVE_ORIGIN:-}" "$sha"
}

# Source: commands/describe
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp describe <ability>
# Prints the ability record including input_schema, output_schema, and
# annotations (readonly, destructive, idempotent).

wpmcp_describe() {
    wpmcp_auth_require

    local ability=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h) wpmcp_display_command_help describe; return 0 ;;
            *)
                if [ -z "$ability" ]; then ability="$1"; shift
                else wpmcp_error_usage "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    if [ -z "$ability" ]; then
        wpmcp_error_usage "Usage: wp-mcp describe <ability>"
    fi

    local segments
    IFS='/' read -ra segments <<< "$ability"
    local encoded=""
    local i
    for i in "${!segments[@]}"; do
        local s="${segments[$i]}"
        if [ $i -gt 0 ]; then encoded="${encoded}/"; fi
        encoded="${encoded}$(wpmcp_url_path_encode "$s")"
    done

    local rest_url
    rest_url=$(wpmcp_rest_url_for "/wp-abilities/v1/abilities/${encoded}")

    local raw rc=0
    raw=$(wpmcp_http_get "$rest_url") || rc=$?
    if [ $rc -ne 0 ]; then
        wpmcp_error_print "network_error" "$WPMCP_ERROR_NETWORK" \
            "Failed to fetch $rest_url (curl exit $rc)"
    fi
    wpmcp_http_split "$raw"
    if [ "${WPMCP_HTTP_STATUS:-000}" -ge 400 ]; then
        wpmcp_http_classify_wp_error "$WPMCP_HTTP_BODY"
    fi

    local body
    body=$(printf '%s' "$WPMCP_HTTP_BODY" | jq -c .)

    if [ "$WPMCP_JSON" = "1" ]; then
        printf '%s' "$body" | jq -c \
            --arg site "$WPMCP_ACTIVE_SITE" \
            '{ok:true,data:.,meta:{site:$site}}'
        return 0
    fi

    if wpmcp_command_exists gum && wpmcp_has_tty; then
        printf '%s' "$body" | gum pager --border rounded
    else
        printf '%s' "$body" | jq .
    fi
}

# Source: commands/discover
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp discover
# Lists every ability registered on the active site that exposes
# show_in_rest=true via the WordPress core abilities REST namespace.

wpmcp_discover() {
    wpmcp_auth_require

    local rest_url
    rest_url=$(wpmcp_rest_url_for "/wp-abilities/v1/abilities")

    local page=1
    local all_abilities="[]"
    while :; do
        local url="${rest_url}?per_page=100&page=${page}"
        local raw rc=0
        raw=$(wpmcp_http_get "$url") || rc=$?
        if [ $rc -ne 0 ]; then
            wpmcp_error_print "network_error" "$WPMCP_ERROR_NETWORK" \
                "Failed to fetch $url (curl exit $rc)"
        fi
        wpmcp_http_split "$raw"
        if [ "${WPMCP_HTTP_STATUS:-000}" -ge 400 ]; then
            wpmcp_http_classify_wp_error "$WPMCP_HTTP_BODY"
        fi
        local body
        body=$(printf '%s' "$WPMCP_HTTP_BODY" | jq -c '. // []')
        local n
        n=$(printf '%s' "$body" | jq 'length')
        if [ "$n" -eq 0 ]; then
            break
        fi
        all_abilities=$(printf '%s\n%s' "$all_abilities" "$body" | jq -sc '.[0] + .[1]')
        if [ "$n" -lt 100 ]; then
            break
        fi
        page=$((page + 1))
        if [ "$page" -gt 1000 ]; then
            wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                "Aborting pagination after 1000 pages"
        fi
    done

    if [ "$WPMCP_JSON" = "1" ]; then
        printf '%s' "$all_abilities" | jq -c \
            --arg site "$WPMCP_ACTIVE_SITE" \
            --arg origin "$WPMCP_ACTIVE_ORIGIN" \
            '{ok:true,data:{abilities:.},meta:{site:$site,origin:$origin,count:(.|length)}}'
        return 0
    fi

    if wpmcp_has_tty; then
        local labels
        labels=$(printf '%s' "$all_abilities" | jq -r '.[] | [.name, (.label // ""), (.category // ""), (.meta.annotations.readonly // false|tostring), (.meta.annotations.destructive // false|tostring)] | @tsv')
        # gum's --columns supplies the header; stdin contains ONLY rows.
        wpmcp_ui_table "$labels" "Name,Label,Category,Readonly,Destructive"
    else
        printf '%s' "$all_abilities" | jq -r '.[] | "\(.name)\t\(.label // "")\t\(.category // "")"'
    fi
}

# Source: commands/doctor
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp doctor [--offline]
# Ordered health checks against the CLI environment and the target site.

wpmcp_doctor() {
    local offline=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --offline) offline=1; shift ;;
            --help|-h) wpmcp_display_command_help doctor; return 0 ;;
            *) wpmcp_error_usage "Unknown doctor flag: $1" ;;
        esac
    done

    local results=()
    local failed=0

    check() {
        local name="$1"; shift
        local ok=0
        local detail=""
        if "$@"; then ok=1; else ok=0; fi
        if [ $ok -eq 1 ]; then
            results+=("OK|$name|$detail")
        else
            results+=("FAIL|$name|$detail")
            failed=$((failed + 1))
        fi
    }

    check "bash >= 4"            wpmcp_check_bash_version
    check "jq available"         wpmcp_check_jq
    check "curl available"       wpmcp_check_curl
    check "gum available"        wpmcp_check_gum
    check "config dir writable"  wpmcp_check_config_dir

    # PHP is only needed by `wp-mcp code`; a missing runtime is a warning,
    # not a failure for users who only use run/discover/describe.
    if wpmcp_check_php; then
        results+=("OK|php available (code)|")
    else
        results+=("WARN|php available (code)|PHP >= 8.0 with proc_open is required for wp-mcp code")
    fi

    if [ "$offline" = "0" ]; then
        check "active site resolvable" wpmcp_check_active_site
        check "credentials present"    wpmcp_check_credentials
        check "site reachable"         wpmcp_check_site_reachable
    fi

    if [ "$WPMCP_JSON" = "1" ]; then
        local arr="[]"
        local r
        for r in "${results[@]}"; do
            IFS='|' read -r status name detail <<< "$r"
            arr=$(echo "$arr" | jq -c \
                --arg status "$status" \
                --arg name "$name" \
                --arg detail "$detail" \
                '. + [{status:$status,name:$name,detail:$detail}]')
        done
        jq -nc \
            --argjson checks "$arr" \
            --argjson ok "$([[ $failed -eq 0 ]] && echo true || echo false)" \
            '{ok:$ok,data:{checks:$checks,failed:('$failed')},meta:{}}'
    else
        echo "wp-mcp doctor"
        echo "============"
        local r
        for r in "${results[@]}"; do
            IFS='|' read -r status name detail <<< "$r"
            case "$status" in
                OK)   echo "  OK    $name" ;;
                WARN) echo "  WARN  $name" ;;
                *)    echo "  FAIL  $name" ;;
            esac
        done
    fi

    return $failed
}

wpmcp_check_bash_version() {
    [ "${BASH_VERSINFO[0]}" -ge 4 ]
}

wpmcp_check_jq() {
    wpmcp_command_exists jq
}

wpmcp_check_curl() {
    wpmcp_command_exists curl
}

wpmcp_check_gum() {
    wpmcp_command_exists gum
}

wpmcp_check_config_dir() {
    wpmcp_paths_ensure
    [ -d "$WPMCP_HOME" ] && [ -w "$WPMCP_HOME" ]
}

wpmcp_check_php() {
    wpmcp_command_exists php || return 1
    php -r 'exit(PHP_VERSION_ID >= 80000 ? 0 : 1);' >/dev/null 2>&1 || return 1
    php -r 'exit(function_exists("proc_open") ? 0 : 1);' >/dev/null 2>&1 || return 1
    return 0
}

wpmcp_check_active_site() {
    # Tolerates "site_required" because that means no profiles yet.
    if [ -z "${WPMCP_ACTIVE_SITE:-}" ]; then
        wpmcp_config_resolve_site 2>/dev/null
    fi
    [ -n "${WPMCP_ACTIVE_SITE:-}" ]
}

wpmcp_check_credentials() {
    [ -n "${WPMCP_ACTIVE_SITE:-}" ] && wpmcp_auth_check "$WPMCP_ACTIVE_SITE"
}

wpmcp_check_site_reachable() {
    local site_url
    site_url=$(wpmcp_config_get_profile "${WPMCP_ACTIVE_SITE:-}" | jq -r '.siteUrl // empty')
    if [ -z "$site_url" ]; then return 1; fi
    local url="${site_url%/}/wp-json/"
    local raw
    raw=$(curl -fsSL --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
    [ "${raw:-000}" -lt 500 ]
}

# Source: commands/run
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp run <ability> --input <json|@file|-> [--yes]
# Executes an ability via POST /wp-json/wp-mcp/v1/abilities/<ns>/<name>/run

wpmcp_run() {
    wpmcp_auth_require

    local ability=""
    local input=""
    local input_source=""  # "inline" | "file" | "stdin"
    local input_file=""
    local yes=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --input|-i)
                input="$2"
                shift 2
                ;;
            --input=*)
                input="${1#--input=}"
                shift
                ;;
            --yes|-y)
                yes=1
                shift
                ;;
            --help|-h)
                wpmcp_display_command_help run
                return 0
                ;;
            *)
                if [ -z "$ability" ]; then
                    ability="$1"
                    shift
                else
                    wpmcp_error_usage "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    if [ -z "$ability" ]; then
        wpmcp_error_usage "Usage: wp-mcp run <ability> --input <json|@file|->"
    fi

    # Parse the input specifier.
    local input_json="null"
    if [ -n "$input" ]; then
        case "$input" in
            @*)
                local f="${input#@}"
                if [ ! -f "$f" ]; then
                    wpmcp_error_usage "Input file not found: $f"
                fi
                input_json=$(cat "$f")
                ;;
            -)
                input_json=$(cat)
                ;;
            *)
                input_json="$input"
                ;;
        esac
    fi

    # Validate JSON before posting. `jq -e` treats valid null/false as
    # failures, so use a plain parse check instead.
    if [ "$input_json" != "null" ] && ! printf '%s' "$input_json" | jq -c . >/dev/null 2>&1; then
        wpmcp_error_print "usage_error" "$WPMCP_ERROR_USAGE" \
            "--input is not valid JSON"
    fi

    # Build the run URL.
    local segments
    IFS='/' read -ra segments <<< "$ability"
    local encoded=""
    local i
    for i in "${!segments[@]}"; do
        local s="${segments[$i]}"
        if [ $i -gt 0 ]; then encoded="${encoded}/"; fi
        encoded="${encoded}$(wpmcp_url_path_encode "$s")"
    done
    local rest_url
    rest_url=$(wpmcp_rest_url_for "/wp-mcp/v1/abilities/${encoded}/run")

    # Optional destructive confirmation.
    if [ "$yes" != "1" ] && [ "$WPMCP_JSON" != "1" ]; then
        local describe_url
        describe_url=$(wpmcp_rest_url_for "/wp-abilities/v1/abilities/${encoded}")
        local describe_raw describe_rc=0
        describe_raw=$(wpmcp_http_get "$describe_url") || describe_rc=$?
        if [ "$describe_rc" -eq 0 ]; then
            wpmcp_http_split "$describe_raw"
            local destructive
            destructive=$(printf '%s' "$WPMCP_HTTP_BODY" | jq -r '.meta.annotations.destructive // false')
            if [ "$destructive" = "true" ]; then
                if ! wpmcp_ui_confirm "Ability '$ability' is marked destructive. Continue?"; then
                    echo "Cancelled."
                    return 0
                fi
            fi
        fi
    fi

    # POST the request. Build the body on stdin so large inputs never hit
    # ARG_MAX and do not appear in jq/curl process arguments.
    local body
    body=$(printf '%s' "$input_json" | jq -c '{input: .}')

    local raw rc=0
    raw=$(wpmcp_http_post_json "$rest_url" "$body") || rc=$?
    if [ "$rc" -ne 0 ]; then
        wpmcp_error_print "network_error" "$WPMCP_ERROR_NETWORK" \
            "Failed to POST $rest_url (curl exit $rc)"
    fi
    wpmcp_http_split "$raw"
    if [ "${WPMCP_HTTP_STATUS:-000}" -ge 400 ]; then
        wpmcp_http_classify_wp_error "$WPMCP_HTTP_BODY"
    fi

    # Normalize the body through stdin. `resp_norm` is empty for invalid
    # JSON; an empty HTTP body is treated as null.
    local resp_body="$WPMCP_HTTP_BODY"
    local resp_norm=""
    resp_norm=$(printf '%s' "$resp_body" | jq -c . 2>/dev/null) || true
    local resp_is_json=0
    if [ -n "$resp_norm" ]; then
        resp_body="$resp_norm"
        resp_is_json=1
    elif [ -z "$resp_body" ]; then
        resp_body="null"
        resp_is_json=1
    fi

    if [ "$WPMCP_JSON" = "1" ]; then
        if [ "$resp_is_json" = "1" ]; then
            printf '%s' "$resp_body" | jq -c \
                --arg site "$WPMCP_ACTIVE_SITE" \
                --arg status "${WPMCP_HTTP_STATUS:-200}" \
                '{ok:true,data:.,meta:{site:$site,http_status:($status|tonumber)}}'
        else
            printf '%s' "$resp_body" | jq -Rsc \
                --arg site "$WPMCP_ACTIVE_SITE" \
                --arg status "${WPMCP_HTTP_STATUS:-200}" \
                '{ok:true,data:.,meta:{site:$site,http_status:($status|tonumber)}}'
        fi
    else
        if [ "$resp_is_json" = "1" ]; then
            printf '%s' "$resp_body" | jq .
        else
            printf '%s\n' "$resp_body"
        fi
    fi
}

# Source: commands/sites
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp sites list | remove | rename

wpmcp_sites() {
    local action="${1:-list}"
    [ "$#" -gt 0 ] && shift

    case "$action" in
        list|ls)
            wpmcp_sites_list "$@"
            ;;
        remove|rm)
            wpmcp_sites_remove "$@"
            ;;
        rename|mv)
            wpmcp_sites_rename "$@"
            ;;
        help|--help|-h)
            wpmcp_display_command_help sites
            ;;
        *)
            wpmcp_error_usage "Unknown sites action: $action"
            ;;
    esac
}

wpmcp_sites_list() {
    local config
    config=$(wpmcp_config_load)

    if [ "$WPMCP_JSON" = "1" ]; then
        echo "$config" | jq -c '{ok:true,data:[.profiles | to_entries[] | {name:.key,siteUrl:.value.siteUrl,origin:.value.origin,defaultUser:.value.defaultUser}],meta:{}}'
        return 0
    fi

    local names
    names=$(echo "$config" | jq -r '.profiles | keys[]')
    if [ -z "$names" ]; then
        echo "No site profiles configured. Run: wp-mcp auth login <url>"
        return 0
    fi

    if wpmcp_has_tty; then
        # gum's --columns provides the column headers; the data on
        # stdin must contain ONLY data rows, not a header line.
        local tsv=""
        while IFS= read -r n; do
            [ -z "$n" ] && continue
            local url user
            url=$(echo "$config" | jq -r --arg n "$n" '.profiles[$n].siteUrl // ""')
            user=$(echo "$config" | jq -r --arg n "$n" '.profiles[$n].defaultUser // ""')
            if [ -z "$tsv" ]; then
                tsv+="${n}"$'\t'"${url}"$'\t'"${user}"
            else
                tsv+=$'\n'"${n}"$'\t'"${url}"$'\t'"${user}"
            fi
        done <<< "$names"
        wpmcp_ui_table "$tsv" "Name,URL,User"
    else
        while IFS= read -r n; do
            [ -z "$n" ] && continue
            local url user
            url=$(echo "$config" | jq -r --arg n "$n" '.profiles[$n].siteUrl // ""')
            user=$(echo "$config" | jq -r --arg n "$n" '.profiles[$n].defaultUser // ""')
            printf '%s\t%s\t%s\n' "$n" "$url" "$user"
        done <<< "$names"
    fi
}

wpmcp_sites_remove() {
    local name=""
    local yes=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes|-y) yes=1; shift ;;
            --help|-h) wpmcp_display_command_help sites; return 0 ;;
            *)
                if [ -z "$name" ]; then name="$1"; shift
                else wpmcp_error_usage "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    if [ -z "$name" ]; then
        wpmcp_error_usage "Usage: wp-mcp sites remove <name> [--yes]"
    fi

    local exists
    exists=$(wpmcp_config_load | jq -r --arg n "$name" '(.profiles[$n] // null) | type')
    if [ "$exists" != "object" ]; then
        wpmcp_error_usage "Site profile '$name' not found."
    fi

    if [ "$yes" != "1" ] && [ "$WPMCP_JSON" != "1" ]; then
        if ! wpmcp_ui_confirm "Remove profile '$name' and its credentials?"; then
            echo "Cancelled."
            return 0
        fi
    fi

    wpmcp_config_remove_profile "$name" >/dev/null
    wpmcp_auth_remove "$name"

    if [ "$WPMCP_JSON" = "1" ]; then
        jq -nc --arg n "$name" '{ok:true,data:{name:$n,removed:true},meta:{}}'
    else
        echo "Removed site profile '$name'"
    fi
}

wpmcp_sites_rename() {
    local old_name="" new_name=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h) wpmcp_display_command_help sites; return 0 ;;
            *)
                if [ -z "$old_name" ]; then old_name="$1"; shift
                elif [ -z "$new_name" ]; then new_name="$1"; shift
                else wpmcp_error_usage "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    if [ -z "$old_name" ] || [ -z "$new_name" ]; then
        wpmcp_error_usage "Usage: wp-mcp sites rename <name> <new-name>"
    fi

    local config
    config=$(wpmcp_config_load)
    local exists
    exists=$(echo "$config" | jq -r --arg n "$old_name" '(.profiles[$n] // null) | type')
    if [ "$exists" != "object" ]; then
        wpmcp_error_usage "Site profile '$old_name' not found."
    fi

    config=$(echo "$config" | jq \
        --arg old "$old_name" --arg new "$new_name" \
        '.profiles[$new] = .profiles[$old] | del(.profiles[$old])')
    echo "$config" | wpmcp_config_save_stdin

    # Migrate credentials file.
    local old_cred new_cred
    old_cred=$(wpmcp_auth_cred_path "$old_name")
    new_cred=$(wpmcp_auth_cred_path "$new_name")
    if [ -f "$old_cred" ]; then
        mv -f "$old_cred" "$new_cred"
    fi

    if [ "$WPMCP_JSON" = "1" ]; then
        jq -nc --arg old "$old_name" --arg new "$new_name" \
            '{ok:true,data:{old:$old,new:$new},meta:{}}'
    else
        echo "Renamed $old_name → $new_name"
    fi
}

# Source: commands/skill
# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp skill install [codex|claude-code|opencode|hermes|pi|global|all]

wpmcp_skill() {
    local action="${1:-help}"
    [ "$#" -gt 0 ] && shift

    case "$action" in
        install)
            wpmcp_skill_install "$@"
            ;;
        help|--help|-h)
            wpmcp_display_command_help skill
            ;;
        *)
            wpmcp_error_usage "Unknown skill action: $action"
            ;;
    esac
}

wpmcp_skill_install() {
    local target="${1:-all}"

    # Resolve the path to the bundled SKILL.md.
    local script_dir=""
    local source="${BASH_SOURCE[0]:-}"
    if [ -n "$source" ]; then
        script_dir="$(cd "$(dirname "$source")/.." && pwd)"
    fi

    local skill_source=""
    local skill_source_is_temp=0
    if [ -n "$script_dir" ] && [ -f "$script_dir/skills/wp-mcp/SKILL.md" ]; then
        skill_source="$script_dir/skills/wp-mcp/SKILL.md"
    else
        # Fallback: download from GitHub.
        skill_source=$(mktemp)
        skill_source_is_temp=1
        if ! curl -fsSL "https://raw.githubusercontent.com/plakio/wp-mcp-cli/main/skills/wp-mcp/SKILL.md" -o "$skill_source"; then
            rm -f "$skill_source"
            wpmcp_error_print "network_error" "$WPMCP_ERROR_NETWORK" \
                "Failed to fetch SKILL.md from GitHub."
        fi
    fi

    case "$target" in
        codex)         wpmcp_skill_install_to "$HOME/.codex/skills/wp-mcp/SKILL.md" "$skill_source" ;;
        claude-code)   wpmcp_skill_install_to "$HOME/.claude/skills/wp-mcp/SKILL.md" "$skill_source" ;;
        opencode)      wpmcp_skill_install_to "$HOME/.config/opencode/skills/wp-mcp/SKILL.md" "$skill_source" ;;
        hermes)        wpmcp_skill_install_to "$HOME/.hermes/skills/wp-mcp/SKILL.md" "$skill_source" ;;
        pi)            wpmcp_skill_install_to "$HOME/.pi/skills/wp-mcp/SKILL.md" "$skill_source" ;;
        global)        wpmcp_skill_install_to "$HOME/.agents/skills/wp-mcp/SKILL.md" "$skill_source" ;;
        all)
            wpmcp_skill_install_to "$HOME/.codex/skills/wp-mcp/SKILL.md" "$skill_source"
            wpmcp_skill_install_to "$HOME/.claude/skills/wp-mcp/SKILL.md" "$skill_source"
            wpmcp_skill_install_to "$HOME/.config/opencode/skills/wp-mcp/SKILL.md" "$skill_source"
            wpmcp_skill_install_to "$HOME/.hermes/skills/wp-mcp/SKILL.md" "$skill_source"
            wpmcp_skill_install_to "$HOME/.pi/skills/wp-mcp/SKILL.md" "$skill_source"
            ;;
        *)
            wpmcp_error_usage "Unknown skill target: $target (expected: codex|claude-code|opencode|hermes|pi|global|all)"
            ;;
    esac

    # Clean up the temp file if we created one. Avoids a RETURN trap so
    # `set -u` does not flag the unset local at function exit.
    if [ "$skill_source_is_temp" = "1" ]; then
        rm -f "$skill_source"
    fi
}

wpmcp_skill_install_to() {
    local dest="$1"
    local source="$2"
    local dest_dir
    dest_dir=$(dirname "$dest")
    mkdir -p "$dest_dir"
    cp "$source" "$dest"
    echo "Installed wp-mcp skill to $dest"
}

# Pass all script arguments to the main function.
main "$@"
