# Design: `wp-mcp code` — local code mode for WP-MCP

- **Status:** Implemented (MVP) on `main`
- **Target:** `wp-mcp-cli` 0.2.0 (additive minor)
- **Last updated:** 2026-11-03
- **Related:** [`docs/cli-rest-api.md`](cli-rest-api.md), [`docs/v1-contract.md`](v1-contract.md), [`skills/wp-mcp/SKILL.md`](../skills/wp-mcp/SKILL.md)
- **Plugin changes required:** none for v1

---

## 1. Decision summary

Add a `wp-mcp code` command that runs a **local PHP script** which calls
WP-MCP abilities through the existing REST shim.

The script runs on the operator's machine, not on the WordPress site. The site
sees only normal `POST /wp-json/wp-mcp/v1/abilities/<name>/run` calls, so the
plugin's per-user access rules, ability permissions, input validation and
`confirm_*` requirements remain in force.

This is **code mode for agents with a shell** (Claude Code, Codex, Cursor,
OpenCode, CI). It is not a replacement for the MCP `discover → info → execute`
ladder used by clients without a code runner (Claude Desktop, ChatGPT).

The design deliberately does **not** add a code runtime to the WordPress
plugin. PHP has no safe per-request sandbox, and a server-side `run-script`
would duplicate `execute-php` while making arbitrary code execution the normal
path. The CLI is the correct place because it can run code locally, keep
credentials local, and give the human a review point before writes.

### Final v1 deltas from this draft

The implemented MVP keeps the same command and safety goals, with these
corrections:

- `--read-only` executes only `annotations.readonly === true` and stubs
  **all** writes, including non-destructive ones such as `write-file` and
  `content-update-post`. `destructive` is only the `--yes` gate in the
  default mode.
- `--read-only` is the real-data planning mode. `--dry-run` stubs every
  ability call; metadata search/describe still run.
- `wp_mcp_search()` reuses the plugin's compact
  `mcp-adapter/discover-abilities` ability; `wp_mcp_describe()` uses the CLI's
  ability description route. There is no local catalog cache in v1.
- A common local bridge (`wp-mcp __code-bridge`) owns modes, budgets,
  annotations and the call log. The PHP, Python and Node clients are thin
  wrappers around it.
- `--runtime php|python|node` is supported. The runtime is inferred from the
  file extension or selected explicitly; the bridge itself only needs Bash,
  `jq` and `curl`, so Python/Node users do not need PHP.
- `--allow <ability>` permits specific destructive abilities as an alternative
  to the blanket `--yes`. It is repeatable and mutually exclusive with
  `--yes`.
- The bridge calls `wp-mcp --json run`/`describe` instead of duplicating the
  HTTP client, URL builder and error table.
- The call log is append-only JSONL so a killed script still reports the
  calls it made.
- Credentials were hardened first: no stored password in child argv or the
  environment, curl config on STDIN, and request/response bodies kept out of
  argument lists.
- Tests live in `tests/code.sh` (no site required) and `tests/hardening.sh`.

---

## 2. Problem

WP-MCP already solved the catalog-size problem: the MCP server exposes three
tools, a compact manifest (~5 KB on a real 869-ability site), ranked search and
on-demand definitions. The remaining cost for multi-step work is:

1. **Round trips.** `discover → get-ability-info → execute` is three calls per
   task; a batch of N writes is N more calls.
2. **Intermediate results in context.** A 100-row list or a large file page
   flows through the model unless the caller uses `fields`/pagination
   perfectly.
3. **Loops and conditionals.** "For each draft post, do X" is N model turns.

Code mode addresses exactly those three costs. It does not address the
catalog-size problem, which is already solved.

The existing `wp-mcp run` command can execute one ability at a time, and an
agent with a shell can already loop over it in Bash. That is technically code
mode, but Bash + `jq` is a poor language for JSON, error handling and
conditionals. A first-class PHP runner is the natural fit for a WordPress
developer's machine.

---

## 3. Goals and non-goals

### Goals

- Run a local script that can call any WP-MCP ability, with the site's access
  rules and permissions unchanged.
- Keep intermediate data local: only what the script prints reaches the model.
- Give the human a review point before destructive writes (`--dry-run`,
  `--read-only`, `--yes`).
- Bound runaway scripts (call budget, timeout, output limits).
- Preserve the existing CLI contracts: JSON envelopes, exit codes, site
  profiles, `WPMCP_HOME`, `--json`, `--quiet`, `--site`.
- Require no plugin changes and no new runtime on the WordPress host.

### Non-goals

- A sandbox. The script runs as the local user with the local user's
  permissions. This is documented and is not a security boundary.
- A replacement for `wp-mcp run`, `discover` or `describe`.
- A replacement for the MCP server or its three-tool ladder.
- Remote code execution on the WordPress site. That is `wp-mcp/execute-php`
  and is out of scope.
- Node/TypeScript support in v1. It can be added later as an optional runtime.
- A GUI, a REPL, or persistent sessions.

---

## 4. Why the CLI is the right place

