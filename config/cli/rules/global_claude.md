# Global Claude Code Rules
# This file is copied to ~/.claude/CLAUDE.md on new devices if not already present.
# It is loaded by Claude Code at the start of every session (global context).

## Code Quality

- Always write idempotent scripts — safe to re-run at any time
- Use `set -euo pipefail` in all bash scripts
- Prefer simple, readable code over clever one-liners
- Add error handling and meaningful error messages
- Follow the existing code style of the project

## Workflow

- Always run `make lint` and `make test` after code changes
- Write tests alongside implementation, not after
- Use conventional commit messages (feat:, fix:, docs:, refactor:, test:, chore:)
- Break large tasks into small, verifiable steps
- Verify changes work before marking tasks complete

## Security

- Never hardcode secrets, tokens, or API keys in source code
- Use environment variables or secret managers for credentials
- Validate all user inputs before processing
- Use least-privilege access for all service accounts
- Scan for common vulnerabilities (injection, auth bypass, XSS)

## Documentation

- Document non-obvious design decisions with inline comments
- Keep README and HOWTO docs up to date with changes
- Use docstrings for all public functions and classes

## Communication

- Explain the "why" behind non-obvious decisions
- Be concise — avoid restating what the code does
- Acknowledge mistakes and backtracking transparently
- Ask for clarification when requirements are ambiguous
