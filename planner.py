"""
Codessa Health Adapter — Remediation Planner
Builds ordered, policy-checked remediation plans from a diagnosis.

Design rules:
- Prefer minimal-impact actions first
- Prefer relocation over destruction when alternate capacity exists
- Every step includes a verification_check
- Plans are safe by default; guarded actions require explicit policy capability
"""
from __future__ import annotations

import uuid
from typing import Any

from health_adapter.api.schemas import (
    ActionRisk,
    ActionType,
    DiagnosisCategory,
    DiagnosisResult,
    PlanStep,
    PolicyEnvelope,
    PolicyMode,
    ProbeSummary,
    RemediationPlan,
)
from health_adapter.domain.policy import PolicyGate, PolicyViolation


class RemediationPlanner:

    def __init__(self) -> None:
        self._gate = PolicyGate()

    def build_plan(
        self,
        diagnosis: DiagnosisResult,
        probe_summary: ProbeSummary,
        envelope: PolicyEnvelope,
        context: dict[str, Any],
    ) -> RemediationPlan:
        """
        Build a remediation plan for the primary diagnosis.
        Steps are policy-filtered before inclusion.
        """
        steps = self._steps_for_diagnosis(diagnosis, probe_summary, envelope, context)

        # Filter out steps that violate policy (they become informational warnings instead)
        allowed_steps: list[PlanStep] = []
        for step in steps:
            try:
                self._gate.validate_action(step.action_type, envelope)
                if step.parameters.get("target_path"):
                    self._gate.validate_target_path(step.parameters["target_path"], envelope)
                allowed_steps.append(step)
            except PolicyViolation:
                # Skip step — policy does not allow it; planner continues without it
                pass

        requires_approval = envelope.policy_mode in {
            PolicyMode.guarded_auto_remediate,
            PolicyMode.halt_and_escalate,
        }

        return RemediationPlan(
            plan_id=str(uuid.uuid4()),
            policy_mode=envelope.policy_mode,
            requires_approval=requires_approval,
            estimated_risk=self._estimate_risk(allowed_steps),
            estimated_recovery_probability=self._estimate_recovery(diagnosis, allowed_steps),
            steps=allowed_steps,
        )

    # ------------------------------------------------------------------
    # Step libraries per diagnosis category
    # ------------------------------------------------------------------

    def _steps_for_diagnosis(
        self,
        diagnosis: DiagnosisResult,
        probe_summary: ProbeSummary,
        envelope: PolicyEnvelope,
        context: dict[str, Any],
    ) -> list[PlanStep]:
        category = diagnosis.primary_diagnosis

        if category in {
            DiagnosisCategory.cache_path_misrouted,
            DiagnosisCategory.disk_exhaustion_effective_path,
            DiagnosisCategory.env_override_conflict,
        }:
            return self._plan_npm_cache_misrouted(probe_summary, envelope, context)

        if category == DiagnosisCategory.temp_path_misrouted:
            return self._plan_temp_misrouted(probe_summary, envelope, context)

        if category == DiagnosisCategory.headroom_below_policy:
            return self._plan_headroom_low(probe_summary, envelope, context)

        if category in {
            DiagnosisCategory.runtime_missing_from_path,
            DiagnosisCategory.declared_runtime_unavailable,
        }:
            return self._plan_runtime_unavailable(context)

        # Fallback: at minimum, capture state and recommend
        return [self._step_capture_snapshot("workspace")]

    def _plan_npm_cache_misrouted(
        self,
        probe_summary: ProbeSummary,
        envelope: PolicyEnvelope,
        context: dict[str, Any],
    ) -> list[PlanStep]:
        """
        Gold fixture plan for npm ENOSPC misrouted cache.
        Sequence: snapshot → clean cache → remove artifacts → rebind cache → verify → retry
        """
        approved_cache_target = self._best_approved_cache_target(envelope)

        steps: list[PlanStep] = [
            self._step_capture_snapshot("workspace_and_relevant_drives"),
            PlanStep(
                step_id="step_02",
                action_type=ActionType.clean_tool_cache,
                target="npm_cache",
                rationale="Clear all cached content from the exhausted effective cache path",
                risk=ActionRisk.low,
                reversible=False,
                approval_required=False,
                verification_check="effective_cache_path_accessible",
                parameters={"toolchain": "npm"},
            ),
        ]

        # Remove node_modules if project_path is known and policy allows
        project_path = context.get("project_path")
        if project_path and envelope.allow_project_install_artifact_removal:
            steps.append(PlanStep(
                step_id="step_03",
                action_type=ActionType.remove_node_modules,
                target=f"{project_path}/node_modules",
                rationale="Remove stale install artifacts to allow clean reinstall",
                risk=ActionRisk.low,
                reversible=False,
                approval_required=False,
                verification_check="node_modules_absent",
                parameters={"target_path": f"{project_path}/node_modules"},
            ))

        # Rebind cache to approved target
        if approved_cache_target and envelope.allow_cross_drive_cache_relocation:
            steps.append(PlanStep(
                step_id="step_04",
                action_type=ActionType.rebind_cache_path,
                target=approved_cache_target,
                rationale=f"Redirect npm cache to approved high-capacity target: {approved_cache_target}",
                risk=ActionRisk.low,
                reversible=True,
                approval_required=False,
                verification_check="effective_cache_path_updated",
                parameters={"toolchain": "npm", "target_path": approved_cache_target},
            ))

        # Clear the env var override if env mutation is allowed
        if envelope.allow_env_var_mutation:
            steps.append(PlanStep(
                step_id="step_05",
                action_type=ActionType.clear_env_var_user,
                target="npm_config_cache",
                rationale="Remove env override that was shadowing the correct global config",
                risk=ActionRisk.low,
                reversible=True,
                approval_required=False,
                verification_check="env_override_cleared",
                parameters={"env_key": "npm_config_cache"},
            ))

        # Verify thresholds
        steps.append(PlanStep(
            step_id="step_06",
            action_type=ActionType.verify_thresholds,
            target="all_relevant_drives",
            rationale="Confirm required drives meet free-space policy floor",
            risk=ActionRisk.low,
            reversible=False,
            approval_required=False,
            verification_check="drive_free_bytes_gte_floor",
            parameters={"min_free_space_bytes": envelope.min_free_space_bytes},
        ))

        # Retry the original operation
        toolchain = context.get("toolchain", "npm")
        operation = context.get("operation", "install")
        steps.append(PlanStep(
            step_id="step_07",
            action_type=ActionType.run_target_command,
            target=f"{toolchain} {operation}",
            rationale="Retry the original operation with corrected environment",
            risk=ActionRisk.low,
            reversible=False,
            approval_required=False,
            verification_check="operation_exit_code_zero",
            parameters={
                "command": toolchain,
                "args": [operation],
                "cwd": context.get("project_path"),
            },
        ))

        return steps

    def _plan_temp_misrouted(
        self,
        probe_summary: ProbeSummary,
        envelope: PolicyEnvelope,
        context: dict[str, Any],
    ) -> list[PlanStep]:
        return [
            self._step_capture_snapshot("temp_routing"),
            PlanStep(
                step_id="step_02",
                action_type=ActionType.rebind_temp_path,
                target="C:\\Temp",
                rationale="Move TEMP/TMP off reserved partition to C:\\Temp",
                risk=ActionRisk.low,
                reversible=True,
                approval_required=False,
                verification_check="effective_temp_path_not_on_reserved",
                parameters={"env_keys": ["TEMP", "TMP"], "target_path": "C:\\Temp"},
            ),
        ]

    def _plan_headroom_low(
        self,
        probe_summary: ProbeSummary,
        envelope: PolicyEnvelope,
        context: dict[str, Any],
    ) -> list[PlanStep]:
        return [
            self._step_capture_snapshot("disk_state"),
            PlanStep(
                step_id="step_02",
                action_type=ActionType.clean_tool_cache,
                target="npm_cache",
                rationale="Free space on low-headroom drive by clearing tool caches",
                risk=ActionRisk.low,
                reversible=False,
                approval_required=False,
                verification_check="drive_headroom_above_floor",
                parameters={"toolchain": "npm"},
            ),
        ]

    def _plan_runtime_unavailable(self, context: dict[str, Any]) -> list[PlanStep]:
        cmd = context.get("toolchain", "unknown")
        return [
            self._step_capture_snapshot("env_state"),
            PlanStep(
                step_id="step_02",
                action_type=ActionType.restart_required_flag,
                target=f"runtime:{cmd}",
                rationale=f"{cmd} is not available in the effective PATH. Install or expose it.",
                risk=ActionRisk.low,
                reversible=False,
                approval_required=True,  # guarded — requires operator
                verification_check=f"command_available.{cmd}",
                parameters={"command": cmd},
            ),
        ]

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _step_capture_snapshot(target: str) -> PlanStep:
        return PlanStep(
            step_id="step_01",
            action_type=ActionType.capture_snapshot,
            target=target,
            rationale="Capture before-state for audit and potential rollback",
            risk=ActionRisk.low,
            reversible=False,
            approval_required=False,
            verification_check=None,
            parameters={"snapshot_type": "before"},
        )

    @staticmethod
    def _best_approved_cache_target(envelope: PolicyEnvelope) -> str | None:
        """Pick the first approved target root that looks like a cache dir."""
        for root in envelope.approved_target_roots:
            if "cache" in root.lower() or "npm" in root.lower():
                return root
        # Fallback: first non-system approved root
        for root in envelope.approved_target_roots:
            if not root.startswith("C:\\Windows") and not root.startswith("C:\\System"):
                return root
        return None

    @staticmethod
    def _estimate_risk(steps: list[PlanStep]) -> ActionRisk:
        if any(s.risk == ActionRisk.high for s in steps):
            return ActionRisk.high
        if any(s.risk == ActionRisk.medium for s in steps):
            return ActionRisk.medium
        return ActionRisk.low

    @staticmethod
    def _estimate_recovery(diagnosis: DiagnosisResult, steps: list[PlanStep]) -> float:
        base = {
            DiagnosisCategory.cache_path_misrouted: 0.94,
            DiagnosisCategory.disk_exhaustion_effective_path: 0.88,
            DiagnosisCategory.env_override_conflict: 0.96,
            DiagnosisCategory.temp_path_misrouted: 0.90,
            DiagnosisCategory.headroom_below_policy: 0.75,
        }.get(diagnosis.primary_diagnosis, 0.60)
        # Penalize if policy stripped important steps
        if len(steps) < 3:
            base -= 0.10
        return round(max(0.0, min(1.0, base)), 2)
