"""
tests/test_api.py — Integration tests for webapp/server.py FastAPI endpoints.

Uses FastAPI's TestClient backed by httpx. SSH calls are mocked.
The server.py module has a try/except that pip-installs deps on ImportError,
so we ensure all deps are pre-imported before loading the module.
"""
import os
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

# Add webapp/ and scripts/ to path
sys.path.insert(0, str(Path(__file__).parent.parent / "webapp"))
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

# Pre-import deps that server.py needs (avoids its pip install fallback)
import db as db_module  # noqa: E402
import fastapi  # noqa: F401, E402
import pydantic  # noqa: F401, E402
import uvicorn  # noqa: F401, E402
import yaml  # noqa: F401, E402


@pytest.fixture
def api_client(tmp_path):
    """Create a TestClient with a temporary database and mocked SSH."""
    db_path = tmp_path / "api_test.db"
    device_db_dir = tmp_path / "devices"
    test_device = "test-dev"

    with patch.dict(os.environ, {
        "WEBAPP_TOKEN": "",
        "INFRA_DIR": str(Path(__file__).parent.parent),
        "CONFIG_DIR": str(Path(__file__).parent.parent / "config"),
        "DEVICE_NAME": test_device,
    }):
        with patch.object(db_module, "DB_PATH", db_path), \
             patch.object(db_module, "DB_DIR", tmp_path), \
             patch.object(db_module, "DEVICE_DB_DIR", device_db_dir):
            db_module.init_webapp_db()
            db_module.init_device_db(test_device)

            # Ensure server module picks up the patched db
            import importlib

            if "server" in sys.modules:
                importlib.reload(sys.modules["server"])
            import server
            from fastapi.testclient import TestClient

            # Patch LOCAL_DEVICE so _active_device() returns test device
            with patch.object(server, "LOCAL_DEVICE", test_device):
                client = TestClient(server.app, raise_server_exceptions=False)
                yield client


# ── System Status ────────────────────────────────────────────────────────────


@pytest.mark.integration
class TestStatusEndpoint:
    def test_status_returns_200(self, api_client):
        resp = api_client.get("/api/status")
        assert resp.status_code == 200
        data = resp.json()
        assert "host" in data
        assert "timestamp" in data
        assert "orgs" in data
        assert "devices" in data

    def test_status_counts(self, api_client):
        resp = api_client.get("/api/status")
        data = resp.json()
        assert isinstance(data["orgs"], int)
        assert isinstance(data["devices"], int)


# ── Organizations ────────────────────────────────────────────────────────────


@pytest.mark.integration
class TestOrgEndpoints:
    def test_list_orgs(self, api_client):
        resp = api_client.get("/api/orgs")
        assert resp.status_code == 200
        assert "orgs" in resp.json()

    def test_create_org(self, api_client):
        resp = api_client.post("/api/orgs", json={
            "name": "new-org",
            "github_url": "github.com",
            "ssh_host_alias": "github-new",
            "ssh_key": "~/.ssh/key",
            "default_branch": "main",
        })
        assert resp.status_code == 200
        assert resp.json()["ok"] is True

        # Verify it's in the list
        resp2 = api_client.get("/api/orgs")
        names = [o["name"] for o in resp2.json()["orgs"]]
        assert "new-org" in names

    def test_delete_org(self, api_client):
        api_client.post("/api/orgs", json={
            "name": "del-org",
            "github_url": "github.com",
        })
        resp = api_client.delete("/api/orgs/del-org")
        assert resp.status_code == 200
        assert resp.json()["ok"] is True


# ── Repos ────────────────────────────────────────────────────────────────────


@pytest.mark.integration
class TestRepoEndpoints:
    def test_list_repos(self, api_client):
        resp = api_client.get("/api/repos")
        assert resp.status_code == 200
        assert "repos" in resp.json()

    def test_list_repos_with_query(self, api_client):
        resp = api_client.get("/api/repos?q=nonexistent")
        assert resp.status_code == 200
        assert resp.json()["total"] == 0


# ── Devices ──────────────────────────────────────────────────────────────────


@pytest.mark.integration
class TestDeviceEndpoints:
    def test_list_devices(self, api_client):
        resp = api_client.get("/api/devices")
        assert resp.status_code == 200
        data = resp.json()
        assert "devices" in data

    def test_device_detail_not_found(self, api_client):
        resp = api_client.get("/api/devices/nonexistent")
        assert resp.status_code == 404


# ── Jobs ─────────────────────────────────────────────────────────────────────


@pytest.mark.integration
class TestJobEndpoints:
    def test_list_jobs(self, api_client):
        resp = api_client.get("/api/jobs")
        assert resp.status_code == 200
        assert "jobs" in resp.json()

    def test_create_job_unknown_device(self, api_client):
        resp = api_client.post("/api/jobs", json={
            "device": "nonexistent-device",
            "action": "custom",
            "command": "echo hi",
        })
        assert resp.status_code == 404

    def test_job_detail_not_found(self, api_client):
        resp = api_client.get("/api/jobs/99999")
        assert resp.status_code == 404


# ── UI ───────────────────────────────────────────────────────────────────────


@pytest.mark.integration
class TestUIEndpoint:
    def test_ui_serves_html(self, api_client):
        resp = api_client.get("/")
        assert resp.status_code == 200
        assert "text/html" in resp.headers.get("content-type", "")


# ── Auth ─────────────────────────────────────────────────────────────────────


@pytest.mark.integration
class TestAuth:
    def test_no_auth_when_token_empty(self, api_client):
        """When WEBAPP_TOKEN is empty, all requests pass."""
        resp = api_client.get("/api/status")
        assert resp.status_code == 200


# ── Settings API ─────────────────────────────────────────────────────────────


@pytest.mark.integration
class TestSettingsAPI:
    """Verify GET/PUT/DELETE /settings/{key} and GET /settings endpoints."""

    def test_put_and_get_setting(self, api_client):
        resp = api_client.put("/api/settings/default_device",
                              json={"value": "dev-srv2"})
        assert resp.status_code == 200
        resp = api_client.get("/api/settings/default_device")
        assert resp.status_code == 200
        assert resp.json()["value"] == "dev-srv2"

    def test_get_missing_setting(self, api_client):
        resp = api_client.get("/api/settings/nonexistent")
        assert resp.status_code == 200
        assert resp.json()["value"] == ""

    def test_list_settings(self, api_client):
        api_client.put("/api/settings/key1", json={"value": "v1"})
        api_client.put("/api/settings/key2", json={"value": "v2"})
        resp = api_client.get("/api/settings")
        assert resp.status_code == 200
        settings = resp.json()["settings"]
        assert "key1" in settings
        assert settings["key1"] == "v1"

    def test_delete_setting(self, api_client):
        api_client.put("/api/settings/tmp", json={"value": "x"})
        resp = api_client.delete("/api/settings/tmp")
        assert resp.status_code == 200
        resp = api_client.get("/api/settings/tmp")
        assert resp.json()["value"] == ""

    def test_status_includes_active_device(self, api_client):
        """Verify /status response includes active_device field."""
        resp = api_client.get("/api/status")
        assert resp.status_code == 200
        data = resp.json()
        assert "active_device" in data
