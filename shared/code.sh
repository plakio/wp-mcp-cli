# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Code mode helpers: PHP bootstrap extraction, execution and rendering.
# The user script runs locally. It is not a sandbox.

# Bump this whenever the embedded PHP bootstrap changes so existing
# installations rewrite $WPMCP_HOME/lib/code-bootstrap.php.
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


wpmcp_code_run_runtime() {
    # wpmcp_code_run_runtime <runtime> <script> <client_dir> <out> <err> <timeout> <timeout_flag>
    local runtime="$1"
    local script="$2"
    local client_dir="$3"
    local out="$4"
    local err="$5"
    local timeout="$6"
    local timeout_flag="$7"
    local status=0

    set -m
    case "$runtime" in
        php)
            php -d auto_prepend_file="$client_dir/php/wpmcp-code.php" \
                -d max_execution_time="$timeout" \
                -d display_errors=stderr \
                -d html_errors=0 \
                -d log_errors=0 \
                -d memory_limit=256M \
                "$script" >"$out" 2>"$err" &
            ;;
        python)
            PYTHONPATH="$client_dir/python${PYTHONPATH:+:$PYTHONPATH}" \
                WPMCP_CODE_SCRIPT="$script" \
                python3 "$client_dir/python/runner.py" >"$out" 2>"$err" &
            ;;
        node)
            node --require "$client_dir/node/wpmcp-code.cjs" "$script" >"$out" 2>"$err" &
            ;;
        *)
            set +m
            wpmcp_error_usage "Unknown runtime: $runtime"
            ;;
    esac
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
