#!/usr/bin/env python3
"""
webapp/server.py — TenAI Control Plane
Pure control-plane webapp: manages orgs, repos, devices, and jobs
via SSH to remote devices over Tailscale.

Usage:
  python webapp/server.py
  # or via Docker:
  docker compose up webapp

Deps: pip install fastapi uvicorn python-dotenv pydantic pyyaml
"""
import asyncio
import json
import os
import re
import subprocess
import time
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv  # noqa: F401 — kept for pip auto-install fallback

try:
    from fastapi import FastAPI, HTTPException, Query, Body
    from fastapi.routing import APIRouter
    from fastapi.middleware.cors import CORSMiddleware
    from fastapi.responses import HTMLResponse
    from starlette.staticfiles import StaticFiles
    from pydantic import BaseModel
    import uvicorn
    import yaml
except ImportError:
    print("Installing dependencies...")
    subprocess.run([sys.executable, "-m", "pip", "install",
                    "fastapi", "uvicorn[standard]", "python-dotenv", "pydantic",
                    "pyyaml", "--break-system-packages", "-q"], check=True)
    from fastapi import FastAPI, HTTPException, Query, Body
    from fastapi.routing import APIRouter
    from fastapi.middleware.cors import CORSMiddleware
    from fastapi.responses import HTMLResponse
    from pydantic import BaseModel
    import uvicorn
    import yaml

from db import init_webapp_db, init_device_db, \
    upsert_org, list_orgs, get_org, delete_org, \
    upsert_repo, list_repos as db_list_repos, get_repo, \
    upsert_device, list_devices as db_list_devices, get_device, update_device_status, \
    create_job, update_job_status, update_job_vt_session, \
    list_jobs as db_list_jobs, get_job, find_running_job, find_running_job_by_task_id, \
    append_job_log, get_job_logs, delete_job as db_delete_job, \
    get_setting, set_setting, list_settings, delete_setting

import sys
# Add scripts/ to path for env_loader
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
from env_loader import load_env

load_env(Path(__file__).parent.parent / ".env")

# ── Config ────────────────────────────────────────────────────────────────────
INFRA_DIR    = Path(os.environ.get("INFRA_DIR", Path(__file__).parent.parent)).expanduser()
# Auth removed — trusting Tailscale network for now (see system_audit.md)
PORT         = int(os.environ.get("WEBAPP_PORT", 7700))
HOST         = os.environ.get("WEBAPP_HOST", "0.0.0.0")
def _load_base_dir() -> str:
    """Load base_dir from config, env, or default."""
    env_val = os.environ.get("BASE_DIR")
    if env_val:
        return env_val
    config_dir = os.environ.get("CONFIG_DIR", str(Path(__file__).parent.parent / "config"))
    defaults_yaml = Path(config_dir) / "defaults.yaml"
    if defaults_yaml.exists():
        try:
            import yaml
            with open(defaults_yaml) as f:
                cfg = yaml.safe_load(f) or {}
            return cfg.get("repos", {}).get("base_dir", "~/projects")
        except Exception:
            pass
    return "~/projects"

BASE_DIR_CFG = _load_base_dir()
VT_PORT      = int(os.environ.get("VT_PORT", 4020))
# Local device name (from .env DEVICE_NAME) — used to detect when VT/SSH targets this host
LOCAL_DEVICE  = os.environ.get("DEVICE_NAME", "")

def _active_device() -> str:
    """Return the currently active device name for DB routing.

    Priority: settings.default_device → DEVICE_NAME env → ''.
    Reads DEVICE_NAME at call time (not frozen at import).
    """
    local_device = os.environ.get("DEVICE_NAME", "")
    try:
        return get_setting("default_device", local_device)
    except Exception:
        return local_device

def _resolve_home(user: str) -> str:
    """Resolve home directory path for a given user (avoids $HOME expansion in Docker)."""
    if user == "root":
        return "/root"
    return f"/home/{user}"
CONFIG_DIR   = Path(os.environ.get("CONFIG_DIR", INFRA_DIR / "config"))

app = FastAPI(title="TenAI Control Plane", version="1.0.0")

