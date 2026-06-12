# Phase 13 — Audit, Maintenance, Recovery, Cleanup, and Alert Follow-Up

> **Time required:** ~60 minutes one-time + 30 minutes/month ongoing

## Why this phase

The build is only done if you can verify it, maintain it, recover it remotely, and clean up what no longer belongs on the host.

Hermes adds new moving parts beyond a generic hardened server: `/root/.hermes`, system services, channels, skills, browser state, and optional tailnet-only apps. This phase turns those into a repeatable runbook.

## What we're building

- A Lynis audit and findings review loop
- Hermes-aware backups for host config, agent state, and system services
- A monthly maintenance checklist for both visibility-first and performance-first profiles
- A Telegram alert setup and follow-up audit loop for RFC1918 deny events
- A cleanup checklist for obsolete files, services, and containers
- An incident-response sketch for a suspected host or agent compromise
- Two explicit recovery branches: encrypted root plus real out-of-band console, or continuity mode without root LUKS

## Prerequisites

- Previous phases complete, or at least adapted to your chosen profile
- Hermes already installed and running as root from Phase 12

## Dependency and optionality

- Required before this phase: baseline phases through 12 (plus any optional branches you chose).
- This is the final required phase for documenting and validating the chosen operating profile.
- Optional steps in this phase:
  - Step 13.3 rootkit sanity checks.
  - Step 13.6 optional VPN/container cleanup subsection (only if you are removing that branch).
  - Step 13.8 Path B encrypted-root recovery path.
  - Step 13.8 Path C Wake-on-LAN recovery path (depends on Phase 04 work).

## Step 13.1 — Run Lynis and record the result

```bash
apt install -y lynis
lynis audit system --quick 2>&1 | tee ~/baseline-snapshot/lynis-report.txt
```

At the bottom, record:

```text
  Hardening index : XX [################....] (XX%)
  Tests performed : XXX
  Plugins enabled : XX
```

Target: **80+** for this build. Lower is not automatically wrong, but review the deltas before moving on.

## Step 13.2 — Review and address findings that matter

Lynis stores detailed findings in `/var/log/lynis-report.dat`:

```bash
grep '^suggestion\[\]' /var/log/lynis-report.dat | sort -u
grep '^warning\[\]' /var/log/lynis-report.dat | sort -u
```

Common useful fixes:

- `AUTH-9286`: configure minimum password age if you still use local passwords
- `BANN-7126`: add a legal banner if you want one
- `FILE-6310`: tighten `/tmp` mount options if they fit your workflow
- `KRNL-6000`: review default umask
- `PKGS-7370`: install `debsums` if you want extra package-integrity checks

Ignore findings that do not fit this build. Re-run Lynis after meaningful changes:

```bash
lynis audit system --quick 2>&1 | tail -20
```

## Step 13.3 — Optional one-time rootkit sanity checks

These are not core controls, but they are reasonable one-time sanity passes.

```bash
apt install -y chkrootkit rkhunter

chkrootkit | tee ~/baseline-snapshot/chkrootkit.txt

rkhunter --update
rkhunter --propupd
rkhunter --check --skip-keypress | tee ~/baseline-snapshot/rkhunter.txt
```

False positives happen. Investigate anything surprising; do not treat every warning as a confirmed compromise.

## Step 13.4 — Back up host config and Hermes state

Back up the host controls and the root-owned Hermes state that would be painful to rebuild by hand.

Create a daily backup script (run as root):

```bash
nano /usr/local/bin/backup-hermes-host.sh
```

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/mnt/data/hermes/backups/host"
DATE="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/hermes-host-${DATE}.tar.gz"

paths=(
  /etc/nftables.conf
  /etc/sysctl.d/99-hardening.conf
  /etc/default/grub
  /etc/fstab
  /etc/crowdsec
  /etc/audit/rules.d
  /root/.hermes
)

for optional in \
  /etc/crypttab \
  /etc/sysctl.d/99-podman.conf \
  /etc/systemd/system/host-rfc1918-alert.service \
  /etc/systemd/system/host-rfc1918-alert.timer \
  /etc/systemd/system/host-rfc1918-digest.service \
  /etc/systemd/system/host-rfc1918-digest.timer \
  /usr/local/bin/rfc1918-alert-check \
  /root/baseline-snapshot; do
  [[ -e "$optional" ]] && paths+=("$optional")
