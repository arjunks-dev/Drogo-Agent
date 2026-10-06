# RedTeam Agent — Native Kali/Debian Setup

Install the agent **natively on Kali Linux** (no Docker required) with one script:
`setup.sh`. It provisions the pentest toolchain, any combination of four AI CLIs,
MCP wiring, the Orchestrator web UI as a systemd service, and terminal aliases.

> **Authorized use only.** Only run engagements against targets you have explicit
> permission to test (CTF/lab).

---

## Quick start

```bash
git clone <this-repo> redteam-agent-src && cd redteam-agent-src
chmod +x setup.sh
./setup.sh                 # interactive menu
# or fully specified (installs everything incl. Docker + the all-in-one image):
./setup.sh install --cli all --orchestrator --yes
```

The run is fully automatic **except one pause**: when it reaches authentication it
prompts you to complete the Claude/Codex browser login, then finishes on its own.
Selecting `--orchestrator` also installs Docker and builds the `redteam-allinone`
image (large, ~10–20 min) so the web UI can launch runs.

After it finishes, open a new shell (or `source ~/.bashrc`) and launch:

```bash
redteam              # default operator (Claude > OpenCode > Codex)
redteam-claude       # Claude Code operator
redteam-opencode     # OpenCode operator
redteam-codex        # Codex operator
redteam-ui           # open the Orchestrator web UI
```

Inside the CLI: `/engage http://your-target` (authorized targets only).

---

## What you can install

Pick **any combination** — all four, or just one. Reconfigure later anytime.

| Component | What it is | Auth needed |
|-----------|-----------|-------------|
| **claude** | Claude Code as the operator + **claude-mem**, context **headroom** config, and the agent skills | Claude subscription (`claude setup-token`) |
| **codex** | Codex as the operator | ChatGPT login (`codex login`) |
| **opencode** | OpenCode as the operator | Provider key (OpenRouter / Anthropic / OpenAI / Ollama) |
| **ollama** | Local models (for OpenCode). Needs a GPU to be practical | none (local) |
| **orchestrator** | Web UI (projects, live runs, artifacts) as a systemd service | none |

The pentest toolchain (nmap, nikto, sqlmap, ffuf, gobuster, wfuzz, dirb, hydra,
john, hashcat, nuclei, subfinder, katana, mitmproxy, Metasploit, wordlists/seclists)
is installed via apt and run **locally** (`REDTEAM_RUNTIME_MODE=local`).

---

## Commands & flags

```
./setup.sh                         interactive install (menu)
./setup.sh install [flags]         install with explicit options
./setup.sh reconfigure             add/enable more CLIs or the service later
./setup.sh auth [claude|codex]     (re)run interactive authentication
./setup.sh status                  show what is installed/configured
./setup.sh uninstall               remove service + aliases (keeps agent files)
```

Install / reconfigure flags:

| Flag | Meaning |
|------|---------|
| `--cli <list>` | comma list of `claude,codex,opencode,ollama` — or `all` |
| `--orchestrator` / `--no-orchestrator` | enable/skip the web UI systemd service |
| `--agent-dir <dir>` | agent runtime base (default `~/redteam-agent`); each CLI gets its own subdir `<dir>/{claude,opencode,codex}` |
| `--port <port>` | orchestrator port (default `18000`) |
| `--yes` | non-interactive; accept defaults, skip prompts |
| `--skip-tools` | do not apt-install the pentest toolchain (assume present) |
| `--skip-auth` | do not run interactive auth at the end |
| `--no-build-image` | skip building the all-in-one Docker image (the UI needs it) |

---

## Installation flow