app.add_middleware(CORSMiddleware,
    allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# All API routes are prefixed with /api to separate from frontend SPA routes
api_router = APIRouter(prefix="/api")




# ── Config loader ────────────────────────────────────────────────────────────
def load_config() -> dict:
    """Load YAML config from config/defaults.yaml."""
    cfg_path = CONFIG_DIR / "defaults.yaml"
    if cfg_path.exists():
        with open(cfg_path) as f:
            return yaml.safe_load(f) or {}
    return {}


def sync_config_to_db():
    """Sync organizations and devices from YAML config into SQLite."""
    cfg = load_config()
    dev = _active_device()

    # Sync organizations to active device DB
    for org_name, org_cfg in cfg.get("organizations", {}).items():
        upsert_org(
            name=str(org_name),
            github_url=org_cfg.get("github_url", "github.com"),
            ssh_host_alias=org_cfg.get("ssh_host_alias", f"github-{org_name}"),
            ssh_key=org_cfg.get("ssh_key", ""),
            default_branch=org_cfg.get("default_branch", "main"),
            device=dev,
        )

    # Sync devices
    for dev_name, dev_cfg in cfg.get("tailscale", {}).get("devices", {}).items():
        caps = dev_cfg.get("capabilities", [])
        upsert_device(
            name=dev_name,
            ip=dev_cfg.get("ip", ""),
            user=dev_cfg.get("user", ""),
            device_type=dev_cfg.get("type", "server"),
            capabilities=json.dumps(caps) if isinstance(caps, list) else str(caps),
        )


# ── SSH helper ───────────────────────────────────────────────────────────────
async def ssh_cmd(device_name: str, cmd: str, timeout: int = 120) -> dict:
    """Execute a command on a remote device via SSH over Tailscale.

    Uses create_subprocess_exec (NOT shell) so that $SHELL, $HOME, etc.
    in `cmd` pass through literally to the remote device rather than
    being expanded by the local Docker shell.
    """
    device = get_device(device_name)
    if not device:
        return {"ok": False, "rc": -1, "stdout": "", "stderr": f"Device not found: {device_name}"}

    ssh_target = f"{device['user']}@{device['ip']}"
    ssh_port = str(device.get("ssh_port", 22))
    ssh_args = [
        "ssh",
        "-p", ssh_port,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10",
        "-o", "BatchMode=yes",
        ssh_target,
        cmd,  # passed as a single argument — no local shell expansion
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *ssh_args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return {
            "ok": proc.returncode == 0,
            "rc": proc.returncode,
            "stdout": stdout.decode().strip(),
            "stderr": stderr.decode().strip(),
        }
    except asyncio.TimeoutError:
        return {"ok": False, "rc": -1, "stdout": "", "stderr": f"Timeout after {timeout}s"}
    except Exception as e:
        return {"ok": False, "rc": -1, "stdout": "", "stderr": str(e)}


# ── Models ────────────────────────────────────────────────────────────────────
class OrgRequest(BaseModel):
    name: str
    github_url: str = "github.com"
    ssh_host_alias: str = ""
    ssh_key: str = ""
    default_branch: str = "main"

class CloneRequest(BaseModel):
    org: str
    repo: str
    device: str
    branch: str = ""

class JobRequest(BaseModel):
    device: str
    org: str = ""
    repo: str = ""
    cli: str = ""           # claude | gemini | codex | shell
    action: str = ""        # conductor | dispatch | clone | pull | custom
    command: str = ""       # custom command (if action=custom)
    branch: str = ""
    task: str = ""          # free-form task description
    task_id: int | None = None  # link to existing task in task DB
    title: str = ""         # task title for auto-creation
    pull_latest: bool = True  # pull latest code if repo already cloned
    base_branch: str = ""   # base branch to create worktree from
    env_file: str = ""      # explicit env file name from ~/.tenai_envs/

class SendKeysRequest(BaseModel):
    device: str
    session: str
    keys: str
    pane: str = "0.0"


# ── Route: Device DB Sync ────────────────────────────────────────────────────
@api_router.post("/sync-device-db")
async def api_sync_device_db(device: str = Query("")):
    """Sync a remote device's DB to local for fresh reads.

    Called by the frontend on device switch. Skips if device is local
    or if synced within the last 30 seconds (cooldown).
    """
    from db import sync_remote_device_db
    dev = device or _active_device()
    result = await sync_remote_device_db(dev, local_device=LOCAL_DEVICE)
    return result


# ── Routes: Organizations ────────────────────────────────────────────────────
@api_router.get("/orgs")
async def api_list_orgs(device: str = Query("")):
    """List all configured organizations with repo counts."""
    dev = device or _active_device()
    orgs = list_orgs(device=dev)

    # Get cloned repos count per org via SSH disk check
    cloned_per_org: dict[str, int] = {}
    base_dir = BASE_DIR_CFG.replace("~", "$HOME")
    try:
        result = await ssh_cmd(
            dev,
            f"for d in {base_dir}/*/; do "
            f"  org=$(basename \"$d\"); "
            f"  count=$(find \"$d\" -maxdepth 2 -name .git -type d 2>/dev/null | wc -l); "
            f"  echo \"$org:$count\"; "
            f"done",
            timeout=15,
        )
        if result["ok"]:
            for line in result["stdout"].splitlines():
                parts = line.strip().split(":")
                if len(parts) == 2 and parts[1].strip().isdigit():
                    cloned_per_org[parts[0].strip()] = int(parts[1].strip())
    except Exception:
        pass

    for org in orgs:
        repos = db_list_repos(org=org["name"], device=dev)
        org["repo_count"] = len(repos)  # available from GitHub sync
        org["cloned_count"] = cloned_per_org.get(org["name"], 0)  # actually on disk
    return {"orgs": orgs}


@api_router.post("/orgs")
async def api_upsert_org(req: OrgRequest, device: str = Query("")):
    """Add or update an organization."""
    dev = device or _active_device()
    alias = req.ssh_host_alias or f"github-{req.name}"
    key = req.ssh_key or f"~/.ssh/{req.name.lower()}-git-ssh-key"
    upsert_org(req.name, req.github_url, alias, key, req.default_branch, device=dev)
    return {"ok": True, "org": req.name}


@api_router.delete("/orgs/{org}")
async def api_delete_org(org: str, device: str = Query("")):
    """Remove an organization and its repos from DB."""
    dev = device or _active_device()
    delete_org(org, device=dev)
    return {"ok": True, "deleted": org}


@api_router.post("/orgs/{org}/sync")
async def api_sync_org(org: str, device: str = Query(...)):
    """Discover repos for an org via SSH to a device.

    Strategies (in order):
    1. GitHub REST API via curl (uses GITHUB_TOKEN if available)
    2. gh CLI (requires gh auth on the device)
    3. List local directories under base_dir/<org>/
    """
    dev = device or _active_device()
    org_data = get_org(org, device=dev)
    if not org_data:
        raise HTTPException(404, f"Org not found: {org}")

    github_url = org_data.get("github_url", "github.com")
    base_dir = BASE_DIR_CFG.replace("~", "$HOME")
    repos_synced = 0

    # Strategy 1: GitHub REST API directly from Python (no SSH needed for API calls)
    github_token = os.environ.get("GITHUB_TOKEN", "")
    import urllib.request, urllib.error
    for endpoint in [f"orgs/{org}", f"users/{org}"]:
        if repos_synced > 0:
            break
        for page in range(1, 4):  # up to 300 repos
            try:
                api_url = f"https://api.{github_url}/{endpoint}/repos?per_page=100&page={page}&type=all"
                req = urllib.request.Request(api_url, headers={
                    "Accept": "application/vnd.github.v3+json",
                    "User-Agent": "tenai-infra-webapp",
                })
                if github_token:
                    req.add_header("Authorization", f"Bearer {github_token}")
                with urllib.request.urlopen(req, timeout=15) as resp:
                    remote_repos = json.loads(resp.read().decode())
                if not remote_repos or not isinstance(remote_repos, list):
                    break
                for r in remote_repos:
                    if not isinstance(r, dict) or "name" not in r:
                        continue
                    if r.get("archived"):
                        continue
                    branch = r.get("default_branch", "main")
                    upsert_repo(
                        org=org,
                        name=r["name"],
                        default_branch=branch,
                        description=r.get("description") or "",
                        pushed_at=r.get("pushed_at") or "",
                        device=dev,
                    )
                    repos_synced += 1
                if len(remote_repos) < 100:
                    break  # last page
            except urllib.error.HTTPError as e:
                print(f"[sync] GitHub API {endpoint} page={page}: HTTP {e.code} {e.reason}")
                break
            except Exception as e:
                print(f"[sync] GitHub API {endpoint} page={page}: {type(e).__name__}: {e}")
                break

    # Strategy 2: gh CLI fallback
    if repos_synced == 0:
        gh_cmd = f"gh repo list {org} --limit 200 --json name,defaultBranchRef,description --no-archived 2>/dev/null"
        gh_result = await ssh_cmd(device, gh_cmd)
        if gh_result["ok"] and gh_result["stdout"]:
            try:
                remote_repos = json.loads(gh_result["stdout"])
                for r in remote_repos:
                    branch = "main"
                    if r.get("defaultBranchRef") and r["defaultBranchRef"].get("name"):
                        branch = r["defaultBranchRef"]["name"]
                    upsert_repo(
                        org=org,
                        name=r["name"],
                        default_branch=branch,
                        description=r.get("description", ""),
                        device=dev,
                    )
                    repos_synced += 1
            except json.JSONDecodeError:
                pass

    # Strategy 3: list local directories
    if repos_synced == 0:
        fallback = await ssh_cmd(device, f"ls -1 {base_dir}/{org}/ 2>/dev/null || echo ''")
        if fallback["ok"]:
            for name in fallback["stdout"].splitlines():
                name = name.strip()
                if name and not name.startswith("."):
                    upsert_repo(org=org, name=name, device=dev)
                    repos_synced += 1

    return {"ok": True, "org": org, "repos_synced": repos_synced}


@api_router.get("/orgs/{org}/repos")
async def api_org_repos(org: str, device: str = Query("")):
    """List repos for an organization."""
    dev = device or _active_device()
    repos = db_list_repos(org=org, device=dev)
    return {"repos": repos, "org": org}


# ── Routes: Repos ─────────────────────────────────────────────────────────────
@api_router.get("/repos/cloned")
async def api_cloned_repos(org: str = Query(""), device: str = Query("")):
    """List repos actually cloned on the device by checking disk for .git dirs."""
    dev = device or _active_device()
    base_dir = BASE_DIR_CFG.replace("~", "$HOME")
    search_dir = f"{base_dir}/{org}" if org else base_dir

    result = await ssh_cmd(
        dev,
        f"find {search_dir} -maxdepth 3 -name .git -type d 2>/dev/null | "
        f"sed 's|/.git$||' | while read d; do "
        f"  rel=$(echo \"$d\" | sed \"s|{base_dir}/||\"); "
        f"  org_name=$(echo \"$rel\" | cut -d/ -f1); "
        f"  repo_name=$(echo \"$rel\" | cut -d/ -f2); "
        f"  branch=$(cd \"$d/..\" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main); "
        f"  echo \"$org_name/$repo_name:$branch\"; "
        f"done",
        timeout=20,
    )
    cloned: list[dict] = []
    if result["ok"]:
        for line in result["stdout"].splitlines():
            line = line.strip()
            if ":" not in line or "/" not in line:
                continue
            path_part, branch = line.rsplit(":", 1)
            parts = path_part.split("/", 1)
            if len(parts) == 2:
                cloned.append({"org": parts[0], "name": parts[1], "branch": branch})
    return {"repos": cloned, "total": len(cloned)}


@api_router.get("/repos")
async def api_list_repos(q: str = Query(""), org: str = Query(""), device: str = Query("")):
    """List repos across all orgs with optional search/filter."""
    dev = device or _active_device()
    repos = db_list_repos(org=org or None, query=q or None, device=dev)
    return {"repos": repos, "total": len(repos)}


@api_router.get("/repos/{org}/{repo}")
async def api_repo_detail(org: str, repo: str, device: str = Query("")):
    """Get repo details. If device is specified, fetch live status via SSH."""
    dev = device or _active_device()
    repo_data = get_repo(org, repo, device=dev)
    if not repo_data:
        raise HTTPException(404, f"Repo not found: {org}/{repo}")

    result = {"repo": repo_data}

    if device:
        # Fetch live info from device
        status = await ssh_cmd(device, f"cd ~/projects/{org}/{repo} && git rev-parse --abbrev-ref HEAD 2>/dev/null && git status --porcelain | wc -l && git log -1 --format='%ar|%s' 2>/dev/null")
        if status["ok"]:
            lines = status["stdout"].splitlines()
            result["live"] = {
                "branch": lines[0] if len(lines) > 0 else "?",
                "dirty_files": int(lines[1]) if len(lines) > 1 else 0,
                "last_commit": lines[2] if len(lines) > 2 else "?",
            }

        # Fetch branches
        branches_result = await ssh_cmd(device, f"cd ~/projects/{org}/{repo} && git branch -r --format='%(refname:short)' 2>/dev/null | head -50")
        if branches_result["ok"]:
            result["branches"] = [b.replace("origin/", "") for b in branches_result["stdout"].splitlines() if b.strip()]

        # Fetch worktrees
        wt_result = await ssh_cmd(device, f"cd ~/projects/{org}/{repo} && git worktree list --porcelain 2>/dev/null")
        if wt_result["ok"]:
            worktrees = []
            current = {}
            for line in wt_result["stdout"].splitlines():
                if line.startswith("worktree "):
                    if current:
                        worktrees.append(current)
                    current = {"path": line[9:]}
                elif line.startswith("branch "):
                    current["branch"] = line[7:].replace("refs/heads/", "")
                elif line.startswith("HEAD "):
                    current["sha"] = line[5:13]
            if current:
                worktrees.append(current)
            result["worktrees"] = worktrees

    return result


@api_router.get("/repos/{org}/{repo}/branches")
async def api_repo_branches(org: str, repo: str, device: str = Query(...)):
    """Fetch branches for a repo via SSH to a device."""
    dev = device or _active_device()
    org_data = get_org(org, device=dev)
    if not org_data:
        raise HTTPException(404, f"Org not found: {org}")

    repo_data = get_repo(org, repo, device=dev)
    default_branch = (repo_data or {}).get("default_branch", org_data.get("default_branch", "main"))
    dev = get_device(device)
    dev_user = dev["user"] if dev else "ubuntu"
    base_dir = BASE_DIR_CFG.replace("~", _resolve_home(dev_user))
    repo_dir = f"{base_dir}/{org}/{repo}"
    alias = org_data["ssh_host_alias"]

    # Try local git branches first
    result = await ssh_cmd(device, f"cd {repo_dir} 2>/dev/null && git fetch --prune -q 2>/dev/null; git branch -r --format='%(refname:short)' 2>/dev/null | sed 's|origin/||' | grep -v HEAD | sort -u")
    branches = []
    if result["ok"] and result["stdout"].strip():
        branches = [b.strip() for b in result["stdout"].splitlines() if b.strip()]

    if not branches:
        # Fallback: git ls-remote
        ls_result = await ssh_cmd(device, f"git ls-remote --heads git@{alias}:{org}/{repo}.git 2>/dev/null | awk '{{print $2}}' | sed 's|refs/heads/||' | sort")
        if ls_result["ok"] and ls_result["stdout"].strip():
            branches = [b.strip() for b in ls_result["stdout"].splitlines() if b.strip()]

    return {"branches": branches, "default": default_branch}


@api_router.post("/repos/clone")
async def api_clone_repo(req: CloneRequest):
    """Clone a repo on a target device."""
    dev = _active_device()
    org_data = get_org(req.org, device=dev)
    if not org_data:
        raise HTTPException(404, f"Org not found: {req.org}")

    alias = org_data["ssh_host_alias"]
    branch = req.branch or org_data.get("default_branch", "main")

    dev = get_device(req.device)
    dev_user = dev["user"] if dev else "ubuntu"
    base_dir = BASE_DIR_CFG.replace("~", _resolve_home(dev_user))

    clone_cmd = (
        f"mkdir -p {base_dir}/{req.org} && "
        f"cd {base_dir}/{req.org} && "
        f"git clone --branch {branch} git@{alias}:{req.org}/{req.repo}.git"
    )
    result = await ssh_cmd(req.device, clone_cmd, timeout=300)
    return {**result, "org": req.org, "repo": req.repo, "device": req.device}


# ── Routes: Devices ───────────────────────────────────────────────────────────
@api_router.get("/devices")
async def api_list_devices():
    """List all configured devices with online status."""
    devices = db_list_devices()
    for d in devices:
        if isinstance(d.get("capabilities"), str):
            try:
                d["capabilities"] = json.loads(d["capabilities"])
            except (json.JSONDecodeError, TypeError):
                d["capabilities"] = []
    return {"devices": devices}


@api_router.get("/devices/refresh")
async def api_refresh_devices():
    """Refresh device online status via Tailscale, then return device list.

    Called by the dashboard on each load to get real-time status.
    """
    devices = db_list_devices()
    ts_status = await asyncio.get_event_loop().run_in_executor(None, _tailscale_status)
    method = "tailscale" if ts_status else "none"
    for d in devices:
        if ts_status:
            peer = ts_status.get(d.get("ip", ""))
            if peer is not None:
                update_device_status(d["name"], peer["online"])
                d["online"] = 1 if peer["online"] else 0
            else:
                update_device_status(d["name"], False)
                d["online"] = 0
        if isinstance(d.get("capabilities"), str):
            try:
                d["capabilities"] = json.loads(d["capabilities"])
            except (json.JSONDecodeError, TypeError):
                d["capabilities"] = []
    return {"devices": devices, "method": method}


@api_router.get("/devices/{name}")
async def api_device_detail(name: str):
    """Get device detail including active tmux sessions."""
    device = get_device(name)
    if not device:
        raise HTTPException(404, f"Device not found: {name}")

    device = dict(device)
    if isinstance(device.get("capabilities"), str):
        try:
            device["capabilities"] = json.loads(device["capabilities"])
        except (json.JSONDecodeError, TypeError):
            device["capabilities"] = []

    # Fetch tmux sessions from the device
    sessions_result = await ssh_cmd(name, "tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null || echo ''")
    sessions = []
    if sessions_result["ok"]:
        for line in sessions_result["stdout"].splitlines():
            if not line:
                continue
            parts = line.split("|")
            sessions.append({
                "name": parts[0] if len(parts) > 0 else "",
                "windows": parts[1] if len(parts) > 1 else "0",
                "attached": parts[2] == "1" if len(parts) > 2 else False,
            })
    device["tmux_sessions"] = sessions

    # Fetch repos on device
    repos_result = await ssh_cmd(name, "find ~/projects -maxdepth 2 -name '.git' -type d 2>/dev/null | head -50")
    repos = []
    if repos_result["ok"]:
        for git_dir in repos_result["stdout"].splitlines():
            git_dir = git_dir.strip()
            if git_dir:
                repo_path = git_dir.replace("/.git", "")
                parts = repo_path.replace(os.path.expanduser("~/projects/"), "").split("/")
                if len(parts) >= 2:
                    repos.append({"org": parts[-2], "name": parts[-1], "path": repo_path})
                elif len(parts) == 1:
                    repos.append({"org": "", "name": parts[0], "path": repo_path})
    device["repos"] = repos

    return device


# ── VibeTunnel helpers ────────────────────────────────────────────────────────


def _vt_call(device_name: str, path: str, method: str = "GET",
             body: dict = None, timeout: int = 10) -> dict:
    """Call VibeTunnel's REST API on a device.

    If the device is the local device, tries 127.0.0.1 first (VT often
    binds to localhost only), then falls back to the Tailscale IP.
    Returns parsed JSON response, or {"ok": False, "error": ...} on failure.
    """
    device = get_device(device_name)
    if not device:
        return {"ok": False, "error": f"Device not found: {device_name}"}

    import urllib.request
    import urllib.error

    # Build list of IPs to try: localhost first if this is the local device
    ips_to_try = []
    if device_name == LOCAL_DEVICE or not LOCAL_DEVICE:
        ips_to_try.append("127.0.0.1")
    ips_to_try.append(device["ip"])

    last_error = ""
    for ip in ips_to_try:
        url = f"http://{ip}:{VT_PORT}/api{path}"
        try:
            data = json.dumps(body).encode() if body else None
            req = urllib.request.Request(url, data=data, method=method, headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
            })
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            return {"ok": False, "error": f"HTTP {e.code}", "detail": e.read().decode()[:200]}
        except Exception as e:
            last_error = str(e)
            continue  # try next IP
    return {"ok": False, "error": last_error}


def _vt_attach_sync(device_name: str, tmux_session: str) -> dict:
    """Attach VibeTunnel to a tmux session (blocking call)."""
    return _vt_call(device_name, "/tmux/attach", method="POST", body={
        "sessionName": tmux_session,
        "cols": 120,
        "rows": 40,
    })


def _vt_session_status_sync(device_name: str, vt_session_id: str) -> dict:
    """Get VibeTunnel session status (blocking call)."""
    return _vt_call(device_name, f"/sessions/{vt_session_id}")


async def _poll_vt_sessions():
    """Background task: sync VT session status for all running jobs.

    Also tries to auto-attach VT for running jobs that are missing VT sessions.
    """
    await asyncio.sleep(10)  # initial delay
    while True:
        try:
            running_jobs, _ = db_list_jobs(status="running", device=_active_device())
            for job in running_jobs:
                if job.get("vt_session_id"):
                    # Check status of existing VT sessions
                    try:
                        vt_result = await asyncio.get_event_loop().run_in_executor(
                            None,
                            lambda j=job: _vt_session_status_sync(j["device"], j["vt_session_id"])
                        )
                        if vt_result.get("status") == "exited":
                            update_job_status(job["id"], "completed", device=job["device"])
                    except Exception:
                        pass  # VT may be unreachable
                elif job.get("tmux_session"):
                    # Auto-attach VT for running jobs missing VT session
                    try:
                        vt_result = await asyncio.get_event_loop().run_in_executor(
                            None,
                            lambda j=job: _vt_attach_sync(j["device"], j["tmux_session"])
                        )
                        if vt_result.get("success") and vt_result.get("sessionId"):
                            device_data = get_device(job["device"])
                            if device_data:
                                vt_sid = vt_result["sessionId"]
                                vt_url = f"http://{_device_dns_name(job['device'])}:{VT_PORT}/"
                                update_job_vt_session(job["id"], vt_sid, vt_url, device=job["device"])
                    except Exception:
                        pass
        except Exception:
            pass  # don't crash the background task
        await asyncio.sleep(30)

# ── Tailscale status helper ──────────────────────────────────────────────────

TAILSCALE_SOCK = "/var/run/tailscale/tailscaled.sock"
TAILSCALE_API_KEY = os.environ.get("TAILSCALE_API_KEY", "")


def _tailscale_status_via_cli() -> dict:
    """Try `tailscale status --json` CLI.  Works if tailscale is on $PATH.

    This is the most reliable method in Docker with network_mode=host because
    the host's tailscale binary is accessible.
    """
    import subprocess
    try:
        cp = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True, text=True, timeout=10,
        )
        if cp.returncode != 0:
            print(f"[tailscale] CLI failed (rc={cp.returncode}): {cp.stderr.strip()}")
            return {}
        status = json.loads(cp.stdout)
        result = {}
        # Self node
        self_node = status.get("Self", {})
        dns_name = self_node.get("DNSName", "").rstrip(".")
        online = self_node.get("Online", True)
        for ip in self_node.get("TailscaleIPs", []):
            result[ip] = {"online": online, "hostname": self_node.get("HostName", ""), "dns_name": dns_name}
        # Peers
        for _key, peer in status.get("Peer", {}).items():
            peer_dns = peer.get("DNSName", "").rstrip(".")
            peer_online = peer.get("Online", False)
            for ip in peer.get("TailscaleIPs", []):
                result[ip] = {"online": peer_online, "hostname": peer.get("HostName", ""), "dns_name": peer_dns}
        print(f"[tailscale] CLI: found {len(result)} peer IPs")
        return result
    except FileNotFoundError:
        print("[tailscale] CLI: 'tailscale' command not found")
        return {}
    except Exception as e:
        print(f"[tailscale] CLI error: {e}")
        return {}


