# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Common code-mode bridge.
#
# The hidden `wp-mcp __code-bridge` command reads one JSON request from STDIN
# and returns one JSON response on STDOUT (success) or STDERR (error). It owns
# the modes, budgets, annotation cache and call log, so the PHP, Python and
# Node clients can stay thin. It only needs Bash, jq and the wp-mcp CLI.
#
# Stateful functions are called directly, not through command substitutions,
# so STATE, budgets and error propagation stay in one shell.

wpmcp_code_bridge() {
    local request op
    request=$(cat)
    op=$(printf '%s' "$request" | jq -r '.op // empty' 2>/dev/null || true)

    case "$op" in
        call|search|discover|describe|log) ;;
        *) wpmcp_code_bridge_error "usage_error" "Unknown code bridge operation." 2 ;;
    esac

    if [ -z "${WPMCP_CODE_STATE:-}" ] || [ ! -f "$WPMCP_CODE_STATE" ]; then
        wpmcp_code_bridge_error "internal_error" "Code bridge state is missing." 1
    fi
    if [ -z "${WPMCP_CODE_LOG:-}" ] || [ ! -f "$WPMCP_CODE_LOG" ]; then
        wpmcp_code_bridge_error "internal_error" "Code bridge log is missing." 1
    fi
    if [ -z "${WPMCP_CODE_CLI:-}" ] || [ ! -f "$WPMCP_CODE_CLI" ]; then
        wpmcp_code_bridge_error "internal_error" "Code bridge CLI is missing." 1
    fi

    if [ -x "$WPMCP_CODE_CLI" ]; then
        WPMCP_CODE_BRIDGE_CMD=("$WPMCP_CODE_CLI")
    else
        WPMCP_CODE_BRIDGE_CMD=(bash "$WPMCP_CODE_CLI")
    fi

    wpmcp_code_bridge_lock
    trap wpmcp_code_bridge_unlock EXIT

    STATE=$(wpmcp_code_bridge_state_read)

    case "$op" in
        call)
            local ability input
            ability=$(printf '%s' "$request" | jq -r '.ability // empty')
            input=$(printf '%s' "$request" | jq -c '.input // null')
            wpmcp_code_bridge_call "$ability" "$input"
            ;;
        search)
            local query limit cursor options
            query=$(printf '%s' "$request" | jq -r '.query // ""')
            limit=$(printf '%s' "$request" | jq -r '.limit // 10')
            cursor=$(printf '%s' "$request" | jq -r '.cursor // empty')
            options=$(jq -nc \
                --arg q "$query" \
                --argjson l "$limit" \
                --arg c "$cursor" \
                '{query:$q,limit:$l} + (if $c == "" then {} else {cursor:$c} end)')
            wpmcp_code_bridge_discover "$options"
            printf '%s' "$WPMCP_CODE_BRIDGE_RESULT" | jq -c '.abilities // []' | wpmcp_code_bridge_ok_stdin
            ;;
        discover)
            local options
            options=$(printf '%s' "$request" | jq -c '.options // {}')
            wpmcp_code_bridge_discover "$options"
            wpmcp_code_bridge_ok "$WPMCP_CODE_BRIDGE_RESULT"
            ;;
        describe)
            local ability
            ability=$(printf '%s' "$request" | jq -r '.ability // empty')
            wpmcp_code_bridge_describe "$ability"
            wpmcp_code_bridge_ok "$WPMCP_CODE_BRIDGE_DEFINITION"
            ;;
        log)
            local message
            message=$(printf '%s' "$request" | jq -r '.message // ""')
            wpmcp_code_bridge_log_event "$(jq -nc --arg m "$message" '{type:"log",message:$m}')"
            wpmcp_code_bridge_ok "null"
            ;;
    esac
}

wpmcp_code_bridge_lock() {
    if wpmcp_command_exists flock; then
        exec 9>"${WPMCP_CODE_STATE}.lock"
        flock -w 10 9 || wpmcp_code_bridge_error "internal_error" "Could not lock code bridge state." 1
        return 0
    fi

    local lock="${WPMCP_CODE_STATE}.lock.d"
    local i=0
    while ! mkdir "$lock" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 200 ]; then
            rm -rf "$lock" 2>/dev/null || true
            i=0
        fi
        sleep 0.05
    done
}

wpmcp_code_bridge_unlock() {
    if ! wpmcp_command_exists flock; then
        rmdir "${WPMCP_CODE_STATE}.lock.d" 2>/dev/null || true
    fi
}

