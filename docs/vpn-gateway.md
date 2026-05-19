# ClaudeBox VPN Gateway

Runs a single shared AmneziaWG container that all ClaudeBox slots route through.
This lets you run multiple parallel Claude sessions while the VPN server sees only
one connection.

## Architecture

```
Host
├── claudebox-vpn-gw  (NET_ADMIN, awg0 tunnel, iptables MASQUERADE)
│   └── network: claudebox-vpn / 172.20.0.2
│
├── claudebox-slot-1  (default route → 172.20.0.2)
│   └── network: claudebox-vpn / 172.20.0.3
│
└── claudebox-slot-2  (default route → 172.20.0.2)
    └── network: claudebox-vpn / 172.20.0.4
```

One VPN connection on the gateway serves all slots concurrently.

## Prerequisites

**1. Add the amneziawg profile** (once per project):
```bash
cd /your/project
claudebox add amneziawg
```

**2. Place your AmneziaWG config file** on the host:
```bash
mkdir -p ~/.config/AmneziaVPN.ORG
cp your-vpn.conf ~/.config/AmneziaVPN.ORG/
```

The filename without `.conf` becomes the tunnel interface name (`vpn.conf` → interface `vpn`).

**3. Create container slots:**
```bash
claudebox create   # repeat for each parallel slot you want
```

## Starting the gateway

Run once from the project directory whose image has the amneziawg profile:

```bash
claudebox vpn-gw start
```

```
VPN gateway started
Gateway IP: 172.20.0.2
New ClaudeBox containers will route all traffic through the VPN gateway.
```

Check status:
```bash
claudebox vpn-gw status
```

## Launching containers

Start Claude normally — each container automatically detects the running gateway:

```bash
claudebox              # single session
claudebox tmux 3       # three parallel sessions
claudebox slot 2       # specific slot
```

Container startup sequence:
1. `05-vpn-gw-client.sh` runs as root → `ip route replace default via 172.20.0.2`
2. `10-amneziawg.sh` runs → finds no AWG configs (not mounted), exits silently
3. Claude starts with all traffic going through the gateway tunnel

## Stopping

```bash
claudebox vpn-gw stop
```

Stop running containers first for a clean shutdown:
```bash
claudebox kill all
claudebox vpn-gw stop
```

## Corporate VPN access (vpn-routing)

If you also need to reach resources on a corporate VPN (running on the host), configure
`vpn-routing` **before** starting the gateway — `vpn-gw start` reads the CIDRs at launch time.

```bash
claudebox vpn-routing enable
claudebox vpn-routing add 10.10.0.0/16 192.168.50.0/24
claudebox vpn-gw start
```

What happens under the hood:

| Layer | Action |
|-------|--------|
| Gateway container | `ip rule add to <cidr> lookup main priority 100` — corporate CIDRs bypass `awg0` and exit via `eth0` back to the host |
| Host | `iptables MASQUERADE` from `172.20.0.0/16` → corporate VPN interface, so the return traffic reaches the containers |
| Client containers | No change needed — they route all traffic to the gateway, which decides where each destination goes |

If you add or change CIDRs after the gateway is already running, restart it:

```bash
claudebox vpn-routing add 10.20.0.0/16
claudebox vpn-gw stop
claudebox vpn-gw start
```

## Troubleshooting

**Gateway fails to start:**
```bash
docker logs claudebox-vpn-gw
```
Common causes: AWG config syntax error, VPN server unreachable, amneziawg profile
not in the image (run `claudebox add amneziawg` then rebuild).

**Container can't reach the internet:**
```bash
claudebox shell
ip route show default   # should show 172.20.x.x, not 172.17.x.x
```

**Subnet conflict** (`172.20.0.0/16` clashes with your network):
Edit `VPN_GW_SUBNET` and `VPN_GW_SUBNET_GW` in `lib/env.sh`, remove the old network,
then restart the gateway:
```bash
docker network rm claudebox-vpn
claudebox vpn-gw start
```
