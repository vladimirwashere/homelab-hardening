# Phase 01 — Network: Dedicate Router 3 to the Autonomous Agent Host

> **Time required:** ~30 minutes

## Why this phase

The whole isolation strategy starts with a network boundary between the autonomous agent host and the rest of the home LAN. Router 3 in router mode with its own subnet provides:

- A separate broadcast domain — devices on `192.168.3.x` can't see `192.168.10.x`
- NAT — blocks unsolicited inbound from main LAN to PC
- A clean foundation for everything else (firewall rules, monitoring) to layer on top of

Even before we touch the host, this single change reduces the attack surface for a bad agent decision or a host compromise dramatically. NAT alone does not stop *outbound* attacks from the host — that is why later phases add nftables and monitoring — but it cleanly handles half the problem at zero cost.

Important limit: on current stock Huawei hardware, Router 3 cannot independently block this one client from reaching upstream RFC1918 space while still allowing normal Internet access. Treat this phase as topology separation and exposure hygiene, not as a full off-host egress firewall.

## What we're building

```text
BEFORE                            AFTER
─────                            ─────
Router 1 (ISP)                    Router 1 (ISP)
   │                                 │
Router 2 ─── WiFi clients          Router 2 ─── WiFi clients
   │                                 │
Router 3 ─── extends WiFi          Router 3 (router mode, NO WiFi)
                                     │
                                  agent host (192.168.10.x)
```

Router 3 changes from "mesh node extending Router 2's WiFi" to "isolated router with its own subnet, serving exactly one wired compute host."

That gives you a separate subnet and inbound shielding. Phase 06 is still where outbound RFC1918 attempts get blocked and logged.

## Prerequisites