wpmcp_code_bridge_state_read() {
    if [ ! -s "$WPMCP_CODE_STATE" ]; then
        printf '%s' '{"seq":0,"executions":0,"total_calls":0,"annotations":{},"definitions":{}}'
    else
        cat "$WPMCP_CODE_STATE"
    fi
}

wpmcp_code_bridge_state_write() {
    local tmp="${WPMCP_CODE_STATE}.tmp.$$"
    printf '%s' "$STATE" > "$tmp" && mv -f "$tmp" "$WPMCP_CODE_STATE"
}

wpmcp_code_bridge_ok() {
    local data="$1"
    printf '%s' "$data" | jq -c '{ok:true,data:.}'
}

wpmcp_code_bridge_ok_stdin() {
    jq -c '{ok:true,data:.}'
}

wpmcp_code_bridge_error() {
    local code="$1"
    local message="$2"
    local exit_code="${3:-5}"
    local remote="${4:-}"
    local details="${5:-}"
    [ -n "$details" ] || details="{}"

    jq -nc \
        --arg code "$code" \
        --arg message "$message" \
        --argjson exit "$exit_code" \
        --arg remote "$remote" \
        --argjson details "$details" \
        '{ok:false,error:{code:$code,message:$message,exitCode:$exit,remoteCode:$remote,details:$details}}' >&2
    exit "$exit_code"
}

wpmcp_code_bridge_log_event() {
    local event="$1"
    printf '%s' "$event" | jq -c . >> "$WPMCP_CODE_LOG"
}

wpmcp_code_bridge_bytes() {
    printf '%s' "$1" | wc -c | tr -d ' '
}

wpmcp_code_bridge_log_start() {
    local seq="$1" ability="$2" kind="$3" readonly="$4" destructive="$5" bytes="$6"
    wpmcp_code_bridge_log_event "$(jq -nc \
        --argjson seq "$seq" \
        --arg ability "$ability" \
        --arg kind "$kind" \
        --argjson readonly "$readonly" \
        --argjson destructive "$destructive" \
        --argjson bytes "$bytes" \
        '{type:"call_start",seq:$seq,ability:$ability,kind:$kind,readonly:$readonly,destructive:$destructive,request_bytes:$bytes}')"
}

wpmcp_code_bridge_log_end() {
    local seq="$1" ability="$2" kind="$3" status="$4" http="$5" duration="$6"
    local req="$7" resp="$8" err="$9" readonly="${10}" destructive="${11}"

    wpmcp_code_bridge_log_event "$(jq -nc \
        --argjson seq "$seq" \
        --arg ability "$ability" \
        --arg kind "$kind" \
        --arg status "$status" \
        --argjson http "$http" \
        --argjson duration "$duration" \
        --argjson req "$req" \
        --argjson resp "$resp" \
        --arg err "$err" \
        --argjson readonly "$readonly" \
        --argjson destructive "$destructive" \
        '{type:"call_end",seq:$seq,ability:$ability,kind:$kind,status:$status,http_status:$http,duration_ms:$duration,request_bytes:$req,response_bytes:$resp,error_code:(if $err == "" then null else $err end),readonly:$readonly,destructive:$destructive}')"
}

wpmcp_code_bridge_remaining() {
    local timeout="${WPMCP_CODE_TIMEOUT:-120}"
    local started="${WPMCP_CODE_STARTED_AT:-}"
    [ -n "$started" ] || started=$(date +%s)
    local now
    now=$(date +%s)
    local remaining=$((timeout - (now - started)))
    if [ "$remaining" -lt 1 ]; then
        return 1
    fi
    printf '%s' "$remaining"
}