| Concern | Plugin | CLI |
|---|---|---|
| Where the script runs | WordPress, as admin | Operator's machine |
| Sandbox | Not possible in PHP per request | Local process; no server blast radius |
| Human review before writes | Hard: one tool call | Natural: `--dry-run` then `--yes` |
| Access rules | Must be re-implemented in the runtime | Already enforced by the REST shim |
| Metrics | Must be instrumented in the runtime | Already recorded by the plugin when metrics are enabled |
| New dependencies | Node/V8 or a PHP `eval` | PHP 8.0+ (already common for WP devs) |
| Changes to the plugin | New ability, runtime, tests, docs | None for v1 |

The CLI already has the infrastructure this command needs:

- site profiles and credential storage (`shared/auth.sh`, `shared/config.sh`);
- an HTTP client with stable error classification (`shared/http.sh`);
- URL building, including `WPMCP_REST_PLAIN` (`shared/url.sh`);
- JSON envelopes and exit codes (`shared/output.sh`, `shared/errors.sh`);
- a single-file distribution built by `compile.sh`;
- smoke tests against a real site (`tests/smoke.sh`).

`wp-mcp code` is the missing runtime, not a new architecture.

---

## 5. User contract

### 5.1 Command

```text
wp-mcp code <file|-> [flags]
```

- `<file>`: path to a `.php` script.
- `-`: read the script from STDIN. The CLI writes it to a temporary file so
  PHP can run it normally.

The command is additive. No existing command changes behavior.

### 5.2 Flags

| Flag | Default | Meaning |
|---|---|---|
| `--dry-run` | off | Execute nothing. Every ability call is logged and returns a stub. |
| `--read-only` | off | Execute only `readonly=true` abilities; stub every write. |
| `--yes` / `-y` | off | Allow all destructive abilities to execute. |
| `--allow <ability>` | none | Allow one destructive ability. Repeatable; mutually exclusive with `--yes`. |
| `--max-calls <n>` | 100 | Maximum ability calls in one script. Range 1–1000. |
| `--timeout <seconds>` | 120 | Maximum wall time. Range 1–3600. |
| `--runtime <r>` | inferred | `php`, `python` or `node`. Inferred from `.php`, `.py`, `.js`, `.mjs`, `.cjs`; stdin defaults to `php`. |
| `--verbose` | off | Include per-call input sizes in the log. Never includes bodies or credentials. |
| `--help` / `-h` | — | Show command help. |

Global flags (`--json`, `--quiet`, `--site`) keep their existing behavior and
must appear before the command, as with every other command.

### 5.3 Examples

```bash
# Read-only script
wp-mcp code audit.php --read-only

# Python or Node script (runtime inferred from the extension)
wp-mcp code audit.py --read-only
wp-mcp code audit.js --read-only

# Plan writes without executing them
wp-mcp code migrate.php --dry-run

# Execute reads, stub writes
wp-mcp code migrate.php --read-only

# Execute everything, including destructive abilities
wp-mcp code migrate.php --yes

# Or allow only specific destructive abilities
wp-mcp code migrate.php --allow wp-mcp/content-delete-post

# Script from STDIN (useful for agents)
wp-mcp code - --dry-run <<'PHP'
<?php
$posts = wp_mcp_call('wp-mcp/content-list-posts', [
    'per_page' => 5,
    'fields'   => ['id', 'title'],
]);
foreach ($posts['posts'] as $post) {
    echo $post['id'] . "\t" . $post['title'] . "\n";
}
PHP
```

### 5.4 Script lifecycle

1. Parse flags and resolve the active site (`wpmcp_auth_require`).
2. Select the runtime (`php`, `python` or `node`) and check its executable.
3. Extract the thin clients to `$WPMCP_HOME/lib/code` if their version changed.
4. Create temporary call-log/state files with mode `0600`.
5. Run the script with the selected runtime. The client talks to the common
   `wp-mcp __code-bridge` command for calls, metadata and modes.
6. Read the call log/state and the script's stdout/stderr.
7. Emit the success or error envelope and exit with the mapped code.
8. Remove the temporary script (if read from STDIN), state and log.

---

## 6. Script API

The bootstrap defines the following functions in the global namespace. They are
available before the user's script runs because the CLI uses
`auto_prepend_file`.

### 6.1 Functions

```php
/**
 * Call one ability through the REST shim.
 *
 * @param string $ability  Namespaced ability name, e.g. "wp-mcp/content-list-posts".
 * @param mixed  $input    Ability input. Must match the ability's input schema.
 * @return mixed           Decoded ability result.
 *
 * @throws WPMCP_Code_Error on transport, HTTP, confirmation or budget errors.
 */
function wp_mcp_call(string $ability, mixed $input = null): mixed;

/**
 * Search the active site's ability catalog through the plugin's compact
 * discovery ability. Rows are ranked and already filtered by the plugin's
 * access rules.
 *
 * @return array<int, array{
 *   name:string,label:string,summary:string,category:string,source:string,
 *   readonly:bool,destructive:bool,requires_confirmation:bool
 * }>
 */
function wp_mcp_search(string $query, int $limit = 10, ?string $cursor = null): array;

/**
 * Return the full discovery response (mode, abilities, total, next_cursor).
 */
function wp_mcp_discover(array $options = []): array;

/**
 * Fetch one ability definition (name, label, description, input_schema,
 * output_schema, meta.annotations) through the CLI's describe route.
 */
function wp_mcp_describe(string $ability): array;

/** Append a message to the script log (visible in data.logs). */
function wp_mcp_log(string $message): void;

/** True when the run is --dry-run. */
function wp_mcp_is_dry_run(): bool;

/** True when the run is --read-only. */
function wp_mcp_is_read_only(): bool;

/** Active site metadata: ['name' => string, 'url' => string, 'origin' => string]. */
function wp_mcp_site(): array;
```

