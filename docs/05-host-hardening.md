# Phase 05 — Host Hardening: Kernel, AppArmor, auditd, AIDE, Tuning

> **Time required:** ~30–60 minutes

## Why this phase

This is where the system goes from "default Ubuntu" to "actively defending itself." We:

- Tighten kernel parameters (sysctl + cmdline) to reduce memory-corruption attack surface
- Switch AppArmor profiles to enforcing mode (Ubuntu ships many in complain mode)
- Apply CIS/USG hardening where available on this Ubuntu release
- Enable auditd with comprehensive rules for forensics
- Set up AIDE for file integrity monitoring
- Configure unattended-upgrades

For the host-native Hermes model, this phase stays relevant. The main agent later gets broad local power, so the machine still needs sane kernel defaults, MAC enforcement, auditability, and a patching baseline.

## What we're building

| Layer | Tool | Purpose |
| --- | --- | --- |
| Memory protections | sysctl | KASLR strict, restrict ptrace, no kexec, etc. |
| Kernel cmdline | GRUB | slab_nomerge, init_on_alloc, vsyscall=none, etc. |
| Process MAC | AppArmor enforcing | Per-process access control |
| CIS hardening (release-dependent) | Ubuntu Pro CIS/USG tooling | Automated baseline hardening where available |
| Audit | auditd + Neo23x0 rules | Privileged-action logging |
| File integrity | AIDE | Daily baseline check |
| Patches | unattended-upgrades | Auto security updates daily |

## Prerequisites

- Phase 3 complete
- SSH access from Client (`tailscale ssh root@homelab` in steady state)

## Profile note

- **Keep this phase in both profiles.** The performance-first profile removes the heaviest visibility layers later, not the kernel, AppArmor, patching, or basic audit baseline.
- **Phase 7 container branch may add compatibility overrides.** Keep this phase as the security baseline; only add targeted exceptions in the optional container branch if required by workload behavior.

## Dependency and optionality

- Required before this phase: Phase 03 remote admin baseline.
- Required after this phase: Phase 06 assumes this hardening baseline is already in place.
- Optional steps in this phase:
  - Step 5.5 CIS/USG is release-dependent and may be unavailable.
  - Step 5.7b local AIDE ignore tuning is optional quality-of-life only.
- Downstream interaction: Phase 07 may introduce container-specific compatibility overrides if your selected workloads require them.

## Step 5.1 — Update package index

```bash
apt update
apt upgrade -y
```

## Step 5.2 — Sysctl hardening

Create a hardening file:

```bash
nano /etc/sysctl.d/99-hardening.conf
```

Paste:

```conf
# ============================================================
# Kernel hardening — autonomous runtime host
# Source: Madaidan's Linux Hardening Guide + CIS Ubuntu Benchmark
# ============================================================

# === Memory protections ===
# Restrict access to kernel addresses
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3

# BPF JIT hardening (mitigates JIT spray attacks)
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# Restrict ptrace (limits process introspection by attackers)
kernel.yama.ptrace_scope = 2

# Disable kexec (so a compromised root cannot replace the running kernel)
kernel.kexec_load_disabled = 1

# Disable user namespaces for unprivileged users
# (Phase 7 revisits this only when you want Podman support containers or sandboxes)
kernel.unprivileged_userns_clone = 0

# Disable SysRq magic keys
kernel.sysrq = 0

# Disable core dumps for setuid programs
fs.suid_dumpable = 0
kernel.core_uses_pid = 1

# Address-space layout randomization (max)
kernel.randomize_va_space = 2

# === Filesystem hardening ===
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# === Network hardening ===
# IPv4
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.log_martians = 1

# IPv6 (disable entirely; we don't use it on the agent LAN)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# === TCP performance + security ===
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
```

Save (Ctrl+O, Enter, Ctrl+X).

Apply:

```bash
sysctl --system
```

Watch the output — should print all the keys with their new values. Errors mean a typo.

## Step 5.3 — Kernel cmdline hardening

Edit GRUB:

```bash
nano /etc/default/grub
```

