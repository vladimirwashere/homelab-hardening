# Phase 09 — VPN Egress for Auxiliary Containers

> **Time required:** ~45 minutes

## Why this phase

Routing selected auxiliary container traffic through a VPN container gives us:

1. **Outbound IP anonymity** — auxiliary workloads talking to GitHub, OpenAI, package mirrors, or other public services see a VPN IP, not your home IP.
2. **A chokepoint we control** — the specific workloads you route through it share one tunnel, which is easier to monitor and test.
3. **Encrypted transport** to the VPN exit, useful if you don't fully trust your ISP.
4. **Kill switch** — if the VPN drops, those routed workloads stop instead of leaking via your real IP.

This guide uses `qmcgaw/gluetun` as the VPN gateway container, with **NordVPN manual service credentials**. Previous attempts used `bubuntux/nordvpn` with access tokens and NordLynx; that path is no longer documented here because the image is unmaintained and proved unreliable in this environment.

Important: this phase does **not** route the host-native main Hermes session through the VPN. It only covers containerized auxiliary workloads that you explicitly attach to Gluetun. If you want host-wide VPN egress, that is a different design.

## What we're building

- A `gluetun` container running NordVPN over OpenVPN, with kill-switch enabled and built-in DNS filtering inside the VPN namespace
- A localhost-only control API for status and kill-switch testing
- A container template for auxiliary workloads to share the VPN namespace (`--network container:gluetun`)
- A test container showing its public IP = VPN exit IP
- Network design: auxiliary workloads can `--network container:gluetun` to share its netns and egress gateway, while the host-native main agent stays on the normal host network
- Built-in DNS filtering inside the VPN namespace (separate from AdGuard on the host)
- A localhost-only control API for status and kill-switch testing

## Prerequisites

- Phase 8 complete
- NordVPN **manual service credentials** (NOT your account password, and NOT the old token flow)
- `/dev/net/tun` available on the host

This phase is optional in both profiles. Use it only when you want encrypted egress for auxiliary containers.

## Dependency and optionality

- This entire phase is optional.
- Required before this phase: Phase 08.
- Downstream dependency: no baseline phase requires this; Phase 10 is independent of this phase.
- If you skip this phase, continue with Phase 10 (visibility-first) or go directly to Phase 11 (performance-first).

## Step 9.1 — Get your NordVPN manual service credentials

1. Log into <https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/service-credentials/>
2. Copy the **service username** and **service password**
3. Store both in your password manager

**⚠️ Never share or commit these credentials. They are still secrets.**

## Step 9.2 — Create the Gluetun config files

```bash
mkdir -p ~/containers/gluetun

cat > ~/containers/gluetun/gluetun.env <<'EOF'
VPN_SERVICE_PROVIDER=nordvpn
VPN_TYPE=openvpn
OPENVPN_USER=REPLACE_WITH_NORDVPN_SERVICE_USERNAME
OPENVPN_PASSWORD=REPLACE_WITH_NORDVPN_SERVICE_PASSWORD
SERVER_COUNTRIES=Netherlands
OPENVPN_PROTOCOL=udp
FIREWALL_OUTBOUND_SUBNETS=172.30.0.0/24
BLOCK_MALICIOUS=on
BLOCK_SURVEILLANCE=on
BLOCK_ADS=on
DNS_UPSTREAM_RESOLVERS=cloudflare,quad9
DNS_UPSTREAM_IPV6=off
PUID=0
PGID=0
PUBLICIP_ENABLED=false
HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH=/gluetun/auth/config.toml
EOF

cat > ~/containers/gluetun/control-server.toml <<'EOF'
[[roles]]
name = "local-admin"
routes = ["GET /v1/vpn/status", "PUT /v1/vpn/status", "GET /v1/dns/status"]
auth = "basic"
username = "gluetun"
password = "REPLACE_WITH_A_LONG_RANDOM_PASSWORD"
EOF

chmod 600 ~/containers/gluetun/gluetun.env ~/containers/gluetun/control-server.toml
```

Explanation:

- `OPENVPN_USER` / `OPENVPN_PASSWORD` are NordVPN **manual service credentials**
- `FIREWALL_OUTBOUND_SUBNETS=172.30.0.0/24` allows the shared VPN namespace to reach local bridge services on `agentnet` (e.g. AdGuard, Ollama) while still blocking direct LAN access
- `BLOCK_*` and `DNS_UPSTREAM_RESOLVERS` keep DNS for VPN-routed containers inside Gluetun by default and block malicious domains at the VPN level, independent of the host AdGuard setup (we want DNS filtering to work even if an agent is misconfigured to bypass the host resolver)
- `PUID=0` / `PGID=0` avoid known OpenVPN file-ownership failures in this stack
- `PUBLICIP_ENABLED=false` suppresses a non-fatal public-IP file write error; public IP is verified with `curl` instead of Gluetun's status file

## Step 9.3 — Start the Gluetun container

```bash
podman run -d --replace \
  --name gluetun \
  --network agentnet \
  --ip 172.30.0.20 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add NET_BIND_SERVICE \
  --device /dev/net/tun \
  --env-file ~/containers/gluetun/gluetun.env \
  -v ~/containers/gluetun/control-server.toml:/gluetun/auth/config.toml:Z \
  -p 127.0.0.1:8000:8000/tcp \
  --restart=unless-stopped \
  docker.io/qmcgaw/gluetun:latest
```

Verify it is up:

```bash
podman ps
podman logs gluetun | tail -30
```

Look for: `Initialization Sequence Completed`.

## Step 9.4 — Verify your apparent IP changed

From a test container that routes through Gluetun:

```bash
podman run --rm --network container:gluetun docker.io/curlimages/curl:latest \
  curl -s https://ifconfig.me
echo
```

Expected: an IP that's **not** your home public IP. It should be the VPN provider's exit IP.

Compare to your real public IP:

```bash
# From your Client (NOT through the Server)
curl -s https://ifconfig.me
echo
```

These should be different.

## Step 9.5 — Test the kill switch

Gluetun exposes a localhost-only control server on port `8000`. We'll use it to stop and restart the VPN without tearing down the container itself. First, test the API:

```bash
BASE=http://127.0.0.1:8000
AUTH=gluetun:REPLACE_WITH_A_LONG_RANDOM_PASSWORD

# Confirm the VPN is running
curl -su "$AUTH" "$BASE/v1/vpn/status"

# Record pre-state
podman run --rm --network container:gluetun docker.io/curlimages/curl:latest \
  curl -s -m 5 https://ifconfig.me

# Stop the VPN inside the container
curl -su "$AUTH" -X PUT "$BASE/v1/vpn/status" \
  -H "Content-Type: application/json" \
  -d '{"status":"stopped"}'

# Try again — should FAIL (no internet through this container)
podman run --rm --network container:gluetun docker.io/curlimages/curl:latest \
  curl -s -m 5 https://ifconfig.me
curl_ec=$?
echo "Exit code: ${curl_ec}"

# Restart the VPN
curl -su "$AUTH" -X PUT "$BASE/v1/vpn/status" \
  -H "Content-Type: application/json" \
  -d '{"status":"running"}'
sleep 10
podman run --rm --network container:gluetun docker.io/curlimages/curl:latest \
  curl -s https://ifconfig.me
echo
```

The middle `curl` should fail with timeout. Kill switch works. The last `curl` should succeed and show the VPN exit IP again.

## Step 9.6 — Understand DNS in the VPN namespace

VPN-routed containers now use **Gluetun's** built-in DNS by default, not AdGuard. That is deliberate: it keeps DNS inside the VPN namespace instead of sending it to a local bridge resolver outside the tunnel. This way, if an agent is compromised and tries to bypass the VPN with direct DNS queries, it still faces Gluetun's filtering rules (e.g., blocking malicious domains). It's an extra layer of defense.

Phase 8 AdGuard still remains the **host** resolver and dashboard. VPN-routed containers use Gluetun DNS by default, so those DNS queries do not appear in AdGuard unless you explicitly route DNS there. This separation also means that if Gluetun is stopped, VPN-routed containers won't accidentally leak DNS queries to AdGuard or the public Internet. They simply won't resolve anything until the VPN is back up.

Basic DNS test inside the VPN namespace:

```bash
podman run --rm --network container:gluetun docker.io/alpine:latest \
  sh -c 'apk add --no-cache bind-tools >/dev/null && nslookup google.com 127.0.0.1'
```

And a blocked-domain spot check:

```bash
podman run --rm --network container:gluetun docker.io/alpine:latest \
  sh -c 'apk add --no-cache bind-tools >/dev/null && nslookup doubleclick.net 127.0.0.1'
```

