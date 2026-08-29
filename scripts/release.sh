#!/usr/bin/env bash

# Bump WPMCP_VERSION in `main`, compile, validate, commit, tag, and push.
# Mirrors plak-cli's scripts/release.sh conventions.

# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

YES=0
TARGET_VERSION=""

for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES=1 ;;
        --help|-h)
            cat <<'HELP'
Usage:
  scripts/release.sh [version] [--yes]

If no version is given, the patch component of WPMCP_VERSION is bumped.
Pass --yes to skip the confirmation prompt.
HELP
            exit 0
            ;;
        --*)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
        *)
            if [ -z "$TARGET_VERSION" ]; then
                TARGET_VERSION="$arg"
            else
                echo "Unexpected argument: $arg" >&2
                exit 1
            fi
            ;;
    esac
done

cd "$(dirname "$0")/.."

# Extract current version.
current=$(grep -E '^WPMCP_VERSION=' main | head -n1 | sed -E 's/^WPMCP_VERSION="([^"]+)"$/\1/')
if [ -z "$current" ]; then
    echo "Could not read WPMCP_VERSION from main." >&2
    exit 1
fi

if [ -z "$TARGET_VERSION" ]; then
    IFS='.' read -r major minor patch <<< "$current"
    TARGET_VERSION="$major.$minor.$((patch + 1))"
fi

if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version: $TARGET_VERSION (expected semver X.Y.Z)" >&2
    exit 1
fi

if [ "$current" = "$TARGET_VERSION" ] && [ "$YES" != "1" ]; then
    echo "Version $current is already current. Pass an explicit version or --yes." >&2
    exit 1
fi

cat <<EOF
About to release wp-mcp-cli $TARGET_VERSION
  (previous: $current)

Steps:
  1. Update WPMCP_VERSION in main
  2. Compile wp-mcp.sh
  3. Validate bash syntax
  4. Commit + push
  5. Tag v$TARGET_VERSION + push tag
EOF

if [ "$YES" != "1" ]; then
    read -r -p "Proceed? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 1
    fi
fi

# 1. Bump version.
sed -i.bak -E "s/^WPMCP_VERSION=\"[0-9]+\.[0-9]+\.[0-9]+\"$/WPMCP_VERSION=\"$TARGET_VERSION\"/" main
rm -f main.bak

# 2. Compile.
./compile.sh

# 3. Validate syntax.
bash -n main shared/* commands/* compile.sh install.sh wp-mcp.sh

# 4. Commit + push.
git add main wp-mcp.sh
git commit -m "Release $TARGET_VERSION"
git push origin main

# 5. Tag + push.
git tag "v$TARGET_VERSION"
git push origin "v$TARGET_VERSION"

echo "Released v$TARGET_VERSION"
