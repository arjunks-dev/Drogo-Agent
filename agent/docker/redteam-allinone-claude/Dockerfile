# Claude Code as an alternative engagement driver, layered on the all-in-one image.
# The base already bundles the full toolchain (jq, sqlite3, nmap, metasploit, ...).
FROM redteam-allinone:latest

# npm 12 running as root skips package lifecycle scripts (same gotcha as opencode),
# so the claude native binary isn't fetched. Run claude-code's install.cjs explicitly,
# then assert `claude --version` at build time so a broken image fails the build.
RUN npm install -g @anthropic-ai/claude-code && \
    ( cd "$(npm root -g)/@anthropic-ai/claude-code" && node install.cjs ) && \
    claude --version
