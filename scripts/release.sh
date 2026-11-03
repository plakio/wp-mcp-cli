#!/usr/bin/env bash

# Bump WPMCP_VERSION in `main`, compile, validate, commit, tag, push, and
# create a GitHub Release.
# Mirrors plak-cli's release.sh conventions.

# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

YES=0
DRY_RUN=0
SKIP_RELEASE=0
TARGET_VERSION=""
REPO_SLUG="plakio/wp-mcp-cli"

for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --skip-release) SKIP_RELEASE=1 ;;
        --help|-h)
            cat <<'HELP'
Usage:
  scripts/release.sh [version] [--yes] [--dry-run] [--skip-release]

If no version is given, the patch component of WPMCP_VERSION is bumped.
Pass --yes to skip the confirmation prompt.
Pass --dry-run to print the plan and generated release notes without
changing anything.
Pass --skip-release to push the tag without creating a GitHub Release.
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

if [ "$current" = "$TARGET_VERSION" ] && [ "$YES" != "1" ] && [ "$DRY_RUN" != "1" ]; then
    echo "Version $current is already current. Pass an explicit version or --yes." >&2
    exit 1
fi

previous_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$previous_tag" ]; then
    changes=$(git log --pretty=format:"- %s" "${previous_tag}..HEAD" 2>/dev/null || true)
else
    changes=$(git log --pretty=format:"- %s" HEAD 2>/dev/null || true)
fi
[ -n "$changes" ] || changes="- Release $TARGET_VERSION"

notes="## What's changed

$changes"
if [ -n "$previous_tag" ]; then
    notes="$notes

**Full Changelog**: https://github.com/${REPO_SLUG}/compare/${previous_tag}...v${TARGET_VERSION}"
fi

cat <<EOF
About to release wp-mcp-cli $TARGET_VERSION
  (previous: $current)
  (previous tag: ${previous_tag:-none})

Steps:
  1. Update WPMCP_VERSION in main
  2. Compile wp-mcp.sh
  3. Validate bash syntax
  4. Commit + push
  5. Tag v$TARGET_VERSION + push
  6. Create GitHub Release$( [ "$SKIP_RELEASE" = "1" ] && echo " (skipped by --skip-release)" || true )

Release notes:
$notes
EOF

if [ "$DRY_RUN" = "1" ]; then
    echo "Dry run: no changes made."
    exit 0
fi

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

# 6. GitHub Release.
if [ "$SKIP_RELEASE" = "1" ]; then
    echo "Skipped GitHub Release (--skip-release)."
elif ! command -v gh >/dev/null 2>&1; then
    echo "Warning: gh not found; tag pushed but no GitHub Release was created." >&2
elif gh release view "v$TARGET_VERSION" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "GitHub Release v$TARGET_VERSION already exists."
elif gh release create "v$TARGET_VERSION" \
    --repo "$REPO_SLUG" \
    --title "wp-mcp-cli v$TARGET_VERSION" \
    --notes "$notes"; then
    echo "Created GitHub Release v$TARGET_VERSION."
else
    echo "Warning: tag pushed, but GitHub Release creation failed." >&2
    echo "Create it manually with: gh release create v$TARGET_VERSION --repo $REPO_SLUG --title \"wp-mcp-cli v$TARGET_VERSION\" --notes \"...\"" >&2
fi

echo "Released v$TARGET_VERSION"
