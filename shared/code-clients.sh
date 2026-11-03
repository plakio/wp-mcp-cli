# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Thin code-mode clients for the common bridge.
# Bump this when any client below changes.
WPMCP_CODE_CLIENT_VERSION="2"

wpmcp_code_require_runtime() {
    local runtime="$1"

    case "$runtime" in
        php)
            wpmcp_command_exists php || wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                "PHP is required for --runtime php."
            if ! php -r 'exit(PHP_VERSION_ID >= 80000 ? 0 : 1);' >/dev/null 2>&1; then
                wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                    "PHP >= 8.0 is required for --runtime php."
            fi
            if ! php -r 'exit(function_exists("proc_open") ? 0 : 1);' >/dev/null 2>&1; then
                wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                    "PHP proc_open() is disabled; --runtime php requires it."
            fi
            ;;
        python)
            wpmcp_command_exists python3 || wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                "Python 3.8+ is required for --runtime python."
            if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
                wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                    "Python 3.8+ is required for --runtime python."
            fi
            ;;
        node)
            wpmcp_command_exists node || wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                "Node.js 18+ is required for --runtime node."
            if ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' >/dev/null 2>&1; then
                wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                    "Node.js 18+ is required for --runtime node."
            fi
            ;;
        *)
            wpmcp_error_usage "Unknown runtime: $runtime"
            ;;
    esac
}

wpmcp_code_validate_client() {
    local runtime="$1"
    local base="$2"

    case "$runtime" in
        php)
            php -l "$base/php/wpmcp-code.php" >/dev/null 2>&1 || \
                wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                    "The PHP code client failed syntax validation."
            ;;
        python)
            if ! python3 - "$base/python/wpmcp_code.py" "$base/python/runner.py" <<'WPMCP_CODE_PY_CHECK'
import sys
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        compile(handle.read(), path, "exec")
WPMCP_CODE_PY_CHECK
            then
                wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                    "The Python code client failed syntax validation."
            fi
            ;;
        node)
            node --check "$base/node/wpmcp-code.cjs" >/dev/null 2>&1 || \
                wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
                    "The Node code client failed syntax validation."
            ;;
    esac
}