def _tailscale_status_via_socket() -> dict:
    """Try Tailscale LocalAPI Unix socket. Returns peer map or empty dict."""
    import socket as sock
    try:
        s = sock.socket(sock.AF_UNIX, sock.SOCK_STREAM)
        s.settimeout(5)
        s.connect(TAILSCALE_SOCK)
        s.sendall(b"GET /localapi/v0/status HTTP/1.0\r\nHost: local\r\n\r\n")
        data = b""
        while True:
            chunk = s.recv(8192)
            if not chunk:
                break
            data += chunk
        s.close()
        body = data.split(b"\r\n\r\n", 1)[1]
        status = json.loads(body)
        result = {}
        # Self node
        self_node = status.get("Self", {})
        dns_name = self_node.get("DNSName", "").rstrip(".")
        for ip in self_node.get("TailscaleIPs", []):
            result[ip] = {"online": True, "hostname": self_node.get("HostName", ""), "dns_name": dns_name}
        # Peers
        for _key, peer in status.get("Peer", {}).items():
            peer_dns = peer.get("DNSName", "").rstrip(".")
            for ip in peer.get("TailscaleIPs", []):
                result[ip] = {"online": peer.get("Online", False), "hostname": peer.get("HostName", ""), "dns_name": peer_dns}
        print(f"[tailscale] Socket: found {len(result)} peer IPs")
        return result
    except Exception as e:
        print(f"[tailscale] Socket unavailable ({TAILSCALE_SOCK}): {e}")
        return {}


