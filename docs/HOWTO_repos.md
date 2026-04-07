# How To — Repo Management & Worktrees

## Common Commands

### List all repos

```bash
make repos
```

### Clone a repo

```bash
make clone REPO=git@github.com:org/repo.git
# Optionally specify branch:
make clone REPO=git@github.com:org/repo.git BRANCH=develop
```

### Pull a specific repo

```bash
make pull REPO=tenai
```

### Pull all repos

```bash
make pull-all
# or simply:
make pull
```

### Full git status across all repos

```bash
make repo-status
```

## Worktrees (Parallel Agent Isolation)

Worktrees create isolated git copies so multiple agents (Claude, Gemini) can work on different branches simultaneously without conflicts.

### Create a worktree

```bash
make worktree REPO=brownfield-cartographer BRANCH=feat/auth
```

### Create worktree + dispatch Claude agent

```bash
make dispatch REPO=brownfield-cartographer BRANCH=feat/auth TASK="Implement auth module"
```

### List worktrees

```bash
make list-worktrees REPO=brownfield-cartographer
```

### Clean merged worktrees

```bash
make clean-worktrees REPO=brownfield-cartographer
```

### Clean build artifacts

```bash
make clean-artifacts REPO=brownfield-cartographer
```

## Scaffolding a New Project

```bash
make new-project DIR=/path/to/project NAME=my-project
```

Creates `CLAUDE.md` and `GEMINI.md` files in the project directory with starter instructions for AI agents.

## Custom BASE_DIR

Override the default repo root:

```bash
make repos BASE_DIR=/custom/path
make pull-all BASE_DIR=/custom/path
```
