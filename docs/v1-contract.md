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
| 5 | ability_execution_failed, schema_validation_failed |
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

## Stable error codes

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
| `/wp-json/wp-mcp/v1/abilities/<ns>/<name>/run` | POST | `run` |

The `wp-mcp/v1/abilities/.../run` endpoint is provided by the WP-MCP plugin in `includes/cli-rest-shim.php`. Adding the endpoint does not require an MCP client update.

## Input handling

`run --input` accepts:

- inline JSON string: `--input '{"path":"/Users"}'`
- `@<path>`: read from a file
- `-`: read from STDIN
- omitted: defaults to `null`

Local JSON validation MUST occur before any network call.
