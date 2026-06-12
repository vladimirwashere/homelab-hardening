# Phase 04 — Wake-on-LAN + Remote Power Recovery

> **Time required:** ~30 minutes

## Why this phase

This phase closes the loop on remote power management: shut the host down over SSH, wake it back up without touching the machine, and keep the BIOS and Linux settings aligned so WoL survives reboots. It assumes the earlier phases are already in place: Router 3 isolation, plain ext4 for unattended recovery, and Tailscale SSH for admin.

This phase is optional and can be done as soon as Phases 1–3 are complete. It does not depend on Phases 5–13.

Important: WoL wakes the machine from a powered-off state only if the motherboard, NIC, BIOS, and Linux driver all agree. It does not replace an out-of-band console. For encrypted root, you still need a real remote-unlock path; for plain ext4, WoL plus Tailscale is enough for normal recovery.

## What we're building

- BIOS power settings that allow NIC wake and preserve standby power
- Linux WoL persistence on the real Ethernet interface
- A clean shutdown command over Tailscale SSH
- A wake test from the same LAN
- A remote wake test through an always-on relay on the `192.168.10.0/24` subnet
- A fallback using `Restore AC Power Loss = Last State` if you want the host to stay offline after an outage, or `Power On` if you want automatic boot after any outage

## Prerequisites

- Phases 1–3 complete
- BIOS already updated with:
  - `ErP Ready = Disabled`
  - `Power On By PCI-E/PCI = Enabled`
  - `Restore AC Power Loss = Last State` (recommended if you may want the host offline sometimes)
  - or `Power On` if you want the machine to boot automatically after any outage
- The server is booted and reachable over Tailscale SSH
- You know which NIC is the real uplink
- You have a device on the `192.168.10.0/24` LAN that can act as a WoL relay, or you are willing to use a smart plug as the fallback recovery path

## Dependency and optionality

- This entire phase is optional.
- Required before this phase: Phases 01-03.
- Downstream dependency: only Phase 13 recovery Path C depends on this work.
- Optional within this phase: Step 4.6 relay setup is only needed for off-site wake. Local-only wake testing can stop after Step 4.5.

Sanitization note: the examples below use the placeholder MAC `aa:bb:cc:dd:ee:ff`. Replace it with your real NIC MAC locally before you run the commands. Do not publish your live MAC address in the repo.

## Step 4.1 — Confirm the active NIC

The interface with the default route is the one that matters. From the server:

```bash
ip -br link
ip route
```

Expected shape:

```text
enp6s0           UP             aa:bb:cc:dd:ee:ff <BROADCAST,MULTICAST,UP,LOWER_UP>
default via 192.168.10.1 dev enp6s0 proto dhcp src 192.168.10.3 metric 100
```

If one interface is `DOWN` or has `NO-CARRIER`, ignore it for WoL. Use the interface that is actually connected.

## Step 4.2 — Check WoL support

Run:

```bash
ethtool enp6s0 | grep -i 'Wake-on\|Supports Wake-on'
```

Expected output:

```text
Supports Wake-on: pumbg
Wake-on: g
```

If `Wake-on` is `d`, enable it for the current boot:

```bash
ethtool -s enp6s0 wol g
ethtool enp6s0 | grep -i 'Wake-on\|Supports Wake-on'
```

Expected after enabling:

```text
Wake-on: g
```

If `Supports Wake-on` does not include `g`, stop here and fix BIOS or the NIC driver path first. This board/NIC combination should support magic-packet WoL.

## Step 4.3 — Make WoL persistent

For this repo, the cleanest persistence path is Netplan. Inspect your current file first:

```bash
ls /etc/netplan
sed -n '1,200p' /etc/netplan/*.yaml
```

Look for the Ethernet entry that owns `enp6s0`. It should be a DHCP-enabled interface, often matched by MAC.

Example:

```yaml
network:
  version: 2
  ethernets:
    lan0:
      match:
        macaddress: aa:bb:cc:dd:ee:ff
      dhcp4: true
      wakeonlan: true
```

Apply it:

```bash
netplan try
netplan apply
```

Recheck:

```bash
ethtool enp6s0 | grep -i 'Wake-on\|Supports Wake-on'
```

Expected:

```text
Wake-on: g
```

If Netplan does not preserve the setting on your install, use a `.link` file instead:

```bash
tee /etc/systemd/network/10-wol.link >/dev/null <<'EOF'
[Match]
MACAddress=aa:bb:cc:dd:ee:ff

[Link]
WakeOnLan=magic
EOF

udevadm control --reload
ip link set enp6s0 down
udevadm trigger --verbose --settle --action add /sys/class/net/enp6s0
```

## Step 4.4 — Record the MAC address

Run:

