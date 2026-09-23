# Project Knowledge — RedTeam Agent

> Committed reference copy. A mirror of this content lives at the repo-root `CLAUDE.md`
> (gitignored per repo policy) so Claude Code auto-loads it when working here.
> For the operator runtime prompt see `agent/CLAUDE.md` (auto-generated — do not hand-edit).

## What this is

Autonomous AI red-team simulation agent for **authorized** CTF/lab pentest targets (README: "For authorized security testing only. Only use against targets you have explicit permission to test."). Works with Claude Code, OpenCode, and Codex. Pentest tools run containerized in Docker (Kali toolbox, mitmproxy, Katana, optional Metasploit RPC). Ships 8 agents, 31 attack skills, 79 reference files, and an optional web orchestrator.

Scope: only ever operate against targets the user has explicit authorization to test. Never assist using these capabilities against unauthorized systems.

## Repo layout — strict three-layer split (do not cross)

| Layer | Purpose | Contents |
|-------|---------|----------|
| **Repo root** | Meta only | `install.sh`, `README*.md`, `.gitignore`, `docs/`, this file |
| **`agent/`** | ALL agent runtime (**canonical, single source of truth**) | `.opencode/`, `scripts/`, `skills/`, `references/`, `docker/`, prompts, `operator-core.md` |
| **`orchestrator/`** | Optional web UI (reads `agent/`, never copies from root) | `backend/` (FastAPI), `frontend/` (React) |

**Never** create root-level `/.opencode/`, `/scripts/`, `/skills/`, `/references/`, `/docker/`. Edit the `agent/`-scoped copy. Two guards enforce this: `.gitignore` blocks the paths, and pre-commit hook `agent/scripts/hooks/block-root-dup-dirs.sh` refuses the commit. The orchestrator hardcodes `agent_source_dir = REPO_ROOT / "agent"` (`orchestrator/backend/app/config.py`).

## Single-source architecture (how prompts/commands are built)

Prompts and commands are maintained **only** in OpenCode format under `agent/.opencode/`. Claude Code and Codex versions are **generated at install time** by `install.sh`:
- `install.sh claude <dir>` → generates `.claude/agents/*.md` + `.claude/commands/*.md`
- `install.sh codex <dir>`  → generates `.codex/agents/*.toml`
- `install.sh opencode <dir>` → copies `.opencode/` directly (no build)

Operator prompt uses a mixed model:
- `agent/.opencode/prompts/agents/operator.txt` — OpenCode source prompt
- `agent/operator-core.md` — shared Claude/Codex methodology body
- `agent/scripts/render-operator-prompts.sh` — renders `agent/CLAUDE.md`, `agent/AGENTS.md`, and local operator wrappers

To change an agent: edit `agent/.opencode/prompts/agents/<name>.txt`, then re-run `install.sh` (or `render-operator-prompts.sh` for the operator). Do not hand-edit generated `agent/CLAUDE.md` / `agent/AGENTS.md` / `.claude/agents/*` / `.codex/agents/*`.

## 8 agents

`operator` (primary, drives all) → `recon-specialist` (network), `source-analyzer` (code), `vulnerability-analyst` (test), `exploit-developer` (exploit), `fuzzer` (deep wordlists >500 entries), `osint-analyst` (OSINT), `report-writer`. Intel accumulates in `intel.md`.

## 5-phase methodology

1. **RECON** — recon-specialist + source-analyzer (parallel)
2. **COLLECT** — import endpoints → SQLite queue, start Katana crawler
3. **TEST** — stage-based case pipeline. Cases carry a `stage` column independent of `status`. Dispatch is **serialized**: one fetch + one `task()` per turn. Routing by stage+type (ingested api/form/graphql/upload/websocket → vuln-analyst; ingested js/page/css/data/unknown/api-spec → source-analyzer; vuln_confirmed → exploit-developer; fuzz_pending → fuzzer).
4. **EXPLOIT** — osint-analyst + exploit-developer (parallel)
5. **REPORT** — report-writer with coverage stats + intel summary

## Case pipeline

SQLite-backed (`cases.db`). 4 producers (mitmproxy, Katana, recon, spec) → dedup + 15 types → zero-token dispatcher (`agent/scripts/dispatcher.sh`) → 4 consumers. Atomic fetch-dispatch pairing.