done

mkdir -p "$BACKUP_DIR"

tar czf "$ARCHIVE" "${paths[@]}"

find "$BACKUP_DIR" -name 'hermes-host-*.tar.gz' -mtime +30 -delete

echo "Backed up to $ARCHIVE"
```

Install and test it:

```bash
chmod +x /usr/local/bin/backup-hermes-host.sh
/usr/local/bin/backup-hermes-host.sh
ls -lh /mnt/data/hermes/backups/host/
```

Then schedule it daily:

```bash
nano /etc/cron.daily/backup-hermes-host
```

```bash
#!/bin/sh
/usr/local/bin/backup-hermes-host.sh > /var/log/backup-hermes-host.log 2>&1
```

```bash
chmod +x /etc/cron.daily/backup-hermes-host
```

Important backup notes:

- These archives can contain secrets, auth tokens, and channel state. Treat them as sensitive.
- Do **not** back up large model directories into the same daily archive. Keep models and bulky artifacts under `/mnt/data/hermes/models` and `/mnt/data/hermes/archives` separately.
- If you still use support containers, create a separate archive for `/root/.config/containers/` and container data.
- The RFC1918 alert helper, systemd timer, and env file paths are part of the baseline backup set as shown above.

## Step 13.5 — Auto-alert setup and monitoring audit

Run the setup subsection once. Use the follow-up subsection whenever an alert fires. Run the monthly checklist once per month. All commands below run as root.

### Alert setup audit — one time

The steady state you want is:

- `/usr/local/bin/rfc1918-alert-check` exists and is executable
- `/root/.config/host-alerts/rfc1918-alert.env` exists with valid Telegram values
- `host-rfc1918-alert.{service,timer}` (loud immediate) and `host-rfc1918-digest.{service,timer}` (quiet twice-daily) exist under `/etc/systemd/system/`
- both timers are enabled and survive reboot
- the silent benign-drop rules (`ts-direct-noise`, `magicdns-noise`, `natpmp-noise`, `ssdp-noise`) are present so the immediate channel stays high-signal

Audit that state with:

```bash
test -x /usr/local/bin/rfc1918-alert-check
test -f /root/.config/host-alerts/rfc1918-alert.env
test -f /etc/systemd/system/host-rfc1918-alert.service
test -f /etc/systemd/system/host-rfc1918-alert.timer
test -f /etc/systemd/system/host-rfc1918-digest.service
test -f /etc/systemd/system/host-rfc1918-digest.timer
systemctl daemon-reload
systemctl enable --now host-rfc1918-alert.timer
systemctl enable --now host-rfc1918-digest.timer
systemctl list-timers 'host-rfc1918-*' --no-pager
nft list chain inet filter output | grep -E 'ts-direct-noise|magicdns-noise|natpmp-noise|ssdp-noise'
systemctl start host-rfc1918-alert.service
journalctl -u host-rfc1918-alert.service -n 50 --no-pager
systemctl start host-rfc1918-digest.service
journalctl -u host-rfc1918-digest.service -n 30 --no-pager
```

If any of those files are missing, go back to Phase 6 Steps 6.8c–6.8d and install the templates from this repo before continuing. If Telegram delivery fails, see Phase 6 troubleshooting (`403 bot can't send messages to the bot`, `getUpdates` empty, forgot to `source` the env file).

Confirm audit watches:

```bash
auditctl -l | grep -E 'firewall_(config|runtime_change|alerting)' || true
touch /etc/nftables.conf
ausearch -k firewall_config -ts recent | tail -3
```

After the first successful alert, steady-state runs should be quiet unless new RFC1918 blocks occur. Check the cursor:

```bash
cat /root/.local/state/host-alerts/rfc1918-alert.state
systemctl start host-rfc1918-alert.service
journalctl -u host-rfc1918-alert.service -n 10 --no-pager
```

To test end-to-end delivery deliberately:

