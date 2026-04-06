"""
P0 Acceptance Test — npm ENOSPC Misrouted Cache
Gold fixture: validates the full diagnose → plan → verify flow
against the canonical incident from the Mission Control integration contract.

Run:
    uv run pytest tests/test_p0_npm_enospc.py -v

This test mocks the OS layer so it runs identically on Linux CI and Windows NEXUS.
"""
from __future__ import annotations

import os
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from health_adapter.api.schemas import (
    DiagnosisCategory,
    FitStatus,
    ResponseStatus,
    Severity,
)
from health_adapter.main import app

client = TestClient(app)

# ---------------------------------------------------------------------------
# Gold fixture — request payload matching MC integration contract step 1
# ---------------------------------------------------------------------------

GOLD_REQUEST = {
    "contract_name": "mission_control.health_adapter",
    "contract_version": "1.0",
    "schema_version": "1.0",
    "request_id": "req_npm_p0_001",
    "trace_id": "trc_npm_p0_001",
    "actor": {"actor_id": "user_phoenix", "actor_type": "user"},
    "device": {"device_id": "dev_nexus_01", "device_class": "workstation", "os_family": "windows"},
    "workspace": {
        "workspace_id": "ws_system_health",
        "project_path": "C:\\Projects\\system_health",
    },
    "target": {"toolchain": "npm", "operation": "install", "symptom": "install_failed_enospc"},
    "execution_mode": "diagnose_and_remediate_safe",
    "policy_envelope": {
        "policy_mode": "safe_auto_remediate",
        "allow_env_var_mutation": True,
        "allow_cache_cleanup": True,
        "allow_project_install_artifact_removal": True,
        "allow_cross_drive_cache_relocation": True,
        "min_free_space_bytes": 2147483648,
        "approved_target_roots": ["C:\\Projects", "E:\\npm-cache"],
    },
    "context": {
        "expected_free_space_floor_bytes": 2147483648,
        "capture_artifacts": True,
        "include_probe_details": True,
    },
}


# ---------------------------------------------------------------------------
# Mock helpers — simulate NEXUS disk state before remediation
# ---------------------------------------------------------------------------

def _mock_disk_partitions():
    """Simulates NEXUS: C: healthy, D: reserved/exhausted, E: healthy."""
    c = MagicMock()
    c.mountpoint = "C:\\"
    c.device = "C:\\"
    c.fstype = "NTFS"

    d = MagicMock()
    d.mountpoint = "D:\\"
    d.device = "D:\\"
    d.fstype = "NTFS"

    e = MagicMock()
    e.mountpoint = "E:\\"
    e.device = "E:\\"
    e.fstype = "NTFS"

    return [c, d, e]


def _mock_disk_usage(mountpoint: str):
    usage = MagicMock()
    if mountpoint == "C:\\":
        usage.total = 100 * 1024 ** 3
        usage.free = 7_645_179_904
        usage.used = usage.total - usage.free
        usage.percent = round(100 * usage.used / usage.total, 1)
    elif mountpoint == "D:\\":
        usage.total = 104_857_600  # 100 MB — reserved partition
        usage.free = 0
        usage.used = usage.total
        usage.percent = 100.0
    elif mountpoint == "E:\\":
        usage.total = 1_000 * 1024 ** 3
        usage.free = 975_020_388_352
        usage.used = usage.total - usage.free
        usage.percent = round(100 * usage.used / usage.total, 1)
    else:
        usage.total = 10 * 1024 ** 3
        usage.free = 5 * 1024 ** 3
        usage.used = 5 * 1024 ** 3
        usage.percent = 50.0
    return usage


async def _mock_npm_config_get(self, key: str):
    """Simulate: effective cache = D:\\Temp\\npm (env override wins), global = E:\\npm-cache."""
    return {
        "cache": "D:\\Temp\\npm",   # env override wins
        "globalconfig": "C:\\Users\\Phoenix\\.npmrc",
        "prefix": "C:\\Users\\Phoenix\\AppData\\Roaming\\npm",
    }.get(key)


