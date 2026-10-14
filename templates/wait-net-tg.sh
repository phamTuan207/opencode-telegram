#!/usr/bin/env bash
# Block until Telegram's API answers. Used as ExecStartPre of the bot unit so a
# network outage does not become a crash-restart loop.
set -u

URL="https://api.telegram.org/"
TRIES="${1:-60}"

for _ in $(seq 1 "$TRIES"); do
  if curl -sf --max-time 3 -o /dev/null "$URL" 2>/dev/null; then
    exit 0
  fi
  sleep 2
done

exit 1