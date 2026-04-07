# How To — CLI Configuration

Manage **extensions, MCP servers, plugins, skills, settings, rules, hooks, and subagents** for Gemini CLI and Claude Code across all mesh devices.

## Quick Start

```bash
# Install everything for all CLIs (local):
make cli-setup

# Install on a remote device:
make cli-setup HOST=<host-name>

# Install on ALL devices:
make cli-setup HOST=all

# Target a specific CLI:
make cli-setup CLI=gemini
make cli-setup CLI=claude
```

## Architecture

```
config/cli/
├── gemini.yaml           # Gemini extensions, skills, settings, rules
├── claude.yaml           # Claude MCP servers, plugins, skills, settings, rules, hooks, subagents
├── codex.yaml            # Placeholder (no extension system)
├── skills/               # Local skill folders (copied to ~/.gemini/skills/ or ~/.claude/skills/)
│   └── README.md
├── rules/
│   ├── global_gemini.md  # Template for ~/.gemini/GEMINI.md
│   └── global_claude.md  # Template for ~/.claude/CLAUDE.md
└── hooks/
    └── claude_hooks.json # Template for ~/.claude/hooks.json

scripts/install/
└── cli_setup.sh          # Unified installer (all asset types, all CLIs)
```

## Makefile Targets

All targets support `HOST=device|all` and `CLI=gemini|claude`.