async def _mock_read_npmrc_key(npmrc_path, key):
    if key == "cache":
        return "E:\\npm-cache"  # correct global config
    return None


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def nexus_env(monkeypatch):
    """Patch OS environment to simulate NEXUS misrouted state."""
    monkeypatch.setenv("npm_config_cache", "D:\\Temp\\npm")
    monkeypatch.setenv("TEMP", "D:\\Temp")
    monkeypatch.setenv("TMP", "D:\\Temp")
    monkeypatch.setenv("PATH", "C:\\Windows\\System32;C:\\Windows;C:\\Program Files\\nodejs")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestP0NpmEnospcDiagnose:
    """Validate the diagnose endpoint against the gold fixture."""

    @patch("psutil.disk_partitions", side_effect=lambda all=False: _mock_disk_partitions())
    @patch("psutil.disk_usage", side_effect=_mock_disk_usage)
    @patch(
        "health_adapter.probes.npm_probe.NpmProbe._npm_config_get",
        new=_mock_npm_config_get,
    )
    @patch(
        "health_adapter.probes.npm_probe.NpmProbe._read_npmrc_key",
        new=staticmethod(_mock_read_npmrc_key),
    )
    def test_diagnose_returns_cache_path_misrouted(self, mock_usage, mock_parts, nexus_env):
        response = client.post("/v1/health/diagnose", json=GOLD_REQUEST)

        assert response.status_code == 200
        body = response.json()

        # Contract fields
        assert body["contract_version"] == "1.0"
        assert body["trace_id"] == "trc_npm_p0_001"
        assert body["status"] == ResponseStatus.completed

        # Primary diagnosis
        diag = body["diagnosis"]
        assert diag["primary_diagnosis"] == DiagnosisCategory.cache_path_misrouted
        assert DiagnosisCategory.disk_exhaustion_effective_path in diag["secondary_diagnoses"]
        assert diag["severity"] == Severity.high
        assert diag["recoverability"] == "recoverable_with_safe_actions"

        # ECL confidence
        ecl = body["ecl_inputs"]
        assert ecl["diagnosis_confidence"] >= 0.90
        assert ecl["config_stability"] < 0.50  # penalized: mismatch + override

        # Probe summary
        ps = body["probe_summary"]
        assert ps["path_mismatch_detected"] is True
        assert "D:" in (ps["effective_cache_drive"] or "")

    @patch("psutil.disk_partitions", side_effect=lambda all=False: _mock_disk_partitions())
    @patch("psutil.disk_usage", side_effect=_mock_disk_usage)
    @patch("health_adapter.probes.npm_probe.NpmProbe._npm_config_get", new=_mock_npm_config_get)
    @patch("health_adapter.probes.npm_probe.NpmProbe._read_npmrc_key", new=staticmethod(_mock_read_npmrc_key))
    def test_plan_includes_rebind_cache_step(self, mock_usage, mock_parts, nexus_env):
        request = {**GOLD_REQUEST, "execution_mode": "plan_only"}
        response = client.post("/v1/health/plan", json=request)

        assert response.status_code == 200
        body = response.json()
        assert body["status"] == ResponseStatus.completed

        plan = body["plan"]
        assert plan["policy_mode"] == "safe_auto_remediate"
        assert plan["requires_approval"] is False
        assert plan["estimated_risk"] == "low"
        assert plan["estimated_recovery_probability"] >= 0.80

        action_types = [s["action_type"] for s in plan["steps"]]
        assert "rebind_cache_path" in action_types
        assert "clean_tool_cache" in action_types

    @patch("psutil.disk_partitions", side_effect=lambda all=False: _mock_disk_partitions())
    @patch("psutil.disk_usage", side_effect=_mock_disk_usage)
    @patch("health_adapter.probes.npm_probe.NpmProbe._npm_config_get", new=_mock_npm_config_get)
    @patch("health_adapter.probes.npm_probe.NpmProbe._read_npmrc_key", new=staticmethod(_mock_read_npmrc_key))
    def test_fitness_returns_not_fit_when_cache_misrouted(self, mock_usage, mock_parts, nexus_env):
        request = {**GOLD_REQUEST, "execution_mode": "fitness_only"}
        response = client.post("/v1/health/fitness", json=request)

        assert response.status_code == 200
        body = response.json()
        fitness = body["fitness"]

        assert fitness["fit_status"] == FitStatus.not_fit
        assert len(fitness["blocking_conditions"]) > 0
        assert any(
            bc["factor_type"] == "cache_path_misrouted"
            for bc in fitness["blocking_conditions"]
        )

    @patch("psutil.disk_partitions", side_effect=lambda all=False: _mock_disk_partitions())
    @patch("psutil.disk_usage", side_effect=_mock_disk_usage)
    @patch("health_adapter.probes.npm_probe.NpmProbe._npm_config_get", new=_mock_npm_config_get)
    @patch("health_adapter.probes.npm_probe.NpmProbe._read_npmrc_key", new=staticmethod(_mock_read_npmrc_key))
    def test_verify_fails_before_remediation(self, mock_usage, mock_parts, nexus_env):
        request = {
            **GOLD_REQUEST,
            "execution_mode": "verify_only",
            "context": {
                "expected_free_space_floor_bytes": 2147483648,
                "requested_checks": [
                    "effective_cache_path_not_on_reserved_partition",
                    "cache_drive_free_space_gte_floor",
                ],
            },
        }
        response = client.post("/v1/health/verify", json=request)

        assert response.status_code == 200
        body = response.json()
        verification = body["verification"]

        # At least one check should fail before remediation
        check_statuses = {c["check_name"]: c["status"] for c in verification["checks"]}
        assert any(s == "fail" for s in check_statuses.values()), (
            "Expected at least one verification failure before remediation"
        )


class TestP0PolicyEnforcement:
    """Verify policy gate blocks disallowed operations."""

    def test_policy_deny_blocks_guarded_mode(self):
        request = {
            **GOLD_REQUEST,
            "execution_mode": "diagnose_and_remediate_guarded",
            "policy_envelope": {
                "policy_mode": "safe_auto_remediate",
                "allow_guarded_actions": False,  # explicitly blocked
            },
        }
        response = client.post("/v1/health/diagnose", json=request)
        body = response.json()
        assert body["status"] == ResponseStatus.denied
        assert any(e["code"] == "POLICY_DENIED" for e in body["errors"])

    def test_healthz_returns_ok(self):
        response = client.get("/v1/health/healthz")
        assert response.status_code == 200
        assert response.json()["status"] == "ok"

    def test_readyz_returns_ready(self):
        response = client.get("/v1/health/readyz")
        assert response.status_code == 200
        assert response.json()["status"] == "ready"
