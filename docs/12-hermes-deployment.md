# Phase 12 — Hermes Agent Deployment: Trusted Root Runtime + Multi-Provider Routing

> **Time required:** ~2-4 hours for the API-only path, +1-2 hours if local models are enabled.

## Why this phase

After the network and host-hardening baseline was in place, the remaining goal was to deploy a high-autonomy runtime agent and pick a model strategy that balances cost, quality, and reliability. Two decisions sit on top of the install:

1. **Where the agent runs.** Hermes itself runs directly as `root` on this single-operator host, consistent with the trust model in Phase 03. Sidecars that hold API keys or expose model endpoints (Ollama, optional LiteLLM proxy) run **rootless under a dedicated `agent-svc` system user** with Podman secrets. This puts the API-key blast radius in a smaller box without sandboxing the agent itself.
2. **Which models do what.** Frontier reasoning models are routed to the orchestrator slot. Cheaper API models (DeepSeek, Haiku, Gemini Flash) and a local 7B coding model handle auxiliary subtasks (compression, vision, bulk file ops). The matrix in Step 12.3 records the choices and their cost/quality basis.

Containment controls (`nftables`, Tailscale ACLs, Router 3 topology) remain in place. The agent runtime is still trusted root; this phase only adds a meaningful key-management boundary, not local agent isolation.

## What was implemented

- Hermes Agent installed on the host via the official installer, runtime state under `/root/.hermes/`.
- `agent-svc` system user created for sidecar services (Ollama, optional LiteLLM).
- OpenRouter chosen as the primary provider — one API key, one bill, per-key spending caps, native fallback.
- Provider routing configured: orchestrator on a frontier model, auxiliary slots on cheaper or local models.
- Optional Ollama sidecar deployed rootless via Podman under `agent-svc` with API key via Podman secrets.
- Optional LiteLLM proxy sidecar for per-model cost tracking, retry/fallback, and clean access logs.
- Root-owned persistent gateway service for headless operation.
- Local-only access pattern for sensitive endpoints (tunnel-first).

## Prerequisites

- Required baseline complete: Phases 01, 02, 03, 05, 06, and 11.
- Phase 07 (Podman + NVIDIA) is required only if you intend to run **local models** via the Ollama sidecar (Step 12.9) or the LiteLLM sidecar (Step 12.10).
- Recommended before this phase: Phase 08 if you want host DNS filtering in front of Hermes.
- `tailscale ssh root@homelab` stable.
- Root-only account model already active from Phase 03.
- 2 TB HDD prepared if you want larger data/artifact retention.
- An OpenRouter account with at least $20 of prepaid credit. A direct provider account is optional.

## Trust split: agent as root, key-holding sidecars as `agent-svc`

| Component | Runs as | Why |
| --- | --- | --- |
| `hermes` CLI + `hermes-gateway` systemd unit | `root` | Consistent with Phase 03 model. Hermes needs broad host access to be useful as an autonomous agent. |
| Ollama (optional) | `agent-svc` (rootless Podman) | Holds GPU access but no Anthropic/OpenAI keys. Limits blast radius of a model-side exploit. |
| LiteLLM proxy (optional) | `agent-svc` (rootless Podman) | Holds *all* provider API keys via Podman secrets. Compromise here is the worst case — keep it small and isolated. |

If you skip the sidecars and let Hermes talk directly to OpenRouter, the trust split collapses to "everything is root" and your one API key lives in `/root/.hermes/.env`. That's also fine; the sidecars exist to *reduce* that one risk, not because the install requires them.

## Step 12.1 — Confirm runtime assumptions

```bash
whoami
id
hostnamectl --static
nvidia-smi  # if you plan to use local models
```

Expected outcome:

- runtime user is `root`
- this host is treated as a trusted single-operator runtime
- GPU is visible to the host (only required for local models)

## Step 12.2 — Keep NVMe for active state, HDD for bulk artifacts

Hermes active state stays on NVMe (`/root/.hermes`) for responsiveness. HDD is for bulk data and model weights.

