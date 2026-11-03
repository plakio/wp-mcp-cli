# wp-mcp-cli v1 Contract

This document defines the stable surface of wp-mcp-cli. Implementations MUST keep the contracts documented here backward-compatible within the v1 line.

## Invocation

```text
wp-mcp [--json] [--quiet] [--site <name>] <command> [args...]
```

## Global flags

| Flag | Effect |
| ---- | ------ |
| `--json` | Emit JSON envelopes on STDOUT/STDERR. |
| `--quiet` / `-q` | Suppress success output on STDOUT. |
| `--site <name>` | Override the active site for this invocation. |
| `--version` | Print `wp-mcp <version>` and exit. |

## Site selection order

1. `--site <name>` (or `WPMCP_SITE` env)
2. `WPMCP_SITE` environment variable
3. The single configured profile (implicit)
4. Exit 2 with `site_required` when multiple profiles exist without a selector

## Exit codes

| Code | Meaning |
| ---- | ------- |
| 0 | success |
| 1 | internal_error |
| 2 | usage_error, site_required, site_not_found, ability_not_found |
| 3 | auth_required, auth_denied, auth_expired |
| 4 | network_error, rest_error, server_unsupported |
| 5 | ability_execution_failed, schema_validation_failed, script_error, call_budget_exceeded |
| 6 | confirmation_required |

## JSON envelopes

### Success (STDOUT)

```json
{
  "ok": true,
  "data": <value>,
  "meta": {
    "site": "<profile name>",
    "origin": "<site origin>"
  }
}
```

`run` also includes `meta.http_status` (the REST status of the ability
execution).

### Error (STDERR, only when `--json` is set; plain text otherwise)

```json
{
  "ok": false,
  "error": {
    "code": "<stable_code>",
    "message": "<human readable>",
    "retryable": false,
    "remoteCode": "<wp-mcp code if different>",
    "details": { ... }
  }
}
```

## Credential handling

Application passwords are stored in `$WPMCP_HOME/credentials/<site>.json`
with mode `0600`. The stored password is never passed to child processes in
command-line arguments and is never exported to their environment. HTTP
requests hand the password to curl through a `--config` document read from
STDIN. Request bodies use a `0600` temporary file, and response bodies stay in
the shell instead of being exported to the environment. When `WPMCP_PASSWORD`
is used for `auth login`, the CLI reads it once and removes it from the
environment before running child processes. (`auth login --password`
necessarily accepts a password on the command line; use `WPMCP_PASSWORD` or
the interactive prompt when that matters.)

## Environment variables

| Variable | Effect |
| -------- | ------ |
| `WPMCP_HOME` | Override the config/credentials/cache root (default `$HOME/.wp-mcp`). |
| `WPMCP_SITE` | Same as `--site <name>`; lower priority than the flag. |
| `WPMCP_USERNAME` | Fallback for `--user` on `auth login`. |
| `WPMCP_PASSWORD` | Fallback for `--password` on `auth login`. |
| `WPMCP_REST_PLAIN` | `1` → use `?rest_route=` instead of pretty permalinks. |
| `WPMCP_HTTP_TIMEOUT` | Per-request curl timeout in seconds (default 30). |
| `WPMCP_HTTP_VERBOSE` | `1` → pass `--verbose` to curl. |
| `WPMCP_UPDATE_CHECK` | Reserved for future use. |
| `WPMCP_CREDENTIAL_BACKEND` | Reserved for future use. |

In non-TTY mode the CLI never auto-prompts. Missing required values
produce one consolidated `usage_error` exit 2 listing every missing
input (with the exact flag or env var to set).



| Code | Exit | Meaning |
| ---- | ---- | ------- |
| `usage_error` | 2 | Argument or flag combination is invalid. |
| `site_required` | 2 | Multiple profiles configured and none selected. |
| `site_not_found` | 2 | `--site` value does not match any saved profile. |
| `ability_not_found` | 2 | Ability name is not registered on the active site. |
| `auth_required` | 3 | No credentials stored for the active site. |
| `auth_denied` | 3 | WordPress rejected HTTP Basic credentials. |
| `auth_expired` | 3 | Application password no longer valid. |
| `network_error` | 4 | curl failed, DNS failed, or timeout. |
| `rest_error` | 4 | 5xx response from the WP site. |
| `server_unsupported` | 4 | Plugin disabled, WP < 6.9, or missing ability namespace. |
| `ability_execution_failed` | 5 | Ability returned `WP_Error` (e.g., `wp_mcp_sandbox_violation`). |
| `schema_validation_failed` | 5 | Local `--input` JSON failed validation. |
| `script_error` | 5 | The `code` script failed, exited non-zero or timed out. |
| `call_budget_exceeded` | 5 | A `code` script exceeded `--max-calls`. |
| `confirmation_required` | 6 | Destructive operation invoked without `--yes` in non-TTY mode. |
| `internal_error` | 1 | Unexpected CLI failure (e.g., failed to write config). |

