#!/usr/bin/env python3
# scripts/lib/state_tracker.py — Per-device install state manifest
#
# Records every filesystem/config change tenai makes so that `make uninstall`
# can surgically reverse only what we installed — leaving pre-existing tools
# and user config untouched.
#
# Manifest location: ~/.tenai/state/<device-name>/manifest.json
#
# Usage (library):
#   from scripts.lib.state_tracker import StateTracker
#   t = StateTracker(device="myserver", device_type="server")
#   t.record_tool_installed("mosh", pkg_mgr="brew", pre_existing=False)
#
# Usage (CLI shim from shell):
#   python3 scripts/lib/state_tracker.py track --device myserver \
#       --type tool_installed --tool mosh --pkg-mgr brew --pre-existing false
#   python3 scripts/lib/state_tracker.py show   --device myserver
#   python3 scripts/lib/state_tracker.py plan   --device myserver
#   python3 scripts/lib/state_tracker.py rename-provisional --from oldname --to newname
#   python3 scripts/lib/state_tracker.py audit  --device myserver
#
import argparse
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _expand(path: str) -> Path:
    return Path(os.path.expanduser(path))


def _entry_id(type_: str, key: str) -> str:
    """Stable 8-char ID keyed on (type, key) — used for idempotency."""
    return hashlib.md5(f"{type_}:{key}".encode()).hexdigest()[:8]


# ---------------------------------------------------------------------------
# StateTracker
# ---------------------------------------------------------------------------