```bash
lsblk
fdisk -l 2>/dev/null | grep '^Disk /dev/sd'

# Replace /dev/sda with your actual HDD device.
HDD=/dev/sda

# Guard: skip partition/format if /mnt/data is already mounted.
if findmnt -rn -T /mnt/data >/dev/null 2>&1; then
  echo "/mnt/data already mounted; skipping disk format."
else
  parted "$HDD" --script mklabel gpt mkpart primary ext4 0% 100%
  mkfs.ext4 -L data ${HDD}1
  mkdir -p /mnt/data
  mount ${HDD}1 /mnt/data
  blkid ${HDD}1
  # Add to /etc/fstab using the UUID from blkid:
  # UUID=<uuid> /mnt/data ext4 defaults,nofail 0 2
fi

mkdir -p /mnt/data/hermes/{models,archives,backups,downloads}
mkdir -p /mnt/data/containers
mkdir -p /mnt/data/agent-svc/{ollama,litellm}
chown -R root:root /mnt/data/hermes /mnt/data/containers
```

`/mnt/data/agent-svc` is created here but reassigned to the `agent-svc` user in Step 12.9 (only if you do the local-model branch).

## Step 12.3 — Choose your provider mix (cost/quality matrix)

Prices are per 1M tokens, captured from provider pricing pages at install time. Re-check before you commit; this market moves monthly.

### Frontier reasoning tier (orchestrator candidates)

| Model | Input | Output | Cache read | Notable benchmark | Best for |
| --- | --- | --- | --- | --- | --- |
| Claude Opus 4.8 | $5.00 | $25.00 | $0.50 | SWE-bench Verified 88.6% | Top agentic perf, expensive |
| Claude Fable 5 | $10.00 | $50.00 | $1.00 | SWE-bench Verified 95.0% | Best-in-class quality, premium |
| GPT-5.5 (short ctx) | $5.00 | $30.00 | $0.50 | Aider Polyglot leader (GPT-5 family) | Strongest non-Claude reasoning |
| GPT-5.4 (short ctx) | $2.50 | $15.00 | $0.25 | One tier down from 5.5, much cheaper | Balanced reasoning workhorse |
| Gemini 2.5 Pro (≤200k) | $1.25 | $10.00 | $0.125 | Aider Polyglot 83.1% | Cheapest of this tier; 1M ctx for data-heavy work |

### Mid / balanced tier (worker candidates)

| Model | Input | Output | Cache read | Best for |
| --- | --- | --- | --- | --- |
| Claude Sonnet 4.6 | $3.00 | $15.00 | $0.30 | Strong agentic worker; huge cache savings on repeated prompts |
| DeepSeek v4-pro | $0.435 | $0.87 | $0.0036 | Cheapest competent reasoning; near-free on cache hits |
| Gemini 2.5 Flash | $0.30 | $2.50 | $0.03 | Cheap, fast, 1M context |

### Cheap / bulk tier (subtask + auxiliary candidates)

| Model | Input | Output | Best for |
| --- | --- | --- | --- |
| Claude Haiku 4.5 | $1.00 | $5.00 | Cheap Claude-family compatibility; cache read $0.10 |
| GPT-5.4-mini | $0.75 | $4.50 | Cheap OpenAI-style outputs |
| DeepSeek v4-flash | $0.14 | $0.28 | Cheapest hosted; ideal for compression/summarization |
| Gemini 2.5 Flash-Lite | $0.10 | $0.40 | Cheapest text in the matrix |
| GPT-5.4-nano | $0.20 | $1.25 | Embeddings/classification on OpenAI stack |

### Local tier (free, capped by hardware)

On a GTX 1080 Ti (Pascal, 11 GB VRAM, no bf16/FP8, no FlashAttention 2) the practical options are 7B-class dense models or small MoE at Q4/Q5. Pascal limits you to `llama.cpp` / Ollama (vLLM does not target Pascal in practice).

| Model | Quant | Approx. VRAM | Best for |
| --- | --- | --- | --- |
| qwen2.5-coder:7b-instruct-q5_K_M | Q5_K_M | ~5.4 GB | Default local coder; leaves headroom for 16-32k context |
| qwen2.5-coder:7b-instruct-q8_0 | Q8_0 | ~8.1 GB | Higher quality, tighter context budget |
| deepseek-r1-distill-qwen-7b | Q4_K_M | ~5 GB | Reasoning distill if you want chain-of-thought locally |
| nomic-embed-text | — | ~1 GB | Local embeddings; cheap and good enough |

