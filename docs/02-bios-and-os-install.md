# Phase 02 — BIOS Settings + Ubuntu 26.04 LTS Install

> **Time required:** ~90 minutes

## Why this phase

We're laying down the foundation: a clean OS install, a sane firmware baseline, and a storage choice that matches your recovery goals. The default repo path is plain ext4 for unattended reboot recovery. If you require encryption at rest, the optional LUKS path is still documented here, but it changes your remote-recovery story and should be a deliberate choice.

26.04 LTS specifically: brand-new "Resolute" release (April 2026), supported until 2031 standard, until 2036 with Ubuntu Pro ESM. Modern kernel (6.14+), latest nftables, AppArmor, systemd. Newer releases may be available by the time you read this; if so, check their support timelines and choose the latest LTS you can get. Avoid non-LTS releases for this project, as they have shorter support windows and may require more frequent disruptive reinstalls.

## What we're building

- BIOS with hardware virtualization + Secure Boot enabled
- Ubuntu Server 26.04 LTS installed minimal, headless, on the 256GB NVMe SSD
- Root filesystem installed on the 256GB NVMe SSD
- Default continuity path: plain ext4 root for unattended reboot recovery
- Optional encrypted path: LUKS2 + LVM root with passphrase entry at boot
- An installer bootstrap user with sudo privileges (deleted in Phase 03 after root access is validated)
- Ubuntu Pro enrolled for `esm-infra`, `esm-apps`, and `livepatch` (`cis/usg` if available for this release)
- The 2TB HDD untouched (we will set it up in Phase 12 for bulk Hermes/runtime data)

## Prerequisites