```bash
ip link show enp6s0
```

Expected line:

```text
link/ether aa:bb:cc:dd:ee:ff brd ff:ff:ff:ff:ff:ff
```

Write that MAC address down exactly. WoL targets the MAC, not the IP.

## Step 4.5 — Verify local wake before remote wake

Use another machine on the same `192.168.10.0/24` LAN to send the magic packet.

If your only client is a MacBook, note this first: a Mac on your normal main-LAN Wi-Fi cannot send a direct WoL packet through Router 3 NAT. For this same-LAN test, temporarily connect the MacBook to a Router 3 LAN port with Ethernet so it gets a `192.168.10.x` address, or skip to the relay method in Step 4.6.

If that machine is Linux:

```bash
sudo apt install -y wakeonlan
wakeonlan aa:bb:cc:dd:ee:ff
```

Or:

```bash
wol -i 192.168.10.255 -p 9 aa:bb:cc:dd:ee:ff
```

If that machine is macOS:

```bash
brew install wakeonlan
wakeonlan aa:bb:cc:dd:ee:ff
```

If you do not want to install a package on macOS, use the built-in Python 3 path:

```bash
python3 - <<'PY'
import socket

mac = "aa:bb:cc:dd:ee:ff".replace(":", "")
packet = bytes.fromhex("FF" * 6 + mac * 16)

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
  sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
  sock.sendto(packet, ("192.168.10.255", 9))

print("Magic packet sent")
PY
```

Now shut the server down cleanly from SSH:

```bash
systemctl poweroff
```

Expected shutdown behavior:

- the SSH session ends cleanly
- the host disappears from `tailscale status`
- the NIC link light usually stays on if standby power is present

Send the WoL packet from the other LAN machine and wait up to 2 minutes.

Expected recovery:

- the server powers on
- `tailscale ssh root@homelab` works again once booted

## Step 4.6 — Set up a remote WoL relay

To wake the server from anywhere, you need a device that is always on and is physically inside the same `192.168.10.0/24` network as the server. The relay can be a Raspberry Pi, another Linux box, or a small always-on mini PC.

On the relay:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
sudo apt install -y wakeonlan
```

Create a wake script:

```bash
cat > ~/wake-homelab.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
wakeonlan aa:bb:cc:dd:ee:ff
EOF
chmod +x ~/wake-homelab.sh
```

From your Client, confirm you can reach the relay through Tailscale and run the script:

```bash
tailscale ssh <relay-user>@<relay-host> ~/wake-homelab.sh
```

Expected result:

- no output, or a small confirmation from `wakeonlan`
- the server boots within about 30 to 120 seconds

Once the server is back, reconnect:

```bash
tailscale ssh root@homelab
```

## Step 4.7 — Test outage recovery separately

Because you set `Restore AC Power Loss = Last State`, the host should return to its previous power state after AC comes back.

Use this rule:

- if the server was off before the outage, it stays off after power returns
- if the server was on before the outage, it powers back on after AC returns

If you later decide you want automatic boot after any outage, switch that BIOS setting to `Power On` instead.

## Step 4.8 — Troubleshooting

**`Supports Wake-on` does not include `g`.**

- The NIC or driver path is wrong, or the BIOS is still cutting standby power.
- Recheck `ErP Ready`, `Power On By PCI-E/PCI`, and the cable/link light.

**`Wake-on` keeps reverting to `d`.**

- Netplan or the `.link` file is not matching the active interface.
- Match by MAC, not by name-only, when possible.

**The machine only wakes from sleep, not from shutdown.**

- That usually means BIOS only supports S3/S4 wake, or ErP is still interfering.
- Keep testing from a full `systemctl poweroff` state, not suspend.

**Remote wake does nothing, but local wake works.**

- The relay is not actually on the same `192.168.10.0/24` network.
- The relay is not always on.
- The packet is not being sent to the server's MAC.

**The server powers on after a power cut when you did not want it to.**

- Change `Restore AC Power Loss` from `Power On` to `Last State`.

## Verification checklist

- [ ] BIOS WoL settings are enabled and ErP is disabled
- [ ] `ethtool enp6s0` reports `Supports Wake-on: pumbg`
- [ ] `ethtool enp6s0` reports `Wake-on: g`
- [ ] WoL survives reboot
- [ ] `systemctl poweroff` cleanly shuts the server down over SSH
- [ ] A local LAN machine can wake the server with a magic packet
- [ ] A remote relay on Tailscale can wake the server from anywhere
- [ ] `tailscale ssh root@homelab` works again after wake

## Next

→ Return to [Phase 13: audit, maintenance, and recovery](13-audit-maintenance.md) when you want to document the final recovery posture and keep this runbook aligned with the rest of the stack.