### 6.2 Error class

PHP 8.0-compatible; no `readonly` properties or enums.

```php
final class WPMCP_Code_Error extends RuntimeException
{
    public string $errorCode;
    public int $exitCode;
    public ?int $httpStatus;
    public ?string $remoteCode;
    public array $details;

    public function __construct(
        string $errorCode,
        string $message,
        int $exitCode = 5,
        ?int $httpStatus = null,
        ?string $remoteCode = null,
        array $details = []
    ) {
        parent::__construct($message);
        $this->errorCode = $errorCode;
        $this->exitCode = $exitCode;
        $this->httpStatus = $httpStatus;
        $this->remoteCode = $remoteCode;
        $this->details = $details;
    }
}
```

The bootstrap registers an uncaught-exception handler that writes the error to
the call log and exits with `exitCode`. The CLI uses that to build the error
envelope. A PHP fatal error (parse error, OOM, timeout) is mapped by the CLI to
`script_error` (exit 5) with the stderr tail.

### 6.3 Environment

The CLI passes non-secret configuration through the child environment:

| Variable | Meaning |
|---|---|
| `WPMCP_CODE_CLI` | `wp-mcp` executable used by the bridge for ability calls. |
| `WPMCP_CODE_BRIDGE_CLI` | Real `wp-mcp` executable used by the thin clients for `__code-bridge`. |
| `WPMCP_CODE_STATE` | Path to the bridge budget/annotation state JSON. |
| `WPMCP_CODE_SCRIPT` | Script path (used by the Python runner). |
| `WPMCP_CODE_RUNTIME` | `php`, `python` or `node`. |
| `WPMCP_CODE_SITE` | Active profile name. |
| `WPMCP_CODE_SITE_URL` | The profile's `siteUrl`, including any subdirectory. |
| `WPMCP_CODE_ORIGIN` | Scheme + host + port (for `wp_mcp_site()`). |
| `WPMCP_CODE_LOG` | Path to the append-only JSONL call log. |
| `WPMCP_CODE_DRY_RUN` | `1` or `0`. |
| `WPMCP_CODE_READ_ONLY` | `1` or `0`. |
| `WPMCP_CODE_ALLOW_DESTRUCTIVE` | `1` or `0` for `--yes`. |
| `WPMCP_CODE_ALLOW` | Newline-separated `--allow` ability names. |
| `WPMCP_CODE_MAX_CALLS` | Integer. |
| `WPMCP_CODE_TIMEOUT` | Integer seconds. |
| `WPMCP_CODE_STARTED_AT` | Unix timestamp used for the bridge timeout. |
| `WPMCP_CODE_VERBOSE` | `1` or `0`. |
| `WPMCP_REST_PLAIN` | Inherited; `1` uses `?rest_route=`. |

The application password is **never** passed to child processes in argv or
in the environment. Neither the clients nor the bridge read it: each child
`wp-mcp run`/`describe` reads the existing `0600` credentials file.

---

## 7. Safety model

### 7.1 Threat model

The script is generated by an AI agent, possibly influenced by untrusted
content on the site (posts, form submissions, reviews). The script runs on the
operator's machine with the operator's privileges. The site is a development or
staging WordPress with an admin-level application password.

The goal is not to sandbox the script. It is to:

1. keep the site's access rules and ability permissions in force;
2. give the human a review point before writes;
3. bound runaway loops and accidental mass operations;
4. keep credentials out of argv, logs and model context.

### 7.2 Modes

| Mode | Reads (`readonly=true`) | Non-destructive writes | Destructive writes | Use case |
|---|---|---|---|---|
| default | execute | execute | fail with `confirmation_required` (exit 6) | normal execution |
| `--dry-run` | stub + log | stub + log | stub + log | static scripts / call graph |
| `--read-only` | execute | stub + log | stub + log | real-data plan |
| `--yes` | execute | execute | execute | approved batch |

`--dry-run` returns a stub for every call:

```php
['__wp_mcp_dry_run' => true, 'ability' => $ability, 'input' => $input]
```

`--read-only` returns a different stub for every non-readonly ability,
including non-destructive writes:

```php
['__wp_mcp_skipped' => true, 'ability' => $ability, 'reason' => 'not_readonly']
```

Scripts that need real data to plan should use `--read-only`.

### 7.3 Annotations and confirmations

Before each call, `wp_mcp_call` resolves the ability's annotations through
the CLI's `describe` route (the native ability record) and caches them in the
bridge state. Search results also seed the annotation cache.

- In `--read-only`, only `readonly === true` executes; every other ability is
  stubbed and logged as `skipped`.
- In default mode, `destructive === true` without `--yes` throws
  `confirmation_required` (exit 6).
- If `destructive` cannot be determined, **fail closed**: treat the ability as
  destructive and require `--yes`.
- If the ability is unknown, throw `ability_not_found` (exit 2).

