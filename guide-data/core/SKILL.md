# Core Workflow Guide for wp-mcp-cli agents

Use this guide as the authoritative workflow when an agent needs to
operate the WP-MCP plugin from the terminal.

## Setup (once)

```bash
# Verify the CLI is installed.
wp-mcp --version

# Verify the local environment.
wp-mcp doctor

# Authenticate to the local Plak site.
wp-mcp auth login https://dev.localhost

# Install the agent skill (one-time, per agent).
wp-mcp skill install all
```

## Discover → Describe → Run

```bash
# 1. Discover every available ability.
wp-mcp --json discover | jq '.data.abilities[].name'

# 2. Describe the schema before invoking.
wp-mcp --json describe wp-mcp/list-directory | jq '.data.input_schema'

# 3. Run the ability.
wp-mcp run wp-mcp/list-directory --input '{"path":"/Users"}'
```

## Code mode (multi-step work)

For loops, pagination, audits or batch updates, write a local PHP script:

```php
<?php
$rows = wp_mcp_search('post', 10);
foreach ($rows as $row) {
    echo $row['name'] . "\n";
}
```

```bash
# Real reads, all writes stubbed. Review the plan.
wp-mcp code audit.php --read-only

# Execute only after explicit approval.
wp-mcp code audit.php --yes
```

The script runs on the local machine, not the WordPress site, and is not a
sandbox. Use `--max-calls` and `--timeout` for large scripts. See
`skills/wp-mcp/SKILL.md` for the full code-mode workflow.

## Rules of engagement

- **Never narrate** the setup steps to the user. Run them silently and
  only surface errors.
- **Never auto-confirm** destructive operations. Pass `--yes` only when
  the user explicitly approved.
- **Prefer `--json`** for any output the agent will parse.
- **For multi-step work**, use `wp-mcp code --read-only` to build a plan from
  real data, then `--yes` only after explicit approval.
- **Branch on `error.code`** rather than parsing `error.message`.
- **Site selection**: do not assume a profile. Use `wp-mcp --json sites list`
  to discover the available sites, then pick one explicitly with `--site`
  or `WPMCP_SITE`.
- **Capability check**: if a destructive ability is rejected with
  `wp_mcp_forbidden`, the user lacks `manage_options` on the target site.

## Common failure modes

| Error code             | Meaning                                          | Fix                                 |
| ---------------------- | ------------------------------------------------ | ----------------------------------- |
| `site_required`        | Multiple profiles, no selector                   | `--site <name>` or `WPMCP_SITE`     |
| `site_not_found`       | Selector didn't match any profile                | `wp-mcp sites list`                 |
| `auth_required`        | No credentials for the active site               | `wp-mcp auth login`                 |
| `auth_denied`          | WordPress rejected HTTP Basic                    | regenerate app password             |
| `wp_mcp_disabled`      | Plugin disabled on the site                      | enable WP-MCP admin                 |
| `wp_mcp_forbidden`     | User lacks `manage_options`                      | use admin credentials               |
| `wp_mcp_ability_not_found` | Ability not registered                        | `wp-mcp --json discover`            |
| `wp_mcp_ability_hidden`   | Ability registered without `show_in_rest`     | enable via Abilities Hub admin      |
| `wp_mcp_sandbox_violation` | Tried to write outside `wp-content/wp-mcp-sandbox/` | use sandbox path             |
| `network_error`        | curl failed                                      | `wp-mcp doctor`                     |
| `confirmation_required`| Destructive op in non-TTY mode without `--yes`   | add `--yes`                         |
