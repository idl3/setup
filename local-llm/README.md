# Local Qwen3.6 + Hermes Agent setup

Reproduces the stack we built: Apple-Silicon Mac running `llama.cpp` serving Qwen3.6-35B-A3B (Q3_K_XL quant) on `:8001`, with Hermes Agent using it as its primary model and bridging Slack via Socket Mode.

## Prerequisites

- macOS 13+ on Apple Silicon (M1–M4)
- ≥24 GB unified RAM (16 GB will swap heavily)
- ~25 GB free disk
- Homebrew installed
- Python 3.11+ (for Hermes; usually picked up automatically)

## What you'll end up with

| Component | Where | Auto-starts |
|---|---|---|
| `llama-server` (Q3_K_XL @ 128K ctx, Metal) | `http://127.0.0.1:8001/v1` | yes (LaunchAgent) |
| Hermes Agent CLI | `~/.local/bin/hermes` | n/a |
| Hermes gateway (Slack/Telegram bridge) | background process | yes (launchd via `hermes gateway install`) |

---

## Phase 1 — Run setup.sh

```sh
cd ~/setup-local-llm
chmod +x setup.sh
./setup.sh
```

Phases the script runs:

1. **preflight** — checks RAM, disk, brew, arch
2. **deps** — `brew install llama.cpp huggingface-cli`
3. **model** — downloads `Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf` (~17 GB) with auto-resume on stalls
4. **metal** — informs about the optional Metal wired-memory cap (skip for Q3)
5. **service** — installs the LaunchAgent, starts llama-server, smoke-tests `:8001/v1/models`
6. **hermes** — patches `~/.hermes/config.yaml` to point at the local server

You can re-run individual phases: `./setup.sh model`, `./setup.sh service`, etc.

### Why Q3 and not Q4/Q5?

We tried both — on a 24 GB Mac, Metal can't fit Q4_K_XL's 22.4 GB weights + KV cache + compute graph even with `iogpu.wired_limit_mb` raised. Q5_K_M doesn't fit at all. Q3_K_XL gets ~92% of Q4's quality at half the headache. Bigger Macs (≥36 GB) can comfortably run Q4_K_XL.

### Why direct curl instead of `hf` CLI?

The HuggingFace CLI was throttled to ~1 MB/s on our test (rate-limited unauthenticated tier). Plain curl pulled at ~25 MB/s. The script uses `--speed-limit / --speed-time` so it auto-aborts and retries if the connection silently dies (which we observed mid-download).

---

## Phase 2 — Install Hermes (if not already installed)

```sh
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
source ~/.zshrc   # or ~/.bashrc
hermes --version
```

If Hermes was just installed, run `hermes setup` once to create `~/.hermes/config.yaml`, then re-run `./setup.sh hermes` to point it at your local server.

---

## Phase 3 — Slack integration (manual, ~10 min)

Hermes uses Slack **Socket Mode** so you don't need a tunnel (ngrok/cloudflared). The Mac initiates an outbound WebSocket; Slack pushes events down it.

### 3a. Generate the manifest

```sh
hermes slack manifest --write
# → ~/.hermes/slack-manifest.json
pbcopy < ~/.hermes/slack-manifest.json
```

### 3b. Create the Slack app

1. https://api.slack.com/apps → **Create New App** → **From an app manifest**
2. Pick your workspace
3. Paste the manifest, click Next, Create

### 3c. Generate the App-Level Token (xapp-)

1. **Settings → Socket Mode** → toggle **On**
2. **Settings → Basic Information → App-Level Tokens** → **Generate Token and Scopes**
   - Name: `hermes-socket`
   - Scope: `connections:write`
   - Save the `xapp-...` token

### 3d. Install to workspace, get Bot Token (xoxb-)

1. **Settings → Install App** → **Install to Workspace** → Allow
2. Copy the **Bot User OAuth Token** (`xoxb-...`)

### 3e. Enable the Messages Tab

This is **not** set by the manifest and breaks DMs if missed:

1. **Features → App Home**
2. Under **Show Tabs**, toggle **Messages Tab** to **On**
3. Check ✅ **Allow users to send Slash commands and messages from the messages tab**

### 3f. Get your Slack member ID

