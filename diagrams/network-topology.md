# Network topology diagram

Mermaid source — renderable in GitHub directly, or export to SVG via mermaid-cli.

```mermaid
flowchart TB
    INET([🌐 Internet])
    
    R1["🛰️ Router 1<br/>DIGI HG8143A5<br/>192.168.100.1<br/>—<br/><i>untouched</i>"]
    
    R2["📡 Router 2<br/>Huawei WS7206<br/>192.168.3.1<br/>—<br/><i>main LAN + WiFi</i>"]
    
    R3["🔒 Router 3<br/>Huawei WS7100<br/>192.168.10.1<br/>—<br/><i>ROUTER mode, isolated</i>"]
    
    subgraph DEVICES["Main LAN Devices"]
        M(["💻 Mac<br/>192.168.3.92"])
        T(["🌡️ Thermostat<br/>192.168.3.x"])
        P(["📱 Phones<br/>192.168.3.x"])
    end
    
    PC["🖥️ Hermes Host<br/>Ubuntu Server 26.04<br/>192.168.10.x<br/>—<br/>Secure Boot • nftables<br/>AppArmor • auditd • AIDE<br/>(LUKS optional path)"]

    subgraph HOST["Host Runtime"]
        HERMES["🧠 Hermes Agent<br/><i>host-native under root-only model</i>"]
        TS["🔑 Tailscale SSH<br/><i>admin + tailnet-only reachability</i>"]
        ADG["🛡️ AdGuard Home<br/><i>host DNS sinkhole</i>"]
        MON["👁️ CrowdSec + Suricata<br/><i>Suricata optional in performance-first builds</i>"]
    end

    subgraph OPTIONAL["Optional Support Containers"]
        VPN["🔐 Gluetun (NordVPN)<br/><i>auxiliary workload egress</i>"]
        OLA["🧠 Ollama or model service<br/><i>GPU workloads</i>"]
        SB["📦 Podman sandboxes / apps<br/><i>support tooling, not the main runtime</i>"]
    end
    
    INET <--> |WAN| R1
    R1 <--> |cascaded NAT| R2
    R2 <--> |bridged| DEVICES
    R2 --> |segmented| R3
    R3 <--> |LAN| PC
    M -.-> |Tailscale SSH| TS
    PC --> HOST
    PC -. optional .-> OPTIONAL
    
    style INET fill:#fff4e6,stroke:#f59e0b,stroke-width:2px
    style R1 fill:#fff4e6,stroke:#f59e0b,stroke-width:2px
    style R2 fill:#dbeafe,stroke:#3b82f6,stroke-width:2px
    style R3 fill:#dcfce7,stroke:#22c55e,stroke-width:3px
    style DEVICES fill:#e0e7ff,stroke:#6366f1,stroke-width:2px
    style PC fill:#fae8ff,stroke:#a855f7,stroke-width:3px
    style HOST fill:#f3f4f6,stroke:#6b7280,stroke-width:2px
    style OPTIONAL fill:#f3f4f6,stroke:#6b7280,stroke-width:2px
    style HERMES fill:#fae8ff,stroke:#a855f7,stroke-width:1px
    style TS fill:#dbeafe,stroke:#3b82f6,stroke-width:1px
    style ADG fill:#dcfce7,stroke:#22c55e,stroke-width:1px
    style MON fill:#fff4e6,stroke:#f59e0b,stroke-width:1px
    style VPN fill:#dbeafe,stroke:#3b82f6,stroke-width:1px
    style OLA fill:#fef3c7,stroke:#eab308,stroke-width:1px
    style SB fill:#e5e7eb,stroke:#6b7280,stroke-width:1px
```

## How to render

GitHub renders this automatically. For other use:

```bash
# Install mermaid-cli
npm install -g @mermaid-js/mermaid-cli

# Render
mmdc -i network-topology.md -o network-topology.svg
```

## What this diagram shows

- The cascade of NAT routers (R1 → R2 → R3) creating isolation through subnet boundaries
- Router 3 highlighted in green as the security boundary
- The agent host as the main runtime, with optional support containers shown separately
- Tailscale SSH as the operator-admin path and the tailnet-only reachability surface
- Main LAN devices (phones, thermostat, Mac) physically cannot reach the host except through the intended Tailscale/admin path and established outbound flows
