# Phase 08 — AdGuard Home: DNS Sinkhole + Blocklists

> **Time required:** ~30 minutes

## Why this phase

DNS is the chokepoint where almost all malware and data exfiltration must look up names. Sinkholing known-bad domains at the resolver kills C2 communication, blocks ad/tracker networks, and stops phishing redirects — *before* TCP/TLS is even attempted.

AdGuard Home does this with modern features: DoH/DoT support natively, per-client policies, sleek dashboard with stats. We run it in a support container, configure it as the host's DNS, and load comprehensive blocklists curated specifically for security (not just ads). This gives the host-native Hermes main session a filtered resolver by default. Auxiliary VPN-routed containers can switch to Gluetun's built-in DNS in Phase 9 if you use that optional path.

## What we're building

- AdGuard Home running as a Podman support container, bound to localhost and a dedicated IP on the `agentnet` bridge
- Configured with blocklists targeting malware/C2/phishing (4+ million domains total)
- The host's `/etc/resolv.conf` pointing at AdGuard for DNS resolution
- A test showing blocked queries
- AdGuard's web UI accessible from Mac via SSH tunnel
- A local-only dashboard surface by default, not a LAN-exposed admin page

## Prerequisites

- Phase 7 complete

AdGuard remains useful in both profiles. Even if you later skip the optional Phase 09 VPN path, the host-native Hermes session still benefits from AdGuard as the host resolver.

## Dependency and optionality

- Required before this phase: Phase 07 container baseline.
- In this repo's sequence, this phase is required before Phase 09 and Phase 10.
- If you defer this phase, also defer Phases 09-10 as currently documented.
- Optional steps in this phase:
  - Step 8.2b low-port sysctl tweak is only needed if port binding on `53` fails in your environment.

## Step 8.1 — Free up port 53 on the host

Ubuntu 26.04 runs `systemd-resolved` which listens on 127.0.0.53:53. We need to coexist:

```bash
# Disable the systemd-resolved DNS stub
nano /etc/systemd/resolved.conf
```

Find or add:

```text
[Resolve]
DNSStubListener=no
```