### Recommended default for a ~$100/mo trading-environment workload

- **Orchestrator:** Claude Sonnet 4.6 via OpenRouter. Strong agentic benchmarks, prompt caching cuts effective input cost ~90% on repeated system prompts (typical for an agent loop), and Anthropic pricing is the most predictable across the matrix.
- **Auxiliary `compression`:** DeepSeek v4-flash. Near-zero cost per call; perfect for log/output summarization.
- **Auxiliary `vision`:** Gemini 2.5 Flash. Multimodal, cheap, fast.
- **Local fallback for offline runs and bulk file ops:** `qwen2.5-coder:7b-instruct-q5_K_M`.
- **Burst-quality escape hatch:** Opus 4.8 or GPT-5.5 invoked manually with `hermes --model ...` when a hard problem warrants it.

Sanity-check the math against your spend cap: at $3/$15 with 80% input cache hits, ~6M input + 2M output tokens/month sits well inside $100. Trading workloads tend to be input-heavy (market data, position state) which favors Anthropic's cache pricing.

## Step 12.4 — Provision API keys

OpenRouter is the primary key. Direct provider keys are optional escape hatches.

1. Create an account at <https://openrouter.ai>.
2. Add prepaid credit ($20 minimum to start). OpenRouter passes provider prices through and charges a 5.5% platform fee on pay-as-you-go.
3. Create a key scoped to this host: dashboard → Keys → "Create Key" → name it `homelab-hermes`, set a hard spend cap (e.g. $120/mo as a circuit breaker above your $100 target).
4. (Optional) Direct OpenAI key from <https://platform.openai.com/api-keys> if you want to bypass the 5.5% fee on hot paths. Set a usage limit there too.
5. (Optional) Direct Anthropic key from <https://console.anthropic.com> for the same reason; remember Pro/Max subscriptions do not work here.

Store keys temporarily out of shell history:

```bash
read -rs OPENROUTER_API_KEY ; export OPENROUTER_API_KEY
# repeat for optional keys; do NOT echo them
```

They get persisted to `/root/.hermes/.env` in Step 12.7 (Hermes only) and/or Podman secrets in Step 12.10 (LiteLLM proxy).

## Step 12.5 — Install Hermes Agent

The official install one-liner (verify the script contents before piping to bash if you have not seen it):

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh
less /tmp/hermes-install.sh   # review
bash /tmp/hermes-install.sh
```

If you want browser-using tools (Playwright), one root step is needed once:

```bash
npx playwright install-deps chromium
```

Reload shell and validate:

```bash
exec "$SHELL" -l
hermes --version
hermes doctor
```

Notes from install behavior:

- The installer handles Python/uv/Node/ripgrep/ffmpeg automatically on supported platforms.
- The only path step that strictly needs root is Playwright `--with-deps`; the rest runs unprivileged. Running as root here is a deliberate choice from the trust model, not a requirement.

## Step 12.6 — Initial setup

```bash
hermes setup
hermes model
```

Identity choice for this repo:

- Keep default neutral behavior initially.
- If needed later, identity can be customized in `/root/.hermes/SOUL.md`. Defer this; identity is a later optimization, not a bootstrap requirement.

## Step 12.7 — Configure provider routing

Edit `/root/.hermes/config.yaml` to set the orchestrator and auxiliary slots:

```yaml
model:
  provider: openrouter
  model: anthropic/claude-sonnet-4.6
  base_url: null
  context_length: 200000

auxiliary:
  compression:
    provider: openrouter
    model: deepseek/deepseek-v4-flash
    base_url: null
  vision:
    provider: openrouter
    model: google/gemini-2.5-flash
    base_url: null
