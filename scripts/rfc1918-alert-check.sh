#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rfc1918-alert-check.sh [--since <window>] [--tail <count>] [--state-file <path>] [--digest]

Summarize kernel log entries that match [nft-deny-rfc1918].

Modes:
  (default)  Alert mode. Sends a Telegram message only when NEW suspicious events
             appear since the last run (tracked by a cursor state file).
             Notifications are loud unless TELEGRAM_DISABLE_NOTIFICATION is set.
  --digest   Digest mode. Sends a quiet heartbeat over a fixed window (default
             12h): the suspicious-event summary plus the suppressed-noise counters
             read from nftables. Ignores the cursor state and always sends.

Environment:
  HOST_LABEL    Optional label for alerts. Defaults to short hostname.
  STATE_FILE    Optional state file used to avoid duplicate alerts (alert mode).
  TELEGRAM_BOT_TOKEN Required for Telegram delivery.
  TELEGRAM_CHAT_ID Required for Telegram delivery.
  TELEGRAM_THREAD_ID Optional Telegram topic/thread ID.
  TELEGRAM_DISABLE_NOTIFICATION Optional Telegram disable_notification flag (alert mode).
EOF
}

since="24 hours ago"
since_set=0
tail_count=10
state_file="${STATE_FILE:-}"
mode="alert"

ensure_state_parent() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  mkdir -p "$(dirname "$path")"
}

write_state() {
  local value="$1"
  [[ -n "$state_file" ]] || return 0
  ensure_state_parent "$state_file"
  printf '%s\n' "$value" > "$state_file"
}

# send_telegram <message> [force_silent]
send_telegram() {
  local message="$1"
  local force_silent="${2:-}"

  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0

  local curl_args=(
    curl -fsS -X POST
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"
    --data-urlencode "text=${message}"
    --data-urlencode "disable_web_page_preview=true"
  )

  if [[ -n "${TELEGRAM_THREAD_ID:-}" ]]; then
    curl_args+=(--data-urlencode "message_thread_id=${TELEGRAM_THREAD_ID}")
  fi

  if [[ -n "$force_silent" || -n "${TELEGRAM_DISABLE_NOTIFICATION:-}" ]]; then
    curl_args+=(--data-urlencode "disable_notification=true")
  fi

  "${curl_args[@]}" >/dev/null
}

# read_counter <comment> — packets dropped by the silent rule carrying <comment>.
read_counter() {
  local comment="$1" out
  command -v nft >/dev/null 2>&1 || { printf 'n/a'; return 0; }
  out="$(nft list chain inet filter output 2>/dev/null \
    | awk -v c="$comment" 'index($0, c) { for (i = 1; i <= NF; i++) if ($i == "packets") { print $(i+1); exit } }')"
  printf '%s' "${out:-0}"
}

summarize_flows() {
  sed -nE 's/.*SRC=([^ ]+).*DST=([^ ]+).*PROTO=([^ ]+).*SPT=([^ ]+).*DPT=([^ ]+).*/\1 -> \2 \3 \4->\5/p' \
    | sort | uniq -c | sort -rn | head -n "$tail_count"
}

