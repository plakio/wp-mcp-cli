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
