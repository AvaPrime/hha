"""
Codessa Health Adapter — API Contract Schemas (Pydantic v2)
Matches Mission Control ↔ Health Adapter Integration Contract v1.0 exactly.
All field names, types, and optionality are authoritative.
"""
from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any
from uuid import UUID

from pydantic import BaseModel, Field, model_validator


# ---------------------------------------------------------------------------
# Enums — must stay in sync with SQL enum types in schema pack
# ---------------------------------------------------------------------------

class ExecutionMode(str, Enum):
    observe_only = "observe_only"
    diagnose_only = "diagnose_only"
    plan_only = "plan_only"
    diagnose_and_plan = "diagnose_and_plan"
    diagnose_and_remediate_safe = "diagnose_and_remediate_safe"
    diagnose_and_remediate_guarded = "diagnose_and_remediate_guarded"
    execute_approved_plan = "execute_approved_plan"
    verify_only = "verify_only"
    fitness_only = "fitness_only"


class PolicyMode(str, Enum):
    observe_only = "observe_only"
    recommend_only = "recommend_only"
    safe_auto_remediate = "safe_auto_remediate"
    guarded_auto_remediate = "guarded_auto_remediate"
    halt_and_escalate = "halt_and_escalate"


class Toolchain(str, Enum):
    npm = "npm"
    pnpm = "pnpm"
    yarn = "yarn"
    pip = "pip"
    uv = "uv"
    cargo = "cargo"
    docker_build = "docker_build"
    java_maven = "java_maven"
    java_gradle = "java_gradle"
    dotnet = "dotnet"
    general = "general"


class Severity(str, Enum):
    info = "info"
    low = "low"
    medium = "medium"
    high = "high"
    critical = "critical"


class Recoverability(str, Enum):
    fully_recoverable = "fully_recoverable"
    recoverable_with_safe_actions = "recoverable_with_safe_actions"
    recoverable_with_guarded_actions = "recoverable_with_guarded_actions"
    requires_operator_intervention = "requires_operator_intervention"
    not_recoverable_in_scope = "not_recoverable_in_scope"


class DiagnosisCategory(str, Enum):
    disk_exhaustion_absolute = "disk_exhaustion_absolute"
    disk_exhaustion_effective_path = "disk_exhaustion_effective_path"
    cache_path_misrouted = "cache_path_misrouted"
    temp_path_misrouted = "temp_path_misrouted"
    workspace_oversized = "workspace_oversized"
    cache_corruption_or_bloat = "cache_corruption_or_bloat"
    install_artifact_conflict = "install_artifact_conflict"
    env_override_conflict = "env_override_conflict"
    config_shadowing = "config_shadowing"
    config_persistence_conflict = "config_persistence_conflict"
    env_override_reinjection = "env_override_reinjection"
    config_shadowing_persistent = "config_shadowing_persistent"
    config_source_ambiguity = "config_source_ambiguity"
    unsafe_cleanup_required = "unsafe_cleanup_required"
    headroom_below_policy = "headroom_below_policy"
    unknown_health_failure = "unknown_health_failure"
    # Environment audit additions
    environment_scope_conflict = "environment_scope_conflict"
    runtime_missing_from_path = "runtime_missing_from_path"
    declared_runtime_unavailable = "declared_runtime_unavailable"
    path_shadowing_high_risk = "path_shadowing_high_risk"
    process_env_stale_after_persistent_fix = "process_env_stale_after_persistent_fix"
    restart_required_for_env_convergence = "restart_required_for_env_convergence"
    temp_route_reserved_partition = "temp_route_reserved_partition"
    cwd_assumption_invalid = "cwd_assumption_invalid"
    tool_launcher_misresolved = "tool_launcher_misresolved"
    declared_effective_env_mismatch = "declared_effective_env_mismatch"


class ActionType(str, Enum):
    capture_snapshot = "capture_snapshot"
    clean_tool_cache = "clean_tool_cache"
    remove_node_modules = "remove_node_modules"
    remove_lockfile = "remove_lockfile"
    prune_temp_directory = "prune_temp_directory"
    rebind_cache_path = "rebind_cache_path"
    rebind_temp_path = "rebind_temp_path"
    set_env_var_user = "set_env_var_user"
    set_env_var_machine = "set_env_var_machine"
    clear_env_var_user = "clear_env_var_user"
    clear_env_var_machine = "clear_env_var_machine"
    rewrite_tool_config = "rewrite_tool_config"
    run_target_command = "run_target_command"
    verify_thresholds = "verify_thresholds"
    restart_required_flag = "restart_required_flag"
    install_runtime = "install_runtime"
    expose_runtime_to_path = "expose_runtime_to_path"
    other = "other"


class ActionRisk(str, Enum):
    low = "low"
    medium = "medium"
    high = "high"


class FitStatus(str, Enum):
    fit = "fit"
    fit_with_constraints = "fit_with_constraints"
    not_fit = "not_fit"


class ResponseStatus(str, Enum):
    completed = "completed"
    completed_with_warnings = "completed_with_warnings"
    partial = "partial"
    failed = "failed"
    denied = "denied"


