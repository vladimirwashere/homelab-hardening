# Phase 03 — First Boot: Root-Only Tailscale SSH Access + Hostname

> **Time required:** ~25 minutes

## Why this phase

This build is deliberately **root-only**: a single trusted-operator box with no separate admin user. The Ubuntu installer forces you to create a user at install time, so we treat that account as a throwaway *bootstrap* user — we use it just long enough to get root access working over Tailscale, then delete it. Steady state is `root` only.

The installer set up SSH with password auth disabled, but we haven't given the server any way to recognize *you* yet — without a key copied over, you can't actually log in remotely. We fix that now (authorizing your key directly for `root`), harden the SSH daemon, remove the bootstrap user, and verify we can disconnect the monitor + keyboard and run headless from here on. This is also the first step in our "remote-first" posture: we want to be able to manage the server entirely from our Client via SSH, without needing physical access for routine tasks. The Tailscale setup is a bit of extra work upfront, but it gives us secure, stable remote access without exposing any services on the LAN or needing router config.

This phase also establishes an important boundary for the later Hermes deployment: the host can be highly autonomous locally, but the Tailscale control plane remains operator-owned. Tags, ACLs, break-glass access, and any later public exposure workflow should stay outside the agent's authority.

Also: a small but valuable habit — set up the server so all the rest of the work can be done from your Client via SSH, copy-paste-friendly. This is the way most real-world servers are managed, and it's good practice to get comfortable with it early. It also means you can work from a more comfortable terminal environment on your Client, rather than being stuck at the physical console for every step.

## What we're building

