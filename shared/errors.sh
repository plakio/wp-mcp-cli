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
