# OpenCode over Telegram, with a Live desktop window

Run your OpenCode agent from Telegram, and keep the same conversation open in a
real TUI on your desktop. Both are clients of one shared server, so a message
sent from your phone shows up in the desktop window while you type, and vice
versa.

```
Telegram ──long poll──> opencode-telegram ──HTTP──┐
                                                    ├──> opencode serve :4096 ──> opencode.db
Live TUI ──────────── client ──── /event (SSE) ───┘             │
                                                   ▲             └──> Live TUI (second client)
                                    settings.json: currentSession.id
```

That shared server is the whole trick. There is no sync daemon and no message
relay: both front ends read the same session, so there is nothing to fall out of
step.

## What this is not

It is not a wrapper around `opencode attach`. The desktop window is a second
client of the same v2 server the bot uses, not a copy of the bot's state.

## Requirements

- Linux with systemd user services
- Node.js 18+ (or any runtime that can run the two packages below)
- OpenCode **v2** — v1 has no `--server` flag and fails silently
- A Telegram bot from [@BotFather](https://t.me/BotFather)

```bash
npm i -g opencode@2
npm i -g @grinev/opencode-telegram-bot
```

Check the paths the install produced; the setup script needs absolute paths
because systemd does not read your shell profile.

```bash
command -v opencode opencode-telegram
```

## Setup

```bash
git clone https://github.com/phamTuan207/opencode-telegram.git
cd opencode-telegram

# dry run: prints the plan, writes nothing
./setup.sh --project-dir ~/Work --port 4096

# real run
./setup.sh --project-dir ~/Work --port 4096 --install
```

The script checks prerequisites, generates a random server password, writes
`~/.config/opencode-telegram-bot/.env` with mode `600`, installs four systemd
user units plus three helper scripts, and enables the services.

Useful flags:

| Flag | Meaning |
|---|---|
| `--project-dir` | Directory the agent works in. Becomes the server's `WorkingDirectory`. |
| `--port` | Server port. Default `4096`. |
| `--opencode-bin` / `--telegram-bin` | Absolute paths, when not on `PATH`. |
| `--install` | Actually write. Without it the run is a dry run. |

### Two values you must fill in

`setup.sh` cannot know these. Open the env file it created:

```bash
${EDITOR:-nano} ~/.config/opencode-telegram-bot/.env
```

| Value | Where to get it |
|---|---|
| `TELEGRAM_BOT_TOKEN` | [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_ALLOWED_USER_ID` | Message the bot once, then read the id from `journalctl --user -u opencode-telegram -f` |

`TELEGRAM_ALLOWED_USER_ID` is the only thing stopping anyone else from driving
your agent. Do not leave it empty.

```bash
systemctl --user restart opencode-telegram
```

### Open a Live window

```bash
~/.local/bin/opencode-live ~/Work
```

Hyprland keybind, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + SHIFT + Z", "OpenCode",
  "~/.local/bin/opencode-live " .. vim.fn.expand("~") .. "/Work")
hyprctl reload && hyprctl configerrors
```

Point it at any launch site you like — keybind, desktop menu, terminal alias —
but have them all call the wrapper script. The wrapper is the only place that
knows the secret, so patching one site leaves the others broken.

## Verify

```bash
# 1. server answers
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $(grep -oP '^OPENCODE_SERVER_PASSWORD=\K.*' ~/.config/opencode-telegram-bot/.env)" \
  http://127.0.0.1:4096/api/session          # expect 200

# 2. which session the bot is following
journalctl --user -u opencode-telegram | grep Attach | tail -3

# 3. it matches the pinned session
jq -r .currentSession.id ~/.config/opencode-telegram-bot/settings.json
```

If the ids in steps 2 and 3 match, Telegram and the desktop window are the same
conversation.

## Troubleshooting

### The Live window opens and immediately disappears

The server sets `OPENCODE_SERVER_PASSWORD`; the v2 client wants that same value
under a different name, `OPENCODE_PASSWORD`. Without it the client exits before
drawing anything:

```
Error: Server at http://127.0.0.1:4096 requires a password; set OPENCODE_PASSWORD
```

Use `opencode-live`. It reads the secret from the env file and exports it under
the name the client expects.

### Do not "clean up" the server password

Removing `OPENCODE_SERVER_PASSWORD` from the unit does not make the server open.
OpenCode always requires auth; with the variable unset it invents a random
password and prints it, which no client can discover in advance.

### The bot stopped reacting, but it is running

Its event-stream subscription has no timeout. When the server flaps, that
request hangs forever: the process is alive, Telegram polling works, no events
ever arrive.

The watchdog timer checks two things that can actually be proven — is the unit
running, and does the bot hold a socket to the server port:

```bash
systemctl --user list-timers | grep watchdog
journalctl --user -u opencode-telegram-watchdog.service
```

**Never probe liveness with `getUpdates`.** Every call makes Telegram terminate
whatever long poll the bot is holding, so the probe kills the process it is
inspecting.

### 401 Unauthorized from Telegram

The token was retyped from somewhere instead of read from the file. Two copies
differing by one character is the usual cause. Read it:

```bash
TOKEN=$(grep -oP '^TELEGRAM_BOT_TOKEN=\K.*' ~/.config/opencode-telegram-bot/.env)
```

### Older sessions missing from the "current directory" view

Sessions migrated from OpenCode v1 stored `session.path` with no leading slash.
v2 reads that column as a path *relative to the project directory*, so the
effective working directory becomes doubled up and matches no filter. Sessions
are not lost.

```sql
-- back up opencode.db first
UPDATE session_v2 SET path=NULL WHERE path<>'' AND path <> '/'||path;
UPDATE session    SET path=NULL WHERE path<>'' AND path <> '/'||path;
```

Then `systemctl --user restart opencode-serve`.

## Layout of what gets installed

```
~/.config/systemd/user/
  opencode-serve.service                  opencode serve --port 4096
  opencode-telegram.service               the bot
  opencode-telegram-watchdog.service      oneshot restart check
  opencode-telegram-watchdog.timer        every 4 minutes
~/.local/bin/
  opencode-live                           TUI client wrapper
  wait-net-tg.sh                          blocks start until Telegram is reachable
  opencode-telegram-watchdog.sh           the restart check
~/.config/opencode-telegram-bot/
  .env                                    secrets, mode 600
  settings.json                           current session, pinned message id
```

## Uninstall

```bash
systemctl --user disable --now opencode-telegram opencode-serve \
  opencode-telegram-watchdog.timer
rm ~/.config/systemd/user/{opencode-serve,opencode-telegram,opencode-telegram-watchdog}.{service,timer}
systemctl --user daemon-reload
rm ~/.local/bin/{opencode-live,wait-net-tg.sh,opencode-telegram-watchdog.sh}
```

Your session history lives in `~/.local/share/opencode/opencode.db` and is not
touched by this.

## License

MIT