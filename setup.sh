#!/usr/bin/env bash
#
# RedTeam Agent — native installer for Kali/Debian Linux.
#
# One command to provision the agent runtime natively (no Docker needed): pentest
# toolchain, any of four AI CLIs (Claude Code / Codex / OpenCode / Ollama), MCP
# wiring, the Orchestrator web UI as a systemd service, and terminal aliases.
#
# Usage:
#   ./setup.sh                         interactive install (menu)
#   ./setup.sh install --cli all --orchestrator --yes
#   ./setup.sh install --cli claude,opencode
#   ./setup.sh reconfigure             add/enable more CLIs or the service later
#   ./setup.sh auth [claude|codex]     (re)run interactive authentication
#   ./setup.sh status                  show what is installed/configured
#   ./setup.sh uninstall               remove service + aliases, then optionally
#                                      the agent dir and the source directory
#   ./uninstall.sh                     standalone uninstaller (wraps the above)
#
# Flags (install / reconfigure):
#   --cli <list>       comma list of: claude,codex,opencode,ollama  (or 'all')
#   --orchestrator     install + enable the Orchestrator web UI systemd service
#   --no-orchestrator  skip the service
#   --agent-dir <dir>  agent runtime location (default: ~/redteam-agent)
#   --port <port>      orchestrator port (default: 18000)
#   --yes              non-interactive; accept defaults, skip prompts
#   --skip-tools       do not apt-install the pentest toolchain (assume present)
#   --skip-auth        do not run interactive auth at the end
#   --no-build-image   skip building the all-in-one Docker image (the UI needs it)
#
# Selecting the orchestrator also installs Docker and builds the all-in-one image
# (the web UI launches engagements as containers). Everything is automatic except
# Claude/Codex authentication, which pauses for your browser login then continues.
#
# Every install/uninstall run is logged to ./logs/<cmd>-<timestamp>.log (next to
# this script) so you can review exactly what happened.
#
# Only for authorized security testing. See README / SETUP.md.

set -uo pipefail

# ----------------------------------------------------------------------------
# Paths + constants
# ----------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/redteam"
CONF_FILE="$CONF_DIR/setup.conf"
ALIAS_MARKER_BEGIN="# >>> redteam-agent aliases >>>"
ALIAS_MARKER_END="# <<< redteam-agent aliases <<<"
DEFAULT_AGENT_DIR="$HOME/redteam-agent"
DEFAULT_PORT=18000
LOG_DIR="$REPO_DIR/logs"          # install/uninstall logs live next to setup.sh
LOG_FILE=""

# Defaults (overridable by flags / existing config)
CLIS=""
WANT_ORCH=""
AGENT_DIR="$DEFAULT_AGENT_DIR"
PORT="$DEFAULT_PORT"
ASSUME_YES=0
SKIP_TOOLS=0
SKIP_AUTH=0
BUILD_IMAGE=""
DOCKER="docker"

# ----------------------------------------------------------------------------
# Logging helpers
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;34m'; C_0='\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
info() { printf "${C_B}[*]${C_0} %s\n" "$*"; }
ok()   { printf "${C_G}[OK]${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_0} %s\n" "$*" >&2; }
err()  { printf "${C_R}[x]${C_0} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf "\n${C_B}=== %s ===${C_0}\n" "$*"; }

# Tee all further output to a timestamped plain-text log under $LOG_DIR so the
# install/uninstall run can be reviewed later (both logs sit next to setup.sh).
# Colours are disabled while logging so the file stays clean/readable.
start_logging() {
  local kind="${1:-setup}"
  mkdir -p "$LOG_DIR" 2>/dev/null || { warn "Cannot create log dir $LOG_DIR; continuing without a log file."; return 0; }
  LOG_FILE="$LOG_DIR/${kind}-$(date +%Y%m%d-%H%M%S).log"
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
  # Line-buffer the tee so the terminal and file stay in sync.
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Logging this run to $LOG_FILE"
}

SUDO=""
need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Need root or sudo to install system packages."
    SUDO="sudo"
  fi
}