wpmcp_code_bridge_claim_call() {
    local kind="$1"
    local max="${WPMCP_CODE_MAX_CALLS:-100}"
    local total_max=$((max * 3))
    [ "$total_max" -lt 50 ] && total_max=50

    local total
    total=$(printf '%s' "$STATE" | jq -r '.total_calls + 1')
    if [ "$total" -gt "$total_max" ]; then
        wpmcp_code_bridge_error "call_budget_exceeded" \
            "Total call budget exceeded (max $total_max)." 5 "" \
            "{\"max_total_calls\":$total_max}"
    fi

    local executions
    if [ "$kind" = "call" ]; then
        executions=$(printf '%s' "$STATE" | jq -r '.executions + 1')
        if [ "$executions" -gt "$max" ]; then
            wpmcp_code_bridge_error "call_budget_exceeded" \
                "Call budget exceeded (max $max)." 5 "" \
                "{\"max_calls\":$max}"
        fi
    else
        executions=$(printf '%s' "$STATE" | jq -r '.executions')
    fi

    local seq
    seq=$(printf '%s' "$STATE" | jq -r '.seq + 1')
    STATE=$(printf '%s' "$STATE" | jq -c \
        --argjson s "$seq" \
        --argjson e "$executions" \
        --argjson t "$total" \
        '.seq=$s | .executions=$e | .total_calls=$t')
    wpmcp_code_bridge_state_write
    WPMCP_CODE_BRIDGE_SEQ="$seq"
}

wpmcp_code_bridge_child_run() {
    local ability="$1"
    local input="$2"
    local remaining http_timeout rc=0 out err stderr envelope
    remaining=$(wpmcp_code_bridge_remaining) || \
        wpmcp_code_bridge_error "script_error" "Code mode timed out." 5
    if [ "$remaining" -lt 30 ]; then
        http_timeout=$remaining
    else
        http_timeout=30
    fi

    err="${WPMCP_CODE_STATE}.child.$$"
    out=$(printf '%s' "$input" | \
        WPMCP_QUIET=0 WPMCP_HTTP_TIMEOUT="$http_timeout" \
        "${WPMCP_CODE_BRIDGE_CMD[@]}" --json run "$ability" --input - 2>"$err") || rc=$?
    stderr=$(cat "$err" 2>/dev/null || true)
    rm -f "$err"

    envelope=$(printf '%s' "$out" | jq -c . 2>/dev/null || true)
    if [ "$rc" -eq 0 ] && printf '%s' "$envelope" | jq -e '.ok == true' >/dev/null 2>&1; then
        WPMCP_CODE_BRIDGE_HTTP_STATUS=$(printf '%s' "$envelope" | jq -r '.meta.http_status // 200')
        WPMCP_CODE_BRIDGE_DATA=$(printf '%s' "$envelope" | jq -c '.data')
        return 0
    fi

    wpmcp_code_bridge_raise_child "$rc" "$stderr"
}

wpmcp_code_bridge_child_describe() {
    local ability="$1"
    local remaining http_timeout rc=0 out err stderr envelope
    remaining=$(wpmcp_code_bridge_remaining) || \
        wpmcp_code_bridge_error "script_error" "Code mode timed out." 5
    if [ "$remaining" -lt 30 ]; then
        http_timeout=$remaining
    else
        http_timeout=30
    fi
    err="${WPMCP_CODE_STATE}.child.$$"
    out=$(WPMCP_QUIET=0 WPMCP_HTTP_TIMEOUT="$http_timeout" \
        "${WPMCP_CODE_BRIDGE_CMD[@]}" --json describe "$ability" 2>"$err") || rc=$?
    stderr=$(cat "$err" 2>/dev/null || true)
    rm -f "$err"

    envelope=$(printf '%s' "$out" | jq -c . 2>/dev/null || true)
    if [ "$rc" -eq 0 ] && printf '%s' "$envelope" | jq -e '.ok == true' >/dev/null 2>&1; then
        WPMCP_CODE_BRIDGE_HTTP_STATUS=$(printf '%s' "$envelope" | jq -r '.meta.http_status // 200')
        WPMCP_CODE_BRIDGE_DATA=$(printf '%s' "$envelope" | jq -c '.data')
        return 0
    fi

    wpmcp_code_bridge_raise_child "$rc" "$stderr"
}

