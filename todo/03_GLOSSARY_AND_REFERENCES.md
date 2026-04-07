# Agent Asset Injection System — Glossary & External References

## Glossary

| Term | Definition |
|------|-----------|
| **Asset** | Any file or directory (skill, hook, sub-agent, policy, etc.) managed by the injection system |
| **Asset Registry** | The `asset-registry/` directory in `tenai-infra` that stores all asset templates and their manifest |
| **Instruction File** | Agent-specific top-level markdown files: `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md` |
| **Skill** | A directory with a `SKILL.md` and optional supporting files that teach an AI agent how to perform a specific task |
| **Sub-Agent** | A specialized AI agent definition (markdown with frontmatter) that runs as a child of the main agent session |
| **Hook** | An automation rule that fires on agent lifecycle events (e.g., after file write, on session start) |
| **Policy** | A TOML rule set (Gemini CLI format) that controls what tools an agent can use in specific modes |
| **Workflow** | A step-by-step procedure template (markdown) placed in `.agents/workflows/` for agent task execution |
| **Command** | A TOML-defined slash command (Gemini CLI format) that triggers a predefined agent action |
| **Rule** | A concise markdown file in `.claude/rules/` that provides a focused guideline for agent behavior |
| **CI Template** | A GitHub Actions YAML workflow template suitable for injection into `.github/workflows/` |
| **Idempotency Ledger** | The `.tenai-assets.lock.yaml` lockfile in a target repo that records which assets were injected and their versions |
| **Scan Profile** | A YAML/JSON document produced by the codebase scanner describing the target repo's characteristics |
| **Conductor Session** | A tmux session managed by `gemini_session.sh` where an AI agent oversees task generation and dispatch |
| **Pre-Hook** | A script that runs before the conductor session starts, used to inject/update assets |
| **Applicability** | Conditions (language, framework, file presence) that determine whether an asset should be injected |
| **Template Rendering** | The process of replacing Jinja2 variables in instruction templates with repo-specific values |

---

## External References

### Specifications & Docs

| Resource | URL | Relevance |
|----------|-----|-----------|
| Claude Code Skills | https://code.claude.com/docs/en/skills | Skill format (SKILL.md, frontmatter, supporting files) |
| Claude Code Sub-Agents | https://code.claude.com/docs/en/sub-agents | Sub-agent format (frontmatter, tools, model, isolation) |
| Claude Code Hooks | https://code.claude.com/docs/en/hooks-guide | Hook format (events, matchers, command/prompt/agent types) |
| Anthropic Skills Repo | https://github.com/anthropics/skills | Reference skill implementations and spec |
| Microsoft Skills Repo | https://github.com/microsoft/skills | `npx skills add` pattern, AGENTS.md, repo structure, plugins |
| Gemini CLI Conductor | https://github.com/gemini-cli-extensions/conductor | Policies, commands, workflow templates |
| OpenAI Agent Skills Blog | https://developers.openai.com/blog/skills-agents-sdk | Conceptual alignment with Agent SDK skills |
| Vercel skills.sh | https://vercel.com/changelog/introducing-skills-the-open-agent-skills-ecosystem | Open ecosystem inspiration |

### Key File Format Examples

| Type | Source | Format |
|------|--------|--------|
| Skill | `anthropics/skills/skills/*/SKILL.md` | Markdown with YAML frontmatter |
| Sub-Agent | `claude Code docs` | Markdown, `name/description/tools/model` frontmatter |
| Hook | Claude Code settings.json | JSON: `{type, event, matcher, command}` |
| Policy | `gemini-cli-extensions/conductor/policies/*.toml` | TOML: `[[rule]]` array tables |
| Command | `gemini-cli-extensions/conductor/commands/*.toml` | TOML with `description` + `prompt` |
| Workflow | `.agents/workflows/*.md` | Markdown with `description` frontmatter |
| CI Template | `.github/workflows/*.yml` | Standard GitHub Actions YAML |
| AGENTS.md | `microsoft/skills/AGENTS.md` | Markdown with agent instructions |

### Existing Codebase Files (tenai-infra)

| File | Role |
|------|------|
| `GEMINI.md` | Current hand-written Gemini instructions |
| `CLAUDE.md` | Current hand-written Claude instructions |
| `scripts/conductor/gemini_session.sh` | Conductor session manager (injection point) |
| `config/defaults.yaml` | Central config (to be extended with `asset_injection` section) |
| `scripts/detect.sh` | OS detection for cross-platform support |
| `Makefile` | Build orchestration (to get new targets) |