# Run as the normal user — setup.sh uses sudo only where needed. Running the whole
# script under sudo would put auth tokens, aliases, the agent dir and ~/.claude in
# /root instead of your home. Warn (and offer to abort) in that case.
guard_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    warn "You are running setup.sh with sudo (as root)."
    warn "User files (Claude/Codex auth, aliases, $DEFAULT_AGENT_DIR, ~/.claude) would land in /root, not /home/$SUDO_USER."
    warn "Recommended: re-run WITHOUT sudo as your normal user — it will sudo only for apt/docker/npm."
    if [ "$ASSUME_YES" -eq 0 ]; then
      prompt_yes_no "Continue as root anyway?" n || die "Aborted. Re-run as: ./setup.sh"
    fi
  fi
}

# ----------------------------------------------------------------------------
# Config persistence (for reconfigure/status)
# ----------------------------------------------------------------------------
save_conf() {
  mkdir -p "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
# RedTeam Agent setup config — written by setup.sh
REDTEAM_CLIS="$CLIS"
REDTEAM_WANT_ORCH="$WANT_ORCH"
REDTEAM_AGENT_DIR="$AGENT_DIR"
REDTEAM_PORT="$PORT"
EOF
  ok "Saved configuration to $CONF_FILE"
}
load_conf() {
  [ -f "$CONF_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$CONF_FILE"
  [ -n "${REDTEAM_CLIS:-}" ]      && CLIS="$REDTEAM_CLIS"
  [ -n "${REDTEAM_WANT_ORCH:-}" ] && WANT_ORCH="$REDTEAM_WANT_ORCH"
  [ -n "${REDTEAM_AGENT_DIR:-}" ] && AGENT_DIR="$REDTEAM_AGENT_DIR"
  [ -n "${REDTEAM_PORT:-}" ]      && PORT="$REDTEAM_PORT"
}

has_cli() { case ",$CLIS," in *",$1,"*) return 0;; *) return 1;; esac; }

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
CMD="install"
case "${1:-}" in
  install|reconfigure|auth|status|uninstall|-h|--help) CMD="$1"; shift || true ;;
esac

AUTH_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cli)            CLIS="$2"; shift 2 ;;
    --orchestrator)   WANT_ORCH="yes"; shift ;;
    --no-orchestrator) WANT_ORCH="no"; shift ;;
    --agent-dir)      AGENT_DIR="$2"; shift 2 ;;
    --port)           PORT="$2"; shift 2 ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    --skip-tools)     SKIP_TOOLS=1; shift ;;
    --skip-auth)      SKIP_AUTH=1; shift ;;
    --no-build-image) BUILD_IMAGE="no"; shift ;;
    claude|codex)     AUTH_TARGET="$1"; shift ;;
    -h|--help)        CMD="--help"; shift ;;
    *) warn "Unknown argument: $1"; shift ;;
  esac
done

if [ "$CLIS" = "all" ]; then CLIS="claude,codex,opencode,ollama"; fi

print_help() {
  # Print the leading comment header (skip shebang), stop at the first code line.
  sed -n '2,/^set -uo pipefail/p' "$0" | sed '/^set -uo pipefail/d; s/^# \{0,1\}//'
}

# ----------------------------------------------------------------------------
# Interactive selection (when not --yes and nothing chosen)
# ----------------------------------------------------------------------------
prompt_yes_no() {
  local q="$1" def="${2:-y}" ans
  if [ "$ASSUME_YES" -eq 1 ]; then [ "$def" = "y" ] && return 0 || return 1; fi
  read -r -p "$q [$( [ "$def" = y ] && echo 'Y/n' || echo 'y/N' )]: " ans || true
  ans="${ans:-$def}"
  case "$ans" in [Yy]*) return 0;; *) return 1;; esac
}

interactive_select() {
  step "Choose AI CLIs to install"
  echo "You can install any combination. Reconfigure later with: ./setup.sh reconfigure"
  local sel=""
  prompt_yes_no "Install Claude Code (claude-mem + headroom + skills)?" y && sel="$sel,claude"
  prompt_yes_no "Install OpenCode?" y && sel="$sel,opencode"
  prompt_yes_no "Install Codex?" n && sel="$sel,codex"
  prompt_yes_no "Install Ollama (local models)?" n && sel="$sel,ollama"
  CLIS="${sel#,}"
  [ -n "$CLIS" ] || die "No CLI selected — nothing to do."
  if prompt_yes_no "Install the Orchestrator web UI as a systemd service?" y; then WANT_ORCH="yes"; else WANT_ORCH="no"; fi
  read -r -p "Agent runtime directory [$AGENT_DIR]: " a || true; AGENT_DIR="${a:-$AGENT_DIR}"
}

