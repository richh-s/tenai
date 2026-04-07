# Data Flow — Setup Pipeline

## `make` (Full Setup)

```mermaid
graph TD
    A["make (all)"] --> B[install]
    A --> C[configure]

    B --> D[install-deps]
    B --> E["setup.py +action=install_all"]

    D --> D1["uv: hydra-core, omegaconf, python-dotenv"]

    E --> F["tailscale.sh"]
    E --> G["mosh.sh"]
    E --> H["tmux.sh"]
    E --> I["tools.sh"]

    F --> F1{tailscale installed?}
    F1 -->|yes| F2[skip]
    F1 -->|no| F3[install + configure]
    F3 --> F4["sysctl (dedup guard)"]
    F3 --> F5["UFW rules"]

    I --> I1["common tools (git, curl, etc.)"]
    I --> I2["Node.js"]
    I --> I3["uv + Python env"]
    I --> I4["Claude Code + Gemini CLI + Codex CLI"]
    I --> I5["muxtree + VibeTunnel"]

    C --> J["ssh.sh"]
    C --> K["aliases.sh"]

    J --> J1["generate SSH key (if missing)"]
    J --> J2["write ~/.ssh/config (marker block)"]

    K --> K1["remove old alias block"]
    K --> K2["write new alias block to shell rc"]
```

## Idempotency Guards

| Script | Guard Type | Mechanism |
|--------|-----------|-----------|
| Install scripts | **Skip guard** | `command -v <tool>` — skips if already installed |
| SSH config | **Replace guard** | Marker-based `START`/`END` block — deletes old, writes new |
| Aliases | **Replace guard** | Same marker-based approach |
| Sysctl | **Dedup guard** | `grep -qxF` — only appends if line not already present |
| tmux config | **Overwrite** | Full replacement with backup of previous |
| pip/uv deps | **Idempotent** | `uv pip install` is naturally idempotent (no-ops if satisfied) |
