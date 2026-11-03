# Homebrew Distribution

`wp-mcp-cli` is distributed through the `plakio/homebrew-tap` repository. Users install it with:

```bash
brew install plakio/tap/wp-mcp-cli
```

## Automated release flow

Use `scripts/release.sh` from the `wp-mcp-cli` repository root. Only this repository needs to be cloned locally.

To auto-increment the patch version from `WPMCP_VERSION` in `main`:

```bash
./scripts/release.sh --yes
```

To release an explicit version:

```bash
./scripts/release.sh 0.1.1 --yes
```

To preview the version, generated release notes and steps without changing
anything:

```bash
./scripts/release.sh 0.2.1 --dry-run
```

To push the tag without creating a GitHub Release:

```bash
./scripts/release.sh 0.2.1 --yes --skip-release
```

To use curated Markdown notes instead of the generated commit list:

```bash
./scripts/release.sh 0.2.1 --dry-run --notes-file /tmp/release-notes.md
./scripts/release.sh 0.2.1 --yes --notes-file /tmp/release-notes.md
```

The script:

1. Uses the `--notes-file` content, or generates notes from commits since the
   previous tag.
2. Updates `WPMCP_VERSION` in `main`.
3. Compiles the Bash distributable (`wp-mcp.sh`) via `compile.sh`.
4. Validates shell syntax with `bash -n`.
5. Commits the version bump and pushes `main`.
6. Creates and pushes tag `v<version>`.
7. Creates a GitHub Release with the notes via `gh`, unless `--skip-release`
   is passed. If `gh` is missing or not authenticated, the tag is still
   pushed and the script prints a warning.

For curated notes, start with the release's highlights, requirements, and
validation. The script appends a **Full Changelog** link automatically when
the notes do not already contain one.

The tag triggers `.github/workflows/notify-homebrew-tap.yml`, which sends a `new-release` repository dispatch event to `plakio/homebrew-tap`. The tap downloads the tag archive, calculates its SHA256, generates and tests the formula on macOS, and pushes the formula update.

The `wp-mcp-cli` repository requires an Actions secret named `TAP_DISPATCH_TOKEN`. It must be a fine-grained token limited to `plakio/homebrew-tap` with `Contents: Read and write` permission.

## Manual recovery

If the tag exists but the tap workflow did not start, resend the notification without creating another release:

```bash
gh workflow run notify-homebrew-tap.yml \
  --repo plakio/wp-mcp-cli \
  --field version=v0.1.0
```

Monitor the run with:

```bash
gh run list --repo plakio/homebrew-tap --workflow update-wp-mcp-cli.yml
```

If the tag exists but the GitHub Release was not created, create it manually:

```bash
gh release create v<version> \
  --repo plakio/wp-mcp-cli \
  --title "wp-mcp-cli v<version>" \
  --generate-notes
```

The release tag is the source of truth. Do not manually edit the formula before the tag exists.