# ----------------------------------------------------------------------------
# System packages + pentest toolchain
# ----------------------------------------------------------------------------
install_system_deps() {
  step "System dependencies"
  need_sudo
  command -v apt-get >/dev/null 2>&1 || die "This installer targets Kali/Debian (apt-get not found)."
  info "Updating apt index..."
  $SUDO apt-get update -y >/dev/null 2>&1 || warn "apt-get update had warnings"

  # Core runtime deps the agent scripts require
  local core=(curl jq sqlite3 git ca-certificates python3 python3-venv python3-pip build-essential lsof unzip ripgrep whois dnsutils openssl netcat-openbsd procps)
  info "Installing core deps: ${core[*]}"
  $SUDO apt-get install -y --no-install-recommends "${core[@]}" >/dev/null 2>&1 \
    && ok "Core dependencies installed" || warn "Some core deps failed — continuing"

  if [ "$SKIP_TOOLS" -eq 1 ]; then
    warn "--skip-tools set; skipping pentest toolchain apt install"
  else
    # Pentest toolchain (Kali repos). Metasploit + seclists are large.
    local tools=(nmap nikto whatweb ffuf gobuster wfuzz dirb sqlmap hydra john hashcat dnsutils wordlists seclists)
    info "Installing pentest toolchain (this can take a while)..."
    $SUDO apt-get install -y --no-install-recommends "${tools[@]}" >/dev/null 2>&1 \
      && ok "Pentest toolchain installed" || warn "Some pentest tools failed — install individually later"
    # Metasploit is optional + heavy; best-effort.
    if prompt_yes_no "Install Metasploit Framework (large)?" y; then
      $SUDO apt-get install -y --no-install-recommends metasploit-framework >/dev/null 2>&1 \
        && ok "Metasploit installed" || warn "Metasploit install failed — add later with: apt install metasploit-framework"
    fi
    # ProjectDiscovery tools (nuclei/subfinder/katana) + mitmproxy
    install_pd_tools
    install_mitmproxy
  fi
}

install_pd_tools() {
  # Prefer apt; fall back to Go install if available.
  for t in nuclei subfinder katana; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t present"; continue; fi
    $SUDO apt-get install -y --no-install-recommends "$t" >/dev/null 2>&1 && { ok "$t (apt)"; continue; }
    if command -v go >/dev/null 2>&1; then
      case "$t" in
        nuclei)    GOBIN=/usr/local/bin $SUDO go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest >/dev/null 2>&1 ;;
        subfinder) GOBIN=/usr/local/bin $SUDO go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest >/dev/null 2>&1 ;;
        katana)    GOBIN=/usr/local/bin $SUDO go install github.com/projectdiscovery/katana/cmd/katana@latest >/dev/null 2>&1 ;;
      esac
      command -v "$t" >/dev/null 2>&1 && ok "$t (go)" || warn "$t not installed — add later"
    else
      warn "$t not installed (no apt pkg / no go) — add later"
    fi
  done
}

install_mitmproxy() {
  command -v mitmdump >/dev/null 2>&1 && { ok "mitmproxy present"; return; }
  info "Installing mitmproxy (pipx/venv)..."
  if command -v pipx >/dev/null 2>&1; then
    pipx install mitmproxy >/dev/null 2>&1 && { ok "mitmproxy (pipx)"; return; }
  fi
  python3 -m venv "$HOME/.redteam-mitmproxy" >/dev/null 2>&1 \
    && "$HOME/.redteam-mitmproxy/bin/pip" install -q --upgrade pip mitmproxy >/dev/null 2>&1 \
    && $SUDO ln -sf "$HOME/.redteam-mitmproxy/bin/mitmdump" /usr/local/bin/mitmdump \
    && $SUDO ln -sf "$HOME/.redteam-mitmproxy/bin/mitmproxy" /usr/local/bin/mitmproxy \
    && ok "mitmproxy (venv)" || warn "mitmproxy install failed — add later"
}