| Target | Description |
|--------|-------------|
| `make cli-setup` | Install **all** CLI config (extensions + MCP + plugins + skills + settings + rules + hooks) |
| `make cli-extensions` | Install/update extensions only |
| `make cli-mcp` | Install/update Claude MCP servers only |
| `make cli-plugins` | Install/update Claude plugins only |
| `make cli-skills` | Copy local skill folders |
| `make cli-vercel-skills` | Install [Vercel Skills](https://skills.sh) (cross-CLI) |
| `make cli-settings` | Merge `settings.json` |
| `make cli-rules` | Copy global rule files |
| `make cli-list` | List all installed assets |
| `make cli-install` | Install a single asset by name |

### Examples

```bash
# Install Gemini extensions on a specific server:
make cli-extensions CLI=gemini HOST=<host-name>

# Install Claude MCP servers everywhere:
make cli-mcp CLI=claude HOST=all

# Install Vercel skills for all CLIs:
make cli-vercel-skills

# Install a single Gemini extension by name:
make cli-install CLI=gemini TYPE=extensions EXT=conductor

# Install a single Claude MCP server:
make cli-install CLI=claude TYPE=mcp EXT=context7

# List what's installed on a remote device:
make cli-list HOST=<host-name> CLI=claude
```

## What Gets Installed

### Gemini CLI Extensions

Configured in `config/cli/gemini.yaml` under `extensions:`. Installed via `gemini extensions install <url> --auto-update`.

| Extension | Source | Purpose |
|-----------|--------|---------|
| conductor | gemini-cli-extensions | Task planning — spec→plan→implement lifecycle |
| security | gemini-cli-extensions | Find vulnerabilities in code changes and PRs |
| code-review | gemini-cli-extensions | Structured code review |
| superpowers | obra | Core skills: TDD, debugging, collaboration patterns |
| context7 | upstash | Up-to-date library documentation in prompts |
| github | github/github-mcp-server | GitHub issues, PRs, repos management |
| chrome-devtools-mcp | ChromeDevTools | Chrome DevTools for coding agents |
| terraform | hashicorp | Infrastructure as Code automation |

Optional (uncomment in YAML): cloud-run, mcp-server-kubernetes, google-workspace, flutter, exa-mcp-server, mcp-toolbox-for-databases, grafana.

### Claude Code MCP Servers

Configured in `config/cli/claude.yaml` under `mcp_servers:`. Installed via `claude mcp add <name> -- <command> <args>`.

| Server | Command | Purpose |
|--------|---------|---------|
| context7 | `npx -y @upstash/context7-mcp@latest` | Up-to-date library docs |
| sequential-thinking | `npx -y @modelcontextprotocol/server-sequential-thinking` | Structured problem decomposition |
| filesystem | `npx -y @modelcontextprotocol/server-filesystem ~` | Controlled file system access |
| github | `npx -y @modelcontextprotocol/server-github` | GitHub repos, issues, PRs |

Optional: puppeteer, postgres, memory, brave-search, slack.

### Claude Code Plugins

Configured under `plugins:`. Installed via `claude install <name>`.

| Plugin | Purpose |
|--------|---------|
| typescript-lsp | Real type checking, go-to-definition |
| security-guidance | Vulnerability scanning, secret detection |
| context7 | Documentation lookup |
| playwright | Browser automation and E2E testing |
| code-review | Quality scoring and review |
| claude-md-management | Auto-maintains CLAUDE.md |
| explanatory-output-style | Explains reasoning ("why" behind decisions) |
| commit-commands | Conventional commit formatting |

Optional: pr-review-toolkit, code-simplifier, frontend-design, feature-dev.

### Vercel Skills (cross-CLI)

Configured under `vercel_skills:`. Installed via `npx skills add <package>`. Works with **any** CLI: gemini, claude, codex, cursor, etc.

| Skill | Package | Purpose |
|-------|---------|---------|
| systematic-debugging | anthropics/skills | Step-by-step debugging methodology |
| test-driven-development | anthropics/skills | Red→green→refactor TDD workflow |
| verification-before-completion | anthropics/skills | Always verify before marking done |
| webapp-testing | anthropics/skills | Web application testing strategies |
| git-commit | anthropics/skills | Conventional commit best practices |
| security-best-practices | anthropics/skills | Security-first coding patterns |
| task-planning | anthropics/skills | Break complex tasks into steps |
| mcp-builder | anthropics/skills | Build custom MCP servers (Claude only) |

Browse more at [skills.sh](https://skills.sh).

Optional: find-skills, frontend-design, skill-creator, subagent-driven-development, using-git-worktrees, pdf, docx.

### Global Rules

Copied to `~/.gemini/GEMINI.md` or `~/.claude/CLAUDE.md` on first install (never overwrites existing). Templates at `config/cli/rules/`.

Covers: code quality, workflow, security, documentation, communication.

### Hooks (Claude only)

Copied from `config/cli/hooks/claude_hooks.json` to `~/.claude/hooks.json`. Empty by default — add hooks for pre/post actions.

## How to Customize

### Add a new extension

Edit `config/cli/gemini.yaml`:

```yaml
extensions:
  - name: my-extension
    url: "https://github.com/owner/my-extension"
    description: "What it does"
```

Then run: `make cli-extensions CLI=gemini` (or `HOST=all` for everywhere).

### Add a new MCP server

Edit `config/cli/claude.yaml`:

```yaml
mcp_servers:
  - name: my-server
    command: npx
    args: ["-y", "@my/mcp-server"]
    description: "What it does"
```

Then run: `make cli-mcp CLI=claude`.

### Add a new Vercel skill

Edit either `gemini.yaml` or `claude.yaml`:

```yaml
vercel_skills:
  - name: my-skill
    package: "owner/repo/skill-name"
    description: "What it does"
```

Then run: `make cli-vercel-skills`.

Or install ad-hoc without editing config:

```bash
npx skills add owner/repo/skill-name
```

### Add a local skill folder

1. Create `config/cli/skills/my-skill/SKILL.md`
2. Add to YAML:
   ```yaml
   skills:
     - name: my-skill
       source: "config/cli/skills/my-skill"
   ```
3. Run: `make cli-skills`

### Modify global rules

Edit `config/cli/rules/global_gemini.md` or `global_claude.md`, then:

```bash
# Will only copy to devices that don't already have the file:
make cli-rules HOST=all

# To force-update on a device, first remove the existing file:
ssh user@device "rm ~/.gemini/GEMINI.md"
make cli-rules HOST=device
```

## Script Usage (Direct)

The installer script can be called directly with environment variables:

```bash
# Install everything:
bash scripts/install/cli_setup.sh

# Just Gemini extensions:
CLI=gemini TYPE=extensions bash scripts/install/cli_setup.sh

# List installed assets:
ACTION=list bash scripts/install/cli_setup.sh

# Install one item:
CLI=gemini TYPE=extensions EXT=conductor ACTION=install bash scripts/install/cli_setup.sh
```

| Variable | Values | Default |
|----------|--------|---------|
| `CLI` | `gemini`, `claude`, (empty=all) | all |
| `TYPE` | `extensions`, `mcp`, `plugins`, `skills`, `vercel-skills`, `settings`, `rules`, `hooks`, `subagents`, (empty=all) | all |
| `ACTION` | `setup`, `list`, `install` | `setup` |
| `EXT` | extension/plugin name (for `ACTION=install`) | — |

## Integration with new-server

When bootstrapping a new device with `make new-server HOST=x`, add `make cli-setup HOST=$(HOST)` to the pipeline. This ensures all CLI tools are configured with the standard extensions, MCP servers, plugins, and skills automatically.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `pyyaml` not installed | Script auto-falls back to pure Python regex parser — no action needed |
| Extension "may already exist" | Normal — idempotent, skips already-installed items |
| Extension installed but not found | Old tmux sessions don't pick up new extensions. Run `make tmux-clean HOST=x` then retry |
| `npx not available` | Install Node.js: `make install` or `bash scripts/install/tools.sh` |
| `gemini: command not found` | Install Gemini CLI: `bash scripts/install/gemini_cli.sh` |
| `claude: command not found` | Install Claude Code: `bash scripts/install/claude_code.sh` |
| Rules not updating | Rules are never overwritten. Delete existing file first, then re-run |
| `can't find window: 0` | Tmux session failed to create. Check SSH connectivity and re-run |

## Sources

- **Gemini extensions**: [geminicli.com/extensions](https://geminicli.com/extensions/)
- **Vercel Skills**: [skills.sh](https://skills.sh/) — `npx skills add <package>`
- **Anthropic skills**: [github.com/anthropics/skills](https://github.com/anthropics/skills)
- **MCP servers**: [modelcontextprotocol.io](https://modelcontextprotocol.io)
- **Claude plugins**: [github.com/anthropics/claude-code](https://github.com/anthropics/claude-code)
