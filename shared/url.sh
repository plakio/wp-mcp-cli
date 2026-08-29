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
