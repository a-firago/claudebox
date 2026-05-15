#!/bin/bash
# DESCRIPTION: AmneziaWG Tools (awg, awg-quick VPN client utilities)

# Install amneziawg-tools from the Amnezia PPA.
#
# NOTE: Only userspace tools are installed here — the kernel module (amneziawg.ko)
# cannot be loaded inside a Docker container since containers share the host kernel.
# To bring up an AWG tunnel you also need --cap-add=NET_ADMIN on the container:
#   claudebox save --cap-add=NET_ADMIN

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[amneziawg] Installing prerequisites..."
# resolvconf is intentionally excluded: its post-install script tries to replace
# /etc/resolv.conf with a symlink, which fails in Docker (bind-mounted by the runtime).
apt-get update
apt-get install -y --no-install-recommends \
    gnupg \
    iproute2 \
    apt-transport-https \
    ca-certificates

echo "[amneziawg] Importing Amnezia PPA signing key..."
gpg --keyserver keyserver.ubuntu.com \
    --recv-keys 75C9DD72C799870E310542E24166F2C257290828

gpg --export 75C9DD72C799870E310542E24166F2C257290828 \
    | tee /usr/share/keyrings/amnezia.gpg > /dev/null

echo "[amneziawg] Adding Amnezia PPA repository..."
echo "deb [signed-by=/usr/share/keyrings/amnezia.gpg] \
https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" \
    | tee /etc/apt/sources.list.d/amnezia.list

echo "[amneziawg] Updating package index..."
apt-get update

echo "[amneziawg] Installing amneziawg-tools..."
apt-get install -y --no-install-recommends \
    amneziawg-tools

echo "[amneziawg] Installing Docker compatibility stubs..."
# awg-quick calls sysctl and resolvconf at runtime; both need Docker workarounds:
# - sysctl: Docker sets net.ipv4.conf.all.src_valid_mark=1 at container creation;
#   runtime write is denied even though the value is already correct.
# - resolvconf: Docker bind-mounts /etc/resolv.conf so the real resolvconf cannot
#   manage it as a symlink. We install a stub that writes nameserver lines directly
#   to /etc/resolv.conf so VPN DNS servers are applied when the tunnel comes up.
#   Without this, Docker's injected DNS (a host-private IP) becomes unreachable
#   when AllowedIPs = 0.0.0.0/0 routes all traffic through the tunnel.
sed -i '/net\.ipv4\.conf\.all\.src_valid_mark/d' /usr/bin/awg-quick
cat > /usr/local/bin/resolvconf << 'RESOLVCONF_STUB'
#!/bin/sh
# Docker resolvconf stub: writes VPN DNS servers directly to /etc/resolv.conf.
# awg-quick calls: resolvconf -a <iface> -m 0 -x  (nameserver lines on stdin)
#                  resolvconf -d <iface>
action=''
for arg in "$@"; do
    case "$arg" in
        -a) action=add ;;
        -d) action=del ;;
    esac
done
case "$action" in
    add)
        cp /etc/resolv.conf /etc/resolv.conf.vpn-backup 2>/dev/null || true
        ns=$(grep '^nameserver')
        if [ -n "$ns" ]; then
            printf '%s\n' "$ns" > /etc/resolv.conf
        fi
        ;;
    del)
        if [ -f /etc/resolv.conf.vpn-backup ]; then
            mv /etc/resolv.conf.vpn-backup /etc/resolv.conf
        fi
        ;;
esac
exit 0
RESOLVCONF_STUB
chmod +x /usr/local/bin/resolvconf

echo "[amneziawg] Installing startup hook..."
# The hook runs as root at container start (via /etc/claudebox/startup.d/).
# It brings up all *.conf files found in any user's AmneziaVPN.ORG directory.
mkdir -p /etc/claudebox/startup.d
cat > /etc/claudebox/startup.d/10-amneziawg.sh << 'STARTUP_HOOK'
#!/bin/sh
# Auto-start AmneziaWG VPN tunnels at container startup.
# Iterates all .conf files mounted from the host under ~/.config/AmneziaVPN.ORG/.
for conf in /home/*/.config/AmneziaVPN.ORG/*.conf; do
    if [ ! -f "$conf" ]; then
        continue
    fi
    printf '[amneziawg] Starting VPN: %s\n' "$(basename "$conf")"
    if ! awg-quick up "$conf" 2>&1; then
        printf '[amneziawg] Warning: failed to start %s\n' "$(basename "$conf")" >&2
    fi
done
STARTUP_HOOK
chmod +x /etc/claudebox/startup.d/10-amneziawg.sh

echo "[amneziawg] Installation complete."
awg --version 2>/dev/null && echo "[amneziawg] awg: OK" || true
which awg-quick && echo "[amneziawg] awg-quick: OK" || true
