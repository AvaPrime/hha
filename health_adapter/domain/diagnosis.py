from __future__ import annotations

import uuid

from health_adapter.domain.models import DiagnosisCategory, EvidenceEnvelope, HealthDiagnosis


def _drive_letter(path: str | None) -> str | None:
    if not path:
        return None
    if len(path) >= 2 and path[1] == ':':
        return path[:2].upper()
    return None


def diagnose(envelope: EvidenceEnvelope) -> HealthDiagnosis:
    trace_id = f"trc_{uuid.uuid4().hex}"

    toolchain = (envelope.request.target_toolchain or '').lower()
    if toolchain != 'npm':
        return HealthDiagnosis(
            trace_id=trace_id,
            device_id=envelope.request.device_id,
            workspace_id=envelope.request.workspace_id,
            primary_diagnosis='unknown_health_failure',
            secondary_diagnoses=(),
            symptom=envelope.request.symptom,
            immediate_cause=None,
            root_cause=None,
            contributing_factors=(),
            impact_scope=None,
            severity='medium',
            confidence_score=0.40,
            confidence_breakdown={'toolchain_support': 0.0, 'evidence_sufficiency': 0.4},
        )

    evidence = envelope.toolchain_evidence
    effective_cache_path = evidence.paths.effective_cache_path if evidence else None
    configured_cache_path = evidence.paths.configured_cache_path if evidence else None
    effective_temp_path = evidence.paths.effective_temp_path if evidence else None
    override_cache = (evidence.env_overrides.get('npm_config_cache') if evidence else None)

    effective_cache_drive = _drive_letter(effective_cache_path)
    configured_cache_drive = _drive_letter(configured_cache_path)
    temp_drive = _drive_letter(effective_temp_path)

    symptom = envelope.request.symptom.lower()
    mentions_enospc = 'enospc' in symptom
    cache_drive_stat = envelope.drive_stats.get(effective_cache_drive or '')
    cache_drive_free = cache_drive_stat.free_bytes if cache_drive_stat else None

    secondary: list[DiagnosisCategory] = []
    contributing: list[str] = []

    if override_cache:
        secondary.append('env_override_conflict')
        contributing.append('Environment override npm_config_cache set effective cache path')

    if effective_cache_drive and configured_cache_drive and effective_cache_drive != configured_cache_drive:
        secondary.append('config_shadowing')
        contributing.append('Configured cache path differs from effective cache path')

    if temp_drive and effective_cache_drive and temp_drive == effective_cache_drive:
        secondary.append('temp_path_misrouted')
        contributing.append('Temp path co-located with effective cache path')

    if mentions_enospc and cache_drive_free is not None and cache_drive_free <= 0:
        primary: DiagnosisCategory = 'cache_path_misrouted'
        secondary.insert(0, 'disk_exhaustion_effective_path')
        immediate = f"write to {effective_cache_path} failed because the effective cache drive is exhausted"
        root = 'npm_config_cache override or config resolution pointed cache at an exhausted partition'
        severity = 'high'
        confidence = 0.92
        breakdown = {
            'filesystem_evidence': 1.0,
            'path_consistency': 0.95,
            'config_agreement': 0.85,
            'freshness': 0.90,
            'verification': 0.00,
        }
    else:
        primary = 'unknown_health_failure'
        immediate = None
        root = None
        severity = 'medium'
        confidence = 0.55 if evidence else 0.35
        breakdown = {
            'filesystem_evidence': 0.6 if envelope.drive_stats else 0.2,
            'path_consistency': 0.5 if evidence else 0.0,
            'config_agreement': 0.5 if evidence else 0.0,
            'freshness': 0.8,
            'verification': 0.0,
        }

    seen: set[DiagnosisCategory] = set()
    dedup_secondary: list[DiagnosisCategory] = []
    for item in secondary:
        if item in seen:
            continue
        seen.add(item)
        dedup_secondary.append(item)

    return HealthDiagnosis(
        trace_id=trace_id,
        device_id=envelope.request.device_id,
        workspace_id=envelope.request.workspace_id,
        primary_diagnosis=primary,
        secondary_diagnoses=tuple(dedup_secondary),
        symptom=envelope.request.symptom,
        immediate_cause=immediate,
        root_cause=root,
        contributing_factors=tuple(contributing),
        impact_scope='dependency_install',
        severity=severity,
        confidence_score=confidence,
        confidence_breakdown=breakdown,
    )