- Phase 1 complete (Server physically connected to Router 3 via Ethernet)
- USB drive ≥8GB for flashing Ubuntu ISO
- Monitor + keyboard connected to Server for BIOS and install
- Client to flash the USB
- Ubuntu Server 26.04 ISO downloaded from <https://releases.ubuntu.com/26.04/> and verified (SHA256) on Client
- Ubuntu Pro token from <https://ubuntu.com/pro/dashboard> (enter during install or attach later with `pro attach`)
- balenaEtcher installed on Client (<https://etcher.balena.io/>) for flashing the USB — safer and more user-friendly than `dd` or `diskpart`.

## Dependency and optionality

- Required before this phase: Phase 01 network isolation.
- Required after this phase: base OS install is required for every later phase.
- Optional step C.7 (LUKS+LVM root): enables at-rest protection but changes reboot/recovery behavior and feeds into Phase 13 recovery Path B.
- Optional step C.9 (Ubuntu Pro attach during install): can be done later with `pro attach`.
- Optional step C.17 ISO cleanup: housekeeping only, no downstream dependency.

## Hardware: Server and Client

This guide uses:

- **Server (PC):** Intel i9-7920X 12-core/24-thread CPU, NVIDIA GTX 1080 11GB GPU, 32GB DDR4 RAM, 256GB NVMe SSD + 2TB HDD storage, ASUS X299 Pro WS motherboard, Corsair RM1000i 1000W PSU. This is a powerful machine that can run multiple VMs/containers for testing and learning, with room to grow. The X299 Pro WS has good BIOS support for virtualization features and Secure Boot, which is essential for this project. The 256GB NVMe is for the OS and critical apps, while the 2TB HDD is reserved for data storage and non-critical workloads (set up in Phase 12). You can use any reasonably modern PC with UEFI firmware, but make sure it supports VT-x, VT-d, and Secure Boot for the best experience. If your hardware lacks these features, you can still follow the general hardening principles, but some controls (e.g., Secure Boot, certain container isolation features) won't be available.
- **Client:** MacBook Air M1 (2020) running macOS Tahoe, used for flashing USB and SSH access. You can use any machine with balenaEtcher and SSH client.

## Part A: Prepare bootable USB

### A.1 — Identify the USB on your Client

Plug it in and identify it:

```bash
diskutil list
```

Find your USB (large drive, label like `Untitled` or factory name). Note the disk identifier, e.g., `/dev/disk4`.

**⚠️ verify it before any destructive command.**

### A.2 — Verify Ubuntu ISO

Verify the ISO hash:

```bash
cd ~/Downloads
shasum -a 256 ubuntu-26.04-live-server-amd64.iso
```

Compare the output to the SHA256 listed at <https://releases.ubuntu.com/26.04/>

### A.3 — Flash with balenaEtcher

Open balenaEtcher:

1. **Flash from file** → select Ubuntu 26.04 ISO
2. **Select target** → pick the 1TB USB (balenaEtcher will warn about large drives — confirm)
3. **Flash!** → enter Client password (Mac: your account password; Windows: UAC prompt)

Takes ~10 minutes including verify pass.

> Why balenaEtcher beats `dd` or `diskpart`: refuses to write to your internal disk by default, verifies after write, shows clear progress. Less risk of catastrophic typo.

When done, safely eject the USB from your Client.

## Part B: BIOS configuration

Plug monitor, keyboard, USB into the Server. Power on. **Press `Delete` repeatedly** as it boots.

### B.1 — Enable VT-x

`Advanced → CPU Configuration → Intel (VMX) Virtualization Technology → Enabled`

### B.2 — Enable VT-d

`Advanced → System Agent (SA) Configuration → VT-d → Enabled`

### B.3 — Check TPM status

`Advanced → Trusted Computing` and `Advanced → PCH-FW Configuration → PTT`

Document whatever you find. Likely absent on X299. That's fine.

### B.4 — Enable Secure Boot

```text
Boot → CSM → Disabled
Boot → Secure Boot → OS Type: Other OS
Boot → Secure Boot → Key Management → Install default keys
Boot → Secure Boot → Secure Boot State: Enabled
```

### B.5 — Set boot priority

`Boot → Boot Option Priorities → Boot Option #1 → [UEFI: your USB drive]`

### B.6 — Save and exit

`Exit → Save Changes and Reset (F10)`

## Part C: Ubuntu 26.04 install

### C.1 — Language + keyboard

Pick `English`, match keyboard.

### C.2 — Installation type

**Ubuntu Server** (not Minimized).

### C.3 — Network

Ethernet detected, IP `192.168.10.x`. Note it.

### C.4 — Proxy

Leave blank.

### C.5 — Mirror

Default.

### C.6 — Storage (plain ext4)

Choose **Custom storage layout**.

Layout on 256GB NVMe:

| Partition | Size | Format              | Mount       |
| --------- | ---- | ------------------- | ----------- |
| nvme0n1p1 | 1 GB | FAT32               | `/boot/efi` |
| nvme0n1p2 | 2 GB | ext4                | `/boot`     |
| nvme0n1p3 | rest | ext4                | `/`         |

**Leave 2TB HDD untouched.**

Steps in installer UI:

1. NVMe → **Add GPT Partition**: `1G`, FAT32, mount `/boot/efi`
2. Free space → **Add GPT Partition**: `2G`, ext4, mount `/boot`
3. Free space → **Add GPT Partition**: rest, ext4, mount `/`

Confirm wipe.

**Plain ext4** is the default for unattended reboot recovery and immediate post-boot SSH access.

**Optional: encrypted root with LUKS+LVM.** See section C.7 for the alternative approach with at-rest disk encryption.

### C.7 — Optional: Storage with LUKS+LVM encryption

**Skip this section if you are using plain ext4 (recommended default). Use this section only if you require encrypted root.**

No later phase requires encrypted root. The dependency is the opposite: if you choose this branch now, follow Phase 13 Path B for remote recovery planning.

Steps in installer UI for LUKS+LVM setup:

1. NVMe → **Add GPT Partition**: `1G`, FAT32, mount `/boot/efi`
2. Free space → **Add GPT Partition**: `2G`, ext4, mount `/boot`
3. Free space → **Add GPT Partition**: rest, leave unformatted
4. That partition → **Format** → `LUKS encrypted physical volume` → enter passphrase
5. Unlocked LUKS volume → **Create LVM volume group**: name `vg-system`
6. Inside VG → **Create logical volume**: name `lv-root`, max size, ext4, mount `/`

**⚠️ Store LUKS passphrase in your password manager. Losing it = data is gone forever.**

If you enable encrypted root here, you will need manual passphrase entry at each boot. For guaranteed off-site recovery, budget for a real out-of-band console. A smart plug alone will not unlock LUKS remotely. See Phase 13 for recovery runbooks specific to encrypted vs. plain ext4 setups.

### C.8 — Profile

The Ubuntu installer requires a named user — but this is a **root-only** build, so this account is just a throwaway *bootstrap* user. Phase 03 authorizes your key directly for `root` and then deletes this account. Pick something simple; it will not survive first boot.

| Field | Value |
| --- | --- |
| Hostname | `homelab` |
| Username | (bootstrap only — any name; deleted in Phase 03) |
| Password | strong, stored in PM |

### C.9 — Ubuntu Pro

Enter your token from <https://ubuntu.com/pro/dashboard>. On current Ubuntu Pro flows, attach normally enables the recommended LTS services from first boot: `esm-infra`, `esm-apps`, and `livepatch`.

> **Never share your Ubuntu Pro token.** Store it in a password manager.

If you skip here, enroll later with `sudo pro attach <TOKEN>`.

### C.10 — SSH

- **Install OpenSSH: YES**
- **Import identity: skip** (manual key setup in Phase 3)
- **Allow password auth: NO**

### C.11 — Snaps

Skip all.

### C.12 — Wait

10–30 minutes.

### C.13 — Reboot

**Remove USB before rebooting.**

Boot sequence: POST → GRUB → boot → login.

*(If you chose the optional LUKS+LVM setup in C.7, you will see **LUKS passphrase** prompt between GRUB and boot.)*

Log in.

### C.14 — Verify

```bash
# Encryption
lsblk
# Expect plain ext4:
# NAME        FSTYPE MOUNTPOINTS
# nvme0n1p1   vfat   /boot/efi
# nvme0n1p2   ext4   /boot
# nvme0n1p3   ext4   /
#
# Or if you chose LUKS+LVM:
# NAME                  FSTYPE      MOUNTPOINTS
# nvme0n1p1             vfat        /boot/efi
# nvme0n1p2             ext4        /boot
# nvme0n1p3             crypto_LUKS
# └─vg--system-lv--root ext4        /
# (exact mapper names vary; look for a dm-crypt/LUKS layer if encrypted)

# Secure Boot
sudo mokutil --sb-state
# Expect: SecureBoot enabled

# Virtualization
grep -c vmx /proc/cpuinfo
# Expect: positive number

# Network
ip a | grep "inet "
# Expect: 192.168.10.x

# Internet
ping -c 3 1.1.1.1

# Ubuntu Pro
sudo pro status --all
# Expect: attached, with `esm-infra`, `esm-apps`, and `livepatch`
# enabled or at least entitled/available for this machine

# OS version
lsb_release -a
# Expect: 26.04 LTS
```

> Note: blur the prompt line if it shows a username or hostname you want to keep private.

### C.15 — Enable Ubuntu Pro services

```bash
# Make sure the current documented Pro client is installed
sudo apt install ubuntu-pro-client -y

# Refresh contract/config/messages after attach
sudo pro refresh

# Current recommended LTS defaults are esm-infra, esm-apps, and livepatch.
# If the installer already enabled them, these commands should be no-ops.
sudo pro enable esm-infra
sudo pro enable esm-apps
sudo pro enable livepatch

# Compliance tooling name/availability is release-dependent.
# On 26.04 they may be enabled by default, or unavailable. Check status and enable if possible.
sudo pro status --all | grep -Ei 'cis|usg' || true
sudo pro enable cis || true

sudo pro status
```

If `pro enable cis` reports unavailable on your release, that's fine — continue. The remaining hardening controls are applied in Phase 5. After enabling Pro services, continue with the normal package upgrade below so any newly available `esm-infra`/`esm-apps` updates are applied.

### C.16 — Initial update

```bash
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
[ -f /var/run/reboot-required ] && sudo reboot
```

If reboot needed, log back in. (If using LUKS, enter passphrase at boot prompt.)

### C.17 — Cleanup installer artifacts

Now that the install is validated, remove temporary installer state.

1. Set BIOS boot priority back to the NVMe drive. Do not leave USB first in the boot order.
2. On your Client, repurpose the installer USB and optionally remove the ISO copy:

```bash
# Replace /dev/disk4 with the USB identifier from Part A
diskutil eraseDisk ExFAT LINUX-INSTALL MBRFormat /dev/disk4

# Optional: remove the ISO after successful validation
rm -f ~/Downloads/ubuntu-26.04-live-server-amd64.iso
```

## Verification checklist

- [ ] VT-x + VT-d enabled
- [ ] Secure Boot enabled (`mokutil --sb-state` confirms)
- [ ] TPM status documented
- [ ] Plain ext4 confirmed OR LUKS prompts every boot (if encrypted setup chosen)
- [ ] IP `192.168.10.x`
- [ ] `ping 1.1.1.1` works
- [ ] `pro status` shows enrolled with `esm-infra` + `esm-apps` + `livepatch` (and `cis/usg` if available)
- [ ] Fully updated

## Issues encountered and solutions

- **UEFI boot order drift after install media removal:** first reboot occasionally selected the USB entry again. Fix was to remove USB physically before reboot and pin `ubuntu` as first UEFI boot target.
- **Secure Boot uncertainty on custom board firmware:** when confirmation screens were ambiguous, I validated from Linux (`mokutil --sb-state`) instead of trusting firmware wording alone.
- **Disk targeting anxiety on multi-disk host:** before partitioning, I captured `lsblk -o NAME,SIZE,MODEL,SERIAL` output and matched serial numbers to avoid formatting the wrong device.

## Troubleshooting

**Installer doesn't see NVMe** → check BIOS NVMe Configuration. Update BIOS firmware (X299 Pro WS has had multiple updates since 2017).

**LUKS prompt missing** → encryption didn't apply. Reinstall, watch C.6 carefully.

**Secure Boot won't enable** → disable CSM fully; try `Provision Factory Defaults` first.

**Ubuntu Pro fails** → network issue. Verify `ping 1.1.1.1`. Retry `sudo pro detach && sudo pro attach <TOKEN>`.

**`pro enable cis` (or `pro enable usg`) fails** → on 26.04 this can be unavailable. Continue to Phase 5 and apply the non-USG hardening controls there.

**Too many unexpected reboots are causing serious downtime** → if you chose LUKS, consider switching to the continuity path documented in [Phase 13](13-audit-maintenance.md) as an explicit risk trade.

## Next

→ [Phase 03: First boot — root-only Tailscale SSH bootstrap](03-first-boot-ssh.md)
