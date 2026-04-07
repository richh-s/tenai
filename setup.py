#!/usr/bin/env python3
"""
setup.py — tenai Infra orchestrator
Uses Hydra for config management. Detects platform and runs appropriate scripts.

Usage:
  python setup.py                          # full setup, auto-detect device type
  python setup.py device=mac               # target specific device type
  python setup.py +action=install_tools    # run specific action only
  python setup.py +action=configure_aliases
  python setup.py tailscale.devices.myserver.ip=100.x.y.z  # override any config
"""
import os
import platform
import subprocess
import sys
from pathlib import Path

# Add scripts/ to path for env_loader
sys.path.insert(0, str(Path(__file__).parent / "scripts"))
from env_loader import load_env  # noqa: E402

import hydra  # noqa: E402
from omegaconf import DictConfig  # noqa: E402

# Load .env before Hydra initializes (with whitespace stripping)
load_env(Path(__file__).parent / ".env")

SCRIPTS_DIR = Path(__file__).parent / "scripts"


def run(cmd: str, check: bool = True, env: dict = None) -> subprocess.CompletedProcess:
    """Run a shell command with live output."""
    merged_env = {**os.environ, **(env or {})}
    print(f"\n$ {cmd}")
    result = subprocess.run(
        cmd, shell=True, check=check,
        env=merged_env, executable="/bin/bash"
    )
    return result


def detect_os() -> str:
    """Detect the current OS/platform."""
    if os.environ.get("TERMUX_VERSION") or Path("/data/data/com.termux").exists():
        return "termux"
    if platform.system() == "Darwin":
        return "mac"
    if platform.system() == "Linux":
        return "linux"
    raise RuntimeError(f"Unknown platform: {platform.system()}")


def build_env(cfg: DictConfig) -> dict:
    """Build environment variables from config for shell scripts."""
    env = {}

    # Device IPs and users — iterate all configured devices
    devices = cfg.tailscale.devices
    for name, dev_cfg in devices.items():
        prefix = name.upper().replace('-', '_')
        env[f"{prefix}_IP"] = dev_cfg.ip
        env[f"{prefix}_USER"] = dev_cfg.user

    # Type-based aliases: first device of each type gets TYPE_IP, TYPE_USER, TYPE_HOST
    # e.g., first "server" → SERVER_IP, first "mac" → MAC_IP, first "android" → ANDROID_IP
    seen_types = set()
    for name, dev_cfg in devices.items():
        dev_type = str(dev_cfg.get("type", "server")).upper().replace("-", "_")
        if dev_type not in seen_types:
            seen_types.add(dev_type)
            env[f"{dev_type}_IP"] = dev_cfg.ip
            env[f"{dev_type}_USER"] = dev_cfg.user
            env[f"{dev_type}_HOST"] = name

    # Tailscale auth key from .env
    if key := os.environ.get("TAILSCALE_AUTH_KEY"):
        env["TAILSCALE_AUTH_KEY"] = key

    # NordVPN token from .env
    if token := os.environ.get("NORDVPN_TOKEN"):
        env["NORDVPN_TOKEN"] = token

    # SSH key path
    env["SSH_KEY_PATH"] = os.path.expanduser(
        os.environ.get("SSH_KEY_PATH", "~/.ssh/id_ed25519")
    )

    return env


def run_script(script_path: str, env: dict, critical: bool = True):
    """Run a bash script with the provided environment.

    Args:
        critical: If False, script failures print a warning but don't crash.
    """
    script = SCRIPTS_DIR / script_path
    if not script.exists():
        print(f"WARNING: Script not found: {script}")
        return
    result = run(f"bash {script}", env=env, check=False)
    if result.returncode != 0:
        if critical:
            raise subprocess.CalledProcessError(result.returncode, f"bash {script}")
        print(f"⚠ {script_path} exited with code {result.returncode} (non-critical, continuing)")


def action_install_all(cfg: DictConfig, os_type: str, env: dict):
    # Install scripts are non-fatal — one failure shouldn't block others
    run_script("install/tailscale.sh", env, critical=False)
    run_script("install/mosh.sh", env, critical=False)
    run_script("install/tmux.sh", env, critical=False)
    run_script("install/tools.sh", env, critical=False)


def action_configure_all(cfg: DictConfig, os_type: str, env: dict):
    run_script("configure/ssh.sh", env)
    run_script("configure/aliases.sh", env)


def action_install_tailscale(cfg, os_type, env):
    run_script("install/tailscale.sh", env)


def action_install_tools(cfg, os_type, env):
    run_script("install/tools.sh", env)


def action_configure_aliases(cfg, os_type, env):
    run_script("configure/aliases.sh", env)


def action_configure_ssh(cfg, os_type, env):
    run_script("configure/ssh.sh", env)


def action_new_project(cfg, os_type, env):
    project_dir = os.environ.get("PROJECT_DIR", os.getcwd())
    project_name = os.environ.get("PROJECT_NAME", Path(project_dir).name)
    run_script("configure/claude_md.sh", {
        **env,
        "PROJECT_DIR": project_dir,
        "PROJECT_NAME": project_name,
    })


ACTIONS = {
    "install_all":          action_install_all,
    "install_tailscale":    action_install_tailscale,
    "install_tools":        action_install_tools,
    "configure_all":        action_configure_all,
    "configure_aliases":    action_configure_aliases,
    "configure_ssh":        action_configure_ssh,
    "new_project":          action_new_project,
}


@hydra.main(version_base=None, config_path="config", config_name="defaults")
def main(cfg: DictConfig) -> None:
    os_type = detect_os()
    env = build_env(cfg)

    # Inject OS_TYPE so scripts can use it
    env["OS_TYPE_OVERRIDE"] = os_type

    action = cfg.get("action", "full_setup")

    print(f"\n{'='*60}")
    device_type = cfg.device.type if "device" in cfg and "type" in cfg.device else os_type
    print("  tenai Infra Setup")
    print(f"  OS: {os_type} | Device: {device_type} | Action: {action}")
    print(f"{'='*60}\n")

    if action == "full_setup":
        action_install_all(cfg, os_type, env)
        action_configure_all(cfg, os_type, env)
    elif action in ACTIONS:
        ACTIONS[action](cfg, os_type, env)
    else:
        print(f"Unknown action: {action}")
        print(f"Available actions: {', '.join(ACTIONS.keys())}")
        sys.exit(1)

    print("\n\u2713 Setup complete!")
    # Detect correct shell RC for the user
    shell_rc = env.get('SHELL_RC', '~/.bashrc')
    if platform.system() == 'Darwin':
        try:
            import getpass
            login_shell = subprocess.check_output(
                ['dscl', '.', '-read', f'/Users/{getpass.getuser()}', 'UserShell'],
                text=True, stderr=subprocess.DEVNULL
            ).strip().split()[-1]
            if 'zsh' in login_shell:
                shell_rc = '~/.zshrc'
        except Exception:
            pass
    print(f"Run: source {shell_rc}")


if __name__ == "__main__":
    main()
