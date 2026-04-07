# Global Gemini CLI Rules
# This file is copied to ~/.gemini/GEMINI.md on new devices if not already present.
# It is loaded by Gemini CLI at the start of every session (global context).

## Code Quality

- Always write idempotent scripts — safe to re-run at any time
- Use `set -euo pipefail` in all bash scripts
- Prefer simple, readable code over clever one-liners
- Add error handling and meaningful error messages

## Workflow

- Always run `make lint` and `make test` after code changes
- Write tests alongside implementation, not after
- Use conventional commit messages (feat:, fix:, docs:, etc.)
- Break large tasks into small, verifiable steps

## Security

- Never hardcode secrets, tokens, or API keys in source code
- Use environment variables or secret managers for credentials
- Validate all user inputs before processing
- Use least-privilege access for all service accounts

## Documentation

- Document non-obvious design decisions with inline comments
- Keep README and HOWTO docs up to date with changes
- Use docstrings for all public functions and classes
