# Dual-DB Architecture

## Overview

tenai-infra uses a **dual-database** architecture separating webapp management data from device-scoped operational data.

## Database Files

| Database | Location | Content |
|----------|----------|---------|
| **Webapp DB** | `~/.tenai/tenai.db` | `devices`, `settings` |
| **Device DB** | `~/.tenai/devices/{name}.db` | `organizations`, `repos`, `tasks`, `jobs`, `subtasks`, `job_logs` |

When `name` is empty (`""`) the device DB is `~/.tenai/devices/.db`.

## How Device Routing Works

Priority chain for determining the active device:

1. **Explicit `?device=` query param** — on API requests
2. **`settings.default_device`** — persisted in webapp DB, configurable from Settings UI
3. **`DEVICE_NAME` env var** — set in `.env`, used in Docker
4. **Empty string** — fallback, uses `~/.tenai/devices/.db`

## CLI Usage

```bash
# Read tasks from a specific device DB
python scripts/conductor/task_db.py --device <host-name> list --repo myapp

# Via Makefile
make task-list REPO=myapp DEVICE=<host-name>

# Remote device (syncs DB first)
make task-list REPO=myapp HOST=<host-name>
```

## Auto-Initialization

`get_device_db(device)` automatically initializes the schema if the device DB file
does not exist. This means new devices get proper table structure on first access.

## Settings API

```
GET  /settings              → {settings: {key: value, ...}}
GET  /settings/{key}        → {key, value}
PUT  /settings/{key}        → body: {value: "..."}
DELETE /settings/{key}      → deletes setting
```

## Frontend

- **Global Device Selector** — Dropdown in sidebar header, scopes all data views
- **Settings View** — Configure `default_device` and `default_cli` with save/reset
