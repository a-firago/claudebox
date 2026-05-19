#!/usr/bin/env bash
# VPN Gateway Commands - Shared AmneziaWG gateway for multiple ClaudeBox containers
# ============================================================================
# Commands: vpn-gw
# Manages a single long-lived gateway container that owns the AWG tunnel.
# All ClaudeBox containers route through it so the VPN server sees only one
# connection, allowing multiple slots to run concurrently.
#
# Network layout:
#   Docker network: claudebox-vpn (172.20.0.0/16)
#   Gateway:  claudebox-vpn-gw  (172.20.0.2)  — runs AWG, does NAT/MASQUERADE
#   Clients:  claudebox-*        (172.20.0.x)  — default route → gateway
#
# Corporate VPN integration (vpn-routing):
#   Gateway adds ip rules to bypass corporate CIDRs from the AWG tunnel.
#   Host gets iptables MASQUERADE from claudebox-vpn subnet → corp VPN interface.

_cmd_vpn_gw() {
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
        start)      _vpn_gw_start ;;
        stop)       _vpn_gw_stop ;;
        status|"")  _vpn_gw_status ;;
        *)
            printf 'Unknown subcommand: %s\n' "$subcmd" >&2
            printf 'Usage: claudebox vpn-gw [start|stop|status]\n' >&2
            exit 1
            ;;
    esac
}

_vpn_gw_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${VPN_GW_CONTAINER}$"
}

_vpn_gw_status() {
    printf 'VPN Gateway container : %s\n' "$VPN_GW_CONTAINER"
    printf 'Docker network        : %s (%s)\n' "$VPN_GW_NETWORK" "$VPN_GW_SUBNET"
    printf '\n'
    if _vpn_gw_running; then
        cecho "Status: running" "$GREEN"
        local gw_ip
        gw_ip=$(docker inspect "$VPN_GW_CONTAINER" \
            --format "{{(index .NetworkSettings.Networks \"${VPN_GW_NETWORK}\").IPAddress}}" \
            2>/dev/null || true)
        if [[ -n "$gw_ip" ]]; then
            printf 'Gateway IP: %s\n' "$gw_ip"
        fi
    else
        cecho "Status: stopped" "$YELLOW"
    fi
    printf '\n'
    printf 'Commands:\n'
    printf '  claudebox vpn-gw start    Start the shared VPN gateway\n'
    printf '  claudebox vpn-gw stop     Stop the gateway\n'
    printf '  claudebox vpn-gw status   Show this status\n'
}

_vpn_gw_ensure_network() {
    if ! docker network inspect "$VPN_GW_NETWORK" >/dev/null 2>&1; then
        if [[ "$VERBOSE" == "true" ]]; then
            printf '[vpn-gw] Creating Docker network %s (%s)\n' "$VPN_GW_NETWORK" "$VPN_GW_SUBNET" >&2
        fi
        docker network create \
            --driver bridge \
            --subnet "$VPN_GW_SUBNET" \
            --gateway "$VPN_GW_SUBNET_GW" \
            "$VPN_GW_NETWORK" >/dev/null
    fi
}

