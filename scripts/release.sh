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
NOTES_FILE=""
REPO_SLUG="plakio/wp-mcp-cli"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y)
            YES=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --skip-release)
            SKIP_RELEASE=1
            shift
            ;;
        --notes-file)
            if [ "$#" -lt 2 ]; then
                echo "--notes-file requires a path" >&2
                exit 1
            fi
            NOTES_FILE="$2"
            shift 2
            ;;
        --notes-file=*)
            NOTES_FILE="${1#--notes-file=}"
            shift
            ;;
        --help|-h)
            cat <<'HELP'
Usage:
  scripts/release.sh [version] [--yes] [--dry-run] [--skip-release] [--notes-file <path>]

If no version is given, the patch component of WPMCP_VERSION is bumped.
Pass --yes to skip the confirmation prompt.
Pass --dry-run to print the plan and release notes without changing anything.
Pass --skip-release to push the tag without creating a GitHub Release.
Pass --notes-file <path> to use curated Markdown notes instead of the
generated commit list.
HELP
            exit 0
            ;;
        --*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$TARGET_VERSION" ]; then
                TARGET_VERSION="$1"
            else
                echo "Unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -n "$NOTES_FILE" ]; then
    case "$NOTES_FILE" in
        /*) ;;
        *) NOTES_FILE="$(pwd)/$NOTES_FILE" ;;
    esac
    if [ ! -f "$NOTES_FILE" ] || [ ! -r "$NOTES_FILE" ]; then
        echo "Notes file not found or not readable: $NOTES_FILE" >&2
        exit 1
    fi
fi

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

if [ -n "$NOTES_FILE" ]; then
    notes=$(cat "$NOTES_FILE")
    if [ -z "$notes" ]; then
        echo "Notes file is empty: $NOTES_FILE" >&2
        exit 1
    fi
else
    if [ -n "$previous_tag" ]; then
        changes=$(git log --pretty=format:"- %s" "${previous_tag}..HEAD" 2>/dev/null || true)
    else
        changes=$(git log --pretty=format:"- %s" HEAD 2>/dev/null || true)
    fi
    [ -n "$changes" ] || changes="- Release $TARGET_VERSION"
    notes="## What's changed

$changes"
fi

if [ -n "$previous_tag" ] && ! printf '%s' "$notes" | grep -Fq "Full Changelog"; then
    notes="$notes

**Full Changelog**: https://github.com/${REPO_SLUG}/compare/${previous_tag}...v${TARGET_VERSION}"
fi

if [ -n "$NOTES_FILE" ]; then
    notes_label="curated from $NOTES_FILE"
else
    notes_label="generated from commits"
fi

cat <<EOF
About to release wp-mcp-cli $TARGET_VERSION
  (previous: $current)
  (previous tag: ${previous_tag:-none})
  (notes: $notes_label)

Steps:
  1. Update WPMCP_VERSION in main
  2. Compile wp-mcp.sh
  3. Validate bash syntax
  4. Run no-site tests (hardening, code mode, skill)
  5. Commit + push
  6. Tag v$TARGET_VERSION + push
  7. Create GitHub Release$( [ "$SKIP_RELEASE" = "1" ] && echo " (skipped by --skip-release)" || true )

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

# 3. Validate syntax and run the no-site test suites. These use a fake CLI and
# fake curl/jq; they do not require a WordPress site or WPMCP_TEST_* variables.
bash -n main shared/* commands/* compile.sh install.sh tests/*.sh wp-mcp.sh
./tests/hardening.sh
./tests/code.sh
./tests/skill.sh

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
