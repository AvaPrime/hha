from __future__ import annotations

from dataclasses import asdict

from fastapi import FastAPI

from health_adapter.domain.diagnosis import diagnose
from health_adapter.domain.models import EvidenceEnvelope, HealthRequest, ToolchainConfigEvidence, ToolchainPaths
from health_adapter.domain.planner import plan_remediation


app = FastAPI(title='Codessa Health Adapter', version='1.0')


@app.post('/v1/health/diagnose')
def run_diagnosis(payload: dict):
    request = HealthRequest(
        device_id=payload['device_id'],
        workspace_id=payload.get('workspace_id'),
        target_toolchain=payload.get('target_toolchain', 'unknown'),
        project_path=payload.get('project_path', ''),
        symptom=payload.get('symptom', ''),
        mode=payload.get('mode', 'recommend_only'),
    )

    evidence = ToolchainConfigEvidence(
        toolchain=request.target_toolchain,
        env_overrides=payload.get('env_overrides', {}) or {},
        paths=ToolchainPaths(
            effective_cache_path=payload.get('effective_cache_path'),
            configured_cache_path=payload.get('configured_cache_path'),
            effective_temp_path=payload.get('effective_temp_path'),
        ),
        config_graph=payload.get('config_graph', {}) or {},
    )

    envelope = EvidenceEnvelope(
        request=request,
        drive_stats={},
        toolchain_evidence=evidence,
    )

    diagnosis = diagnose(envelope)
    remediation_plan = plan_remediation(diagnosis)

    return {
        'trace_id': diagnosis.trace_id,
        'status': 'completed',
        'primary_diagnosis': diagnosis.primary_diagnosis,
        'severity': diagnosis.severity,
        'confidence': diagnosis.confidence_score,
        'diagnosis': asdict(diagnosis),
        'remediation_plan': asdict(remediation_plan),
        'artifacts': [],
    }