Expected: `google.com` resolves normally, while `doubleclick.net` is blocked (for example `0.0.0.0`, no answer, or another blocked response depending on the current Gluetun release).

## Step 9.7 — Quadlet for persistence

Root-only build: install the quadlet as a **system** unit in `/etc/containers/systemd/` (managed with plain `systemctl`, no `--user`). `%h` resolves to `/root`.

```bash
install -d -m 755 /etc/containers/systemd
nano /etc/containers/systemd/gluetun.container
```

Contents:

```ini
[Unit]
Description=VPN egress gateway (Gluetun + NordVPN)
After=network-online.target

[Container]
Image=docker.io/qmcgaw/gluetun:latest
ContainerName=gluetun
Network=agentnet
IP=172.30.0.20
AddCapability=NET_ADMIN
AddCapability=NET_RAW
AddCapability=NET_BIND_SERVICE
AddDevice=/dev/net/tun
EnvironmentFile=%h/containers/gluetun/gluetun.env
Volume=%h/containers/gluetun/control-server.toml:/gluetun/auth/config.toml:Z
PublishPort=127.0.0.1:8000:8000/tcp

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
```

Stop the manual container:

```bash
podman stop gluetun
podman rm gluetun
```

Start via systemd:

```bash
systemctl daemon-reload
systemctl start gluetun.service
systemctl enable gluetun.service
systemctl status gluetun.service
```

## Step 9.8 — Container template for agents (preview)

For agent containers to use the VPN, they use Podman's "container network" mode:

```bash
# Just an example — DON'T run this as an agent yet (Phase 12)
podman run --rm --network container:gluetun docker.io/curlimages/curl:latest \
  curl -s https://ifconfig.me
echo
```

`--network container:gluetun` means: use the same network namespace as the `gluetun` container. The new container literally shares its network interfaces. Its outbound traffic exits via the VPN tunnel; its kill-switch is Gluetun's firewall.

Use this pattern for auxiliary containerized workloads you intentionally run through the VPN. The host-native `main` Hermes session in Phase 12 does not use this path by default. It keeps the design simple: one VPN container, and only explicitly delegated workloads share its network stack. If the VPN is down, those delegated workloads have no network access until it returns.

## Verification checklist

- [ ] `gluetun` container is running without errors (`podman ps` + `podman logs gluetun`)
- [ ] `podman logs gluetun` shows `Initialization Sequence Completed` indicating a successful VPN connection
- [ ] Test container `curl ifconfig.me` returns the VPN exit IP, not your home IP (`podman run --rm --network container:gluetun docker.io/curlimages/curl:latest curl -s https://ifconfig.me`)
- [ ] Kill switch test passes (`stopped` → `curl` fails) → (`running` → `curl` succeeds again)
- [ ] DNS inside the VPN namespace works (`nslookup google.com 127.0.0.1`)
- [ ] systemd quadlet starts the VPN container on boot (`systemctl enable gluetun.service`) and it comes up without errors (`systemctl status gluetun.service`)

## Troubleshooting

**`/dev/net/tun` is missing.** Load it on the host: `modprobe tun`. If it doesn't persist across reboots, add `tun` to `/etc/modules-load.d/tun.conf`. Gluetun needs this to create the VPN tunnel interface. Without it, the container will fail to initialize the VPN connection.

**`podman logs gluetun` shows `writing configuration to file: chown /etc/openvpn/target.ovpn: operation not permitted`.** Make sure `PUID=0` and `PGID=0` are present in `/root/containers/gluetun/gluetun.env`, then recreate the container.

**`podman logs gluetun` shows `listen tcp :53: bind: permission denied`.** Make sure `NET_BIND_SERVICE` is present in the `podman run` command (or quadlet) so Gluetun can bind its internal DNS service. Without it, DNS inside the VPN namespace won't work and you'll see errors about binding to port 53. This won't break the VPN tunnel itself, but any container sharing Gluetun's network will fail to resolve DNS queries.

**Authentication fails with NordVPN.** This guide uses **manual service credentials**, not your Nord account password and not the old token path.

**VPN connects but local bridge services stop working.** Check `FIREWALL_OUTBOUND_SUBNETS=172.30.0.0/24` is set so the shared VPN namespace can still reach `agentnet`.

## Next

→ Optional next: [Phase 10: Suricata — network IDS](10-suricata-ids.md)

→ Baseline next (if skipping visibility-first): [Phase 11: CrowdSec — HIDS + community blocklist](11-crowdsec.md)
