#!/usr/bin/env bash
# VPN Routing Commands - Manage corporate VPN access from inside containers
# ============================================================================
# Commands: vpn-routing
# Manages [vpn-routing] section in profiles.ini:
#   - Enables host iptables rules so containers reach corporate VPN resources
#   - CIDRs listed here are bypassed from the Amnezia tunnel inside containers

_cmd_vpn_routing() {
    init_project_dir "$PROJECT_DIR"
    local profile_file
    profile_file=$(get_profile_file_path)

    # Skip control flags (--enable-sudo etc.) passed through by dispatch_command
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
        enable)
            if grep -q '^\[vpn-routing\]' "$profile_file" 2>/dev/null; then
                printf 'vpn-routing is already enabled.\n'
            else
                update_profile_section "$profile_file" "vpn-routing"
                printf 'vpn-routing enabled.\n'
                printf 'Add corporate CIDRs with: claudebox vpn-routing add <cidr>\n'
            fi
            ;;

        disable)
            _vpn_routing_remove_section "$profile_file"
            printf 'vpn-routing disabled.\n'
            ;;

        add)
            local cidrs=()
            for arg in "$@"; do
                if [[ "$arg" != -* ]]; then
                    cidrs+=("$arg")
                fi
            done
            if [[ ${#cidrs[@]} -eq 0 ]]; then
                error "Usage: claudebox vpn-routing add <cidr> [cidr...]\nExample: claudebox vpn-routing add 10.0.0.0/8 172.16.0.0/12"
            fi
            update_profile_section "$profile_file" "vpn-routing" "${cidrs[@]}"
            cecho "Added: ${cidrs[*]}" "$GREEN"
            printf '\n'
            _vpn_routing_show "$profile_file"
            ;;

        remove)
            local cidrs=()
            for arg in "$@"; do
                if [[ "$arg" != -* ]]; then
                    cidrs+=("$arg")
                fi
            done
            if [[ ${#cidrs[@]} -eq 0 ]]; then
                error "Usage: claudebox vpn-routing remove <cidr> [cidr...]\nExample: claudebox vpn-routing remove 10.0.0.0/8"
            fi
            _vpn_routing_remove_cidrs "$profile_file" "${cidrs[@]}"
            cecho "Removed: ${cidrs[*]}" "$YELLOW"
            printf '\n'
            _vpn_routing_show "$profile_file"
            ;;

        ""|status)
            _vpn_routing_show "$profile_file"
            printf 'Commands:\n'
            printf '  claudebox vpn-routing enable              Enable VPN routing\n'
            printf '  claudebox vpn-routing disable             Disable VPN routing\n'
            printf '  claudebox vpn-routing add <cidr...>       Add corporate CIDRs\n'
            printf '  claudebox vpn-routing remove <cidr...>    Remove CIDRs\n'
            ;;

        *)
            error "Unknown subcommand: $subcmd\nUsage: claudebox vpn-routing [enable|disable|add <cidr...>|remove <cidr...>]"
            ;;
    esac
}

_vpn_routing_show() {
    local profile_file="$1"
    local cidrs=()

    if grep -q '^\[vpn-routing\]' "$profile_file" 2>/dev/null; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && cidrs+=("$line")
        done < <(read_profile_section "$profile_file" "vpn-routing")

        cecho "vpn-routing: enabled" "$GREEN"
        if [[ ${#cidrs[@]} -gt 0 ]]; then
            printf 'Corporate CIDRs:\n'
            for cidr in "${cidrs[@]}"; do
                printf '  %s\n' "$cidr"
            done
        else
            printf 'No CIDRs configured.\n'
        fi
    else
        cecho "vpn-routing: disabled" "$YELLOW"
    fi
    printf '\n'
}

_vpn_routing_remove_section() {
    local profile_file="$1"
    if [[ ! -f "$profile_file" ]]; then
        return 0
    fi
    awk -v sect="vpn-routing" '
        /^\[/ && $0 == "[" sect "]" { skip=1; next }
        /^\[/ && $0 != "[" sect "]" { skip=0 }
        !skip { print }
    ' "$profile_file" > "${profile_file}.tmp" && mv "${profile_file}.tmp" "$profile_file"
}

_vpn_routing_remove_cidrs() {
    local profile_file="$1"
    shift
    local to_remove=("$@")

    local current=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && current+=("$line")
    done < <(read_profile_section "$profile_file" "vpn-routing")

    local new_cidrs=()
    for cidr in "${current[@]}"; do
        local keep=true
        for r in "${to_remove[@]}"; do
            if [[ "$cidr" == "$r" ]]; then
                keep=false
                break
            fi
        done
        if [[ "$keep" == "true" ]]; then
            new_cidrs+=("$cidr")
        fi
    done

    # Remove old section then rewrite it (keep header even if no CIDRs remain)
    _vpn_routing_remove_section "$profile_file"
    {
        if [[ -f "$profile_file" ]]; then
            cat "$profile_file"
        fi
        printf '[vpn-routing]\n'
        for cidr in "${new_cidrs[@]}"; do
            printf '%s\n' "$cidr"
        done
        printf '\n'
    } > "${profile_file}.tmp" && mv "${profile_file}.tmp" "$profile_file"
}

export -f _cmd_vpn_routing _vpn_routing_show _vpn_routing_remove_section _vpn_routing_remove_cidrs
