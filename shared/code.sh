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
