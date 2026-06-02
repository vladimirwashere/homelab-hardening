# Phase 00 — Threat Model & Scope

## What this stack protects

A Linux server (the "Server") running Hermes Agent as a trusted local development and operations session on a home network. Hermes is expected to:

- Call cloud LLM APIs (Anthropic, OpenAI, etc.)
- Run self-hosted models locally (Ollama, vLLM)
- Install packages, libraries, CLIs, browsers, and developer tooling
- Execute arbitrary code (Python, shell, Node.js, etc.)
- Browse the web and drive browser automation
- Maintain projects on GitHub and on the local filesystem
- Run shell commands and administer much of the Server itself
- Deploy tailnet-only services on the Server
- Delegate work to optional containerized or remote sandboxes

The same machine is also used for development work and operator-driven admin tasks. It is not a media server, file server, or general household services box. It is a single-node compute host for one trusted operator and one highly capable autonomous assistant.

The key design choice is explicit: the main Hermes session is treated as a trusted coworker on the host. If you give it full root-equivalent control or unrestricted package-manager access, you are intentionally accepting operator-level local power. This guide does not pretend otherwise. The main security goal is steady-state containment and visibility: keep the box off the rest of the home LAN during normal operation, log attempted upstream-RFC1918 access, and make recovery straightforward if the host itself is lost.

## Dependency and optionality map

