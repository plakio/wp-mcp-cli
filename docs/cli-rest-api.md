# CLI REST API (WP-MCP plugin)

This document is the authoritative reference for the REST endpoint that
`wp-mcp-cli` (and any HTTP client) consumes to execute abilities
without going through JSON-RPC/MCP.

## Endpoint

```
POST /wp-json/wp-mcp/v1/abilities/<namespace>/<name>/run
```

**Authentication**: WordPress Application Passwords (HTTP Basic). The
user must hold `manage_options` (single-site) or `is_super_admin()`
(multisite).

**Body** (strict):

```json
{ "input": <any JSON value or null> }
```

Any field other than `input` results in `400 Bad Request`. A missing
body or `input: null` is allowed.

**Path constraint**: `ability_name` matches
`^[a-z0-9-]+(?:/[a-z0-9-]+)+$`. Examples:

- `wp-mcp/list-directory`
- `wp-mcp/execute-php`
- `wp-mcp/gutenberg-create-pending-batch`
- `wc-list-products`

## Successful response

The response is the raw ability result wrapped by `rest_ensure_response()`.
The shape depends on the ability. Example:

```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "entries": [
    { "name": "wp-content", "type": "dir", "size": 4096 },
    { "name": "wp-mcp-sandbox", "type": "dir", "size": 256 }
  ],
  "total": 2,
  "path": "/Users/.../public"
}
```

## Error response

WordPress REST error envelope:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json

{
  "code": "wp_mcp_ability_not_found",
  "message": "Ability \"wp-mcp/foo\" is not registered.",
  "data": { "status": 404 }
}
```

### Stable error codes

| Code | HTTP | When |
| ---- | ---- | ---- |
| `wp_mcp_disabled` | 403 | Plugin is disabled on the site. |
| `wp_mcp_forbidden` | 403 | User lacks `manage_options`. |
| `wp_mcp_ability_not_found` | 404 | Ability is not registered. |
| `wp_mcp_ability_hidden` | 404 | Ability exists but `meta.show_in_rest !== true`. |
| `wp_mcp_path_missing` | 404 | Filesystem ability: path does not exist. |
| `wp_mcp_path_unreadable` | 404 | Filesystem ability: path not readable. |
| `wp_mcp_path_unwritable` | 404 | Filesystem ability: path not writable. |
| `wp_mcp_sandbox_violation` | 403 | Tried to access outside `wp-content/wp-mcp-sandbox/`. |
| `wp_mcp_sandbox_only` | 403 | Operation restricted to the sandbox. |
| `wp_mcp_path_blocked` | 403 | Path is on the deny-list. |
| `wp_mcp_invalid_input` | 400 | Input failed the schema or business validation. |
| `wp_mcp_missing_field` | 400 | Required input field missing. |
| `wp_mcp_invalid_id` | 404 | Resource ID is malformed. |
| `wp_mcp_missing_id` | 400 | Resource ID is required. |
| `wp_mcp_production_block` | 403 | Operation blocked by production guard. |
| (anything else) | 500 | Unexpected error. |

## Discovery (used by `wp-mcp discover`)

The CLI uses the WordPress core Abilities API namespace:

```
GET /wp-json/wp-abilities/v1/abilities
GET /wp-json/wp-abilities/v1/abilities/<namespace>/<name>
```

These routes are provided by WordPress 6.9 core and require no plugin
modifications. Pagination follows standard `?per_page=N&page=N` rules.

## CORS

CORS is **not** enabled by default. CLI calls originate from the local
machine, so CORS is not needed. If a web client requires it, set the
standard WP CORS filters (`rest_pre_serve_request`, etc.) — the WP-MCP
plugin does not block them.

## Versioning

The endpoint version is encoded in the namespace (`wp-mcp/v1`). Breaking
changes will be introduced under a new namespace (`wp-mcp/v2`).