## Engagement commands & modes

- `/engage <url>` — semi-autonomous (asks auth setup; first phase needs approval)
- `/autoengage <url>` — fully autonomous, zero interaction, max coverage
- Others: `/resume`, `/status`, `/queue`, `/report`, `/proxy`, `/auth`, `/osint`, `/subdomain`, `/config`, `/stop`, phase overrides (`/recon` `/scan` `/enumerate` `/exploit` `/pivot`)

Outputs land in `engagements/<timestamp-target>/`: `findings.md`, `report.md`, `log.md`, `intel.md`, `cases.db`, `surfaces.jsonl`, plus **sensitive** `intel-secrets.json` / `auth.json` (never share casually).

## Tech stack

- **Agent runtime**: Bash scripts (`agent/scripts/`, `lib/`), Python helpers (`browser_flow.py`, contract checks), OpenCode/Claude/Codex config. Requires `curl`, `jq`, `sqlite3`, Docker.
- **Orchestrator backend**: FastAPI + `uvicorn[standard]`, SQLite, `requires-python >=3.11`, pytest. Located `orchestrator/backend/app/`.
- **Orchestrator frontend**: React + Vite + TypeScript + Vitest. Scripts: `npm run dev` / `build` / `test` (vitest run). Tabs: Documents / Events / Progress / Cases.

## Common commands

```bash
# Install runtime into a target dir (per product)
./install.sh claude ~/my-project
./install.sh opencode ~/my-project
./install.sh --dry-run opencode

# Re-render operator prompts after editing operator-core.md / operator.txt
bash agent/scripts/render-operator-prompts.sh

# Orchestrator web UI (default http://127.0.0.1:18000)
./orchestrator/run.sh          # bootstraps venv, installs+builds frontend
./orchestrator/run.sh --rebuild
./orchestrator/stop.sh

# Backend tests (from orchestrator/backend/)
pytest

# Frontend tests (from orchestrator/frontend/)
npm run test

# Contract guards for agent prompts (regression checks)
python agent/scripts/check_operator_prompt_contract.py
python agent/scripts/check_operator_respawn_contract.py
python agent/scripts/check_exploit_developer_prompt_contract.py
python agent/scripts/check_sensitive_data_skill_contract.py
```

## Platform note

**Native Windows/PowerShell is NOT supported** for running engagements — needs bash, curl, jq, sqlite3, Docker. This checkout is on Windows: use it for **dev/analysis/docs only**, not live engagements. Run actual engagements under the Docker all-in-one runtime, Linux, or macOS.

Where to run the CLI:
- **Repo root** — dev workspace (repo tooling, orchestrator dev, docs)
- **`agent/`** (or installed `~/redteam-agent/`) — drives engagements

## Customization quick reference

- **Add a skill**: create `agent/skills/<name>/SKILL.md` (frontmatter + methodology), add `"skills/<name>/SKILL.md"` to the instructions array in `agent/.opencode/opencode.json`.
- **Add references**: drop files in `agent/references/<category>/`, update `agent/references/INDEX.md`.
- **Change LLM provider (OpenCode)**: edit `model` in `agent/.opencode/opencode.json` (Anthropic, OpenAI, Google, Ollama).

## Knowledge graph

A graphify knowledge graph of this project lives at `../graphify-out/` (relative to repo root, in the parent workspace `C:\Dev\Drogo-Agent`): 1891 nodes, 3997 edges, 208 communities. Open `graph.html` to browse; `GRAPH_REPORT.md` for the audit. Core abstractions cluster in the orchestrator backend `Run` lifecycle (`Run`, `User`, `_reconcile_run_status()`, `get_connection()`, `BrowserFlow`, `Project`). For architecture questions, prefer `graphify query "<question>"` against the existing graph over re-reading files. Note: ~146 INFERRED semantic edges near `Run`/`User` are model-reasoned and should be verified before trusting as fact.

## Conventions

- Bash scripts are the primary runtime language for the agent; Python for browser automation and contract/regression checks.
- Keep the three-layer split intact — the pre-commit hook will reject root-dir duplication.
- Sensitive engagement artifacts (`intel-secrets.json`, `auth.json`, live `engagements/`) are never shared or committed.