```bash
ping -c 1 192.168.3.1 || true
systemctl start host-rfc1918-alert.service
journalctl -u host-rfc1918-alert.service -n 50 --no-pager
```

Expected result: exactly one Telegram message arrives for the intentional test, and the service log shows the same blocked destination.

### Follow up when an alert fires

Use this short loop every time Telegram tells you a blocked RFC1918 attempt occurred:

1. Decide whether the hit was intentional. A recent `ping 192.168.3.1`, ad-hoc validation, or a known admin test can explain it.
2. Re-summarize the recent events from the host:

```bash
/usr/local/bin/rfc1918-alert-check --since "30 minutes ago" --tail 20
journalctl -k --since "30 minutes ago" --grep '\[nft-deny-rfc1918\]' -o short-iso
```

1. Confirm the timer and service are healthy:

```bash
systemctl status --no-pager host-rfc1918-alert.timer
journalctl -u host-rfc1918-alert.service -n 50 --no-pager
```

1. If the destination is unexpected, check what changed on the host before moving on:

```bash
ss -tupn
lsof -i -P -n | head -50
systemctl list-units --type=service
```

1. If you cannot explain the hit quickly, treat it as suspicious and move to the incident-response section below.

### Monthly checks

### Core host checks

- `apt update && apt list --upgradable`
- `apt upgrade` or confirm unattended-upgrades already applied the security fixes you expected
- Reboot if a kernel, NVIDIA, or low-level runtime update requires it
- `pro status`
- `livepatch status`
- `aide --check`
- `lynis audit system --quick`
- `cscli hub update && cscli hub upgrade`
- `cscli decisions list | wc -l`

### Hermes checks (run as root)

- `hermes doctor`
- `hermes setup` (only if reconfiguration is needed)
- `npm --version` and `npx --version` run directly (no sudo)
- `python3 -m pip --version || echo "pip not installed - optional"`
- `command -v docker >/dev/null && docker version || echo "Docker not installed - optional"`
- `systemctl --failed`
- `systemctl list-units --type=service`
- `hermes logs list`
- `hermes logs errors -n 100`
- Review `journalctl -u hermes-gateway -n 100 --no-pager` or the actual unit name shown by `systemctl list-unit-files | grep -i hermes`

### RFC1918 containment checks

- `journalctl -k --since "30 days ago" --grep '\[nft-deny-rfc1918\]' -o short-iso | tail -50`
- `test ! -x /usr/local/bin/rfc1918-alert-check || /usr/local/bin/rfc1918-alert-check --since "30 days ago"`
- `systemctl status --no-pager host-rfc1918-alert.timer host-rfc1918-digest.timer`
- `journalctl -u host-rfc1918-alert.service -n 50 --no-pager`
- `journalctl -u host-rfc1918-digest.service -n 30 --no-pager` (confirm the twice-daily heartbeat is firing)
- `nft list chain inet filter output | grep -E 'ts-direct-noise|magicdns-noise|natpmp-noise|ssdp-noise'` (confirm benign noise is still being contained silently)
- Investigate any destination on Router 1, Router 2, or other upstream LAN devices that you did not intentionally test

### Profile-specific checks

Visibility-first profile:

- `suricata-update`
- `systemctl status suricata --no-pager`
- Confirm `/etc/cron.daily/suricata-update` still exists if you rely on it

Performance-first profile:

- `systemctl is-active suricata || true` should show `inactive` or no unit
- `test ! -e /etc/cron.daily/suricata-update && echo "No Suricata updater"`
- `podman ps -a --format '{{.Names}}' | grep '^evebox$' || echo "No EveBox container"`

### Resource checks

- `ps -eo pid,comm,%mem,%cpu --sort=-%mem | head -15`
- `df -h`
- `ss -tlnp`

## Step 13.6 — Cleanup obsolete artifacts and unused services

Run this once after the current design is in place so the host contains only the files, services, and containers you still intend to keep.

Inventory first:

```bash
podman ps -a
podman images
systemctl list-unit-files | grep -Ei 'adguard|gluetun|ollama|agent|hermes' || true
systemctl list-unit-files | grep -Ei 'suricata|crowdsec|tailscaled|nftables' || true
nft -a list chain inet filter input | grep TEMP_ || echo "No temporary nft recovery rules"
```

