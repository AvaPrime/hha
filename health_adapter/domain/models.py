from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Literal


PolicyMode = Literal[
    'observe_only',
    'recommend_only',
    'safe_auto_remediate',
    'guarded_auto_remediate',
    'halt_and_escalate',
]


DiagnosisCategory = Literal[
    'disk_exhaustion_absolute',
    'disk_exhaustion_effective_path',
    'cache_path_misrouted',
    'temp_path_misrouted',
    'workspace_oversized',
    'cache_corruption_or_bloat',
    'install_artifact_conflict',
    'env_override_conflict',
    'config_shadowing',
    'unsafe_cleanup_required',
    'headroom_below_policy',
    'unknown_health_failure',
]


Severity = Literal['info', 'low', 'medium', 'high', 'critical']


@dataclass(frozen=True)
class DriveStat:
    drive: str
    total_bytes: int
    free_bytes: int


@dataclass(frozen=True)
class ToolchainPaths:
    effective_cache_path: str | None = None
    configured_cache_path: str | None = None
    effective_temp_path: str | None = None


@dataclass(frozen=True)
class ToolchainConfigEvidence:
    toolchain: str
    env_overrides: dict[str, str] = field(default_factory=dict)
    paths: ToolchainPaths = field(default_factory=ToolchainPaths)
    config_graph: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class HealthRequest:
    device_id: str
    workspace_id: str | None
    target_toolchain: str
    project_path: str
    symptom: str
    mode: PolicyMode


@dataclass(frozen=True)
class EvidenceEnvelope:
    request: HealthRequest
    observed_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    drive_stats: dict[str, DriveStat] = field(default_factory=dict)
    toolchain_evidence: ToolchainConfigEvidence | None = None


@dataclass(frozen=True)
class HealthDiagnosis:
    trace_id: str
    device_id: str
    workspace_id: str | None
    primary_diagnosis: DiagnosisCategory
    secondary_diagnoses: tuple[DiagnosisCategory, ...]
    symptom: str
    immediate_cause: str | None
    root_cause: str | None
    contributing_factors: tuple[str, ...]
    impact_scope: str | None
    severity: Severity
    confidence_score: float
    confidence_breakdown: dict[str, float] = field(default_factory=dict)
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass(frozen=True)
class RemediationPlan:
    trace_id: str
    device_id: str
    workspace_id: str | None
    diagnosis_id: str | None
    policy_mode: PolicyMode
    requires_approval: bool
    estimated_risk: Severity | None
    estimated_recovery_probability: float | None
    confidence_score: float | None
    plan_steps: list[dict[str, Any]]
    reversal_strategy: dict[str, Any] = field(default_factory=dict)
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

