# Homelab Architecture & Security Diagrams

Visual documentation of the network topology and security architecture.

## Diagrams

### [Network Topology](network-topology.md)

**Shows:** Hardware layout, router cascade, subnet boundaries, and host-runtime plus optional support-container organization.

- **Key insight:** Three-layer NAT isolation (ISP → R1 → R2 → R3) creates security boundaries
- **Focus:** Router 3 and the agent host as the hardened inner sanctum
- **Viewers:** System architects, security reviewers, network admins

### [Traffic Flow](traffic-flow.md)

**Shows:** Packet journey from the host-native Hermes session and the optional auxiliary-container path to the internet, with security checkpoints at each layer.

- **Key insight:** Defense-in-depth architecture with independent security controls
- **Focus:** host DNS filtering (when enabled) → egress firewall containment → optional VPN path for auxiliary workloads → optional IDS/threat-intel layers
- **Viewers:** Security engineers, incident responders, compliance reviewers

---

## Color Scheme

| Color | Meaning |
| --- | --- |
| 🟠 Orange (`#f59e0b`) | ISP/Internet-facing (untouched) |
| 🔵 Blue (`#3b82f6`) | Main LAN (trusted but not segmented) |
| 🟢 Green (`#22c55e`) | Security boundary (router 3) |
| 🟣 Purple (`#a855f7`) | Hardened compute (agent host/main runtime) |
| ⚫ Gray (`#6b7280`) | Infrastructure/support containers |
| 🔴 Red (`#ef4444`) | Firewall rules (deny) |
| 🟡 Yellow (`#eab308`) | Threat intelligence (CrowdSec) |

---

## Rendering

### Option 1: GitHub (automatic)

Push to GitHub — both `.md` files render as Mermaid diagrams automatically in pull requests and README.

### Option 2: Local export to SVG

```bash
# Install mermaid-cli (one-time)
npm install -g @mermaid-js/mermaid-cli

# Render both diagrams
mmdc -i diagrams/network-topology.md -o diagrams/network-topology.svg
mmdc -i diagrams/traffic-flow.md -o diagrams/traffic-flow.svg
```

### Option 3: View in VS Code

Install [Markdown Preview Mermaid Support](https://marketplace.visualstudio.com/items?itemName=bierner.markdown-mermaid) extension.

---

## Accessibility Notes

- ✅ Each node has text labels (not emoji-only)
- ✅ Flow direction is explicit (TB/LR annotations)
- ✅ Color is supplementary (not the only differentiator)
- ✅ Descriptions and tables provide alt-text equivalent context

---

## Maintaining These Diagrams

When updating:

1. Keep emojis for quick scanning — but label everything explicitly
2. Update `docs/` references when topology changes
3. Run render checks individually: `mmdc -i diagrams/network-topology.md -o diagrams/network-topology.svg` and `mmdc -i diagrams/traffic-flow.md -o diagrams/traffic-flow.svg`
4. Review both `.md` source and rendered output
5. Commit both — markdown for version control, SVG for visual review in diffs

---

## Related Documentation

- **Architecture rationale:** See [docs/00-threat-model.md](../docs/00-threat-model.md)
- **Router 3 setup:** See [docs/01-network-router3.md](../docs/01-network-router3.md)
- **Agent host hardening:** See [docs/05-host-hardening.md](../docs/05-host-hardening.md)
- **Security stack:** See docs 05–13 for the core and optional branches
