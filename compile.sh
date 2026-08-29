#!/usr/bin/env bash

# Compile wp-mcp-cli source files into a single distributable script.
# Mirrors plak-cli's compile.sh: concatenates `main`, `shared/*`, and
# `commands/*` into wp-mcp.sh.

# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

OUTPUT_FILE="wp-mcp.sh"
MAIN_SCRIPT="main"
LIB_DIR="shared"
COMMANDS_DIR="commands"

if [ ! -f "$MAIN_SCRIPT" ] || [ ! -d "$COMMANDS_DIR" ] || [ ! -d "$LIB_DIR" ]; then
    echo "Error: run compile.sh from the wp-mcp-cli repository root." >&2
    exit 1
fi

echo "Compiling $OUTPUT_FILE..."

# Use -F (fixed string) + -x (whole line) so only the exact `main "$@"`
# invocation at the bottom of `main` is stripped.
grep -vFx 'main "$@"' "$MAIN_SCRIPT" > "$OUTPUT_FILE"

{
    echo ""
    echo "# --- Shared Helpers ---"
    find "$LIB_DIR" -type f ! -name '.*' | sort | while IFS= read -r lib_file; do
        echo "# Source: $lib_file"
        cat "$lib_file"
        echo ""
    done

    echo "# --- Command Functions ---"
    find "$COMMANDS_DIR" -type f ! -name '.*' | sort | while IFS= read -r cmd_file; do
        echo "# Source: $cmd_file"
        cat "$cmd_file"
        echo ""
    done

    echo '# Pass all script arguments to the main function.'
    echo 'main "$@"'
} >> "$OUTPUT_FILE"

chmod +x "$OUTPUT_FILE"
echo "Created $(pwd)/$OUTPUT_FILE"