def _tailscale_status_via_api() -> dict:
    """Try Tailscale HTTP API. Returns peer map or empty dict."""
    if not TAILSCALE_API_KEY:
        print("[tailscale] HTTP API: TAILSCALE_API_KEY not set, skipping")
        return {}
    import urllib.request
    try:
        req = urllib.request.Request(
            "https://api.tailscale.com/api/v2/tailnet/-/devices",
            headers={"Authorization": f"Bearer {TAILSCALE_API_KEY}"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        result = {}
        for device in data.get("devices", []):
            is_online = device.get("online", False)
            hostname = device.get("hostname", "")
            dns_name = device.get("name", "").rstrip(".")
            for addr in device.get("addresses", []):
                result[addr] = {"online": is_online, "hostname": hostname, "dns_name": dns_name}
        print(f"[tailscale] HTTP API: found {len(result)} device IPs")
        return result
    except Exception as e:
        print(f"[tailscale] HTTP API failed: {e}")
        return {}


def _tailscale_status() -> dict:
    """Get Tailscale peer status.

    Tries in order: CLI → LocalAPI socket → HTTP API.
    Returns dict mapping Tailscale IP -> {"online": bool, "hostname": str, "dns_name": str}
    or empty dict if all methods fail.
    """
    # 1. CLI — most reliable, works on host with network_mode=host
    result = _tailscale_status_via_cli()
    if result:
        return result
    # 2. LocalAPI Unix socket
    result = _tailscale_status_via_socket()
    if result:
        return result
    # 3. HTTP API (needs TAILSCALE_API_KEY)
    return _tailscale_status_via_api()


def _device_dns_name(device_name: str) -> str:
    """Get MagicDNS hostname for a device (e.g. 'myserver.tail389322.ts.net').

    Falls back to device IP if Tailscale status unavailable.
    """
    device = get_device(device_name)
    if not device:
        return device_name
    ts_status = _tailscale_status()
    peer = ts_status.get(device.get("ip", ""))
    if peer and peer.get("dns_name"):
        return peer["dns_name"]
    return device.get("ip", device_name)


@api_router.post("/devices/{name}/ping")
async def api_ping_device(name: str):
    """Check if a device is reachable (via Tailscale status, fallback to SSH)."""
    device = get_device(name)
    if not device:
        return {"device": name, "online": False, "detail": "Device not found"}

    # Try Tailscale status first (fast, works for all device types)
    ts_status = await asyncio.get_event_loop().run_in_executor(None, _tailscale_status)
    if ts_status:
        peer = ts_status.get(device.get("ip", ""))
        if peer is not None:
            online = peer["online"]
            update_device_status(name, online)
            return {"device": name, "online": online, "method": "tailscale"}

    # Fallback to SSH
    result = await ssh_cmd(name, "echo ok", timeout=15)
    online = result["ok"] and result["stdout"].strip() == "ok"
    update_device_status(name, online)
    return {"device": name, "online": online, "method": "ssh", "detail": result}


@api_router.post("/devices/ping-all")
async def api_ping_all():
    """Check all devices via Tailscale status (fast, single call), fallback to SSH."""
    devices = db_list_devices()
    results = {}

    # Try Tailscale status first — one call covers all devices
    ts_status = await asyncio.get_event_loop().run_in_executor(None, _tailscale_status)
    if ts_status:
        all_resolved = True
        for d in devices:
            peer = ts_status.get(d.get("ip", ""))
            if peer is not None:
                online = peer["online"]
                update_device_status(d["name"], online)
                results[d["name"]] = {"device": d["name"], "online": online, "method": "tailscale"}
            else:
                all_resolved = False
        if all_resolved:
            return {"results": results}

    # Fallback: SSH ping for any unresolved devices
    for d in devices:
        if d["name"] not in results:
            try:
                r = await api_ping_device(d["name"])
                results[d["name"]] = r
            except Exception as e:
                results[d["name"]] = {"online": False, "error": str(e)}

    return {"results": results}



# ── Routes: Jobs ──────────────────────────────────────────────────────────────
@api_router.post("/jobs")
async def api_create_job(req: JobRequest):
    """Issue a command/action on a remote device. Returns job ID + connect command."""
    device = get_device(req.device)
    if not device:
        raise HTTPException(404, f"Device not found: {req.device}")

    ssh_target = f"{device['user']}@{device['ip']}"
    base_dir = BASE_DIR_CFG.replace("~", _resolve_home(device['user']))
    repo_dir = f"{base_dir}/{req.org}/{req.repo}" if req.org and req.repo else ""

    # Resolve org data and branch
    org_data = get_org(req.org, device=req.device) if req.org else None
    alias = org_data["ssh_host_alias"] if org_data else "github.com"
    branch = req.branch or (org_data.get("default_branch", "main") if org_data else "main")

    # Helper: build a clone-or-pull preamble for actions that need the repo ready
    def _repo_setup_cmd() -> str:
        """Returns a shell snippet that ensures the repo is cloned and optionally pulled."""
        if not repo_dir:
            return ""
        clone_part = (
            f"if [ ! -d {repo_dir}/.git ]; then "
            f"mkdir -p {base_dir}/{req.org} && "
            f"git clone --branch {branch} git@{alias}:{req.org}/{req.repo}.git {repo_dir}; "
            f"fi"
        )
        pull_part = ""
        if req.pull_latest:
            pull_part = f" && cd {repo_dir} && git checkout {branch} 2>/dev/null; git pull --ff-only 2>/dev/null || true"
        return f"{clone_part}{pull_part}"

    # Build the remote command based on action
    # NOTE: VibeTunnel (vt) is NOT wrapped around commands inside tmux sessions.
    # vt requires an interactive TTY and crashes in detached tmux.
    # VibeTunnel's daemon discovers tmux sessions automatically.
    tmux_session = ""
    remote_cmd = req.command  # default: custom command

    # Helper: generate unique tmux session name (appends -2, -3, ... if already exists)
    async def _unique_session_name(device: str, base_name: str) -> str:
        result = await ssh_cmd(device, "tmux list-sessions -F '#{session_name}' 2>/dev/null", timeout=10)
        existing = set(result["stdout"].splitlines()) if result["ok"] else set()
        if base_name not in existing:
            return base_name
        for i in range(2, 100):
            candidate = f"{base_name}-{i}"
            if candidate not in existing:
                return candidate
        return f"{base_name}-{int(time.time()) % 10000}"

    if req.action == "clone":
        remote_cmd = f"mkdir -p {base_dir}/{req.org} && cd {base_dir}/{req.org} && git clone --branch {branch} git@{alias}:{req.org}/{req.repo}.git"

    elif req.action == "pull":
        remote_cmd = f"cd {repo_dir} && git pull"

    elif req.action == "conductor":
        tmux_session = await _unique_session_name(req.device, f"{req.repo}-conductor")
        # Read conductor config from defaults.yaml
        cfg = load_config()
        conductor_cfg = cfg.get("conductor", {})
        model = conductor_cfg.get("gemini_model", os.environ.get("GEMINI_MODEL", "gemini-2.5-pro"))
        tasks_file = conductor_cfg.get("task_output_file", "TASKS.md")
        setup = _repo_setup_cmd()
        setup_prefix = f"{setup} && " if setup else ""
        # Scaffold TASKS.md if it doesn't exist
        scaffold = (
            f"if [ ! -f {repo_dir}/{tasks_file} ]; then "
            f"cat > {repo_dir}/{tasks_file} << 'TMPL'\n"
            f"# TASKS.md — Agent Task Backlog\n"
            f"# Generated by Gemini Conductor. Each task must pass the ATC filter:\n"
            f"# Self-Contained | Verifiable | Bounded | Parallelizable | Resume-safe\n\n"
            f"## Active\n\n## In Progress\n\n## Done\n"
            f"TMPL\n"
            f"fi"
        )
        cli = f"gemini --model={model}"
        remote_cmd = f"{setup_prefix}{scaffold} && tmux new-session -d -s {tmux_session} -c {repo_dir} '{cli}'"

    elif req.action == "dispatch":
        safe_branch = req.branch.replace("/", "-").lower() if req.branch else "work"

        # ── Idempotency check: reuse existing running job ──
        # Check by task_id first (most specific), then by repo+branch
        existing = None
        if req.task_id:
            existing = find_running_job_by_task_id(req.task_id, device=req.device)
        if not existing:
            existing = find_running_job(req.repo, req.branch, device=req.device)
        if existing and existing.get("tmux_session"):
            sess_check = await ssh_cmd(req.device, f"tmux has-session -t {existing['tmux_session']} 2>/dev/null && echo ALIVE || echo DEAD", timeout=10)
            if sess_check["ok"] and "ALIVE" in sess_check["stdout"]:
                return {
                    "job_id": existing["id"],
                    "already_running": True,
                    "tmux_session": existing["tmux_session"],
                    "connect_cmd": existing.get("connect_cmd", ""),
                    "vt_url": existing.get("vt_url"),
                    "message": f"Session '{existing['tmux_session']}' already running for {req.repo}/{req.branch}",
                }
            else:
                # Session dead — mark old job as failed
                update_job_status(existing["id"], "failed", device=req.device)
                append_job_log(existing["id"], "Session not found on device — marked as failed", device=req.device)

        tmux_session = await _unique_session_name(req.device, f"{req.repo}-{safe_branch}")

        # Resolve base_branch: from request, task DB, org setting, or default 'main'
        base_branch = req.base_branch or branch  # user-specified > org default > 'main'
        task_id_for_job = None
        task_data = None
        subtasks_data = []
        try:
            _set_task_device(req.device)
            from task_db import (
                add_task as _add_task,
                get_task_with_subtasks, query_tasks,
            )

            # 1) Explicit task_id provided → use that task
            if req.task_id:
                task_data = get_task_with_subtasks(req.task_id)
                if task_data:
                    task_id_for_job = req.task_id
                    if task_data.get("base_branch"):
                        base_branch = task_data["base_branch"]
                    subtasks_data = task_data.get("subtasks", [])

            # 2) No task_id but title/description → auto-create task
            if not task_id_for_job and (req.title or req.task):
                auto_branch = req.branch or f"task/{req.repo}-{int(time.time()) % 100000}"
                try:
                    new_id = _add_task(
                        repo=req.repo,
                        title=req.title or req.task[:120],
                        branch=auto_branch,
                        description=req.task or req.title,
                        created_by=f"{req.cli or 'webapp'}-dispatch",
                        created_by_cli=req.cli or "webapp",
                    )
                    task_id_for_job = new_id
                    task_data = get_task_with_subtasks(new_id)
                    subtasks_data = task_data.get("subtasks", []) if task_data else []
                    # Use auto_branch as the actual branch
                    if not req.branch:
                        req.branch = auto_branch
                        safe_branch = auto_branch.replace("/", "-").lower()
                except Exception as exc:
                    append_job_log(0, f"Auto-create task failed: {exc}")

            # 3) Fallback: match by branch
            if not task_id_for_job:
                matching = query_tasks(repo=req.repo, branch=req.branch, limit=1)
                if matching:
                    t = matching[0]
                    task_id_for_job = t["id"]
                    if t.get("base_branch"):
                        base_branch = t["base_branch"]
                    task_data = get_task_with_subtasks(t["id"])
                    if task_data:
                        subtasks_data = task_data.get("subtasks", [])
        except Exception:
            pass  # task_db not available — proceed with defaults

        # ── Ensure work branch != base branch ──
        # Git won't allow a worktree on a branch that's already checked out
        if not req.branch or req.branch == base_branch:
            if task_data and task_data.get("title"):
                slug = re.sub(r'[^a-z0-9]+', '-', task_data["title"].lower())[:40].strip('-')
                req.branch = f"task/{slug}"
            elif req.title:
                slug = re.sub(r'[^a-z0-9]+', '-', req.title.lower())[:40].strip('-')
                req.branch = f"task/{slug}"
            else:
                req.branch = f"task/{req.repo}-{int(time.time()) % 100000}"
            safe_branch = req.branch.replace("/", "-").lower()

        # ── Build rich WORKTREE.md content ──
        worktree_md_content = _build_dispatch_worktree_md(
            task_id_for_job, task_data, subtasks_data, req, repo_dir,
        )

        # ── Read CLI model from config ──
        cfg = load_config()
        conductor_cfg = cfg.get("conductor", {})
        claude_model = conductor_cfg.get("claude_model", os.environ.get("CLAUDE_MODEL", "sonnet"))
        gemini_model = conductor_cfg.get("gemini_model", os.environ.get("GEMINI_MODEL", "gemini-2.5-pro"))
        codex_model = conductor_cfg.get("codex_model", os.environ.get("CODEX_MODEL", ""))

        # ── Launch CLI interactively (NOT -p one-shot) ──
        # Read launch_args from config/cli/{cli}.yaml (same as worktree.sh)
        # Fallback to known auto-approve flags if config unavailable
        cli_name = req.cli or "claude"
        cli_args_str = ""
        try:
            cli_cfg_path = CONFIG_DIR / "cli" / f"{cli_name}.yaml"
            if cli_cfg_path.exists():
                import yaml as _yaml
                cli_cfg_data = _yaml.safe_load(cli_cfg_path.read_text()) or {}
                launch_args_list = cli_cfg_data.get("launch_args", [])
                cli_args_str = " ".join(str(a) for a in launch_args_list)
        except Exception:
            pass  # fallback to defaults below

        if not cli_args_str:
            # Defaults when config is missing
            if cli_name == "claude":
                cli_args_str = "--dangerously-skip-permissions"
            elif cli_name == "gemini":
                cli_args_str = "--sandbox=none"
            elif cli_name == "codex":
                cli_args_str = "--full-auto"

        if cli_name == "claude":
            cli_cmd = f"claude --model {claude_model} {cli_args_str}"
        elif cli_name == "gemini":
            cli_cmd = f"gemini --model {gemini_model} {cli_args_str}"
        elif cli_name == "codex":
            cli_cmd = f"codex {cli_args_str}" if not codex_model else f"codex {cli_args_str} -m {codex_model}"
        else:
            cli_cmd = f"claude --model {claude_model} {cli_args_str}"

        # The initial prompt sent after CLI starts up
        has_subtasks = len(subtasks_data) > 0
        if has_subtasks:
            agent_prompt = (
                "Read WORKTREE.md and implement the task. Follow the subtask checklist — "
                "mark each subtask done as you complete it. When all subtasks are done: "
                "run tests, commit, push branch, create a PR with `gh pr create`, "
                "create PROOF.md, then exit."
            )
        else:
            agent_prompt = (
                "Read WORKTREE.md. First, break the task into 3-7 concrete subtasks and "
                "list them as a checklist in WORKTREE.md. Then implement each subtask, "
                "checking them off as you go. When done: run tests, commit, push branch, "
                "create a PR with `gh pr create`, create PROOF.md, then exit."
            )

        setup = _repo_setup_cmd()
        setup_prefix = f"{setup} && " if setup else ""
        wt_dir = f".trees/{safe_branch}"
        # Robust worktree setup with git fetch and base_branch:
        # 1. Fetch latest from origin and prune stale worktrees
        # 2. If worktree dir exists, reuse it (cd into it)
        # 3. If not, try to attach existing branch, then create new with -B
        #    (-B force-creates or resets, avoiding 'branch already exists' errors)
        worktree_setup = (
            f"git fetch origin 2>/dev/null; "
            f"git worktree prune 2>/dev/null; "
            f"if [ -d {wt_dir} ]; then "
            f"  cd {wt_dir} && git checkout {req.branch} 2>/dev/null || true; "
            f"else "
            f"  git worktree add {wt_dir} {req.branch} 2>/dev/null || "
            f"  git worktree add -B {req.branch} {wt_dir} origin/{base_branch} 2>/dev/null || "
            f"  git worktree add -B {req.branch} {wt_dir} {base_branch} 2>/dev/null || "
            f"  (mkdir -p {wt_dir} && git worktree add {wt_dir} HEAD 2>/dev/null && "
            f"   cd {wt_dir} && git checkout -B {req.branch} 2>/dev/null); "
            f"fi"
        )
        # Escape worktree_md_content for heredoc (use single-quoted delimiter)
        worktree_init = (
            f"cat > {repo_dir}/{wt_dir}/WORKTREE.md << 'WTEOF'\n"
            f"{worktree_md_content}\n"
            f"WTEOF\n"
            # Copy agent config files if they exist
            f"for f in .env CLAUDE.md GEMINI.md AGENTS.md; do "
            f"  [ -f {repo_dir}/$f ] && cp {repo_dir}/$f {repo_dir}/{wt_dir}/ 2>/dev/null; "
            f"done; "
            # Auto-attach named env files from ~/.tenai_envs/
            # If explicit env_file is set, use that; otherwise auto-detect
            f"if [ -n '{req.env_file}' ] && [ '{req.env_file}' != 'none' ] && [ -f $HOME/.tenai_envs/{req.env_file} ]; then "
            f"  cat $HOME/.tenai_envs/{req.env_file} >> {repo_dir}/{wt_dir}/.env 2>/dev/null; "
            f"elif [ -z '{req.env_file}' ]; then "
            f"  for envf in $HOME/.tenai_envs/{req.org}--{req.repo}.env "
            f"  $HOME/.tenai_envs/{req.repo}.env; do "
            f"    [ -f \"$envf\" ] && cat \"$envf\" >> {repo_dir}/{wt_dir}/.env 2>/dev/null && break; "
            f"  done; "
            f"fi; "
            # Symlink agent config dirs (avoid copying skills/ which causes conflicts)
            f"for d in .claude .gemini .codex; do "
            f"  [ -d {repo_dir}/$d ] && [ ! -e {repo_dir}/{wt_dir}/$d ] && "
            f"  ln -s {repo_dir}/$d {repo_dir}/{wt_dir}/$d 2>/dev/null; "
            f"done; "
            f"true"  # ensure exit 0 regardless of which dirs/files exist
        )

        # Launch CLI in tmux — prompt is sent SEPARATELY via async task
        # because CLI init (auth, MCP, extensions) can take 15-30 seconds.
        # Pre-trust the worktree dir for Claude to skip "trust this folder?" prompt
        trust_cmd = ""
        if req.cli == "claude" or (req.cli not in ("gemini", "codex")):
            trust_cmd = (
                f"claude config add trustedDirectories {repo_dir}/{wt_dir} "
                f"2>/dev/null; true && "
            )

        # Pre-auth gh CLI with org's GitHub token
        gh_auth_cmd = ""
        try:
            org_cfg = cfg.get("organizations", {}).get(req.org, {})
            token_name = org_cfg.get("github_api_token_name", "GITHUB_TOKEN")
            gh_token = os.environ.get(token_name, "")
            if gh_token:
                # Send token to gh auth + export as env var for the tmux session
                gh_auth_cmd = (
                    f"echo '{gh_token}' | gh auth login --with-token 2>/dev/null; true && "
                    f"export GH_TOKEN='{gh_token}' && "
                )
        except Exception:
            pass  # proceed without gh auth

        remote_cmd = (
            f"{setup_prefix}"
            f"cd {repo_dir} && "
            f"mkdir -p .trees && "
            f"{worktree_setup} && "
            f"{worktree_init} && "
            f"{trust_cmd}"
            f"{gh_auth_cmd}"
            # Kill any stale session with same name (from failed previous jobs)
            f"tmux kill-session -t {tmux_session} 2>/dev/null; true && "
            f"tmux new-session -d -s {tmux_session} -c {repo_dir}/{wt_dir} && "
            f"tmux set-option -t {tmux_session} remain-on-exit on && "
            f"tmux send-keys -t {tmux_session} '{cli_cmd}' Enter"
        )
        # Store prompt for deferred delivery
        _deferred_prompt = agent_prompt

    elif req.action == "shell":
        base_name = f"shell-{req.device}"
        if repo_dir:
            base_name = f"shell-{req.org}-{req.repo}"
        tmux_session = await _unique_session_name(req.device, base_name)
        setup = _repo_setup_cmd()
        setup_prefix = f"{setup} && " if setup else ""
        shell_cmd = "$SHELL -l"
        remote_cmd = f"{setup_prefix}tmux new-session -d -s {tmux_session} -c {repo_dir or '$HOME'} '{shell_cmd}'"

    # Build connect command
    connect_cmd = ""
    if tmux_session:
        connect_cmd = f"mosh {ssh_target} -- tmux attach -t {tmux_session}"

    # Execute
    result = await ssh_cmd(req.device, remote_cmd, timeout=300)

    # Persist job with task linkage + worktree_md
    task_id_val = task_id_for_job if req.action == "dispatch" else None
    wt_md_val = worktree_md_content if req.action == "dispatch" else ""
    job_id = create_job(
        device=req.device,
        command=remote_cmd,
        org=req.org,
        repo=req.repo,
        cli=req.cli,
        tmux_session=tmux_session,
        connect_cmd=connect_cmd,
        action=req.action,
        branch=req.branch,
        task_id=task_id_val,
        worktree_md=wt_md_val,
        agent_prompt=_deferred_prompt if '_deferred_prompt' in dir() else "",
    )

    if not result["ok"]:
        update_job_status(job_id, "failed", device=req.device)
        if result["stderr"]:
            append_job_log(job_id, f"ERROR: {result['stderr']}", device=req.device)
    else:
        if result["stdout"]:
            append_job_log(job_id, result["stdout"], device=req.device)

    # ── VibeTunnel integration: attach tmux session to VT browser terminal ──
    vt_session_id = ""
    vt_url = ""
    if tmux_session and result["ok"]:
        try:
            vt_result = await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: _vt_attach_sync(req.device, tmux_session)
            )
            if vt_result.get("success") and vt_result.get("sessionId"):
                vt_session_id = vt_result["sessionId"]
                vt_url = f"http://{_device_dns_name(req.device)}:{VT_PORT}/"
                update_job_vt_session(job_id, vt_session_id, vt_url, device=req.device)
                append_job_log(job_id, f"VT terminal: {vt_url}", device=req.device)
            else:
                err = vt_result.get("error", "unknown")
                append_job_log(job_id, f"VT attach skipped: {err}", device=req.device)
        except Exception as e:
            append_job_log(job_id, f"VT attach failed: {e}", device=req.device)

    # ── Deferred agent prompt delivery ──
    # CLI init takes 15-30s; send the prompt after CLI is ready.
    if req.action == "dispatch" and result["ok"] and tmux_session:
        prompt_to_send = _deferred_prompt if '_deferred_prompt' in dir() else ""
        if prompt_to_send:
            async def _send_deferred_prompt(
                dev: str, session: str, prompt: str, jid: int
            ):
                """Wait for CLI to be ready, then send the task prompt."""
                for attempt in range(12):  # ~60s max (12 * 5s)
                    await asyncio.sleep(5)
                    # Check if tmux pane shows a ready indicator
                    check = await ssh_cmd(
                        dev,
                        f"tmux capture-pane -t {session} -p 2>/dev/null | "
                        f"tail -20",
                        timeout=10,
                    )
                    output = check.get("stdout", "")

                    # ── Auto-accept Claude "Bypass Permissions" confirmation ──
                    # Claude Code shows a numbered menu:
                    #   1. No, exit
                    #   2. Yes, I accept
                    # Send "2" to accept it so the agent can proceed.
                    bypass_markers = [
                        "Bypass Permissions",
                        "Yes, I accept",
                        "dangerously-skip-permissions",
                    ]
                    if any(m in output for m in bypass_markers) and "No, exit" in output:
                        await ssh_cmd(
                            dev,
                            f"tmux send-keys -t {session} 2 Enter",
                            timeout=10,
                        )
                        append_job_log(
                            jid,
                            f"Auto-accepted Bypass Permissions prompt (attempt {attempt + 1})",
                            device=dev,
                        )
                        continue  # re-check for CLI ready on next iteration

                    # Look for CLI ready markers
                    ready_markers = [
                        "Type your message",  # gemini
                        ">",  # generic prompt
                        "claude>",  # claude
                        "What can I help",  # claude
                    ]
                    if any(m in output for m in ready_markers):
                        # CLI is ready — send prompt: literal text then Enter separately
                        escaped = prompt.replace("'", "'\\''")
                        await ssh_cmd(
                            dev,
                            f"tmux send-keys -t {session} -l '{escaped}'",
                            timeout=10,
                        )
                        await asyncio.sleep(0.3)
                        await ssh_cmd(
                            dev,
                            f"tmux send-keys -t {session} Enter",
                            timeout=10,
                        )
                        append_job_log(
                            jid,
                            f"Agent prompt sent (attempt {attempt + 1})",
                            device=dev,
                        )
                        return
                # Fallback: send anyway after timeout
                escaped = prompt.replace("'", "'\\''")
                await ssh_cmd(
                    dev,
                    f"tmux send-keys -t {session} -l '{escaped}'",
                    timeout=10,
                )
                await asyncio.sleep(0.3)
                await ssh_cmd(
                    dev,
                    f"tmux send-keys -t {session} Enter",
                    timeout=10,
                )
                append_job_log(
                    jid,
                    "Agent prompt sent (fallback after 60s)",
                    device=dev,
                )

            asyncio.ensure_future(
                _send_deferred_prompt(
                    req.device, tmux_session, prompt_to_send, job_id
                )
            )

    return {
        "job_id": job_id,
        "ok": result["ok"],
        "connect_cmd": connect_cmd,
        "tmux_session": tmux_session,
        "vt_session_id": vt_session_id,
        "vt_url": vt_url,
        "stdout": result["stdout"],
        "stderr": result["stderr"],
    }



@api_router.get("/jobs")
async def api_list_jobs(device: str = Query(""), status: str = Query(""),
                        org: str = Query(""), repo: str = Query(""),
                        limit: int = Query(20), offset: int = Query(0)):
    """List jobs with optional filters and pagination."""
    dev = device or _active_device()
    jobs, total = db_list_jobs(
        status=status or None,
        org=org or None,
        repo=repo or None,
        limit=limit,
        offset=offset,
        device=dev,
    )
    # Enrich with task titles
    try:
        _set_task_device(dev)
        from task_db import get_task_with_subtasks
        for j in jobs:
            tid = j.get("task_id")
            if tid:
                t = get_task_with_subtasks(tid)
                if t:
                    j["task_title"] = t.get("title", "")
    except Exception:
        pass
    return {"jobs": jobs, "total": total, "limit": limit, "offset": offset}


@api_router.get("/jobs/{job_id}")
async def api_job_detail(job_id: int, device: str = Query("")):
    """Get job detail with log tail + task progress."""
    dev = device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")
    logs = get_job_logs(job_id, device=dev)
    result = {**job, "logs": logs}
    # Include task progress and title if linked
    if job.get("task_id"):
        try:
            _set_task_device(dev)
            from task_db import compute_task_progress, get_task_with_subtasks
            task = get_task_with_subtasks(job["task_id"])
            if task:
                result["task_title"] = task.get("title", "")
                result["progress"] = compute_task_progress(job["task_id"])
        except Exception:
            pass
    return result


@api_router.get("/jobs/{job_id}/worktree-md")
async def api_job_worktree_md(job_id: int, device: str = Query("")):
    """Get WORKTREE.md content for a job (persisted in DB)."""
    dev = device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")
    # Try persisted worktree_md first
    if job.get("worktree_md"):
        return {"job_id": job_id, "content": job["worktree_md"]}
    # Fallback: generate from task_db if task_id available
    if job.get("task_id"):
        try:
            _set_task_device(dev)
            from task_db import build_worktree_md, get_task_with_subtasks
            task = get_task_with_subtasks(job["task_id"])
            if task:
                md = build_worktree_md(task, subtasks=task.get("subtasks", []))
                return {"job_id": job_id, "content": md}
        except Exception:
            pass
    return {"job_id": job_id, "content": "No WORKTREE.md content available"}


@api_router.post("/jobs/{job_id}/log")
async def api_job_append_log(job_id: int, req: dict = Body(...), device: str = Query("")):
    """Append a log line to a job (used by CLI agents via curl)."""
    dev = device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")
    line = req.get("line", "")
    if not line:
        raise HTTPException(400, "Missing 'line' field")
    append_job_log(job_id, line, device=dev)
    return {"ok": True, "job_id": job_id}


@api_router.get("/jobs/{job_id}/vt-status")
async def api_job_vt_status(job_id: int, device: str = Query("")):
    """Check VibeTunnel session status for a job."""
    dev = device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")
    if not job.get("vt_session_id"):
        return {"status": "unknown", "has_vt": False}

    try:
        vt_result = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: _vt_session_status_sync(job["device"], job["vt_session_id"])
        )
        vt_status = vt_result.get("status", "unknown")
        if vt_status == "exited" and job["status"] == "running":
            update_job_status(job_id, "completed", device=dev)
        return {"status": vt_status, "has_vt": True, "vt_url": job.get("vt_url", "")}
    except Exception:
        return {"status": "unknown", "has_vt": True, "vt_url": job.get("vt_url", "")}


