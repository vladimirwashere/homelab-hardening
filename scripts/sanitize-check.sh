#!/usr/bin/env bash
# sanitize-check.sh — pre-commit secret-scanning + sanity checks
# Run from repo root: ./scripts/sanitize-check.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

failed=0
warned=0

echo "🔍 Checking staged files for secrets and personal info..."
echo

# What files are about to be committed?
STAGED=$(git diff --cached --name-only 2>/dev/null || git ls-files)
if [ -z "$STAGED" ]; then
  STAGED=$(find . -type f \
    -not -path './.git/*' \
    -not -path './node_modules/*' \
    -not -name '*.svg')
fi

# === 1. Check for high-confidence secret patterns ===
echo "→ Checking for tokens, keys, credentials..."

declare -A patterns=(
  ["AWS Access Key"]='AKIA[0-9A-Z]{16}'
  ["GitHub PAT (classic)"]='ghp_[A-Za-z0-9]{36}'
  ["GitHub PAT (fine-grained)"]='github_pat_[A-Za-z0-9_]{82}'
  ["OpenAI API key"]='sk-[A-Za-z0-9]{20,}'
  ["Anthropic API key"]='sk-ant-[A-Za-z0-9_-]{20,}'
  ["Telegram bot token"]='[0-9]{8,10}:[A-Za-z0-9_-]{35}'
  ["Slack token"]='xox[bpoa]-[0-9]+-[0-9]+-[A-Za-z0-9]+'
  ["Generic API key"]='api[_-]?key[\"'\'']?\s*[:=]\s*[\"'\''][A-Za-z0-9]{32,}[\"'\'']'
  ["Private RSA key"]='-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  ["Bearer token"]='[Bb]earer\s+[A-Za-z0-9_\-\.=]{20,}'
  ["NordVPN token"]='[A-Fa-f0-9]{64}'
)

for desc in "${!patterns[@]}"; do
  pattern="${patterns[$desc]}"
  matches=$(echo "$STAGED" | xargs -I{} grep -l -E "$pattern" {} 2>/dev/null | grep -v "scripts/sanitize-check.sh" || true)
  if [ -n "$matches" ]; then
    echo -e "  ${RED}✗${NC} Possible $desc found in:"
    echo "$matches" | sed 's/^/      /'
    failed=$((failed + 1))
  fi
done

# === 2. Check for personally identifying patterns ===
echo
echo "→ Checking for personal identifiers..."

# Real public IPs (rough heuristic — anything that's NOT RFC1918/link-local/test ranges)
public_ip_files=$(STAGED_FILES="$STAGED" python3 - <<'PY'
import ipaddress
import pathlib
import re
import os

files = [line.strip() for line in os.environ.get("STAGED_FILES", "").splitlines() if line.strip()]
ip_pat = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")

allowed_nets = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("203.0.113.0/24"),
    ipaddress.ip_network("198.51.100.0/24"),
]
allowed_exact = {
    "0.0.0.0",
    "255.255.255.255",
    "255.255.255.0",
    # Common public DNS examples used in connectivity/upstream docs
    "1.1.1.1",
    "8.8.8.8",
    "9.9.9.9",
}

flagged = []
for name in files:
    path = pathlib.Path(name)
    try:
        text = path.read_text(errors="ignore")
    except Exception:
        continue

    bad = False
    for raw in ip_pat.findall(text):
        if raw in allowed_exact:
            continue
        try:
            ip = ipaddress.ip_address(raw)
        except ValueError:
            continue
        if any(ip in net for net in allowed_nets):
            continue
        bad = True
        break
    if bad:
        flagged.append(name)

print("\n".join(flagged))
PY
)

if [ -n "$public_ip_files" ]; then
  echo -e "  ${YELLOW}⚠${NC} Possible public IPs found (may be screenshots/docs OK, but verify):"
  echo "$public_ip_files" | sed 's/^/      /'
  warned=$((warned + 1))
fi

# Real MAC addresses (anything not aa:bb:cc:dd:ee:ff or similar placeholders)
mac_files=$(echo "$STAGED" | xargs -I{} grep -lE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' {} 2>/dev/null | \
  xargs grep -lvE '(aa:bb:cc|00:00:00|ff:ff:ff|01:00:5e|^docs/)' 2>/dev/null || true)

if [ -n "$mac_files" ]; then
  echo -e "  ${YELLOW}⚠${NC} Files contain MAC-address-like strings — verify they're sanitized:"
  echo "$mac_files" | sed 's/^/      /'
  warned=$((warned + 1))
fi

# === 3. Check ignored files aren't accidentally tracked ===
echo
echo "→ Checking .gitignore rules are respected..."

forbidden=("secrets/" "*.key" "*.pem" "nordvpn-token.txt" "gluetun.env" "control-server.toml" "wg0.conf")
for pattern in "${forbidden[@]}"; do
  if echo "$STAGED" | grep -q "$pattern"; then
    echo -e "  ${RED}✗${NC} A file matching '$pattern' is in commit — should be ignored!"
    failed=$((failed + 1))
  fi
done

# Match real .env files only (not *.env.template)
if echo "$STAGED" | grep -E '(^|/)\.env$' | grep -q .; then
  echo -e "  ${RED}✗${NC} A file matching '.env' is in commit — should be ignored!"
  failed=$((failed + 1))
fi

# === 4. Suggest gitleaks for full scan ===
echo
if command -v gitleaks >/dev/null 2>&1; then
  echo "→ Running gitleaks..."
  if gitleaks detect --no-banner --redact 2>&1 | grep -q "leaks found: 0"; then
    echo -e "  ${GREEN}✓${NC} gitleaks found 0 leaks"
  else
    echo -e "  ${RED}✗${NC} gitleaks found issues — run 'gitleaks detect' for details"
    failed=$((failed + 1))
  fi
else
  echo -e "  ${YELLOW}⚠${NC} gitleaks not installed. Recommended: brew install gitleaks"
  warned=$((warned + 1))
fi

# === Summary ===
echo
echo "═══════════════════════════════════════════"
if [ $failed -eq 0 ] && [ $warned -eq 0 ]; then
  echo -e "${GREEN}✓ All checks passed.${NC} Safe to commit."
  exit 0
elif [ $failed -eq 0 ]; then
  echo -e "${YELLOW}⚠ $warned warning(s).${NC} Review and commit if OK."
  exit 0
else
  echo -e "${RED}✗ $failed error(s), $warned warning(s).${NC} Fix before committing."
  exit 1
fi