wpmcp_code_bridge_raise_child() {
    local rc="$1"
    local stderr="$2"
    local error code message remote details exit_code

    error=$(printf '%s' "$stderr" | jq -c '.error // empty' 2>/dev/null || true)
    if [ -z "$error" ]; then
        code="script_error"
        message="The wp-mcp child process failed."
        exit_code=5
        remote=""
        details=$(printf '%s' "$stderr" | tail -c 2000 | jq -Rsc '{stderr:.}')
    else
        code=$(printf '%s' "$error" | jq -r '.code // "script_error"')
        message=$(printf '%s' "$error" | jq -r '.message // "The wp-mcp child process failed."')
        remote=$(printf '%s' "$error" | jq -r '.remoteCode // ""')
        details=$(printf '%s' "$error" | jq -c '.details // {}')
        case "$rc" in
            ''|*[!0-9]*) exit_code=5 ;;
            *) exit_code=$rc ;;
        esac
        [ "$exit_code" -gt 0 ] 2>/dev/null || exit_code=5

        case "$code" in
            wp_mcp_ability_not_found|wp_mcp_ability_hidden|rest_ability_not_found)
                remote="$code"
                code="ability_not_found"
                exit_code=2
                ;;
            wp_mcp_invalid_input|wp_mcp_missing_field)
                remote="$code"
                code="schema_validation_failed"
                exit_code=5
                ;;
            wp_mcp_forbidden|wp_mcp_disabled)
                remote="$code"
                code="auth_denied"
                exit_code=3
                ;;
        esac
        if [ -z "$remote" ] && [ "${code#wp_mcp_}" != "$code" ]; then
            remote="$code"
        fi
    fi

    wpmcp_code_bridge_error "$code" "$message" "$exit_code" "$remote" "$details"
}

wpmcp_code_bridge_valid_ability() {
    [[ "$1" =~ ^[a-z0-9-]+(/[a-z0-9-]+)+$ ]]
}

wpmcp_code_bridge_annotations() {
    local ability="$1"
    local cached
    cached=$(printf '%s' "$STATE" | jq -c --arg a "$ability" '.annotations[$a] // empty')
    if [ -n "$cached" ]; then
        WPMCP_CODE_BRIDGE_ANNOTATIONS="$cached"
        return 0
    fi
    wpmcp_code_bridge_describe "$ability"
    WPMCP_CODE_BRIDGE_ANNOTATIONS=$(printf '%s' "$WPMCP_CODE_BRIDGE_DEFINITION" | jq -c '.meta.annotations // {}')
}

wpmcp_code_bridge_describe() {
    local ability="$1"
    local cached seq bytes start duration definition annotations http
    if ! wpmcp_code_bridge_valid_ability "$ability"; then
        wpmcp_code_bridge_error "usage_error" "Invalid ability name: $ability" 2 "" \
            "{\"ability\":\"$ability\"}"
    fi
    cached=$(printf '%s' "$STATE" | jq -c --arg a "$ability" '.definitions[$a] // empty')
    if [ -n "$cached" ]; then
        WPMCP_CODE_BRIDGE_DEFINITION="$cached"
        return 0
    fi

    wpmcp_code_bridge_claim_call "describe"
    seq="$WPMCP_CODE_BRIDGE_SEQ"
    bytes=$(wpmcp_code_bridge_bytes "$(jq -nc --arg a "$ability" '{ability_name:$a}')")
    start=$(date +%s)
    wpmcp_code_bridge_log_start "$seq" "$ability" "describe" true false "$bytes"

    wpmcp_code_bridge_child_describe "$ability"
    definition="$WPMCP_CODE_BRIDGE_DATA"
    http="${WPMCP_CODE_BRIDGE_HTTP_STATUS:-200}"
    annotations=$(printf '%s' "$definition" | jq -c '.meta.annotations // {}')
    STATE=$(printf '%s' "$STATE" | jq -c \
        --arg a "$ability" \
        --argjson d "$definition" \
        --argjson an "$annotations" \
        '.definitions[$a]=$d | .annotations[$a]=$an')
    wpmcp_code_bridge_state_write

    duration=$((($(date +%s) - start) * 1000))
    wpmcp_code_bridge_log_end "$seq" "$ability" "describe" "ok" "$http" "$duration" \
        "$bytes" "$(wpmcp_code_bridge_bytes "$definition")" "" true false
    WPMCP_CODE_BRIDGE_DEFINITION="$definition"
}

