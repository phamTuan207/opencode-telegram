#!/usr/bin/env bash
# Restart opencode-telegram when it is genuinely frozen.
#
# WHAT GOES WRONG WITHOUT THIS
# The bot subscribes to the OpenCode event stream with no timeout. When the
# server flaps, that request hangs forever: the process is alive, Telegram
# polling works, but no session events ever arrive, so the bot stops reacting.
#
# WHAT MUST NOT BE USED AS A PROBE
# getUpdates. Every getUpdates call makes Telegram terminate whatever long poll
# the bot is currently holding, so the probe kills the process it is inspecting.
# That produced a restart every few minutes, forever, without ever catching a
# real freeze.
#
# WHAT IS CHECKED INSTEAD — two provable conditions:
#   1. the unit is not running        -> start it
#   2. the bot holds no socket to the server port -> its subscribe never
#      completed -> restart
#
# Note: do not add a socket-received-timeout check. The v2 server sends no
# periodic heartbeat; on a perfectly healthy bot that timestamp grows for hours
# while idle and only resets on real work, so a timeout restarts a healthy bot.
set -u

UNIT="${UNIT:-opencode-telegram}"
PORT="${OPENCODE_PORT:-@PORT@}"
BIN_DIR="@BIN_DIR@"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"

start_or_restart() {
  systemctl --user start "$UNIT.service" 2>/dev/null || true
}

pid="$(systemctl --user show -p MainPID --value "$UNIT.service" 2>/dev/null || true)"

# 1. unit not running (Restart= does not cover an explicit stop)
if [ -z "$pid" ] || [ "$pid" = "0" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "$UNIT: not running, starting"
  start_or_restart
  exit 0
fi

# 2. no ESTAB socket from the bot to the server port
# Read the inodes systemd already tracks for the unit, so the match cannot
# accidentally hit an unrelated process that happens to hold the same port.
inodes="$(systemctl --user show -p MainPID --value "$UNIT.service" >/dev/null 2>&1; \
  ls -l "/proc/$pid/fd" 2>/dev/null | grep -oP 'socket:\[\K[0-9]+' | tr '\n' ' ')"

found=0
for ino in $inodes; do
  if awk -v p=":$PORT" -v i="$ino" 'NR>1 && $4 ~ p"$" && $10 == i {found=1} END{exit !found}' \
       /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    found=1
    break
  fi
done

if [ "$found" -eq 0 ]; then
  echo "$UNIT: no socket to port $PORT, restarting"
  systemctl --user restart "$UNIT.service" 2>/dev/null || true
fi