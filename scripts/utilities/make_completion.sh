#!/bin/bash
# Makefile completion script for bash/zsh
# Generates completions by parsing Makefile targets
#
# Installation:
#   source scripts/utilities/make_completion.sh
#   Or:  make setup-completion
#
# Works in both bash and zsh shells.

_make_tenai_targets() {
    local makefile="$1"
    [ -f "$makefile" ] || return
    grep -E '^[a-zA-Z0-9_-]+:' "$makefile" 2>/dev/null | \
        grep -v ':=' | \
        grep -v '^\s*#' | \
        sed 's/:.*//' | \
        sort -u
}

if [ -n "$ZSH_VERSION" ]; then
    # ── ZSH native completion ──
    # Ensure compinit is loaded (safe to call multiple times)
    autoload -Uz compinit 2>/dev/null
    # Use -C to skip security check (faster startup)
    compinit -C 2>/dev/null

    _make_tenai_zsh() {
        local project_root=""
        if [[ -f "Makefile" ]]; then
            project_root="."
        elif [[ -f "../Makefile" ]]; then
            project_root=".."
        else
            # Fall back to default make completion
            _make 2>/dev/null
            return
        fi

        local targets
        targets=($(_make_tenai_targets "$project_root/Makefile"))
        compadd -a targets
    }

    compdef _make_tenai_zsh make

elif [ -n "$BASH_VERSION" ]; then
    # ── BASH completion ──
    _make_tenai_bash() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        local project_root=""

        if [[ -f "Makefile" ]]; then
            project_root="."
        elif [[ -f "../Makefile" ]]; then
            project_root=".."
        else
            return 1
        fi

        local targets
        targets=$(_make_tenai_targets "$project_root/Makefile")
        COMPREPLY=($(compgen -W "$targets" -- "$cur"))
    }

    complete -F _make_tenai_bash make
fi