`--yes` only permits the call. It does **not** inject `confirm_*` arguments.
The script must pass them explicitly, and the ability's schema still validates
them. This preserves the plugin's contract: the confirmation flag is a caller
assertion, and the CLI does not invent it.

This is a deliberate departure from `wp-mcp run`, which skips its interactive
confirmation when `--json` is set. In `code`, `--json` never implies `--yes`.

### 7.4 Budgets and timeouts

- `--max-calls` (default 100, max 1000): `wp_mcp_call` increments a counter and
  throws `call_budget_exceeded` (exit 5) when exceeded.
- `--timeout` (default 120 s, max 3600): the CLI passes
  `max_execution_time` to PHP and the bootstrap checks elapsed time before each
  call. Long HTTP requests use a per-call timeout of `min(30, remaining)`.
- Output: the CLI captures stdout/stderr and truncates the envelope at 1 MiB,
  reporting `truncated: true`. The script can write large data to a local file
  and print only the path.

### 7.5 Credentials

- The credentials file is read by the bootstrap, never by the user's script
  directly. (PHP can still read any local file; this is not a sandbox. The
  convention keeps accidental leaks out of scripts.)
- The `Authorization` header is never logged.
- The call log records ability names, statuses, durations and byte counts only.
  It does not record inputs or response bodies.
- `--verbose` records input **sizes**, not input values.
- The CLI does not print the credentials path in the envelope.

### 7.6 Prompt injection

A script generated from site content can contain harmful operations. The
mitigations are:

- default fail-closed for destructive abilities;
- `--dry-run` and `--read-only` for review;
- the CLI prints the script path and a SHA-256 hash before execution in human
  mode, and includes only the hash in `meta` in JSON mode;
- the agent skill instructs agents to show the script and the dry-run plan to
  the human before using `--yes`;
- the site's access rules still apply, so a compromised script cannot exceed
  the profile's permissions.

The CLI cannot enforce human review. It can make the safe path the default and
the dangerous path explicit.

### 7.7 What this is not

- It is not a sandbox.
- It is not a security boundary.
- It is not a replacement for the plugin's access rules.
- It is not a way to run code on the site. Use `wp-mcp/execute-php` for that,
  explicitly.

---

## 8. Output contract

### 8.1 JSON envelope

Success (STDOUT, `--json`):

```json
{
  "ok": true,
  "data": {
    "output": "…",
    "output_type": "text",
    "calls": [
      {
        "seq": 1,
        "ability": "wp-mcp/content-list-posts",
        "status": "ok",
        "http_status": 200,
        "duration_ms": 42,
        "request_bytes": 87,
        "response_bytes": 1847,
        "destructive": false,
        "error_code": null
      }
    ],
    "logs": ["Drafts: 3"],
    "dry_run": false,
    "read_only": false,
    "duration_ms": 1234,
    "truncated": false
  },
  "meta": {
    "site": "dev.localhost",
    "origin": "https://dev.localhost",
    "script_sha256": "9f2c…"
  }
}
```

- `script_sha256` lets the caller verify which script ran without putting the
  script body in the envelope. The local path is not included.
- If the script's stdout is valid JSON, `output` is the parsed value and
  `output_type` is `json`. Otherwise `output` is the raw text and
  `output_type` is `text`.
- `calls` is metadata only. It never contains inputs or response bodies.
- `logs` contains messages from `wp_mcp_log()`.

Error (STDERR, `--json`):

```json
{
  "ok": false,
  "error": {
    "code": "confirmation_required",
    "message": "Ability 'wp-mcp/content-delete-post' is destructive. Re-run with --yes.",
    "retryable": false,
    "remoteCode": null,
    "details": {
      "ability": "wp-mcp/content-delete-post",
      "seq": 3
    }
  }
}
```

### 8.2 Call log

The bootstrap writes `WPMCP_CODE_LOG` atomically:

```json
{
  "version": 1,
  "dry_run": false,
  "read_only": false,
  "started_at": "2026-11-03T15:00:00+00:00",
  "finished_at": "2026-11-03T15:00:02+00:00",
  "duration_ms": 1234,
  "calls": [],
  "logs": [],
  "error": null
}
```

On error, `error` is `{code, message, exit_code, http_status, remote_code,
details}`.

### 8.3 Human output

- Print the script's stdout as-is.
- Print a one-line summary to STDERR unless `--quiet`:
  `3 calls: 1 read, 2 writes (dry-run)`.
- On error, print `Error: <message>` to STDERR.

### 8.4 Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | `internal_error` (missing bootstrap, missing PHP, log failure) |
| 2 | `usage_error`, `site_required`, `site_not_found`, `ability_not_found` |
| 3 | `auth_required`, `auth_denied`, `auth_expired` |
| 4 | `network_error`, `rest_error` |
| 5 | `script_error`, `ability_execution_failed`, `schema_validation_failed`, `call_budget_exceeded` |
| 6 | `confirmation_required` |

These match the existing `docs/v1-contract.md` catalog. New codes are additive
and must be documented there.

---

## 9. Implementation

> The implemented MVP follows the deltas in section 1: the thin PHP, Python
> and Node clients call the common `wp-mcp __code-bridge` command, which
> invokes `wp-mcp --json run`/`describe` and uses the plugin's compact
> discovery. The direct PHP HTTP layer and disk catalog cache described below
> are retained as the original design, not as the current code path.

