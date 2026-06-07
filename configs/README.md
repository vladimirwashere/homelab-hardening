# Configuration templates

Sanitized templates for the configs used across the phases. Each has `[REPLACE_ME_*]` markers where personal values go. When you copy them, replace the markers with your actual values (e.g. IP addresses, usernames) and update the table below to document where they go.

These templates assume a root-only host baseline with a host-native autonomous runtime, `nftables` containment, and optional support containers.

| File | Used in | Goes on system at |
| --- | --- | --- |
| `nftables.conf.template` | Phase 6 | `/etc/nftables.conf` |
| `99-hardening.conf` | Phase 5 | `/etc/sysctl.d/99-hardening.conf` |
| `sshd_config.snippet` | Phase 3 | merge into `/etc/ssh/sshd_config` |
| `mac-ssh-config.template` | Phase 3 | `~/.ssh/config` (on your Mac) |
| `host-rfc1918-alert.env.template` | Phases 6 and 13 | `/root/.config/host-alerts/rfc1918-alert.env` |
| `host-rfc1918-alert.service.template` | Phases 6 and 13 | `/etc/systemd/system/host-rfc1918-alert.service` |
| `host-rfc1918-alert.timer.template` | Phases 6 and 13 | `/etc/systemd/system/host-rfc1918-alert.timer` |
| `host-rfc1918-digest.service.template` | Phases 6 and 13 | `/etc/systemd/system/host-rfc1918-digest.service` |
| `host-rfc1918-digest.timer.template` | Phases 6 and 13 | `/etc/systemd/system/host-rfc1918-digest.timer` |
| `60-firewall-integrity.rules` | Phase 6 | `/etc/audit/rules.d/60-firewall-integrity.rules` |

## How to use

```bash
# Example for nftables:
cp configs/nftables.conf.template /tmp/nftables.conf
# Edit and replace [REPLACE_ME_*] markers
cp /tmp/nftables.conf /etc/nftables.conf
nft -c -f /etc/nftables.conf   # validate
nft -f /etc/nftables.conf       # apply
```

Notes:

- This build is root-only: `mac-ssh-config.template` and `sshd_config.snippet` log in as `root` (`PermitRootLogin prohibit-password`, `AllowUsers root`), matching [Phase 03](../docs/03-first-boot-ssh.md). The RFC1918 alert and digest units run as **system** units under root (`/etc/systemd/system/`), not `--user` units.
- RFC1918 delivery is two-tier: `host-rfc1918-alert.*` is the loud immediate channel (new suspicious events only), and `host-rfc1918-digest.*` is the quiet twice-daily heartbeat (00:00/12:00 local) that also reports the silently-dropped `ts-direct-noise` / `magicdns-noise` / `natpmp-noise` / `ssdp-noise` counters from nftables.
- The nftables template assumes AdGuard is queried on `127.0.0.1` by default, so no AdGuard container-IP placeholder is required unless you intentionally use that branch.
- Hermes runtime config on this root-only host lives under `/root/.hermes/` and should be backed up, not committed here unsanitized.
- The RFC1918 alert env template contains Telegram secrets. Keep it at `/root/.config/host-alerts/rfc1918-alert.env` with `chmod 600`.

## Adding your own configs to the repo

When publishing a config you've customized:

1. Sanitize: replace your real IPs/usernames with `[REPLACE_ME_*]` markers
2. Drop in `configs/` as `.template`
3. Update this README's table

## What to *never* put in here

- VPN private keys
- API tokens
- LUKS passphrases
- WireGuard configs (entire `wg0.conf`)
- AdGuard admin password hash
- CrowdSec enrollment token
- Telegram bot tokens
- Unsanitized `/root/.hermes/config.yaml`, `/root/.hermes/.env`, or channel/session state
- Any other secrets or personally identifiable information