```

Then put the key into `/root/.hermes/.env`:

```bash
install -m 600 /dev/null /root/.hermes/.env
cat >> /root/.hermes/.env <<'EOF'
OPENROUTER_API_KEY=sk-or-v1-...
# OPENAI_API_KEY=sk-...
# ANTHROPIC_API_KEY=sk-ant-...
# DEEPSEEK_API_KEY=...
# GEMINI_API_KEY=...
EOF
chmod 600 /root/.hermes/.env
```

Hardening flags worth setting in `.env` (none of these are on by default; pick deliberately):

```bash
cat >> /root/.hermes/.env <<'EOF'
# Do NOT enable YOLO mode on a host with autonomy + market access.
HERMES_YOLO_MODE=false

# Restrict file writes to a single working tree.
HERMES_WRITE_SAFE_ROOT=/root/work

# Mask secrets in logs.
HERMES_REDACT_SECRETS=true

# Long-running tool calls (model inference, data fetches) need a generous timeout.
HERMES_API_TIMEOUT=1800
EOF
```

Sanity-check:

```bash
hermes doctor
hermes --print 'reply with the single word OK' 2>&1 | tail -5
```

The `hermes doctor` output should list your provider and resolved model. The smoke test should print `OK` and a small token bill should appear in your OpenRouter dashboard.

## Step 12.8 — Verify config/state layout

```bash
ls -la /root/.hermes
test -f /root/.hermes/config.yaml && echo "config.yaml present"
test -f /root/.hermes/.env && echo ".env present"
stat -c '%a %n' /root/.hermes/.env  # expect 600
hermes doctor
```

Typical paths now used by this build:

- `/root/.hermes/config.yaml`
- `/root/.hermes/.env`
- `/root/.hermes/logs/`
- `/root/.hermes/sessions/`
- `/root/.hermes/skills/` (if/when enabled)

## Step 12.9 — Optional: local model sidecar via Ollama

Skip this step if you only want API models.

Prerequisite: Phase 07 complete (Podman + NVIDIA container toolkit working).

Create the unprivileged service user and storage:

```bash
useradd --system --create-home --shell /usr/sbin/nologin agent-svc
loginctl enable-linger agent-svc
chown -R agent-svc:agent-svc /mnt/data/agent-svc
install -d -o agent-svc -g agent-svc -m 700 /mnt/data/agent-svc/ollama
```

Run Ollama rootless under `agent-svc` with GPU access:

```bash
sudo -iu agent-svc bash <<'EOF'
mkdir -p ~/.config/containers
podman run -d \
  --name ollama \
  --device nvidia.com/gpu=all \
  --restart unless-stopped \
  -v /mnt/data/agent-svc/ollama:/root/.ollama \
  -p 127.0.0.1:11434:11434 \
  docker.io/ollama/ollama:latest

podman exec ollama ollama pull qwen2.5-coder:7b-instruct-q5_K_M
podman exec ollama ollama pull nomic-embed-text
EOF
```

The port is bound to `127.0.0.1` only — Hermes (on the host) reaches it via loopback, and Tailscale/LAN cannot. Verify:

```bash
curl -s http://127.0.0.1:11434/api/tags | jq '.models[].name'
```

Wire Ollama into Hermes as the local auxiliary fallback. Update `/root/.hermes/config.yaml`:

```yaml
auxiliary:
  compression:
    provider: custom
    model: qwen2.5-coder:7b-instruct-q5_K_M
    base_url: http://127.0.0.1:11434/v1
  embeddings:
    provider: custom
    model: nomic-embed-text
    base_url: http://127.0.0.1:11434/v1
```

For `provider: custom` the SDK falls back to `OPENAI_API_KEY` for the bearer header; Ollama ignores it. Set it to any non-empty value if Hermes complains:

```bash
echo "OPENAI_API_KEY=ollama-ignored" >> /root/.hermes/.env
```

Persist as a systemd quadlet so the container survives reboots without manual intervention. Under `agent-svc`:

```bash
sudo -iu agent-svc bash <<'EOF'
mkdir -p ~/.config/containers/systemd
cat > ~/.config/containers/systemd/ollama.container <<'UNIT'
[Unit]
Description=Ollama local model server
After=network-online.target

