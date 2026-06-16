#!/usr/bin/env bash
# Functions for managing Docker containers, images, and runtime.

# Docker checks
check_docker() {
    command -v docker >/dev/null || return 1
    docker info >/dev/null 2>&1 || return 2
    docker ps >/dev/null 2>&1 || return 3
    return 0
}

install_docker() {
    warn "Docker is not installed."
    cecho "Would you like to install Docker now? (y/n)" "$CYAN"
    read -r response
    [[ "$response" =~ ^[Yy]$ ]] || error "Docker is required. Visit: https://docs.docker.com/engine/install/"

    info "Installing Docker..."

    [[ -f /etc/os-release ]] && . /etc/os-release || error "Cannot detect OS"

    case "${ID:-}" in
        ubuntu|debian)
            warn "Installing Docker requires sudo privileges..."
            sudo apt-get update
            sudo apt-get install -y ca-certificates curl gnupg lsb-release
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/$ID/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(lsb_release -cs) stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        fedora|rhel|centos)
            warn "Installing Docker requires sudo privileges..."
            sudo dnf -y install dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        arch|manjaro)
            warn "Installing Docker requires sudo privileges..."
            sudo pacman -S --noconfirm docker
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        *)
            error "Unsupported OS: ${ID:-unknown}. Visit: https://docs.docker.com/engine/install/"
            ;;
    esac

    success "Docker installed successfully!"
    configure_docker_nonroot
}

configure_docker_nonroot() {
    warn "Configuring Docker for non-root usage..."
    warn "This requires sudo to add you to the docker group..."

    getent group docker >/dev/null || sudo groupadd docker
    sudo usermod -aG docker "$USER"

    success "Docker configured for non-root usage!"
    warn "You need to log out and back in for group changes to take effect."
    warn "Or run: ${CYAN}newgrp docker"
    warn "Then run 'claudebox' again."
    info "Trying to activate docker group in current shell..."
    exec newgrp docker
}

docker_exec_root() {
    docker exec -u root "$@"
}

docker_exec_user() {
    docker exec -u "$DOCKER_USER" "$@"
}

# _setup_vpn_routing: Apply host iptables rules so Docker containers can reach corporate
# VPN resources. Detects VPN interfaces from ip route; idempotent (checks before adding).
# Requires passwordless sudo for iptables; prints manual commands if unavailable.
_setup_vpn_routing() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        return 0
    fi
    if ! command -v ip >/dev/null 2>&1; then
        return 0
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi

    local default_iface
    default_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -z "$default_iface" ]]; then
        return 0
    fi

    local docker_cidr
    docker_cidr=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
    if [[ -z "$docker_cidr" ]]; then
        return 0
    fi

    local vpn_ifaces
    vpn_ifaces=$(ip route 2>/dev/null | awk '
        /dev / && ($1 ~ /^10\./ ||
                   $1 ~ /^172\.1[6-9]\./ || $1 ~ /^172\.2[0-9]\./ || $1 ~ /^172\.3[01]\./ ||
                   $1 ~ /^192\.168\./) {
            for (i = 1; i <= NF; i++) if ($i == "dev") print $(i+1)
        }
    ' 2>/dev/null | sort -u 2>/dev/null) || true

    if [[ -z "$vpn_ifaces" ]]; then
        return 0
    fi

    local have_sudo=false
    if sudo -n true 2>/dev/null; then
        have_sudo=true
    fi

    local iface
    while IFS= read -r iface; do
        if [[ -z "$iface" ]]; then
            continue
        fi
        if [[ "$iface" == "$default_iface" ]]; then
            continue
        fi
        case "$iface" in
            lo|docker*|br-*|veth*)
                continue
                ;;
        esac

        if [[ "$have_sudo" != "true" ]]; then
            printf '[claudebox] VPN routing: passwordless sudo needed for iptables on %s. Run manually:\n' "$iface" >&2
            printf '  sudo iptables -t nat -A POSTROUTING -s %s -o %s -j MASQUERADE\n' "$docker_cidr" "$iface" >&2
            printf '  sudo iptables -I DOCKER-USER -i docker0 -o %s -j ACCEPT\n' "$iface" >&2
            printf '  sudo iptables -I DOCKER-USER -i %s -o docker0 -m state --state RELATED,ESTABLISHED -j ACCEPT\n' "$iface" >&2
            continue
        fi

        if ! sudo -n iptables -t nat -C POSTROUTING -s "$docker_cidr" -o "$iface" -j MASQUERADE 2>/dev/null; then
            sudo -n iptables -t nat -A POSTROUTING -s "$docker_cidr" -o "$iface" -j MASQUERADE 2>/dev/null || true
        fi

        if ! sudo -n iptables -C DOCKER-USER -i docker0 -o "$iface" -j ACCEPT 2>/dev/null; then
            sudo -n iptables -I DOCKER-USER -i docker0 -o "$iface" -j ACCEPT 2>/dev/null || true
        fi

        if ! sudo -n iptables -C DOCKER-USER -i "$iface" -o docker0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
            sudo -n iptables -I DOCKER-USER -i "$iface" -o docker0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        fi

        if [[ "$VERBOSE" == "true" ]]; then
            printf '[claudebox] VPN routing configured: %s -> docker bridge %s\n' "$iface" "$docker_cidr" >&2
        fi

    done <<< "$vpn_ifaces"
}