@api_router.post("/jobs/{job_id}/vt-attach")
async def api_job_vt_attach(job_id: int, device: str = Query("")):
    """Manually attach VibeTunnel to a running job's tmux session."""
    dev = device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")
    if job["status"] != "running":
        raise HTTPException(400, "Can only attach VT to running jobs")
    if not job.get("tmux_session"):
        raise HTTPException(400, "Job has no tmux session to attach")
    if job.get("vt_session_id"):
        return {"already_attached": True, "vt_url": job["vt_url"], "vt_session_id": job["vt_session_id"]}

    try:
        vt_result = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: _vt_attach_sync(job["device"], job["tmux_session"])
        )
        if vt_result.get("success") and vt_result.get("sessionId"):
            vt_session_id = vt_result["sessionId"]
            vt_url = f"http://{_device_dns_name(job['device'])}:{VT_PORT}/"
            update_job_vt_session(job_id, vt_session_id, vt_url, device=dev)
            append_job_log(job_id, f"VT terminal attached: {vt_url}", device=dev)
            return {"ok": True, "vt_session_id": vt_session_id, "vt_url": vt_url}
        else:
            err = vt_result.get("error", "unknown")
            return {"ok": False, "error": err}
    except Exception as e:
        raise HTTPException(500, f"VT attach failed: {e}") from e