wpmcp_code_bridge_discover() {
    local options="$1"
    local seq bytes start duration result http
    wpmcp_code_bridge_claim_call "search"
    seq="$WPMCP_CODE_BRIDGE_SEQ"
    bytes=$(wpmcp_code_bridge_bytes "$options")
    start=$(date +%s)
    wpmcp_code_bridge_log_start "$seq" "mcp-adapter/discover-abilities" "search" true false "$bytes"

    wpmcp_code_bridge_child_run "mcp-adapter/discover-abilities" "$options"
    result="$WPMCP_CODE_BRIDGE_DATA"
    http="${WPMCP_CODE_BRIDGE_HTTP_STATUS:-200}"
    STATE=$(printf '%s' "$STATE" | jq -c --argjson r "$result" '
        reduce ($r.abilities // [])[] as $row (.;
            if ($row.name // "") != "" and (($row.readonly // null) != null or ($row.destructive // null) != null) then
                .annotations[$row.name] = {
                    readonly: ($row.readonly // false),
                    destructive: (if $row.destructive == null then true else ($row.destructive == true) end)
                }
            else . end
        )')
    wpmcp_code_bridge_state_write

    duration=$((($(date +%s) - start) * 1000))
    wpmcp_code_bridge_log_end "$seq" "mcp-adapter/discover-abilities" "search" "ok" "$http" "$duration" \
        "$bytes" "$(wpmcp_code_bridge_bytes "$result")" "" true false
    WPMCP_CODE_BRIDGE_RESULT="$result"
}

wpmcp_code_bridge_is_allowed() {
    local ability="$1"
    [ -n "${WPMCP_CODE_ALLOW:-}" ] || return 1
    printf '%s\n' "$WPMCP_CODE_ALLOW" | grep -Fxq -- "$ability"
}

wpmcp_code_bridge_call() {
    local ability="$1"
    local input="$2"
    local seq bytes start duration annotations readonly destructive result http
    if ! wpmcp_code_bridge_valid_ability "$ability"; then
        wpmcp_code_bridge_error "usage_error" "Invalid ability name: $ability" 2 "" \
            "{\"ability\":\"$ability\"}"
    fi
    wpmcp_code_bridge_claim_call "call"
    seq="$WPMCP_CODE_BRIDGE_SEQ"
    bytes=$(wpmcp_code_bridge_bytes "$input")
    wpmcp_code_bridge_annotations "$ability"
    annotations="$WPMCP_CODE_BRIDGE_ANNOTATIONS"
    readonly=$(printf '%s' "$annotations" | jq -r 'if .readonly == true then "true" else "false" end')
    destructive=$(printf '%s' "$annotations" | jq -r \
        'if has("destructive") then (if .destructive == true then "true" else "false" end) else "true" end')

    start=$(date +%s)
    wpmcp_code_bridge_log_start "$seq" "$ability" "call" "$readonly" "$destructive" "$bytes"

    if [ "${WPMCP_CODE_DRY_RUN:-0}" = "1" ]; then
        duration=$((($(date +%s) - start) * 1000))
        wpmcp_code_bridge_log_end "$seq" "$ability" "call" "dry_run" null "$duration" "$bytes" 0 "" "$readonly" "$destructive"
        wpmcp_code_bridge_ok "$(jq -nc --arg a "$ability" --argjson i "$input" \
            '{__wp_mcp_dry_run:true,ability:$a,input:$i}')"
        return 0
    fi

    if [ "${WPMCP_CODE_READ_ONLY:-0}" = "1" ] && [ "$readonly" != "true" ]; then
        duration=$((($(date +%s) - start) * 1000))
        wpmcp_code_bridge_log_end "$seq" "$ability" "call" "skipped" null "$duration" "$bytes" 0 "" "$readonly" "$destructive"
        wpmcp_code_bridge_ok "$(jq -nc --arg a "$ability" \
            '{__wp_mcp_skipped:true,ability:$a,reason:"not_readonly"}')"
        return 0
    fi

    if [ "$destructive" = "true" ] &&
        [ "${WPMCP_CODE_ALLOW_DESTRUCTIVE:-0}" != "1" ] &&
        ! wpmcp_code_bridge_is_allowed "$ability"; then
        duration=$((($(date +%s) - start) * 1000))
        wpmcp_code_bridge_log_end "$seq" "$ability" "call" "blocked" null "$duration" "$bytes" 0 "" "$readonly" "$destructive"
        wpmcp_code_bridge_error "confirmation_required" \
            "Ability '$ability' is destructive. Re-run with --yes or --allow $ability." 6 "" \
            "{\"ability\":\"$ability\",\"seq\":$seq}"
    fi

    wpmcp_code_bridge_child_run "$ability" "$input"
    result="$WPMCP_CODE_BRIDGE_DATA"
    http="${WPMCP_CODE_BRIDGE_HTTP_STATUS:-200}"
    duration=$((($(date +%s) - start) * 1000))
    wpmcp_code_bridge_log_end "$seq" "$ability" "call" "ok" "$http" "$duration" \
        "$bytes" "$(wpmcp_code_bridge_bytes "$result")" "" "$readonly" "$destructive"
    wpmcp_code_bridge_ok "$result"
}
