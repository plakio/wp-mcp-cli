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
