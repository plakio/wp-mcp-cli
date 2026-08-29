# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# wp-mcp-cli version reporting.

wpmcp_version_print() {
    echo "$WPMCP_NAME $WPMCP_VERSION"
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