@api_router.get("/jobs/{job_id}/connect")
async def api_job_connect(job_id: int, device: str = Query("")):
    """Get the mosh/tmux command to connect to a running job."""
    dev = device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")
    return {"connect_cmd": job.get("connect_cmd", ""), "tmux_session": job.get("tmux_session", "")}


@api_router.delete("/jobs/{job_id}")
async def api_kill_or_delete_job(job_id: int, device: str = Query("")):
    """Kill a running job or delete a completed/failed job."""
    dev = device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")

    if job.get("status") == "running":
        if job.get("tmux_session") and job.get("device"):
            await ssh_cmd(job["device"], f"tmux kill-session -t {job['tmux_session']} 2>/dev/null || true")
        update_job_status(job_id, "killed", device=dev)
        return {"ok": True, "job_id": job_id, "action": "killed"}
    else:
        db_delete_job(job_id, device=dev)
        return {"ok": True, "job_id": job_id, "action": "deleted"}


class BatchDeleteJobsRequest(BaseModel):
    job_ids: list[int]


@api_router.post("/jobs-batch-delete")
async def api_batch_delete_jobs(req: BatchDeleteJobsRequest,
                                device: str = Query("")):
    """Delete or kill multiple jobs at once."""
    dev = device or _active_device()
    results = []
    for jid in req.job_ids:
        job = get_job(jid, device=dev)
        if not job:
            results.append({"job_id": jid, "action": "not_found"})
            continue
        if job.get("status") == "running":
            if job.get("tmux_session") and job.get("device"):
                await ssh_cmd(job["device"],
                              f"tmux kill-session -t {job['tmux_session']} "
                              "2>/dev/null || true")
            update_job_status(jid, "killed", device=dev)
            results.append({"job_id": jid, "action": "killed"})
        else:
            db_delete_job(jid, device=dev)
            results.append({"job_id": jid, "action": "deleted"})
    return {"ok": True, "results": results}


@api_router.post("/jobs/{job_id}/send-keys")
async def api_job_send_keys(job_id: int, req: SendKeysRequest):
    """Send keys to a running job's tmux session."""
    dev = req.device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")
    session = job.get("tmux_session")
    if not session:
        raise HTTPException(400, "Job has no tmux session")
    # Use -l (literal) for the text, then send Enter separately
    # This ensures TUI apps like Gemini CLI properly receive the input
    escaped = req.keys.replace("'", "'\\''")
    result = await ssh_cmd(
        dev,
        f"tmux send-keys -t {session} -l '{escaped}'",
        timeout=10,
    )
    if result["ok"]:
        await asyncio.sleep(0.3)
        await ssh_cmd(
            dev,
            f"tmux send-keys -t {session} Enter",
            timeout=10,
        )
    # Log the sent message
    preview = req.keys[:80] + ("…" if len(req.keys) > 80 else "")
    append_job_log(job_id, f"User message: {preview}", device=dev)
    return {"ok": result["ok"], "stderr": result.get("stderr", "")}


@api_router.post("/jobs/{job_id}/send-special-key")
async def api_job_send_special_key(job_id: int, req: SendKeysRequest):
    """Send a special key (arrows, Escape, Ctrl-C etc.) to a tmux session.

    Unlike send-keys which uses -l (literal) + Enter, this sends the key
    name directly so tmux interprets it as a special key.
    """
    dev = req.device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")
    session = job.get("tmux_session")
    if not session:
        raise HTTPException(400, "Job has no tmux session")
    # Allowed special key names (tmux key table)
    allowed = {
        "Up", "Down", "Left", "Right",
        "Enter", "Escape", "Tab", "BSpace",
        "C-c", "C-d", "C-z", "C-l", "C-b",
        "Space", "DC",  # Delete
        "Home", "End",
    }
    key_name = req.keys.strip()
    if key_name not in allowed:
        raise HTTPException(400, f"Key '{key_name}' not in allowed list: {sorted(allowed)}")
    result = await ssh_cmd(
        dev,
        f"tmux send-keys -t {session} {key_name}",
        timeout=10,
    )
    return {"ok": result["ok"], "stderr": result.get("stderr", "")}


@api_router.get("/jobs/{job_id}/tmux-capture")
async def api_job_tmux_capture(job_id: int, device: str = Query(""),
                               lines: int = Query(50)):
    """Capture recent tmux pane output for a running job."""
    dev = device or _active_device()
    job = get_job(job_id, device=dev)
    if not job:
        raise HTTPException(404, f"Job not found: {job_id}")
    session = job.get("tmux_session")
    if not session:
        raise HTTPException(400, "Job has no tmux session")
    result = await ssh_cmd(
        dev,
        f"tmux capture-pane -t {session} -p -S -{lines} 2>/dev/null",
        timeout=10,
    )
    return {"ok": result["ok"], "output": result.get("stdout", "")}


# ── Routes: Tasks (TASKS.md parsing & auto-dispatch) ─────────────────────────
@api_router.get("/tasks/{device}/{org}/{repo}")
async def api_get_tasks(device: str, org: str, repo: str,
                        section: str = Query("")):
    """Parse TASKS.md from a remote device and return structured tasks."""
    dev = get_device(device)
    if not dev:
        raise HTTPException(404, f"Device not found: {device}")

    base_dir = BASE_DIR_CFG.replace("~", _resolve_home(dev["user"]))
    repo_path = f"{base_dir}/{org}/{repo}"

    # Run parse_tasks.py remotely via SSH
    parse_cmd = f"cd ~/tenai-infra && python3 scripts/conductor/parse_tasks.py {repo_path} --json"
    if section:
        parse_cmd += f" --section '{section}'"

    result = await ssh_cmd(device, parse_cmd, timeout=15)
    if not result["ok"]:
        raise HTTPException(500, f"Failed to parse tasks: {result['stderr']}")

    try:
        tasks = json.loads(result["stdout"])
    except json.JSONDecodeError as e:
        raise HTTPException(500, f"Invalid JSON from parse_tasks: {result['stdout'][:200]}") from e

    return {"tasks": tasks, "repo": f"{org}/{repo}", "device": device}