ensure_node() {
  step "Node.js"
  if command -v node >/dev/null 2>&1; then
    local v; v="$(node --version 2>/dev/null)"; ok "node present ($v)"; return
  fi
  info "Installing Node.js LTS via NodeSource..."
  need_sudo
  curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash - >/dev/null 2>&1 \
    && $SUDO apt-get install -y nodejs >/dev/null 2>&1 \
    && ok "node $(node --version)" || { warn "NodeSource failed, trying apt nodejs npm"; $SUDO apt-get install -y nodejs npm >/dev/null 2>&1 && ok "node (apt)" || die "Node.js install failed"; }
}

# ----------------------------------------------------------------------------
# AI CLI installers (npm global, with postinstall-script fix for npm>=12-as-root)
# ----------------------------------------------------------------------------
npm_global_with_postinstall() {
  # $1 = npm package, $2 = postinstall script filename inside the pkg, $3 = bin to verify
  # Global npm installs write to a root-owned prefix, so use sudo when not root.
  local pkg="$1" post="$2" bin="$3"
  $SUDO npm install -g "$pkg" >/dev/null 2>&1 || { warn "npm install -g $pkg failed"; return 1; }
  local root; root="$(npm root -g)/$pkg"
  if [ -n "$post" ] && [ -f "$root/$post" ]; then
    ( cd "$root" && $SUDO node "$post" ) >/dev/null 2>&1 || warn "$pkg postinstall ($post) reported an issue"
  fi
  command -v "$bin" >/dev/null 2>&1 && return 0 || return 1
}

install_claude() {
  step "Claude Code"
  if command -v claude >/dev/null 2>&1; then ok "claude present ($(claude --version 2>&1 | head -1))"; else
    npm_global_with_postinstall "@anthropic-ai/claude-code" "install.cjs" "claude" \
      && ok "claude $(claude --version 2>&1 | head -1)" || { warn "claude install failed"; return 1; }
  fi
  install_claude_extras
}

install_claude_extras() {
  # claude-mem plugin (best-effort via marketplace), context "headroom" settings, skills.
  info "Claude extras: claude-mem, context headroom, skills"
  # claude-mem: try the plugin marketplace flow; non-fatal.
  if claude plugin --help >/dev/null 2>&1; then
    claude plugin marketplace add claude-mem/claude-mem >/dev/null 2>&1 || true
    claude plugin install claude-mem >/dev/null 2>&1 \
      && ok "claude-mem installed" \
      || warn "claude-mem auto-install skipped (add later: claude plugin install claude-mem)"
  else
    warn "claude plugin subcommand unavailable — skipping claude-mem auto-install"
  fi
  # Context "headroom": configure autocompact + larger context handling in user settings.
  local cset="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  if command -v jq >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp)"
    if [ -f "$cset" ]; then cp "$cset" "$tmp"; else echo '{}' > "$tmp"; fi
    jq '. + {autoCompactEnabled: true, cleanupPeriodDays: 30}' "$tmp" > "$cset" 2>/dev/null \
      && ok "Context headroom configured (autoCompact on)" \
      || warn "Could not write $cset"
    rm -f "$tmp"
  fi
  # Skills: the agent's own skills install with the runtime (install.sh).
  ok "Agent skills install with the Claude runtime (install.sh claude)"
}

install_codex() {
  step "Codex"
  if command -v codex >/dev/null 2>&1; then ok "codex present ($(codex --version 2>&1 | head -1))"; return; fi
  $SUDO npm install -g @openai/codex >/dev/null 2>&1 \
    && command -v codex >/dev/null 2>&1 \
    && ok "codex $(codex --version 2>&1 | head -1)" || warn "codex install failed (npm i -g @openai/codex)"
}

install_opencode() {
  step "OpenCode"
  if command -v opencode >/dev/null 2>&1; then ok "opencode present"; return; fi
  npm_global_with_postinstall "opencode-ai" "postinstall.mjs" "opencode" \
    && ok "opencode $(opencode --version 2>&1 | head -1)" || warn "opencode install failed"
}