wpmcp_code_extract_clients() {
    local runtime="$1"
    local base="$WPMCP_HOME/lib/code"
    local version_file="$base/version"
    local php_file="$base/php/wpmcp-code.php"
    local py_file="$base/python/wpmcp_code.py"
    local py_runner="$base/python/runner.py"
    local node_file="$base/node/wpmcp-code.cjs"

    mkdir -p "$base/php" "$base/python" "$base/node" || \
        wpmcp_error_print "internal_error" "$WPMCP_ERROR_INTERNAL" \
            "Cannot create $base."
    chmod 700 "$base" "$base/php" "$base/python" "$base/node" 2>/dev/null || true

    if [ -f "$version_file" ] &&
        [ "$(cat "$version_file" 2>/dev/null)" = "$WPMCP_CODE_CLIENT_VERSION" ] &&
        [ -f "$php_file" ] && [ -f "$py_file" ] && [ -f "$py_runner" ] && [ -f "$node_file" ]; then
        wpmcp_code_validate_client "$runtime" "$base"
        return 0
    fi

    local tmp

    tmp="$php_file.tmp.$$"
    cat > "$tmp" <<'WPMCP_CODE_PHP_CLIENT'
<?php
// wp-mcp code PHP client (AGPL-3.0-or-later)
// Thin client: modes, budgets, annotations and logging live in the common bridge.

if (defined('WPMCP_CODE_CLIENT')) {
    return;
}
define('WPMCP_CODE_CLIENT', '2');

final class WPMCP_Code_Error extends RuntimeException
{
    public string $errorCode;
    public int $exitCode;
    public ?string $remoteCode;
    public array $details;

    public function __construct(
        string $errorCode,
        string $message,
        int $exitCode = 5,
        ?string $remoteCode = null,
        array $details = []
    ) {
        parent::__construct($message);
        $this->errorCode = $errorCode;
        $this->exitCode = $exitCode;
        $this->remoteCode = $remoteCode;
        $this->details = $details;
    }
}

function wp_mcp_code_env(string $key, string $default = ''): string
{
    $value = getenv($key);
    return $value === false ? $default : $value;
}

function wp_mcp_code_log_event(string $type, array $data = []): void
{
    $log = wp_mcp_code_env('WPMCP_CODE_LOG');
    if ($log === '') {
        return;
    }
    $event = ['type' => $type] + $data;
    $line = json_encode($event, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    if ($line === false) {
        return;
    }
    @file_put_contents($log, $line . "\n", FILE_APPEND | LOCK_EX);
}

function wp_mcp_code_bridge(array $request): mixed
{
    $cli = wp_mcp_code_env('WPMCP_CODE_BRIDGE_CLI');
    if ($cli === '' || !is_file($cli)) {
        throw new WPMCP_Code_Error('internal_error', 'The wp-mcp CLI is missing.', 1);
    }

    $out = tempnam(sys_get_temp_dir(), 'wpmcp-bridge-out-');
    $err = tempnam(sys_get_temp_dir(), 'wpmcp-bridge-err-');
    if ($out === false || $err === false) {
        if (is_string($out)) {
            @unlink($out);
        }
        if (is_string($err)) {
            @unlink($err);
        }
        throw new WPMCP_Code_Error('internal_error', 'Could not create bridge temporary files.', 1);
    }
    chmod($out, 0600);
    chmod($err, 0600);

    $cmd = is_executable($cli) ? [$cli, '__code-bridge'] : ['bash', $cli, '__code-bridge'];
    $spec = [0 => ['pipe', 'r'], 1 => ['file', $out, 'w'], 2 => ['file', $err, 'w']];
    $proc = proc_open($cmd, $spec, $pipes, null, null);
    if (!is_resource($proc)) {
        @unlink($out);
        @unlink($err);
        throw new WPMCP_Code_Error('internal_error', 'Could not start the code bridge.', 1);
    }

    $payload = json_encode($request, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    if ($payload === false) {
        fclose($pipes[0]);
        @proc_terminate($proc);
        @unlink($out);
        @unlink($err);
        throw new WPMCP_Code_Error('script_error', 'The bridge request is not JSON-encodable.', 5);
    }
    fwrite($pipes[0], $payload);
    fclose($pipes[0]);
    $exit = proc_close($proc);
    $stdout = (string) file_get_contents($out);
    $stderr = (string) file_get_contents($err);
    @unlink($out);
    @unlink($err);

    $envelope = json_decode($stdout, true);
    if ($exit === 0 && is_array($envelope) && ($envelope['ok'] ?? false) === true) {
        return $envelope['data'] ?? null;
    }

    $decoded = json_decode($stderr, true);
    $error = is_array($decoded) && isset($decoded['error']) && is_array($decoded['error'])
        ? $decoded['error']
        : null;
    if ($error !== null) {
        $code = (string) ($error['code'] ?? 'script_error');
        $message = (string) ($error['message'] ?? 'The code bridge failed.');
        $exitCode = isset($error['exitCode']) ? (int) $error['exitCode'] : ($exit > 0 ? $exit : 5);
        $remote = isset($error['remoteCode']) && $error['remoteCode'] !== ''
            ? (string) $error['remoteCode']
            : null;
        $details = isset($error['details']) && is_array($error['details']) ? $error['details'] : [];
        throw new WPMCP_Code_Error($code, $message, $exitCode, $remote, $details);
    }

    throw new WPMCP_Code_Error(
        'internal_error',
        'The code bridge failed.',
        $exit > 0 ? $exit : 1,
        null,
        ['stderr' => substr($stderr, -2000)]
    );
}

function wp_mcp_call(string $ability, mixed $input = null): mixed
{
    return wp_mcp_code_bridge(['op' => 'call', 'ability' => $ability, 'input' => $input]);
}

function wp_mcp_search(string $query, int $limit = 10, ?string $cursor = null): array
{
    $request = ['op' => 'search', 'query' => $query, 'limit' => max(1, min(50, $limit))];
    if ($cursor !== null && $cursor !== '') {
        $request['cursor'] = $cursor;
    }
    $rows = wp_mcp_code_bridge($request);
    return is_array($rows) ? $rows : [];
}

function wp_mcp_discover(array $options = []): array
{
    $result = wp_mcp_code_bridge(['op' => 'discover', 'options' => $options]);
    return is_array($result) ? $result : [];
}

function wp_mcp_describe(string $ability): array
{
    $result = wp_mcp_code_bridge(['op' => 'describe', 'ability' => $ability]);
    return is_array($result) ? $result : [];
}

function wp_mcp_log(string $message): void
{
    wp_mcp_code_bridge(['op' => 'log', 'message' => $message]);
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

$GLOBALS['wpmcp_code_started_at'] = microtime(true);
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
WPMCP_CODE_PHP_CLIENT
    chmod 600 "$tmp"
    mv -f "$tmp" "$php_file"

    tmp="$py_file.tmp.$$"
    cat > "$tmp" <<'WPMCP_CODE_PYTHON_CLIENT'
"""Thin client for wp-mcp code mode.

Modes, budgets, annotations and logging live in the common bridge.
"""
import atexit
import builtins
import json
import os
import subprocess
import sys
import time

_STARTED = time.time()
_INSTALLED = False


class WPMCPCodeError(Exception):
    def __init__(self, error_code, message, exit_code=5, remote_code=None, details=None):
        super().__init__(message)
        self.error_code = error_code
        self.exit_code = int(exit_code)
        self.remote_code = remote_code
        self.details = details or {}


def _env(key, default=""):
    value = os.environ.get(key)
    return default if value is None else value


def _encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str)


def _log_event(kind, data):
    path = _env("WPMCP_CODE_LOG")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(_encode({"type": kind, **data}) + "\n")
    except OSError:
        pass


def _error_from(envelope, fallback_exit):
    error = envelope.get("error") if isinstance(envelope, dict) else None
    if not isinstance(error, dict):
        return None
    return WPMCPCodeError(
        error.get("code", "script_error"),
        error.get("message", "The code bridge failed."),
        error.get("exitCode", fallback_exit or 5),
        error.get("remoteCode") or None,
        error.get("details") or {},
    )


def _bridge(request):
    cli = _env("WPMCP_CODE_BRIDGE_CLI")
    if not cli or not os.path.isfile(cli):
        raise WPMCPCodeError("internal_error", "The wp-mcp CLI is missing.", 1)

    command = [cli, "__code-bridge"] if os.access(cli, os.X_OK) else ["bash", cli, "__code-bridge"]
    try:
        result = subprocess.run(
            command,
            input=_encode(request).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=os.environ,
        )
    except OSError as exc:
        raise WPMCPCodeError("internal_error", "Could not start the code bridge: %s" % exc, 1)

    stdout = result.stdout.decode("utf-8", "replace")
    stderr = result.stderr.decode("utf-8", "replace")

    if result.returncode == 0:
        try:
            envelope = json.loads(stdout)
        except json.JSONDecodeError:
            raise WPMCPCodeError(
                "internal_error",
                "The code bridge returned invalid JSON.",
                1,
                None,
                {"stderr": stderr[-2000:]},
            )
        if isinstance(envelope, dict) and envelope.get("ok") is True:
            return envelope.get("data")
        error = _error_from(envelope, result.returncode)
        if error is not None:
            raise error
        raise WPMCPCodeError(
            "internal_error",
            "The code bridge returned an unexpected envelope.",
            1,
            None,
            {"stderr": stderr[-2000:]},
        )

    try:
        envelope = json.loads(stderr)
    except json.JSONDecodeError:
        envelope = None
    error = _error_from(envelope, result.returncode)
    if error is not None:
        raise error
    raise WPMCPCodeError(
        "internal_error",
        "The code bridge failed.",
        result.returncode or 1,
        None,
        {"stderr": stderr[-2000:]},
    )


def wp_mcp_call(ability, input=None):
    return _bridge({"op": "call", "ability": ability, "input": input})


def wp_mcp_search(query, limit=10, cursor=None):
    request = {"op": "search", "query": query, "limit": max(1, min(50, int(limit)))}
    if cursor:
        request["cursor"] = cursor
    rows = _bridge(request)
    return rows if isinstance(rows, list) else []


def wp_mcp_discover(options=None):
    result = _bridge({"op": "discover", "options": options or {}})
    return result if isinstance(result, dict) else {}


def wp_mcp_describe(ability):
    result = _bridge({"op": "describe", "ability": ability})
    return result if isinstance(result, dict) else {}


def wp_mcp_log(message):
    _bridge({"op": "log", "message": str(message)})


def wp_mcp_is_dry_run():
    return _env("WPMCP_CODE_DRY_RUN") == "1"


def wp_mcp_is_read_only():
    return _env("WPMCP_CODE_READ_ONLY") == "1"


def wp_mcp_site():
    return {
        "name": _env("WPMCP_CODE_SITE"),
        "url": _env("WPMCP_CODE_SITE_URL"),
        "origin": _env("WPMCP_CODE_ORIGIN"),
    }


def _excepthook(exc_type, exc, traceback):
    if isinstance(exc, SystemExit):
        sys.__excepthook__(exc_type, exc, traceback)
        return
    code = getattr(exc, "error_code", "script_error")
    exit_code = getattr(exc, "exit_code", 5)
    remote = getattr(exc, "remote_code", None)
    details = getattr(exc, "details", {})
    _log_event("error", {
        "code": code,
        "message": str(exc),
        "exit_code": exit_code,
        "remote_code": remote,
        "details": details,
    })
    sys.stderr.write(str(exc) + "\n")
    sys.exit(exit_code)


def _atexit():
    _log_event("end", {"duration_ms": int((time.time() - _STARTED) * 1000)})


def install():
    global _INSTALLED
    if _INSTALLED:
        return
    _INSTALLED = True
    exports = [
        "wp_mcp_call",
        "wp_mcp_search",
        "wp_mcp_discover",
        "wp_mcp_describe",
        "wp_mcp_log",
        "wp_mcp_is_dry_run",
        "wp_mcp_is_read_only",
        "wp_mcp_site",
        "WPMCPCodeError",
    ]
    for name in exports:
        setattr(builtins, name, globals()[name])
    sys.excepthook = _excepthook
    atexit.register(_atexit)
    _log_event("start", {"started_at": _STARTED, "pid": os.getpid()})
WPMCP_CODE_PYTHON_CLIENT
    chmod 600 "$tmp"
    mv -f "$tmp" "$py_file"

    tmp="$py_runner.tmp.$$"
    cat > "$tmp" <<'WPMCP_CODE_PYTHON_RUNNER'
import os
import runpy
import sys

import wpmcp_code

wpmcp_code.install()
script = os.environ["WPMCP_CODE_SCRIPT"]
sys.argv = [script]
sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
runpy.run_path(script, run_name="__main__")
WPMCP_CODE_PYTHON_RUNNER
    chmod 600 "$tmp"
    mv -f "$tmp" "$py_runner"

    tmp="$node_file.tmp.$$"
    cat > "$tmp" <<'WPMCP_CODE_NODE_CLIENT'
"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");

const STARTED = Date.now();

class WPMCPCodeError extends Error {
    constructor(errorCode, message, exitCode = 5, remoteCode = null, details = {}) {
        super(message);
        this.name = "WPMCPCodeError";
        this.errorCode = errorCode;
        this.exitCode = Number.isInteger(exitCode) ? exitCode : 5;
        this.remoteCode = remoteCode;
        this.details = details;
    }
}

function _env(key, fallback = "") {
    const value = process.env[key];
    return value === undefined ? fallback : value;
}

function _logEvent(type, data) {
    const log = _env("WPMCP_CODE_LOG");
    if (!log) {
        return;
    }
    try {
        fs.appendFileSync(log, JSON.stringify({ type, ...data }) + "\n");
    } catch {
        // logging must not break the script
    }
}

function _errorFrom(error, fallbackExit) {
    if (!error || typeof error !== "object") {
        return null;
    }
    return new WPMCPCodeError(
        error.code || "script_error",
        error.message || "The code bridge failed.",
        Number.isInteger(error.exitCode) ? error.exitCode : (fallbackExit || 5),
        error.remoteCode || null,
        error.details || {}
    );
}

function _bridge(request) {
    const cli = _env("WPMCP_CODE_BRIDGE_CLI");
    if (!cli || !fs.existsSync(cli)) {
        throw new WPMCPCodeError("internal_error", "The wp-mcp CLI is missing.", 1);
    }

    let command = cli;
    let args = ["__code-bridge"];
    try {
        fs.accessSync(cli, fs.constants.X_OK);
    } catch {
        command = "bash";
        args = [cli, "__code-bridge"];
    }

    const result = spawnSync(command, args, {
        input: JSON.stringify(request),
        encoding: "utf8",
        env: process.env,
        maxBuffer: 64 * 1024 * 1024,
    });
    if (result.error) {
        throw new WPMCPCodeError("internal_error", `Could not start the code bridge: ${result.error.message}`, 1);
    }

    const stdout = result.stdout || "";
    const stderr = result.stderr || "";

    if (result.status === 0) {
        let envelope;
        try {
            envelope = JSON.parse(stdout);
        } catch {
            throw new WPMCPCodeError(
                "internal_error",
                "The code bridge returned invalid JSON.",
                1,
                null,
                { stderr: stderr.slice(-2000) }
            );
        }
        if (envelope && envelope.ok === true) {
            return envelope.data;
        }
        const error = _errorFrom(envelope && envelope.error, result.status);
        if (error) {
            throw error;
        }
        throw new WPMCPCodeError(
            "internal_error",
            "The code bridge returned an unexpected envelope.",
            1,
            null,
            { stderr: stderr.slice(-2000) }
        );
    }

    let envelope = null;
    try {
        envelope = JSON.parse(stderr);
    } catch {
        envelope = null;
    }
    const error = _errorFrom(envelope && envelope.error, result.status);
    if (error) {
        throw error;
    }
    throw new WPMCPCodeError(
        "internal_error",
        "The code bridge failed.",
        result.status || 1,
        null,
        { stderr: stderr.slice(-2000) }
    );
}

function wp_mcp_call(ability, input = null) {
    return _bridge({ op: "call", ability, input });
}

function wp_mcp_search(query, limit = 10, cursor = null) {
    const request = { op: "search", query, limit: Math.max(1, Math.min(50, Number(limit))) };
    if (cursor) {
        request.cursor = cursor;
    }
    const rows = _bridge(request);
    return Array.isArray(rows) ? rows : [];
}

function wp_mcp_discover(options = {}) {
    const result = _bridge({ op: "discover", options: options || {} });
    return result && typeof result === "object" ? result : {};
}

function wp_mcp_describe(ability) {
    const result = _bridge({ op: "describe", ability });
    return result && typeof result === "object" ? result : {};
}

function wp_mcp_log(message) {
    _bridge({ op: "log", message: String(message) });
}

function wp_mcp_is_dry_run() {
    return _env("WPMCP_CODE_DRY_RUN") === "1";
}

function wp_mcp_is_read_only() {
    return _env("WPMCP_CODE_READ_ONLY") === "1";
}

function wp_mcp_site() {
    return {
        name: _env("WPMCP_CODE_SITE"),
        url: _env("WPMCP_CODE_SITE_URL"),
        origin: _env("WPMCP_CODE_ORIGIN"),
    };
}

function _fail(error) {
    const code = error instanceof WPMCPCodeError ? error.errorCode : "script_error";
    const exitCode = error instanceof WPMCPCodeError ? error.exitCode : 5;
    _logEvent("error", {
        code,
        message: error && error.message ? error.message : String(error),
        exit_code: exitCode,
        remote_code: error && error.remoteCode ? error.remoteCode : null,
        details: error && error.details ? error.details : {},
    });
    process.stderr.write((error && error.message ? error.message : String(error)) + "\n");
    process.exit(exitCode);
}

process.on("uncaughtException", _fail);
process.on("unhandledRejection", _fail);
process.on("exit", () => _logEvent("end", { duration_ms: Date.now() - STARTED }));
_logEvent("start", { started_at: STARTED / 1000, pid: process.pid });

globalThis.WPMCPCodeError = WPMCPCodeError;
globalThis.wp_mcp_call = wp_mcp_call;
globalThis.wp_mcp_search = wp_mcp_search;
globalThis.wp_mcp_discover = wp_mcp_discover;
globalThis.wp_mcp_describe = wp_mcp_describe;
globalThis.wp_mcp_log = wp_mcp_log;
globalThis.wp_mcp_is_dry_run = wp_mcp_is_dry_run;
globalThis.wp_mcp_is_read_only = wp_mcp_is_read_only;
globalThis.wp_mcp_site = wp_mcp_site;
WPMCP_CODE_NODE_CLIENT
    chmod 600 "$tmp"
    mv -f "$tmp" "$node_file"

    printf '%s\n' "$WPMCP_CODE_CLIENT_VERSION" > "$version_file"
    chmod 600 "$version_file"
    rm -f "$WPMCP_HOME/lib/code-bootstrap.php" "$WPMCP_HOME/lib/code-bootstrap.version"

    wpmcp_code_validate_client "$runtime" "$base"
}