### 9.1 Files

| File | Change |
|---|---|
| `commands/code` | New. Flag parsing, runtime check, execution, envelope. |
| `shared/code.sh` | New. Bootstrap extraction, PHP checks, log reading, rendering. |
| `main` | Add `code` to the help text and command router. |
| `commands/doctor` | Report PHP availability for `code` as a non-fatal warning. |
| `tests/smoke.sh` | Add code-mode cases. |
| `README.md` | Command list, requirements, examples. |
| `docs/v1-contract.md` | Command contract, flags, envelope, exit codes. |
| `docs/code-mode.md` | This document. |
| `skills/wp-mcp/SKILL.md` | Add the code-mode workflow. |
| `compile.sh` | No change if the bootstrap is embedded as a heredoc. |

### 9.2 `commands/code`

Responsibilities:

1. Parse flags (`--dry-run`, `--read-only`, `--yes`, `--max-calls`,
   `--timeout`, `--runtime`, `--verbose`, `--help`).
2. Reject incompatible combinations: `--dry-run` + `--yes` is a usage error;
   `--read-only` + `--yes` is a usage error (pick one mode).
3. Resolve the script path. `-` reads STDIN into a `mktemp` file with mode
   `0600`; register a trap to remove it.
4. `wpmcp_auth_require`.
5. `wpmcp_code_require_php`.
6. `wpmcp_code_extract_bootstrap`.
7. Create the log file (`mktemp`, `0600`).
8. Export the environment and run PHP.
9. Read the log; build the envelope; print; exit.

### 9.3 `shared/code.sh`

Functions:

```bash
wpmcp_code_require_php()        # command -v php; php -r version check >= 8.0
wpmcp_code_bootstrap_path()     # $WPMCP_HOME/lib/code-bootstrap.php
wpmcp_code_extract_bootstrap()  # write embedded heredoc if version changed
wpmcp_code_run()                # php -d auto_prepend_file=... script
wpmcp_code_read_log()           # jq -c . "$WPMCP_CODE_LOG" or "{}"
wpmcp_code_render()             # human/JSON envelope
wpmcp_code_cleanup()            # trap: remove temp script and log
```

The bootstrap version is a constant in `commands/code`:

```bash
WPMCP_CODE_BOOTSTRAP_VERSION="1"
```

The extraction writes `$WPMCP_HOME/lib/code-bootstrap.php` and
`$WPMCP_HOME/lib/code-bootstrap.version`. If the version differs, rewrite both.
Create `$WPMCP_HOME/lib` with `mkdir -p` and mode `0700`. Use a temp file +
`mv` for atomicity and `chmod 600` on the bootstrap.

### 9.4 Bootstrap

Embed the PHP bootstrap as a quoted heredoc inside `commands/code`:

```bash
cat > "$tmp_bootstrap" <<'PHP'
<?php
// wp-mcp-cli code bootstrap (AGPL-3.0-or-later)
// ...
PHP
```

Why a heredoc instead of `lib/code-bootstrap.php`:

- `compile.sh` concatenates `shared/*` and `commands/*`; a separate PHP file
  would need a new build step or a second distribution artifact.
- The CLI is distributed as a single `wp-mcp.sh`. The heredoc preserves that.

The bootstrap must be PHP 8.0-compatible:

- no `readonly` properties (8.1);
- no enums (8.1);
- no `array_is_list` (8.1);
- `str_contains`, `match`, `?->` are fine (8.0).

Register a shutdown function that writes the call log even when the script
dies from a fatal error, a timeout or an uncaught exception. The CLI must be
able to distinguish "script failed before any call" from "script failed after
N calls".

### 9.5 HTTP layer

`wp_mcp_call` builds:

```text
POST {origin}/wp-json/wp-mcp/v1/abilities/{ns}/{name}/run
Body: {"input": <json>}
Auth: Basic base64(user:app_password)
```

When `WPMCP_REST_PLAIN=1`, use
`{origin}/index.php?rest_route=/wp-mcp/v1/abilities/{ns}/{name}/run`.

Prefer the `curl` extension; fall back to `file_get_contents` with a stream
context (`ignore_errors`, `timeout`). Parse the status from
`curl_getinfo` or `$http_response_header`.

Error mapping (mirror `shared/http.sh`):

| Situation | `errorCode` | Exit |
|---|---|---|
| 401 | `auth_required` | 3 |
| 403 `wp_mcp_forbidden` | `auth_denied` | 3 |
| 404 `wp_mcp_ability_not_found` | `ability_not_found` | 2 |
| 404 `wp_mcp_ability_hidden` | `ability_not_found` | 2 |
| 400 `wp_mcp_invalid_input` | `schema_validation_failed` | 5 |
| 5xx | `ability_execution_failed` | 5 |
| curl/stream failure | `network_error` | 4 |

The `remoteCode` field carries the WordPress code when present.

### 9.6 Catalog cache

`wp_mcp_search` and `wp_mcp_describe` use the native WordPress routes:

```text
GET /wp-json/wp-abilities/v1/abilities?per_page=100&page=N
GET /wp-json/wp-abilities/v1/abilities/{ns}/{name}
```