[Container]
Image=docker.io/ollama/ollama:latest
ContainerName=ollama
PublishPort=127.0.0.1:11434:11434
Volume=/mnt/data/agent-svc/ollama:/root/.ollama
AddDevice=nvidia.com/gpu=all

[Service]
Restart=always

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now ollama.service
EOF
```

## Step 12.10 — Optional: LiteLLM proxy sidecar

LiteLLM lets you put one OpenAI-compatible endpoint in front of multiple providers, with per-model cost accounting, fallback chains, and a single audit log — useful for a trading-adjacent workload that needs receipts. Skip if OpenRouter alone is sufficient.

Run rootless under `agent-svc`. Use Podman secrets for keys instead of an `.env`:

```bash
sudo -iu agent-svc bash <<'EOF'
read -rs ; printf '%s' "$REPLY" | podman secret create openrouter_api_key -
read -rs ; printf '%s' "$REPLY" | podman secret create openai_api_key -
read -rs ; printf '%s' "$REPLY" | podman secret create anthropic_api_key -
podman secret ls
EOF
```

Minimal config (under `agent-svc`'s home, e.g. `/home/agent-svc/litellm/config.yaml`):

```yaml
model_list:
  - model_name: orchestrator
    litellm_params:
      model: openrouter/anthropic/claude-sonnet-4.6
      api_key: os.environ/OPENROUTER_API_KEY
      fallbacks: [orchestrator-fallback]
  - model_name: orchestrator-fallback
    litellm_params:
      model: openai/gpt-5.4
      api_key: os.environ/OPENAI_API_KEY
  - model_name: cheap
    litellm_params:
      model: openrouter/deepseek/deepseek-v4-flash
      api_key: os.environ/OPENROUTER_API_KEY
  - model_name: local-coder
    litellm_params:
      model: openai/qwen2.5-coder:7b-instruct-q5_K_M
      api_base: http://127.0.0.1:11434/v1
      api_key: ollama-ignored

litellm_settings:
  drop_params: true
  set_verbose: false
  json_logs: true
```

Run the container with secrets mounted as env:

```bash
sudo -iu agent-svc podman run -d \
  --name litellm \
  --restart unless-stopped \
  --network host \
  --secret openrouter_api_key,type=env,target=OPENROUTER_API_KEY \
  --secret openai_api_key,type=env,target=OPENAI_API_KEY \
  --secret anthropic_api_key,type=env,target=ANTHROPIC_API_KEY \
  -v /home/agent-svc/litellm:/config:Z \
  ghcr.io/berriai/litellm:main-latest \
  --config /config/config.yaml --port 4000 --host 127.0.0.1
```

Point Hermes at the proxy:

```yaml
model:
  provider: custom
  model: orchestrator
  base_url: http://127.0.0.1:4000/v1
  context_length: 200000

auxiliary:
  compression:
    provider: custom
    model: cheap
    base_url: http://127.0.0.1:4000/v1
