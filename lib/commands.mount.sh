#!/usr/bin/env bash
# Mount Commands - Extra host directories in the container workspace
# ============================================================================
# Commands: mount
# Manages [mounts] section in profiles.ini.
# Each entry is a standard Docker volume spec: /host/path:/container/path
# Mounts are applied to every container launched in the project.

_cmd_mount() {
    init_project_dir "$PROJECT_DIR"
    local profile_file
    profile_file=$(get_profile_file_path)

    # Strip control flags passed through by dispatch_command
    local subcmd=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -* ]]; then
            shift
        else
            subcmd="$1"
            shift
            break
        fi
    done

    case "$subcmd" in
        add)
            local specs=()
            for arg in "$@"; do
                if [[ "$arg" != -* ]]; then
                    specs+=("$arg")
                fi
            done
            if [[ ${#specs[@]} -eq 0 ]]; then
                printf 'Usage: claudebox mount add <host_path>:<container_path> [...]\n' >&2
                printf 'Example: claudebox mount add /home/user/shared:/workspace/shared\n' >&2
                exit 1
            fi
            local spec
            for spec in "${specs[@]}"; do
                _mount_validate_spec "$spec"
                update_profile_section "$profile_file" "mounts" "$spec"
            done
            cecho "Added ${#specs[@]} mount(s)" "$GREEN"
            printf '\n'
            _mount_show "$profile_file"
            ;;

        remove)
            local specs=()
            for arg in "$@"; do
                if [[ "$arg" != -* ]]; then
                    specs+=("$arg")
                fi
            done
            if [[ ${#specs[@]} -eq 0 ]]; then
                printf 'Usage: claudebox mount remove <host_path>:<container_path> [...]\n' >&2
                exit 1
            fi
            _mount_remove_entries "$profile_file" "${specs[@]}"
            cecho "Removed ${#specs[@]} mount(s)" "$YELLOW"
            printf '\n'
            _mount_show "$profile_file"
            ;;

        ""|list)
            _mount_show "$profile_file"
            printf 'Commands:\n'
            printf '  claudebox mount add <host>:<container>    Add a mount\n'
            printf '  claudebox mount remove <host>:<container> Remove a mount\n'
            printf '  claudebox mount list                      List mounts\n'
            ;;

        *)
            printf 'Unknown subcommand: %s\n' "$subcmd" >&2
            printf 'Usage: claudebox mount [add|remove|list]\n' >&2
            exit 1
            ;;
    esac
}

_mount_validate_spec() {
    local spec="$1"
    if [[ "$spec" != *:* ]]; then
        printf 'ERROR: Mount spec must be "host_path:container_path", got: %s\n' "$spec" >&2
        exit 1
    fi
    local host_path="${spec%%:*}"
    # Expand ~ manually (not in double quotes to avoid issues)
    host_path="${host_path/#\~/$HOME}"
    if [[ ! -e "$host_path" ]]; then
        printf 'Warning: host path does not exist: %s\n' "$host_path" >&2
    fi
}

_mount_show() {
    local profile_file="$1"
    local entries=()
    local entry
    while IFS= read -r entry; do
        [[ -n "$entry" ]] && entries+=("$entry")
    done < <(read_profile_section "$profile_file" "mounts" 2>/dev/null || true)

    if [[ ${#entries[@]} -eq 0 ]]; then
        printf 'No extra mounts configured.\n\n'
        return 0
    fi

    printf 'Extra mounts:\n'
    for entry in "${entries[@]}"; do
        local host_part="${entry%%:*}"
        local container_part="${entry#*:}"
        printf '  %-35s -> %s\n' "$host_part" "$container_part"
    done
    printf '\n'
}

_mount_remove_entries() {
    local profile_file="$1"
    shift
    local to_remove=("$@")

    local current=()
    local entry
    while IFS= read -r entry; do
        [[ -n "$entry" ]] && current+=("$entry")
    done < <(read_profile_section "$profile_file" "mounts" 2>/dev/null || true)

    local kept=()
    for entry in "${current[@]}"; do
        local remove=false
        local r
        for r in "${to_remove[@]}"; do
            if [[ "$entry" == "$r" ]]; then
                remove=true
                break
            fi
        done
        if [[ "$remove" == "false" ]]; then
            kept+=("$entry")
        fi
    done

    _mount_remove_section "$profile_file"
    if [[ ${#kept[@]} -gt 0 ]]; then
        {
            if [[ -f "$profile_file" ]]; then
                cat "$profile_file"
            fi
            printf '[mounts]\n'
            for entry in "${kept[@]}"; do
                printf '%s\n' "$entry"
            done
            printf '\n'
        } > "${profile_file}.tmp" && mv "${profile_file}.tmp" "$profile_file"
    fi
}

_mount_remove_section() {
    local profile_file="$1"
    if [[ ! -f "$profile_file" ]]; then
        return 0
    fi
    awk -v sect="mounts" '
        /^\[/ && $0 == "[" sect "]" { skip=1; next }
        /^\[/ && $0 != "[" sect "]" { skip=0 }
        !skip { print }
    ' "$profile_file" > "${profile_file}.tmp" && mv "${profile_file}.tmp" "$profile_file"
}

export -f _cmd_mount _mount_show _mount_validate_spec _mount_remove_entries _mount_remove_section
