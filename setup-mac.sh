#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  setup-mac.sh — Modern macOS dev shell bootstrap
# ─────────────────────────────────────────────────────────────────────────────
#  What this installs:
#    • Homebrew (if missing)
#    • tmux (latest), fzf, starship, reattach-to-user-namespace
#    • JetBrains Mono Nerd Font
#    • oh-my-zsh + plugins (tmux, fzf, autosuggestions, syntax-highlighting)
#    • oh-my-tmux (gpakosz/.tmux) + TPM + 8 AI/agentic-workflow plugins
#    • Dracula-themed Starship prompt
#    • Ghostty terminal config (font + Dracula theme)
#    • Sourced secrets pattern (~/.config/secrets.env, never committed)
#
#  Design goals:
#    1. Idempotent — safe to re-run any number of times
#    2. Non-destructive — backs up existing dotfiles before replacing
#    3. Self-contained — no external repo needed; all configs are inline
#    4. Secret-safe — writes a *.example template, never real tokens
#
#  Usage:
#    chmod +x setup-mac.sh && ./setup-mac.sh
#
#  Tested on: macOS 14+ (Sonoma/Sequoia), Apple Silicon and Intel
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ─── Colors & logging ────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

log()  { printf "${C_BLUE}${C_BOLD}▸${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}  ✓${C_RESET} %s\n" "$*"; }
skip() { printf "${C_DIM}  ↷ %s (already done)${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}  ⚠ %s${C_RESET}\n" "$*"; }
die()  { printf "${C_RED}  ✗ %s${C_RESET}\n" "$*" >&2; exit 1; }

backup() {
  local f=$1
  if [[ -e $f && ! -L $f ]]; then
    local b="${f}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$f" "$b"
    ok "backed up $f → $b"
  fi
}

TS=$(date +%Y%m%d-%H%M%S)

# ─── Pre-flight ──────────────────────────────────────────────────────────────
log "Pre-flight checks"
[[ "$(uname)" == "Darwin" ]] || die "This script is macOS-only."
ARCH=$(uname -m)
ok "macOS detected (arch: $ARCH)"

# ─── Phase 1: Homebrew ───────────────────────────────────────────────────────
log "Phase 1 — Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew not found — installing"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ "$ARCH" == "arm64" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/usr/local/bin/brew shellenv)"
  fi
else
  skip "Homebrew installed ($(brew --version | head -1))"
fi

# ─── Phase 2: brew bundle ────────────────────────────────────────────────────
log "Phase 2 — Installing packages via brew bundle"
brew bundle --file=- <<'BREWFILE'
# CLI tools
brew "tmux"
brew "fzf"
brew "starship"
brew "reattach-to-user-namespace"
brew "git"
brew "python@3.13"   # required for tmux-window-name plugin (libtmux)

# Fonts
cask "font-jetbrains-mono-nerd-font"
BREWFILE
ok "brew bundle complete"

# tmux-window-name plugin needs libtmux importable from python3
if ! python3 -c "import libtmux" >/dev/null 2>&1; then
  pip3 install --user --break-system-packages libtmux >/dev/null
  ok "installed libtmux (tmux-window-name dependency)"
else
  skip "libtmux"
fi

# fzf shell integration (idempotent — installer skips already-configured rc lines)
if [[ ! -f ~/.fzf.zsh ]]; then
  "$(brew --prefix)/opt/fzf/install" --key-bindings --completion --no-update-rc --no-fish >/dev/null
  ok "fzf shell integration installed"
else
  skip "fzf shell integration"
fi