# journalctl prints "-- No entries --" when a cursor/window query matches nothing.
# That sentinel must not be counted as an event or alerted on.
strip_journal_sentinels() {
  sed '/^-- No entries --$/d'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      [[ $# -ge 2 ]] || { echo "missing value for --since" >&2; exit 2; }
      since="$2"
      since_set=1
      shift 2
      ;;
    --tail)
      [[ $# -ge 2 ]] || { echo "missing value for --tail" >&2; exit 2; }
      tail_count="$2"
      shift 2
      ;;
    --state-file)
      [[ $# -ge 2 ]] || { echo "missing value for --state-file" >&2; exit 2; }
      state_file="$2"
      shift 2
      ;;
    --digest)
      mode="digest"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$tail_count" =~ ^[0-9]+$ ]] || { echo "--tail must be an integer" >&2; exit 2; }

host_label="${HOST_LABEL:-$(hostname -s 2>/dev/null || hostname)}"

# ---------------------------------------------------------------------------
# Digest mode: quiet, fixed-window heartbeat. No cursor state. Always sends.
# ---------------------------------------------------------------------------
if [[ "$mode" == "digest" ]]; then
  [[ "$since_set" -eq 1 ]] || since="12 hours ago"

  matches="$({ journalctl -k --since "$since" --grep '\[nft-deny-rfc1918\]' --no-pager -o short-iso 2>/dev/null || true; } \
    | sed '/^$/d' | strip_journal_sentinels)"

  if [[ -n "$matches" ]]; then
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    summary="$(printf '%s\n' "$matches" | summarize_flows || true)"
  else
    count=0
    summary=""
  fi

  ts_noise="$(read_counter "ts-direct-noise")"
  magicdns_noise="$(read_counter "magicdns-noise")"
  natpmp_noise="$(read_counter "natpmp-noise")"
  ssdp_noise="$(read_counter "ssdp-noise")"

  message="Host: $host_label — containment digest
Window: $since
Suspicious RFC1918 attempts: $count"

  if [[ -n "$summary" ]]; then
    message="$message

Top suspicious flows:
$summary"
  fi

  message="$message

Suppressed benign noise (packets since last ruleset load):
  Tailscale direct (sport 41641): $ts_noise
  MagicDNS to 100.100.100.100:53: $magicdns_noise
  NAT-PMP to gateway (5351): $natpmp_noise
  SSDP to gateway (1900): $ssdp_noise"

  printf '%s\n' "$message"
  send_telegram "$message" "silent"

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo
    echo "Digest posted to Telegram chat ${TELEGRAM_CHAT_ID} (silent)"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Alert mode: loud, incremental. Sends only on new suspicious events.
# ---------------------------------------------------------------------------
state_marker=""
query_ref="$since"
now_epoch="$(date +%s)"

if [[ -n "$state_file" && -r "$state_file" ]]; then
  state_marker="$(tr -d '\n' < "$state_file")"
  case "$state_marker" in
    cursor:*)
      query_mode=(--after-cursor "${state_marker#cursor:}")
      query_ref="state cursor"
      ;;
    time:*)
      query_mode=(--since "@${state_marker#time:}")
      query_ref="@${state_marker#time:}"
      ;;
    *)
      query_mode=(--since "$since")
      ;;
  esac
else
  query_mode=(--since "$since")
fi

raw_output="$({ journalctl -k "${query_mode[@]}" --grep '\[nft-deny-rfc1918\]' --no-pager --show-cursor -o short-iso 2>/dev/null || true; } | sed '/^$/d')"
cursor="$(printf '%s\n' "$raw_output" | sed -n 's/^-- cursor: //p' | tail -n 1)"
matches="$(printf '%s\n' "$raw_output" | sed '/^-- cursor: /d' | strip_journal_sentinels)"

if [[ -z "$matches" ]]; then
  if [[ -n "$state_file" && "$state_marker" != cursor:* ]]; then
    write_state "time:$now_epoch"
  fi
  echo "No [nft-deny-rfc1918] events since $query_ref."
  exit 0
fi

count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
summary="$(printf '%s\n' "$matches" | summarize_flows || true)"
recent="$(printf '%s\n' "$matches" | tail -n "$tail_count")"

message="Host: $host_label
Events: $count
Window: $query_ref

Top blocked flows:
${summary:-No parsed flow summary available}

Recent log lines:
$recent"

printf '%s\n' "$message"

send_telegram "$message"

if [[ -n "$state_file" ]]; then
  if [[ -n "$cursor" ]]; then
    write_state "cursor:$cursor"
  else
    write_state "time:$now_epoch"
  fi
fi

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo
  echo "Alert posted to Telegram chat ${TELEGRAM_CHAT_ID}"
fi