class DispatchTasksRequest(BaseModel):
    device: str
    org: str
    repo: str
    cli: str = "claude"      # claude | gemini | codex
    branch_prefix: str = ""  # optional: override branch from tasks


@api_router.post("/jobs/dispatch-tasks")
async def api_dispatch_tasks(req: DispatchTasksRequest):
    """Auto-dispatch all Active tasks from TASKS.md to parallel agents.

    For each dispatchable task (Active + has branch), creates a job via api_create_job.
    """
    # First get the tasks
    dev = get_device(req.device)
    if not dev:
        raise HTTPException(404, f"Device not found: {req.device}")

    base_dir = BASE_DIR_CFG.replace("~", _resolve_home(dev["user"]))
    repo_path = f"{base_dir}/{req.org}/{req.repo}"

    parse_cmd = f"cd ~/tenai-infra && python3 scripts/conductor/parse_tasks.py {repo_path} --dispatchable --json"
    result = await ssh_cmd(req.device, parse_cmd, timeout=15)
    if not result["ok"]:
        raise HTTPException(500, f"Failed to parse tasks: {result['stderr']}")

    try:
        tasks = json.loads(result["stdout"])
    except json.JSONDecodeError:
        return {"dispatched": 0, "error": "No tasks found or invalid TASKS.md"}

    if not tasks:
        return {"dispatched": 0, "message": "No dispatchable tasks in TASKS.md"}

    # Dispatch each task
    dispatched = []
    for task in tasks:
        branch = req.branch_prefix + task["branch"] if req.branch_prefix else task["branch"]
        job_req = JobRequest(
            device=req.device,
            action="dispatch",
            org=req.org,
            repo=req.repo,
            branch=branch,
            command=task["description"],
            cli=req.cli,
        )
        try:
            job_result = await api_create_job(job_req)
            dispatched.append({
                "task_number": task["number"],
                "title": task["title"],
                "branch": branch,
                "job_id": job_result["job_id"],
            })
        except Exception as e:
            dispatched.append({
                "task_number": task["number"],
                "title": task["title"],
                "error": str(e),
            })

    return {
        "dispatched": len([d for d in dispatched if "job_id" in d]),
        "total_tasks": len(tasks),
        "results": dispatched,
    }


# ── Routes: Task Database ────────────────────────────────────────────────────
# These endpoints use the device-scoped SQLite task database.
# Import task_db functions
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts" / "conductor"))


def _set_task_device(device: str | None = None):
    """Set the active device for task_db operations.

    This ensures task-db queries go to the correct device DB.
    Must be called before any task_db function in API handlers.
    """
    from task_db import set_device
    if device is None or device == "":
        dev = _active_device()
    else:
        dev = device
    set_device(dev)


def _build_dispatch_worktree_md(
    task_id: int | None,
    task_data: dict | None,
    subtasks_data: list[dict],
    req: "JobRequest",
    repo_dir: str,
) -> str:
    """Build rich WORKTREE.md content for a dispatched agent.

    Uses build_worktree_md() from task_db when task data is available,
    otherwise falls back to a basic template.
    """
    if task_data:
        try:
            from task_db import build_worktree_md
            return build_worktree_md(task_data, subtasks=subtasks_data)
        except Exception:
            pass

    # Fallback: basic WORKTREE.md
    task_desc = req.task or f"Implement changes on branch {req.branch}"
    lines = [
        f"# Task: {task_desc[:200]}",
        f"- **Branch**: {req.branch}",
        f"- **Repo**: {req.org}/{req.repo}" if req.org else f"- **Repo**: {req.repo}",
        f"- **Parent**: {repo_dir}",
        "",
        "## Instructions",
        "1. Read this file to understand your task scope",
        "2. Break this task into 3-7 concrete subtasks and add them as a checklist",
        "3. Implement each subtask in order, checking them off",
        "4. Run lint and test commands (check Makefile: `make lint && make test`)",
        "5. Create `PROOF.md` with: test results, files changed, brief walkthrough",
        f"6. Commit and push: `git add -A && git commit -m 'feat: <summary>' "
        f"&& git push -u origin {req.branch}`",
        "7. Create a PR: `gh pr create --base main --fill 2>/dev/null || true`",
        "8. Exit when complete",
        "",
        "## Do not",
        "- Install system packages or tools (no apt, brew, npm -g, pip install)",
        "- Modify files outside this task's scope",
        "- Commit .env files",
        "- Merge from other branches (let CI handle it)",
    ]
    return "\n".join(lines)


class TaskRegisterRequest(BaseModel):
    repo: str
    title: str
    org: str = ""
    branch: str = ""
    description: str = ""
    instruction: str = ""
    verification: str = ""
    context_ref: str = ""
    plan_document: str = ""
    spec_document: str = ""
    cli: str = ""
    model: str = ""
    github_issue: Optional[int] = None
    conductor_track: str = ""
    timelimit: Optional[int] = None


class TaskUpdateRequest(BaseModel):
    status: Optional[str] = None
    title: Optional[str] = None
    branch: Optional[str] = None
    description: Optional[str] = None
    instruction: Optional[str] = None
    verification: Optional[str] = None
    plan_document: Optional[str] = None
    spec_document: Optional[str] = None
    timelimit: Optional[int] = None
    assigned_to: Optional[str] = None
    assigned_cli: Optional[str] = None
    proof_path: Optional[str] = None
    proof_summary: Optional[str] = None


@api_router.get("/task-db")
async def api_task_db_list(
    repo: str = Query(None),
    status: str = Query(None),
    pattern: str = Query(None),
    context_type: str = Query(None),
    created_by: str = Query(None),
    since: str = Query(None),
    until: str = Query(None),
    limit: int = Query(20),
    offset: int = Query(0),
    device: str = Query(""),
):
    """List/query tasks from the task database with rich filters and pagination."""
    _set_task_device(device)
    from task_db import query_tasks
    tasks = query_tasks(
        repo=repo, status=status, pattern=pattern,
        context_type=context_type, created_by=created_by,
        since=since, until=until, limit=limit, offset=offset,
    )
    total = query_tasks(
        repo=repo, status=status, pattern=pattern,
        context_type=context_type, created_by=created_by,
        since=since, until=until, count_only=True,
    )
    return {"tasks": tasks, "count": len(tasks), "total": total, "offset": offset, "limit": limit}


@api_router.post("/task-db")
async def api_task_db_register(req: TaskRegisterRequest, device: str = Query("")):
    """Register a new task with standardized format."""
    _set_task_device(device)
    from task_db import register_task
    tid = register_task(
        repo=req.repo, title=req.title, branch=req.branch, org=req.org,
        description=req.description, instruction=req.instruction,
        verification=req.verification, context_ref=req.context_ref,
        plan_document=req.plan_document, spec_document=req.spec_document,
        cli=req.cli, model=req.model,
        github_issue=req.github_issue, conductor_track=req.conductor_track,
        timelimit=req.timelimit,
    )
    return {"ok": True, "task_id": tid, "title": req.title}


@api_router.patch("/task-db/{task_id}")
async def api_task_db_update(task_id: int, req: TaskUpdateRequest, device: str = Query("")):
    """Update task fields by ID."""
    _set_task_device(device)
    from task_db import update_task
    fields = {k: v for k, v in req.model_dump().items() if v is not None}
    if not fields:
        raise HTTPException(400, "No fields to update")
    update_task(task_id, **fields)
    return {"ok": True, "task_id": task_id, "updated": list(fields.keys())}


@api_router.delete("/task-db/{task_id}")
async def api_task_db_delete(task_id: int, device: str = Query("")):
    """Delete a task by ID."""
    _set_task_device(device)
    from task_db import delete_task
    delete_task(task_id)
    return {"ok": True, "task_id": task_id}


@api_router.post("/task-db/{task_id}/duplicate")
async def api_task_db_duplicate(task_id: int, req: dict = Body(default={}), device: str = Query("")):
    """Duplicate a task and its subtasks as a new task."""
    _set_task_device(device)
    from task_db import duplicate_task
    new_title = req.get("title") if isinstance(req, dict) else None
    try:
        new_id = duplicate_task(task_id, new_title=new_title)
    except ValueError as exc:
        raise HTTPException(404, str(exc)) from exc
    return {"ok": True, "source_task_id": task_id, "new_task_id": new_id}


class BulkDeleteRequest(BaseModel):
    task_ids: list[int]


@api_router.post("/task-db/bulk-delete")
async def api_task_db_bulk_delete(req: BulkDeleteRequest, device: str = Query("")):
    """Delete multiple tasks and their subtasks."""
    _set_task_device(device)
    from task_db import delete_task
    deleted = []
    for tid in req.task_ids:
        try:
            delete_task(tid)
            deleted.append(tid)
        except Exception:
            pass
    return {"ok": True, "deleted": deleted, "count": len(deleted)}


@api_router.get("/task-db/repos")
async def api_task_db_repos(device: str = Query("")):
    """List distinct repo names from the task database."""
    _set_task_device(device)
    from task_db import list_repos
    repos = list_repos()
    return {"repos": repos}


@api_router.get("/task-db/render/{repo}")
async def api_task_db_render(repo: str, device: str = Query("")):
    """Render TASKS.md from database for a repo."""
    _set_task_device(device)
    from task_db import render_tasks_md
    md = render_tasks_md(repo)
    return {"repo": repo, "content": md}


@api_router.post("/task-db/{task_id}/generate-subtasks")
async def api_task_db_generate_subtasks(task_id: int, device: str = Query("")):
    """Generate subtasks for a task using LLM (Gemini API).

    Reads the task title + description, calls Gemini to produce subtasks,
    then saves them to the subtasks table.
    """
    _set_task_device(device)
    from task_db import get_task, add_subtask, list_subtasks

    task = get_task(task_id)
    if not task:
        raise HTTPException(404, f"Task {task_id} not found")

    api_key = os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        raise HTTPException(500, "GEMINI_API_KEY not set — cannot generate subtasks")

    title = task.get("title", "")
    description = task.get("description", "")
    verification = task.get("verification", "")

    prompt = (
        "You are a software engineering task planner. Given the following task, "
        "break it down into 3-7 concrete, actionable subtasks. "
        "Each subtask should be self-contained and verifiable.\n\n"
        f"Task Title: {title}\n"
        f"Description: {description}\n"
        f"Verification: {verification}\n\n"
        "Return ONLY a JSON array of objects with these fields:\n"
        '- "title": string (concise subtask title)\n'
        '- "phase": string (one of: "setup", "implement", "test", "verify", "cleanup")\n'
        '- "ordinal": integer (order within phase, starting from 1)\n\n'
        "Example output:\n"
        '[{"title": "Add database migration", "phase": "setup", "ordinal": 1}]\n\n'
        "JSON output:"
    )

    import httpx
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(
                f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={api_key}",
                json={"contents": [{"parts": [{"text": prompt}]}]},
            )
            resp.raise_for_status()
            data = resp.json()
            text = data["candidates"][0]["content"]["parts"][0]["text"]
    except Exception as exc:
        raise HTTPException(500, f"LLM call failed: {exc}") from exc

    # Parse JSON from response (handle markdown code blocks)
    import json as _json
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text[3:]
        text = text.rsplit("```", 1)[0]
    try:
        subtask_list = _json.loads(text.strip())
    except _json.JSONDecodeError as exc:
        raise HTTPException(500, f"Failed to parse LLM output as JSON: {text[:200]}") from exc

    if not isinstance(subtask_list, list):
        raise HTTPException(500, "LLM output is not a JSON array")

    # Save subtasks to DB
    for st in subtask_list:
        add_subtask(
            task_id=task_id,
            title=st.get("title", "Untitled"),
            phase=st.get("phase", "implement"),
            ordinal=st.get("ordinal", 0),
            status="pending",
        )

    # Return the full list
    all_subtasks = list_subtasks(task_id)
    return {"ok": True, "task_id": task_id, "subtasks": all_subtasks, "count": len(subtask_list)}