Symlink `/etc/resolv.conf` to the real systemd-resolved file (so it doesn't manage it through the stub):

```bash
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved

# Verify port 53 is free
ss -tlnp | grep ':53 '
# Should return nothing (or only AdGuard's container, after the next step)
```

## Step 8.2 — Create persistent storage for AdGuard

```bash
mkdir -p ~/containers/adguard/{work,conf}
```

If Podman fails to bind host port 53 with `permission denied`, you can relax low-port binding on the host. This is optional and broadens host behavior, so prefer container capabilities first.

### Step 8.2b — Optional: allow low-port binding

```bash
echo 'net.ipv4.ip_unprivileged_port_start=53' | tee /etc/sysctl.d/99-lowports.conf
sysctl --system | grep ip_unprivileged_port_start
```

## Step 8.3 — Start AdGuard Home container

```bash
podman run -d \
  --name adguard \
  --network agentnet \
  --ip 172.30.0.10 \
  --cap-add=NET_BIND_SERVICE \
  --cap-add=SETUID \
  --cap-add=SETGID \
  -p 127.0.0.1:3000:3000/tcp \
  -p 127.0.0.1:53:53/udp \
  -p 127.0.0.1:53:53/tcp \
  -v ~/containers/adguard/work:/opt/adguardhome/work:Z \
  -v ~/containers/adguard/conf:/opt/adguardhome/conf:Z \
  --restart=unless-stopped \
  docker.io/adguard/adguardhome:latest
```

> On this root-only build, publish AdGuard to host loopback (`127.0.0.1`) instead of a container-only address like `172.30.0.10`.

Verify:

```bash
podman ps
podman logs adguard | head -20
```

## Step 8.4 — Initial setup via web UI

Need to reach the dashboard on port 3000 (bound to 127.0.0.1 — not exposed to LAN). Use a Tailscale SSH tunnel from the Client:

On your **Client**:

```bash
tailscale ssh -L 3000:127.0.0.1:3000 root@homelab
# Leave this terminal open
```

If your local Tailscale SSH build does not support `-L`, temporarily use the break-glass OpenSSH path from Phase 03, then close it again immediately after setup.

If you use OpenSSH for this fallback tunnel, temporarily set `AllowTcpForwarding yes` in `sshd_config`, validate with `sshd -t`, restart `sshd`, complete setup, then restore `AllowTcpForwarding no` and disable `sshd` again.

In your browser: `http://localhost:3000`

The AdGuard initial-setup wizard appears:

1. **Web admin interface:** keep it local-only for this build (avoid exposing admin beyond localhost/tunnel paths)
2. **DNS server:** keep DNS bound to the local host-published path used in this phase
3. **Admin user:** create username + strong password (store in PM)
4. **Done** → log in

> ⚠️ **Never share or expose your AdGuard admin password.** Store it in a password manager.

The important part is the *host* publish target, not the container's internal bind. Keep the published UI on `127.0.0.1:3000` so the dashboard stays local unless you intentionally tunnel or expose it later.

## Step 8.5 — Configure upstream DNS

In AdGuard UI: **Settings → DNS settings → Upstream DNS servers**.

Replace with reputable encrypted resolvers (DoH for privacy + integrity):

```text
https://cloudflare-dns.com/dns-query
https://dns.quad9.net/dns-query
https://dns.adguard-dns.com/dns-query
```

**Bootstrap DNS** (used to resolve the DoH endpoints themselves):

```text
192.168.10.1
```

**Load-balancing strategy:** Load balancing.

Save. Test:

```bash
# From server SSH:
dig @127.0.0.1 google.com
# Expect: an answer
```

## Step 8.6 — Add comprehensive blocklists

In AdGuard UI: **Filters → DNS blocklists → Add blocklist → Add a custom list**.

Add these in turn (one at a time; each takes a moment to download):

| Name | URL | Why |
| --- | --- | --- |
| Hagezi Pro | `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt` | Best curated security-focused list 2025 |
| Hagezi TIF (Threat Intelligence) | `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt` | Threat-intelligence-driven blocks |
| OISD Big | `https://big.oisd.nl/` | Comprehensive ads+malware |
| Phishing Army | `https://phishing.army/download/phishing_army_blocklist_extended.txt` | Anti-phishing |
| ph00lt0 blocklist | `https://github.com/ph00lt0/blocklist/raw/master/host_blocklists.txt` | Strict tracker/spyware |
| Stalkerware Indicators | `https://raw.githubusercontent.com/AssoEchap/stalkerware-indicators/master/generated/hosts` | Spyware/stalkerware |

After all are added, click **Check for updates**. Total should be a few million domains.

## Step 8.7 — Configure DNS security features

**Settings → DNS settings → DNS server configuration**:

- ✓ Block IPv6 AAAA queries (we disabled IPv6 in Phase 5)
- ✓ Enable DNSSEC (validates DNS responses are signed)
- ✓ Disable resolving of /etc/hosts entries from filter (clean separation)

**Settings → General settings**:

- Disable: "Show statistics for the last X" (privacy — don't keep query logs forever)
  - Set retention to: 1 day for dashboard, 0 days for query log (or whatever fits)

## Step 8.8 — Update nftables for AdGuard

Before switching the host resolver to AdGuard, confirm the AdGuard container can resolve upstream DNS successfully:

```bash
# Test from inside AdGuard container
podman exec adguard nslookup google.com 127.0.0.1
```

Should resolve via upstream DoH (port 443 outbound, already allowed by Phase 6).

## Step 8.9 — Adjust nftables to allow host DNS to AdGuard

If you follow this guide's localhost setup (`127.0.0.1:53`), no extra nftables rule is needed for host-to-AdGuard DNS.

If you intentionally query AdGuard on `172.30.0.10`, add explicit allow rules in the `output` chain (after `ct state` rules, before `@rfc1918_v4`) and reload nftables:

```bash
nano /etc/nftables.conf
```

In the `output` chain, **near the top**, add (after `ct state` rules, before the `@rfc1918_v4` rules):

```nft
# Allow DNS to AdGuard container
ip daddr 172.30.0.10 udp dport 53 accept
ip daddr 172.30.0.10 tcp dport 53 accept
```

Reload:

```bash
nft -f /etc/nftables.conf
```

## Step 8.10 — Point host's resolver at AdGuard

```bash
nano /etc/systemd/resolved.conf
```

Set:

```text
[Resolve]
DNS=127.0.0.1
FallbackDNS=
DNSStubListener=no
```

Restart:

```bash
systemctl restart systemd-resolved

# Verify
resolvectl status | grep "Current DNS Server"
# Expect: 127.0.0.1
```

## Step 8.11 — Test blocking

```bash
# Should be allowed
dig google.com +short
# Expect: a real IP

# Should be blocked (Hagezi)
dig doubleclick.net +short
# Expect: 0.0.0.0 or no answer

# Another known-blocked domain
dig googleads.g.doubleclick.net +short
```

In AdGuard UI: **Query Log** — you should see these queries with "Blocked by filter" labels. Try a few more known-bad domains from the blocklists to confirm. Also check the dashboard stats to see blocked query counts.

## Step 8.12 — Persist AdGuard across reboots (systemd quadlet)

Root-only build: install the quadlet as a **system** unit in `/etc/containers/systemd/` (managed with plain `systemctl`, no `--user`). `%h` resolves to `/root`.

```bash
install -d -m 755 /etc/containers/systemd
nano /etc/containers/systemd/adguard.container
```

Contents:

```ini
[Unit]
Description=AdGuard Home DNS sinkhole
After=network-online.target

[Container]
Image=docker.io/adguard/adguardhome:latest
ContainerName=adguard
Network=agentnet
IP=172.30.0.10
AddCapability=NET_BIND_SERVICE
AddCapability=SETUID
AddCapability=SETGID
PublishPort=127.0.0.1:3000:3000/tcp
PublishPort=127.0.0.1:53:53/udp
PublishPort=127.0.0.1:53:53/tcp
Volume=%h/containers/adguard/work:/opt/adguardhome/work:Z
Volume=%h/containers/adguard/conf:/opt/adguardhome/conf:Z

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Stop the manually-run container and let systemd manage:

```bash
podman stop adguard
podman rm adguard

systemctl daemon-reload
systemctl start adguard.service
systemctl enable adguard.service
systemctl status adguard.service
```

## Verification checklist

- [ ] AdGuard UI accessible via SSH tunnel + `localhost:3000`
- [ ] At least 4 blocklists loaded with millions of domains total
- [ ] `dig google.com` works (allowed)
- [ ] `dig doubleclick.net` returns 0.0.0.0 (blocked)
- [ ] Host's `resolvectl status` shows DNS = 127.0.0.1 (AdGuard)
- [ ] AdGuard restarts after reboot (without errors in logs)

> Phase 9 note: the default VPN path uses Gluetun's built-in DNS for VPN-routed containers. AdGuard remains the host resolver and dashboard from this phase onward.

For this repo's host-native Hermes baseline, that means:

- the main Hermes session uses AdGuard on the host by default
- auxiliary VPN-routed containers can use Gluetun DNS if you intentionally attach them there
- the AdGuard dashboard remains local-only unless you deliberately create a tailnet-only access path

## Issues encountered and solutions

- **Bootstrap DNS timeouts under strict egress policy:** AdGuard could stall when bootstrap resolvers were blocked. Setting bootstrap DNS to Router 3 (`192.168.10.1`) stabilized endpoint resolution.
- **Port-53 conflicts during migration:** local resolver contention caused intermittent failures. Stopping the conflicting listener before container start fixed deterministic bind behavior.
- **Blocklist overreach during initial tuning:** aggressive lists caused occasional false positives; maintaining an allowlist + periodic query-log review kept usability acceptable.

## Troubleshooting

**Port 53 conflict on startup.** systemd-resolved still has port 53. Verify `DNSStubListener=no` is set and resolved was restarted. Check `ss -tlnp | grep ':53 '`. If resolved is still listening, try `systemctl restart systemd-resolved` again. If another process is using port 53, identify and stop it. AdGuard must bind to port 53 to function as the DNS server.

**`podman run` fails with `cannot expose privileged port 53`.** First confirm `NET_BIND_SERVICE` is present in the run/quadlet config. If it still fails and you accept host-wide low-port relaxation, set `net.ipv4.ip_unprivileged_port_start=53` and reload sysctl.

**`podman run` fails with `cannot assign requested address` for `172.30.0.10:53`.** Do not publish host ports to `172.30.0.10`; publish to `127.0.0.1` instead. The `--network agentnet` and `--ip 172.30.0.10` options are internal container addressing only. Published ports must bind to a host interface (`127.0.0.1` here), while the container can still keep its internal IP for peer communication.

**`dig` queries fail.** Check `cat /etc/resolv.conf` (systemd-managed) and verify `resolvectl status` shows DNS `127.0.0.1`. Test connectivity to AdGuard directly: `dig @127.0.0.1 google.com`. If this fails, check AdGuard logs for errors. Ensure AdGuard is running and listening on port 53. If using `systemd-resolved`, ensure `DNSStubListener=no` is set and resolved was restarted.

**AdGuard logs show bootstrap DNS timeouts to `1.1.1.1` / `8.8.8.8` / `9.9.9.9`.** Under strict outbound policy, set AdGuard Bootstrap DNS to `192.168.10.1`. This allows AdGuard to resolve upstream DoH servers while still blocking direct DNS queries to public resolvers. The container can still access the internet for DoH on port 443, but all DNS queries must go through the specified bootstrap DNS, which is allowed by nftables. This is a common issue when using strict outbound rules that block direct DNS queries to public resolvers. By setting the bootstrap DNS to your local router, you allow AdGuard to resolve the DoH endpoints without allowing it to bypass the blocklists.

**Blocklists won't download.** AdGuard container needs outbound HTTPS. Verify Phase 6 nftables allows TCP 443. Test from container: `podman exec adguard wget https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt -O /tmp/test.txt`.

**Web UI hangs after blocklists update.** Large lists take 60+ seconds to compile. Be patient. If it fails, check AdGuard logs for errors during list processing. Ensure the container has enough resources (CPU/memory) to handle large blocklists.

## Next

→ Optional next: [Phase 09: VPN container — encrypted egress gateway](09-vpn-egress.md)

→ Visibility-first next (without VPN): [Phase 10: Suricata — network IDS](10-suricata-ids.md)
