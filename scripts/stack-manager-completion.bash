#!/usr/bin/env bash
#
# Bash completion for stack-manager.sh
#
# Installation:
#   1. Copy to /etc/bash_completion.d/stack-manager
#   2. Or source in ~/.bashrc:
#      source /path/to/stack-manager-completion.bash
#

_stack_manager_completion() {
    local cur prev opts modes
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Available commands
    local commands="start stop restart status logs clean interactive menu help"

    # Available modes
    local modes="dev citus patroni monitoring production"

    # Command flags
    local start_flags="--tools -t"
    local stop_flags="--force -f"
    local logs_flags="--follow -f"

    # Complete commands
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands}" -- ${cur}) )
        return 0
    fi

    # Complete modes for commands that need them
    if [[ ${COMP_CWORD} -eq 2 ]]; then
        case "${prev}" in
            start|stop|restart|logs|clean)
                COMPREPLY=( $(compgen -W "${modes}" -- ${cur}) )
                return 0
                ;;
        esac
    fi

    # Complete flags for commands
    if [[ ${COMP_CWORD} -eq 3 ]]; then
        case "${COMP_WORDS[1]}" in
            start|restart)
                COMPREPLY=( $(compgen -W "${start_flags}" -- ${cur}) )
                return 0
                ;;
            stop)
                COMPREPLY=( $(compgen -W "${stop_flags}" -- ${cur}) )
                return 0
                ;;
            logs)
                COMPREPLY=( $(compgen -W "${logs_flags}" -- ${cur}) )
                return 0
                ;;
        esac
    fi

    return 0
}

# Register completion function
complete -F _stack_manager_completion stack-manager.sh
complete -F _stack_manager_completion ./scripts/stack-manager.sh

# Also register for common aliases
complete -F _stack_manager_completion sm
complete -F _stack_manager_completion stack-manager