class ErrorCode(str, Enum):
    bad_request = "BAD_REQUEST"
    unsupported_toolchain = "UNSUPPORTED_TOOLCHAIN"
    workspace_not_found = "WORKSPACE_NOT_FOUND"
    target_not_writable = "TARGET_NOT_WRITABLE"
    probe_failed = "PROBE_FAILED"
    diagnosis_failed = "DIAGNOSIS_FAILED"
    plan_not_found = "PLAN_NOT_FOUND"
    policy_denied = "POLICY_DENIED"
    action_not_allowed = "ACTION_NOT_ALLOWED"
    execution_failed = "EXECUTION_FAILED"
    verification_failed = "VERIFICATION_FAILED"
    artifact_write_failed = "ARTIFACT_WRITE_FAILED"
    ledger_write_failed = "LEDGER_WRITE_FAILED"
    timeout = "TIMEOUT"
    internal_error = "INTERNAL_ERROR"


# ---------------------------------------------------------------------------
# Shared sub-models
# ---------------------------------------------------------------------------

class ActorContext(BaseModel):
    actor_id: str
    actor_type: str = "user"


class DeviceContext(BaseModel):
    device_id: str
    device_class: str = "workstation"
    os_family: str  # 'linux' | 'windows' | 'darwin'


class WorkspaceContext(BaseModel):
    workspace_id: str
    project_path: str | None = None
    project_id: str | None = None


class TargetContext(BaseModel):
    toolchain: Toolchain | None = None
    operation: str | None = None
    symptom: str | None = None


class PolicyEnvelope(BaseModel):
    policy_mode: PolicyMode = PolicyMode.recommend_only
    allow_persistent_config_changes: bool = False
    allow_env_var_mutation: bool = False
    allow_cache_cleanup: bool = False
    allow_temp_cleanup: bool = False
    allow_project_install_artifact_removal: bool = False
    allow_cross_drive_cache_relocation: bool = False
    allow_guarded_actions: bool = False
    approved_target_roots: list[str] = Field(default_factory=list)
    min_free_space_bytes: int = 2 * 1024 ** 3  # 2 GB default
    max_temp_cleanup_scope: str = "approved_roots_only"


class RequestContext(BaseModel):
    expected_free_space_floor_bytes: int = 2 * 1024 ** 3
    capture_artifacts: bool = True
    include_probe_details: bool = False
    requested_checks: list[str] = Field(default_factory=list)
    provided_error_text: str | None = None
    provided_logs: list[str] = Field(default_factory=list)
    timeout_ms: int | None = None
    artifact_capture_budget_ms: int | None = None


class StructuredError(BaseModel):
    code: ErrorCode
    message: str
    retryable: bool = False
    layer: str = "adapter"
    details: dict[str, Any] = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# Request envelope (shared base for all endpoints)
# ---------------------------------------------------------------------------

class BaseHealthRequest(BaseModel):
    contract_name: str = "mission_control.health_adapter"
    contract_version: str = "1.0"
    schema_version: str = "1.0"
    request_id: str
    trace_id: str
    timestamp: datetime = Field(default_factory=datetime.utcnow)
    actor: ActorContext | None = None
    device: DeviceContext | None = None
    workspace: WorkspaceContext | None = None
    target: TargetContext | None = None
    execution_mode: ExecutionMode
    policy_envelope: PolicyEnvelope = Field(default_factory=PolicyEnvelope)
    context: RequestContext = Field(default_factory=RequestContext)
    idempotency_key: str | None = None
    plan_ref: dict[str, str] | None = None  # {"plan_id": "..."}

    @model_validator(mode="after")
    def require_device_for_mutating_modes(self) -> "BaseHealthRequest":
        mutating = {
            ExecutionMode.diagnose_and_remediate_safe,
            ExecutionMode.diagnose_and_remediate_guarded,
            ExecutionMode.execute_approved_plan,
        }
        if self.execution_mode in mutating and self.device is None:
            raise ValueError("device context is required for mutating execution modes")
        return self


# ---------------------------------------------------------------------------
# Diagnosis response types
# ---------------------------------------------------------------------------

class DiagnosisResult(BaseModel):
    primary_diagnosis: DiagnosisCategory
    secondary_diagnoses: list[DiagnosisCategory] = Field(default_factory=list)
    symptom: str
    immediate_cause: str | None = None
    root_cause: str | None = None
    contributing_factors: list[str] = Field(default_factory=list)
    severity: Severity
    impact_scope: str | None = None
    recoverability: Recoverability = Recoverability.recoverable_with_safe_actions
    recommended_next_action: str | None = None


class ProbeSummary(BaseModel):
    project_drive: str | None = None
    effective_cache_drive: str | None = None
    effective_cache_path: str | None = None
    declared_cache_path: str | None = None
    effective_temp_path: str | None = None
    path_mismatch_detected: bool = False
    drive_free_bytes: dict[str, int] = Field(default_factory=dict)  # {"C:": 7645179904, ...}
    additional: dict[str, Any] = Field(default_factory=dict)


