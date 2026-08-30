#!/usr/bin/env bash

# wp-mcp - Bash entrypoint
# Source file for the compiled wp-mcp.sh distribution script.

# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

WPMCP_NAME="wp-mcp"
WPMCP_VERSION="0.1.9"
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
    jq -n \
        --arg user "$user" \
        --arg pass "$pass" \
        --arg site "$site" \
        '{site:$site,username:$user,app_password:$pass,created_at:now|todate}' \
        > "$tmp"
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
    WPMCP_ACTIVE_USER=$(echo "$cred" | jq -r '.username')
    WPMCP_ACTIVE_PASS=$(echo "$cred" | jq -r '.app_password')
    export WPMCP_ACTIVE_USER WPMCP_ACTIVE_PASS
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
    local method="$1"
    local url="$2"
    local body_file="${3:-}"

    local cred_args=()
    if [ -n "${WPMCP_ACTIVE_USER:-}" ] && [ -n "${WPMCP_ACTIVE_PASS:-}" ]; then
        cred_args=(-u "$WPMCP_ACTIVE_USER:$WPMCP_ACTIVE_PASS")
    fi

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

    # shellcheck disable=SC2086
    curl "${cred_args[@]}" "${curl_args[@]}" "$url" 2>/dev/null
    local rc=$?
    if [ $rc -ne 0 ]; then
        return $rc
    fi
    return 0
}

wpmcp_http_get() {
    # GET <url> → emits STATUS<TAB>BODY (use wpmcp_http_split)
    wpmcp_http_request GET "$1"
}

wpmcp_http_post_json() {
    # POST <url> <json_string> → emits STATUS<TAB>BODY
    local url="$1"
    local json="$2"
    local tmp
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN
    printf '%s' "$json" > "$tmp"
    wpmcp_http_request POST "$url" "$tmp"
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
    export WPMCP_HTTP_STATUS WPMCP_HTTP_BODY
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

    local raw
    if [ "$method" = "GET" ]; then
        raw=$(wpmcp_http_get "$url")
    else
        raw=$(wpmcp_http_post_json "$url" "$body")
    fi
    local rc=$?
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
    local body="$1"
    local site origin
    site="${WPMCP_ACTIVE_SITE:-}"
    origin="${WPMCP_ACTIVE_ORIGIN:-}"

    # Wrap the raw body as the `data` field.
    local data
    if [ -z "$body" ]; then
        data="null"
    elif echo "$body" | jq -e . >/dev/null 2>&1; then
        data=$(echo "$body" | jq -c .)
    else
        data=$(jq -n --arg s "$body" '$s')
    fi

    jq -nc \
        --argjson data "$data" \
        --arg site "$site" \
        --arg origin "$origin" \
        '{ok:true,data:$data,meta:{site:$site,origin:$origin}}'
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
    if [ -z "$pass" ] && [ -n "${WPMCP_PASSWORD:-}" ]; then
        pass="$WPMCP_PASSWORD"
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
    export WPMCP_ACTIVE_USER WPMCP_ACTIVE_PASS
    WPMCP_ACTIVE_SITE="$name"
    WPMCP_ACTIVE_ORIGIN="$origin"
    export WPMCP_ACTIVE_SITE WPMCP_ACTIVE_ORIGIN

    local probe_url="$url/wp-json/wp/v2/users/me"
    local probe_raw
    probe_raw=$(wpmcp_http_get "$probe_url")
    local probe_rc=$?
    if [ $probe_rc -ne 0 ]; then
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
        jq -nc --argjson data "$annotated" '{ok:true,data:$data,meta:{}}'
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

    local raw
    raw=$(wpmcp_http_get "$rest_url")
    local rc=$?
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
        jq -nc \
            --argjson ability "$body" \
            --arg site "$WPMCP_ACTIVE_SITE" \
            '{ok:true,data:$ability,meta:{site:$site}}'
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
        local raw
        raw=$(wpmcp_http_get "$url")
        local rc=$?
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
        all_abilities=$(jq -nc --argjson a "$all_abilities" --argjson b "$body" '$a + $b')
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
        jq -nc \
            --argjson abilities "$all_abilities" \
            --arg site "$WPMCP_ACTIVE_SITE" \
            --arg origin "$WPMCP_ACTIVE_ORIGIN" \
            '{ok:true,data:{abilities:$abilities},meta:{site:$site,origin:$origin,count:($abilities|length)}}'
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
            if [ "$status" = "OK" ]; then
                echo "  OK    $name"
            else
                echo "  FAIL  $name"
            fi
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

    # Validate JSON before posting.
    if [ "$input_json" != "null" ] && ! printf '%s' "$input_json" | jq -e . >/dev/null 2>&1; then
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
        local describe_raw
        describe_raw=$(wpmcp_http_get "$describe_url")
        if [ $? -eq 0 ]; then
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

    # POST the request.
    local body
    body=$(jq -nc --argjson input "$input_json" '{input:$input}')

    local raw
    raw=$(wpmcp_http_post_json "$rest_url" "$body")
    local rc=$?
    if [ $rc -ne 0 ]; then
        wpmcp_error_print "network_error" "$WPMCP_ERROR_NETWORK" \
            "Failed to POST $rest_url (curl exit $rc)"
    fi
    wpmcp_http_split "$raw"
    if [ "${WPMCP_HTTP_STATUS:-000}" -ge 400 ]; then
        wpmcp_http_classify_wp_error "$WPMCP_HTTP_BODY"
    fi

    local resp_body
    resp_body=$(printf '%s' "$WPMCP_HTTP_BODY" | jq -c . 2>/dev/null || printf '%s' "$WPMCP_HTTP_BODY")

    if [ "$WPMCP_JSON" = "1" ]; then
        jq -nc \
            --argjson data "$resp_body" \
            --arg site "$WPMCP_ACTIVE_SITE" \
            '{ok:true,data:$data,meta:{site:$site}}'
    else
        if echo "$resp_body" | jq -e . >/dev/null 2>&1; then
            echo "$resp_body" | jq .
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
