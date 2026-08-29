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