install_ollama() {
  step "Ollama"
  if command -v ollama >/dev/null 2>&1; then ok "ollama present ($(ollama --version 2>&1 | head -1))"; else
    info "Installing Ollama (official script)..."
    curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1 \
      && ok "ollama installed" || warn "ollama install failed (see https://ollama.com/download)"
  fi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "No NVIDIA GPU detected — local models will run on CPU (slow). Prefer a tool-capable model if you use Ollama."
  fi
}

# ----------------------------------------------------------------------------
# Agent runtime (reuses the repo's install.sh per CLI) — forces local mode
# ----------------------------------------------------------------------------
install_agent_runtime() {
  step "Agent runtime -> $AGENT_DIR"
  mkdir -p "$AGENT_DIR"
  local did=0
  for cli in claude opencode codex; do
    has_cli "$cli" || continue
    info "Generating $cli runtime..."
    # Skip install.sh's prereq checks: it unconditionally requires a running Docker
    # daemon even for non-docker products, which a native Kali install does not have.
    # setup.sh has already ensured the CLI + jq/sqlite3/python3/git itself.
    if REDTEAM_SKIP_PREREQ_CHECKS=1 REDTEAM_SKIP_DOCKER_IMAGE_CHECKS=1 \
         bash "$REPO_DIR/install.sh" "$cli" "$AGENT_DIR" >/dev/null 2>&1; then
      ok "$cli runtime installed"
      did=1
    else
      warn "install.sh $cli reported an issue — re-run: ./install.sh $cli $AGENT_DIR"
    fi
  done
  [ "$did" -eq 1 ] || warn "No CLI runtime generated (ollama-only install has no agent config)"
  # Force local runtime mode (Kali has the tools natively — no Docker tool containers).
  if [ -f "$AGENT_DIR/.env" ]; then
    if grep -q '^REDTEAM_RUNTIME_MODE=' "$AGENT_DIR/.env"; then
      sed -i 's/^REDTEAM_RUNTIME_MODE=.*/REDTEAM_RUNTIME_MODE=local/' "$AGENT_DIR/.env"
    else
      echo 'REDTEAM_RUNTIME_MODE=local' >> "$AGENT_DIR/.env"
    fi
    ok "Runtime mode set to local"
  fi
}

setup_mcp() {
  has_cli claude || has_cli opencode || return 0
  step "MCP wiring"
  if command -v msfconsole >/dev/null 2>&1 || prompt_yes_no "Set up Metasploit MCP anyway?" n; then
    if [ -f "$REPO_DIR/agent/scripts/install_metasploit_mcp.sh" ]; then
      bash "$REPO_DIR/agent/scripts/install_metasploit_mcp.sh" "$AGENT_DIR" >/dev/null 2>&1 \
        && ok "Metasploit MCP installed under $AGENT_DIR/.opencode/vendor" \
        || warn "Metasploit MCP setup failed (needs python3-venv + network)"
    fi
  else
    info "Metasploit not present — skipping Metasploit MCP"
  fi
}

# ----------------------------------------------------------------------------
# Docker engine + all-in-one image (required by the Orchestrator web UI runs).
# The UI launches each engagement as: docker run redteam-allinone:latest opencode ...
# ----------------------------------------------------------------------------
set_docker_cmd() {
  if docker info >/dev/null 2>&1; then DOCKER="docker"
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then DOCKER="sudo docker"
  else DOCKER="docker"; fi
}

install_docker() {
  step "Docker engine (for Orchestrator web UI runs)"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker present and daemon running"; return 0
  fi
  need_sudo
  if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker engine via apt (docker.io)..."
    if ! $SUDO apt-get install -y --no-install-recommends docker.io >/dev/null 2>&1; then
      warn "docker.io apt install failed; trying get.docker.com"
      curl -fsSL https://get.docker.com | $SUDO sh >/dev/null 2>&1 || { warn "Docker install failed — UI runs will not work"; return 1; }
    fi
    ok "Docker engine installed"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker >/dev/null 2>&1 || warn "could not start docker service (WSL? run: sudo dockerd &)"
  fi
  $SUDO usermod -aG docker "$(whoami)" >/dev/null 2>&1 || true
  if docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
    ok "Docker daemon reachable"
  else
    warn "Docker installed but daemon not reachable yet — re-login for the docker group, then re-run with --no-build-image to just build the image."
  fi
}

