# HOWTO: Releases

How the tagged release system works for `tenai-infra`.

## Overview

Releases use **semver** (`MAJOR.MINOR.PATCH`). Tags are created in an isolated git worktree with sanitized config — your `main` branch keeps your real device configuration intact.

## Quick reference

```bash
# Generate release notes (idempotent — skips if file exists)
make release-notes

# Edit the generated notes
$EDITOR .release_notes/vX.Y.Z.md

# Create the release
make tagged-release PATCH=1 AUTO_MESSAGE=1
```

## Step-by-step

### 1. Generate release notes

```bash
make release-notes
```

This:
- Parses git log since the last tag
- Categorizes commits by conventional prefix (`feat:`, `fix:`, `refactor:`, `docs:`)
- Saves to `.release_notes/{next_version}.md`
- Shows the filepath for editing

**Idempotent**: running again skips if the file already exists. Use `FORCE=1` to regenerate:

```bash
make release-notes FORCE=1
```

Add a summary message:

```bash
make release-notes MESSAGE="Sprint 3: env fixes and universal aliases"
```

### 2. Review and edit

Open the generated file and customize:

```bash
$EDITOR .release_notes/v0.0.2.md
```

You can add context, reorder items, remove noise, or expand descriptions. The file is standard markdown.

### 3. Create the tagged release

```bash
# Use PATCH=1, MINOR=1, or MAJOR=1 to control version bump
make tagged-release PATCH=1 AUTO_MESSAGE=1
```

What happens internally:

1. **Get last tag**: reads from `git describe --tags`
2. **Compute next version**: increments MAJOR, MINOR, or PATCH
3. **Resolve notes**: checks `.release_notes/{version}.md`, auto-generates if missing
4. **Show preview**: displays the full release notes
5. **Confirm**: asks y/N before proceeding
6. **Create worktree**: `git worktree add /tmp/tenai-release-vX.Y.Z`
7. **Sanitize config**: clears devices, resets tailnet, removes `.env` and secrets
8. **Commit + tag**: annotated tag with release notes embedded
9. **Push tag**: to GitHub origin
10. **Cleanup**: removes worktree and temp branch

### Message modes

| Option | Behavior |
|:-------|:---------|
| `AUTO_MESSAGE=1` | Uses `.release_notes/vX.Y.Z.md` if it exists, else auto-generates |
| `MESSAGE_FILE=path` | Uses a custom file as release notes |
| `MESSAGE="text"` | Inline text embedded in the tag |
| *(none)* | Tag with just "Release vX.Y.Z" |

## Versioning rules

| Bump | When | Example |
|:-----|:-----|:--------|
| `PATCH=1` | Bug fixes, small improvements | v0.1.0 → v0.1.1 |
| `MINOR=1` | New features, non-breaking changes | v0.1.1 → v0.2.0 |
| `MAJOR=1` | Breaking changes, major rewrites | v0.2.0 → v1.0.0 |

## Commit conventions

Release notes are auto-generated from commit messages. Use conventional commits:

```
feat: add tenai_tmux_* universal aliases
fix: Docker .env-as-directory root cause
refactor: extract Makefile inline bash to scripts
docs: comprehensive .env.example with all vars
```

Commits without a known prefix land in the "📦 Other" section.

## Internals

### Files

| File | Purpose |
|:-----|:--------|
| `scripts/entrypoints/release_notes.sh` | Generates release notes from git log |
| `scripts/entrypoints/tagged_release.sh` | Tagged release workflow |
| `.release_notes/` | Generated notes (gitignored) |

### Why an isolated worktree?

The release tag needs a **clean config** for distribution (no real device IPs, no secrets). But your `main` branch needs your real config to work. The worktree solves this:

1. Creates a temp branch from HEAD
2. Sanitizes config in the worktree only
3. Commits + tags from there
4. The tag is reachable, but the temp branch is deleted
5. Your `main` branch is untouched

### Future: task-based release notes

When the task DB integration is complete, `release_notes.sh` will also query completed tasks from all device DBs via the webapp API and include them alongside git commit analysis.
