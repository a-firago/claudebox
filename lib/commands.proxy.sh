#!/usr/bin/env bash
# Proxy Commands - HTTP/HTTPS proxy configuration for containers
# ============================================================================
# Proxy scripts live in ~/.config/proxy/*.sh
# Each script exports http_proxy / https_proxy / etc.
# All scripts are sourced at container launch time and the resulting env vars
# are passed to the container via -e flags.

_cmd_proxy() {
    local proxy_dir="$HOME/.config/proxy"
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        add)
            _proxy_add "$proxy_dir" "$@"
            ;;
        remove)
            _proxy_remove "$proxy_dir" "$@"
            ;;
        show)
            _proxy_show "$proxy_dir"
            ;;
        list|"")
            _proxy_list "$proxy_dir"
            printf 'Commands:\n'
            printf '  claudebox proxy add <script.sh> [name]   Symlink a proxy script\n'
            printf '  claudebox proxy remove <name>            Remove a proxy script\n'
            printf '  claudebox proxy list                     List configured proxies\n'
            printf '  claudebox proxy show                     Show proxy env vars (masked)\n'
            ;;
        *)
            printf 'Unknown subcommand: %s\n' "$subcmd" >&2
            printf 'Usage: claudebox proxy [add|remove|list|show]\n' >&2
            exit 1
            ;;
    esac
}

_proxy_add() {
    local proxy_dir="$1"
    local src="${2:-}"
    local name="${3:-}"

    if [[ -z "$src" ]]; then
        printf 'Usage: claudebox proxy add <script.sh> [name]\n' >&2
        printf 'Example: claudebox proxy add ~/bin/proxy.sh\n' >&2
        printf 'Example: claudebox proxy add ~/bin/proxy.sh corporate\n' >&2
        exit 1
    fi

    # Expand ~
    src="${src/#\~/$HOME}"

    if [[ ! -f "$src" ]]; then
        printf 'ERROR: File not found: %s\n' "$src" >&2
        exit 1
    fi

    if [[ -z "$name" ]]; then
        name=$(basename "$src" .sh)
    fi

    mkdir -p "$proxy_dir"
    ln -sf "$src" "$proxy_dir/${name}.sh"
    cecho "Proxy '${name}' added" "$GREEN"
    printf '\n'
    _proxy_list "$proxy_dir"
}

_proxy_remove() {
    local proxy_dir="$1"
    local name="${2:-}"

    if [[ -z "$name" ]]; then
        printf 'Usage: claudebox proxy remove <name>\n' >&2
        exit 1
    fi

    local target="$proxy_dir/${name}.sh"
    if [[ ! -e "$target" ]]; then
        printf 'ERROR: Proxy not found: %s\n' "$name" >&2
        exit 1
    fi

    rm -f "$target"
    cecho "Proxy '${name}' removed" "$YELLOW"
    printf '\n'
    _proxy_list "$proxy_dir"
}

_proxy_list() {
    local proxy_dir="$1"

    if [[ ! -d "$proxy_dir" ]]; then
        printf 'No proxy scripts configured.\n\n'
        return 0
    fi

    local found=false
    local f
    for f in "$proxy_dir"/*.sh; do
        if [[ -f "$f" ]]; then
            found=true
            break
        fi
    done

    if [[ "$found" == "false" ]]; then
        printf 'No proxy scripts configured.\n\n'
        return 0
    fi

    printf 'Configured proxies:\n'
    for f in "$proxy_dir"/*.sh; do
        if [[ -f "$f" ]]; then
            local name
            name=$(basename "$f" .sh)
            if [[ -L "$f" ]]; then
                local link_target
                link_target=$(readlink "$f")
                printf '  %-20s -> %s\n' "$name" "$link_target"
            else
                printf '  %-20s (%s)\n' "$name" "$f"
            fi
        fi
    done
    printf '\n'
}

_proxy_show() {
    local proxy_dir="$1"

    if [[ ! -d "$proxy_dir" ]]; then
        printf 'No proxy configured.\n'
        return 0
    fi

    local vars
    vars=$(
        unset http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY 2>/dev/null || true
        local f
        for f in "$proxy_dir"/*.sh; do
            if [[ -f "$f" ]]; then
                # shellcheck disable=SC1090
                source "$f" >/dev/null 2>&1 || true
            fi
        done
        env | grep -iE '^(http_proxy|https_proxy|ftp_proxy|no_proxy)=' 2>/dev/null || true
    )

    if [[ -z "$vars" ]]; then
        printf 'No proxy environment variables found.\n'
        return 0
    fi

    printf 'Proxy environment:\n'
    local line
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local masked
            masked=$(printf '%s' "$line" | sed 's|://[^@]*@|://***@|g')
            printf '  %s\n' "$masked"
        fi
    done <<< "$vars"
    printf '\n'
}

export -f _cmd_proxy _proxy_add _proxy_remove _proxy_list _proxy_show
