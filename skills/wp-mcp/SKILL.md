---
name: wp-mcp
description: "Use when working with wp-mcp-cli for the WP-MCP WordPress plugin: discovering abilities on a local site, describing schemas, executing filesystem/code-execution/Gutenberg/Elementor/WooCommerce abilities, managing site profiles, or installing the CLI from the plakio/wp-mcp-cli repository."
---

# wp-mcp

Use the `wp-mcp` CLI for local WordPress sites that have the
[WP-MCP plugin](https://github.com/plakio/wp-mcp) installed. The CLI
talks to the plugin over WordPress Application Passwords (HTTP Basic)
and exposes the same `WP_Ability` registry that the MCP server uses.

## Key Rules

- The CLI is for local Plak sites. It does **not** handle OAuth, device
  flow, multi-host production, or Windows-native installs.
- Application Passwords are the only auth method. Generate one from the
  WP-MCP → Configuration admin page in your WordPress dashboard.
- An ability is the atomic unit of work. Discover → describe → run is
  the canonical 3-step pattern.
- Destructive abilities (`destructive: true` in annotations) require
  `--yes` in non-TTY contexts. The CLI never auto-confirms.
- A new ability registered via `wp_register_ability()` with
  `meta.show_in_rest => true` becomes available via the CLI
  automatically — no CLI update needed.

## Installation

If wp-mcp-cli is not installed, use one of:

```bash
# Via curl (macOS/Linux)
curl -fsSL https://raw.githubusercontent.com/plakio/wp-mcp-cli/main/install.sh | bash

# Via Homebrew (macOS)
brew install plakio/tap/wp-mcp-cli

# From a local checkout
./install.sh --dev
```

Install this skill for your agent:

```bash
wp-mcp skill install codex       # or claude-code, opencode, hermes, pi, global, all
```

## Agent-friendly interface

The CLI is designed for non-interactive use. No TTY is required when all
values are passed via flags.

**Global flags** (must appear before the command):

- `--json` — force JSON output.
- `--quiet` / `-q` — suppress success output on STDOUT. Errors still go
  to STDERR.
- `--site <name>` — override the active site (or set `WPMCP_SITE`).
- `--version` — show wp-mcp-cli version.

**Selection order for the active site**:

1. `--site <name>`
2. `WPMCP_SITE` environment variable
3. The single configured profile (implicit)
4. `site_required` (exit 2) when multiple profiles exist without a selector

**Error handling**:

- Exit codes: `0` success · `1` internal · `2` usage · `3` auth ·
  `4` network · `5` execution · `6` confirmation_required
- Errors go to STDERR; data goes to STDOUT. Use `data=$(wp-mcp ... 2>/dev/null)`.
- JSON envelope on STDOUT in `--json` mode:
  `{"ok":true,"data":<value>,"meta":{"site":"...","origin":"..."}}`
- JSON envelope on STDERR in `--json` mode:
  `{"ok":false,"error":{"code":"...","message":"...","retryable":bool}}`

## Common Commands

```bash
wp-mcp --json version                                  # {name, version, os}
wp-mcp doctor --offline                                # CLI env health
wp-mcp doctor                                          # CLI env + site reachability

wp-mcp auth login https://dev.localhost                # interactive credential wizard
wp-mcp --json auth status                              # current site + credential summary
wp-mcp auth logout

wp-mcp --json sites list                               # [{name,siteUrl,origin,defaultUser}]
wp-mcp sites rename dev.localhost staging
wp-mcp sites remove old-site --yes

wp-mcp --json discover                                 # list every ability on the active site
wp-mcp --json describe wp-mcp/list-directory           # schema + annotations
wp-mcp run wp-mcp/list-directory --input '{"path":"/Users"}'
wp-mcp run wp-mcp/read-file --input @request.json
cat request.json | wp-mcp run wp-mcp/execute-php --input -
wp-mcp run wp-mcp/delete-file --input '{"path":"/tmp/x"}' --yes
```

## Discover → Describe → Run

The canonical workflow for an agent:

1. **Discover**: `wp-mcp --json discover` returns every ability with
   `{name, label, category, meta.annotations.{readonly,destructive,idempotent}}`.
   Use `jq '.data.abilities[] | select(.meta.annotations.destructive == true) | .name'`
   to find dangerous ones.
2. **Describe**: `wp-mcp --json describe <ns>/<name>` returns
   `input_schema` and `output_schema`. Validate your input locally before
   sending — the CLI does not enforce the schema.
3. **Run**: `wp-mcp run <ns>/<name> --input '<json>'` posts to
   `POST /wp-json/wp-mcp/v1/abilities/<ns>/<name>/run` with body
   `{"input":<json>}`.

## Input handling

The `--input` flag accepts:

- inline JSON string: `--input '{"path":"/Users"}'`
- `@<path>` — read JSON from a file: `--input @payload.json`
- `-` — read JSON from STDIN: `cat payload.json | wp-mcp ... --input -`
- omitted — `input` defaults to `null`

## Authentication

`wp-mcp auth login <url>` stores a WordPress Application Password at
`~/.wp-mcp/credentials/<site>.json` with `chmod 0600`. The CLI never
prints the password back. To rotate, `wp-mcp auth logout && wp-mcp auth login`.

## Troubleshooting

- `wp-mcp: command not found` — re-run the installer and check `$PATH`.
- `site_required` — pass `--site <name>` or set `WPMCP_SITE`.
- `auth_required` — `wp-mcp auth login <url>`.
- `network_error` — `wp-mcp doctor` to verify the site is reachable.
- `ability_not_found` — the ability may be disabled in the WP-MCP Abilities
  Hub admin page; verify with `wp-mcp --json discover`.
- For pretty-permalink failures on sites without them, set
  `WPMCP_REST_PLAIN=1`.

## Development

When editing wp-mcp-cli:

1. Read `AGENTS.md` first.
2. Compile after source edits: `./compile.sh`.
3. Validate: `bash -n main shared/* commands/* compile.sh install.sh wp-mcp.sh`.
4. Smoke test against a real site: `./tests/smoke.sh` (when present).
5. Releases are triggered by tag `v<version>`; the tag automatically
   notifies the Homebrew tap via `.github/workflows/notify-homebrew-tap.yml`.
