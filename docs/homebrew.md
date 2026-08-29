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

The script:

1. Updates `WPMCP_VERSION` in `main`.
2. Compiles the Bash distributable (`wp-mcp.sh`) via `compile.sh`.
3. Validates shell syntax with `bash -n`.
4. Commits the version bump and pushes `main`.
5. Creates and pushes tag `v<version>`.

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

The release tag is the source of truth. Do not manually edit the formula before the tag exists.
