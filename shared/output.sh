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
