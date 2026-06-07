# Phase 06 — nftables Firewall: Deny Private IP Destinations

> **Time required:** ~30 minutes

## Why this phase

Router 3 only stops *inbound* from the rest of the house. It does not stop the Server from initiating outbound to other RFC1918 ranges on its own. If Hermes, a delegated tool, or a compromised workload misbehaves, it could still scan and attack those networks by default.

nftables on the host enforces the rule we actually want in steady state: **outbound to RFC1918 ranges (except Router 3's gateway) is DROPPED.** With the current stock Huawei hardware, this is still the only practical place to block those attempts.

We also log dropped packets with a stable prefix, `[nft-deny-rfc1918]`, so you can query and alert on them directly. That matters because once you intentionally trust the host account with root-equivalent power, this firewall is no longer an independent boundary. Keep it anyway: it still blocks ordinary mistakes and gives you high-signal evidence when something tries to reach upstream LAN devices on Routers 1 or 2.

## What we're building

```text
DEFAULT POLICIES:
  input:    drop     (allow-list only)
  forward:  drop     (server is not a router)
  output:   drop     (default-deny everything outbound)

INPUT chain — allow:
  ✓ established/related connections
  ✓ loopback
  ✓ Tailscale WireGuard (UDP 41641) + services reached via tailscale0
  ✓ SSH only via tailscale0 (defense-in-depth; sshd disabled but rule kept)
  Drop anything else

OUTPUT chain — allow:
  ✓ established/related
  ✓ loopback
  ✓ DNS to gateway (53)
  ✓ NTP to gateway (123)
  ✓ DHCP (67/68)
  ✓ Tailscale public path support (UDP 3478 + 41641)
  ✓ ICMP to PUBLIC destinations (after RFC1918 deny)
  ✓ HTTPS to anywhere PUBLIC (not RFC1918)
  ✓ HTTP to anywhere PUBLIC (limited; agents need it for some sites)
  ✓ SSH outbound to anywhere PUBLIC (cloning git over ssh)
  ✓ git protocol (9418) — optional
  ✓ VPN tunnel WireGuard handshake/data (UDP 51820 + common ports)
  Drop and LOG outbound to RFC1918 ranges
  Drop anything else
```

Note: this is RESTRICTIVE for the host but PERMISSIVE for what reaches Public IPs. Additional filters later may still help, but this host firewall is the actual steady-state no-lateral-movement policy for the main Hermes session and everything it launches.

Important for the host-native autonomous runtime model:

- `iifname "tailscale0" accept` means a service can be reachable from your tailnet without being reachable from the physical LAN. That is the intended baseline for autonomous host services.
- Public publishing is a separate workflow. Do not confuse "reachable over Tailscale" with "safe to expose publicly."
- If you later give Hermes full root-equivalent control, treat this firewall as steady-state enforcement plus detection, not as an independent control plane that survives host compromise.

## Prerequisites

- Phase 5 complete
- Tailscale SSH session active to the server (`tailscale ssh root@homelab`)

## Dependency and optionality

- Required before this phase: Phase 05 hardening baseline.
- Required after this phase: this containment boundary is assumed by Phases 07-13.
- Required in this phase: Steps 6.8c–6.8e (RFC1918 alert helper, Telegram delivery, auditd firewall integrity watches).
- Optional steps: Step 6.9b temporary high-speed LAN transfer path, Step 6.10 tighter outbound policy, and the optional git `9418` egress allow in the sample ruleset.

> ⚠️ **UFW conflict:** If UFW is enabled from another guide or prior host setup, disable and reset it before applying nftables — they cannot coexist cleanly:
>
> ```bash
> ufw disable  # turn off UFW so it stops interfering with nftables
> ufw reset    # wipes any rules you added during the bootstrap phase, which is fine because nftables will be the new firewall going forward
> systemctl disable --now ufw 2>/dev/null || true
> ufw status   # should show: Status: inactive
> ```

## Step 6.1 — Verify nftables is installed and active

```bash
# Should already be there in 26.04
nft list ruleset

# If you see existing rules from Tailscale or installer, save them first as a baseline for later diff:
nft list ruleset > ~/baseline-snapshot/nft-ruleset-before.txt
```

## Step 6.2 — Identify your network interface name

```bash
ip -br link
# Output looks like:
#   lo               UNKNOWN        00:00:00:00:00:00
#   eno1             UP             aa:bb:cc:dd:ee:ff
# OR
#   enp4s0           UP             aa:bb:cc:dd:ee:ff
# OR similar
```

Note the Ethernet interface name (not `lo`). You will use it in temporary recovery rules and break-glass steps. The main ruleset below does not hardcode the physical interface name.

```bash
# Save interface name to a shell variable to use below
ETH=$(ip -br link | awk '$2=="UP" && $1!="lo" {print $1; exit}')
echo "Interface: $ETH"
```

## Step 6.3 — Find the gateway IP

```bash
GW=$(ip route | awk '/default/ {print $3; exit}')
echo "Gateway: $GW"
# Expect: 192.168.10.1 (Router 3)
```

## Step 6.4 — Write the nftables config

Manual path (edit in place):

```bash
nano /etc/nftables.conf
```

Replace its contents with (substitute `192.168.10.1` with your actual gateway):

```nft
#!/usr/sbin/nft -f

# ============================================================
# nftables config — autonomous runtime host
# Default-deny outbound, drop and log RFC1918 except gateway
# ============================================================

flush ruleset

table inet filter {

    # === Named sets ===
    # RFC1918 private ranges (we deny outbound to these)
    set rfc1918_v4 {
        type ipv4_addr
        flags interval
        elements = {
            10.0.0.0/8,
            172.16.0.0/12,
            192.168.0.0/16,
            169.254.0.0/16,
            100.64.0.0/10
        }
    }

    # The gateway is the one exception — needed for routing
    set gateway_v4 {
        type ipv4_addr
        elements = { 192.168.10.1 }
    }

    # === Chains ===

    chain input {
        type filter hook input priority 0; policy drop;

        # Allow established/related
        ct state established,related accept
        ct state invalid drop

        # Loopback
        iif "lo" accept

        # ICMPv4 (essential — restrict to common types)
        ip protocol icmp icmp type {
            echo-request,
            echo-reply,
            destination-unreachable,
            time-exceeded,
            parameter-problem
        } accept

        # Tailscale: accept all decapsulated traffic (SSH, management)
        # Use iifname here so nftables can load before tailscale0 exists at boot.
        iifname "tailscale0" accept

        # Tailscale: incoming WireGuard on the physical NIC
        udp dport 41641 accept

        # SSH defense-in-depth: only via Tailscale if sshd is ever re-enabled
        tcp dport 22 iifname "tailscale0" accept

        # Log + drop everything else (rate-limited to avoid log flooding)
        limit rate 10/minute log prefix "[nft-input-drop] " level warn
        counter drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        # Server is not a router. No forwarding.
    }

    chain output {
        type filter hook output priority 0; policy drop;

        # Allow established/related
        ct state established,related accept
        ct state invalid drop

        # Loopback
        oif "lo" accept

        # === Allowed to gateway ===
        ip daddr @gateway_v4 udp dport { 53, 67, 123 } accept   # DNS, DHCP, NTP
        ip daddr @gateway_v4 tcp dport 53 accept                # DNS over TCP
        ip daddr @gateway_v4 tcp dport 853 accept               # DNS over TLS

        # === Known-benign RFC1918 noise: drop silently (counter only, no log/alert) ===
        # Keeps [nft-deny-rfc1918] high-signal. Counters stay visible for the digest.
        # - Tailscale NAT traversal to peer LAN addresses (sport 41641) → DERP relay handles fallback
        # - MagicDNS queries to 100.100.100.100:53 → baseline DNS stays on the gateway or localhost AdGuard
        # - NAT-PMP/PCP (UDP 5351) port-mapping requests to the gateway (unwanted hole-punching)
        # - SSDP/UPnP discovery (UDP 1900) to the gateway (IGD probes; UPnP stays off on Router 3)
        ip daddr @rfc1918_v4 udp sport 41641 counter drop comment "ts-direct-noise"
        ip daddr 100.100.100.100 udp dport 53 counter drop comment "magicdns-noise"
        ip daddr @gateway_v4 udp dport 5351 counter drop comment "natpmp-noise"
        ip daddr @gateway_v4 udp dport 1900 counter drop comment "ssdp-noise"

        # === DENY RFC1918 (except gateway, which was matched above) ===
        ip daddr @rfc1918_v4 limit rate 10/minute log prefix "[nft-deny-rfc1918] " level warn
        ip daddr @rfc1918_v4 counter drop

        # ICMP to PUBLIC destinations (deny happens first above)
        ip protocol icmp icmp type {
            echo-request,
            destination-unreachable,
            time-exceeded
        } accept

        # === Allow specific PUBLIC outbound ===
        # HTTP / HTTPS (agents need to browse)
        tcp dport { 80, 443 } accept

        # Tailscale STUN (UDP 3478) — NAT traversal handshake to public STUN servers
        # Note: when Mac is on the same LAN, the direct WireGuard path hits the RFC1918
        # deny rule above (intentional). Tailscale auto-falls back to DERP relay via
        # TCP 443 (already allowed above), so Tailscale SSH remains functional.
        udp dport { 3478, 41641 } accept

        # Public NTP (for pool.ntp.org or similar sources)
        udp dport 123 accept

        # SSH (for git clone over ssh, etc.)
        tcp dport 22 accept

        # Git protocol (rarely used now but free)
        tcp dport 9418 accept

        # DNS over TLS (DoT) — upstream resolvers
        tcp dport 853 accept

        # VPN tunnel (OpenVPN/WireGuard) — adjust ports for your provider
        udp dport { 51820, 1194, 443 } accept

        # === Default deny ===
        limit rate 10/minute log prefix "[nft-output-drop] " level warn
        counter drop
    }
}
```

Save.

> Why these specific exceptions and not others:
>
> - We only allow to-gateway on 53/123 (DNS, NTP) — Router 3 forwards these upstream, so the agent can still resolve and sync time, but can't reach other services on the gateway if it gets compromised.
> - HTTP/HTTPS are allowed because agents legitimately need them; content filtering is layered via AdGuard (Phase 8) + Suricata (Phase 10). If you want stricter policy, allow only 443 and block 80. Some services still rely on HTTP, so this repo keeps 80/443 initially and tightens destinations later as telemetry improves.
> - Inbound SSH only on `tailscale0` (defense-in-depth if sshd is ever re-enabled) — we don't want sshd listening on the physical LAN interface, but if it is ever re-enabled by mistake, this rule prevents it from being reachable except via Tailscale.
> - All RFC1918 outbound (except gateway) is dropped and logged — this is the core steady-state control for keeping the host off upstream LAN space. The logs also give you a precise signal when something on the box tries to break NAT subnet isolation.

### Why four flows are dropped *without* logging

Four categories of outbound RFC1918 traffic are constant, benign, and would otherwise drown the alert signal, so they are dropped with a counter but **no log**:

- **Tailscale direct paths (`udp sport 41641` → RFC1918):** `tailscaled` continuously probes peers' physical LAN addresses to negotiate a direct WireGuard tunnel. Denying the LAN shortcut is intentional containment — Tailscale automatically falls back to the DERP relay over TCP 443 (you can confirm with `tailscale ping <peer>`, which reports `via DERP`). Tailscale ACLs are unrelated here: they govern tailnet reachability, not the transport's path discovery.
- **MagicDNS (`100.100.100.100:53`):** the baseline resolver path here is the gateway DNS or localhost AdGuard, not the Tailscale stub resolver. Dropping these queries silently keeps the immediate channel quiet when `tailscaled` probes MagicDNS. If you intentionally want MagicDNS as your active resolver, replace this silent drop with an explicit allow rule above the RFC1918 deny.
- **NAT-PMP/PCP (`udp dport 5351` → gateway):** the host asking the router to open port mappings. We never want the host punching holes in the router.
- **SSDP/UPnP discovery (`udp dport 1900` → gateway):** periodic Internet Gateway Device probes. Router 3 keeps UPnP off; blocking these stops discovery chatter without affecting normal operation.

Everything else to RFC1918 still hits the logged `[nft-deny-rfc1918]` rule, so any entry that appears is genuinely unexpected (a real scan, an agent reaching for an upstream device, etc.). The suppressed counters remain visible via `nft list chain inet filter output` and are reported in the twice-daily digest (Step 6.8d).

## Step 6.5 — Test the config syntax

```bash
# Dry-run check
nft -c -f /etc/nftables.conf
# No output = valid syntax. Error means typo.
```

## Step 6.6 — Apply the ruleset

```bash
systemctl enable nftables
nft -f /etc/nftables.conf
systemctl restart nftables
systemctl status nftables --no-pager
nft list ruleset
```

⚠️ **Test Tailscale SSH still works.** Open a **new** terminal window on your Client:

```bash
tailscale ssh root@homelab
```

If it works, continue. If not, fix from the still-open Tailscale SSH session or physical console. Common issues: syntax error in nftables.conf, or new rules accidentally blocking Tailscale traffic. If you get locked out, use the break-glass flow from Phase 3 to add a temporary allow rule for your source IP, then fix the config and remove the allow rule immediately after.

If peers do not reappear in `tailscale status` right after apply, wait ~30 seconds and retest. If still degraded, restart Tailscale and retest:

```bash
systemctl restart tailscaled
tailscale status
```

## Step 6.6b — Cleanup temporary firewall recovery/debug rules

After any emergency `nft` edits, return immediately to the canonical ruleset on disk.

```bash
nft -f /etc/nftables.conf
nft -a list chain inet filter input | grep -E 'TEMP_|RECOVERY' || echo "No temporary input rules"
nft -a list chain inet filter output | grep -E 'TEMP_|RECOVERY' || echo "No temporary output rules"
```

## Step 6.7 — Make it persistent

```bash
systemctl status nftables --no-pager
# Should be active (enabled) and show no errors

# Confirm the systemd unit will load /etc/nftables.conf on boot
cat /lib/systemd/system/nftables.service | grep ExecStart
# Expect: /usr/sbin/nft -f /etc/nftables.conf

# Reboot validation
reboot

# After reconnect
systemctl --failed
systemctl is-active nftables
```

Expected: `nftables` is active after reboot, no failed units.

## Step 6.7b — Fix NTP after applying the firewall

After Phase 06 applies the nftables ruleset, chrony may stop syncing if it still points at Canonical NTS endpoints (TCP 4460), which this policy blocks. Public UDP/123 NTP is allowed, so the fix is to point chrony to public pool servers.

The nftables template already includes an NTP rule in the correct position (after the RFC1918 drop block). Enable it and reconfigure chrony:

```bash
# The rule is already in /etc/nftables.conf — just reload
nft -f /etc/nftables.conf

# Reconfigure chrony to use public pools
tee /etc/chrony/chrony.conf > /dev/null <<'EOF'
pool pool.ntp.org iburst
pool time.cloudflare.com iburst

makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF

systemctl restart chrony
sleep 10 && chronyc sources -v
timedatectl
```

Expected: at least one source shows `*` in `chronyc sources` and `timedatectl` shows `System clock synchronized: yes`.

If the clock was already far off (e.g. after a long suspend or VM resume), set it manually first:

```bash
date -s "$(curl -sI google.com | grep -i '^date:' | cut -d' ' -f2-)"
systemctl restart chrony && sleep 5 && chronyc makestep
```

> **Gateway-only alternative:** If your router serves NTP, you can avoid opening public UDP 123 by pointing chrony at the gateway instead: `server 192.168.10.1 iburst`. Test whether the router responds first: `python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(3); s.sendto(b'\x1b'+47*b'\x00',('192.168.10.1',123)); print(s.recvfrom(48))"`. Most consumer routers do not.

## Step 6.8 — Test outbound filtering

Try to reach `192.168.3.1` (Router 2 — should be DENIED):

```bash
# This should fail with timeout / no route error
ping -c 2 -W 2 192.168.3.1
echo "Exit code: $?"
```

Expected: timeout, non-zero exit code

Try to reach the public internet (should WORK):

```bash
ping -c 2 1.1.1.1
curl -sI https://github.com | head -1
```

Expected: pings succeed, curl returns `HTTP/2 200`.

Look at the drop log:

```bash
journalctl -k -n 50 | grep "nft-deny"
```

Should show the ping to 192.168.3.1 logged.

## Step 6.8b — Monitor outbound RFC1918 attempts explicitly

These log hits are the exact signal to watch if you care about the host trying to break NAT subnet isolation and contact devices on Routers 1 or 2. Normal Web browsing, package downloads, and API calls should **not** hit this rule. A hit usually means one of three things:

- you deliberately tested the boundary (good, expected)
- some tool on the host guessed a private IP and tried to connect to it
- something is probing or scanning upstream LAN space, which is worth investigating

Manual checks:

```bash
# Show all RFC1918 deny events since boot
journalctl -k --since boot --grep '\[nft-deny-rfc1918\]' -o short-iso

# Focus on the last 24 hours
journalctl -k --since "24 hours ago" --grep '\[nft-deny-rfc1918\]' -o short-iso

# Summarize the top blocked source/destination pairs
journalctl -k --since "24 hours ago" --grep '\[nft-deny-rfc1918\]' -o cat \
    | sed -nE 's/.*SRC=([^ ]+).*DST=([^ ]+).*PROTO=([^ ]+).*SPT=([^ ]+).*DPT=([^ ]+).*/\1 -> \2 \3 \4->\5/p' \
    | sort | uniq -c | sort -rn
```

The interesting destinations here are usually:

- `192.168.3.1` or whatever Router 2 uses
- the RFC1918 address of Router 3's WAN side
- other upstream devices on Router 2's LAN
- anything in `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, or `100.64.0.0/10` that you did not intentionally test

## Step 6.8c — Install the alert helper from this repo

The repo includes a small helper script that summarizes `[nft-deny-rfc1918]` events, avoids duplicate notifications with a state file, and can deliver alerts to Telegram.

OpenSSH is disabled after Phase 03, so plain `rsync root@homelab:...` only works during a temporary break-glass sshd window. Choose one deployment path:

- Server checkout (recommended): use the alternative block below and install directly from a local repo checkout on the host.
- Temporary OpenSSH window: follow Phase 03 break-glass flow to enable sshd briefly, run `rsync`, then disable sshd again.
- No OpenSSH transfer: package files locally and extract over Tailscale SSH.

### Deploy from your Mac (only during a temporary OpenSSH window)

From the repo root on your Mac:

```bash
rsync -av \
  configs/host-rfc1918-alert.env.template \
  configs/host-rfc1918-alert.service.template \
  configs/host-rfc1918-alert.timer.template \
  configs/host-rfc1918-digest.service.template \
  configs/host-rfc1918-digest.timer.template \
  configs/60-firewall-integrity.rules \
  scripts/rfc1918-alert-check.sh \
  root@homelab:/root/hardening-assets/
```

### Deploy from your Mac without enabling OpenSSH

```bash
tar czf - \
  configs/host-rfc1918-alert.env.template \
  configs/host-rfc1918-alert.service.template \
  configs/host-rfc1918-alert.timer.template \
  configs/host-rfc1918-digest.service.template \
  configs/host-rfc1918-digest.timer.template \
  configs/60-firewall-integrity.rules \
  scripts/rfc1918-alert-check.sh \
| tailscale ssh root@homelab 'mkdir -p /root/hardening-assets && tar xzf - -C /root/hardening-assets'
```

On the server as root:

```bash
mkdir -p /root/.config/host-alerts /root/.local/state/host-alerts
install -m 0755 /root/hardening-assets/rfc1918-alert-check.sh /usr/local/bin/rfc1918-alert-check
install -m 600 /root/hardening-assets/host-rfc1918-alert.env.template /root/.config/host-alerts/rfc1918-alert.env
install -m 644 /root/hardening-assets/host-rfc1918-alert.service.template /etc/systemd/system/host-rfc1918-alert.service
install -m 644 /root/hardening-assets/host-rfc1918-alert.timer.template /etc/systemd/system/host-rfc1918-alert.timer
install -m 644 /root/hardening-assets/host-rfc1918-digest.service.template /etc/systemd/system/host-rfc1918-digest.service
install -m 644 /root/hardening-assets/host-rfc1918-digest.timer.template /etc/systemd/system/host-rfc1918-digest.timer

# Manual test (no Telegram required for this step)
/usr/local/bin/rfc1918-alert-check --since "24 hours ago"
```

### Alternative — repo cloned on the server

If you keep a checkout on the host, run from the repo root as root:

```bash
mkdir -p /root/.config/host-alerts /root/.local/state/host-alerts
install -m 0755 ./scripts/rfc1918-alert-check.sh /usr/local/bin/rfc1918-alert-check
install -m 600 configs/host-rfc1918-alert.env.template /root/.config/host-alerts/rfc1918-alert.env
install -m 644 configs/host-rfc1918-alert.service.template /etc/systemd/system/host-rfc1918-alert.service
install -m 644 configs/host-rfc1918-alert.timer.template /etc/systemd/system/host-rfc1918-alert.timer
install -m 644 configs/host-rfc1918-digest.service.template /etc/systemd/system/host-rfc1918-digest.service
install -m 644 configs/host-rfc1918-digest.timer.template /etc/systemd/system/host-rfc1918-digest.timer

/usr/local/bin/rfc1918-alert-check --since "24 hours ago"
```

If there were no hits in the test window, the script prints a clean message and exits. If there were hits, it prints a short summary plus recent raw log lines.

## Step 6.8d — Automate Telegram alerts (root system timers)

This is a root-only build, so delivery runs as **system** systemd timers. No `-n` and no `--user` instance are needed — root reads the kernel log directly.

Alerts are delivered by **Linux** (`rfc1918-alert-check` + systemd), not by the Hermes runtime. This is intentional: containment alerts should fire even when the agent stack is not running.

The design uses two complementary channels so you are only interrupted for things that matter:

| Channel | Unit | Cadence | Behavior | Notification |
| --- | --- | --- | --- | --- |
| **Suspicious (immediate)** | `host-rfc1918-alert.*` | every ~5 min | Telegram only on *new* `[nft-deny-rfc1918]` events (cursor dedup). With benign noise dropped silently at the firewall, this fires only on genuinely unexpected upstream-LAN attempts. | Loud |
| **Digest (heartbeat)** | `host-rfc1918-digest.*` | 00:00 and 12:00 local | Quiet 12-hour summary plus the suppressed-noise counters from nftables, so you can confirm the pipeline is alive and see how much benign traffic was contained. | Silent |

This split depends on the silent benign-drop rules from Step 6.3 (`ts-direct-noise`, `magicdns-noise`, `natpmp-noise`, `ssdp-noise`). Without them, the immediate channel would alert on constant Tailscale and gateway-discovery chatter.

### 1. Create a Telegram bot

In Telegram:

1. Open `@BotFather`
2. Send `/newbot`, follow the prompts, and pick a username (e.g. `@homelab-alerts-bot`)
3. When BotFather shows the bot menu, tap **API token** (not *Edit bot* or *Bot settings*)
4. Copy the token — it looks like `7123456789:AAHxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` (~46 characters). The number before `:` is the **bot's** ID, not your chat ID

Keep the token out of git. It goes only in `/root/.config/host-alerts/rfc1918-alert.env`.

### 2. Start a chat with the bot (required before chat ID lookup)

Open your new bot in Telegram and send `/start`.

The bot will **not** reply with your chat ID. That is normal — Telegram bots do not send chat IDs automatically.

### 3. Find your personal chat ID on the server

On the server, put the token in the env file first:

```bash
nano /root/.config/host-alerts/rfc1918-alert.env
```

Set `TELEGRAM_BOT_TOKEN` to the value from BotFather. Leave `TELEGRAM_CHAT_ID` blank for now.

Load the env file into your shell, then query Telegram:

```bash
source /root/.config/host-alerts/rfc1918-alert.env

# Validate token format and API reachability
curl -sS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"

python3 - <<'PY'
import json
import os
import urllib.request

token = os.environ["TELEGRAM_BOT_TOKEN"]
url = f"https://api.telegram.org/bot{token}/getUpdates"
data = json.load(urllib.request.urlopen(url))
seen = set()

for item in data.get("result", []):
    for key in ("message", "edited_message", "channel_post"):
        msg = item.get(key)
        if not msg:
            continue
        chat = msg.get("chat", {})
        chat_id = chat.get("id")
        if chat_id is None or chat_id in seen:
            continue
        seen.add(chat_id)
        label = chat.get("title") or chat.get("username") or chat.get("first_name", "")
        print(f"{chat_id}\t{chat.get('type', '?')}\t{label}")
PY
```

Use the numeric ID from the **private** chat row (your name), not the bot's ID from `getMe`.

Example output:

```text
123456789    private    [YOUR_NAME]
9876543210   private    Homelab Alerts Bot   ← bot row; do NOT use this ID
```

Put your personal ID in the env file:

```bash
nano /root/.config/host-alerts/rfc1918-alert.env
chmod 600 /root/.config/host-alerts/rfc1918-alert.env
```

Minimum required values:

- `TELEGRAM_BOT_TOKEN` — from BotFather (`<bot-id>:<secret>`, ~46 chars)
- `TELEGRAM_CHAT_ID` — your personal numeric ID from `getUpdates` (no colon)

Optional:

- `TELEGRAM_THREAD_ID` — Telegram topic/thread ID
- `TELEGRAM_DISABLE_NOTIFICATION=true` — silent messages

### 4. Test delivery before enabling the timer

```bash
source /root/.config/host-alerts/rfc1918-alert.env

curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "text=Homelab RFC1918 alert test OK"
```

Expect `"ok":true` in the JSON response and a message in Telegram.

### 5. Enable both timers and verify delivery

If you deployed via Mac copy or tar-over-Tailscale, all four unit files should already be installed from Step 6.8c. If you used the server checkout alternative, ensure the templates are installed there first.

Enable both timers:

```bash
systemctl daemon-reload
systemctl enable --now host-rfc1918-alert.timer
systemctl enable --now host-rfc1918-digest.timer
systemctl list-timers 'host-rfc1918-*' --no-pager
```

Test the loud suspicious channel:

```bash
systemctl start host-rfc1918-alert.service
journalctl -u host-rfc1918-alert.service -n 50 --no-pager
```

Expected log ending when there are new events:

```text
Alert posted to Telegram chat <your-chat-id>
```

Test the quiet digest channel on demand (it normally only runs at 00:00/12:00):

```bash
systemctl start host-rfc1918-digest.service
journalctl -u host-rfc1918-digest.service -n 30 --no-pager
```

Expected: a silent Telegram message summarizing the last 12h plus the suppressed-noise counters, ending with `Digest posted to Telegram chat <id> (silent)`.

If there are no recent suspicious events and you want to confirm the loud path end-to-end, generate one (note: `sport 41641` Tailscale noise is silently dropped, so use a plain destination that hits the logged rule):

```bash
ping -c 1 192.168.3.1 || true
systemctl start host-rfc1918-alert.service
journalctl -u host-rfc1918-alert.service -n 50 --no-pager
```

### 6. Steady-state behavior

With the silent benign-drop rules in place (Step 6.3), the immediate channel should be quiet in normal operation — Tailscale direct probes (`sport 41641`), MagicDNS (`100.100.100.100:53`), NAT-PMP (`5351`), and SSDP (`1900`) no longer reach the logged `[nft-deny-rfc1918]` rule.

After the first delivery, `/root/.local/state/host-alerts/rfc1918-alert.state` stores a journal cursor, so later runs alert only on **new** suspicious events. Verify deduplication:

```bash
systemctl status --no-pager host-rfc1918-alert.timer
cat /root/.local/state/host-alerts/rfc1918-alert.state
systemctl start host-rfc1918-alert.service
journalctl -u host-rfc1918-alert.service -n 20 --no-pager
# Expect: "No [nft-deny-rfc1918] events since state cursor" in steady state
```

Confirm how much benign traffic is being suppressed (these counters feed the digest):

```bash
nft list chain inet filter output | grep -E 'ts-direct-noise|magicdns-noise|natpmp-noise|ssdp-noise'
```

These alerts are for attempted upstream-LAN access only. They are not a feed of normal Internet traffic.

## Step 6.8e — auditd watches for firewall and alert integrity

Add dedicated audit rules so changes to the canonical ruleset, alert + digest units, and live `nft` invocations leave an audit trail:

```bash
# From the Mac-rsync flow in Step 6.8c:
install -m 644 /root/hardening-assets/60-firewall-integrity.rules /etc/audit/rules.d/60-firewall-integrity.rules

# If you keep a repo checkout on the server instead:
# install -m 644 configs/60-firewall-integrity.rules /etc/audit/rules.d/60-firewall-integrity.rules

augenrules --load
systemctl restart auditd
auditctl -l | grep -E 'firewall_(config|runtime_change|alerting)' || true
```

If `augenrules --load` prints errors about paths in `/etc/audit/rules.d/hardening.rules` that do not exist on this host, edit or trim those Neo23x0 lines first (see Phase 5 issues), then reload.

Verify:

```bash
touch /etc/nftables.conf
ausearch -k firewall_config -ts recent | tail -5
```

Expected: audit events with `key="firewall_config"` for the touch.

## Step 6.9 — Understand tailnet-only services

With the rules above loaded, a process listening on the host is still **not** reachable from the physical LAN unless you add an explicit input rule for that interface. But because `tailscale0` is accepted, that same process can be reachable from your tailnet if your Tailscale ACLs allow it.

That is the intended baseline for this repo's host-native Hermes setup:

- Host-native services may be tailnet-only.
- The physical LAN stays blocked by default.
- Public exposure remains a separate, operator-approved step.

## Step 6.9b — Optional: ad-hoc high-speed file transfer from Mac via Router 3 LAN

Use this only when a large copy is slow enough over Tailscale that you want a temporary local path. The recommended physical setup is:

```text
Mac Ethernet -> Router 3 LAN port -> Server Ethernet
```

That keeps Router 3 in the path, gives you normal LAN speed, and avoids baking a permanent LAN SSH exception into `/etc/nftables.conf`.

Preferred order:

- Best for this ad-hoc workflow: Mac on Router 3 via Ethernet
- Acceptable fallback: Mac on Router 3 WiFi
- Not covered here: direct Mac-to-server cable, which is more manual and only worth it if you do this often

Important:

- Keep the canonical `/etc/nftables.conf` unchanged
- Add a temporary live rule only for the transfer window
- Reload `/etc/nftables.conf` after the transfer to remove the temporary rule cleanly

### 1. Connect the Mac to Router 3

Plug the Mac into one of Router 3's LAN ports using Ethernet. If your Mac stays on Router 2 WiFi at the same time, that is fine; traffic to `192.168.10.0/24` will still use the direct Router 3 path.

On the Mac, confirm you got a `192.168.10.x` address:

```bash
MAC_IF=$(route -n get 192.168.10.1 2>/dev/null | awk '/interface:/{print $2}')
MAC_IP=$(ipconfig getifaddr "$MAC_IF")
echo "Mac interface: $MAC_IF"
echo "Mac IP: $MAC_IP"
```

If that prints nothing, renew DHCP on the new interface from macOS Settings and re-run the commands.

### 2. Open a temporary local SSH path on the server

Do this from your existing Tailscale SSH session to the server.

```bash
ETH=$(ip route show default | awk '/default/ {print $5; exit}')
SERVER_LAN_IP=$(ip -4 addr show "$ETH" | awk '/inet / {print $2}' | cut -d/ -f1)
echo "Server interface: $ETH"
echo "Server LAN IP: $SERVER_LAN_IP"

systemctl enable --now ssh
nft add rule inet filter input iifname "$ETH" ip saddr 192.168.10.0/24 tcp dport 22 accept comment "TEMP_MAC_TRANSFER"

ss -ltnp | grep ':22'
nft -a list chain inet filter input | grep TEMP_MAC_TRANSFER
```

If you want the narrowest possible rule, replace `192.168.10.0/24` with the exact `Mac IP` you printed above.

### 3. Transfer files from the Mac

On the Mac, set the server IP you printed above:

```bash
SERVER=192.168.10.10   # replace with the Server LAN IP from the server output above
```

Push from Mac to server:

```bash
rsync -avh --info=progress2 --partial /path/to/source/ root@"$SERVER":/root/incoming/
```

Pull from server to Mac:

```bash
rsync -avh --info=progress2 --partial root@"$SERVER":/path/to/source/ /path/to/destination/
```

Single file instead of a directory:

```bash
scp /path/to/file root@"$SERVER":/root/incoming/
scp root@"$SERVER":/path/to/file /path/to/destination/
```

`rsync` is the better default for large copies because it resumes more cleanly if the transfer is interrupted.

### 4. Close the temporary path again

On the server, return immediately to the canonical Tailscale-only posture:

```bash
systemctl disable --now ssh
systemctl disable --now ssh.socket 2>/dev/null || true
nft -f /etc/nftables.conf

ss -ltnp | grep ':22' || echo "No sshd listener - good"
nft -a list chain inet filter input | grep TEMP_MAC_TRANSFER || echo "No temporary transfer rule - good"
```

If you enabled Router 3 WiFi just for this, disable it again after the transfer.

### 5. Sanity check from the Mac

After cleanup, direct LAN SSH should be closed again:

```bash
ssh -o ConnectTimeout=5 root@"$SERVER"
```

Expected result: timeout or refusal. Normal admin access should still be through Tailscale:

```bash
tailscale ssh root@homelab
```

## Step 6.10 — Optional: tighten further

If you want even stricter outbound — only allow HTTPS, not HTTP — comment out the `80` in `tcp dport { 80, 443 }` and run `nft -f /etc/nftables.conf`. Some apt repositories and software still use HTTP for legitimate reasons, so leaving 80 open is a reasonable trade-off. If you do block 80, monitor the Suricata logs for blocked outbound HTTP and add allow rules for specific destinations as needed.

## Step 6.11 — Save baseline snapshot

After the ruleset, alerts, and audit watches are in place, refresh the host baseline under `~/baseline-snapshot/`:

```bash
mkdir -p ~/baseline-snapshot

nft list ruleset > ~/baseline-snapshot/nft-ruleset-after.txt
diff ~/baseline-snapshot/nft-ruleset-before.txt ~/baseline-snapshot/nft-ruleset-after.txt \
  > ~/baseline-snapshot/nft-ruleset-diff.txt

systemctl list-unit-files --type=service > ~/baseline-snapshot/services-post-phase6.txt
ss -tlnp > ~/baseline-snapshot/open-ports-post-phase6.txt
sysctl -a 2>/dev/null > ~/baseline-snapshot/sysctl-post-phase6.txt
date > ~/baseline-snapshot/phase6-complete-date.txt
```

Keep these snapshots on the host (not in git). Diff against them after major changes in later phases.

Refresh the snapshot whenever you change the ruleset or alert pipeline (for example after adding benign-noise suppressions):

```bash
mkdir -p ~/baseline-snapshot

nft list ruleset > ~/baseline-snapshot/nft-ruleset-after.txt
diff ~/baseline-snapshot/nft-ruleset-before.txt ~/baseline-snapshot/nft-ruleset-after.txt \
  > ~/baseline-snapshot/nft-ruleset-diff.txt || true

systemctl list-unit-files --type=service > ~/baseline-snapshot/services-post-phase6.txt
ss -tlnp > ~/baseline-snapshot/open-ports-post-phase6.txt
sysctl -a 2>/dev/null > ~/baseline-snapshot/sysctl-post-phase6.txt
date > ~/baseline-snapshot/phase6-complete-date.txt

# Confirm the four benign-noise counters are present in the live ruleset
nft list chain inet filter output | grep -E 'ts-direct-noise|magicdns-noise|natpmp-noise|ssdp-noise'
```

## Verification checklist

- [ ] `nft list ruleset` shows the full ruleset
- [ ] Outbound to `192.168.3.1` is blocked
- [ ] Outbound to `1.1.1.1` works
- [ ] `tailscale ssh root@homelab` from Mac still works after applying ruleset
- [ ] `ssh root@<server-lan-ip>` from LAN is refused — port 22 not open on the physical LAN interface
- [ ] Drop logs appear in `journalctl -k`
- [ ] `systemctl is-enabled nftables` returns `enabled`
- [ ] After `reboot`, rules are still active and Tailscale SSH works
- [ ] `nft list chain inet filter output` shows the `ts-direct-noise`, `magicdns-noise`, `natpmp-noise`, and `ssdp-noise` counters
- [ ] `systemctl is-enabled host-rfc1918-alert.timer` and `host-rfc1918-digest.timer` both return `enabled`
- [ ] `curl` test to Telegram `sendMessage` returns `"ok":true` before enabling the timers
- [ ] `/root/.local/state/host-alerts/rfc1918-alert.state` exists after the first alert run
- [ ] A manual `host-rfc1918-digest.service` run delivers a silent summary with suppressed-noise counters
- [ ] `auditctl -l` shows `firewall_config`, `firewall_alerting`, and `firewall_runtime_change`
- [ ] `~/baseline-snapshot/nft-ruleset-after.txt` and related Phase 6 snapshot files exist
- [ ] In steady state the immediate channel reports "no new events" (benign noise is silently dropped at the firewall)

## Issues encountered and solutions

- **`nftables` load-order edge case with `tailscale0`:** rules referencing interface existence too early can fail at boot. Using `iifname "tailscale0"` avoided startup fragility.
- **False confidence from router segmentation alone:** early testing proved host-initiated RFC1918 traffic could still occur. Explicit deny+log host rules became non-negotiable.
- **Alerting path drift after renaming:** moving to `host-rfc1918-alert.*` required updating unit names, env path, and state path together; partial renames broke timer runs.
- **Install commands failed with `No such file or directory`:** `install` was run on the server without the repo files present. Deploying templates and the script to `/root/hardening-assets/` via `rsync` from the Mac first fixed it.
- **Alert fatigue from benign Tailscale traffic:** the immediate channel originally fired every ~5 minutes with 50+ events, almost all `tailscaled` NAT-traversal (`sport 41641`), MagicDNS (`100.100.100.100:53`), and NAT-PMP (`5351`) drops. Tailscale ACLs do not govern these — they are the transport's own path discovery and resolver behavior, and the transport still falls back cleanly to DERP over TCP 443 when direct LAN paths are denied. The fix was to drop those flows silently at the firewall (counter, no log) so `[nft-deny-rfc1918]` only ever reflects genuinely unexpected attempts, then split delivery into a loud immediate channel and a quiet twice-daily digest.
- **Residual SSDP chatter after Tailscale noise was silenced:** UDP `1900` probes to the gateway (`192.168.10.1`) continued to hit the logged deny rule every ~20 seconds. These are UPnP IGD discovery attempts, not a breach. Adding a third silent rule (`ssdp-noise`) alongside `natpmp-noise` cleared the last steady-state alert source.
- **Spurious `Events: 1` alerts with no log lines:** `journalctl --after-cursor` emits `-- No entries --` when the cursor is current. The alert script now strips that sentinel before counting; redeploy `rfc1918-alert-check.sh` after pulling this fix.
- **Bot never replied with a chat ID:** expected behavior. Chat IDs come from the Bot API `getUpdates` endpoint after you send `/start`, not from the bot itself.
- **Used the bot's ID as `TELEGRAM_CHAT_ID`:** `getMe` returns the bot's numeric ID (the prefix of the token). Using that as `chat_id` yields `403 Forbidden: the bot can't send messages to the bot`. The personal ID from `getUpdates` is different.
- **First Telegram alert was very large:** hundreds of Tailscale peer-discovery and mDNS blocks in the first 24-hour window looked alarming but were steady-state noise. The state-file cursor stopped repeat alerts on subsequent timer runs.

## Troubleshooting

**Locked myself out of SSH.** From the physical console: `nft flush ruleset` to wipe rules immediately. Then re-edit `/etc/nftables.conf`.

**`nftables.service` fails on boot with `Interface does not exist` for `tailscale0`.** Use `iifname "tailscale0"` (not `iif "tailscale0"`) in rules so the ruleset can load before the interface appears. The `iifname` match checks the interface name without requiring it to exist at load time, while `iif` requires the interface to be present when the ruleset is loaded.

**Outbound ping to `192.168.3.1` still works.** Ensure the RFC1918 drop rule is placed *before* the ICMP allow rule in the output chain. The order of rules matters — nftables processes them top to bottom, so if the allow rule is above the deny, the packet matches the allow first and never hits the deny.

**I need temporary local LAN SSH for recovery, but nftables blocks it.** Use the break-glass flow in Phase 3 (`docs/03-first-boot-ssh.md`, Step 3.15 Path B) to add a narrowly scoped, temporary allow rule for your source IP, then remove it immediately after recovery.

**`apt update` fails after applying rules.** Either DNS is not reaching Router 3, or the DNS/NTP rules were changed. Validate with `dig @192.168.10.1 google.com` and `chronyc sources -v`.

**Clock is not synchronised / `apt update` fails with "Release file not valid yet" / frequent `nft-output-drop` logs.** Usually chrony is still targeting Canonical NTS endpoints (TCP 4460), which are blocked by policy. See Step 6.7b and re-point chrony to public NTP pools over UDP/123.

**Drops aren't being logged.** `journalctl -k` shows kernel logs. If empty, verify `rsyslog` or `systemd-journald` is running. Logs may also be in `/var/log/kern.log`.

**ICMP to 1.1.1.1 fails.** Check the `icmp type` allow lines in output chain. Try `nft trace add output protocol icmp` to see what's happening.

**Telegram `KeyError: 'TELEGRAM_BOT_TOKEN'` when running the chat-ID script.** Run `source /root/.config/host-alerts/rfc1918-alert.env` in the same shell first, or export the token explicitly. A token saved only in the file is not visible to Python until sourced.

**Telegram API returns `404 Not Found`.** The URL must include the literal word `bot` before the token: `https://api.telegram.org/bot<TOKEN>/getMe`. Missing `bot`, extra spaces, or a truncated token all produce 404.

**Telegram API returns `401 Unauthorized`.** Token typo or copy error. Re-copy from BotFather → **API token**.

**Telegram API returns `403 ... the bot can't send messages to the bot`.** `TELEGRAM_CHAT_ID` is set to the bot's own ID (from `getMe` or the numeric prefix of the token). Use your personal chat ID from `getUpdates` instead.

**`getUpdates` returns an empty `result` list.** Send `/start` (or any message) to the bot in Telegram, wait a few seconds, and retry. Confirm `getMe` returns `"ok":true` first (outbound HTTPS to Telegram is allowed).

**Second alert run sends the same large summary again.** Check that `/root/.local/state/host-alerts/rfc1918-alert.state` exists and contains a `cursor:` line. The service template sets `STATE_FILE`; if that path is wrong or unwritable, deduplication fails.

**Immediate alerts with `Events: 1` and `Recent log lines: -- No entries --`.** `journalctl --after-cursor` prints that sentinel when nothing new matched; older script versions treated it as a real event. Update `/usr/local/bin/rfc1918-alert-check` from this repo (the script now strips that line before counting).

**`augenrules --load` fails on Neo23x0 paths, then firewall rules do not appear.** Trim broken watch lines in `/etc/audit/rules.d/hardening.rules` (paths for software not installed on this host), reload, then install `60-firewall-integrity.rules` separately.

**`Object "daddr" is unknown, try "ip help"` when adding a benign-drop rule.** That line is nftables syntax, not a shell command. Edit `/etc/nftables.conf` (or use `nft insert rule ...`) — do not paste rule fragments directly into the shell.

## Next

→ Optional container branch: [Phase 07: Podman + NVIDIA Container Toolkit](07-podman-nvidia.md)

→ Baseline continuation if deferring containers: [Phase 11: CrowdSec — HIDS + community blocklist](11-crowdsec.md)
