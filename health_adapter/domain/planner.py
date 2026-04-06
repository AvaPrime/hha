from __future__ import annotations

from health_adapter.domain.models import HealthDiagnosis, RemediationPlan


def plan_remediation(diagnosis: HealthDiagnosis) -> RemediationPlan:
    steps: list[dict] = [
        {
            'step_id': 'step_01',
            'action_type': 'record_baseline_snapshot',
            'target_path': diagnosis.workspace_id,
            'rationale': 'Capture pre-state',
            'risk_level': 'low',
            'reversible': True,
            'approval_requirement': 'none',
        }
    ]

    if diagnosis.primary_diagnosis == 'cache_path_misrouted':
        steps.extend(
            [
                {
                    'step_id': 'step_02',
                    'action_type': 'clean_tool_cache',
                    'target_path': 'effective_cache_path',
                    'rationale': 'Remove exhausted or corrupt cache artifacts',
                    'risk_level': 'low',
                    'reversible': False,
                    'approval_requirement': 'none',
                },
                {
                    'step_id': 'step_03',
                    'action_type': 'remove_project_install_artifacts',
                    'target_path': 'node_modules',
                    'rationale': 'Free install artifacts and reset dependency state',
                    'risk_level': 'medium',
                    'reversible': False,
                    'approval_requirement': 'none',
                },
                {
                    'step_id': 'step_04',
                    'action_type': 'rebind_cache_to_approved_path',
                    'target_path': 'approved_cache_path',
                    'rationale': 'Prefer relocation over destructive cleanup when approved capacity exists',
                    'risk_level': 'low',
                    'reversible': True,
                    'approval_requirement': 'none',
                },
                {
                    'step_id': 'step_05',
                    'action_type': 'retry_toolchain_command',
                    'target_path': 'project_path',
                    'rationale': 'Verify recovery by retrying the original failing command',
                    'risk_level': 'low',
                    'reversible': False,
                    'approval_requirement': 'none',
                },
            ]
        )

    return RemediationPlan(
        trace_id=diagnosis.trace_id,
        device_id=diagnosis.device_id,
        workspace_id=diagnosis.workspace_id,
        diagnosis_id=None,
        policy_mode='recommend_only' if diagnosis.confidence_score < 0.75 else 'safe_auto_remediate',
        requires_approval=True,
        estimated_risk='low' if diagnosis.severity in ('info', 'low', 'medium') else 'medium',
        estimated_recovery_probability=0.9 if diagnosis.primary_diagnosis == 'cache_path_misrouted' else 0.5,
        confidence_score=min(0.95, diagnosis.confidence_score),
        plan_steps=steps,
        reversal_strategy={},
    )