1. **System deps** — core (`curl jq sqlite3 git python3 python3-venv python3-pip build-essential …`) + the pentest toolchain (apt). Metasploit is optional (prompted; it's large).
2. **Node.js** — installed via NodeSource if missing (needed by the CLIs and the UI).
3. **CLIs** — only the ones you chose, each via `npm install -g` (OpenCode and Claude Code get their native-binary postinstall run explicitly, which npm-as-root otherwise skips).
4. **Claude extras** (if claude chosen) — `claude-mem` plugin, context **headroom** config (`autoCompact` on in `~/.claude/settings.json`), and the agent skills (installed with the Claude runtime).
5. **Agent runtime** — generated per CLI into its **own** directory `~/redteam-agent/<cli>` via the repo's `install.sh`, then forced to `REDTEAM_RUNTIME_MODE=local`. (Each CLI gets a separate dir because `install.sh` produces a single-CLI runtime per directory and wipes the others on each run — separate dirs let Claude/OpenCode/Codex coexist. The `redteam-<cli>` aliases `cd` into the matching dir.)
6. **MCP** — Metasploit MCP wired under the agent dir when Metasploit is present.
7. **Docker + image** (only if the orchestrator is selected) — installs the Docker engine and builds the `redteam-allinone:latest` image. The web UI launches each engagement as a container, so this is required for UI runs. (`--no-build-image` skips the build.)
8. **Orchestrator service** — backend venv + frontend build + a `systemd --user` unit (`redteam-orchestrator.service`), enabled and started on `http://127.0.0.1:<port>`.
9. **Aliases** — a managed block appended to `~/.bashrc` (and `~/.zshrc` if present).
10. **Auth** — the only manual step. Setup **pauses** here, prompts you to complete the Claude/Codex browser login, then finishes automatically.

Everything is automatic except that one authentication pause.

---

## Authentication (the one manual step)

Run at the end of install, or anytime with `./setup.sh auth`:

- **Claude** (subscription, no API cost):
  ```bash
  claude setup-token
  ```
  Opens a URL; authorize with your Claude Plus/Max account; the long-lived token is stored under `~/.claude`.
- **Codex** (ChatGPT):
  ```bash
  codex login
  ```
- **OpenCode** — set a provider in `~/.config/opencode/opencode.jsonc` or `~/redteam-agent/.opencode/opencode.json`. Examples:
  - OpenRouter: set `OPENROUTER_API_KEY` and use a model like `openrouter/anthropic/claude-sonnet-5`.
  - Ollama (local): point a provider at `http://localhost:11434/v1` and use a **tool-capable** model.
- **Ollama** — no auth. Pull a tool-capable model, e.g. `ollama pull qwen2.5:7b-instruct`.

---

## Launching attacks — CLI or UI

Two independent execution paths (both set up by the installer):

- **CLI (native, local mode):** open a `redteam-*` alias and run `/engage http://TARGET`. Uses the CLI you authed (Claude / OpenCode / Codex) and the pentest tools installed natively — no Docker.
- **UI (Orchestrator):** `redteam-ui` → **New Run** → enter the target. Each run executes as `docker run redteam-allinone:latest opencode run "/engage --auto <target>"` — i.e. **Docker + OpenCode in autonomous mode**. Configure the model/provider/auth per project in the UI's Edit-project modal.

> Only engage targets you are explicitly authorized to test.

## Orchestrator web UI (systemd service)

```bash
systemctl --user status redteam-orchestrator     # health
systemctl --user restart redteam-orchestrator     # restart
journalctl --user -u redteam-orchestrator -f       # logs
```

Default URL: `http://127.0.0.1:18000` (or your `--port`). The service runs as a
**user** unit; `loginctl enable-linger` is set so it survives logout. On a headless
box without a user systemd session, start it manually with `./orchestrator/run.sh`.

**How it runs engagements (important):** the orchestrator is **Docker-based and
OpenCode-only**. It launches every run as a container from the `redteam-allinone:latest`
image, driving OpenCode in `--auto` (autonomous) mode — it does **not** use the native
CLI aliases, Claude, or Codex. That is why selecting the orchestrator also installs
Docker and builds that image. Per-run model/provider/keys come from the project's
**Model** config (injected as container env). Operate it via its tabs:

- **Dashboard** — projects + run overview
- **Progress** — phase/task timeline for the active run
- **Events** — streaming event log
- **Cases** — the SQLite queue (endpoints being tested)
- **Documents** — artifacts (`findings.md`, `report.md`, `intel.md`, `log.md`)

Create a **Project**, set its 6 config tabs (Model / Auth / Env / Crawler / Parallel /
Agents), then **New Run** against a target. The backend auto-recovers interrupted runs
and synthesizes a report if one is missing.

---

## Reconfigure later

Add another CLI, enable the service, etc. — without reinstalling everything:

```bash
redteam-setup reconfigure      # or: ./setup.sh reconfigure
```

Your previous choices are remembered in `~/.config/redteam/setup.conf`.

---

## Ollama note (important)

Ollama models run **locally**. Two requirements for use with this agent:

1. The model must support **tool-calling** (the operator dispatches tools/subagents). Check with `ollama show <model>` → capabilities must include `tools`.
2. Practical performance needs a **GPU**. On CPU-only hosts, local models are far too slow for a full engagement. The installer warns if no NVIDIA GPU is detected.

For real engagements on modest hardware, a cloud provider via OpenCode (OpenRouter with credits) or Claude Code via your subscription is far more practical.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `sudo` prompts repeatedly | Normal — apt steps need root. Run interactively once. |
| CLI not found after install | `source ~/.bashrc` (or open a new shell). |
| `opencode`/`claude` errors about a missing native binary | Re-run the postinstall: `cd $(npm root -g)/<pkg> && node <install.cjs|postinstall.mjs>`; the installer does this automatically. |
| Orchestrator service won't start | `journalctl --user -u redteam-orchestrator -e`; ensure the frontend built and the backend venv exists. |
| A pentest tool is missing | `sudo apt install <tool>`; ProjectDiscovery tools (nuclei/subfinder/katana) may need `go install` if not in apt. |
| Ollama very slow | You're on CPU. Use a GPU host, or switch to a cloud provider. |

---

## Logs

Every install/uninstall run is written to a timestamped plain-text log next to
the script, so you can review exactly what happened:

```
logs/install-YYYYMMDD-HHMMSS.log
logs/reconfigure-YYYYMMDD-HHMMSS.log
logs/uninstall-YYYYMMDD-HHMMSS.log
```

---

## Uninstall

```bash
./uninstall.sh           # standalone uninstaller (recommended)
# or equivalently:
./setup.sh uninstall
```

The uninstaller:

1. stops + removes the Orchestrator systemd service,
2. removes the managed alias block from `~/.bashrc` / `~/.zshrc`,
3. asks whether to also remove the **agent runtime dir** (`~/redteam-agent`), and
4. finally asks whether to remove the **installer source directory** as well.

Installed CLIs (claude/codex/opencode/ollama) and the pentest toolchain are left
in place (remove them manually if desired). If you choose to delete the source
directory, the uninstall log is first copied to your home directory so it
survives the deletion.