# run_claudebox_container - Main entry point for container execution
# Usage: run_claudebox_container <container_name> <mode> [args...]
# Args:
#   container_name: Name for the container (empty for auto-generated)
#   mode: "interactive", "detached", "pipe", or "attached"
#   args: Commands to pass to claude in container
# Returns: Exit code from container
# Note: Handles all mounting, environment setup, and security configuration
run_claudebox_container() {
    local container_name="$1"
    local run_mode="$2"  # "interactive", "detached", "pipe", or "attached"
    shift 2
    local container_args=("$@")
    
    # Handle "attached" mode - start detached, wait, then attach
    if [[ "$run_mode" == "attached" ]]; then
        # Start detached
        run_claudebox_container "$container_name" "detached" "${container_args[@]}" >/dev/null
        
        # Show progress while container initializes
        fillbar
        
        # Wait for container to be ready
        while ! docker exec "$container_name" true ; do
            sleep 0.1
        done
        
        fillbar stop
        
        # Attach to ready container
        docker attach "$container_name"
        
        return
    fi
    
    local docker_args=()
    
    # Set run mode
    case "$run_mode" in
        "interactive")
            # Only use -it if we have a TTY
            if [ -t 0 ] && [ -t 1 ]; then
                docker_args+=("-it")
            fi
            # Use --rm for auto-cleanup unless it's an admin container
            # Admin containers need to persist so we can commit changes
            if [[ -z "$container_name" ]] || [[ "$container_name" != *"admin"* ]]; then
                docker_args+=("--rm")
            fi
            if [[ -n "$container_name" ]]; then
                docker_args+=("--name" "$container_name")
            fi
            docker_args+=("--init")
            ;;
        "detached")
            docker_args+=("-d")
            if [[ -n "$container_name" ]]; then
                docker_args+=("--name" "$container_name")
            fi
            ;;
        "pipe")
            docker_args+=("--rm" "--init")
            ;;
    esac
    
    # Always check for tmux socket and mount if available (or create one)
    local tmux_socket=""
    local tmux_socket_dir=""
    
    # If TMUX env var is set, extract socket path from it
    if [[ -n "${TMUX:-}" ]]; then
        # TMUX format is typically: /tmp/tmux-1000/default,23456,0
        tmux_socket="${TMUX%%,*}"
        tmux_socket_dir=$(dirname "$tmux_socket")
    else
        # Look for existing tmux socket or determine where to create one
        local uid=$(id -u)
        local default_socket_dir="/tmp/tmux-$uid"
        
        # Check common locations for existing sockets
        for socket_dir in "$default_socket_dir" "/var/run/tmux-$uid" "$HOME/.tmux"; do
            if [[ -d "$socket_dir" ]]; then
                # Find any socket in the directory
                for socket in "$socket_dir"/default "$socket_dir"/*; do
                    if [[ -S "$socket" ]]; then
                        tmux_socket="$socket"
                        tmux_socket_dir="$socket_dir"
                        break
                    fi
                done
                [[ -n "$tmux_socket" ]] && break
            fi
        done
        
        # If no socket found, ensure we have a socket directory for potential tmux usage
        if [[ -z "$tmux_socket" ]]; then
            tmux_socket_dir="$default_socket_dir"
            # Create the socket directory if it doesn't exist
            if [[ ! -d "$tmux_socket_dir" ]]; then
                mkdir -p "$tmux_socket_dir"
                chmod 700 "$tmux_socket_dir"
            fi
            
            # Check if tmux is installed and create a detached session if so
            if command -v tmux >/dev/null 2>&1; then
                # Create a minimal tmux server without attaching
                # This creates the socket but doesn't start any session
                tmux -S "$tmux_socket_dir/default" start-server \; 2>/dev/null || true
                if [[ -S "$tmux_socket_dir/default" ]]; then
                    tmux_socket="$tmux_socket_dir/default"
                    if [[ "$VERBOSE" == "true" ]]; then
                        echo "[DEBUG] Created tmux server socket at: $tmux_socket" >&2
                    fi
                fi
            fi
        fi
    fi
    
    # Mount the socket and directory if we have them
    if [[ -n "$tmux_socket_dir" ]] && [[ -d "$tmux_socket_dir" ]]; then
        # Always mount the socket directory
        docker_args+=(-v "$tmux_socket_dir:$tmux_socket_dir")
        if [[ "$VERBOSE" == "true" ]]; then
            echo "[DEBUG] Mounting tmux socket directory: $tmux_socket_dir" >&2
        fi
        
        # Mount specific socket if it exists
        if [[ -n "$tmux_socket" ]] && [[ -S "$tmux_socket" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo "[DEBUG] Tmux socket found at: $tmux_socket" >&2
            fi
        fi
        
        # Pass TMUX env var if available
        [[ -n "${TMUX:-}" ]] && docker_args+=(-e "TMUX=$TMUX")
    fi
    
    # Standard configuration for ALL containers
    docker_args+=(
        -w /workspace
        -v "$PROJECT_DIR":/workspace
        -v "$PROJECT_PARENT_DIR":/home/$DOCKER_USER/.claudebox
    )
    
    # Ensure .claude directory exists
    if [[ ! -d "$PROJECT_SLOT_DIR/.claude" ]]; then
        mkdir -p "$PROJECT_SLOT_DIR/.claude"
    fi

    docker_args+=(-v "$PROJECT_SLOT_DIR/.claude":/home/$DOCKER_USER/.claude)
    
    # Mount .claude.json only if it already exists (from previous session)
    if [[ -f "$PROJECT_SLOT_DIR/.claude.json" ]]; then
        docker_args+=(-v "$PROJECT_SLOT_DIR/.claude.json":/home/$DOCKER_USER/.claude.json)
    fi
    
    # Mount .config directory
    docker_args+=(-v "$PROJECT_SLOT_DIR/.config":/home/$DOCKER_USER/.config)
    
    # Mount .cache directory
    docker_args+=(-v "$PROJECT_SLOT_DIR/.cache":/home/$DOCKER_USER/.cache)
    
    # Mount SSH directory
    docker_args+=(-v "$HOME/.ssh":"/home/$DOCKER_USER/.ssh:ro")

    # Extra mounts from [mounts] section in profiles.ini
    if [[ -f "$PROJECT_PARENT_DIR/profiles.ini" ]]; then
        local mount_spec host_path
        while IFS= read -r mount_spec; do
            if [[ -z "$mount_spec" ]]; then
                continue
            fi
            # Expand ~ in host path
            host_path="${mount_spec%%:*}"
            host_path="${host_path/#\~/$HOME}"
            local container_path="${mount_spec#*:}"
            if [[ ! -e "$host_path" ]]; then
                printf '[mount] Warning: skipping missing host path: %s\n' "$host_path" >&2
                continue
            fi
            docker_args+=(-v "${host_path}:${container_path}")
        done < <(read_profile_section "$PROJECT_PARENT_DIR/profiles.ini" "mounts" 2>/dev/null || true)
    fi

    # Track temp files for cleanup via the EXIT trap set up later in the MCP section.
    # Declared here so the VPN gateway hook can register its temp file before MCP runs.
    declare -a mcp_temp_files=()

    # VPN: either route through the shared gateway or mount configs for in-container AWG.
    local vpn_gw_ip=""
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${VPN_GW_CONTAINER}$"; then
        vpn_gw_ip=$(docker inspect "$VPN_GW_CONTAINER" \
            --format "{{(index .NetworkSettings.Networks \"${VPN_GW_NETWORK}\").IPAddress}}" \
            2>/dev/null || true)
    fi

    if [[ -n "$vpn_gw_ip" ]]; then
        # Gateway mode: join the VPN network; a startup hook sets the default route.
        # AWG configs are NOT mounted — the gateway owns the tunnel.
        local gw_client_hook
        gw_client_hook=$(mktemp /tmp/claudebox-vpngw-client-XXXXXX.sh)
        mcp_temp_files+=("$gw_client_hook")
        cat > "$gw_client_hook" << HOOK
#!/bin/sh
ip route replace default via "${vpn_gw_ip}"
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
printf '[vpn-gw] Routing via gateway %s\n' "${vpn_gw_ip}"
HOOK
        chmod +x "$gw_client_hook"
        docker_args+=(
            --network "$VPN_GW_NETWORK"
            -e "CLAUDEBOX_VPN_GW_IP=$vpn_gw_ip"
            -v "$gw_client_hook:/etc/claudebox/startup.d/05-vpn-gw-client.sh:ro"
        )
    else
        # No gateway: mount AWG configs so the container can run the tunnel locally.
        if [[ -d "$HOME/.config/AmneziaVPN.ORG" ]]; then
            docker_args+=(-v "$HOME/.config/AmneziaVPN.ORG":"/home/$DOCKER_USER/.config/AmneziaVPN.ORG:ro")
        fi
    fi

    # ADB host server forwarding — when aosp profile is active, route adb through
    # the host's adb server so USB-attached devices are visible inside the container.
    local aosp_active=false
    if [[ -f "$PROJECT_PARENT_DIR/profiles.ini" ]]; then
        if grep -q "^aosp" "$PROJECT_PARENT_DIR/profiles.ini"; then
            aosp_active=true
        fi
    fi
    if [[ "$aosp_active" == "true" ]]; then
        # When on the VPN gateway network, host-gateway resolves to the wrong bridge IP.
        # Use the VPN network's gateway address (the host's IP on that bridge) directly.
        if [[ -n "$vpn_gw_ip" ]]; then
            docker_args+=(--add-host="host.docker.internal:${VPN_GW_SUBNET_GW}")
        else
            docker_args+=(--add-host=host.docker.internal:host-gateway)
        fi
        docker_args+=(-e ANDROID_ADB_SERVER_ADDRESS=host.docker.internal)
    fi

    # Proxy env vars from ~/.config/proxy/*.sh
    # Each script exports http_proxy / https_proxy / etc.; vars are forwarded to the container.
    local proxy_dir="$HOME/.config/proxy"
    if [[ -d "$proxy_dir" ]]; then
        local proxy_vars
        proxy_vars=$(
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
        local proxy_line
        while IFS= read -r proxy_line; do
            if [[ -n "$proxy_line" ]]; then
                docker_args+=(-e "$proxy_line")
            fi
        done <<< "$proxy_vars"
    fi

    # Mount .env file if it exists in the project directory
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        docker_args+=(-v "$PROJECT_DIR/.env":/workspace/.env:ro)
        if [[ "$VERBOSE" == "true" ]]; then
            echo "[DEBUG] Mounting .env file from project directory" >&2
        fi
    fi
    
    # Parse and prepare MCP servers for native --mcp-config support
    # Check for jq dependency first - fail fast with clear error message
    if ! command -v jq >/dev/null 2>&1; then
        printf "ERROR: jq is required for MCP server configuration but not installed.\n" >&2
        printf "Please install jq to use MCP server integration:\n" >&2
        printf "  macOS: brew install jq\n" >&2
        printf "  Ubuntu/Debian: apt-get install jq\n" >&2
        printf "  RHEL/CentOS: yum install jq\n" >&2
        exit 1
    fi
    
    # Helper function to create and merge MCP config files
    create_mcp_config_file() {
        local config_file="$1"
        local temp_file="$2"
        
        # Create temporary file with unique name
        local mcp_file=$(mktemp /tmp/claudebox-mcp-$(date +%s)-$$.json 2>/dev/null || mktemp)
        mcp_temp_files+=("$mcp_file")
        
        # Extract mcpServers if they exist
        if [[ -f "$config_file" ]] && jq -e '.mcpServers' "$config_file" >/dev/null 2>&1; then
            if [[ -f "$temp_file" ]]; then
                # Merge with existing temp file
                jq -s '.[0].mcpServers * .[1].mcpServers | {mcpServers: .}' \
                    "$temp_file" "$config_file" > "$mcp_file" 2>/dev/null
            else
                # Create new config file
                jq '{mcpServers: .mcpServers}' "$config_file" > "$mcp_file" 2>/dev/null
            fi
            printf "%s" "$mcp_file"
        else
            rm -f "$mcp_file"
            printf ""
        fi
    }
    
    local user_mcp_file=""
    local project_mcp_file=""

    # Set up cleanup trap for temporary MCP config files
    # (mcp_temp_files array is declared earlier in this function)
    cleanup_mcp_files() {
        local file
        for file in "${mcp_temp_files[@]}"; do
            if [[ -f "$file" ]]; then
                rm -f "$file"
            fi
        done
        if [[ -n "$user_mcp_file" ]] && [[ -f "$user_mcp_file" ]]; then
            rm -f "$user_mcp_file"
        fi
        if [[ -n "$project_mcp_file" ]] && [[ -f "$project_mcp_file" ]]; then
            rm -f "$project_mcp_file"
        fi
    }
    trap cleanup_mcp_files EXIT
    
    # Create user MCP config file from ~/.claude.json
    if [[ -f "$HOME/.claude.json" ]]; then
        user_mcp_file=$(create_mcp_config_file "$HOME/.claude.json" "")
        
        if [[ -n "$user_mcp_file" ]]; then
            local user_count=$(jq '.mcpServers | length' "$user_mcp_file" 2>/dev/null || echo "0")
            if [[ "$user_count" -gt 0 ]]; then
                if [[ "$VERBOSE" == "true" ]]; then
                    printf "Found %s user MCP servers\n" "$user_count" >&2
                fi
                docker_args+=(-v "$user_mcp_file":/tmp/user-mcp-config.json:ro)
                if [[ "$VERBOSE" == "true" ]]; then
                    echo "[DEBUG] Mounting user MCP configuration file" >&2
                fi
            else
                rm -f "$user_mcp_file"
                user_mcp_file=""
            fi
        fi
    fi
    
    # Create project MCP config file by merging project configs
    # Start with empty config file for merging
    local temp_project_file=$(mktemp /tmp/claudebox-project-temp-$(date +%s)-$$.json 2>/dev/null || mktemp)
    mcp_temp_files+=("$temp_project_file")
    echo '{"mcpServers":{}}' > "$temp_project_file"
    
    # Merge shared project settings first
    local merged_file=""
    if [[ -f "$PROJECT_DIR/.claude/settings.json" ]]; then
        merged_file=$(create_mcp_config_file "$PROJECT_DIR/.claude/settings.json" "$temp_project_file")
        if [[ -n "$merged_file" ]]; then
            mv "$merged_file" "$temp_project_file"
        fi
    fi
    
    # Merge local project settings (highest priority)
    if [[ -f "$PROJECT_DIR/.claude/settings.local.json" ]]; then
        merged_file=$(create_mcp_config_file "$PROJECT_DIR/.claude/settings.local.json" "$temp_project_file")
        if [[ -n "$merged_file" ]]; then
            mv "$merged_file" "$temp_project_file"
        fi
    fi
    
    # Check if we have any project servers
    local project_count=$(jq '.mcpServers | length' "$temp_project_file" 2>/dev/null || echo "0")
    if [[ "$project_count" -gt 0 ]]; then
        project_mcp_file="$temp_project_file"
        if [[ "$VERBOSE" == "true" ]]; then
            printf "Found %s project MCP servers\n" "$project_count" >&2
        fi
        docker_args+=(-v "$project_mcp_file":/tmp/project-mcp-config.json:ro)
        if [[ "$VERBOSE" == "true" ]]; then
            echo "[DEBUG] Mounting project MCP configuration file" >&2
        fi
    else
        rm -f "$temp_project_file"
        project_mcp_file=""
    fi
    
    
    # Add environment variables
    local project_name=$(basename "$PROJECT_DIR")
    local slot_name=$(basename "$PROJECT_SLOT_DIR")
    
    # Calculate slot index for hostname
    local slot_index=1  # default if we can't determine
    if [[ -n "$PROJECT_PARENT_DIR" ]] && [[ -n "$slot_name" ]]; then
        slot_index=$(get_slot_index "$slot_name" "$PROJECT_PARENT_DIR" 2>/dev/null || echo "1")
    fi
    
    docker_args+=(
        -e "NODE_ENV=${NODE_ENV:-production}"
        -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
        -e "CLAUDEBOX_PROJECT_NAME=$project_name"
        -e "CLAUDEBOX_SLOT_NAME=$slot_name"
        -e "TERM=${TERM:-xterm-256color}"
        -e "VERBOSE=${VERBOSE:-false}"
        -e "CLAUDEBOX_WRAP_TMUX=${CLAUDEBOX_WRAP_TMUX:-false}"
        -e "CLAUDEBOX_PANE_NAME=${CLAUDEBOX_PANE_NAME:-}"
        -e "CLAUDEBOX_TMUX_PANE=${CLAUDEBOX_TMUX_PANE:-}"
        --cap-add NET_ADMIN
        --cap-add NET_RAW
        --sysctl net.ipv4.conf.all.src_valid_mark=1
        --sysctl net.ipv4.conf.all.rp_filter=2
        "$IMAGE_NAME"
    )
    
    # Add any additional arguments
    if [[ ${#container_args[@]} -gt 0 ]]; then
        docker_args+=("${container_args[@]}")
    fi
    
    # Apply host iptables VPN routing rules only when NOT using the shared gateway.
    # In gateway mode the gateway container handles all NAT; host rules are not needed.
    if [[ -z "$vpn_gw_ip" ]] && \
       [[ -f "$PROJECT_PARENT_DIR/profiles.ini" ]] && \
       grep -q '^\[vpn-routing\]' "$PROJECT_PARENT_DIR/profiles.ini"; then
        _setup_vpn_routing
    fi

    # Run the container
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[DEBUG] Docker run command: docker run ${docker_args[*]}" >&2
    fi
    docker run "${docker_args[@]}"
    local exit_code=$?
    
    return $exit_code
}

check_container_exists() {
    local container_name="$1"
    
    # Check if container exists (running or stopped)
    if docker ps -a --filter "name=^${container_name}$" --format "{{.Names}}"  | grep -q "^${container_name}$"; then
        # Check if it's running
        if docker ps --filter "name=^${container_name}$" --format "{{.Names}}"  | grep -q "^${container_name}$"; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "none"
    fi
}

run_docker_build() {
    info "Running docker build..."
    export DOCKER_BUILDKIT=1
    
    # Check if we need to force rebuild due to template changes
    local no_cache_flag=""
    if [[ "${CLAUDEBOX_FORCE_NO_CACHE:-false}" == "true" ]]; then
        no_cache_flag="--no-cache"
        info "Forcing full rebuild (templates changed)"
    fi
    
    docker build \
        $no_cache_flag \
        --progress=${BUILDKIT_PROGRESS:-auto} \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        --build-arg USER_ID="$USER_ID" \
        --build-arg GROUP_ID="$GROUP_ID" \
        --build-arg USERNAME="$DOCKER_USER" \
        --build-arg NODE_VERSION="$NODE_VERSION" \
        --build-arg DELTA_VERSION="$DELTA_VERSION" \
        --build-arg REBUILD_TIMESTAMP="${CLAUDEBOX_REBUILD_TIMESTAMP:-}" \
        -f "$1" -t "$IMAGE_NAME" "$2" || error "Docker build failed"
}

export -f check_docker install_docker configure_docker_nonroot docker_exec_root docker_exec_user run_claudebox_container check_container_exists run_docker_build _setup_vpn_routing