In Slack → click your avatar → View full profile → ⋮ → Copy member ID. Format `U01ABC2DEF3`.

### 3g. Write tokens into `~/.hermes/.env`

```sh
cat >> ~/.hermes/.env <<EOF
SLACK_BOT_TOKEN=xoxb-…
SLACK_APP_TOKEN=xapp-…
SLACK_ALLOWED_USERS=U…
EOF
chmod 600 ~/.hermes/.env
```

For multiple workspaces, comma-separate the bot tokens:
```
SLACK_BOT_TOKEN=xoxb-workspace1,xoxb-workspace2
SLACK_APP_TOKEN=xapp-…   # one App-Level Token works across all installs of the same app
```

### 3h. Install the gateway as a launchd service

```sh
hermes gateway install
hermes gateway start
hermes gateway status
```

### 3i. Set the home channel

DM `@<your-bot>` in Slack and send:

```
/hermes sethome
```

Hermes writes the DM channel ID to `.env` as `SLACK_HOME_CHANNEL`. From now on cron output, scheduled tasks, and proactive messages land here.

---

## Verifying everything

```sh
# llama-server
curl -s http://127.0.0.1:8001/v1/models | python3 -m json.tool | head

# Hermes config
hermes doctor

# One-shot inference through Hermes (~30-60s on first call)
hermes -z "What's 17 squared?"

# Gateway status
hermes gateway status
tail -f ~/.hermes/logs/gateway.log
```

---

## Troubleshooting

### `Insufficient Memory (kIOGPUCommandBufferCallbackErrorOutOfMemory)`
You're hitting Metal's wired-memory cap. Either drop the quant (Q3_K_XL is the sweet spot for 24 GB) or bump `sudo sysctl iogpu.wired_limit_mb=22000`. To persist across reboots, see "Persistent Metal cap" below.

### Bot connected but doesn't respond
Slack events aren't reaching Hermes. Check, in order:
1. **Event Subscriptions** is **On** (UI page, with Socket Mode it should not require a Request URL)
2. Bot events list contains `app_mention`, `message.im`, `message.channels`, `message.groups`
3. App was **reinstalled** after any scope/event change — old token = old permissions
4. `hermes gateway restart` to re-open the WebSocket

Live tail to see events arriving:
```sh
tail -F ~/.hermes/logs/gateway.log
```

### DMs to the bot don't go through
**App Home → Messages Tab** is not toggled on. The manifest doesn't set it; you have to flip it manually.

### `hf download` is very slow
Use plain `curl` against `https://huggingface.co/<org>/<repo>/resolve/main/<file>` — 10–30× faster than the CLI on unauthenticated downloads. Add `--speed-limit / --speed-time` to auto-abort silent stalls.

### Persistent Metal cap (across reboots)

macOS doesn't read `/etc/sysctl.conf` reliably; create a LaunchDaemon:

```sh
sudo tee /Library/LaunchDaemons/local.iogpu-wired-limit.plist >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>local.iogpu-wired-limit</string>
  <key>RunAtLoad</key>        <true/>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/sbin/sysctl</string>
    <string>iogpu.wired_limit_mb=22000</string>
  </array>
</dict>
</plist>
EOF
sudo launchctl load -w /Library/LaunchDaemons/local.iogpu-wired-limit.plist
```

---

## Files this setup creates

| File | Purpose |
|---|---|
| `~/models/Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf` | model weights (~17 GB) |
| `~/Library/LaunchAgents/local.llama-server.plist` | LaunchAgent for llama-server auto-start |
| `~/.hermes/config.yaml` | Hermes config (we edit only the `model:` block) |
| `~/.hermes/.env` | Slack tokens, allowlists, home channel |
| `~/.hermes/slack-manifest.json` | generated by `hermes slack manifest --write` |

## Useful commands afterwards

```sh
# Restart the local server
launchctl unload ~/Library/LaunchAgents/local.llama-server.plist && \
launchctl load   ~/Library/LaunchAgents/local.llama-server.plist

# Tail llama-server logs
tail -f /tmp/llama-server.log

# Stop the local server
launchctl unload ~/Library/LaunchAgents/local.llama-server.plist

# Restart Hermes gateway after config changes
hermes gateway restart
```
