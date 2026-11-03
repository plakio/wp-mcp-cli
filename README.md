# wp-mcp-cli

[![Tests](https://github.com/plakio/wp-mcp-cli/actions/workflows/test.yml/badge.svg)](https://github.com/plakio/wp-mcp-cli/actions/workflows/test.yml)

`wp-mcp-cli` is a Bash + [`gum`](https://github.com/charmbracelet/gum) CLI for the [WP-MCP WordPress plugin](https://github.com/plakio/wp-mcp). It talks to the plugin over WordPress Application Passwords (HTTP Basic) and exposes the same `WP_Ability` registry that the MCP server uses — without going through JSON-RPC.

The CLI is designed for **local Plak sites**. It does not handle OAuth, device flow, multi-host production, or Windows-native installs.

## Why a CLI when MCP exists?

WP-MCP ships an MCP server so Claude, Cursor, Codex, and other MCP clients can talk to WordPress. The MCP server, however, is JSON-RPC over HTTP and assumes a persistent MCP client. The CLI is a **complementary** surface:

- Same code path (`wp_get_ability($name)->execute($input)`) on the server side.
- Plain REST + Basic Auth on the wire — works in any terminal, every CI, every SSH session.
- Designed for non-interactive use by coding agents: `--json` envelope, stable error codes, exit codes, no TTY required.

## Architecture

```
                   ┌── MCP (POST /mcp/wp-mcp)        → Claude, Cursor, Codex
                   │
WP-MCP internals ──┤  wp_get_ability($name)->execute($input)   ← single execution layer
                   │
                   └── REST (POST /wp-mcp/v1/abilities/{name}/run)  → wp-mcp-cli
                                                                      ↓
                                                              Pi / Codex / OpenCode
                                                              scripts / CI / SSH
```

Adding a new ability (`wp_register_ability()` with `meta.show_in_rest => true`) makes it appear automatically through MCP, REST, and the CLI. No CLI update required.

## Requirements

- `bash` ≥ 4 (5+ on macOS via `brew install bash`)
- `gum` — `brew install gum` or `pacman -S gum`
- `jq` — `brew install jq`
- `curl`
- `php` ≥ 8.0 — only for `wp-mcp code`

## Installation

```bash
# Via curl (macOS/Linux)
curl -fsSL https://raw.githubusercontent.com/plakio/wp-mcp-cli/main/install.sh | bash

# Via Homebrew (macOS)
brew install plakio/tap/wp-mcp-cli

# From a local checkout (development)
./install.sh --dev
```

## Quickstart

```bash
# 1. Authenticate to a local Plak site.
wp-mcp auth login https://dev.localhost

# 2. Discover every ability exposed by the plugin.
wp-mcp --json discover | jq '.data.abilities[].name'

# 3. Inspect the schema of an ability.
wp-mcp --json describe wp-mcp/list-directory | jq '.data.input_schema'

# 4. Run it.
wp-mcp run wp-mcp/list-directory --input '{"path":"/Users"}'
```

## Commands

```
wp-mcp auth login [<url>] [--name <name>]   # save credentials for a WP-MCP site
wp-mcp auth status                            # show the active profile + credential summary
wp-mcp auth logout                            # remove credentials for the active site

wp-mcp sites list                             # list saved site profiles
wp-mcp sites remove <name> [--yes]
wp-mcp sites rename <name> <new-name>

wp-mcp discover                               # list every ability on the active site
wp-mcp describe <ability>                     # show schema + annotations
wp-mcp run <ability> --input <json|@file|-> [--yes]
wp-mcp code <file|-> [--dry-run|--read-only|--yes]

wp-mcp doctor [--offline]                     # health checks
wp-mcp skill install [codex|claude-code|opencode|hermes|pi|global|all]
wp-mcp version
```

## Code mode

`wp-mcp code` runs a local PHP script that calls abilities through the same
REST path as `wp-mcp run`. The script runs on your machine; it is **not** a
sandbox, and it has your local user's permissions. Use it for loops,
pagination, audits and batch work where intermediate data should not flow
through the model.

```php
<?php
$rows = wp_mcp_search('post', 5);
foreach ($rows as $row) {
    echo $row['name'] . "\n";
}
```

```bash
# Reads execute; every write is stubbed and logged.
wp-mcp code migrate.php --read-only

# Review the plan, then execute it.
wp-mcp code migrate.php --yes
```

Modes:

| Mode | Reads (`readonly=true`) | Non-destructive writes | Destructive writes |
| ---- | ----------------------- | ---------------------- | ------------------ |
| default | execute | execute | exit 6 unless `--yes` |
| `--read-only` | execute | stub | stub |
| `--dry-run` | stub | stub | stub |
| `--yes` | execute | execute | execute |

`--dry-run` still performs metadata calls (`wp_mcp_search` / `wp_mcp_describe`).
Use `--read-only` when the plan needs real data. The CLI does not pass the
application password to the script or its child processes; the script reaches
the site through the same `wp-mcp run` path.

## Global flags

- `--json` — force JSON output for commands that support it.
- `--quiet` / `-q` — suppress success output on STDOUT. Errors still go to STDERR.
- `--site <name>` — override the active site (or set `WPMCP_SITE`).
- `--version` — show wp-mcp-cli version.

## Exit codes

| Code | Meaning                                             |
| ---- | --------------------------------------------------- |
| 0    | success                                             |
| 1    | internal error                                      |
| 2    | usage error / `site_required` / `site_not_found` / `ability_not_found` |
| 3    | `auth_required` / `auth_denied` / `auth_expired`    |
| 4    | `network_error` / `rest_error` / `server_unsupported` |
| 5    | `ability_execution_failed` / `schema_validation_failed` / `script_error` / `call_budget_exceeded` |
| 6    | `confirmation_required` (destructive without `--yes`) |

## JSON envelopes

Success (STDOUT):
```json
{ "ok": true, "data": <value>, "meta": { "site": "...", "origin": "..." } }
```

Error (STDERR in `--json` mode):
```json
{ "ok": false, "error": { "code": "...", "message": "...", "retryable": false, "remoteCode": "...", "details": {...} } }
```

## Project structure

```
main              # globals, setup, command router
shared/           # shared helpers (paths, config, auth, http, output, ui, url, code)
commands/         # command functions (auth, sites, discover, describe, run, code, doctor, skill)
compile.sh        # builds wp-mcp.sh
install.sh        # local installer
docs/             # contract + code mode + homebrew maintenance
skills/wp-mcp/    # agent skill
guide-data/       # bundled guides
tests/            # hardening, code mode and live-site smoke tests
```

## Development

```bash
./compile.sh
bash -n main shared/*.sh commands/*
./tests/hardening.sh   # no site required
./tests/code.sh        # no site required
./tests/smoke.sh       # requires WPMCP_TEST_URL/USER/PASSWORD
```

CI and `scripts/release.sh` run the no-site tests. The live smoke test is
optional and requires a disposable WordPress site; it is not part of the
release gate.

## License

GNU Affero General Public License v3 or later. See `LICENSE`.

## See also

- [docs/homebrew.md](docs/homebrew.md) — release & tap maintenance.
- [docs/v1-contract.md](docs/v1-contract.md) — stable contract reference.
- [docs/code-mode.md](docs/code-mode.md) — code mode design and mode semantics.
- [skills/wp-mcp/SKILL.md](skills/wp-mcp/SKILL.md) — the agent skill.
- [guide-data/core/SKILL.md](guide-data/core/SKILL.md) — the canonical agent workflow.
