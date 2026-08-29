# SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
# SPDX-License-Identifier: AGPL-3.0-or-later

# gum wrappers. Every helper checks for a TTY first and falls back to
# stdin/flags when no TTY is available, so commands remain usable in
# CI and from coding agents.

wpmcp_ui_input() {
    # wpmcp_ui_input <prompt> [<default>] → echoes value
    local prompt="$1"
    local default="${2:-}"
    if ! wpmcp_has_tty; then
        wpmcp_error_usage "$prompt (no TTY available; pass the value via flag)"
    fi
    wpmcp_require_gum
    local args=(--prompt "$prompt" --prompt.foreground 212)
    if [ -n "$default" ]; then
        args+=(--value "$default")
    fi
    gum input "${args[@]}"
}

wpmcp_ui_password() {
    # wpmcp_ui_password <prompt> → echoes value
    local prompt="$1"
    if ! wpmcp_has_tty; then
        wpmcp_error_usage "$prompt (no TTY available; pass the value via flag)"
    fi
    wpmcp_require_gum
    gum input --password --prompt "$prompt" --prompt.foreground 212
}

wpmcp_ui_confirm() {
    # wpmcp_ui_confirm <prompt> [<default_yes>] → echoes "Yes" or "No"
    local prompt="$1"
    local default_yes="${2:-true}"
    if ! wpmcp_has_tty; then
        wpmcp_error_print "confirmation_required" "$WPMCP_ERROR_CONFIRMATION" \
            "$prompt (pass --yes to confirm)"
    fi
    wpmcp_require_gum
    local args=(--prompt "$prompt" --affirmative "Yes" --negative "No")
    if [ "$default_yes" = "true" ]; then
        args+=(--default=true)
    else
        args+=(--default=false)
    fi
    gum confirm "${args[@]}"
}

wpmcp_ui_choose() {
    # wpmcp_ui_choose <prompt> <newline_separated_options> → echoes selected
    local prompt="$1"
    shift
    if ! wpmcp_has_tty; then
        wpmcp_error_usage "$prompt (no TTY available; pass the value via flag)"
    fi
    wpmcp_require_gum
    printf '%s\n' "$@" | gum choose --prompt "$prompt" --header "$prompt"
}

wpmcp_ui_table() {
    # wpmcp_ui_table <tsv_data> [<columns_comma_separated>]
    local tsv="$1"
    local columns="${2:-}"
    if ! wpmcp_has_tty; then
        # In non-TTY contexts, print TSV plain for piping into other tools.
        printf '%s\n' "$tsv"
        return 0
    fi
    wpmcp_require_gum
    local args=()
    if [ -n "$columns" ]; then
        IFS=',' read -ra cols <<< "$columns"
        args+=(--columns "${cols[@]}")
    fi
    printf '%s\n' "$tsv" | gum table "${args[@]}" --border rounded --print
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
