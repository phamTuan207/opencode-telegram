#!/usr/bin/env bash
# Scaffolder: generate a working Telegram-bot ↔ OpenCode setup.
#
# What it does:
#   1. checks prerequisites and prints what is missing
#   2. writes ~/.config/opencode-telegram-bot/.env from .env.example, with a
#      freshly generated server password
#   3. installs the systemd user units and the helper scripts
#   4. prints the two manual steps (Hyprland keybind, desktop menu entry)
#
# What it deliberately does NOT do:
#   - install opencode or the bot (tell the user the command, let them run it)
#   - edit your Hyprland or desktop config
#   - enable anything without --install
#
# Usage:
#   ./setup.sh --project-dir ~/Work --port 4096            # dry run, print plan
#   ./setup.sh --project-dir ~/Work --install              # actually write
#   ./setup.sh --project-dir ~/Work --install --bot-token 123:ABC ...
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$HERE/templates"

PROJECT_DIR="$HOME"
PORT=4096
BOT_TOKEN=""
CHAT_ID=""
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode || true)}"
TELEGRAM_BIN="${OPENCODE_TELEGRAM_BIN:-$(command -v opencode-telegram || true)}"
BIN_DIR="$HOME/.local/bin"
INSTALL=0
BOT_ENV_DIR="$HOME/.config/opencode-telegram-bot"

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir)  PROJECT_DIR="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --bot-token)    BOT_TOKEN="$2"; shift 2 ;;
    --chat-id)      CHAT_ID="$2"; shift 2 ;;
    --opencode-bin) OPENCODE_BIN="$2"; shift 2 ;;
    --telegram-bin) TELEGRAM_BIN="$2"; shift 2 ;;
    --bin-dir)      BIN_DIR="$2"; shift 2 ;;
    --install)      INSTALL=1; shift ;;
    -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P || echo "$PROJECT_DIR")"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mx %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. checks
say "Checking prerequisites"
missing=0

if [ -z "$OPENCODE_BIN" ] || [ ! -x "$OPENCODE_BIN" ]; then
  warn "opencode not found. Install the v2 binary, then re-run with --opencode-bin <path>."
  missing=1
else
  echo "  opencode:        $OPENCODE_BIN ($("$OPENCODE_BIN" --version 2>/dev/null || echo 'version unknown'))"
fi

if [ -z "$TELEGRAM_BIN" ] || [ ! -x "$TELEGRAM_BIN" ]; then
  warn "opencode-telegram not found. Install it, then re-run with --telegram-bin <path>."
  missing=1
else
  echo "  bot:             $TELEGRAM_BIN"
fi

command -v systemctl >/dev/null || die "systemctl not found"
echo "  systemd user:    available"
echo "  project dir:     $PROJECT_DIR"
echo "  server port:     $PORT"

[ "$missing" -eq 0 ] || die "Fix the items above first. Nothing was written."

# ------------------------------------------------------- 2. generate secret
SERVER_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-32)"
ENV_FILE="$BOT_ENV_DIR/.env"

say "Configuration"
echo "  env file:        $ENV_FILE"
echo "  password:        generated (32 chars, random)"

if [ -f "$ENV_FILE" ]; then
  warn "$ENV_FILE already exists — it will be left untouched."
  warn "If you mean to reinstall, move it aside first:  mv $ENV_FILE $ENV_FILE.bak"
fi

# ------------------------------------------------------------- 3. rendering
render() {
  # $1 = template file, $2 = destination
  sed \
    -e "s|@OPENCODE_BIN@|$OPENCODE_BIN|g" \
    -e "s|@OPENCODE_TELEGRAM_BIN@|$TELEGRAM_BIN|g" \
    -e "s|@BIN_DIR@|$BIN_DIR|g" \
    -e "s|@PROJECT_DIR@|$PROJECT_DIR|g" \
    -e "s|@PORT@|$PORT|g" \
    -e "s|@SERVER_PASSWORD@|$SERVER_PASSWORD|g" \
    "$TPL/$1" > "$2"
}

UNIT_DIR="$HOME/.config/systemd/user"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

say "Rendering units and scripts"
render opencode-serve.service               "$STAGE/opencode-serve.service"
render opencode-telegram.service            "$STAGE/opencode-telegram.service"
render opencode-telegram-watchdog.service   "$STAGE/opencode-telegram-watchdog.service"
render opencode-telegram-watchdog.timer     "$STAGE/opencode-telegram-watchdog.timer"
render wait-net-tg.sh                       "$STAGE/wait-net-tg.sh"
render opencode-live                        "$STAGE/opencode-live"
render opencode-telegram-watchdog.sh        "$STAGE/opencode-telegram-watchdog.sh"
ls -1 "$STAGE" | sed 's/^/  /'

if [ "$INSTALL" -ne 1 ]; then
  cat <<EOF

Dry run. Nothing was written.

Re-run with --install to write these files and enable the services:
  ./setup.sh --project-dir "$PROJECT_DIR" --port $PORT --install

Then fill in TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USER_ID in:
  $ENV_FILE
EOF
  exit 0
fi

# ------------------------------------------------------------- 4. install
say "Installing"

install -d -m 700 "$BOT_ENV_DIR"
if [ ! -f "$ENV_FILE" ]; then
  sed -e "s|__SERVER_PASSWORD__|$SERVER_PASSWORD|g" "$HERE/.env.example" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "  wrote $ENV_FILE (600)"
  [ -n "$BOT_TOKEN" ] && sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$BOT_TOKEN|" "$ENV_FILE"
  [ -n "$CHAT_ID" ]   && sed -i   "s|^TELEGRAM_ALLOWED_USER_ID=.*|TELEGRAM_ALLOWED_USER_ID=$CHAT_ID|"   "$ENV_FILE"
fi

install -d -m 755 "$UNIT_DIR"
for u in opencode-serve.service opencode-telegram.service \
         opencode-telegram-watchdog.service opencode-telegram-watchdog.timer; do
  install -m 644 "$STAGE/$u" "$UNIT_DIR/$u"
  echo "  installed $UNIT_DIR/$u"
done

install -d -m 755 "$BIN_DIR"
for s in opencode-live wait-net-tg.sh opencode-telegram-watchdog.sh; do
  install -m 755 "$STAGE/$s" "$BIN_DIR/$s"
  echo "  installed $BIN_DIR/$s"
done

systemctl --user daemon-reload
for u in opencode-serve opencode-telegram opencode-telegram-watchdog.timer; do
  systemctl --user enable --now "$u" >/dev/null 2>&1 || warn "could not enable $u"
done

say "Done"
cat <<EOF

Still to do by hand:

  1. Edit the two Telegram values in $ENV_FILE
       TELEGRAM_BOT_TOKEN       (from @BotFather)
       TELEGRAM_ALLOWED_USER_ID (your chat id; send /start to the bot first)
     Then: systemctl --user restart opencode-telegram

  2. Open a Live window. Any of these works:
       $BIN_DIR/opencode-live $PROJECT_DIR
     Hyprland keybind — add to ~/.config/hypr/bindings.lua:
       o.bind("SUPER + CTRL + SHIFT + Z", "OpenCode", "$BIN_DIR/opencode-live $PROJECT_DIR")
     then: hyprctl reload && hyprctl configerrors

Verify:
  curl -s -o /dev/null -w '%{http_code}\\n' \\
    -H "Authorization: Bearer \$(grep -oP '^OPENCODE_SERVER_PASSWORD=\\K.*' $ENV_FILE)" \\
    http://127.0.0.1:$PORT/api/session
  journalctl --user -u opencode-telegram -f
EOF