# ── Routes: Subtask CRUD + Progress ──────────────────────────────────────────


class SubtaskCreateRequest(BaseModel):
    title: str
    phase: str = ""
    ordinal: int = 0
    status: str = "pending"


class SubtaskUpdateRequest(BaseModel):
    title: Optional[str] = None
    phase: Optional[str] = None
    status: Optional[str] = None
    ordinal: Optional[int] = None
    checkpoint: Optional[str] = None
    evidence: Optional[str] = None


@api_router.get("/task-db/{task_id}/subtasks")
async def api_task_subtasks_list(task_id: int, device: str = Query("")):
    """List subtasks for a task, ordered by phase then ordinal."""
    _set_task_device(device)
    from task_db import list_subtasks
    subtasks = list_subtasks(task_id)
    return {"task_id": task_id, "subtasks": subtasks, "count": len(subtasks)}


@api_router.post("/task-db/{task_id}/subtasks")
async def api_task_subtask_add(task_id: int, req: SubtaskCreateRequest, device: str = Query("")):
    """Add a subtask to a task."""
    _set_task_device(device)
    from task_db import add_subtask
    sid = add_subtask(
        task_id=task_id, title=req.title,
        phase=req.phase, ordinal=req.ordinal, status=req.status,
    )
    return {"ok": True, "subtask_id": sid, "task_id": task_id}


@api_router.patch("/task-db/subtasks/{subtask_id}")
async def api_task_subtask_update(subtask_id: int, req: SubtaskUpdateRequest, device: str = Query("")):
    """Update subtask fields (status, evidence, etc.)."""
    _set_task_device(device)
    from task_db import update_subtask
    fields = {k: v for k, v in req.model_dump().items() if v is not None}
    if not fields:
        raise HTTPException(400, "No fields to update")
    update_subtask(subtask_id, **fields)
    return {"ok": True, "subtask_id": subtask_id, "updated": list(fields.keys())}


@api_router.get("/task-db/{task_id}/progress")
async def api_task_progress(task_id: int, device: str = Query("")):
    """Get task progress based on subtask completion."""
    _set_task_device(device)
    from task_db import compute_task_progress
    progress = compute_task_progress(task_id)
    return {"task_id": task_id, **progress}


@api_router.get("/task-db/{task_id}/worktree-md")
async def api_task_worktree_md(task_id: int, device: str = Query("")):
    """Generate WORKTREE.md content for a task including subtasks."""
    _set_task_device(device)
    from task_db import build_worktree_md, get_task_with_subtasks
    task = get_task_with_subtasks(task_id)
    if not task:
        raise HTTPException(404, f"Task {task_id} not found")
    md = build_worktree_md(task, subtasks=task.get("subtasks", []))
    return {"task_id": task_id, "content": md}


# ── Routes: System ────────────────────────────────────────────────────────────
@api_router.get("/status")
async def api_system_status():
    """Overall system status."""
    dev = _active_device()
    orgs = list_orgs(device=dev)
    devices = db_list_devices()
    running_jobs, _ = db_list_jobs(status="running", device=dev)
    # Task count from task DB
    try:
        from task_db import query_tasks
        total_tasks = query_tasks(count_only=True)
    except Exception:
        total_tasks = 0
    return {
        "host": os.uname().nodename,
        "active_device": dev,
        "orgs": len(orgs),
        "devices": len(devices),
        "running_jobs": len(running_jobs),
        "total_tasks": total_tasks,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

# ── Routes: Named Env Files (~/.tenai_envs/) ─────────────────────────────────
# These endpoints are DEVICE-AWARE: pass ?device=myserver to list/read/write
# env files on a remote device via SSH. Without ?device, operates locally.

TENAI_ENVS_DIR = Path.home() / ".tenai_envs"


async def _remote_env_cmd(device: str, cmd: str) -> str:
    """Run a command on a remote device to manage ~/.tenai_envs/."""
    result = await ssh_cmd(device, cmd, timeout=15)
    return result.stdout.strip() if result.returncode == 0 else ""


@api_router.get("/env-files")
async def api_list_env_files(device: str = ""):
    """List all named env files in ~/.tenai_envs/ on a device."""
    if device:
        raw = await _remote_env_cmd(
            device,
            "ls -1 ~/.tenai_envs/ 2>/dev/null | grep -v '^\\.'"
        )
        files = []
        for name in raw.splitlines():
            name = name.strip()
            if name:
                files.append({"name": name})
        return {"files": files, "device": device}
    else:
        # Local (webapp container or same host)
        TENAI_ENVS_DIR.mkdir(parents=True, exist_ok=True)
        files = []
        for f in sorted(TENAI_ENVS_DIR.iterdir()):
            if f.is_file() and not f.name.startswith("."):
                files.append({
                    "name": f.name,
                    "size": f.stat().st_size,
                    "modified": f.stat().st_mtime,
                })
        return {"files": files, "device": "local"}


@api_router.get("/env-files/{name}")
async def api_get_env_file(name: str, device: str = ""):
    """Read a named env file on a device."""
    if device:
        content = await _remote_env_cmd(device, f"cat ~/.tenai_envs/{name} 2>/dev/null")
        if not content:
            raise HTTPException(404, f"Env file not found on {device}: {name}")
        return {"name": name, "content": content, "device": device}
    else:
        path = TENAI_ENVS_DIR / name
        if not path.exists() or not path.is_file():
            raise HTTPException(404, f"Env file not found: {name}")
        return {"name": name, "content": path.read_text(), "device": "local"}


@api_router.put("/env-files/{name}")
async def api_put_env_file(name: str, req: dict, device: str = ""):
    """Create or update a named env file on a device."""
    content = req.get("content", "")
    if device:
        # Escape content for heredoc
        escaped = content.replace("'", "'\\''")
        await _remote_env_cmd(
            device,
            f"mkdir -p ~/.tenai_envs && cat > ~/.tenai_envs/{name} << 'ENVEOF'\n{escaped}\nENVEOF"
        )
        return {"ok": True, "name": name, "device": device}
    else:
        TENAI_ENVS_DIR.mkdir(parents=True, exist_ok=True)
        path = TENAI_ENVS_DIR / name
        path.write_text(content)
        return {"ok": True, "name": name, "device": "local"}


@api_router.delete("/env-files/{name}")
async def api_delete_env_file(name: str, device: str = ""):
    """Delete a named env file on a device."""
    if device:
        await _remote_env_cmd(device, f"rm -f ~/.tenai_envs/{name}")
        return {"ok": True, "device": device}
    else:
        path = TENAI_ENVS_DIR / name
        if path.exists():
            path.unlink()
        return {"ok": True, "device": "local"}


# ── Routes: Settings ─────────────────────────────────────────────────────────
@api_router.get("/settings")
async def api_list_settings():
    """List all settings."""
    settings = list_settings()
    return {"settings": {s["key"]: s["value"] for s in settings}}


@api_router.get("/settings/{key:path}")
async def api_get_setting(key: str):
    """Get a setting value."""
    val = get_setting(key)
    return {"key": key, "value": val}


class SettingRequest(BaseModel):
    value: str


@api_router.put("/settings/{key:path}")
async def api_set_setting(key: str, req: SettingRequest):
    """Set a setting value."""
    set_setting(key, req.value)
    return {"ok": True, "key": key, "value": req.value}


@api_router.delete("/settings/{key:path}")
async def api_delete_setting(key: str):
    """Delete a setting."""
    delete_setting(key)
    return {"ok": True, "deleted": key}


class BatchSettingsRequest(BaseModel):
    settings: dict[str, str]


@api_router.put("/settings-batch")
async def api_set_settings_batch(req: BatchSettingsRequest):
    """Set multiple settings at once."""
    for k, v in req.settings.items():
        set_setting(k, v)
    return {"ok": True, "count": len(req.settings)}


# ── UI ─────────────────────────────────────────────────────────────────────────
_DIST = Path(__file__).parent / "frontend" / "dist"

# Mount SPA static assets (JS, CSS, fonts) if the dist folder exists
if _DIST.exists():
    app.mount("/assets", StaticFiles(directory=str(_DIST / "assets")), name="spa-assets")


# Include all API routes under /api prefix
app.include_router(api_router)


@app.get("/{full_path:path}", response_class=HTMLResponse)
async def ui(full_path: str = ""):
    """Serve the React SPA (or legacy index.html as fallback)."""
    # Prefer the React SPA build
    spa_index = _DIST / "index.html"
    if spa_index.exists():
        return HTMLResponse(spa_index.read_text())
    # Fallback to legacy monolith index.html
    legacy = Path(__file__).parent / "index.html"
    if legacy.exists():
        return HTMLResponse(legacy.read_text())
    return HTMLResponse("<h1>TenAI Control Plane</h1><p>UI not found. See /docs</p>")


# ── Startup ───────────────────────────────────────────────────────────────────
@app.on_event("startup")
async def startup():
    init_webapp_db()
    # Init device DB for active device (or local device)
    dev = _active_device()
    if dev:
        init_device_db(dev)
    sync_config_to_db()
    asyncio.create_task(_poll_vt_sessions())
    asyncio.create_task(_startup_ping_devices())


async def _startup_ping_devices():
    """Ping all devices at startup to set initial online status.

    Uses Tailscale LocalAPI first (instant), falls back to SSH.
    """
    await asyncio.sleep(3)  # let the server finish starting
    try:
        devices = db_list_devices()
        # Try Tailscale first — one call covers all devices
        ts_status = await asyncio.get_event_loop().run_in_executor(None, _tailscale_status)
        if ts_status:
            for d in devices:
                peer = ts_status.get(d.get("ip", ""))
                if peer is not None:
                    update_device_status(d["name"], peer["online"])
                else:
                    update_device_status(d["name"], False)
            return
        # Fallback to SSH
        for d in devices:
            try:
                result = await ssh_cmd(d["name"], "echo ok", timeout=10)
                online = result["ok"] and result["stdout"].strip() == "ok"
                update_device_status(d["name"], online)
            except Exception:
                update_device_status(d["name"], False)
    except Exception:
        pass  # don't crash startup


if __name__ == "__main__":
    print(f"\n{'='*60}")
    print(f"  TenAI Control Plane")
    print(f"  Listening: http://{HOST}:{PORT}")
    print(f"  API docs:  http://localhost:{PORT}/docs")
    print(f"{'='*60}\n")

    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