- Client connected to your current WiFi (Router 2)
- Working internet
- Router 3 (Huawei WS7100) physically accessible
- Pen + paper or password manager open for noting credentials
- Existing Ethernet cable from Router 2 Port 4 to Router 3 WAN port (you'll temporarily disconnect this)

## Dependency and optionality

- Required before this phase: Phase 00 threat model review.
- Required after this phase: this network boundary is the foundation for every later phase.
- Optional steps in this phase: Step 1.11b cleanup is quality-of-life only and has no downstream dependency.

## Pre-flight: confirm current state

**On Mac:**

```bash
ipconfig getifaddr en0
ping -c 3 1.1.1.1
```

**Expected:** IP in `192.168.3.x` range, internet connectivity working (no packet loss).

## Step 1.1 — Read Router 3's label

Pick up Router 3 (Huawei WS7100). On its bottom/back, note:

- Default WiFi SSID (e.g., `HUAWEI-XXXX-2.4G` and `HUAWEI-XXXX-5G`)
- Default WiFi password
- Default web admin password (if printed)
- Reset button location (small pinhole)

## Step 1.2 — Disconnect Router 3 from Router 2

Unplug the Ethernet cable between **Router 3 Port 1 (WAN)** and **Router 2 Port 4**. Router 3 stays powered on.

This isolates Router 3 from the rest of the network while we change its config — prevents conflicts (both routers default to `192.168.3.1`).

## Step 1.3 — Factory reset Router 3

Insert a paperclip into the reset pinhole, **hold for ~10 seconds** until lights start blinking or change color. Release.

Wait **90 seconds** for the router to fully reboot. Don't rush this.

## Step 1.4 — Connect Client to Router 3's default WiFi

From your Client's WiFi network list, select the default SSID you noted in 1.1. Use the WiFi password from the label.

> Use the 2.4 GHz network if available — better range, more reliable for setup work.

**Verify:**

```bash
ipconfig getifaddr en0
```

**Expected:** IP in `192.168.3.x` range, e.g., `192.168.3.102`.

## Step 1.5 — Open Router 3's admin page

In your browser, go to:

```text
http://192.168.3.1
```

A router first-time-setup page should load. If you get an error, wait another 30 seconds and retry.

## Step 1.6 — Initial setup wizard

The wizard will prompt for:

- **Connection type:** select **DHCP**
- **Admin password:** create a strong, unique password (store in password manager)
- **WiFi:** the wizard typically forces you to set this. Enter a temporary name/password (we're disabling WiFi shortly anyway). Example: `tempwifi-r3` / `Temp!2025Pass`.

Complete the wizard.

## Step 1.7 — Verify router mode

Navigate to `More functions → System settings → Operating mode` (paths vary by firmware version). Confirm mode is **Router** (not Bridge/AP/Repeater).

> If you can't find this setting, that's fine — WS7100 defaults to Router mode after reset. Move on.

## Step 1.8 — Change LAN subnet to 192.168.10.0/24

**Most important step in the phase.** Navigate to `LAN settings` (might be under My Wi-Fi → LAN or Settings → Network → LAN).

Change:

| Setting | Value |
| --- | --- |
| Router IP address | `192.168.10.1` |
| Subnet mask | `255.255.255.0` |
| DHCP server | Enabled |
| Start IP | `192.168.10.100` |
| End IP | `192.168.10.200` |
| Lease time | Default (24h) |

Save. Router will reboot. Wait 60 seconds, then reconnect to its WiFi.

```bash
ipconfig getifaddr en0
```

**Expected:** `192.168.10.x` (not `.3.x` anymore).

Open `http://192.168.10.1` — admin page loads.

## Step 1.8b — Apply Router 3 exposure hygiene

While you are still logged into Router 3's admin UI, disable or clear anything that would accidentally expose the host beyond the intended topology:

- **UPnP:** disabled
- **DMZ host:** empty / disabled
- **Virtual server / port forwarding:** no rules
- **Remote administration from WAN:** disabled if the firmware exposes it

This does **not** solve the outbound RFC1918 problem. It just removes the common consumer-router shortcuts that would punch holes back in from the other direction.

## Step 1.9 — Disable Router 3's WiFi

Navigate to `Wi-Fi settings`. **Disable both 2.4 GHz and 5 GHz networks.** Save.

> Your Mac will lose its WiFi connection here. Expected.

## Step 1.10 — Reconnect Router 3 to Router 2

Plug the Ethernet cable back:

- Router 3 WAN port (Port 1) → Router 2 Port 4

Wait ~90 seconds.

## Step 1.11 — Reconnect Mac to Router 2's WiFi

From your Mac's WiFi menu, reconnect to your normal home WiFi.

```bash
ipconfig getifaddr en0
ping -c 3 1.1.1.1
```

**Expected:** `192.168.3.x`, pings succeed.

## Step 1.11b — Optional: cleanup temporary Router 3 WiFi entries on Client

Remove the temporary Router 3 SSIDs from your Mac's preferred list so it does not auto-join them later if Router 3 WiFi is ever briefly re-enabled for recovery.

```bash
networksetup -listpreferredwirelessnetworks en0
sudo networksetup -removepreferredwirelessnetwork en0 tempwifi-r3 2>/dev/null || true

# Optional: also remove the factory SSIDs if you joined them during setup
sudo networksetup -removepreferredwirelessnetwork en0 HUAWEI-XXXX-2.4G 2>/dev/null || true
sudo networksetup -removepreferredwirelessnetwork en0 HUAWEI-XXXX-5G 2>/dev/null || true
```

## Step 1.12 — Isolation test

```bash
ping -c 3 192.168.10.1
```

**Expected:** all 3 packets time out. "Request timeout" or "100% packet loss."

This is the crucial verification — the admin machine on the main LAN cannot reach Router 3's subnet. Router 3's NAT blocks unsolicited inbound.

## Step 1.13 — Connect the PC

Plug Ethernet:

- Router 3 LAN port (Port 2, 3, or 4 — **not** Port 1) → PC Ethernet port

If the PC has any OS installed, boot it and check connectivity. If not, leave unpowered — Phase 2 handles the install.

## Step 1.14 — Document final state

Add to your private notes (NOT in this repo):

```text
Router 3 (Huawei WS7100)
  Mode: Router
  Admin IP: 192.168.10.1
  Admin password: [strong password, store in password manager]
  WAN: DHCP from Router 2 (gets 192.168.3.x address)
  LAN: 192.168.10.0/24
  DHCP range: 192.168.10.100 – 192.168.10.200
  WiFi: Disabled
  Connected to Router 2 Port 4 via WAN cable
  PC connected to Router 3 LAN port via Ethernet cable
```

## Verification checklist

Run through these before marking phase complete:

- [ ] Mac on Router 2 WiFi cannot ping `192.168.10.1` (Router 3 admin IP) — confirms isolation
- [ ] Router 3 admin is not reachable from the main LAN. Future admin requires a direct LAN cable to Router 3, or a browser on the host itself.
- [ ] UPnP is off, DMZ is off, and no port-forward / virtual-server rules exist on Router 3.
- [ ] WiFi on Router 3 confirmed disabled (no SSID visible)
- [ ] PC (if powered) has IP in `192.168.10.x` range and can ping
- [ ] PC can `ping 1.1.1.1` (internet works through the cascade)

## Troubleshooting

**Router 3 admin page won't load after factory reset.**
Wait longer — router firmware can take time to boot. If after 3 minutes still no luck, the reset may not have completed; try holding the button 15 seconds.

**Mac doesn't get a `192.168.10.x` address after step 1.8.**
Forget the WiFi network on your Mac (System Settings → Wi-Fi → Details → Forget) and reconnect. DHCP lease may be cached. If that doesn't work, double-check you changed the LAN subnet on Router 3 (not just the WiFi SSID/password). If you accidentally set Router 3 to Bridge mode, it won't have a LAN IP at all — factory reset and try again.

**Internet stops working from Mac on Router 2 WiFi after this phase.**
Should not happen — Router 2 is untouched. Check the cable to Router 1 hasn't been bumped.

**Mac CAN ping `192.168.10.1` from main WiFi.**
Router 3 might still be in AP/bridge mode. Re-verify step 1.7. If in router mode but ping still succeeds, there may be a route or static binding — start over from 1.3 (factory reset).

## Next

→ [Phase 02: BIOS settings + Ubuntu install](02-bios-and-os-install.md)