## Filesystem layout

```text
$WPMCP_HOME                          (default: $HOME/.wp-mcp, mode 0700)
├── sites.json                       profile registry, mode 0600
├── credentials/
│   └── <site>.json                  application password, mode 0600
├── cache/                           reserved for future use
└── locks/                           reserved for future use
```

## REST endpoints consumed

The CLI does NOT wrap MCP. It consumes the WP-MCP REST shim directly:

| Endpoint | Method | Used by |
| -------- | ------ | ------- |
| `/wp-json/wp/v2/users/me` | GET | `auth login` credential probe |
| `/wp-json/wp-abilities/v1/abilities` | GET | `discover` (paginated) |
| `/wp-json/wp-abilities/v1/abilities/<ns>/<name>` | GET | `describe` |
| `/wp-json/wp-mcp/v1/abilities/<ns>/<name>/run` | POST | `run`, `code` |

The `wp-mcp/v1/abilities/.../run` endpoint is provided by the WP-MCP plugin in `includes/cli-rest-shim.php`. Adding the endpoint does not require an MCP client update.

## Input handling

`run --input` accepts:

- inline JSON string: `--input '{"path":"/Users"}'`
- `@<path>`: read from a file
- `-`: read from STDIN
- omitted: defaults to `null`

Local JSON validation MUST occur before any network call.

## Code mode

```text
wp-mcp code <file|-> [--dry-run|--read-only|--yes] [--max-calls <n>] [--timeout <s>] [--verbose]
```

Runs a local PHP 8.0+ script that calls abilities through the same REST shim
as `wp-mcp run`. The script is local code, not a sandbox.

| Flag | Default | Effect |
| ---- | ------- | ------ |
| `--dry-run` | off | Stub every ability call. Metadata search/describe still run. |
| `--read-only` | off | Execute only `readonly=true` abilities; stub all writes. |
| `--yes` / `-y` | off | Allow `destructive=true` abilities. |
| `--max-calls <n>` | 100 | Maximum ability calls, 1–1000. |
| `--timeout <s>` | 120 | Wall-clock limit, 1–3600. |
| `--verbose` | off | Print one line per call in human mode. |

Without a mode flag, readonly abilities and non-destructive writes execute;
a destructive call exits 6 unless `--yes` is set. `--dry-run`, `--read-only`
and `--yes` are mutually exclusive where they overlap. `--json` does not
imply `--yes`. `--yes` only permits a destructive call; it does not inject
the ability's `confirm_*` arguments. `--quiet` suppresses the script's
stdout/stderr and the human summary; with `--json` the envelope is still
emitted.

The script API is `wp_mcp_call()`, `wp_mcp_search()`, `wp_mcp_discover()`,
`wp_mcp_describe()`, `wp_mcp_log()`, `wp_mcp_is_dry_run()`,
`wp_mcp_is_read_only()` and `wp_mcp_site()`.

Success envelope:

```json
{
  "ok": true,
  "data": {
    "output": "...",
    "output_type": "text|json",
    "output_encoding": "utf8|base64",
    "stderr": "...",
    "stderr_truncated": false,
    "calls": [],
    "logs": [],
    "dry_run": false,
    "read_only": false,
    "duration_ms": 123,
    "truncated": false
  },
  "meta": {
    "site": "...",
    "origin": "...",
    "script_sha256": "..."
  }
}
```

Errors use the normal error envelope. Code mode adds `script_error` and
`call_budget_exceeded` (exit 5). A wall-clock timeout is reported as
`script_error`. The full workflow and the exact mode semantics are in
[`docs/code-mode.md`](code-mode.md).

The `WPMCP_CODE_*` variables are internal to the child bootstrap and are not
a stable user API.