build_allinone_image() {
  step "Building all-in-one image (redteam-allinone:latest)"
  if $DOCKER image inspect redteam-allinone:latest >/dev/null 2>&1; then
    ok "Image already present — skipping build"; return 0
  fi
  local df="$REPO_DIR/agent/docker/redteam-allinone/Dockerfile"
  [ -f "$df" ] || { warn "Dockerfile not found: $df — cannot build image"; return 1; }
  info "This pulls the full Kali toolchain into the image (~10-20 min, several GB)..."
  if $DOCKER build -t redteam-allinone:latest -f "$df" "$REPO_DIR"; then
    ok "redteam-allinone:latest built"
  else
    warn "Image build failed — UI runs will not work until it builds. Re-run: $DOCKER build -t redteam-allinone:latest -f $df $REPO_DIR"
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Orchestrator web UI as a systemd (user) service
# ----------------------------------------------------------------------------
setup_orchestrator() {
  [ "$WANT_ORCH" = "yes" ] || { info "Orchestrator service not requested — skipping"; return 0; }
  step "Orchestrator web UI service"
  local od="$REPO_DIR/orchestrator"
  [ -d "$od" ] || { warn "orchestrator/ not found — skipping"; return 0; }

  # Backend venv
  info "Preparing backend venv..."
  python3 -m venv "$od/backend/.venv" >/dev/null 2>&1 || warn "venv create failed"
  "$od/backend/.venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
  "$od/backend/.venv/bin/pip" install -q -e "$od/backend" >/dev/null 2>&1 \
    && ok "Backend deps installed" || warn "Backend pip install had issues"

  # Frontend build (needs node)
  if command -v npm >/dev/null 2>&1 && [ -d "$od/frontend" ]; then
    info "Building frontend (npm ci + build)..."
    ( cd "$od/frontend" && (npm ci >/dev/null 2>&1 || npm install >/dev/null 2>&1) && npm run build >/dev/null 2>&1 ) \
      && ok "Frontend built" || warn "Frontend build had issues (UI may be unavailable)"
  fi

  # systemd user unit
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"
  cat > "$unit_dir/redteam-orchestrator.service" <<EOF
[Unit]
Description=RedTeam Agent Orchestrator Web UI
After=network.target

[Service]
Type=simple
WorkingDirectory=$od
Environment=HOST=127.0.0.1
Environment=PORT=$PORT
ExecStart=/usr/bin/env bash $od/run.sh --foreground
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  ok "Wrote systemd unit: $unit_dir/redteam-orchestrator.service"

  if systemctl --user daemon-reload >/dev/null 2>&1; then
    systemctl --user enable redteam-orchestrator.service >/dev/null 2>&1 || warn "enable failed"
    systemctl --user restart redteam-orchestrator.service >/dev/null 2>&1 \
      && ok "Orchestrator service started (http://127.0.0.1:$PORT)" \
      || warn "Service start failed — check: systemctl --user status redteam-orchestrator"
    # Keep the user service alive after logout
    command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$(whoami)" >/dev/null 2>&1 || true
  else
    warn "systemd --user not available — start manually: $od/run.sh"
  fi
}

# ----------------------------------------------------------------------------
# Terminal aliases
# ----------------------------------------------------------------------------
build_alias_block() {
  echo "$ALIAS_MARKER_BEGIN"
  echo "# Managed by redteam-agent setup.sh — do not edit between markers."
  echo "export REDTEAM_AGENT_DIR=\"$AGENT_DIR\""
  echo "alias redteam-setup='bash \"$REPO_DIR/setup.sh\"'"
  has_cli claude   && echo "alias redteam-claude='cd \"$AGENT_DIR\" && claude'"
  has_cli opencode && echo "alias redteam-opencode='cd \"$AGENT_DIR\" && opencode'"
  has_cli codex    && echo "alias redteam-codex='cd \"$AGENT_DIR\" && codex'"
  # Default launcher: prefer claude > opencode > codex
  local def=""
  has_cli claude && def="claude"; [ -z "$def" ] && has_cli opencode && def="opencode"; [ -z "$def" ] && has_cli codex && def="codex"
  [ -n "$def" ] && echo "alias redteam='cd \"$AGENT_DIR\" && $def'"
  [ "$WANT_ORCH" = "yes" ] && echo "alias redteam-ui='xdg-open http://127.0.0.1:$PORT >/dev/null 2>&1 || echo http://127.0.0.1:$PORT'"
  echo "$ALIAS_MARKER_END"
}

install_aliases() {
  step "Terminal aliases"
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || { [ "$rc" = "$HOME/.bashrc" ] && touch "$rc" || continue; }
    # Remove existing managed block, then append fresh
    if grep -qF "$ALIAS_MARKER_BEGIN" "$rc" 2>/dev/null; then
      sed -i "/$(printf '%s' "$ALIAS_MARKER_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$ALIAS_MARKER_END" | sed 's/[][\.*^$/]/\\&/g')/d" "$rc"
    fi
    build_alias_block >> "$rc"
    ok "Aliases written to $rc"
  done
  info "Open a new shell or run: source ~/.bashrc"
}

# ----------------------------------------------------------------------------
# Authentication (interactive — the only manual step)
# ----------------------------------------------------------------------------
do_auth_claude() {
  command -v claude >/dev/null 2>&1 || return 0
  step "Claude authentication (subscription)"
  echo "Claude Code will set up a long-lived subscription token. Follow the browser prompt."
  if prompt_yes_no "Authenticate Claude now?" y; then
    claude setup-token || warn "claude setup-token did not complete — run later: claude setup-token"
  else
    info "Skipped. Run later: claude setup-token"
  fi
}
do_auth_codex() {
  command -v codex >/dev/null 2>&1 || return 0
  step "Codex authentication (ChatGPT)"
  if codex login status >/dev/null 2>&1; then ok "Codex already logged in"; return; fi
  if prompt_yes_no "Authenticate Codex now (ChatGPT login)?" y; then
    codex login || warn "codex login did not complete — run later: codex login"
  else
    info "Skipped. Run later: codex login"
  fi
}
run_auth() {
  [ "$SKIP_AUTH" -eq 1 ] && { warn "--skip-auth set; skipping authentication"; return 0; }
  if has_cli claude || has_cli codex; then
    step "Authentication — the only manual step"
    echo "Everything else is installed. Complete the browser login(s) below;"
    echo "setup finishes automatically once you're done."
  fi
  has_cli claude && do_auth_claude
  has_cli codex  && do_auth_codex
  if has_cli opencode; then
    info "OpenCode: set your provider/key in $AGENT_DIR/.opencode/opencode.json or ~/.config/opencode/ (OpenRouter/Ollama/Anthropic/OpenAI)."
  fi
}

# ----------------------------------------------------------------------------
# status / uninstall
# ----------------------------------------------------------------------------
do_status() {
  load_conf
  step "RedTeam Agent — status"
  echo "Config:        $CONF_FILE"
  echo "Agent dir:     $AGENT_DIR"
  echo "CLIs selected: ${CLIS:-<none>}"
  echo "Orchestrator:  ${WANT_ORCH:-<unset>} (port $PORT)"
  echo ""
  for c in claude codex opencode ollama; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c: $("$c" --version 2>&1 | head -1)"; else warn "$c: not installed"; fi
  done
  echo ""
  if systemctl --user is-active redteam-orchestrator.service >/dev/null 2>&1; then
    ok "Orchestrator service: active (http://127.0.0.1:$PORT)"
  else
    warn "Orchestrator service: not active"
  fi
}

do_uninstall() {
  start_logging uninstall
  load_conf
  step "Uninstall"
  systemctl --user disable --now redteam-orchestrator.service >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/redteam-orchestrator.service"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  ok "Orchestrator service removed"
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    sed -i "/$(printf '%s' "$ALIAS_MARKER_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$ALIAS_MARKER_END" | sed 's/[][\.*^$/]/\\&/g')/d" "$rc"
    ok "Aliases removed from $rc"
  done
  info "Installed CLIs (claude/codex/opencode/ollama) and the pentest toolchain were left in place."

  # Optional: remove the agent runtime directory.
  if [ -d "$AGENT_DIR" ]; then
    if prompt_yes_no "Also remove the agent runtime dir '$AGENT_DIR'?" n; then
      rm -rf "$AGENT_DIR" && ok "Removed agent runtime dir: $AGENT_DIR"
    else
      info "Agent files in $AGENT_DIR were left in place."
    fi
  fi

  # Final prompt: optionally remove the installer source directory too.
  warn "Installer source directory: $REPO_DIR"
  if prompt_yes_no "Remove the source directory '$REPO_DIR' as well?" n; then
    # Preserve this uninstall log outside the directory we are about to delete.
    local saved=""
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
      saved="$HOME/$(basename "$LOG_FILE")"
      cp -f "$LOG_FILE" "$saved" 2>/dev/null && info "Uninstall log copied to $saved (the one in the source dir will be deleted)."
    fi
    cd "$HOME" 2>/dev/null || cd / 2>/dev/null || true
    if rm -rf "$REPO_DIR"; then
      ok "Source directory removed: $REPO_DIR"
      [ -n "$saved" ] && echo "Uninstall log preserved at: $saved"
    else
      err "Could not fully remove $REPO_DIR (remove it manually if needed)."
    fi
  else
    info "Source directory kept: $REPO_DIR"
    [ -n "$LOG_FILE" ] && echo "This uninstall log: $LOG_FILE"
  fi
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
print_summary() {
  step "Done"
  echo "Agent runtime:  $AGENT_DIR  (REDTEAM_RUNTIME_MODE=local)"
  echo "CLIs:           $CLIS"
  [ "$WANT_ORCH" = "yes" ] && echo "Orchestrator:   http://127.0.0.1:$PORT  (systemctl --user status redteam-orchestrator)"
  echo ""
  echo "Launch (after 'source ~/.bashrc'):"
  has_cli claude   && echo "  redteam-claude      # Claude Code operator"
  has_cli opencode && echo "  redteam-opencode    # OpenCode operator"
  has_cli codex    && echo "  redteam-codex       # Codex operator"
  echo "  redteam             # default operator"
  echo "  redteam-setup reconfigure   # add CLIs / service later"
  echo ""
  echo "Launch an attack TWO ways (authorized targets only):"
  echo "  • CLI:  open a 'redteam-*' alias, then  /engage http://TARGET"
  [ "$WANT_ORCH" = "yes" ] && echo "  • UI:   redteam-ui  ->  New Run -> enter target (Docker + all-in-one image, OpenCode --auto)"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main_install() {
  start_logging "$CMD"
  load_conf
  guard_user
  need_sudo
  if [ -z "$CLIS" ] && [ "$ASSUME_YES" -eq 0 ]; then interactive_select; fi
  [ -n "$CLIS" ] || die "No CLIs selected. Use --cli claude,opencode[,codex,ollama] or run interactively."
  [ -z "$WANT_ORCH" ] && WANT_ORCH="no"

  info "Plan: CLIs=[$CLIS]  orchestrator=$WANT_ORCH  agent-dir=$AGENT_DIR  port=$PORT"
  install_system_deps
  ensure_node
  has_cli claude   && install_claude
  has_cli codex    && install_codex
  has_cli opencode && install_opencode
  has_cli ollama   && install_ollama
  install_agent_runtime
  setup_mcp
  if [ "$WANT_ORCH" = "yes" ] && [ "$BUILD_IMAGE" != "no" ]; then
    install_docker
    set_docker_cmd
    build_allinone_image
  fi
  setup_orchestrator
  install_aliases
  save_conf
  run_auth
  print_summary
}

case "$CMD" in
  -h|--help|"--help") print_help ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
  auth)
    load_conf
    if [ -n "$AUTH_TARGET" ]; then
      [ "$AUTH_TARGET" = claude ] && do_auth_claude
      [ "$AUTH_TARGET" = codex ]  && do_auth_codex
    else
      run_auth
    fi
    ;;
  reconfigure)
    load_conf
    info "Reconfigure — current CLIs: [${CLIS:-none}], orchestrator=${WANT_ORCH:-no}"
    interactive_select
    main_install
    ;;
  install|*) main_install ;;
esac
