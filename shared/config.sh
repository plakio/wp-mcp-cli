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
        if [ "$exists" != '"object"' ]; then
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
