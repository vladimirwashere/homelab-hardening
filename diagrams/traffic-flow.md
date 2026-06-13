# Traffic flow diagram

Shows the two relevant paths now: the host-native Hermes main session, and the optional auxiliary-container path through Gluetun.

```mermaid
flowchart LR
    MAIN["🧠 Hermes main session<br/>host-native"]
    AUX["📦 Auxiliary containers<br/>optional"]

    subgraph STACK["Always-On Controls"]
        direction TB
        ADG["🛡️ AdGuard Home<br/>host DNS sinkhole"]
        TS["🔑 Tailscale / tailscale0<br/><i>admin + tailnet-only reachability</i>"]
        NFT["🔥 nftables<br/>egress firewall<br/><i>deny RFC1918<br/>except gateway</i>"]
        SUR["👁️ Suricata<br/><i>optional visibility layer</i>"]
        CS["🚫 CrowdSec<br/>threat intelligence<br/><i>block bad IPs</i>"]
    end

    subgraph OPTIONAL["Optional Auxiliary Path"]
        direction TB
        GDNS["🧭 Gluetun DNS<br/><i>inside VPN namespace</i>"]
        VPN["🔐 Gluetun<br/><i>auxiliary egress + kill switch</i>"]
    end
    
    subgraph ROUTERS["Router Cascade"]
        direction TB
        R3["🔒 Router 3<br/>192.168.10.1<br/>—<br/>first NAT"]
        R2["📡 Router 2<br/>192.168.3.1<br/>—<br/>second NAT"]
        R1["🛰️ Router 1<br/>192.168.100.1<br/>—<br/>third NAT"]
    end
    
    INET([🌐 Internet])
    
    MAIN -->|DNS + normal host egress| ADG
    ADG --> NFT
    AUX -->|optional DNS + payload| GDNS
    GDNS --> VPN
    VPN --> NFT
    TS -.->|tailnet-only inbound| MAIN
    NFT -->|inspected| SUR
    SUR -.->|observes| CS
    NFT -->|tunneled| R3
    R3 -->|bridged| R2
    R2 -->|cascaded| R1
    R1 -->|to public| INET
    
    style MAIN fill:#fae8ff,stroke:#a855f7,stroke-width:2px
    style AUX fill:#e5e7eb,stroke:#6b7280,stroke-width:2px
    style STACK fill:#f9fafb,stroke:#6b7280,stroke-width:2px
    style ADG fill:#dcfce7,stroke:#22c55e,stroke-width:2px
    style TS fill:#dbeafe,stroke:#3b82f6,stroke-width:2px
    style OPTIONAL fill:#f9fafb,stroke:#6b7280,stroke-width:2px
    style GDNS fill:#dcfce7,stroke:#22c55e,stroke-width:2px
    style VPN fill:#dbeafe,stroke:#3b82f6,stroke-width:2px
    style NFT fill:#fee2e2,stroke:#ef4444,stroke-width:2px
    style SUR fill:#fff4e6,stroke:#f59e0b,stroke-width:2px
    style CS fill:#fef3c7,stroke:#eab308,stroke-width:2px
    style ROUTERS fill:#f3f4f6,stroke:#6b7280,stroke-width:2px
    style R3 fill:#dcfce7,stroke:#22c55e,stroke-width:2px
    style R2 fill:#dbeafe,stroke:#3b82f6,stroke-width:2px
    style R1 fill:#fff4e6,stroke:#f59e0b,stroke-width:2px
    style INET fill:#fff4e6,stroke:#f59e0b,stroke-width:2px
```

## Defense-in-depth checkpoints

| # | Checkpoint | What it stops | What it doesn't stop |
| --- | --- | --- | --- |
| 1 | **AdGuard Home** | Known malicious, phishing, and unwanted domains at the host resolver | Direct IP connections; brand-new malicious domains |
| 2 | **Optional Gluetun path** | Home-IP exposure and ISP visibility for selected auxiliary workloads | The host-native main session unless you intentionally route it elsewhere |
| 3 | **nftables** | Outbound RFC1918 lateral movement and unwanted physical-LAN inbound | Connections to public Internet |
| 4 | **Tailscale** | Gives a controlled tailnet-only admin and service surface | Public exposure if you deliberately publish beyond the tailnet |
| 5 | **Suricata IDS** | (alerts only) Known exploit/C2/scan patterns when enabled | Zero-day signatures; anything you disable for performance |
| 6 | **CrowdSec** | Inbound from community-flagged bad IPs | First-time-seen attackers; targeted attacks |
| 7 | **Router 3 NAT** | Unsolicited inbound from the main LAN | Outbound from the agent host |

Each layer is independent — bypassing one doesn't bypass the others.

> The main Hermes session normally uses the host network and the host resolver. It does not automatically inherit the Gluetun path.