class StateTracker:
    """
    Append-only per-device install manifest.

    All record_* methods are idempotent — calling twice produces one entry.
    Tracking failures are silently swallowed so installs are never aborted.
    """

    SCHEMA_VERSION = "1"

    def __init__(
        self,
        device: str,
        device_type: str = "",
        state_dir: str = "~/.tenai/state",
        tenai_version: str = "",
    ) -> None:
        self.device = device
        self.device_type = device_type
        self.state_dir = _expand(state_dir)
        self.manifest_dir = self.state_dir / device
        self.manifest_path = self.manifest_dir / "manifest.json"
        self.backup_dir = self.manifest_dir / "backups"
        self.tenai_version = tenai_version or os.environ.get("TENAI_VERSION", "")
        self._manifest: dict | None = None

    # ── I/O ──────────────────────────────────────────────────────────────────

    def _load(self) -> dict:
        if self._manifest is not None:
            return self._manifest
        if self.manifest_path.exists():
            try:
                with open(self.manifest_path) as f:
                    self._manifest = json.load(f)
                return self._manifest
            except (json.JSONDecodeError, OSError):
                pass  # corrupt — start fresh
        self._manifest = {
            "schema_version": self.SCHEMA_VERSION,
            "device": self.device,
            "device_type": self.device_type,
            "tenai_version": self.tenai_version,
            "created_at": _now(),
            "last_updated": _now(),
            "entries": [],
        }
        return self._manifest

    def _save(self) -> None:
        try:
            self.manifest_dir.mkdir(parents=True, exist_ok=True)
            self.backup_dir.mkdir(parents=True, exist_ok=True)
            m = self._load()
            m["last_updated"] = _now()
            tmp = self.manifest_path.with_suffix(".json.tmp")
            with open(tmp, "w") as f:
                json.dump(m, f, indent=2)
                f.write("\n")
            tmp.replace(self.manifest_path)
        except OSError:
            pass  # never abort install

    def _has_entry(self, entry_id: str) -> bool:
        return any(e.get("id") == entry_id for e in self._load().get("entries", []))

    def _append(self, entry: dict) -> None:
        m = self._load()
        if not self._has_entry(entry["id"]):
            m["entries"].append(entry)
            self._save()

    # ── Recording methods ─────────────────────────────────────────────────────

    def record_file_created(self, path: str) -> None:
        """Track a file tenai created from scratch."""
        try:
            self._append({
                "id": _entry_id("file_created", path),
                "type": "file_created",
                "path": path,
                "timestamp": _now(),
                "reversible": True,
            })
        except Exception:
            pass

    def record_file_modified(self, path: str, marker_start: str, marker_end: str) -> None:
        """Track a file tenai appended a marked block to."""
        try:
            self._append({
                "id": _entry_id("file_modified", f"{path}:{marker_start}"),
                "type": "file_modified",
                "path": path,
                "marker_start": marker_start,
                "marker_end": marker_end,
                "timestamp": _now(),
                "reversible": True,
            })
        except Exception:
            pass

    def record_ssh_config_block(self, marker_start: str, marker_end: str,
                                path: str = "~/.ssh/config") -> None:
        """Track a tenai block added to ~/.ssh/config."""
        try:
            self._append({
                "id": _entry_id("ssh_config_block", f"{path}:{marker_start}"),
                "type": "ssh_config_block",
                "path": path,
                "marker_start": marker_start,
                "marker_end": marker_end,
                "timestamp": _now(),
                "reversible": True,
            })
        except Exception:
            pass

    def record_tool_installed(self, tool: str, pkg_mgr: str, pre_existing: bool) -> None:
        """Track a tool installed via package manager."""
        try:
            self._append({
                "id": _entry_id("tool_installed", tool),
                "type": "tool_installed",
                "tool": tool,
                "pkg_mgr": pkg_mgr,
                "pre_existing": pre_existing,
                "timestamp": _now(),
                "reversible": not pre_existing,
            })
        except Exception:
            pass

    def record_dir_created(self, path: str) -> None:
        """Track a directory tenai created."""
        try:
            self._append({
                "id": _entry_id("dir_created", path),
                "type": "dir_created",
                "path": path,
                "timestamp": _now(),
                "reversible": True,
            })
        except Exception:
            pass

    def record_ssh_key_created(self, path: str) -> None:
        """Track an SSH key pair tenai generated."""
        try:
            self._append({
                "id": _entry_id("ssh_key_created", path),
                "type": "ssh_key_created",
                "path": path,
                "timestamp": _now(),
                "reversible": True,
            })
        except Exception:
            pass

    def record_config_registered(self, device: str,
                                  config_file: str = "config/local.yaml") -> None:
        """Track a device registration written to config/local.yaml."""
        try:
            self._append({
                "id": _entry_id("config_registered", device),
                "type": "config_registered",
                "device": device,
                "config_file": config_file,
                "timestamp": _now(),
                "reversible": True,
            })
        except Exception:
            pass

    def record_cli_extension(self, cli: str, name: str, url: str = "") -> None:
        """Track a CLI extension (Gemini/Claude) tenai installed."""
        try:
            self._append({
                "id": _entry_id("cli_extension_installed", f"{cli}:{name}"),
                "type": "cli_extension_installed",
                "cli": cli,
                "name": name,
                "url": url,
                "timestamp": _now(),
                "reversible": True,
            })
        except Exception:
            pass

    def record_cli_skill(self, cli: str, name: str, symlink_path: str = "") -> None:
        """Track a CLI skill symlink tenai created."""
        try:
            self._append({
                "id": _entry_id("cli_skill_installed", f"{cli}:{name}"),
                "type": "cli_skill_installed",
                "cli": cli,
                "name": name,
                "symlink_path": symlink_path,
                "timestamp": _now(),
                "reversible": bool(symlink_path),
            })
        except Exception:
            pass

    # ── Query ─────────────────────────────────────────────────────────────────

    def was_installed_by_us(self, tool: str) -> bool:
        return any(
            e.get("type") == "tool_installed" and e.get("tool") == tool
            for e in self._load().get("entries", [])
        )

    def was_file_created_by_us(self, path: str) -> bool:
        return any(
            e.get("type") == "file_created" and e.get("path") == path
            for e in self._load().get("entries", [])
        )

    def get_all(self) -> list:
        return self._load().get("entries", [])

    def generate_uninstall_plan(self) -> list:
        """Reversible entries in reverse-chronological order (skip pre-existing tools)."""
        entries = [e for e in self.get_all() if e.get("reversible", False)]
        return list(reversed(entries))

    # ── Rename provisional ────────────────────────────────────────────────────

    @classmethod
    def rename_provisional(cls, from_name: str, to_name: str,
                            state_dir: str = "~/.tenai/state") -> bool:
        """
        Rename provisional manifest dir to final registered device name.
        Called after register_device.py completes.
        """
        try:
            base = _expand(state_dir)
            src = base / from_name
            dst = base / to_name
            if not src.exists():
                return False
            if dst.exists() and dst != src:
                # Merge src entries into existing dst
                src_t = cls(from_name, state_dir=str(state_dir))
                dst_t = cls(to_name, state_dir=str(state_dir))
                for entry in src_t.get_all():
                    if not dst_t._has_entry(entry["id"]):
                        dst_t._load()["entries"].append(entry)
                dst_t._save()
                shutil.rmtree(src)
            else:
                src.rename(dst)
                manifest_path = dst / "manifest.json"
                if manifest_path.exists():
                    with open(manifest_path) as f:
                        m = json.load(f)
                    m["device"] = to_name
                    m["last_updated"] = _now()
                    with open(manifest_path, "w") as f:
                        json.dump(m, f, indent=2)
                        f.write("\n")
            return True
        except Exception:
            return False

    # ── Audit ─────────────────────────────────────────────────────────────────

    @classmethod
    def audit(cls, device: str, device_type: str = "",
              state_dir: str = "~/.tenai/state", infra_dir: str = "",
              home_dir: str = "") -> "StateTracker":
        """
        Best-effort manifest reconstruction from filesystem.
        Reads SSH key name and tool list via load_config() (respects TENAI_CONFIG).

        Args:
            home_dir: Override for Path.home() — pass a temp dir in tests
                      so audit never touches real ~/.ssh or ~/.tenai.
        """
        t = cls(device=device, device_type=device_type, state_dir=state_dir)
        home = Path(home_dir) if home_dir else Path.home()

        cfg: dict = {}
        try:
            if infra_dir:
                sys.path.insert(0, infra_dir)
            from scripts.lib.load_config import load_config  # type: ignore[import]
            cfg = load_config()
        except Exception:
            pass

        ssh_key_name = cfg.get("ssh", {}).get("key_name", "tenai-ssh-key")

        # ~/.tenai_aliases
        if (home / ".tenai_aliases").exists():
            t.record_file_created("~/.tenai_aliases")

        # Shell RC markers
        for rc in [home / ".zshrc", home / ".bashrc", home / ".bash_profile"]:
            if rc.exists():
                try:
                    content = rc.read_text(errors="replace")
                    if "INFRA ALIASES START" in content:
                        import re
                        m_start = re.search(r'.*(INFRA ALIASES START).*', content)
                        m_end = re.search(r'.*(INFRA ALIASES END).*', content)
                        if m_start and m_end:
                            t.record_file_modified(
                                f"~/{rc.name}",
                                m_start.group(0).strip(),
                                m_end.group(0).strip(),
                            )
                except OSError:
                    pass

        # SSH config block
        ssh_cfg = home / ".ssh" / "config"
        if ssh_cfg.exists():
            try:
                content = ssh_cfg.read_text(errors="replace")
                if "INFRA SSH START" in content:
                    import re
                    m_start = re.search(r'.*(INFRA SSH START).*', content)
                    m_end = re.search(r'.*(INFRA SSH END).*', content)
                    if m_start and m_end:
                        t.record_ssh_config_block(
                            m_start.group(0).strip(),
                            m_end.group(0).strip(),
                            path="~/.ssh/config",
                        )
            except OSError:
                pass

        # SSH key (name from config)
        if (home / ".ssh" / ssh_key_name).exists():
            t.record_ssh_key_created(f"~/.ssh/{ssh_key_name}")

        # ~/.tenai dir
        if (home / ".tenai").exists():
            t.record_dir_created("~/.tenai")

        # Tools from config (all pre_existing=True — we cannot know otherwise)
        pkg_mgr = os.environ.get("PKG_MGR", "")
        tools_cfg = cfg.get("tools", {})
        all_tools: set = set()
        for type_tools in tools_cfg.values():
            if isinstance(type_tools, list):
                all_tools.update(type_tools)
        for tool in sorted(all_tools):
            if shutil.which(tool):
                t.record_tool_installed(tool, pkg_mgr=pkg_mgr, pre_existing=True)

        # Device registration
        try:
            local_yaml = Path(infra_dir or ".") / "config" / "local.yaml"
            if local_yaml.exists():
                import yaml  # type: ignore[import]
                ldata = yaml.safe_load(local_yaml.read_text()) or {}
                devices = ldata.get("tailscale", {}).get("devices", {})
                if device in devices:
                    t.record_config_registered(device)
        except Exception:
            pass

        count = len(t.get_all())
        print(f"✓ Audit complete — {count} entries reconstructed (best-effort)", file=sys.stderr)
        return t


# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

def _show(tracker: StateTracker) -> None:
    entries = tracker.get_all()
    m = tracker._load()
    reversible = [e for e in entries if e.get("reversible")]
    print(f"\n── tenai state: {m['device']} ({m.get('device_type','')}) ──")
    print(f"   Manifest: {tracker.manifest_path}")
    print(f"   Created:  {m.get('created_at','?')}")
    print(f"   Updated:  {m.get('last_updated','?')}")
    print(f"   Entries:  {len(entries)} total, {len(reversible)} reversible\n")
    for e in entries:
        rev = "✓" if e.get("reversible") else "⊘"
        etype = e.get("type", "?")
        if etype == "tool_installed":
            pre = " (pre-existing)" if e.get("pre_existing") else ""
            label = f"{e.get('tool')}{pre} via {e.get('pkg_mgr')}"
        elif etype == "config_registered":
            label = f"device={e.get('device')} in {e.get('config_file')}"
        elif etype == "cli_extension_installed":
            label = f"{e.get('cli')}: {e.get('name')}"
        elif etype == "cli_skill_installed":
            label = f"{e.get('cli')}: skill {e.get('name')}"
        else:
            label = e.get("path", "")
        print(f"  [{rev}] {etype:<28} {label}")
    print()


def _plan(tracker: StateTracker) -> None:
    plan = tracker.generate_uninstall_plan()
    if not plan:
        print("Nothing to uninstall — manifest empty or all entries pre-existing.")
        return
    print(f"\n── Uninstall plan: {tracker.device} ({len(plan)} items) ──\n")
    for e in plan:
        etype = e.get("type", "?")
        if etype == "file_created":
            print(f"  rm -f {e.get('path')}")
        elif etype in ("file_modified", "ssh_config_block"):
            print(f"  remove block '{e.get('marker_start')}' from {e.get('path')}")
        elif etype == "tool_installed":
            print(f"  uninstall {e.get('tool')} (via {e.get('pkg_mgr')})")
        elif etype == "dir_created":
            print(f"  rmdir {e.get('path')}  # if empty")
        elif etype == "ssh_key_created":
            p = e.get("path", "")
            print(f"  rm -f {p} {p}.pub")
        elif etype == "config_registered":
            print(f"  remove device '{e.get('device')}' from {e.get('config_file')}")
        elif etype == "cli_extension_installed":
            print(f"  {e.get('cli')} extensions remove {e.get('name')}")
        elif etype == "cli_skill_installed":
            sl = e.get("symlink_path", "")
            print(f"  rm -f {sl}" if sl else f"  # remove {e.get('cli')} skill {e.get('name')}")
    print()


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(prog="state_tracker.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_device(p: argparse.ArgumentParser) -> None:
        p.add_argument("--device", required=True)
        p.add_argument("--state-dir", default="~/.tenai/state")

    # track
    trk = sub.add_parser("track")
    add_device(trk)
    trk.add_argument("--device-type", default="")
    trk.add_argument("--type", dest="type_", required=True)
    trk.add_argument("--path", default="")
    trk.add_argument("--marker-start", default="")
    trk.add_argument("--marker-end", default="")
    trk.add_argument("--tool", default="")
    trk.add_argument("--pkg-mgr", default="")
    trk.add_argument("--pre-existing", default="false")
    trk.add_argument("--cli", default="")
    trk.add_argument("--name", default="")
    trk.add_argument("--url", default="")
    trk.add_argument("--symlink-path", default="")

    # show
    shw = sub.add_parser("show")
    add_device(shw)

    # plan
    pln = sub.add_parser("plan")
    add_device(pln)

    # rename-provisional
    rnm = sub.add_parser("rename-provisional")
    rnm.add_argument("--from", dest="from_name", required=True)
    rnm.add_argument("--to", dest="to_name", required=True)
    rnm.add_argument("--state-dir", default="~/.tenai/state")

    # audit
    aud = sub.add_parser("audit")
    add_device(aud)
    aud.add_argument("--device-type", default="")
    aud.add_argument("--infra-dir", default="")
    aud.add_argument("--home-dir", default="", help="Override home dir (for testing)")

    args = parser.parse_args()

    if args.cmd == "track":
        t = StateTracker(device=args.device, device_type=args.device_type, state_dir=args.state_dir)
        pre = args.pre_existing.lower() in ("true", "1", "yes")
        ty = args.type_
        if ty == "file_created":
            t.record_file_created(args.path)
        elif ty == "file_modified":
            t.record_file_modified(args.path, args.marker_start, args.marker_end)
        elif ty == "ssh_config_block":
            t.record_ssh_config_block(args.marker_start, args.marker_end, args.path or "~/.ssh/config")
        elif ty == "tool_installed":
            t.record_tool_installed(args.tool, args.pkg_mgr, pre)
        elif ty == "dir_created":
            t.record_dir_created(args.path)
        elif ty == "ssh_key_created":
            t.record_ssh_key_created(args.path)
        elif ty == "config_registered":
            t.record_config_registered(args.device, args.path or "config/local.yaml")
        elif ty == "cli_extension_installed":
            t.record_cli_extension(args.cli, args.name, args.url)
        elif ty == "cli_skill_installed":
            t.record_cli_skill(args.cli, args.name, args.symlink_path)

    elif args.cmd == "show":
        _show(StateTracker(device=args.device, state_dir=args.state_dir))

    elif args.cmd == "plan":
        _plan(StateTracker(device=args.device, state_dir=args.state_dir))

    elif args.cmd == "rename-provisional":
        ok = StateTracker.rename_provisional(args.from_name, args.to_name, state_dir=args.state_dir)
        if ok:
            print(f"✓ Renamed: {args.from_name} → {args.to_name}")

    elif args.cmd == "audit":
        StateTracker.audit(
            device=args.device, device_type=args.device_type,
            state_dir=args.state_dir, infra_dir=args.infra_dir,
            home_dir=args.home_dir,
        )
        _show(StateTracker(device=args.device, state_dir=args.state_dir))


if __name__ == "__main__":
    main()
