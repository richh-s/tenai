# HOWTO: Create and Manage CLI Agent Skills

> This document captures the best practices for creating skills that work
> across Claude Code, Gemini CLI, and Codex CLI — synthesized from
> official documentation as of March 2026.

## What is a Skill?

A skill is a reusable instruction set that an AI agent can discover and
invoke (automatically or via `/skill-name`) to perform a specific task.
Skills are stored as `SKILL.md` files inside named directories.

## Skill Discovery Paths

All three CLIs discover skills from these locations (in precedence order):

| Priority | Path | Scope |
|:---------|:-----|:------|
| 1 (highest) | `.agents/skills/<name>/SKILL.md` | Project (shared) |
| 2 | `.claude/skills/` · `.gemini/skills/` · `.codex/skills/` | Project (CLI-specific) |
| 3 | `~/.claude/skills/` · `~/.gemini/skills/` · `~/.codex/skills/` | User (global) |
| 4 | Extension skills | Extension-bundled |

**Our convention:** Canonical skills live in `.agents/skills/` and are
symlinked to `.{cli}/skills/` via `make skills-sync`.

For global deployment to devices: `make cli-skills HOST=<device>`.

## Creating a New Skill

### 1. Create the directory

```bash
mkdir -p .agents/skills/<skill-name>
```

### 2. Write SKILL.md

```yaml
---
name: skill-name
description: >
  What this skill does. When to use it. Use when <trigger phrase 1>,
  <trigger phrase 2>, or <trigger phrase 3>.
  Triggers: "phrase 1", "phrase 2", "phrase 3".
---
```

### 3. Add the body

Use this template:

```markdown
# skill-name — Short Title

One-sentence summary of what this skill does.

## Prerequisites
- List what must be true before running

## Steps

### 1. First step
\`\`\`bash
concrete-command --with-args
\`\`\`
**Expected response:** `{"ok": true}`

### 2. Next step
...

## Output
What the skill produces.
```

### 4. Validate the skill

```bash
# Use the validate-skill skill or manually check:
# - Frontmatter has name + description
# - Description is trigger-rich
# - Steps are imperative with concrete commands
# - No internal script dependencies
# - Expected output is documented
```

### 5. Sync to CLIs

```bash
make skills-sync     # creates symlinks in .claude/.gemini/.codex
make cli-skills      # deploys to global ~/.{cli}/skills/ on devices
```

## Best Practices

### Frontmatter

| Field | Required | Best Practice |
|:------|:---------|:-------------|
| `name` | ✅ | Lowercase hyphenated, matches directory name |
| `description` | ✅ | Rich with trigger phrases, says WHEN to use |

**Do NOT use CLI-specific frontmatter** like `allowed-tools`, `context`,
or `disable-model-invocation` unless you're writing a CLI-specific override.

### Content

| Principle | Explanation |
|:----------|:-----------|
| **One skill, one job** | Each skill does exactly one thing |
| **Zero context assumption** | Self-contained, no hidden dependencies |
| **API-only dependencies** | Use `curl`, `git`, `gh`, `make` — never `python scripts/...` |
| **Imperative steps** | Numbered steps with concrete shell commands |
| **Expected output** | Document what each command returns |
| **Prerequisites section** | List what must be true before running |
| **Output section** | Describe what the skill produces |

### Description Writing

The `description` field is the most important part — it determines when
the LLM will auto-trigger the skill.

```yaml
# ❌ BAD — too vague, won't trigger correctly
description: Handles tasks

# ❌ BAD — says what, not when
description: Registers tasks in the database

# ✅ GOOD — says when + why + trigger phrases
description: >
  Register tasks into the central task database via API after generating
  or planning them. Use this skill after creating tasks from conductor
  planning, manual breakdown, or GitHub issue analysis.
  Triggers: "register task", "add task to database", "save tasks to DB".
```

### Self-Sufficiency

Skills must work in ANY repo on ANY device. They should only depend on:
- **APIs** via `curl` (webapp at `http://localhost:7700`)
- **Git** commands (`git`, `gh`)
- **Build tools** (`make`, `npm`, `cargo`)
- **Standard Unix** (`cat`, `grep`, `ls`, `tee`)

**Never depend on:**
- Repo-internal scripts (`python scripts/conductor/...`)
- Specific file paths that only exist in one repo
- System packages that might not be installed

### Supporting Files

For complex skills, add supporting files:

```
my-skill/
├── SKILL.md           # Main instructions (required)
├── references/
│   └── api-spec.md    # Detailed API docs (loaded on demand)
├── examples/
│   └── sample.md      # Usage examples
└── scripts/
    └── helper.sh      # Self-contained utility scripts
```

Reference supporting files from SKILL.md:
```markdown
## Additional Resources
- For complete API details, see [references/api-spec.md](references/api-spec.md)
```

## CLI-Specific Notes

### Claude Code
- Supports `disable-model-invocation: true` to prevent auto-triggering
- Supports `context: fork` to run in a subagent
- Supports `$ARGUMENTS` for parameter passing
- Legacy `.claude/commands/` is deprecated — use `.claude/skills/`

### Gemini CLI
- Natively discovers `.agents/skills/` (no symlink needed)
- Skills are lazy-loaded: only metadata loaded initially
- `.agents/skills/` takes precedence over `.gemini/skills/`

### Codex CLI
- Natively discovers `.agents/skills/` (no symlink needed)
- `name` must be lowercase + hyphens only, max 64 characters
- Avoid `<` and `>` in frontmatter descriptions