Then clean up what no longer belongs.

### Obsolete privilege artifacts

Ensure old wrapper/temporary privilege artifacts from previous repo revisions are absent:

```bash
rm -f /usr/local/sbin/*agent-safe-* /usr/local/sbin/*service-control* 2>/dev/null || true
rm -f /etc/sudoers.d/*agent* 2>/dev/null || true
rm -rf /etc/agent-runtime 2>/dev/null || true
```

### Unused generic container artifacts

If these are no longer part of your host:

```bash
podman rm -f test-agent 2>/dev/null || true
podman rmi agent-base:latest 2>/dev/null || true
```

### Optional VPN/container path

If you are **not** using the Phase 09 Gluetun path anymore for auxiliary workloads:

```bash
systemctl disable --now gluetun.service 2>/dev/null || true
podman rm -f gluetun 2>/dev/null || true
rm -f /etc/containers/systemd/gluetun.container
rm -f /root/containers/gluetun/gluetun.env /root/containers/gluetun/control-server.toml
systemctl daemon-reload
systemctl reset-failed gluetun.service 2>/dev/null || true
```

If you still use that path, keep it and document exactly which workloads still depend on it.

### Suricata visibility branch

If you are adopting the performance-first profile, follow the cleanup section in Phase 10 and make sure the updater, service, and any EveBox container are gone.

### Service cleanup

Disable and remove any old system units you no longer want:

```bash
systemctl disable --now <old-unit>.service
rm -f /etc/systemd/system/<old-unit>.service
systemctl daemon-reload
```

### Expected steady state after cleanup

After cleanup:

- Hermes runs as a root system service
- `podman ps -a` only shows support containers you intentionally kept
- no temporary nft recovery rules remain
- `ss -tlnp` only shows listeners you expect
- Suricata is either intentionally active or intentionally absent
- `/mnt/data/hermes` is present and mounted if you kept the Phase 12 data layout
- obsolete privilege wrapper binaries and temporary sudoers drop-ins are absent

## Step 13.7 — Sketch an incident-response plan

If you suspect compromise, avoid making it up in the moment.

### Immediate

1. Disconnect the Server from Router 3.
2. Do **not** immediately power it off unless safety requires it.
3. Note any visible alerts, suspicious services, or pairings.

### Triage

From the physical console or a still-working Tailscale session, collect (as root):

```bash
journalctl -u crowdsec -n 200 --no-pager
journalctl -k --since "24 hours ago" --grep '\[nft-deny-rfc1918\]' -o short-iso
cscli alerts list --since 24h
aide --check
ausearch -ts today | head -100
last -20
lsof -i -P -n | grep ESTABLISHED || true
hermes doctor
hermes --version
systemctl list-units --type=service
journalctl -u hermes-gateway -n 200 --no-pager
```

If the Hermes unit name differs, query it with `systemctl list-unit-files | grep -i hermes`.

### Containment

1. Disconnect the Server from Router 3 or pull the Router 3 WAN cable if you need to preserve the box powered on but isolated.
2. Stop any suspicious services: `systemctl stop <service>`
3. Stop any support containers you no longer trust: `podman stop <name>`
4. Assume `root` (and therefore Hermes) may already have changed firewall, routing, Tailscale, or service state. Treat host policy as evidence to inspect, not as something automatically trustworthy.

### Recovery

- Best case: restore from a known-good backup and rotate credentials
- Worst case: rebuild from Phase 2, then restore only the config and Hermes state you trust

After recovery, rerun `aide --check`, `hermes doctor`, and the firewall/Tailscale validation steps.

## Step 13.8 — Choose and document your recovery path

All validation commands below run as root.

### Path A — continuity mode with plain ext4 (no LUKS)

This is the default configuration for unattended reboot recovery.

- Plain ext4 root filesystem (no LUKS encryption)
- Immediate SSH access on boot without passphrase decryption
- Unattended reboot recovery and Tailscale rejoin workflows
- Acceptable trade-off: no at-rest protection for system disk if hardware is stolen/seized

Validation for this path:

- `lsblk -f` shows plain ext4, no crypto_LUKS
- Reboot intentionally and confirm system comes up without passphrase entry
- `tailscale ssh root@homelab` works immediately after reboot
- `hermes doctor` succeeds

### Path B — Optional: encrypted root with LUKS+LVM plus real out-of-band console

Use this only if at-rest disk protection is required and you can deploy a real remote-unlock path.

Decision gate examples:

- At-rest disk encryption is a regulatory or operational requirement
- You have deployed a real IP-KVM device (PiKVM, JetKVM, etc.) for guaranteed off-site recovery
- A smart plug alone is **not** enough; you need actual LUKS passphrase entry capability
- Unattended reboot recovery is less important than encrypted-at-rest posture

Recommended path: rebuild with root LUKS+LVM, then restore the trusted parts of your config. Keep documentation of the out-of-band console availability.

High-level rebuild sequence:

1. Export and verify backups first
2. Reinstall Ubuntu with root LUKS+LVM (see Phase 2, section C.7)
3. Re-apply this repo's phases
4. Restore the backed-up config and Hermes state you trust

Post-change validation:

- `lsblk -f`
- If plain ext4 (Path A): no crypto_LUKS layer
- If LUKS+LVM (Path B): crypto_LUKS → LVM volume group visible
- `systemctl --failed`
- `nft list ruleset`
- `tailscale ssh root@homelab` after a reboot
- `hermes doctor`

When you choose either path, document the choice, date, reason, and rollback criteria.

### Path C — Optional: Wake-on-LAN + remote power recovery

Use this after the host is stable on plain ext4 and Tailscale SSH.

See Phase 04 for the full setup and troubleshooting runbook.

- BIOS keeps standby power to the NIC (`ErP Disabled`)
- `Power On By PCI-E/PCI` is enabled
- Linux reports `Supports Wake-on: pumbg`
- Linux reports `Wake-on: g`
- WoL survives reboot via Netplan or a `.link` file
- A remote relay on `192.168.10.0/24` can send the magic packet over Tailscale

Validation for this path:

- `ethtool enp6s0 | grep -i 'Wake-on\|Supports Wake-on'`
- `systemctl poweroff`
- local LAN wake succeeds from the MAC address
- remote relay wake succeeds from a Tailscale SSH session
- `tailscale ssh root@homelab` works after wake

## Verification checklist

- [ ] Lynis score recorded and reviewed
- [ ] Backup script runs and produces archives under `/mnt/data/hermes/backups/host/`
- [ ] `hermes doctor` and `hermes logs errors -n 100` are part of the monthly routine
- [ ] Profile-specific maintenance checks match your chosen profile
- [ ] Cleanup leaves only the services and containers you intentionally kept
- [ ] Telegram delivery is installed (loud immediate + quiet twice-daily digest), tested, and reviewed during monthly checks
- [ ] Incident-response notes are documented before you need them
- [ ] Your recovery path is explicit: encrypted root plus real OOB console, or documented continuity mode without root LUKS

## Issues encountered and solutions

- **Telegram chat ID confusion during first setup:** the bot token prefix matches the bot's numeric ID from `getMe`, which is not the delivery target. Personal chat IDs come from `getUpdates` after `/start`. Documented fully in Phase 6 Step 6.8d.
- **First RFC1918 alert looked like an incident:** a large initial summary (Tailscale UDP 41641, mDNS to gateway, MagicDNS) was steady-state noise. The current baseline now silent-drops the transport and MagicDNS chatter at the firewall; the journal cursor in `rfc1918-alert.state` still keeps later runs quiet when nothing genuinely new appears.
- **`install` failed with missing repo files on the server:** deploying templates and the script to `/root/hardening-assets/` via `rsync` from the Mac before running `install` fixed it.
- **SSDP (`UDP 1900`) alerts after Tailscale noise was silenced:** gateway IGD discovery probes continued to hit the logged deny rule. A third silent rule (`ssdp-noise`) cleared the last steady-state source; refresh `~/baseline-snapshot/` after applying it.

## Next

→ Revisit [README.md](../README.md) when you have final metrics and lessons learned to record for this build.
