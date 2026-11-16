# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# gum wrappers. Prompt helpers check for a controlling terminal first and
# attach gum's TUI to /dev/tty, so they keep working when stdout is
# redirected and never leak prompt output into JSON or piped data. Decorative
# helpers (tables, pagers) require stdout to be a TTY and fall back to plain
# text otherwise. No helper prompts in CI, cron or agents without a
# controlling terminal.
#
# The second positional argument is the "flag hint" — a short string
# (e.g. "--user", "WPMCP_USERNAME") that the error message includes so
# the caller knows exactly which mechanism to use in non-TTY mode.

wpmcp_ui_gum() {
    # wpmcp_ui_gum <gum args...>
    # gum reads keystrokes from stdin and draws the prompt on stderr; the
    # entered value (or confirm status) stays on stdout so callers can
    # capture it. Point both streams at the controlling terminal so a
    # redirected stdout neither hides the prompt nor makes gum abort with an
    # unknown terminal width.
    if wpmcp_has_controlling_tty; then
        gum "$@" </dev/tty 2>/dev/tty
    else
        gum "$@"
    fi
}

wpmcp_ui_input() {
    # wpmcp_ui_input <prompt> <flag_hint> [<default>] [env_var]
    #   flag_hint: short hint like "--user" or "WPMCP_USERNAME" shown
    #              in the non-TTY error.
    #   env_var:   optional environment variable to read as a fallback
    #              before falling back to gum.
    local prompt="$1"
    local flag_hint="$2"
    local default="${3:-}"
    local env_var="${4:-}"

    if [ -n "$env_var" ] && [ -n "${!env_var:-}" ]; then
        printf '%s' "${!env_var}"
        return 0
    fi

    if ! wpmcp_has_tty; then
        wpmcp_error_usage "Missing $prompt. Pass '$flag_hint' as a flag${env_var:+ or set $env_var}."
    fi
    wpmcp_require_gum
    local gum_args=(--prompt "$prompt" --prompt.foreground 212)
    if [ -n "$default" ]; then
        gum_args+=(--value "$default")
    fi
    wpmcp_ui_gum input "${gum_args[@]}"
}

wpmcp_ui_password() {
    # wpmcp_ui_password <prompt> <flag_hint> [env_var]
    local prompt="$1"
    local flag_hint="$2"
    local env_var="${3:-}"

    if [ -n "$env_var" ] && [ -n "${!env_var:-}" ]; then
        printf '%s' "${!env_var}"
        return 0
    fi

    if ! wpmcp_has_tty; then
        wpmcp_error_usage "Missing $prompt. Pass '$flag_hint' as a flag${env_var:+ or set $env_var}."
    fi
    wpmcp_require_gum
    wpmcp_ui_gum input --password --prompt "$prompt" --prompt.foreground 212
}

wpmcp_ui_confirm() {
    # wpmcp_ui_confirm <prompt> [<default_yes>]
    local prompt="$1"
    local default_yes="${2:-true}"
    if ! wpmcp_has_tty; then
        wpmcp_error_print "confirmation_required" "$WPMCP_ERROR_CONFIRMATION" \
            "$prompt (pass --yes to confirm)"
    fi
    wpmcp_require_gum
    # gum confirm takes the prompt as a positional argument. It has no
    # --prompt flag; passing one makes gum print help on stdout and cancel.
    local args=("$prompt" --affirmative "Yes" --negative "No")
    if [ "$default_yes" = "true" ]; then
        args+=(--default=true)
    else
        args+=(--default=false)
    fi
    wpmcp_ui_gum confirm "${args[@]}"
}

wpmcp_ui_choose() {
    # wpmcp_ui_choose <prompt> <flag_hint> <newline_separated_options>
    local prompt="$1"
    local flag_hint="$2"
    shift 2
    if ! wpmcp_has_tty; then
        wpmcp_error_usage "Missing $prompt. Pass '$flag_hint' as a flag."
    fi
    wpmcp_require_gum
    # Options are passed as arguments so the helper can reserve stdin for
    # keystrokes from /dev/tty.
    wpmcp_ui_gum choose --prompt "$prompt" --header "$prompt" "$@"
}

wpmcp_ui_table() {
    # wpmcp_ui_table <tsv_data> [<columns_comma_separated>]
    local tsv="$1"
    local columns="${2:-}"
    if ! wpmcp_stdout_is_tty; then
        # When stdout is a pipe or file, print TSV plain for other tools.
        printf '%s\n' "$tsv"
        return 0
    fi
    wpmcp_require_gum
    local args=()
    # gum's --columns flag expects a single comma-separated string,
    # not one argv entry per column name.
    if [ -n "$columns" ]; then
        args+=(--columns "$columns")
    fi
    # gum's --separator flag sets the field separator. The flag is
    # documented with a comma as its example value, which makes it
    # ambiguous whether the default is comma or auto-detected tab.
    # Pass tab explicitly so the field split is unambiguous and works
    # the same on every gum version.
    printf '%s\n' "$tsv" | gum table "${args[@]}" --separator $'\t' --border rounded --print
}

wpmcp_ui_spin() {
    # wpmcp_ui_spin <title> <command...> → runs command, suppressing gum output if non-TTY
    local title="$1"
    shift
    if ! wpmcp_has_tty; then
        "$@"
        return $?
    fi
    wpmcp_require_gum
    gum spin --title "$title" --spinner dot -- "$@"
}
