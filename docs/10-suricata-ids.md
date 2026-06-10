# Phase 10 — Suricata: Network IDS for the Visibility-First Profile

> **Time required:** ~30 minutes

## Why this phase

Suricata watches network traffic and pattern-matches against rulesets to spot known-bad behavior — exploit attempts, malware C2 fingerprints, reconnaissance scans, data exfiltration patterns. It runs in **alert mode** (not inline IPS), meaning it logs what it sees but does not drop traffic itself. Good for visibility, low risk for breakage, and useful when you want proof of what your box is doing.

Paired with CrowdSec (Phase 11), they complement each other: Suricata watches *packet patterns*, CrowdSec watches *log lines* and shares IPs with the community.

This phase is part of the **visibility-first** profile, not the core LAN-containment boundary. Router 3 isolation plus nftables already prevent lateral movement. Suricata adds observability, but it is also the first steady-state service to revisit if you want a performance-first autonomous-agent box.

## What we're building

- Suricata 7.x installed and configured for the active Ethernet interface
- Emerging Threats Open ruleset loaded (free, ~40k rules)
- Alert mode (logs to eve.json + fast.log; doesn't drop)
- Daily rule auto-updates via `suricata-update`
- A test attack signature to verify it fires
- A documented cleanup path if you later switch to the performance-first profile

## Prerequisites

- Phase 8 complete
- Phase 09 is optional and independent; you can do this phase whether or not you enable the VPN path

If you are intentionally building the performance-first profile, you can skip this phase and go straight to Phase 11.

## Dependency and optionality

- This entire phase is optional (visibility-first branch).
- Required before this phase: Phase 08.
- Not required before this phase: Phase 09.
- Downstream dependency: no later baseline phase requires Suricata; Phase 11 remains baseline.
- Optional step in this phase: Step 10.9 EveBox dashboarding is convenience only.

## Step 10.1 — Install Suricata

```bash
apt install -y software-properties-common
add-apt-repository ppa:oisf/suricata-stable -y
apt update
apt install -y suricata jq

# Verify version
suricata --build-info | head -5
```

## Step 10.2 — Identify your interface

```bash
ip -br link
ETH=$(ip -br link | awk '$2=="UP" && $1!="lo" {print $1; exit}')
echo "Using: $ETH"
```

## Step 10.3 — Configure Suricata

```bash
cp /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak
nano /etc/suricata/suricata.yaml
```

Key changes (use Ctrl+W in nano to search):

**Set your interface** (search for `af-packet:`):

```yaml
af-packet:
  - interface: enX                   # ← your interface
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    threads: auto
```

After editing, replace `enX` with the interface detected in Step 10.2:

```bash
sed -i "s/interface: enX/interface: ${ETH}/" /etc/suricata/suricata.yaml
```

**Set HOME_NET to the local subnet** (search for `HOME_NET`):

```yaml
vars:
  address-groups:
    HOME_NET: "[192.168.10.0/24,172.30.0.0/24]"
    EXTERNAL_NET: "!$HOME_NET"
```

**Enable EVE JSON output** (search for `eve-log:`):

Make sure it's enabled (`enabled: yes`), and check the file path is `/var/log/suricata/eve.json`.

**Make sure fast.log is also enabled** for human-readable alerts:

```yaml
outputs:
  - fast:
      enabled: yes
      filename: fast.log
```

Save.

## Step 10.4 — Set up rule updates

```bash
suricata-update update-sources
suricata-update list-sources

# Enable free ETOpen source
suricata-update enable-source et/open

# Update rules (downloads ~40k rules)
suricata-update

# Reload (just to verify the config compiles)
suricata -T -c /etc/suricata/suricata.yaml
```

> Expect: `Configuration provided was successfully loaded. Exiting.`

## Step 10.5 — Start Suricata

```bash
systemctl enable --now suricata
systemctl status suricata --no-pager
```

Check it's actually capturing:

```bash
suricatasc -c "iface-stat enX"
# Should show pkts increasing
```

## Step 10.6 — Set up daily rule updates

```bash
nano /etc/cron.daily/suricata-update
```

Contents:

```bash
#!/bin/bash
/usr/bin/suricata-update -q && /usr/bin/suricatasc -c "reload-rules"
```

Make executable:

```bash
chmod +x /etc/cron.daily/suricata-update
```

## Step 10.7 — Test it fires

The classic test trigger — ET ruleset includes a rule for `testmyids.com`:

```bash
# This will be detected (the User-Agent and domain trigger ET rule SID 2013028)
curl http://testmyids.com
```

Wait a few seconds, then:

```bash
tail -20 /var/log/suricata/fast.log

# Look for an alert like:
# 09/14/2025-14:23:12.000  [**] [1:2013028:7] ET POLICY ... [**] ...
```

## Step 10.8 — Useful queries

Real-time alerts:

```bash
tail -f /var/log/suricata/fast.log
# Ctrl+C to exit
```

Top 10 alerted signatures (last hour):

```bash
jq -r 'select(.event_type=="alert") | .alert.signature' /var/log/suricata/eve.json 2>/dev/null | sort | uniq -c | sort -rn | head -10
```

Alerts per source IP:

```bash
jq -r 'select(.event_type=="alert") | .src_ip' /var/log/suricata/eve.json 2>/dev/null | sort | uniq -c | sort -rn | head -10
```

## Step 10.9 — (Optional) Easier dashboarding

Use this only if you want a UI. It is not required for Suricata detection or for any later phase.

For a dashboard, the open-source EveBox is great. If you do not have the `agentnet` network yet, or encounter permission/TLS issues, use this command:

```bash
podman run -d \
  --name evebox \
  --user root \
  -p 127.0.0.1:5636:5636 \
  -v /var/log/suricata:/var/log/suricata:ro,Z \
  --entrypoint evebox \
  docker.io/jasonish/evebox:latest \
  server --datastore sqlite --input /var/log/suricata/eve.json
```

If you see permission errors, run:

```bash
chmod o+rx /var/log/suricata
chmod o+r /var/log/suricata/eve.json /var/log/suricata/fast.log
```

EveBox will start with HTTPS enabled. Access via a Tailscale SSH tunnel from your client:

```bash
tailscale ssh -L 5636:127.0.0.1:5636 root@homelab
# Browser: https://localhost:5636
```

If your local Tailscale SSH build does not support `-L`, temporarily use the break-glass OpenSSH path from Phase 03, then close it again after setup.

If you use OpenSSH for this fallback tunnel, temporarily set `AllowTcpForwarding yes` in `sshd_config`, validate with `sshd -t`, restart `sshd`, complete setup, then restore `AllowTcpForwarding no` and disable `sshd` again.

On first run, EveBox will print a random admin password in the logs. To reset it later:

```bash
podman exec -it evebox evebox config users passwd admin
```

Skip if you find this overkill.

## Performance-first cleanup or downgrade

If you already completed this phase and later decide to run the performance-first profile, Suricata is the first monitoring layer to revisit. Removing it reduces visibility, but it does **not** remove the core Router 3 + nftables no-lateral-movement boundary.

Disable the service and its rule-update hook:

```bash
systemctl disable --now suricata
rm -f /etc/cron.daily/suricata-update
```

If you used EveBox for Suricata dashboards, remove that too:

```bash
podman rm -f evebox 2>/dev/null || true
```

If you do not plan to re-enable Suricata soon, remove the package and stale logs after exporting anything you want to keep:

```bash
apt purge -y suricata
apt autoremove -y
add-apt-repository --remove ppa:oisf/suricata-stable -y 2>/dev/null || true
apt update
rm -rf /var/log/suricata
```

Cleanup checks:

```bash
systemctl is-active suricata || true
systemctl is-enabled suricata || true
test ! -e /etc/cron.daily/suricata-update && echo "No Suricata daily updater"
podman ps -a --format '{{.Names}}' | grep '^evebox$' || echo "No EveBox container"
```

Expected steady state for the performance-first profile: Suricata is inactive or absent, there is no Suricata daily updater, there is no EveBox container, and CrowdSec plus the firewall remain in place.

## Verification checklist

- [ ] `systemctl is-active suricata` returns `active`
- [ ] Rules loaded (`suricata-update list-sources` shows et/open enabled)
- [ ] Test trigger fires (`curl http://testmyids.com` → fast.log alert)
- [ ] Daily rule update cron in place
- [ ] eve.json being written

## Issues encountered and solutions

- **Resource overhead on older CPU workloads:** Suricata increased baseline utilization more than expected during noisy outbound tests. I documented it as an optional visibility layer, not mandatory baseline.
- **Rule update drift risk:** missed update windows weakened detection quality. Adding explicit update verification to maintenance reduced silent degradation.
- **Signal-to-noise management:** default alert volume was high during initial burn-in; narrowing focus to recurring/high-confidence signatures made alerts operationally useful.

## Troubleshooting

**Suricata won't start.** `journalctl -u suricata -n 50`. Usually misconfig in suricata.yaml. Validate: `suricata -T -c /etc/suricata/suricata.yaml`.

**No alerts despite traffic.** Verify the interface is captured: `suricatasc -c "iface-stat enX"`. If `pkts=0`, your interface name is wrong. Also check `HOME_NET` includes your subnet.

**eve.json grows huge.** Configure logrotate. Suricata also has built-in rotation — see `outputs` section in suricata.yaml.

**`curl testmyids.com` doesn't trigger alert.** May have been removed from ETOpen. Test instead with `curl -A "BlackSun" http://google.com` (a custom user-agent that ETOpen detects).

## Next

→ [Phase 11: CrowdSec — HIDS + community blocklist](11-crowdsec.md)