```

Hermes now sees one endpoint; LiteLLM handles fan-out, cost accounting, and fallback. Audit log at `/home/agent-svc/litellm/logs/`.

## Step 12.11 — Install persistent gateway service

For headless operation:

```bash
hermes gateway install --system
hermes gateway start --system
hermes gateway status --system
journalctl -u hermes-gateway -n 100 --no-pager
```

This runs as root, consistent with the rest of the agent.

## Step 12.12 — Gateway exposure and access discipline

Baseline choice:

- Keep gateway local/tailnet-facing only.
- No WAN exposure, no router port forwards.
- If you enable messaging platforms, restrict users via explicit allowlists.

Example allowlist environment variables (only if gateway bots are enabled):

```bash
# /root/.hermes/.env
GATEWAY_ALLOW_ALL_USERS=false
GATEWAY_ALLOWED_USERS=123456789
TELEGRAM_ALLOWED_USERS=123456789
```

A prompt-injected agent with messaging-channel access is a real attack path against the API-key wallet. Allowlists are not optional once you turn this on.

## Step 12.13 — Operational checks

```bash
hermes doctor
hermes memory status || true
hermes logs list
hermes logs errors -n 100
systemctl status --no-pager hermes-gateway
# Sidecar checks (only if Step 12.9 / 12.10 done):
sudo -iu agent-svc systemctl --user status ollama.service
sudo -iu agent-svc podman logs --tail 50 litellm 2>/dev/null || true
```

Spend control:

- Check OpenRouter dashboard daily for the first week to validate routing matches your config.
- If LiteLLM is in the loop, `jq -r '.spend' /home/agent-svc/litellm/logs/*.jsonl` gives a daily total per model.

## Issues encountered and fixes

### Issue: stale shell PATH after installer

- **Symptom:** `hermes: command not found` immediately after install.
- **Fix:** `exec "$SHELL" -l`.
- **Prevention:** always reload shell before first verification command.

### Issue: tried to use ChatGPT Plus / Claude Pro subscription as API auth

- **Symptom:** 401 / "no key provided" errors despite an active consumer subscription.
- **Fix:** create a separate API key on `platform.openai.com` or `console.anthropic.com`; fund it with prepaid credit.
- **Prevention:** treat consumer subscriptions and API access as fully separate billing surfaces. Same applies to Gemini, Grok, DeepSeek.

### Issue: service starts but no expected gateway activity

- **Symptom:** `hermes-gateway` active, but no incoming channel events.
- **Fix:** run `hermes gateway setup`, then confirm allowlist/user IDs in `/root/.hermes/.env`.
- **Prevention:** always validate `hermes gateway status --system` and `hermes logs gateway`.

### Issue: Ollama on Pascal hits FlashAttention / bf16 errors

- **Symptom:** `qwen2.5-coder` 14B+ models OOM or fail to load on the 1080 Ti.
- **Fix:** stick to 7B at Q4/Q5; the 14B at Q4 fits weights but starves the KV cache. Pascal has no bf16 / no FlashAttention 2 — many newer inference engines (vLLM, TGI) will not work at all.
- **Prevention:** plan local model selection around the Pascal limit from the start. Treat anything above 8 GB on disk as suspect.

### Issue: uncertainty around persona design

- **Symptom:** pressure to over-customize identity too early.
- **Fix:** kept identity open-ended; deferred `SOUL.md` customization.
- **Prevention:** treat identity as a later optimization, not a bootstrap requirement.

## Trade-offs accepted in this phase

- Running Hermes as root maximizes autonomy and minimizes friction but removes local privilege boundaries. The sidecar `agent-svc` user narrows the API-key blast radius without claiming hermes itself is sandboxed.
- OpenRouter as the primary key trades a 5.5% platform fee for a single billing surface, native fallback, and one key to rotate. Direct provider keys are kept as optional escape hatches.
- The LiteLLM sidecar adds a container and an extra failure mode in exchange for unified cost accounting and a clean audit log. Skip it if OpenRouter dashboards are enough.
- Local models on a 1080 Ti are capped at the 7B/Q5 tier in practice. They are a fallback for offline runs and bulk subtasks, not a frontier replacement.
- Persistent gateway operation improves operability but expands the need for strict user allowlists and log review.

## Verification checklist

- [ ] `hermes --version` returns cleanly
- [ ] `hermes doctor` reports healthy baseline with the expected provider/model
- [ ] `/root/.hermes/config.yaml` and `/root/.hermes/.env` exist; `.env` is mode 600
- [ ] `hermes --print 'reply with the single word OK'` succeeds and produces a small bill on the OpenRouter dashboard
- [ ] `hermes gateway status --system` is active
- [ ] `journalctl -u hermes-gateway -n 100 --no-pager` shows healthy startup
- [ ] `curl -m 5 http://192.168.3.1 ; echo $?` still fails from the host (containment intact)
- [ ] (Optional) `curl -s http://127.0.0.1:11434/api/tags` lists local models; port 11434 is *not* reachable from the tailnet
- [ ] (Optional) LiteLLM `/v1/models` lists `orchestrator`, `cheap`, `local-coder`; port 4000 is *not* reachable from the tailnet
- [ ] OpenRouter spend cap is set below your monthly ceiling as a circuit breaker

## Next

→ [Phase 13: Audit, maintenance, recovery, cleanup, and alert follow-up](13-audit-maintenance.md)