Cache the full catalog at
`$WPMCP_CACHE_DIR/abilities-<site>.json` with a TTL of one hour. The cache is
local, contains no credentials, and is safe to delete. The script can force a
refresh by deleting the file or by setting `WPMCP_CODE_REFRESH_CATALOG=1`
(optional; document it if implemented).

The plugin's access rules filter these routes, so the cache only contains
abilities the profile can see.

### 9.7 `main` and help

Add `code` to the command list:

```text
code        Run a local PHP script that calls abilities
```

Add a `code)` case in the router and a `wpmcp_display_command_help code`
section with the flags and the safety modes.

### 9.8 `doctor`

Add a non-fatal check:

```text
OK/WARN  php available (code)
```

A missing PHP must not fail `doctor` for users who only use `run`/`discover`.
Use a `WARN` status or print an informational line; do not increment `failed`.

### 9.9 `compile.sh`

No change. The heredoc lives inside `commands/code`, which `compile.sh` already
concatenates.

---

## 10. Test plan

### Smoke tests (`tests/smoke.sh`)

Use the existing disposable-site setup.

1. `wp-mcp code --help` exits 0 and mentions `--dry-run`.
2. `wp-mcp code` with a missing file exits 2 (`usage_error`).
3. Read-only script:
   ```php
   <?php
   $r = wp_mcp_call('wp-mcp/list-directory', ['path' => '/']);
   echo count($r['entries']);
   ```
   → exit 0, `ok:true`, one call with `status: "ok"`.
4. Destructive script without `--yes` → exit 6, no write.
5. Destructive script with `--dry-run` → exit 0, `status: "dry_run"`, no write.
6. Destructive script with `--read-only` → exit 0, `status: "skipped"`, no write.
6b. Non-destructive write (`content-update-post`, `write-file`) with
    `--read-only` → exit 0, `status: "skipped"`, no write.
7. `--max-calls 1` with two calls → exit 5, `call_budget_exceeded`.
8. Unknown ability → exit 2, `ability_not_found`.
9. Invalid ability name (`../etc/passwd`) → exit 2, `usage_error`.
10. `--json` without `--yes` on a destructive call → exit 6 (does not skip the
    confirmation like `run` does).
11. `wp_mcp_search('post')` returns at least one row; `wp_mcp_describe()` on the
    first row returns `input_schema`.
12. Script with a PHP parse error → exit 5, `script_error`, stderr tail in the
    error details.
13. Python and Node read scripts → exit 0 with the same output and modes;
    `--runtime` overrides the extension inference.
14. `--allow wp-mcp/content-delete-post` allows that destructive ability but
    still blocks another destructive ability with exit 6.
15. `--allow` with `--yes` is a usage error.

### Security tests

- The password never appears in `ps` output, the envelope, or the call log.
- The call log contains no input or response bodies.
- Unknown annotations fail closed.
- `--dry-run` performs zero ability executions. Metadata search/describe may
  still POST to the REST shim; verify with a request counter or the site's
  logs that no execution route is called.
- A script cannot bypass access rules: use a profile whose access rules deny an
  ability and confirm the REST shim returns `wp_mcp_ability_hidden`.

### Unit tests

- `php -l` on the extracted bootstrap.
- Pure helpers: ability-name validation, URL building, log serialization,
  annotation cache. These can be tested without a site by including the
  bootstrap in a PHP test harness and stubbing the HTTP function.
- `compile.sh` output contains the bootstrap heredoc exactly once.

### Manual acceptance

- Run a 100-post audit script on a disposable site; confirm only the summary
  reaches the terminal.
- Run a 10-post write script with `--dry-run`, review the plan, then `--yes`.
- Kill the script with `--timeout 2`; confirm exit 5 and no orphan process.

---

## 11. Documentation and skill

### `README.md`

- Add `code` to the command list.
- Add `php >= 8.0` under requirements, marked "only for `wp-mcp code`".
- Add a short "Code mode" section with the `--dry-run` → `--yes` flow.

### `docs/v1-contract.md`

- Add the command syntax, flags, envelope fields and exit codes.
- State that `--json` does not imply `--yes`.
- State that the script runs locally and is not a sandbox.

### `skills/wp-mcp/SKILL.md`

Add a section:

```markdown
## Code mode (batch and multi-step work)

Use `wp-mcp code` when a task needs loops, conditionals, pagination or many
ability calls. The script runs locally and calls the site through the REST shim.

1. Find abilities with `wp-mcp --json discover` / `wp-mcp describe`.
2. Write a PHP script using `wp_mcp_call()`, `wp_mcp_search()`,
   `wp_mcp_describe()` and `wp_mcp_log()`.
3. Run it with `--dry-run` and show the plan to the human.
4. Only after approval, run with `--yes`.

Never use `wp-mcp/execute-php` from a code script unless the human explicitly
asked for server-side execution. Prefer the narrowest ability.
```

### `guide-data/core/SKILL.md`

Add a one-line pointer to the code-mode section.

---

## 12. Rollout

- **Version:** 0.2.0 (minor, additive).
- **Feature flag:** none. The command is additive and requires explicit use.
- **Backward compatibility:** no changes to `auth`, `sites`, `discover`,
  `describe`, `run`, `doctor`, `skill`, `version`.
