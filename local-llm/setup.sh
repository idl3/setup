#!/usr/bin/env bash
# setup.sh — install llama.cpp + Qwen3.6-35B-A3B (Q3_K_XL) + Hermes Agent on a fresh
# macOS Apple Silicon machine. Re-runnable; each phase is idempotent.
#
# Usage:  ./setup.sh           # run everything
#         ./setup.sh deps      # just install brew packages
#         ./setup.sh model     # just download the model
#         ./setup.sh service   # just install the launchd service
#         ./setup.sh hermes    # just configure Hermes (assumes Hermes is already installed)
#
# Manual steps are listed in README.md (Slack app creation, tokens, etc.).

set -euo pipefail

MODEL_FILE="$HOME/models/Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf"
MODEL_URL="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf"
MODEL_MIN_BYTES=16500000000   # 16.5 GB; full file is ~16.8 GB
PORT=8001
ALIAS="qwen3.6-35b-a3b"
PLIST_LABEL="local.llama-server"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

log() { printf "\n\033[1;36m▶ %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m! %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; }

phase_preflight() {
  log "Preflight checks"
  [ "$(uname)" = "Darwin" ] || { err "macOS only."; exit 1; }
  [ "$(uname -m)" = "arm64" ] || warn "Not Apple Silicon — Metal acceleration won't apply."
  command -v brew >/dev/null || { err "Homebrew not installed. https://brew.sh"; exit 1; }

  ram_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  echo "  RAM: ${ram_gb} GB"
  if [ "$ram_gb" -lt 24 ]; then
    warn "Less than 24 GB RAM — Q3_K_XL may swap heavily."
  fi

  free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
  echo "  Free disk in \$HOME: ${free_gb} GB"
  [ "$free_gb" -lt 25 ] && { err "Need ≥25 GB free for the model."; exit 1; }
}

phase_deps() {
  log "Install brew packages (llama.cpp, hf CLI)"
  brew install --quiet llama.cpp huggingface-cli || true
  command -v llama-server >/dev/null || { err "llama-server missing after install."; exit 1; }
  echo "  llama-server: $(which llama-server)"
}

phase_model() {
  log "Download model (~17 GB) with resilient resume-on-stall"
  mkdir -p "$(dirname "$MODEL_FILE")"

  cur=$(stat -f%z "$MODEL_FILE" 2>/dev/null || echo 0)
  if [ "$cur" -ge "$MODEL_MIN_BYTES" ]; then
    echo "  Already downloaded ($((cur/1024/1024)) MB)."
    return
  fi

  attempt=0
  while true; do
    attempt=$((attempt+1))
    echo "  attempt $attempt @ $(date +%H:%M:%S)"
    # --speed-limit/--speed-time abort if throughput drops below 200 KB/s for 30s
    # --retry handles transient errors; -C - resumes from current file size
    curl -L --fail -C - \
      --connect-timeout 30 \
      --speed-limit 200000 --speed-time 30 \
      --retry 20 --retry-delay 5 --retry-all-errors \
      -o "$MODEL_FILE" "$MODEL_URL" || true

    cur=$(stat -f%z "$MODEL_FILE" 2>/dev/null || echo 0)
    if [ "$cur" -ge "$MODEL_MIN_BYTES" ]; then
      echo "  Done: $((cur/1024/1024)) MB"
      return
    fi
    [ "$attempt" -ge 30 ] && { err "Giving up after 30 attempts."; exit 1; }
    sleep 5
  done
}

phase_metal_cap() {
  log "Metal wired-memory cap (optional — only needed for Q4+ quants)"
  current=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
  echo "  iogpu.wired_limit_mb is currently: $current"
  echo "  Q3_K_XL runs fine at the default. Skip unless you plan to test Q4_K_XL or larger."
  echo "  To bump (one-shot, reverts at reboot):  sudo sysctl iogpu.wired_limit_mb=22000"
  echo "  To persist across reboots, create a LaunchDaemon — see README.md."
}

phase_service() {
  log "Install llama-server as a launchd user agent (auto-starts at login)"

  if [ -f "$PLIST_PATH" ]; then
    echo "  Existing plist at $PLIST_PATH — unloading first"
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
  fi

  mkdir -p "$(dirname "$PLIST_PATH")"
  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>${PLIST_LABEL}</string>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardOutPath</key>  <string>/tmp/llama-server.log</string>
  <key>StandardErrorPath</key><string>/tmp/llama-server.log</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(which llama-server)</string>
    <string>--model</string>          <string>${MODEL_FILE}</string>
    <string>--port</string>           <string>${PORT}</string>
    <string>--alias</string>          <string>${ALIAS}</string>
    <string>-np</string>              <string>1</string>
    <string>-c</string>               <string>131072</string>
    <string>-n</string>               <string>32768</string>
    <string>--no-context-shift</string>
    <string>--temp</string>           <string>0.6</string>
    <string>--top-p</string>          <string>0.95</string>
    <string>--top-k</string>          <string>20</string>
    <string>--repeat-penalty</string> <string>1.00</string>
    <string>--presence-penalty</string><string>0.00</string>
    <string>--fit</string>            <string>on</string>
    <string>-fa</string>              <string>on</string>
    <string>-ctk</string>             <string>q8_0</string>
    <string>-ctv</string>             <string>q8_0</string>
    <string>-ub</string>              <string>256</string>
    <string>--chat-template-kwargs</string>
    <string>{"preserve_thinking": true}</string>
  </array>
</dict>
</plist>
PLIST

  launchctl load -w "$PLIST_PATH"
  sleep 6
  if curl -fsS "http://127.0.0.1:${PORT}/v1/models" >/dev/null; then
    echo "  ✓ llama-server up on http://127.0.0.1:${PORT}/v1"
  else
    warn "Server not responding yet. tail -f /tmp/llama-server.log to watch it warm up."
  fi
}

phase_hermes() {
  log "Configure Hermes to use the local llama-server"
  command -v hermes >/dev/null || {
    err "hermes not installed. Run:"
    err "  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"
    exit 1
  }

  CFG="$HOME/.hermes/config.yaml"
  [ -f "$CFG" ] || { err "$CFG not found. Run \`hermes setup\` once first."; exit 1; }

  cp "$CFG" "${CFG}.bak.$(date +%Y%m%d-%H%M%S)"
  echo "  Backup at ${CFG}.bak.$(date +%Y%m%d-%H%M%S)"

  python3 <<PY
import re, pathlib, sys
p = pathlib.Path("$CFG")
src = p.read_text()
new_block = """model:
  default: ${ALIAS}
  provider: custom
  base_url: http://127.0.0.1:${PORT}/v1
  api_key: local
  context_length: 131072
"""
# replace from 'model:' up to the next top-level key (line starting with non-space)
out = re.sub(r"^model:\n(?:[ \t].*\n)+", new_block, src, count=1, flags=re.M)
if out == src:
    sys.exit("could not locate 'model:' block in config.yaml")
p.write_text(out)
print("  ✓ Replaced model: block")
PY

  echo "  Validating with hermes doctor..."
  hermes doctor 2>&1 | grep -E "(✓|⚠|✗).*(API key|config\.yaml|Custom endpoint|Configuration)" || true

  echo "  Smoke test (this can take ~60s on first call due to system prompt size)..."
  if hermes -z "Reply with exactly: hello world" 2>/dev/null | grep -qi "hello world"; then
    echo "  ✓ Hermes is talking to the local model"
  else
    warn "Smoke test didn't return 'hello world'. Check llama-server log."
  fi
}

phase_summary() {
  log "Done. Manual steps remaining (Slack):"
  cat <<'EOF'
  1. hermes slack manifest --write
  2. https://api.slack.com/apps  →  Create New App → From an app manifest → paste ~/.hermes/slack-manifest.json
  3. Enable Socket Mode (Settings → Socket Mode), generate App-Level Token (xapp-)
  4. Install App → copy Bot Token (xoxb-)
  5. Features → App Home → toggle "Messages Tab" ON  (NOT in the manifest — must do manually)
  6. Add to ~/.hermes/.env:
       SLACK_BOT_TOKEN=xoxb-...
       SLACK_APP_TOKEN=xapp-...
       SLACK_ALLOWED_USERS=U...           (your Slack member ID)
  7. hermes gateway install   # registers launchd service
  8. hermes gateway start
  9. DM the bot in Slack, send "/hermes sethome"

  See README.md for the full Slack walkthrough.
EOF
}

case "${1:-all}" in
  preflight) phase_preflight ;;
  deps)      phase_deps ;;
  model)     phase_model ;;
  metal)     phase_metal_cap ;;
  service)   phase_service ;;
  hermes)    phase_hermes ;;
  summary)   phase_summary ;;
  all)
    phase_preflight
    phase_deps
    phase_model
    phase_metal_cap
    phase_service
    phase_hermes
    phase_summary
    ;;
  *) err "unknown phase: $1"; exit 1 ;;
esac