# ─── Phase 3: oh-my-zsh ──────────────────────────────────────────────────────
log "Phase 3 — oh-my-zsh"
if [[ ! -d $HOME/.oh-my-zsh ]]; then
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
else
  skip "oh-my-zsh installed"
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
for plugin_repo in \
  "zsh-users/zsh-autosuggestions" \
  "zsh-users/zsh-syntax-highlighting"; do
  plugin_name=${plugin_repo##*/}
  dest="$ZSH_CUSTOM/plugins/$plugin_name"
  if [[ ! -d $dest ]]; then
    git clone --depth 1 "https://github.com/$plugin_repo" "$dest"
    ok "cloned $plugin_name"
  else
    skip "$plugin_name"
  fi
done

# ─── Phase 4: oh-my-tmux + TPM ───────────────────────────────────────────────
log "Phase 4 — oh-my-tmux + TPM"
if [[ ! -d $HOME/.tmux ]]; then
  git clone --depth 1 https://github.com/gpakosz/.tmux.git "$HOME/.tmux"
  ok "cloned gpakosz/.tmux"
else
  skip "oh-my-tmux clone"
fi

backup "$HOME/.tmux.conf"
ln -sf "$HOME/.tmux/.tmux.conf" "$HOME/.tmux.conf"
ok "symlinked ~/.tmux.conf → ~/.tmux/.tmux.conf"

if [[ ! -d $HOME/.tmux/plugins/tpm ]]; then
  git clone --depth 1 https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
  ok "cloned TPM"
else
  skip "TPM"
fi

# ─── Phase 5: ~/.tmux.conf.local ─────────────────────────────────────────────
log "Phase 5 — ~/.tmux.conf.local (Dracula + AI plugins)"
backup "$HOME/.tmux.conf.local"
cp "$HOME/.tmux/.tmux.conf.local" "$HOME/.tmux.conf.local"

# Patch oh-my-tmux defaults: 24-bit color, OS clipboard, Dracula palette,
# disable secondary C-a prefix, vi mode, history, plugins block.
python3 - "$HOME/.tmux.conf.local" <<'PYEOF'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()

# Toggle defaults
t = t.replace("tmux_conf_24b_colour=auto",         "tmux_conf_24b_colour=true")
t = t.replace("tmux_conf_copy_to_os_clipboard=false", "tmux_conf_copy_to_os_clipboard=true")

# Dracula palette overrides (replace whole block 1..17)
dracula = '''tmux_conf_theme_colour_1="#282a36"    # Dracula background
tmux_conf_theme_colour_2="#44475a"    # Dracula current line
tmux_conf_theme_colour_3="#6272a4"    # Dracula comment
tmux_conf_theme_colour_4="#bd93f9"    # Dracula purple (accent)
tmux_conf_theme_colour_5="#f1fa8c"    # Dracula yellow
tmux_conf_theme_colour_6="#282a36"    # Dracula background
tmux_conf_theme_colour_7="#f8f8f2"    # Dracula foreground
tmux_conf_theme_colour_8="#282a36"    # Dracula background
tmux_conf_theme_colour_9="#f1fa8c"    # Dracula yellow
tmux_conf_theme_colour_10="#ff79c6"   # Dracula pink
tmux_conf_theme_colour_11="#50fa7b"   # Dracula green
tmux_conf_theme_colour_12="#6272a4"   # Dracula comment
tmux_conf_theme_colour_13="#f8f8f2"   # Dracula foreground
tmux_conf_theme_colour_14="#282a36"   # Dracula background
tmux_conf_theme_colour_15="#282a36"   # Dracula background
tmux_conf_theme_colour_16="#ff5555"   # Dracula red
tmux_conf_theme_colour_17="#f8f8f2"   # Dracula foreground'''
t = re.sub(
    r'tmux_conf_theme_colour_1="#[0-9a-fA-F]+".*?tmux_conf_theme_colour_17="#[0-9a-fA-F]+".*?$',
    dracula, t, count=1, flags=re.DOTALL | re.MULTILINE)

# User customizations block (idempotent — only insert if marker not present)
user_block = '''# >>> bootstrap user customizations >>>
# Fix tmux server PATH so run-shell hooks find Homebrew's python3 (with libtmux)
# instead of Apple's /usr/bin/python3. Critical for tmux-window-name plugin.
set-environment -g PATH "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

set -g history-limit 50000
set -g mouse on
set -g status-keys vi
set -g mode-keys vi
set -sg escape-time 0
set -g focus-events on

# Prefix: Ctrl-q (single-hand, no shell/vim/CJK conflict; needs `stty -ixon` in shell)
set -gu prefix2
unbind C-a
unbind C-b
set -g prefix C-q
bind C-q send-prefix

# vim-style pane navigation
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# split panes (preserve cwd)
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# reload config
bind r source-file ~/.tmux.conf \\; display "Config reloaded"
# <<< bootstrap user customizations <<<
'''
if "bootstrap user customizations" not in t:
    t = t.replace("# this is the place to override or undo settings",
                  "# this is the place to override or undo settings\n\n" + user_block, 1)

# Plugin block (idempotent)
plugin_block = '''# >>> bootstrap plugins >>>
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-yank'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'ofirgall/tmux-window-name'
set -g @plugin 'sainnhe/tmux-fzf'
set -g @plugin 'laktak/extrakto'
set -g @plugin 'rickstaa/tmux-notify'

set -g @continuum-restore 'on'
set -g @continuum-save-interval '15'
set -g @resurrect-capture-pane-contents 'on'
set -g @resurrect-strategy-nvim 'session'

set -g @tnotify-verbose 'on'
set -g @tnotify-sleep-duration '4'

set -g @extrakto_key 'a'
set -g @extrakto_split_size '15'
set -g @extrakto_clip_tool 'pbcopy'

set-environment -g TMUX_FZF_LAUNCH_KEY 'g'
# <<< bootstrap plugins <<<
'''
if "bootstrap plugins" not in t:
    # insert before the "-- custom variables --" section
    anchor = "# -- custom variables --"
    if anchor in t:
        t = t.replace(anchor, plugin_block + "\n" + anchor, 1)
    else:
        t += "\n" + plugin_block

p.write_text(t)
print("patched")
PYEOF
ok "~/.tmux.conf.local patched"

# ─── Phase 6: ~/.zshrc additions (idempotent block) ──────────────────────────
log "Phase 6 — ~/.zshrc additions"
backup "$HOME/.zshrc"

ZSHRC="$HOME/.zshrc"
[[ -f $ZSHRC ]] || touch "$ZSHRC"

# Set ZSH_THEME="" so Starship can take over. Only change if currently a theme.
if grep -qE '^ZSH_THEME="[^"]*[^"]"' "$ZSHRC" && ! grep -qE '^ZSH_THEME=""' "$ZSHRC"; then
  sed -i.tmpbak -E 's/^ZSH_THEME="[^"]*"/ZSH_THEME=""  # Starship handles the prompt/' "$ZSHRC"
  rm -f "$ZSHRC.tmpbak"
  ok "ZSH_THEME set to empty"
else
  skip "ZSH_THEME already empty/unset"
fi

# Expand plugins=() if it's just (git) or empty
if grep -qE '^plugins=\(git\)' "$ZSHRC"; then
  sed -i.tmpbak -E 's/^plugins=\(git\)/plugins=(git tmux fzf zsh-autosuggestions zsh-syntax-highlighting)/' "$ZSHRC"
  rm -f "$ZSHRC.tmpbak"
  ok "expanded oh-my-zsh plugins"
else
  skip "plugins= line already customized (manual review recommended)"
fi

# Append init block between markers (idempotent)
if ! grep -q "bootstrap-shell-init-start" "$ZSHRC"; then
cat >> "$ZSHRC" <<'ZSHEOF'

# >>> bootstrap-shell-init-start >>>
# tmux plugin: always land in tmux on shell startup
# AUTOSTART_ONCE prevents re-spawn when you exit tmux; AUTOCONNECT attaches to
# existing session instead of creating duplicates; AUTOQUIT=false keeps the
# shell alive after detach so the terminal doesn't close.
ZSH_TMUX_AUTOSTART=true
ZSH_TMUX_AUTOSTART_ONCE=true
ZSH_TMUX_AUTOCONNECT=false   # each new tab spawns its own tmux session (not shared)
ZSH_TMUX_AUTOQUIT=false
ZSH_TMUX_FIXTERM=true

# Disable terminal flow control (frees Ctrl-Q as tmux prefix, Ctrl-S for fwd history search)
[[ $- == *i* ]] && stty -ixon 2>/dev/null

# Local secrets (sourced if file exists; chmod 600)
[ -f ~/.config/secrets.env ] && source ~/.config/secrets.env

# Starship prompt
command -v starship >/dev/null && eval "$(starship init zsh)"

# fzf keybindings + completions
command -v fzf >/dev/null && source <(fzf --zsh)
# <<< bootstrap-shell-init-end <<<
ZSHEOF
  ok "appended shell-init block"
else
  skip "shell-init block already present"
fi

# ─── Phase 7: Starship config (Dracula) ──────────────────────────────────────
log "Phase 7 — Starship config (Dracula)"
mkdir -p "$HOME/.config"
backup "$HOME/.config/starship.toml"
cat > "$HOME/.config/starship.toml" <<'STARSHIP_EOF'
# Starship prompt — Dracula palette
# Docs: https://starship.rs/config/

format = """
[╭─](fg:comment)$os$username$hostname$directory$git_branch$git_status$git_state$cmd_duration$jobs
[╰─](fg:comment)$character"""

add_newline = true
command_timeout = 1500
palette = "dracula"

[palettes.dracula]
bg = "#282a36"
current = "#44475a"
fg = "#f8f8f2"
comment = "#6272a4"
cyan = "#8be9fd"
green = "#50fa7b"
orange = "#ffb86c"
pink = "#ff79c6"
purple = "#bd93f9"
red = "#ff5555"
yellow = "#f1fa8c"

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
vimcmd_symbol = "[❮](bold purple)"

[username]
style_user = "bold pink"
style_root = "bold red"
format = "[$user]($style)[@](fg:comment)"
show_always = false

[hostname]
ssh_only = true
format = "[$hostname](bold orange)[ in ](fg:comment)"

[directory]
style = "bold cyan"
truncation_length = 4
truncation_symbol = "…/"
truncate_to_repo = true
read_only = " "
format = "[$path]($style)[$read_only](fg:red) "

[directory.substitutions]
"~/Projects" = " "
"Documents" = "󰈙 "

[git_branch]
symbol = " "
style = "bold purple"
format = "[on ](fg:comment)[$symbol$branch]($style) "

[git_status]
style = "bold yellow"
format = "[$all_status$ahead_behind]($style) "
ahead = "↑${count} "
behind = "↓${count} "
diverged = "↕↑${ahead_count}↓${behind_count} "
conflicted = " ${count} "
untracked = "?${count} "
modified = "!${count} "
staged = "+${count} "
renamed = "»${count} "
deleted = "✘${count} "
stashed = "≡${count} "

[cmd_duration]
min_time = 2000
format = "[took $duration](fg:orange) "

[jobs]
symbol = "✦ "
style = "bold purple"
number_threshold = 1
symbol_threshold = 1

[os]
disabled = false
format = "[$symbol]($style)"
style = "bold purple"

[os.symbols]
Macos = " "

[aws]
disabled = true
[gcloud]
disabled = true
[kubernetes]
disabled = true
[docker_context]
disabled = true
[package]
disabled = true
[python]
disabled = true
[nodejs]
disabled = true
[rust]
disabled = true
[golang]
disabled = true
STARSHIP_EOF
ok "wrote ~/.config/starship.toml"

# ─── Phase 8: Ghostty config ─────────────────────────────────────────────────
log "Phase 8 — Ghostty config"
mkdir -p "$HOME/.config/ghostty"
backup "$HOME/.config/ghostty/config"
cat > "$HOME/.config/ghostty/config" <<'GHOSTTY_EOF'
# Ghostty terminal config
# Docs: https://ghostty.org/docs/config

# Font
font-family = "JetBrainsMono Nerd Font"
font-size = 14
font-thicken = true
adjust-cell-height = 10%

# Theme
theme = Dracula

# Window
window-padding-x = 12
window-padding-y = 8
window-padding-balance = true
window-decoration = true
macos-titlebar-style = transparent
background-opacity = 0.97
background-blur-radius = 20

# Behavior
copy-on-select = clipboard
mouse-hide-while-typing = true
confirm-close-surface = false
shell-integration = zsh
shell-integration-features = cursor,sudo,title

# Cursor
cursor-style = bar
cursor-style-blink = true

# Scrollback
scrollback-limit = 100000

# Keybinds (Cmd-based, no tmux conflict)
keybind = cmd+t=new_tab
keybind = cmd+w=close_surface
keybind = cmd+d=new_split:right
keybind = cmd+shift+d=new_split:down
GHOSTTY_EOF

# Mirror to macOS app-support path so Ghostty finds it regardless
APP_SUPPORT="$HOME/Library/Application Support/com.mitchellh.ghostty"
mkdir -p "$APP_SUPPORT"
backup "$APP_SUPPORT/config"
cp "$HOME/.config/ghostty/config" "$APP_SUPPORT/config"
ok "wrote Ghostty config (XDG + app-support)"

# ─── Phase 9: secrets.env template ───────────────────────────────────────────
log "Phase 9 — secrets.env template (NEVER commit real tokens)"
if [[ ! -f $HOME/.config/secrets.env.example ]]; then
  cat > "$HOME/.config/secrets.env.example" <<'SECRETS_EOF'
# Local secrets — sourced by ~/.zshrc.
# Copy to ~/.config/secrets.env and chmod 600.
# DO NOT COMMIT this file or its real-token sibling.

# export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# export OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# export ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
SECRETS_EOF
  chmod 600 "$HOME/.config/secrets.env.example"
  ok "wrote ~/.config/secrets.env.example"
else
  skip "secrets.env.example already exists"
fi

if [[ ! -f $HOME/.config/secrets.env ]]; then
  warn "~/.config/secrets.env not found — copy from .example and add real tokens:"
  warn "    cp ~/.config/secrets.env.example ~/.config/secrets.env && chmod 600 ~/.config/secrets.env"
else
  current_mode=$(stat -f "%OLp" "$HOME/.config/secrets.env" 2>/dev/null || stat -c "%a" "$HOME/.config/secrets.env")
  if [[ $current_mode != "600" ]]; then
    chmod 600 "$HOME/.config/secrets.env"
    ok "tightened ~/.config/secrets.env to mode 600"
  else
    skip "~/.config/secrets.env already mode 600"
  fi
fi

# ─── Phase 10: bootstrap tmux + install plugins headless ─────────────────────
log "Phase 10 — Install tmux plugins headless"
# Kill any pre-existing server so the new conf takes effect cleanly
tmux kill-server 2>/dev/null || true
sleep 1
tmux new-session -d -s _bootstrap -x 200 -y 50
sleep 2
"$HOME/.tmux/plugins/tpm/scripts/install_plugins.sh" >/dev/null 2>&1 || warn "TPM install reported issues — run 'prefix + I' inside tmux to retry"
ok "tmux plugins installed"
tmux kill-session -t _bootstrap 2>/dev/null || true

# ─── Final summary ───────────────────────────────────────────────────────────
log "Setup complete"
cat <<EOF

  ${C_BOLD}Installed:${C_RESET}
    tmux $(tmux -V 2>/dev/null | awk '{print $2}')
    starship $(starship --version 2>/dev/null | awk '{print $2}')
    fzf $(fzf --version 2>/dev/null | awk '{print $1}')

  ${C_BOLD}Next steps:${C_RESET}
    1. ${C_BOLD}Quit and reopen Ghostty${C_RESET} to load the new font + Dracula theme.
    2. If you have secrets to set up:
         cp ~/.config/secrets.env.example ~/.config/secrets.env
         chmod 600 ~/.config/secrets.env
         \$EDITOR ~/.config/secrets.env
    3. Inside tmux:  ${C_BOLD}prefix + a${C_RESET} = extrakto, ${C_BOLD}prefix + g${C_RESET} = fuzzy nav
    4. Backups for replaced files have suffix ${C_DIM}.bak.<timestamp>${C_RESET}

  ${C_BOLD}Idempotent:${C_RESET} re-run this script anytime — existing items are skipped.

EOF
