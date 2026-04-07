---
name: validate-skill
description: >
  Validate a newly created or modified skill against best practices.
  Use this skill after creating a new skill to check its structure,
  frontmatter, and content quality. Provides analysis and recommendations.
  Triggers: "validate skill", "check skill quality", "review skill",
  "skill lint", "is this skill correct".
---

# validate-skill — Skill Quality Validator

Validate a skill's structure and content against the cross-CLI best practices
standard (Claude Code, Gemini CLI, Codex CLI).

## When to Use

Run this **after creating or modifying any skill** in `.agents/skills/`.

## Validation Checklist

Read the target skill's `SKILL.md` and check each criterion:

### Structure (required)

- [ ] **SKILL.md exists** in `<skill-name>/SKILL.md`
- [ ] **YAML frontmatter** present (between `---` markers)
- [ ] **`name` field** — lowercase, hyphenated, matches directory name
- [ ] **`description` field** — present and non-empty

### Frontmatter Quality

- [ ] **Description is trigger-rich** — contains phrases the LLM will match
  - ✅ Good: "Use when creating a PR, pushing code, or finishing a task"
  - ❌ Bad: "Handles PRs"
- [ ] **Description says WHEN to use** — not just what it does
- [ ] **No angle brackets** in frontmatter (`<`, `>`) — breaks some parsers

### Content Quality

- [ ] **One skill, one job** — does exactly one thing
- [ ] **Zero context assumption** — does not depend on previous messages
- [ ] **Self-sufficient** — no dependencies on repo-internal scripts
  - ✅ Good: `curl`, `git`, `gh`, `make`
  - ❌ Bad: `python scripts/conductor/task_db.py`
- [ ] **Imperative steps** — numbered, with concrete shell commands
- [ ] **Expected output** — states what the command returns
- [ ] **Prerequisites listed** — what must be true before this skill runs
- [ ] **Output section** — describes what the skill produces

### Cross-CLI Compatibility

- [ ] **Frontmatter uses only `name` + `description`** (universal fields)
- [ ] **No CLI-specific frontmatter** (`allowed-tools`, `context` are Claude-only)
- [ ] **Works via auto-trigger** — description alone enables correct invocation

## Steps

### 1. Read the target skill

```bash
cat .agents/skills/<skill-name>/SKILL.md
```

### 2. Run through the checklist above

For each failed check, note:
- **What failed**: the criterion
- **Why**: what's wrong
- **Fix**: specific text to change

### 3. Report

Print a validation report:

```
=== Skill Validation: <skill-name> ===
✓ SKILL.md exists
✓ Frontmatter present
✗ Description not trigger-rich — add "Use when..." phrases
✓ One skill, one job
✗ Depends on internal script — replace with curl API call
...
Score: 8/12 checks passed
Recommendation: Fix description and remove script dependency
```

### 4. Fix issues (if requested)

If the user says "fix it", apply the recommended changes directly.

## Output

A validation report with pass/fail per criterion and actionable fixes.