class ECLInputs(BaseModel):
    diagnosis_confidence: float = Field(ge=0.0, le=1.0)
    path_attribution_confidence: float = Field(ge=0.0, le=1.0)
    remediation_confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    verification_confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    config_stability: float = Field(ge=0.0, le=1.0)


# ---------------------------------------------------------------------------
# Remediation plan types
# ---------------------------------------------------------------------------

class PlanStep(BaseModel):
    step_id: str
    action_type: ActionType
    target: str | None = None
    rationale: str | None = None
    risk: ActionRisk = ActionRisk.low
    reversible: bool = False
    approval_required: bool = False
    estimated_freed_bytes: int | None = None
    verification_check: str | None = None
    parameters: dict[str, Any] = Field(default_factory=dict)


class RemediationPlan(BaseModel):
    plan_id: str
    policy_mode: PolicyMode
    requires_approval: bool = False
    estimated_risk: ActionRisk = ActionRisk.low
    estimated_recovery_probability: float | None = Field(default=None, ge=0.0, le=1.0)
    steps: list[PlanStep]


# ---------------------------------------------------------------------------
# Execution result types
# ---------------------------------------------------------------------------

class ActionEventResult(BaseModel):
    step_id: str
    action_type: ActionType
    result_status: str  # 'success' | 'failed' | 'skipped' | 'dry_run_only'
    exit_code: int | None = None
    error_message: str | None = None


class ExecutionResult(BaseModel):
    plan_id: str
    overall_status: str
    steps_executed: int
    steps_succeeded: int
    steps_failed: int
    action_events: list[ActionEventResult] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Verification types
# ---------------------------------------------------------------------------

class VerificationCheck(BaseModel):
    check_name: str
    status: str  # 'pass' | 'fail' | 'skip'
    observed_value: Any = None
    expected_value: Any = None
    detail: str | None = None


class VerificationResult(BaseModel):
    overall_pass: bool
    checks: list[VerificationCheck]
    followup_required: bool = False
    followup_notes: str | None = None


# ---------------------------------------------------------------------------
# Fitness types
# ---------------------------------------------------------------------------

class BlockingCondition(BaseModel):
    factor_type: str
    severity: Severity
    description: str


class FitnessResult(BaseModel):
    device_id: str
    workspace_id: str | None = None
    toolchain: Toolchain | None = None
    storage_fitness: float | None = Field(default=None, ge=0.0, le=1.0)
    temp_path_fitness: float | None = Field(default=None, ge=0.0, le=1.0)
    cache_path_fitness: float | None = Field(default=None, ge=0.0, le=1.0)
    install_fitness: float | None = Field(default=None, ge=0.0, le=1.0)
    workspace_headroom_fitness: float | None = Field(default=None, ge=0.0, le=1.0)
    overall_fitness: float = Field(ge=0.0, le=1.0)
    fit_status: FitStatus
    blocking_conditions: list[BlockingCondition] = Field(default_factory=list)
    advisories: list[str] = Field(default_factory=list)
    stale_after: datetime | None = None


# ---------------------------------------------------------------------------
# Artifact types
# ---------------------------------------------------------------------------

class ArtifactRef(BaseModel):
    artifact_id: str
    artifact_type: str
    format: str = "json"
    uri: str | None = None
    content_hash: str | None = None
    size_bytes: int | None = None


# ---------------------------------------------------------------------------
# Canonical refs
# ---------------------------------------------------------------------------

class CanonicalRefs(BaseModel):
    trace_id: str | None = None
    diagnosis_ref: str | None = None
    plan_ref: str | None = None
    incident_ref: str | None = None
    verification_ref: str | None = None


# ---------------------------------------------------------------------------
# Shared response base
# ---------------------------------------------------------------------------

class BaseHealthResponse(BaseModel):
    contract_name: str = "mission_control.health_adapter"
    contract_version: str = "1.0"
    schema_version: str = "1.0"
    request_id: str
    trace_id: str
    status: ResponseStatus
    result_type: str
    adapter_runtime_ms: int | None = None
    warnings: list[str] = Field(default_factory=list)
    errors: list[StructuredError] = Field(default_factory=list)
    artifacts: list[ArtifactRef] = Field(default_factory=list)
    canonical_refs: CanonicalRefs | None = None


# ---------------------------------------------------------------------------
# Endpoint-specific response models
# ---------------------------------------------------------------------------

class DiagnoseResponse(BaseHealthResponse):
    result_type: str = "diagnosis_result"
    diagnosis: DiagnosisResult | None = None
    ecl_inputs: ECLInputs | None = None
    probe_summary: ProbeSummary | None = None


class PlanResponse(BaseHealthResponse):
    result_type: str = "remediation_plan_result"
    plan: RemediationPlan | None = None
    ecl_inputs: ECLInputs | None = None


class ExecuteResponse(BaseHealthResponse):
    result_type: str = "execution_result"
    execution: ExecutionResult | None = None
    ecl_inputs: ECLInputs | None = None


class VerifyResponse(BaseHealthResponse):
    result_type: str = "verification_result"
    verification: VerificationResult | None = None
    ecl_inputs: ECLInputs | None = None


class FitnessResponse(BaseHealthResponse):
    result_type: str = "fitness_result"
    fitness: FitnessResult | None = None