# Read corporate bypass CIDRs from the current project's profiles.ini.
# Outputs a space-separated string (empty if vpn-routing is not configured).
_vpn_gw_read_bypass_cidrs() {
    local profiles_ini
    profiles_ini="$(get_parent_dir "$PROJECT_DIR")/profiles.ini"
    if [[ ! -f "$profiles_ini" ]]; then
        printf ''
        return 0
    fi

    local cidrs=()
    local cidr
    while IFS= read -r cidr; do
        if [[ -n "$cidr" ]]; then
            cidrs+=("$cidr")
        fi
    done < <(read_profile_section "$profiles_ini" "vpn-routing" 2>/dev/null || true)

    if [[ ${#cidrs[@]} -gt 0 ]]; then
        printf '%s' "${cidrs[*]}"
    fi
}

# Set up host iptables so the claudebox-vpn network can reach corporate VPN interfaces.
# Mirrors what _setup_vpn_routing does for the default bridge, but targets claudebox-vpn.
_vpn_gw_setup_host_routing() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        return 0
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi

    local vpn_net_cidr
    vpn_net_cidr=$(docker network inspect "$VPN_GW_NETWORK" \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    if [[ -z "$vpn_net_cidr" ]]; then
        return 0
    fi

    # Derive the bridge interface name for claudebox-vpn (br-<first 12 chars of network ID>)
    local net_id bridge_name
    net_id=$(docker network inspect "$VPN_GW_NETWORK" --format '{{.Id}}' 2>/dev/null | cut -c1-12 || true)
    bridge_name="br-${net_id}"

    # Detect corporate VPN interfaces on the host (same heuristic as _setup_vpn_routing)
    local default_iface
    default_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

    local vpn_ifaces
    vpn_ifaces=$(ip route 2>/dev/null | awk '
        /dev / && ($1 ~ /^10\./ ||
                   $1 ~ /^172\.1[6-9]\./ || $1 ~ /^172\.2[0-9]\./ || $1 ~ /^172\.3[01]\./ ||
                   $1 ~ /^192\.168\./) {
            for (i = 1; i <= NF; i++) if ($i == "dev") print $(i+1)
        }
    ' 2>/dev/null | sort -u 2>/dev/null) || true

    if [[ -z "$vpn_ifaces" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            printf '[vpn-gw] No corporate VPN interfaces detected on host\n' >&2
        fi
        return 0
    fi

    local have_sudo=false
    if sudo -n true 2>/dev/null; then
        have_sudo=true
    fi

    local iface
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        [[ "$iface" == "$default_iface" ]] && continue
        case "$iface" in
            lo|docker*|br-*|veth*) continue ;;
        esac

        if [[ "$have_sudo" != "true" ]]; then
            printf '[vpn-gw] Corporate routing requires passwordless sudo. Run manually:\n'
            printf '  sudo iptables -t nat -A POSTROUTING -s %s -o %s -j MASQUERADE\n' \
                "$vpn_net_cidr" "$iface"
            if ip link show "$bridge_name" >/dev/null 2>&1; then
                printf '  sudo iptables -I FORWARD -i %s -o %s -j ACCEPT\n' "$bridge_name" "$iface"
                printf '  sudo iptables -I FORWARD -i %s -o %s -m state --state RELATED,ESTABLISHED -j ACCEPT\n' \
                    "$iface" "$bridge_name"
            fi
            continue
        fi

        if ! sudo -n iptables -t nat -C POSTROUTING -s "$vpn_net_cidr" -o "$iface" -j MASQUERADE 2>/dev/null; then
            sudo -n iptables -t nat -A POSTROUTING -s "$vpn_net_cidr" -o "$iface" -j MASQUERADE 2>/dev/null || true
        fi

        if ip link show "$bridge_name" >/dev/null 2>&1; then
            if ! sudo -n iptables -C FORWARD -i "$bridge_name" -o "$iface" -j ACCEPT 2>/dev/null; then
                sudo -n iptables -I FORWARD -i "$bridge_name" -o "$iface" -j ACCEPT 2>/dev/null || true
            fi
            if ! sudo -n iptables -C FORWARD -i "$iface" -o "$bridge_name" \
                    -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
                sudo -n iptables -I FORWARD -i "$iface" -o "$bridge_name" \
                    -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
            fi
        fi

        printf '[vpn-gw] Host routing: %s -> %s\n' "$vpn_net_cidr" "$iface"
    done <<< "$vpn_ifaces"
}

_vpn_gw_start() {
    # Resolve image for this project
    local image_name
    image_name=$(get_image_name 2>/dev/null || true)
    if [[ -z "$image_name" ]]; then
        printf 'ERROR: Run this command from your project directory.\n' >&2
        exit 1
    fi
    if ! docker image inspect "$image_name" >/dev/null 2>&1; then
        printf 'ERROR: Image "%s" not found. Run "claudebox" to build it first.\n' "$image_name" >&2
        exit 1
    fi

    # Require at least one AWG config file
    local awg_dir="$HOME/.config/AmneziaVPN.ORG"
    local conf_count=0
    if [[ -d "$awg_dir" ]]; then
        conf_count=$(find "$awg_dir" -maxdepth 1 -name "*.conf" 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [[ "$conf_count" -eq 0 ]]; then
        printf 'ERROR: No *.conf files found in %s\n' "$awg_dir" >&2
        printf 'Copy your AmneziaWG config file(s) there first.\n' >&2
        exit 1
    fi

    if _vpn_gw_running; then
        printf 'VPN gateway is already running.\n'
        return 0
    fi

    _vpn_gw_ensure_network

    # Read corporate VPN bypass CIDRs (may be empty if vpn-routing not configured)
    local bypass_cidrs
    bypass_cidrs=$(_vpn_gw_read_bypass_cidrs)

    # Write the gateway startup script.
    # Single-quoted heredoc — no host-side variable expansion.
    # VPN_BYPASS_CIDRS is passed as a container env var and expanded at runtime.
    local gw_script
    gw_script=$(mktemp /tmp/claudebox-vpngw-XXXXXX.sh)
    chmod +x "$gw_script"

    cat > "$gw_script" << 'GWSCRIPT'
#!/bin/sh
set -eu

vpn_started=false
for conf in /home/claude/.config/AmneziaVPN.ORG/*.conf; do
    [ -f "$conf" ] || continue
    iface=$(basename "$conf" .conf)
    printf '[vpn-gw] Starting tunnel: %s\n' "$iface"
    if awg-quick up "$conf" 2>&1; then
        vpn_started=true
        # NAT: masquerade all claudebox-vpn traffic going out through the tunnel
        link_net=$(ip route show | awk '/eth0/ && /scope link/ && /proto kernel/ {print $1; exit}')
        if [ -n "$link_net" ]; then
            iptables -t nat -A POSTROUTING -s "$link_net" -o "$iface" -j MASQUERADE 2>/dev/null || true
            iptables -A FORWARD -i eth0 -o "$iface" -j ACCEPT 2>/dev/null || true
            iptables -A FORWARD -i "$iface" -o eth0 \
                -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
            printf '[vpn-gw] NAT: %s -> %s\n' "$link_net" "$iface"
        fi
    else
        printf '[vpn-gw] Warning: failed to start %s\n' "$iface" >&2
    fi
done

if [ "$vpn_started" != "true" ]; then
    printf '[vpn-gw] ERROR: no tunnels started\n' >&2
    exit 1
fi

# Bypass corporate CIDRs from the AWG tunnel so they route via eth0 → host corp VPN.
# VPN_BYPASS_CIDRS is a space-separated list injected via -e at container start.
if [ -n "${VPN_BYPASS_CIDRS:-}" ]; then
    for cidr in $VPN_BYPASS_CIDRS; do
        if ! ip rule show | grep -q "to $cidr lookup main"; then
            ip rule add to "$cidr" lookup main priority 100
            printf '[vpn-gw] Corporate bypass: %s\n' "$cidr"
        fi
    done
fi

printf '[vpn-gw] Gateway ready\n'
exec tail -f /dev/null
GWSCRIPT

    local docker_run_args=(
        -d --rm
        --name "$VPN_GW_CONTAINER"
        --network "$VPN_GW_NETWORK"
        --cap-add NET_ADMIN
        --cap-add NET_RAW
        --sysctl net.ipv4.ip_forward=1
        --sysctl net.ipv4.conf.all.src_valid_mark=1
        --sysctl net.ipv4.conf.all.rp_filter=2
        -v "$awg_dir":/home/claude/.config/AmneziaVPN.ORG:ro
        -v "$gw_script":/run/vpngw-start.sh:ro
        --entrypoint /bin/sh
    )

    if [[ -n "$bypass_cidrs" ]]; then
        docker_run_args+=(-e "VPN_BYPASS_CIDRS=$bypass_cidrs")
    fi

    docker_run_args+=("$image_name" /run/vpngw-start.sh)

    docker run "${docker_run_args[@]}" >/dev/null
    rm -f "$gw_script"

    # Wait up to 15 s for the gateway to signal readiness
    local retries=0
    local ready=false
    while [[ $retries -lt 15 ]]; do
        if docker logs "$VPN_GW_CONTAINER" 2>&1 | grep -q '\[vpn-gw\] Gateway ready'; then
            ready=true
            break
        fi
        sleep 1
        ((retries++)) || true
    done

    if [[ "$ready" != "true" ]]; then
        docker logs "$VPN_GW_CONTAINER" >&2 || true
        docker stop "$VPN_GW_CONTAINER" >/dev/null 2>&1 || true
        printf 'ERROR: VPN gateway failed to start. Check logs above.\n' >&2
        exit 1
    fi

    cecho "VPN gateway started" "$GREEN"

    local gw_ip
    gw_ip=$(docker inspect "$VPN_GW_CONTAINER" \
        --format "{{(index .NetworkSettings.Networks \"${VPN_GW_NETWORK}\").IPAddress}}" \
        2>/dev/null || true)
    if [[ -n "$gw_ip" ]]; then
        printf 'Gateway IP: %s\n' "$gw_ip"
    fi

    # Set up host-side iptables so claudebox-vpn network reaches corporate VPN
    if [[ -n "$bypass_cidrs" ]]; then
        _vpn_gw_setup_host_routing
    fi

    printf 'New ClaudeBox containers will route all traffic through the VPN gateway.\n'
}

_vpn_gw_stop() {
    if ! _vpn_gw_running; then
        printf 'VPN gateway is not running.\n'
        return 0
    fi
    docker stop "$VPN_GW_CONTAINER" >/dev/null
    cecho "VPN gateway stopped" "$GREEN"
}

export -f _cmd_vpn_gw _vpn_gw_status _vpn_gw_start _vpn_gw_stop \
          _vpn_gw_running _vpn_gw_ensure_network \
          _vpn_gw_read_bypass_cidrs _vpn_gw_setup_host_routing
