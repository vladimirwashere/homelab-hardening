# Phase 11 — CrowdSec: HIDS + Community IP Blocklist

> **Time required:** ~20 minutes

## Why this phase

CrowdSec is the modern replacement for fail2ban. Two big advantages:

1. **Behavior-based detection** — uses YAML "scenarios" like "5 failed SSH logins in 2 minutes" instead of one-shot regex
2. **Crowd intelligence** — 12M+ malicious IPs reported daily across the user base. Your nftables drops these before they touch any service.

The nftables bouncer is the enforcement part: CrowdSec decides "ban IP X," the bouncer adds it to its own nftables set (`ip crowdsec` / `crowdsec-blacklists`) and drops packets before they reach services. No code changes to any service.

Unlike Suricata, CrowdSec is usually cheap enough to keep in both the visibility-first and performance-first profiles. Treat it as part of the default baseline unless you have a concrete reason to remove it.

## What we're building

- CrowdSec engine installed
- Community blocklist enrollment (free, anonymous)
- Linux + SSH parsers loaded
- nftables bouncer adding IPs to our set
- Test: ban an IP, verify it's dropped
- A lower-overhead detection layer that still makes sense if Phase 10 is skipped

## Prerequisites

- Phase 6 complete
- Phase 10 is optional and only applies to the visibility-first profile

## Dependency and optionality

- Required before this phase: Phase 06.
- Not required before this phase: Phase 10.
- Downstream dependency: Phase 12 assumes CrowdSec baseline is present unless you intentionally deviate.
- Optional steps in this phase:
  - Step 11.7 extra web scenarios only if you deploy web services.
  - Step 11.8 dashboard is convenience only.

## Step 11.1 — Install CrowdSec

Ubuntu 26.04 (`resolute`) path (recommended):

```bash
# Use distro package on Ubuntu 26.04 (resolute)
# packagecloud can lag new Ubuntu codenames and return 404 Release.
apt update
apt install -y crowdsec

# Verify
cscli version
systemctl status crowdsec --no-pager
```

If your distro doesn't provide CrowdSec yet, use packagecloud instead:

```bash
mkdir -p /etc/apt/keyrings
curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey | gpg --dearmor -o /etc/apt/keyrings/crowdsec.gpg
echo "deb [signed-by=/etc/apt/keyrings/crowdsec.gpg] https://packagecloud.io/crowdsec/crowdsec/ubuntu/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/crowdsec.list
apt update
apt install -y crowdsec
```

If you prefer the upstream one-liner installer, use it only after reviewing the script contents first.

## Step 11.2 — Install standard collections

```bash
# Linux + sshd is the baseline
cscli collections install crowdsecurity/linux
cscli collections install crowdsecurity/sshd

# Reload
systemctl reload crowdsec
cscli collections list
```

In this root-only build, `sshd` is disabled in steady state (Phase 03). Keep `crowdsecurity/sshd` mainly for break-glass windows when OpenSSH is intentionally re-enabled.

If install fails with `invalid download hash`, `Downloaded version doesn't match index`, or `tainted ... won't enable unless --force`, run this recovery path:

```bash
systemctl stop crowdsec
cscli hub update
cscli collections install crowdsecurity/linux --force
cscli collections install crowdsecurity/sshd --force
systemctl start crowdsec
systemctl reload crowdsec
cscli collections list
cscli parsers list | grep -E 'syslog-logs|dateparse-enrich'
cscli scenarios list | grep -E 'ssh-bf|ssh-slow-bf'
```

Expected after a forced reinstall: `... : overwrite` warnings. Those are normal when existing hub files are replaced.

## Step 11.3 — Install the nftables bouncer

```bash
# Ubuntu 26.04 package name is generic:
apt install -y crowdsec-firewall-bouncer

# Bouncer config
nano /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
```

Adjust these settings:

```yaml
mode: nftables
update_frequency: 10s
log_mode: file
log_dir: /var/log/
log_level: info

# Let bouncer manage its own nftables table/chain/set
nftables:
  ipv4:
    enabled: true
    set-only: false
    table: crowdsec
    chain: crowdsec-chain
  ipv6:
    enabled: false
```

The critical detail: `set-only: false` means the bouncer manages its own table/chain/set. This avoids naming/family mismatches on Ubuntu 26.04 packages and keeps CrowdSec enforcement self-contained.

Restart bouncer:

```bash
systemctl restart crowdsec-firewall-bouncer
systemctl status crowdsec-firewall-bouncer --no-pager
```

Verify the bouncer is registered with CrowdSec:

```bash
cscli bouncers list
# Expect a row showing the firewall bouncer
```

## Step 11.4 — Enroll in the community blocklist

This shares your anonymized detections with the CrowdSec community in exchange for access to their global blocklist (12M+ IPs/day).

```text
# Create a free account at https://app.crowdsec.net first
# Get your enroll key from the dashboard
```

Then run:

```bash
cscli console enroll <YOUR_ENROLL_KEY>
```