- **Release notes:** "Add `wp-mcp code` for local batch scripts. PHP 8.0+ is
  required for this command only. Scripts run on your machine; the site's
  access rules still apply."
- **Homebrew:** the existing tap workflow picks up the new version.
- **Rollback:** remove the command; no stored state, no migration.

### 12.1 Definition of done

- [ ] `wp-mcp code --help` documents every flag and safety mode.
- [ ] A read-only script runs end to end against a disposable site.
- [ ] A destructive script without `--yes` exits 6 and writes nothing.
- [ ] `--dry-run` performs zero ability executions (metadata search/describe
      may still run).
- [ ] `--read-only` executes only `readonly=true` abilities and stubs all
      writes, including non-destructive ones.
- [ ] `--max-calls` and `--timeout` are enforced.
- [ ] `--allow` permits only the named destructive abilities; it cannot be
      combined with `--yes`.
- [ ] PHP, Python and Node clients all use the same bridge and produce the
      same envelope/modes.
- [ ] The application password never appears in argv, logs or envelopes.
- [ ] Unknown annotations fail closed.
- [ ] `--json` does not imply `--yes`.
- [ ] `doctor` reports PHP, Python and Node availability without failing
      other commands.
- [ ] `compile.sh` produces a single `wp-mcp.sh` containing the bridge and
      client templates.
- [ ] README, `docs/v1-contract.md`, the skill and this document are updated.
- [ ] Smoke tests pass on a disposable site.
- [ ] The selected client passes its runtime syntax check.

---

## 13. Alternatives considered

### Server-side PHP script (`run-script` in the plugin)

Rejected for v1. It duplicates `execute-php`, cannot be sandboxed in PHP, and
would make arbitrary code execution the normal path. It also requires a new
ability, runtime, access-rule integration, metrics, tests and docs in the
plugin.

### Server-side JS sandbox

Rejected. PHP hosting rarely has Node/V8/QuickJS; a remote sandbox adds a
network dependency and sends site data to a third party. If a real sandbox is
ever needed, it belongs in a separate service that talks to the REST shim.

### Node runtime in the CLI

Deferred. Node is not guaranteed on WordPress developers' machines; PHP is.
The bootstrap API can be mirrored in a Node/TS runtime later, but v1 keeps one
runtime and one code path.

### Bash-only runner

Rejected. Bash + `jq` is poor for JSON, loops, error handling and large scripts.
PHP is the natural language for a WordPress developer and is already a
dependency of the site.

### Replacing the MCP three-tool ladder

Rejected. The ladder is the correct interface for clients without a code
runner and is what the compact-discovery benchmark validated. Code mode is an
additional path, not a replacement.

---

## 14. Open questions

1. **Should `--dry-run` be the default in non-TTY mode?**
   Recommendation: no. The default already fails closed on destructive
   abilities, and forcing dry-run would break automation that intentionally
   writes with `--yes`.
2. **Should `--yes` be per-ability?**
   A v2 feature: `--allow wp-mcp/content-update-post --allow ...`. For v1, a
   global `--yes` plus the dry-run review is enough.
3. **Should the call log include inputs?**
   No by default. `--verbose` records sizes only. Scripts can log what they
   choose with `wp_mcp_log()`.
4. **Should `wp_mcp_search` use the plugin's compact discovery?**
   Yes, if the plugin later exposes a REST discovery endpoint. For v1, the
   native catalog + local filter is sufficient and requires no plugin changes.
5. **Should the CLI generate TypeScript types?**
   v2. The PHP API is dynamic; types would help Node users, not PHP users.
6. **Should the command support `--arg key=value`?**
   Not in v1. Scripts can read environment variables or define constants.
   Adding it later is backward-compatible.
7. **Should the bootstrap be user-editable?**
   No. It is versioned and rewritten when it changes. Document it as internal.

---

## Appendix A: example scripts

### A.1 Audit draft posts

```php
<?php
$page = 1;
$drafts = [];

do {
    $result = wp_mcp_call('wp-mcp/content-list-posts', [
        'page'        => $page,
        'per_page'    => 100,
        'post_status' => 'draft',
        'fields'      => ['id', 'title', 'modified'],
    ]);

    $drafts = array_merge($drafts, $result['posts']);
    $page = $result['pagination']['next_page'] ?? null;
} while ($page !== null);

wp_mcp_log('Drafts: ' . count($drafts));

foreach ($drafts as $post) {
    echo $post['id'] . "\t" . $post['title'] . "\n";
}
```

### A.2 Batch update with a read-only plan

```php
<?php
$posts = wp_mcp_call('wp-mcp/content-list-posts', [
    'per_page'    => 50,
    'post_status' => 'draft',
    'fields'      => ['id', 'title'],
]);

foreach ($posts['posts'] as $post) {
    $result = wp_mcp_call('wp-mcp/content-update-post', [
        'id'             => $post['id'],
        'status'         => 'publish',
        'confirm_update' => true,
    ]);

    if (isset($result['__wp_mcp_skipped'])) {
        wp_mcp_log('Would publish ' . $post['id']);
        continue;
    }

    wp_mcp_log('Published ' . $post['id']);
}
```

Run it first with `--read-only`: the list call executes and every
`content-update-post` call is stubbed and logged. Review the plan, then run
with `--yes`. `--dry-run` would stub the list call too, so it cannot build a
data-driven plan.