- SSH keypair on your Client (if you don't already have one — one-time)
- Public key authorized for **root** on the Server (installed at physical console — one-time)
- Tailscale installed on the Server and Client: `tailscale ssh root@homelab` works from anywhere
- The installer's bootstrap user deleted, leaving a clean root-only account model
- OpenSSH disabled on the server after Tailscale is verified — no port 22 exposed on the LAN
- Hardened `sshd_config` (root-only, key-only) retained as emergency reference in case sshd must be temporarily re-enabled
- SSH config shortcut using the stable Tailscale hostname — no port-forward, no fixed IP needed
- Tailscale ACLs and exposure controls that stay operator-owned later, even after Hermes gets broad local power
- First snapshot of system baseline for later comparison

## Prerequisites

- Phase 2 complete
- Server booted, logged in at the physical console
- Client on any network (home WiFi is fine)
- Server has internet (`192.168.10.x`)
- Tailscale account set up (free at <https://tailscale.com> — same account on Client and Server)

## Dependency and optionality

- Required before this phase: Phase 02 OS install.
- Required after this phase: this phase establishes the remote admin path used by Phases 05-13.
- Optional steps in this phase:
  - Step 3.1 key generation is optional if you already have a trusted keypair.
  - Step 3.11 physical-console login disable is optional and has no downstream dependency.
  - Step 3.15 Path B (temporary LAN SSH) is break-glass only and should not be kept as steady state.
- Not optional for this build: Step 3.6d removes the installer's bootstrap user so the box is genuinely root-only.
- Phase 04 can be run right after this phase, but is optional.

## Access strategy

The Server sits behind Router 3's NAT. Rather than punching a port-forward through the router, we use **Tailscale**: a WireGuard-based overlay VPN that handles NAT traversal automatically.

- `tailscale ssh root@homelab` works from anywhere, not just the home LAN
- No open port 22 exposed on `192.168.10.x`
- No router config to maintain
- Cryptographically authenticated end-to-end

The one-time bootstrap problem (how do we install Tailscale on a machine we can't SSH into yet?) is solved with a **reverse tunnel**: the Server dials *out* to the Client, and we push Tailscale through that outbound connection.

## Step 3.1 — Generate SSH key on Client (if you don't already have one)

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null && echo "key exists" || echo "no key yet"
```

If no key:

```bash
ssh-keygen -t ed25519 -C "$(whoami)-client-$(date +%Y%m%d)"
# Accept default file location
# Set a passphrase (recommended — protects the key if Client is stolen)
```

> Why ed25519: modern, fast, strong, smaller than RSA. Don't use DSA or RSA <4096.

Show the public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

Copy the full output to clipboard.

## Step 3.2 — Authorize your key for root on the server

No, you do **not** have to type the ed25519 key manually. Because this build is root-only, we install the key directly into **`/root/.ssh/authorized_keys`** (using `sudo` from the bootstrap user's physical-console session).

Use one of these methods from easiest to hardest.

### Method A (recommended): USB file transfer

On your Client:

```bash
# Write only the public key to a small text file
cat ~/.ssh/id_ed25519.pub > ~/Downloads/homelab-id_ed25519.pub
```

Copy that file to a USB stick and plug it into the Server.

On the Server physical console:

```bash
sudo install -d -m 700 /root/.ssh

# Find and mount USB (adjust device/path as needed)
lsblk
sudo mkdir -p /mnt/usb
sudo mount /dev/sdb1 /mnt/usb

# Install key for root
cat /mnt/usb/homelab-id_ed25519.pub | sudo tee -a /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys

# Verify
sudo cat /root/.ssh/authorized_keys
# Should contain one full line starting with ssh-ed25519

# Unmount when done
sudo umount /mnt/usb
```

### Method B: direct paste at physical console (if your console supports it)

On the Server physical console:

```bash
sudo install -d -m 700 /root/.ssh
sudo nano /root/.ssh/authorized_keys
# Paste one complete line starting with ssh-ed25519
# Ctrl+O Enter to save, Ctrl+X to exit
sudo chmod 600 /root/.ssh/authorized_keys
sudo cat /root/.ssh/authorized_keys
```

### Method C (last resort): manual entry

Only use this if A/B are impossible. Manual typing is error-prone; if you must do it, run:

```bash
sudo ssh-keygen -lf /root/.ssh/authorized_keys
```

and compare the fingerprint to your Client key fingerprint from:

```bash
ssh-keygen -lf ~/.ssh/id_ed25519.pub
```

## Step 3.3 — Bootstrap: one-time reverse tunnel from Server to Client

This bridges the NAT gap exactly once. The Server dials out to your Client; you dial back in through that outbound tunnel.

**On your Client first** — enable Remote Login temporarily from macOS Settings:

`System Settings -> General -> Sharing -> Remote Login -> On`

Then get your Client LAN IP:

```bash
ipconfig getifaddr en0   # note your Client's LAN IP, e.g. 192.168.3.x
```

If you want a CLI status check (optional):

```bash
sudo systemsetup -getremotelogin
```

**On the Server** (physical console) — start the reverse tunnel:

```bash
# Confirm sshd is running and root key login is allowed (Ubuntu default)
sudo systemctl enable --now ssh
sudo sshd -T | grep -i permitrootlogin   # expect: permitrootlogin prohibit-password

# Open outbound tunnel: "anyone on Client:2222 gets forwarded to me:22"
# (the outbound dial uses YOUR CLIENT username on the Mac)
ssh -o StrictHostKeyChecking=accept-new \
    -fN \
    -R 2222:localhost:22 \
    you@192.168.3.92
```

Replace `you` with your **Client (Mac) username** and `192.168.3.92` with your Client's LAN IP. You can run this from the bootstrap user's console session; `sudo` is only needed for the two commands above.

If prompted for `you@192.168.3.92` password, enter your Mac account password. If your Mac only allows key auth, add the server bootstrap public key to your Mac `~/.ssh/authorized_keys` before opening this tunnel.

Quick reachability check from the server console before opening the tunnel:

```bash
CLIENT_LAN_IP=192.168.3.92   # replace with your Mac LAN IP
ping -c 2 "$CLIENT_LAN_IP"
```

**On your Client** — connect back through the tunnel **as root** (key-based, since we authorized your key for root in Step 3.2):

```bash
ssh root@localhost -p 2222
```

The first time you connect, accept the new host key. You should land on the server's **root** shell.

**Keep both sessions open** until Tailscale is confirmed.

## Step 3.4 — Install Tailscale on the Server

In the SSH session (or at the physical console):

```bash
curl -fsSL https://tailscale.com/install.sh | sh

# Bring up with SSH enabled and tag this node as a server
tailscale up --ssh --advertise-tags=tag:server
```

Tailscale prints an authentication URL:

```text
To authenticate, visit:
    https://login.tailscale.com/a/xxxxxxxxxxxxxx
```

Open that URL on your Client. Since you're already logged in to Tailscale on the Client, click **Connect** to add the Server to your tailnet. Approve the `tag:server` tag when prompted.

Get the PC's Tailscale IP:

```bash
tailscale ip -4
# Returns something like 100.93.137.15 — note this
tailscale status
# Expect both the Client and Server to appear
```

## Step 3.5 — Tag Client as client

On your Client:

```bash
sudo tailscale set --advertise-tags=tag:client
```

If `set` is unavailable on your Client Tailscale version, tag it via the admin console:
[admin console](https://login.tailscale.com/admin/machines) → your Client → Edit tags → `tag:client`.

## Step 3.5b — Set MagicDNS name to `homelab` (quick)

This lets you keep a stable host name (`homelab`) for SSH-related workflows while the primary admin path remains `tailscale ssh root@homelab`.

1. In Tailscale admin console, enable MagicDNS:
[DNS settings](https://login.tailscale.com/admin/dns) -> toggle **MagicDNS** ON.
2. In Machines, rename your server node to `homelab` (or set this at bring-up with `tailscale set --hostname=homelab`).
3. From your Client, verify resolution:

```bash
tailscale status | grep -i homelab
tailscale ssh root@homelab
```

If the name is not visible immediately, wait ~30 seconds for control-plane propagation and retry.

## Step 3.6 — Test Tailscale SSH from Client

Open a **new terminal window** on your Client (leave the tunnel session open as a safety net):

```bash
tailscale ssh root@homelab
# or by IP if the hostname doesn't resolve:
# tailscale ssh root@100.93.137.15
```

Confirm it works:

```bash
whoami && hostname && tailscale status
```

Expected: `root`, the server hostname, and Tailscale status showing both devices. If this works, you have secure remote access to the server over Tailscale, and can proceed to remove the bootstrap user, harden the SSH daemon, and remove the temporary reverse tunnel. If it doesn't work, troubleshoot connectivity, tags, and ACLs before proceeding. The reverse tunnel session is still open as a fallback if needed.

## Step 3.6b — Lock down Tailscale ACLs (client -> server SSH only)

Your Linux-side hardening is only half the story. The other half is Tailscale policy.

In the Tailscale admin console, merge an ACL structure equivalent to this into your full policy file (do not replace the entire policy with only this fragment):

```json
"ssh": [
  {
    "action": "accept",
    "src": ["tag:client"],
    "dst": ["tag:server"],
    "users": ["root"]
  }
],
"tagOwners": {
  "tag:client": ["autogroup:admin"],
  "tag:server": ["autogroup:admin"]
}
```

This means:

- Only devices tagged `tag:client` can SSH to devices tagged `tag:server`
- Only tailnet admins can assign those tags (prevents random members from self-tagging)
- `root` is the only login user, matching this build's root-only model. **This `"root"` entry is required** — without it `tailscale ssh root@homelab` is denied and you lose remote access.

Quick validation:

- From your tagged Client (`tag:client`):

```bash
tailscale ssh root@homelab
```

Should succeed.

- From any untagged/non-client device in the same tailnet:

```bash
tailscale ssh root@homelab
```

Should be denied by ACL.

## Step 3.6c — Keep the Tailscale control plane operator-only

Later phases intentionally give Hermes broad local authority on this box. Do **not** let that spill into ownership of the tailnet itself.

- Keep Tailscale auth keys, tag changes, ACL edits, Serve/Funnel configuration, and admin-console access under the human operator's control.
- Do not hand `tailscale up`, `tailscale set`, `tailscale serve`, `tailscale funnel`, auth keys, or admin-console access to Hermes unless you explicitly accept that it can reshape the tailnet or publish services.
- Tailnet-only services later can simply listen on the host. They do not require giving the agent tailnet-admin privileges.

Quick check on the Server:

```bash
tailscale serve status
# Expected on a fresh build: no serve config
```

## Step 3.6d — Remove the installer's bootstrap user (go root-only)

Now that `tailscale ssh root@homelab` works **and** the key-based reverse-tunnel path proved root login over sshd works, the installer's bootstrap user has done its job. Delete it so the box is genuinely root-only.

> Do this from a **root** session (`tailscale ssh root@homelab`), never from the bootstrap user's own session — you cannot delete a user you are logged in as.

```bash
# From a root session. Replace BOOTSTRAP with the installer username.
BOOTSTRAP=youruser

if [ -z "$BOOTSTRAP" ] || [ "$BOOTSTRAP" = "youruser" ] || [ "$BOOTSTRAP" = "root" ]; then
  echo "Set BOOTSTRAP to the real installer username before running removal commands."
  exit 1
fi

id "$BOOTSTRAP" >/dev/null 2>&1 || { echo "User '$BOOTSTRAP' does not exist."; exit 1; }

# Optional: keep a backup of anything useful from its home first
tar czf /root/${BOOTSTRAP}-home-backup-$(date +%Y%m%d).tar.gz -C /home "$BOOTSTRAP" 2>/dev/null || true

# Stop its lingering services and processes
loginctl disable-linger "$BOOTSTRAP" 2>/dev/null || true
loginctl terminate-user "$BOOTSTRAP" 2>/dev/null || true
pkill -KILL -u "$BOOTSTRAP" 2>/dev/null || true
sleep 2

# Remove the home first (robust against odd filenames), then the account
rm -rf /home/"$BOOTSTRAP"
rm -f /var/mail/"$BOOTSTRAP" /var/spool/mail/"$BOOTSTRAP" 2>/dev/null || true
deluser "$BOOTSTRAP"      # Ubuntu; fallback: userdel "$BOOTSTRAP"

# Verify root-only
id "$BOOTSTRAP" 2>&1 || echo "bootstrap user gone"
awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd   # expect: empty
```

Make sure `root` has a usable password too, for physical-console / `su` break-glass (Tailscale SSH and key login don't need it, but the console does):

```bash
passwd -S root        # "root P ..." = usable password set; "L" = locked
# passwd root    # set one if it is locked/unknown
```

## Step 3.7 — Disable OpenSSH on the server

Tailscale SSH is confirmed. Shut down the OpenSSH daemon so port 22 is no longer open on the LAN:

```bash
# Kill the reverse tunnel process (no longer needed)
pkill -f "ssh .* -R 2222:localhost:22" || true

# Disable and stop sshd
systemctl disable --now ssh
systemctl disable --now ssh.socket 2>/dev/null || true

# Confirm port 22 is gone
ss -ltnp | grep ':22' || echo "No sshd listener — good"
```

## Step 3.8 — Disable Client Remote Login

On your Client, disable Remote Login in:

`System Settings -> General -> Sharing -> Remote Login -> Off`

Optional CLI status check:

```bash
sudo systemsetup -getremotelogin
# Expected: Remote Login: Off
```

Clean up the stale tunnel host key:

```bash
ssh-keygen -R '[localhost]:2222'
# Optional: remove backup file created by ssh-keygen -R
rm -f ~/.ssh/known_hosts.old
```

If this server is ever reinstalled or its host keys change, clear stale local entries before reconnecting:

```bash
ssh-keygen -R homelab 2>/dev/null || true
ssh-keygen -R 192.168.10.3 2>/dev/null || true   # replace if your LAN IP differs
ssh-keygen -R 100.100.100.100 2>/dev/null || true # replace with any old Tailscale IP
```

**Leave the physical console session active in case we need to recover.**

## Step 3.9 — Harden sshd_config

> **Note:** OpenSSH (`sshd`) is disabled as of Step 3.7 but remains installed. This hardened config is kept as an emergency reference — if Tailscale ever fails and you need to temporarily re-enable sshd from the physical console, these settings ensure it comes up securely.

In your Tailscale SSH session:

```bash
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)
nano /etc/ssh/sshd_config
```

Make sure these settings are present (uncomment / add / change as needed):

```text
# Authentication (root-only build: key-based root login, never password)
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes

# Limit who can log in
AllowUsers root

# Session
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30

# Modern crypto only
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,sntrup761x25519-sha512@openssh.com
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256

# Disable forwarding by default (temporarily enable only for break-glass local tunnels)
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no

# Limit features
PermitUserEnvironment no
PrintMotd no
```

Save and test config:

```bash
sshd -t
# No output = good
```

> ⚠️ sshd is disabled (Step 3.7) — do **not** restart it. The `sshd -t` check above confirms the config is valid. This is saved for emergency reference only. If you need a break-glass local tunnel (`ssh -L`), temporarily set `AllowTcpForwarding yes`, validate with `sshd -t`, restart sshd for the maintenance window, then restore `AllowTcpForwarding no` before disabling sshd again.

## Step 3.10 — Optional SSH config shortcut on Client

Steady-state admin path is `tailscale ssh root@homelab`.  
The `ssh homelab` shortcut below is only useful when you intentionally run OpenSSH for break-glass or temporary tunneling workflows.

On your Client:

```bash
mkdir -p ~/.ssh
nano ~/.ssh/config
```

Add the server's MagicDNS hostname:

```sshconfig
Host homelab
  HostName homelab
  User root
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

If your environment needs an explicit Tailscale transport, use `tailscale nc` proxy:

```sshconfig
Host homelab
  HostName homelab
  ProxyCommand tailscale nc %h %p
  User root
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

Save (`Ctrl+O`, `Ctrl+X`). Permissions:

```bash
chmod 600 ~/.ssh/config
```

Primary connectivity test (recommended):

```bash
tailscale ssh root@homelab
```

Optional shortcut test (only when sshd is intentionally enabled):

```bash
ssh homelab
```

## Step 3.11 — Disable physical console login (optional)

If you want, you can disable login on the physical TTYs to force SSH-only. Skip this if you might lose Client access and need physical fallback.

For now, **leave it enabled** — better fallback option.

## Step 3.12 — Root-only operator note

After Step 3.6d, this host is root-only and normal administration runs directly as `root` over Tailscale SSH. No `sudo` timeout tuning is required in steady state.

## Step 3.13 — Disconnect physical console

You should now be able to unplug:

- Monitor
- Keyboard

The server can run headless from here on. Everything is via Tailscale SSH.

## Step 3.14 — Take a baseline snapshot

Record the state of the system *before* heavy hardening, so you can compare before/after.

```bash
# From SSH:
mkdir -p ~/baseline-snapshot
cd ~/baseline-snapshot

# Installed packages
dpkg --get-selections > packages.txt

# Running services
systemctl list-unit-files --type=service --state=enabled > services-enabled.txt
systemctl list-units --type=service --state=running > services-running.txt

# Open ports
ss -tlnp > open-ports.txt
ss -ulnp >> open-ports.txt

# Sysctl values we'll change later
sysctl -a 2>/dev/null > sysctl-all.txt

# Kernel parameters
cat /proc/cmdline > cmdline.txt

# Date stamp
date > snapshot-date.txt

ls -la
```

Keep this directory — Phase 13 will diff against it for post-hardening comparison.

## Step 3.15 — Break-glass runbook: restore access if Tailscale fails

If Tailscale stops working, recover in this order.

### Path A (preferred before Phase 06): reverse tunnel via physical console

This keeps your normal posture (no LAN-exposed sshd). Use this before Phase 06. After Phase 06 is active, outbound RFC1918 egress is restricted and this path may not be reachable.

1. On the server's physical console:

```bash
systemctl enable --now ssh
systemctl status ssh --no-pager
```

Expect: active (running).

1. On your Client, temporarily enable Remote Login:

`System Settings -> General -> Sharing -> Remote Login -> On`

```bash
ipconfig getifaddr en0   # should be 192.168.3.92
```

1. On the server's physical console, create the reverse tunnel:

```bash
ssh -o StrictHostKeyChecking=accept-new \
  -fN \
  -R 2222:localhost:22 \
  you@192.168.3.92
```

(`you@192.168.3.92` is your **Client/Mac username** and LAN IP.)

1. On your Client, connect through the tunnel **as root**:

```bash
ssh root@localhost -p 2222
```

1. Recover Tailscale, then close the temporary path:

```bash
pkill -f "ssh .* -R 2222:localhost:22" || true
systemctl disable --now ssh
systemctl disable --now ssh.socket 2>/dev/null || true
ssh-keygen -R [localhost]:2222
# Optional: remove backup file created by ssh-keygen -R
rm -f ~/.ssh/known_hosts.old
```

Then disable Remote Login in:

`System Settings -> General -> Sharing -> Remote Login -> Off`

Optional CLI status check:

```bash
sudo systemsetup -getremotelogin
```

### Path B (preferred after Phase 06): temporary local LAN SSH

Use this when Path A is unavailable. After Phase 06, this is usually the practical recovery path.

1. Put your Client on Router 3 LAN (direct cable to Router 3 LAN port, or temporary Router 3 WiFi enable), so it gets `192.168.10.x`.
2. On the server physical console, start sshd:

```bash
systemctl enable --now ssh
```

1. If Phase 6 nftables is active, add a temporary allow rule for your Client's source IP:

```bash
ETH=$(ip route show default | awk '/default/ {print $5; exit}')
# Replace CLIENT_R3_IP with your Client IP on Router 3 LAN (for example 192.168.10.4)
nft add rule inet filter input iifname "$ETH" ip saddr <CLIENT_R3_IP> tcp dport 22 ct state new,established accept comment "TEMP_SSH_RECOVERY"
```

1. Connect from Client:

```bash
# Replace SERVER_R3_IP with the server IP on Router 3 LAN (for example 192.168.10.3)
ssh root@<SERVER_R3_IP>
```

1. After recovery, remove temporary access and return to Tailscale-only mode:

```bash
nft -a list chain inet filter input | grep TEMP_SSH_RECOVERY
# delete the matching handle
nft delete rule inet filter input handle <HANDLE>

systemctl disable --now ssh
systemctl disable --now ssh.socket 2>/dev/null || true
ss -ltnp | grep ':22' || echo "No sshd listener — good"
```

## Step 3.15b — Post-recovery cleanup check

After any break-glass session, confirm temporary access paths are closed again.

On the Server:

```bash
ss -ltnp | grep ':22' || echo "No sshd listener — good"
nft -a list chain inet filter input | grep TEMP_SSH_RECOVERY || echo "No temporary nft recovery rule"
tailscale serve status
# Expected on a fresh build: no serve config. If you had to use Serve/Funnel for recovery, remove that config now and confirm it's gone.
```

On your Client:

```bash
sudo systemsetup -getremotelogin
pgrep -af "ssh .* -R 2222:localhost:22" || echo "No reverse tunnel process"
```

If you temporarily re-enabled Router 3 WiFi for Path B, disable both bands again and remove that SSID from your Client preferred network list.

## Step 3.16 — Verify no internet-exposed SSH

Run these checks after setup and after major network changes:

1. On server, verify local sshd is off in normal mode:

```bash
ss -ltnp | grep ':22' || echo "No sshd listener — good"
```

1. From a LAN device (without Tailscale SSH path), test direct SSH to server LAN IP:

```bash
ssh -o ConnectTimeout=5 root@192.168.10.3
```

Expected: timeout/refused in normal mode.

1. Verify router config manually: no port-forward/NAT rule for TCP 22 to this server on Router 1/2/3.

2. Optional external check from a network outside your home (phone hotspot or VPS):

```bash
nmap -Pn -p22 <your-public-ip>
```

Expected: `closed` or `filtered`.

1. Confirm intended remote path still works:

```bash
tailscale ssh root@homelab
```

## Verification checklist

- [ ] `tailscale ssh root@homelab` from Mac connects cleanly as `root`
- [ ] (Optional) `ssh homelab` shortcut connects as `root` when OpenSSH is intentionally enabled for break-glass/tunneling
- [ ] The installer's bootstrap user is deleted: `awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd` is empty
- [ ] `passwd -S root` shows a usable password (`P`) for console/`su` break-glass
- [ ] `ss -ltnp | grep ':22'` on the server returns nothing — sshd is not listening
- [ ] macOS Settings shows `Remote Login: Off` (System Settings -> General -> Sharing)
- [ ] `sshd -t` on the server returns no errors (config is valid for emergency re-enable)
- [ ] Tailscale ACL enforces `tag:client` -> `tag:server` SSH with `users: ["root"]`, and non-client devices are denied
- [ ] `tailscale serve status` on the server shows no active Serve/Funnel config on a fresh build
- [ ] Router port-forwarding for TCP 22 is disabled (Router 1/2/3)
- [ ] Baseline snapshot directory exists in `/root/baseline-snapshot/`
- [ ] Server is running headless

## Issues encountered and solutions

- **Root login worked in Tailscale SSH but failed via `ssh homelab`:** root key was missing from `/root/.ssh/authorized_keys` even though bootstrap-user key existed. Copying and deduplicating the key solved it.
- **Unsafe temptation to remove bootstrap user too early:** deleting before validating both root access paths creates lockout risk. The fix was to enforce a two-path validation gate before deletion.
- **ACL confusion during early tests:** mixed tag state caused intermittent deny behavior. Re-applying strict `tag:client -> tag:server` plus `users: ["root"]` and waiting for propagation fixed it.

## Troubleshooting

**`tailscale ssh` says "access denied" or "access controls don't allow".** Check that the server has tag `tag:server` and the Mac has tag `tag:client` in the Tailscale admin console. Both tags must appear for the ACL `ssh` rule to match. Tags can take ~30 seconds to propagate after being set.

**Both devices show up on only one device's `tailscale status`.** They're on different tailnets. Run `tailscale logout && tailscale up` on both (use `sudo` on macOS if your install requires it), authenticate with the same account, then re-tag.

**`tailscale ssh` refuses but `tailscale status` shows both devices.** Run `tailscale debug whois <mac-tailscale-ip>` from the server to see what role/tags Tailscale sees for the Mac.

**Need emergency access if Tailscale is broken.** Follow Step 3.15. Before Phase 06, use Path A first. After Phase 06, use Path B first, then return to Tailscale-only mode.

**`Permission denied (publickey)`.** On the server, check `/root/.ssh/authorized_keys` permissions (600), `/root/.ssh` (700), and that the file contains one complete, unwrapped key line. If copied manually, compare fingerprints with `ssh-keygen -lf` on both sides.

**SSH connects but immediately disconnects.** Check `journalctl -u ssh -n 30` on the server. Common cause: typo in `sshd_config`.

## Next

If you want remote shutdown/wake before hardening the host, continue to [Phase 04: Wake-on-LAN + remote power recovery](04-wake-on-lan.md).

→ [Phase 05: Host hardening (kernel, AppArmor, auditd, AIDE)](05-host-hardening.md)