- Core containment path is: Phase 01 -> 02 -> 03 -> 05 -> 06 -> 11 -> 12 -> 13.
- Optional Phase 04 (Wake-on-LAN) can be inserted any time after Phase 03 and is revisited in Phase 13 recovery Path C.
- Optional container branch starts at Phase 07 and gates Phases 08-10 as documented.
- Recommended DNS filtering branch is Phase 08 (which depends on Phase 07 in this repo's containerized setup).
- Optional VPN branch is Phase 09 (depends on 08) and only affects auxiliary container workloads.
- Optional visibility branch is Phase 10 (depends on 08, not 09) and can be skipped for performance-first.
- Optional encrypted-root branch starts in Phase 02 section C.7 and changes recovery requirements in Phase 13 Path B.

## Threat actors (in order of priority)

1. **Hermes or its delegated work makes a bad decision.** Most likely threat. Prompt injection, malicious data, unsafe tools, or simple bad judgment could cause the trusted agent to install malicious software, delete data, attempt reconnaissance, or try to expose a service. Mitigation is not "hide the host from the main agent"; it is to harden the host, keep steady-state RFC1918 egress blocked, keep the admin path narrow, and make suspicious network behavior visible.
2. **Drive-by malware or hostile packages on the host.** Less likely but still real: a package, browser exploit, dev dependency, or script compromises the box. Mitigation is minimal exposure, host hardening, DNS filtering, monitoring, and treating host compromise as a recoverable event.
3. **An attacker who compromises a network-facing service on the host.** This could be Tailscale-reachable software, a locally deployed dashboard, or an intentionally published app. Mitigation is to keep the admin path Tailscale-only, default to tailnet-only services, review public publishing separately, and keep the host patched.
4. **Lateral movement from another device on the home LAN.** Less likely, but the Hermes host should not make this easier. Mitigation is Router 3 isolation plus host nftables rules that deny and log outbound RFC1918 destinations, so the Server stays off upstream LAN space during normal operation.
5. **A fully compromised trusted local admin/root session.** This is the hard limit of the design. With current hardware, there is no separate enforcement plane that survives this. Mitigation is mostly operational: logs, backups, rebuildability, and honest documentation of what the routers cannot do.

## Out-of-scope threats

- **Nation-state actors.** This stack is designed for commodity malware, bad automation decisions, prompt-injected tools, and casual attackers, not sophisticated state or bespoke offensive capability.
- **Strong local containment from the main Hermes session.** If you want the main agent to behave like a fully trusted local developer with broad system power, you do not also get strong guarantees that it cannot modify its own host. This guide does not promise that.
- **Independent enforcement after trusted local compromise.** Hermes runs as `root` on this build, so it can change host policy directly. This stack does not claim otherwise.
- **Physical compromise.** Someone with hands-on access can attack the hardware, the boot chain, or the running system. Physical security is separate.
- **Zero-day Linux kernel exploits.** Patching cadence helps, but there is no software-only answer if an unpatched kernel 0-day gets weaponized first.

## Assumptions

- The ISP gateway (Router 1) is not actively performing MITM. Standard home-internet trust model.
- The main router (Router 2) is trusted for connectivity, not for fine-grained security enforcement.
- Current stock Huawei HG8143A5, WS7206, and WS7100 hardware can provide subnet separation, NAT, disabled UPnP/DMZ/port-forward hygiene, and some coarse client controls, but not per-client outbound ACLs or targeted RFC1918 destination blocking for the Hermes host.
- This is a root-only box: Hermes runs directly as `root`, the single trusted operator account. There is no sudo boundary to cross and no separate admin user.
- Running the agent as `root` is an intentional operator-level trust decision for a single-operator box, not a bug.
- Docker daemon access, if you intentionally enable it, is also root-equivalent and inside the same trust boundary.
- Tailscale ACLs, auth keys, Serve/Funnel settings, and public publishing decisions should stay under human operator control even though `root` can still alter local Tailscale state.
- Tailnet-only services are an acceptable risk for this box. Public publishing requires a separate operator-reviewed workflow.
- If the optional VPN path is used, it applies to auxiliary workloads, not to the host-native main Hermes session unless you intentionally change that.

## Trade-offs accepted

| Choice | Trade-off |
| --- | --- |
| Host-native agent running directly as `root` | Maximum autonomy on one box, but no strong local containment from the main agent. Acceptable because the goal is a trusted coworker, not a hostile tenant. |
| Host firewall on the same protected machine | Best available with current hardware, but not independent from full host compromise. Keep it anyway because it blocks ordinary mistakes and produces high-signal logs. |
| Router 3 plus exposure hygiene instead of a real firewall appliance | Cheap and practical, but cannot do per-client outbound RFC1918 ACLs. |
| Denylist DNS filtering (not full allowlist) | Easier to maintain, but a malicious destination can still slip through if no list catches it yet. Layered monitoring compensates. |
| Tailnet-only autonomous services | More reachable surface than localhost-only, but still not exposed to the physical LAN or public Internet by default. |
| Containers as optional support tooling, not the main runtime | Simpler and more honest for the trusted main agent, but less local isolation for that primary workflow. |
| Plain ext4 (no encryption) | No at-rest protection if hardware is stolen. Unattended reboot recovery and immediate SSH access after boot. Default configuration. Optional LUKS+LVM branch available if encrypted root is required. |
| Software RAID / no RAID | If a disk dies, restore from backup. Acceptable for a non-critical lab workstation. |

## In-scope controls

- Router 3 dedicated subnet and NAT
- Router 3 exposure hygiene: Wi-Fi off, UPnP off, no DMZ, no accidental virtual-server rules
- Host nftables rules that deny and log outbound RFC1918 ranges except the gateway
- Automated Telegram alerts plus manual follow-up for `[nft-deny-rfc1918]` events (Phase 06)
- Tailscale-only admin path with SSH and ACL restrictions
- Host kernel hardening (sysctl, kernel cmdline, AppArmor)
- Disk encryption (LUKS) or a documented continuity exception
- DNS-level filtering (AdGuard Home + blocklists)
- Host IDS + community IP blocklist (CrowdSec)
- Network IDS (Suricata + ET Open) for the visibility-first profile
- File integrity monitoring (AIDE)
- Privileged-action auditing (auditd)
- Optional auxiliary containers and sandboxes (Podman, and Docker if you intentionally accept that trust trade)
- Optional VPN egress for auxiliary workloads
- Patching cadence (unattended-upgrades, daily security)
- Recovery and cleanup runbooks for obsolete artifacts, alert follow-up, and continuity decisions

## Out-of-scope controls (and why)

- **Independent hardware firewall:** better separation, but additional hardware and operational cost, which this repo explicitly avoids.
- **Separate management network:** overkill for a single host.
- **Preventing Hermes from changing most local dev state:** contrary to the purpose of this build.
- **External SIEM / log aggregation:** all logs stay on the host; acceptable for this threat level.
- **Public service publishing by default:** too much exposure for the baseline. Keep it as an explicit later branch.
- **Hardware security module / YubiKey:** can be added later, but not required for the baseline.
- **Commercial HIPS / EDR:** expensive and unnecessary for the current scope.
- **Network deception / honeypots:** interesting, but not the priority before the main preventive controls are solid.

## What "good enough" looks like

After completing the baseline phases (plus any optional branches you chose):

- Hermes can install packages, libraries, applications, CLIs, and developer tooling, run code, browse the web, maintain repos, and use local models on the Server.
- In normal steady state, outbound attempts to Routers 1 or 2 or any other upstream RFC1918 destinations are dropped and logged with `[nft-deny-rfc1918]`.
- Those hits are logged, summarized, and delivered via Telegram on a systemd timer, so "something tried to break NAT isolation" is visible instead of hypothetical.
- The Server is not published to the physical LAN or Internet by default; tailnet-only services remain the safer baseline.
- Known malicious or unwanted domains are blocked at DNS.
- Known-bad inbound IPs can be blocked by CrowdSec before they reach userland services.
- The visibility-first profile can alert on reconnaissance or suspicious network activity; the performance-first profile can remove the heaviest layers cleanly without losing the basic Router 3 plus nftables steady-state behavior.
- A successful compromise still leaves audit logs, firewall-deny events, and file-integrity signals for forensic value.
- Patching is automatic, daily, and unattended to reduce the window for known exploits.
- The recovery model is explicit: either keep plain ext4 for continuity, or choose encrypted root and pair it with real out-of-band console access.

The stack provides defense in depth around one central promise: under normal operation, the Hermes box stays off the rest of the home LAN, and when that promise is threatened you get logs and a clear recovery story rather than fake guarantees.

## Residual risks

1. **The main Hermes session can damage its own host.** This repo does not try to stop a trusted autonomous developer from modifying local files, installing bad packages, deleting projects, or making the machine unusable.
2. **Root-equivalent compromise (including Docker-root equivalence)** can disable nftables, AppArmor, CrowdSec, and every other software guard on the Server.
3. **Current router hardware cannot independently enforce outbound RFC1918 policy.** If host policy is removed, Router 3 alone does not save the design.
4. **Tailnet-only services still expand the reachable attack surface.** They are safer than public publishing, not risk-free.
5. **Supply-chain or browser compromise** can still land malicious code on the host.
6. **AdGuard, Suricata, and CrowdSec gaps** mean no blocklist or signature set catches everything.
7. **Optional VPN provider compromise** can deanonymize auxiliary workload traffic if you use that path.

## Default disk posture and continuity

The default repo baseline is plain ext4 root so the box can reboot unattended and come back without manual unlock. That is the right default here when continuity and remote recovery matter more than at-rest secrecy.

If at-rest protection matters more for your environment, use the optional LUKS+LVM path in Phase 02 and pair it with a real out-of-band console such as PiKVM, JetKVM, or another IP-KVM-class device. A smart plug alone is not enough, because it can only power-cycle the machine; it cannot enter the LUKS passphrase.

When you deviate from the plain-ext4 default, document the date, the reason, and the recovery plan. The runbook for switching between continuity mode and encrypted-root mode lives in Phase 13.

## Revisiting this doc

Review this document every 6 months or after any incident. Update it whenever the scope changes, the exposure model changes, or the runtime trust level changes. If a new incident shows that a threat or assumption was understated, rewrite the relevant section immediately rather than preserving the older story.

---

Last reviewed: 2026-05-23 by Vladimir Pirvu