Find the `GRUB_CMDLINE_LINUX_DEFAULT` line and replace it with:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 pti=on vsyscall=none debugfs=off oops=panic module.sig_enforce=1 lockdown=confidentiality mce=0 loglevel=0 randomize_kstack_offset=on"
```

Each parameter is explained briefly:

- `slab_nomerge` — prevents heap-spray attacks from merging slabs
- `init_on_alloc=1 init_on_free=1` — zero memory on alloc/free, mitigates use-after-free
- `page_alloc.shuffle=1` — randomizes page allocator
- `pti=on` — page table isolation (Meltdown mitigation)
- `vsyscall=none` — removes deprecated vsyscall page
- `debugfs=off` — disables debug filesystem
- `oops=panic` — kernel oops → panic, prevents some exploitation
- `module.sig_enforce=1` — only signed kernel modules
- `lockdown=confidentiality` — locks down kernel APIs that bypass other controls
- `mce=0` — machine check disabled (some exploits use these)
- `randomize_kstack_offset=on` — randomize kernel stack offset per syscall

> ⚠️ Important compatibility note: `module.sig_enforce=1` means out-of-tree DKMS modules must be enrolled via MOK when Secure Boot is on. If you plan to use proprietary NVIDIA drivers in Phase 7, complete the MOK enrollment step there or the driver will not load.

Save. Update GRUB:

```bash
update-grub
```

Reboot to apply:

```bash
reboot
```

After reboot, verify:

```bash
cat /proc/cmdline
# Should show all the new options we added to GRUB_CMDLINE_LINUX_DEFAULT (quiet may be missing if the system is configured to hide it on boot)
```

## Step 5.3b — Quick post-reboot health check

Before moving on, confirm this reboot didn't leave failed units behind:

```bash
systemctl --failed
```

If `kdump-tools` failed and you are using `kernel.kexec_load_disabled=1`, that's an expected and intentional conflict. Disable kdump cleanly:

```bash
sed -i 's/^USE_KDUMP=.*/USE_KDUMP=0/' /etc/default/kdump-tools 2>/dev/null || true
systemctl disable --now kdump-tools.service 2>/dev/null || true
systemctl mask kdump-tools.service 2>/dev/null || true
systemctl reset-failed
```

> **Why this trade and not the other way around.** `kernel.kexec_load_disabled=1` blocks a compromised root from booting a different kernel via `kexec_load`, bypassing Secure Boot, `module.sig_enforce=1`, and `lockdown=confidentiality`. Those three controls work as a layered set — dropping the kexec lock weakens the other two as well. kdump only provides post-mortem crash dumps; for a host that runs adversarial-ish workloads (the Hermes threat model in Phase 00), keeping the kernel attack surface closed is worth more than convenient crash analysis. If you ever need crash dumps for a specific kernel issue, flip `kexec_load_disabled` to `0` temporarily for the debug session and revert after — it's one-way per boot, so a reboot restores the lock.

### Slow boot from `systemd-networkd-wait-online`

If `systemd-analyze blame` shows `systemd-networkd-wait-online.service` taking ~2 minutes, the cause is almost always an unplugged secondary NIC declared in netplan. Netplan generates a wait-online drop-in that waits for **every** ethernet it knows about (`-i enp6s0:degraded -i enp5s0:degraded`), and the unplugged one never reaches `degraded`, so the unit times out after 2 minutes.

Confirm the cause:

```bash
systemd-analyze blame | head -5
systemctl cat systemd-networkd-wait-online.service | tail -10
# Look for "-i <iface>" entries — if any of them are unplugged, that's the source
```

The right fix is to remove the unused interface from netplan (not a systemd-unit override — netplan regenerates the drop-in on every boot and overrides would need to be re-applied). Inspect the current config:

```bash
ls /etc/netplan/
cat /etc/netplan/*.yaml
```

Back it up, delete the unused interface block, and re-apply:

```bash
cp /etc/netplan/00-installer-config.yaml /etc/netplan/00-installer-config.yaml.bak.$(date +%F-%H%M%S)

# Replace enp5s0 with the actual unused interface name from your config
sed -i '/^    enp5s0:/,/^      set-name: enp5s0$/d' /etc/netplan/00-installer-config.yaml

cat /etc/netplan/00-installer-config.yaml   # sanity check — keep the uplink block intact
chmod 600 /etc/netplan/00-installer-config.yaml
netplan generate
netplan apply
```

If you want to keep the interface in netplan for future use but stop blocking boot on it, replace the deletion with `optional: true` under the interface block instead.

### Redundant cloud-image packages on a bare-metal install

Ubuntu's server installer leaves a few packages enabled by default that only make sense for cloud images. On bare-metal homelab hardware they are redundant and add noise (or worse, real boot delays):

| Package | Symptom |
| --- | --- |
| `cloud-initramfs-copymods` | dmesg: `Kernel command line option 'copymods' is deprecated, use 'rd.driver.export' instead.` — dracut shim emits this on every boot just by being installed |
| `overlayroot` | dmesg: `dracut-pre-pivot[...]: ln: Read-only file system` — its pre-pivot hook tries to `ln` into the rootfs before it's writable |
| `cloud-initramfs-dyn-netconf` | dynamic network config for cloud bootstrapping; not needed when netplan owns the config |

Find which are installed and purge:

```bash
dpkg -l | grep -E 'cloud-initramfs|overlayroot' || echo "None installed"

apt purge -y cloud-initramfs-copymods overlayroot cloud-initramfs-dyn-netconf 2>/dev/null
update-initramfs -u -k all
```

Verify after the next reboot:

```bash
dmesg | grep -iE 'copymods|dracut-pre-pivot.*Read-only' || echo "Clean — boot noise gone"
```

## Step 5.4 — AppArmor: confirm enabled, set profiles to enforce

```bash
# Confirm AppArmor is loaded and running
aa-status
# Expect: "apparmor module is loaded" and a count of profiles in enforce mode (may be 0) and complain mode (some profiles ship in complain by default)
```

Ubuntu 26.04 ships most profiles in *enforce* mode by default. Some are in *complain* (warn but allow). Let's force everything to enforce:

```bash
# Install utilities if not present
apt install apparmor-utils apparmor-profiles apparmor-profiles-extra -y

# Set all loaded profiles to enforce
aa-enforce /etc/apparmor.d/*

# Re-check status
aa-status
```

The output now shows almost everything in enforce mode. Anything that flips a service into a bad state can be reverted with `aa-complain /etc/apparmor.d/<profile>`. We'll keep an eye on AppArmor denials in dmesg during later phases and adjust as needed.

## Step 5.4b — Cleanup temporary AppArmor complain-mode changes

If you switch any profile to complain mode during later troubleshooting, move it back to enforce as soon as the service is stable.

```bash
aa-status
aa-enforce /etc/apparmor.d/<profile>
aa-status
```

## Step 5.5 — CIS/USG hardening (release-dependent)

Ubuntu Pro compliance tooling availability varies by release. On Ubuntu 26.04, `cis/usg` may currently be unavailable. This step handles both cases cleanly. If the tooling is available, we run it and snapshot the before/after state. If not, we skip and record that fact for future reference.

```bash
apt install ubuntu-pro-client -y
pro refresh
pro status --all | grep -Ei 'cis|usg' || true

# Try to enable compliance tooling repository (no-op if unavailable)
pro enable cis || true

mkdir -p ~/baseline-snapshot

if command -v usg >/dev/null 2>&1; then
  usg generate-tailoring cis_level1_server cis-tailoring.xml
  usg audit --tailoring-file cis-tailoring.xml | tee usg-audit-before.txt | tail -20
  usg fix --tailoring-file cis-tailoring.xml | tee usg-fix.log | tail -20
  usg audit --tailoring-file cis-tailoring.xml | tee usg-audit-after.txt | tail -20
  mv usg-audit-before.txt usg-audit-after.txt usg-fix.log ~/baseline-snapshot/
else
  echo "USG/CIS tooling unavailable on this release; continuing with remaining hardening controls." \
    | tee ~/baseline-snapshot/usg-unavailable.txt
fi
```

If USG is available, its fix step may request a reboot. Reboot if prompted.

## Step 5.6 — auditd installation + Neo23x0 rules

```bash
apt install auditd audispd-plugins -y

# Confirm running and enabled on boot
systemctl status auditd --no-pager
```

Get Neo23x0's well-known hardening ruleset:

```bash
curl -fsSL https://raw.githubusercontent.com/Neo23x0/auditd/master/audit.rules \
  -o /etc/audit/rules.d/hardening.rules

# Load rules immediately (they will also load on boot)
augenrules --load || true

# Verify (some rules may be skipped on newer kernels or for paths not present)
auditctl -s
auditctl -l | head -30
auditctl -l | wc -l
```

Test:

```bash
touch /etc/shadow.test  # not an attack, just a watched file
rm /etc/shadow.test
ausearch -i -ts recent | grep shadow.test | head -10
# Should show audit events
```

## Step 5.7 — AIDE (file integrity monitoring)

```bash
apt install --no-install-recommends aide aide-common -y

# Configure
nano /etc/default/aide
# Make sure CRON_DAILY_RUN is set to "yes" to enable daily checks

# Build initial database (takes 5–10 minutes — it hashes the entire filesystem)
aide --init --config=/etc/aide/aide.conf
```

When done, AIDE has a baseline. Daily cron will diff against it and email/log any changes.

Move the new db into place:

```bash
cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

Test:

```bash
aide --check --config=/etc/aide/aide.conf | head -40
```

On active systems, first check often reports runtime changes in `/run`, logs, Tailscale state, or livepatch state. That is normal.

### Step 5.7b — Optional: reduce noisy runtime-only paths

Use this only if the default AIDE output is too noisy for your workflow. No later phase depends on this tuning.

Then rebuild baseline:

```bash
tee /etc/aide/aide.conf.d/99-local-ignore >/dev/null <<'EOF'
!/run/.*
!/var/log/audit/audit.log
!/var/lib/tailscale/.*
!/var/log/sysstat/.*
!/var/snap/canonical-livepatch/common/kernel-sru-date
!/var/snap/canonical-livepatch/common/kernel-support-status
!/var/snap/canonical-livepatch/common/last-check
!/var/snap/canonical-livepatch/common/logs
EOF

aide --init --config=/etc/aide/aide.conf
cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

Now create a deliberate change and re-check:

```bash
echo "test" | tee /etc/aide-test-file
aide --check --config=/etc/aide/aide.conf | head -30
# Should show: "Detected:" with /etc/aide-test-file as Added and "Summary: Added: 1"
rm /etc/aide-test-file
```

## Step 5.8 — Configure unattended-upgrades

Should be installed already; configure it:

```bash
dpkg-reconfigure -plow unattended-upgrades
# Answer YES to auto-install security updates and ESM updates, NO to everything else
```

Make it apply security + ESM updates only (not all upgrades, which can be disruptive):

```bash
nano /etc/apt/apt.conf.d/50unattended-upgrades
```

Ensure these lines exist (uncomment if commented):

```text
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
```

Save. Test config:

```bash
unattended-upgrade --dry-run --debug 2>&1 | head -30
# Should list candidate packages and exit cleanly without errors (does not actually apply updates in dry-run)
```

## Step 5.9 — Disable unused services

Common unneeded services on a server:

```bash
# Avahi (mDNS) — not needed on isolated subnet
systemctl disable --now avahi-daemon.service avahi-daemon.socket 2>/dev/null || true

# CUPS (printing)
systemctl disable --now cups.service cups.socket cups-browsed.service 2>/dev/null || true

# Bluetooth
systemctl disable --now bluetooth.service 2>/dev/null || true

# ModemManager
systemctl disable --now ModemManager.service 2>/dev/null || true

# Verify
systemctl list-unit-files --state=enabled --type=service
```

## Step 5.10 — Re-snapshot

```bash
cd ~/baseline-snapshot

# Record post-hardening state
systemctl list-unit-files --type=service --state=enabled > services-enabled-post.txt
ss -tlnp > open-ports-post.txt
ss -ulnp >> open-ports-post.txt
sysctl -a 2>/dev/null > sysctl-all-post.txt

# Diff
diff services-enabled.txt services-enabled-post.txt | head -20
diff open-ports.txt open-ports-post.txt | head -20

# Sysctl diff is more meaningful with grep
grep -E "kptr|dmesg|bpf|ptrace|kexec|userns|sysrq|suid|randomize|protected" sysctl-all.txt > sysctl-before-key.txt
grep -E "kptr|dmesg|bpf|ptrace|kexec|userns|sysrq|suid|randomize|protected" sysctl-all-post.txt > sysctl-after-key.txt
diff sysctl-before-key.txt sysctl-after-key.txt
```

## Verification checklist

- [ ] `/proc/cmdline` shows the new boot parameters
- [ ] `systemctl --failed` is empty after reboot
- [ ] `aa-status` shows profiles in enforce mode
- [ ] CIS/USG audit completed if tooling is available (or recorded as unavailable on this release)
- [ ] `auditctl -l | wc -l` returns a non-zero rule count
- [ ] `aide --check --config=/etc/aide/aide.conf` runs (small runtime-only diffs are acceptable)
- [ ] `unattended-upgrade --dry-run` runs without errors
- [ ] Avahi, CUPS, Bluetooth, ModemManager disabled

## Issues encountered and solutions

- **Kernel-hardening side effects on tooling:** some convenience tools expected relaxed namespace/kernel defaults. I documented explicit exceptions instead of weakening the baseline silently.
- **Audit rule noise during first run:** initial auditd output was too noisy to be actionable. I tuned rule ordering and focused on high-signal events tied to containment and privilege changes.
- **Neo23x0 `augenrules --load` errors for missing paths:** the upstream ruleset references products and directories not present on this host (`filebeat`, `crowdstrike`, some `NetworkManager` paths). I removed or commented those lines in `/etc/audit/rules.d/hardening.rules` before reloading. Firewall-specific watches live in Phase 6's `60-firewall-integrity.rules` instead of bloating the generic ruleset further.
- **AIDE runtime cost on first baseline:** initial database generation took longer than expected; scheduling integrity checks outside active build windows avoided workflow disruption.

## Troubleshooting

**System won't boot after GRUB changes.** From the GRUB menu, press `e` to edit a boot entry, remove offending parameter, boot. Then fix `/etc/default/grub` and `update-grub`.

**`pro enable cis` reports unavailable on Ubuntu 26.04.** This can be expected while compliance tooling catches up for a new release. Continue with the remaining controls in this phase and record the skip in `~/baseline-snapshot/usg-unavailable.txt`.

**`kdump-tools` fails to load kdump kernel after reboot.** Expected when `kernel.kexec_load_disabled=1` is set. Disable and mask `kdump-tools` (see Step 5.3b).

**Boot takes ~2 minutes / `systemd-networkd-wait-online.service` times out.** Caused by an unplugged secondary NIC declared in netplan — wait-online waits for every interface netplan knows about. Remove the unused interface from `/etc/netplan/*.yaml` (see Step 5.3b). A systemd-unit override is not the right fix because netplan re-generates the wait-online drop-in on every boot.

**Boot log shows `dracut-pre-pivot[...]: ln: Read-only file system` or `copymods is deprecated`.** Redundant cloud-image packages left over from the installer. Purge `cloud-initramfs-copymods`, `overlayroot`, and `cloud-initramfs-dyn-netconf` (see Step 5.3b).

**Installing AIDE opens a Postfix configuration prompt.** Re-run with `--no-install-recommends` to avoid pulling an MTA in this phase.

**`unprivileged_userns_clone=0` breaks specific container workloads later.** Expected on a hardened baseline. Apply only minimal, documented overrides in Phase 7 if your optional container branch needs them.

**AppArmor denials in dmesg.** Identify which profile: `journalctl -k | grep DENIED`. Set that profile to complain mode: `aa-complain /etc/apparmor.d/<profile>`.

**AIDE takes forever.** Normal — full filesystem hash on first run. Run during a coffee break.

**AIDE reports differences immediately after initialization.** Common for active runtime paths (`/run`, logs, Tailscale, livepatch state). Use optional local ignore entries in Step 5.7 if you want cleaner day-to-day output.

**`augenrules --load` errors on paths from Neo23x0 rules (`filebeat`, `crowdstrike`, etc.).** Those watches target software not installed on this host. Edit `/etc/audit/rules.d/hardening.rules` to remove or comment the broken lines, then reload. Add firewall-specific watches in Phase 6 Step 6.8e instead of expanding the generic ruleset.

## Next

→ [Phase 06: nftables firewall](06-nftables-firewall.md)