Then approve the machine from the web console (one click).

After approval, restart CrowdSec so enrollment state is applied:

```bash
systemctl restart crowdsec
systemctl status crowdsec --no-pager
```

Check status:

```bash
cscli console status
cscli capi status
```

After a few minutes, the blocklist should populate:

```bash
cscli decisions list -o raw | wc -l
# Expect: a large number after a few minutes
```

## Step 11.5 — Test detection and enforcement

Steady-state note: Phase 03 disables `sshd` and keeps key-only auth, so live password brute-force simulation is not the primary validation path.

Primary validation (works with sshd disabled): manual decision propagation:

```bash
cscli decisions add --ip 198.51.100.1 --reason test --duration 5m
sleep 15
cscli decisions list | grep 198.51.100.1
nft list set ip crowdsec crowdsec-blacklists
cscli decisions delete --ip 198.51.100.1
```

`198.51.100.1` is a TEST-NET address reserved for documentation (safe for validation).

Optional live `ssh-bf` test (break-glass only):

- Temporarily re-enable `sshd` and allow password auth for a short test window.
- Trigger failed logins from a separate test host.
- Confirm `cscli alerts list` shows `ssh-bf`, then restore Phase 03 `sshd` settings and disable `sshd` again.

## Step 11.6 — Look at what CrowdSec sees

```bash
# Recent alerts
cscli alerts list

# Current bans
cscli decisions list

# Top blocked countries (from your community blocklist)
cscli decisions list -o raw | awk -F',' '{print $5}' | sort | uniq -c | sort -rn | head -10

# Confirm nftables set is being populated
nft list set ip crowdsec crowdsec-blacklists | head
```

## Step 11.7 — Optional: scenarios for web traffic, etc

If you later expose any web services from the host or from support containers, install scenarios:

```bash
cscli collections install crowdsecurity/http-cve
cscli collections install crowdsecurity/base-http-scenarios
systemctl reload crowdsec
```

Skip for now unless you intentionally deploy tailnet-only or operator-approved public web apps.

## Step 11.8 — Dashboard (optional)

CrowdSec offers a free web console at <https://app.crowdsec.net> — visualizes your alerts, bans, scenarios, attack origin map. Already enabled via Step 11.4.

Log in via browser, navigate to your enrolled machine.

## Step 11.9 — Stats

After running for a few days, check these:

```bash
# Total IPs currently blocked (community + local)
cscli decisions list -o raw | wc -l

# Bans from your local detections
cscli alerts list --since 7d | wc -l

# Top scenarios firing on your machine
cscli alerts list -o raw | awk -F',' '{print $4}' | sort | uniq -c | sort -rn | head -5
```

Record those numbers in your README.md "Metrics" section.

## Verification checklist

- [ ] `systemctl is-active crowdsec` → active
- [ ] `systemctl is-active crowdsec-firewall-bouncer` → active
- [ ] `cscli bouncers list` shows the firewall bouncer
- [ ] `cscli decisions list` shows IPs (probably many — community blocklist)
- [ ] `nft list set ip crowdsec crowdsec-blacklists` shows IPs being added
- [ ] Either brute-force test or manual decision test proved ban -> nftables propagation

## Troubleshooting

**`cscli decisions list` is empty for hours.** Console enrollment didn't complete. Check `cscli console status`. Re-enroll if needed.

**Bouncer registered but nothing added to nftables.** Use bouncer-managed mode (`set-only: false`) with `table: crowdsec` and `chain: crowdsec-chain`. Verify with `nft list table ip crowdsec`. Check logs: `tail -50 /var/log/crowdsec-firewall-bouncer.log`.

**`apt update` fails on CrowdSec packagecloud with `404 ... Release`.** Your Ubuntu codename is newer than packagecloud support. Remove `/etc/apt/sources.list.d/crowdsec.list` and use distro packages (`crowdsec`, `crowdsec-firewall-bouncer`).

**Step 11.2 fails with `invalid download hash` and `tainted` items.** Hub metadata and local artifacts are out of sync. Use the Step 11.2 recovery commands (`cscli hub update` + reinstall collections with `--force`), then verify parser/scenario status. If still broken, reset hub cache (`rm -rf /etc/crowdsec/hub`, recreate directory, `cscli hub update`, reinstall collections).

**False positives on legitimate IPs.** Add to allowlist: `cscli decisions delete --ip <IP>` then `cscli simulation enable scenario-name` for that scenario.

**Brute force test doesn't trigger.** Make sure the test source can actually reach the Server's SSH surface. A host on `192.168.3.x` (main LAN) usually cannot reach the Server directly behind Router 3 NAT. Test from a device on the Router 3 LAN (`192.168.10.x`) or over Tailscale.

**I have no second test machine.** Use the manual decision validation in Step 11.5 and verify the IP appears in `ip crowdsec` / `crowdsec-blacklists`.

## Next

→ [Phase 12: Hermes deployment — trusted root session on the host](12-hermes-deployment.md)
