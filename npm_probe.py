"""
Codessa Health Adapter — npm Toolchain Probe
Resolves effective npm config graph including:
  - environment override (npm_config_cache)
  - project .npmrc
  - user .npmrc
  - global npmrc
  - builtin default

This is the P0 probe — designed specifically around the npm ENOSPC
misrouted-cache incident where npm_config_cache env var pointed to
an exhausted reserved partition, overriding the correct global config.

Config precedence (highest → lowest):
  1. CLI args (not applicable here)
  2. Environment variables: npm_config_*
  3. Project .npmrc
  4. User .npmrc (~/.npmrc)
  5. Global npmrc (npm config get globalconfig)
  6. npm builtin defaults
"""
from __future__ import annotations

import asyncio
import os
import platform
import subprocess
import time
from pathlib import Path
from typing import Any

from health_adapter.probes.base import BaseProbe, ProbeResult, ProbeStatus


class NpmProbe(BaseProbe):
    probe_id = "npm_probe"
    trust_tier = "high"

    async def run(self, context: dict[str, Any]) -> ProbeResult:
        start = time.monotonic()
        observations = []
        warnings = []
        errors = []

        project_path = context.get("project_path")

        # --- 1. Resolve effective cache path via `npm config get cache` ---
        effective_cache = await self._npm_config_get("cache")
        if effective_cache is None:
            warnings.append("npm not found or config unreadable — command_resolution check recommended")
            effective_cache = ""

        observations.append(self._obs(
            metric_name="effective_cache_path",
            metric_value=effective_cache,
            metric_unit="path",
            observation_type="config_fact",
            path=effective_cache or None,
            drive=self._drive_of(effective_cache) if effective_cache else None,
            confidence=0.98,
        ))

        # --- 2. Read env var override ---
        env_override = os.environ.get("npm_config_cache") or os.environ.get("NPM_CONFIG_CACHE") or ""
        observations.append(self._obs(
            metric_name="npm_config_cache_env_override",
            metric_value=env_override,
            metric_unit="path",
            observation_type="config_fact",
            path=env_override or None,
            confidence=1.0,
            raw_evidence={"scope": "process", "env_key": "npm_config_cache"},
        ))

        # --- 3. Read global config file value ---
        global_config_path = await self._npm_config_get("globalconfig")
        global_cache = await self._read_npmrc_key(global_config_path, "cache") if global_config_path else None

        observations.append(self._obs(
            metric_name="declared_cache_path",
            metric_value=global_cache or "",
            metric_unit="path",
            observation_type="config_fact",
            path=global_cache or None,
            drive=self._drive_of(global_cache) if global_cache else None,
            confidence=0.95,
            raw_evidence={"source": "global_npmrc", "path": global_config_path},
        ))

        # --- 4. Path mismatch detection ---
        path_mismatch = bool(
            effective_cache
            and global_cache
            and Path(effective_cache).resolve() != Path(global_cache).resolve()
        )
        observations.append(self._obs(
            metric_name="path_mismatch_detected",
            metric_value=path_mismatch,
            metric_unit="boolean",
            observation_type="config_fact",
            confidence=0.98 if effective_cache and global_cache else 0.60,
        ))

        if path_mismatch:
            warnings.append(
                f"npm cache path mismatch: effective={effective_cache!r} "
                f"!= declared={global_cache!r}. "
                f"Likely cause: npm_config_cache env override is active."
            )

        # --- 5. Override source attribution ---
        if env_override and effective_cache and env_override == effective_cache:
            observations.append(self._obs(
                metric_name="npm_config_cache_override_source",
                metric_value="npm_config_cache env var (process scope)",
                metric_unit="string",
                observation_type="config_fact",
                confidence=0.98,
                raw_evidence={"winning_scope": "process", "losing_scope": "user/global"},
            ))
            warnings.append(
                "npm_config_cache environment variable is overriding global config. "
                "This is the primary override source."
            )

        # --- 6. Effective cache drive ---
        if effective_cache:
            observations.append(self._obs(
                metric_name="effective_cache_drive",
                metric_value=self._drive_of(effective_cache),
                metric_unit="string",
                observation_type="config_fact",
                drive=self._drive_of(effective_cache),
                confidence=1.0,
            ))

        # --- 7. Effective prefix ---
        prefix = await self._npm_config_get("prefix")
        if prefix:
            observations.append(self._obs(
                metric_name="npm_prefix",
                metric_value=prefix,
                metric_unit="path",
                observation_type="config_fact",
                path=prefix,
                confidence=0.95,
            ))

        # --- 8. node_modules size (if project_path provided) ---
        if project_path:
            nm_path = Path(project_path) / "node_modules"
            nm_size = await asyncio.to_thread(self._dir_size_bytes, nm_path) if nm_path.exists() else 0
            observations.append(self._obs(
                metric_name="node_modules_size_bytes",
                metric_value=nm_size,
                metric_unit="bytes",
                observation_type="capacity_fact",
                path=str(nm_path),
                confidence=1.0,
            ))

        return ProbeResult(
            probe_id=self.probe_id,
            status=ProbeStatus.degraded if warnings else ProbeStatus.ok,
            observations=observations,
            warnings=warnings,
            errors=errors,
            duration_ms=(time.monotonic() - start) * 1000,
        )

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    async def _npm_config_get(self, key: str) -> str | None:
        """Run `npm config get <key>` and return stripped output."""
        try:
            result = await asyncio.to_thread(
                subprocess.run,
                ["npm", "config", "get", key],
                capture_output=True,
                text=True,
                timeout=10,
            )
            out = result.stdout.strip()
            if result.returncode == 0 and out and out != "undefined":
                return out
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            pass
        return None

    @staticmethod
    async def _read_npmrc_key(npmrc_path: str, key: str) -> str | None:
        """Parse a key=value from an .npmrc file."""
        try:
            path = Path(npmrc_path)
            if not path.exists():
                return None
            content = await asyncio.to_thread(path.read_text, encoding="utf-8")
            for line in content.splitlines():
                line = line.strip()
                if line.startswith(f"{key}="):
                    return line.split("=", 1)[1].strip()
        except Exception:
            pass
        return None

    @staticmethod
    def _drive_of(path: str) -> str:
        if platform.system() == "Windows":
            return path[:2] if len(path) >= 2 else path
        parts = Path(path).parts
        return parts[0] if parts else "/"

    @staticmethod
    def _dir_size_bytes(path: Path) -> int:
        """Recursively sum directory size. Returns 0 on error."""
        try:
            return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
        except Exception:
            return 0