### A.3 Search and describe

```php
<?php
$rows = wp_mcp_search('woocommerce orders', 5);

foreach ($rows as $row) {
    wp_mcp_log($row['name'] . ' — ' . $row['label']);
}

$schema = wp_mcp_describe('wp-mcp/content-list-posts');
wp_mcp_log('Required: ' . implode(', ', $schema['input_schema']['required'] ?? []));
```

### A.4 Error handling

```php
<?php
try {
    $result = wp_mcp_call('wp-mcp/content-get-post', ['id' => 123]);
} catch (WPMCP_Code_Error $e) {
    if ($e->errorCode === 'ability_not_found') {
        wp_mcp_log('Ability missing; falling back to a list query');
        $result = wp_mcp_call('wp-mcp/content-list-posts', [
            'search'   => 'Hello',
            'per_page' => 1,
            'fields'   => ['id', 'title'],
        ]);
    } else {
        throw $e;
    }
}
```

---

## Appendix B: bootstrap skeleton

> Historical skeleton. The implemented bootstrap lives in `shared/code.sh`,
> invokes `wp-mcp --json run`, and writes logs only to the append-only JSONL
> file (never to STDERR). The shape below is retained for design context.

This is the shape, not the final implementation.

```php
<?php
// wp-mcp-cli code bootstrap (AGPL-3.0-or-later)
// Version: 1

if (!defined('WPMCP_CODE_BOOTSTRAP')) {
    define('WPMCP_CODE_BOOTSTRAP', '1');

    final class WPMCP_Code_Error extends RuntimeException
    {
        public string $errorCode;
        public int $exitCode;
        public ?int $httpStatus;
        public ?string $remoteCode;
        public array $details;

        public function __construct(
            string $errorCode,
            string $message,
            int $exitCode = 5,
            ?int $httpStatus = null,
            ?string $remoteCode = null,
            array $details = []
        ) {
            parent::__construct($message);
            $this->errorCode = $errorCode;
            $this->exitCode = $exitCode;
            $this->httpStatus = $httpStatus;
            $this->remoteCode = $remoteCode;
            $this->details = $details;
        }
    }

    function wp_mcp_env(string $key, string $default = ''): string
    {
        $value = getenv($key);
        return $value === false ? $default : $value;
    }

    function wp_mcp_site(): array
    {
        return [
            'name'   => wp_mcp_env('WPMCP_CODE_SITE'),
            'origin' => wp_mcp_env('WPMCP_CODE_ORIGIN'),
        ];
    }

    function wp_mcp_is_dry_run(): bool
    {
        return wp_mcp_env('WPMCP_CODE_DRY_RUN') === '1';
    }

    function wp_mcp_is_read_only(): bool
    {
        return wp_mcp_env('WPMCP_CODE_READ_ONLY') === '1';
    }

    function wp_mcp_log(string $message): void
    {
        // Append to WPMCP_CODE_LOG under a lock; also write to STDERR.
        fwrite(STDERR, '[wp-mcp] ' . $message . PHP_EOL);
        // ... persist to the log ...
    }

    function wp_mcp_http(string $method, string $path, ?array $body = null): array
    {
        // Read credentials from WPMCP_CODE_CREDS_FILE.
        // Build the URL from WPMCP_CODE_ORIGIN, WPMCP_REST_PLAIN.
        // Use curl if available, else streams.
        // Return ['status' => int, 'body' => string].
    }

    function wp_mcp_describe(string $ability): array
    {
        // GET /wp-abilities/v1/abilities/<name>; cache in memory.
    }

    function wp_mcp_call(string $ability, array $input = []): mixed
    {
        // Validate name; check budget; resolve annotation; enforce modes.
        // POST /wp-mcp/v1/abilities/<name>/run with {"input": ...}.
        // Decode JSON; map errors to WPMCP_Code_Error.
    }

    function wp_mcp_search(string $query, int $limit = 10): array
    {
        // GET /wp-abilities/v1/abilities?per_page=100&page=N (cached).
        // Filter locally; return compact rows.
    }

    // Register the exception handler that writes the log and exits.
}
```

---

## Appendix C: flag and exit table

| Flag | Values | Default | Notes |
|---|---|---|---|
| `--dry-run` | boolean | off | Incompatible with `--yes` and `--read-only`. |
| `--read-only` | boolean | off | Incompatible with `--yes` and `--dry-run`. |
| `--yes` / `-y` | boolean | off | Required for destructive abilities. |
| `--max-calls` | 1–1000 | 100 | `call_budget_exceeded` on overflow. |
| `--timeout` | 1–3600 | 120 | Seconds. |
| `--runtime` | `php` | `php` | `node` reserved for v2. |
| `--verbose` | boolean | off | Input sizes only. |
| `--help` / `-h` | — | — | Command help. |

| Exit | Codes |
|---|---|
| 0 | success |
| 1 | `internal_error` |
| 2 | `usage_error`, `site_required`, `site_not_found`, `ability_not_found` |
| 3 | `auth_required`, `auth_denied`, `auth_expired` |
| 4 | `network_error`, `rest_error` |
| 5 | `script_error`, `ability_execution_failed`, `schema_validation_failed`, `call_budget_exceeded` |
| 6 | `confirmation_required` |
