# Phase 07 — Podman + NVIDIA Support Tooling (Optional Branch)

> **Time required:** ~45-60 minutes

## Why this phase

The primary runtime in this repo is host-native Hermes (Phase 12), not containers. Podman still matters for support workloads:

- DNS and utility services (Phase 08+)
- optional VPN-routed delegated jobs (Phase 09)
- GPU sidecar workloads that should stay separate from the main runtime

This phase records the root-only container baseline used by the later optional phases.

## What was implemented

- Podman installed and validated
- NVIDIA container runtime enabled
- dedicated support network `agentnet`
- system quadlet location prepared (`/etc/containers/systemd`)

## Prerequisites

- Phase 06 complete (`nftables` baseline active)
- host GPU driver working (`nvidia-smi`)
- root shell access

## Step 7.1 — Install Podman and dependencies

```bash
apt update
apt install -y podman jq curl uidmap slirp4netns fuse-overlayfs crun
podman --version
```

## Step 7.2 — Validate baseline container execution

```bash
podman run --rm docker.io/library/hello-world
podman run --rm docker.io/curlimages/curl:latest curl -fsSI https://example.com | head -1
```

## Step 7.3 — Install NVIDIA container support

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update
apt install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=podman
```

## Step 7.4 — Verify GPU inside container

```bash
nvidia-smi
podman run --rm --device nvidia.com/gpu=all docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

## Step 7.5 — Create support network

```bash
podman network create --subnet 172.30.0.0/24 --gateway 172.30.0.1 agentnet
podman network inspect agentnet
```

Why `172.30.0.0/24`:

- avoids overlap with home LAN ranges
- keeps support-container traffic easy to reason about during containment tests

## Step 7.6 — Prepare root system quadlet path

```bash
install -d -m 755 /etc/containers/systemd
```

Later phases place `.container` quadlets here and manage them with plain `systemctl`.

## Step 7.7 — Optional storage relocation to HDD

If `/var/lib/containers` starts growing too much:

```bash
systemctl stop adguard.service gluetun.service 2>/dev/null || true
podman stop -a 2>/dev/null || true

mkdir -p /mnt/data/containers/storage
rsync -aHAX --info=progress2 /var/lib/containers/ /mnt/data/containers/storage/

cp /etc/containers/storage.conf /etc/containers/storage.conf.bak.$(date +%Y%m%d)
nano /etc/containers/storage.conf
# set:
# graphroot = "/mnt/data/containers/storage"

podman system reconfigure 2>/dev/null || true
podman info | jq '.store.graphRoot'
systemctl start adguard.service gluetun.service 2>/dev/null || true
```

## Issues encountered and solutions

- **Runtime mismatch after installing NVIDIA toolkit:** resolved by re-running `nvidia-ctk runtime configure --runtime=podman`.
- **Network confusion during repeated tests:** resolved by always checking `podman network inspect agentnet` before recreating resources.
- **Storage growth under image-heavy workloads:** addressed by documenting HDD relocation early instead of waiting for NVMe pressure.

## Trade-offs accepted

- Podman adds operational complexity and additional attack surface vs pure host-native services.
- Containerizing support services improves dependency isolation and rollback safety.
- GPU container support is useful but increases maintenance burden.

## Verification checklist

- [ ] `podman --version` is healthy
- [ ] `podman run --rm hello-world` succeeds
- [ ] host and container `nvidia-smi` both succeed
- [ ] `podman network inspect agentnet` returns expected subnet/gateway
- [ ] `/etc/containers/systemd/` exists for subsequent phases

## Troubleshooting

**`podman run hello-world` fails.** Check `podman info` and verify package install completed; rerun `apt install -y podman ...`.

**GPU is visible on host but not in container.** Re-run `nvidia-ctk runtime configure --runtime=podman` and retest.

**`agentnet` already exists.** Continue; inspect with `podman network inspect agentnet`.

## Next

→ [Phase 08: AdGuard Home DNS sinkhole](08-adguard-dns.md)
