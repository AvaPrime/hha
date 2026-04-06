"""
Codessa Health Adapter — Diagnosis Engine
Maps raw probe observations into typed health diagnoses.

Stage 1: Deterministic rules (pattern → diagnosis_category + severity + confidence)
Stage 2: MCL pattern reasoning (Phase 4 — stub only in v0.1)

Design rule: The engine reads observations. It does not call probes.
All I/O has already happened by the time diagnosis runs.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from health_adapter.api.schemas import (
    DiagnosisCategory,
    DiagnosisResult,
    ECLInputs,
    ProbeSummary,
    Recoverability,
    Severity,
)
from health_adapter.probes.base import RawObservation


@dataclass
class ObservationIndex:
    """Fast lookup of observations by metric_name and drive."""
    _by_metric: dict[str, list[RawObservation]] = field(default_factory=dict)

    def add(self, obs: RawObservation) -> None:
        self._by_metric.setdefault(obs.metric_name, []).append(obs)

    def get(self, metric_name: str) -> list[RawObservation]:
        return self._by_metric.get(metric_name, [])

    def scalar(self, metric_name: str, default: Any = None) -> Any:
        """Return the first value for a metric, or default."""
        obs_list = self.get(metric_name)
        return obs_list[0].metric_value if obs_list else default

    def scalar_for_drive(self, metric_name: str, drive: str) -> Any | None:
        for obs in self.get(metric_name):
            if obs.drive == drive:
                return obs.metric_value
        return None

    def confidence(self, metric_name: str) -> float:
        obs_list = self.get(metric_name)
        return obs_list[0].confidence if obs_list else 0.5


@dataclass
class DiagnosisCandidate:
    category: DiagnosisCategory
    severity: Severity
    confidence: float
    evidence_keys: list[str] = field(default_factory=list)
    is_primary: bool = False


class DiagnosisEngine:
    """
    Deterministic rule-based diagnosis engine.

    Rule evaluation order matters: rules are evaluated in definition order.
    The first rule that produces a primary diagnosis wins;
    all other triggered rules become secondary diagnoses.

    Each rule is a method prefixed with `_rule_`.
    Rules return DiagnosisCandidate | None.
    """

    def diagnose(
        self,
        observations: list[RawObservation],
        context: dict[str, Any],
        symptom: str = "",
    ) -> tuple[DiagnosisResult, ECLInputs, ProbeSummary]:
        idx = ObservationIndex()
        for obs in observations:
            idx.add(obs)

        candidates = self._evaluate_all_rules(idx, context, symptom)

        primary = next((c for c in candidates if c.is_primary), None)
        secondaries = [c for c in candidates if not c.is_primary]

        if primary is None:
            primary = DiagnosisCandidate(
                category=DiagnosisCategory.unknown_health_failure,
                severity=Severity.low,
                confidence=0.40,
                is_primary=True,
            )

        diagnosis = DiagnosisResult(
            primary_diagnosis=primary.category,
            secondary_diagnoses=[c.category for c in secondaries],
            symptom=symptom or self._infer_symptom(primary.category),
            immediate_cause=self._immediate_cause(primary.category, idx),
            root_cause=self._root_cause(primary.category, idx),
            contributing_factors=self._contributing_factors(candidates, idx),
            severity=primary.severity,
            impact_scope=context.get("operation"),
            recoverability=self._recoverability(primary.category),
            recommended_next_action=self._recommended_action(primary.category),
        )

        ecl = self._compute_ecl(primary, candidates, idx)
        probe_summary = self._build_probe_summary(idx)

        return diagnosis, ecl, probe_summary

    # ------------------------------------------------------------------
    # Rule evaluation
    # ------------------------------------------------------------------

    def _evaluate_all_rules(
        self,
        idx: ObservationIndex,
        context: dict[str, Any],
        symptom: str,
    ) -> list[DiagnosisCandidate]:
        rules = [
            self._rule_cache_path_misrouted,
            self._rule_disk_exhaustion_effective_path,
            self._rule_env_override_conflict,
            self._rule_temp_path_misrouted,
            self._rule_headroom_below_policy,
            self._rule_disk_exhaustion_absolute,
            self._rule_runtime_missing_from_path,
            self._rule_declared_runtime_unavailable,
        ]

        candidates: list[DiagnosisCandidate] = []
        primary_set = False

        for rule in rules:
            candidate = rule(idx, context, symptom)
            if candidate is not None:
                if not primary_set:
                    candidate.is_primary = True
                    primary_set = True
                candidates.append(candidate)

        return candidates

    # ------------------------------------------------------------------
    # Individual rules
    # ------------------------------------------------------------------

    def _rule_cache_path_misrouted(
        self, idx: ObservationIndex, context: dict[str, Any], symptom: str
    ) -> DiagnosisCandidate | None:
        """
        Triggered when: effective cache path != declared cache path
        AND effective cache drive is a reserved partition or has 0 free bytes.
        Reference: npm ENOSPC gold fixture.
        """
        path_mismatch = idx.scalar("path_mismatch_detected", False)
        effective_cache = idx.scalar("effective_cache_path", "")
        effective_drive = idx.scalar("effective_cache_drive", "")

        if not path_mismatch:
            return None

        # Cross-reference drive health
        drive_reserved = idx.scalar_for_drive("drive_is_reserved_partition", effective_drive)
        drive_free = idx.scalar_for_drive("drive_free_bytes", effective_drive)

        if drive_reserved or (drive_free is not None and drive_free < context.get("min_free_space_bytes", 2 * 1024 ** 3)):
            return DiagnosisCandidate(
                category=DiagnosisCategory.cache_path_misrouted,
                severity=Severity.high,
                confidence=min(
                    idx.confidence("path_mismatch_detected"),
                    idx.confidence("effective_cache_path"),
                    0.96,
                ),
                evidence_keys=["path_mismatch_detected", "effective_cache_path", "drive_free_bytes"],
            )
        return None

    def _rule_disk_exhaustion_effective_path(
        self, idx: ObservationIndex, context: dict[str, Any], symptom: str
    ) -> DiagnosisCandidate | None:
        """Triggered when the effective cache drive has insufficient free space."""
        effective_drive = idx.scalar("effective_cache_drive", "")
        if not effective_drive:
            return None
        drive_free = idx.scalar_for_drive("drive_free_bytes", effective_drive)
        floor = context.get("min_free_space_bytes", 2 * 1024 ** 3)
        if drive_free is not None and drive_free < floor:
            return DiagnosisCandidate(
                category=DiagnosisCategory.disk_exhaustion_effective_path,
                severity=Severity.high,
                confidence=1.0,
                evidence_keys=["drive_free_bytes", "effective_cache_drive"],
            )
        return None

    def _rule_env_override_conflict(
        self, idx: ObservationIndex, context: dict[str, Any], symptom: str
    ) -> DiagnosisCandidate | None:
        """Triggered when npm_config_cache env var is overriding global config."""
        env_override = idx.scalar("npm_config_cache_env_override", "")
        override_source = idx.scalar("npm_config_cache_override_source", "")
        if env_override and "process scope" in (override_source or ""):
            return DiagnosisCandidate(
                category=DiagnosisCategory.env_override_conflict,
                severity=Severity.high,
                confidence=0.98,
                evidence_keys=["npm_config_cache_env_override", "npm_config_cache_override_source"],
            )
        return None

    def _rule_temp_path_misrouted(
        self, idx: ObservationIndex, context: dict[str, Any], symptom: str
    ) -> DiagnosisCandidate | None:
        """Triggered when TEMP/TMP points to a reserved or exhausted partition."""
        temp_path = idx.scalar("effective_temp_path", "")
        temp_drive = idx.scalar("effective_temp_drive", "")
        if not temp_drive:
            return None
        drive_reserved = idx.scalar_for_drive("drive_is_reserved_partition", temp_drive)
        drive_free = idx.scalar_for_drive("drive_free_bytes", temp_drive)
        floor = context.get("min_free_space_bytes", 2 * 1024 ** 3)
        if drive_reserved or (drive_free is not None and drive_free < floor):
            return DiagnosisCandidate(
                category=DiagnosisCategory.temp_path_misrouted,
                severity=Severity.high,
                confidence=0.92,
                evidence_keys=["effective_temp_path", "effective_temp_drive", "drive_free_bytes"],
            )
        return None

    def _rule_headroom_below_policy(
        self, idx: ObservationIndex, context: dict[str, Any], symptom: str
    ) -> DiagnosisCandidate | None:
        """Triggered when any relevant drive is below the policy floor."""
        floor = context.get("min_free_space_bytes", 2 * 1024 ** 3)
        for obs in idx.get("drive_free_bytes"):
            if obs.metric_value < floor:
                reserved = idx.scalar_for_drive("drive_is_reserved_partition", obs.drive or "")
                if not reserved:  # reserved partition already handled above
                    return DiagnosisCandidate(
                        category=DiagnosisCategory.headroom_below_policy,
                        severity=Severity.medium,
                        confidence=1.0,
                        evidence_keys=["drive_free_bytes"],
                    )
        return None

    def _rule_disk_exhaustion_absolute(
        self, idx: ObservationIndex, context: dict[str, Any], symptom: str
    ) -> DiagnosisCandidate | None:
        """Triggered when ALL relevant drives are below policy floor — true exhaustion."""
        floor = context.get("min_free_space_bytes", 2 * 1024 ** 3)
        all_obs = idx.get("drive_free_bytes")
        if not all_obs:
            return None
        if all(o.metric_value < floor for o in all_obs):
            return DiagnosisCandidate(
                category=DiagnosisCategory.disk_exhaustion_absolute,
                severity=Severity.critical,
                confidence=1.0,
                evidence_keys=["drive_free_bytes"],
            )
        return None

    def _rule_runtime_missing_from_path(
        self, idx: ObservationIndex, context: dict[str, Any], symptom: str
    ) -> DiagnosisCandidate | None:
        """Triggered when a critical command is not found in PATH."""
        for obs in idx.get("path_entries"):
            pass  # PATH presence checked via command_available metrics

        toolchain = context.get("toolchain", "")
        cmd_key = f"command_available.{toolchain}"
        available = idx.scalar(cmd_key)
        if available is False:
            return DiagnosisCandidate(
                category=DiagnosisCategory.runtime_missing_from_path,
                severity=Severity.high,
                confidence=1.0,
                evidence_keys=[cmd_key],
            )
        return None

    def _rule_declared_runtime_unavailable(
        self, idx: ObservationIndex, context: dict[str, Any], symptom: str
    ) -> DiagnosisCandidate | None:
        """
        Triggered when any declared command is unavailable.
        Reference: uv ENOENT MCP launch failure.
        """
        for obs in idx.get("command_available.uv"):
            if obs.metric_value is False:
                return DiagnosisCandidate(
                    category=DiagnosisCategory.declared_runtime_unavailable,
                    severity=Severity.high,
                    confidence=1.0,
                    evidence_keys=["command_available.uv"],
                )
        return None

    # ------------------------------------------------------------------
    # Narrative builders
    # ------------------------------------------------------------------

    def _infer_symptom(self, category: DiagnosisCategory) -> str:
        return {
            DiagnosisCategory.cache_path_misrouted: "tool install failed with no-space error",
            DiagnosisCategory.disk_exhaustion_effective_path: "write failed on effective path drive",
            DiagnosisCategory.env_override_conflict: "environment variable overriding correct config",
            DiagnosisCategory.temp_path_misrouted: "temp operations routed to exhausted partition",
            DiagnosisCategory.runtime_missing_from_path: "command not found in effective PATH",
            DiagnosisCategory.declared_runtime_unavailable: "spawn failed — command not runnable",
        }.get(category, "unknown symptom")

    def _immediate_cause(self, category: DiagnosisCategory, idx: ObservationIndex) -> str:
        if category == DiagnosisCategory.cache_path_misrouted:
            eff = idx.scalar("effective_cache_path", "unknown")
            drive = idx.scalar("effective_cache_drive", "unknown")
            free = idx.scalar_for_drive("drive_free_bytes", drive)
            free_str = f"{free:,} bytes" if free is not None else "unknown"
            return f"write to effective cache path {eff!r} failed — drive {drive} has {free_str} free"
        if category == DiagnosisCategory.env_override_conflict:
            override = idx.scalar("npm_config_cache_env_override", "")
            return f"npm_config_cache env var forces cache to {override!r}"
        return "write or execution failed on the effective path"

    def _root_cause(self, category: DiagnosisCategory, idx: ObservationIndex) -> str:
        if category == DiagnosisCategory.cache_path_misrouted:
            src = idx.scalar("npm_config_cache_override_source", "env override")
            decl = idx.scalar("declared_cache_path", "correct path")
            return (
                f"{src} overrides the correct global config ({decl!r}), "
                "routing all cache writes to an exhausted or reserved partition"
            )
        if category == DiagnosisCategory.env_override_conflict:
            return (
                "A process-scope environment variable is winning over the "
                "user/global config, hiding the correct setting"
            )
        return "effective execution path does not match declared configuration"

    def _contributing_factors(
        self, candidates: list[DiagnosisCandidate], idx: ObservationIndex
    ) -> list[str]:
        factors = []
        eff_drive = idx.scalar("effective_cache_drive", "")
        if eff_drive:
            free = idx.scalar_for_drive("drive_free_bytes", eff_drive)
            total = idx.scalar_for_drive("drive_total_bytes", eff_drive)
            reserved = idx.scalar_for_drive("drive_is_reserved_partition", eff_drive)
            if reserved:
                factors.append(f"Drive {eff_drive} is a reserved/system partition (total: {total} bytes)")
            if free is not None and free == 0:
                factors.append(f"Drive {eff_drive} has 0 bytes free")
        env_override = idx.scalar("npm_config_cache_env_override", "")
        if env_override:
            factors.append(f"npm_config_cache env var set to {env_override!r}")
        declared = idx.scalar("declared_cache_path", "")
        if declared:
            factors.append(f"Correct global config value: {declared!r} (shadowed)")
        return factors

    def _recoverability(self, category: DiagnosisCategory) -> Recoverability:
        safe_categories = {
            DiagnosisCategory.cache_path_misrouted,
            DiagnosisCategory.disk_exhaustion_effective_path,
            DiagnosisCategory.env_override_conflict,
            DiagnosisCategory.temp_path_misrouted,
            DiagnosisCategory.headroom_below_policy,
        }
        if category in safe_categories:
            return Recoverability.recoverable_with_safe_actions
        if category == DiagnosisCategory.disk_exhaustion_absolute:
            return Recoverability.requires_operator_intervention
        return Recoverability.recoverable_with_guarded_actions

    def _recommended_action(self, category: DiagnosisCategory) -> str:
        return {
            DiagnosisCategory.cache_path_misrouted: "plan_safe_remediation",
            DiagnosisCategory.disk_exhaustion_effective_path: "plan_safe_remediation",
            DiagnosisCategory.env_override_conflict: "plan_safe_remediation",
            DiagnosisCategory.temp_path_misrouted: "plan_safe_remediation",
            DiagnosisCategory.headroom_below_policy: "plan_safe_remediation",
            DiagnosisCategory.disk_exhaustion_absolute: "escalate_to_operator",
            DiagnosisCategory.runtime_missing_from_path: "install_or_expose_runtime",
            DiagnosisCategory.declared_runtime_unavailable: "install_or_expose_runtime",
        }.get(category, "diagnose_further")

    def _compute_ecl(
        self,
        primary: DiagnosisCandidate,
        all_candidates: list[DiagnosisCandidate],
        idx: ObservationIndex,
    ) -> ECLInputs:
        # config_stability: penalized when effective != declared
        path_mismatch = idx.scalar("path_mismatch_detected", False)
        env_override = idx.scalar("npm_config_cache_env_override", "")
        config_stability = 1.0
        if path_mismatch:
            config_stability -= 0.50
        if env_override:
            config_stability -= 0.28
        config_stability = max(0.0, round(config_stability, 2))

        return ECLInputs(
            diagnosis_confidence=primary.confidence,
            path_attribution_confidence=min(
                idx.confidence("effective_cache_path"),
                idx.confidence("path_mismatch_detected"),
            ),
            config_stability=config_stability,
        )

    def _build_probe_summary(self, idx: ObservationIndex) -> ProbeSummary:
        # Build drive_free_bytes dict from all drive observations
        drive_free: dict[str, int] = {}
        for obs in idx.get("drive_free_bytes"):
            if obs.drive:
                drive_free[obs.drive] = int(obs.metric_value)

        return ProbeSummary(
            project_drive=None,  # set by path probe in Phase 2
            effective_cache_drive=idx.scalar("effective_cache_drive"),
            effective_cache_path=idx.scalar("effective_cache_path"),
            declared_cache_path=idx.scalar("declared_cache_path"),
            effective_temp_path=idx.scalar("effective_temp_path"),
            path_mismatch_detected=bool(idx.scalar("path_mismatch_detected", False)),
            drive_free_bytes=drive_free,
        )
