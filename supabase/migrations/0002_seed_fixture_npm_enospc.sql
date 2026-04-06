-- =============================================================================
-- Seed fixture: npm ENOSPC misrouted cache incident
-- =============================================================================

BEGIN;

WITH upsert_c AS (
  INSERT INTO hardware_components (
    device_fingerprint, component_type, device_role, vendor, model, expected_operating_profile
  ) VALUES
    ('fixture-device-storage-c', 'storage', 'project_drive_c', 'fixture', 'ProjectDrive C', '{"capacity_gb":100,"role":"project"}'),
    ('fixture-device-storage-d', 'storage', 'temp_drive_d', 'fixture', 'ReservedTempDrive D', '{"capacity_gb":0.5,"role":"temp_reserved"}'),
    ('fixture-device-storage-e', 'storage', 'cache_drive_e', 'fixture', 'CacheDrive E', '{"capacity_gb":1000,"role":"cache"}')
  ON CONFLICT (device_fingerprint) DO UPDATE SET last_seen_at = now()
  RETURNING component_id, device_fingerprint
), components AS (
  SELECT component_id, device_fingerprint FROM upsert_c
  UNION ALL
  SELECT component_id, device_fingerprint FROM hardware_components
  WHERE device_fingerprint IN ('fixture-device-storage-c','fixture-device-storage-d','fixture-device-storage-e')
), upsert_src AS (
  INSERT INTO hardware_sensor_sources (adapter_id, adapter_type, platform, trust_tier, tool_name, tool_version)
  VALUES
    ('fixture_path_probe_v1', 'path_probe', 'windows', 'high', 'fixture_path_probe', '1.0'),
    ('fixture_resource_probe_v1', 'resource_probe', 'windows', 'high', 'fixture_resource_probe', '1.0'),
    ('fixture_npm_resolver_v1', 'toolchain_resolver', 'windows', 'high', 'fixture_npm_resolver', '1.0')
  ON CONFLICT (adapter_id) DO UPDATE SET updated_at = now()
  RETURNING source_id, adapter_id
), sources AS (
  SELECT source_id, adapter_id FROM upsert_src
  UNION ALL
  SELECT source_id, adapter_id FROM hardware_sensor_sources
  WHERE adapter_id IN ('fixture_path_probe_v1','fixture_resource_probe_v1','fixture_npm_resolver_v1')
), obs AS (
  INSERT INTO health_observations (
    trace_id, device_id, workspace_id, component_id, source_id,
    observation_kind, observation_type, path, drive,
    metric_name, metric_value_numeric, metric_value_text, unit,
    source_adapter, raw_payload_ref, confidence_score
  )
  SELECT * FROM (
    VALUES
      ('trc_fixture_npm_enospc_001','dev_nexus_01','ws_system_health',
        (SELECT component_id FROM components WHERE device_fingerprint='fixture-device-storage-c'),
        (SELECT source_id FROM sources WHERE adapter_id='fixture_path_probe_v1'),
        'path_fact','project_path','C:\\Projects\\system_health','C:',
        'project.drive_free_gb',7.2000,NULL,'GB','fixture_path_probe_v1',
        '{"project_path":"C:\\Projects\\system_health","drive":"C:"}'::jsonb,0.990),

      ('trc_fixture_npm_enospc_001','dev_nexus_01','ws_system_health',
        (SELECT component_id FROM components WHERE device_fingerprint='fixture-device-storage-d'),
        (SELECT source_id FROM sources WHERE adapter_id='fixture_npm_resolver_v1'),
        'toolchain_config','effective_npm_cache_path','D:\\Temp\\npm','D:',
        'npm.effective_cache_path',NULL,'D:\\Temp\\npm','path','fixture_npm_resolver_v1',
        '{"effective_cache_path":"D:\\Temp\\npm","source":"env_override:npm_config_cache"}'::jsonb,0.990),

      ('trc_fixture_npm_enospc_001','dev_nexus_01','ws_system_health',
        (SELECT component_id FROM components WHERE device_fingerprint='fixture-device-storage-e'),
        (SELECT source_id FROM sources WHERE adapter_id='fixture_npm_resolver_v1'),
        'toolchain_config','configured_global_npm_cache_path','E:\\npm-cache','E:',
        'npm.global_config_cache_path',NULL,'E:\\npm-cache','path','fixture_npm_resolver_v1',
        '{"configured_global_npm_cache_path":"E:\\npm-cache","source":"global_npmrc"}'::jsonb,0.980),

      ('trc_fixture_npm_enospc_001','dev_nexus_01','ws_system_health',
        (SELECT component_id FROM components WHERE device_fingerprint='fixture-device-storage-d'),
        (SELECT source_id FROM sources WHERE adapter_id='fixture_resource_probe_v1'),
        'resource_fact','drive_free_space','D:\\','D:',
        'drive.free_space_gb',0.0000,NULL,'GB','fixture_resource_probe_v1',
        '{"drive":"D:","free_bytes":0}'::jsonb,1.000),

      ('trc_fixture_npm_enospc_001','dev_nexus_01','ws_system_health',
        (SELECT component_id FROM components WHERE device_fingerprint='fixture-device-storage-e'),
        (SELECT source_id FROM sources WHERE adapter_id='fixture_resource_probe_v1'),
        'resource_fact','drive_free_space','E:\\','E:',
        'drive.free_space_gb',900.0000,NULL,'GB','fixture_resource_probe_v1',
        '{"drive":"E:","free_bytes":966367641600}'::jsonb,1.000),

      ('trc_fixture_npm_enospc_001','dev_nexus_01','ws_system_health',
        NULL,
        (SELECT source_id FROM sources WHERE adapter_id='fixture_npm_resolver_v1'),
        'env_override','npm_config_cache_override',NULL,NULL,
        'env.npm_config_cache',NULL,'D:\\Temp\\npm','path','fixture_npm_resolver_v1',
        '{"env_var":"npm_config_cache","value":"D:\\Temp\\npm"}'::jsonb,0.990)
  ) AS v(
    trace_id, device_id, workspace_id, component_id, source_id,
    observation_kind, observation_type, path, drive,
    metric_name, metric_value_numeric, metric_value_text, unit,
    source_adapter, raw_payload_ref, confidence_score
  )
  WHERE NOT EXISTS (
    SELECT 1 FROM health_observations ho
    WHERE ho.trace_id = 'trc_fixture_npm_enospc_001'
      AND ho.observation_type = v.observation_type
  )
  RETURNING health_observation_id
), diag AS (
  INSERT INTO health_diagnoses (
    trace_id, device_id, workspace_id, primary_diagnosis, secondary_diagnoses,
    symptom, immediate_cause, root_cause, contributing_factors, impact_scope,
    severity, confidence_score, confidence_breakdown, evidence_observation_ids, status
  )
  SELECT
    'trc_fixture_npm_enospc_001',
    'dev_nexus_01',
    'ws_system_health',
    'cache_path_misrouted',
    ARRAY['disk_exhaustion_effective_path'::diagnosis_category, 'env_override_conflict'::diagnosis_category, 'temp_path_misrouted'::diagnosis_category],
    'npm install returned ENOSPC despite adequate overall system capacity',
    'write to D:\\Temp\\npm failed because effective cache path resolved to exhausted drive',
    'npm_config_cache environment override shadowed safer global npm cache configuration',
    '["D drive is tiny reserved partition","alternate approved capacity existed on E drive"]'::jsonb,
    'dependency_install',
    'high',
    0.960,
    '{"config_agreement":0.98,"filesystem_evidence":1.0,"path_consistency":0.95,"freshness":0.99,"verification":0.91}'::jsonb,
    ARRAY(SELECT health_observation_id FROM health_observations WHERE trace_id='trc_fixture_npm_enospc_001'),
    'active'
  WHERE NOT EXISTS (
    SELECT 1 FROM health_diagnoses WHERE trace_id='trc_fixture_npm_enospc_001'
  )
  RETURNING diagnosis_id
), anomaly_seed AS (
  INSERT INTO hardware_anomalies (
    component_id, anomaly_type, severity, metric_name, observed_value, threshold_value,
    supporting_observation_ids, detection_basis, confidence_score, policy_rule_id, diagnosis_id
  )
  SELECT
    (SELECT component_id FROM components WHERE device_fingerprint='fixture-device-storage-d'),
    'disk_exhaustion_effective_path',
    'high',
    'drive.free_space_gb',
    0.0000,
    2.0000,
    ARRAY[]::UUID[],
    'Effective npm cache path resolved to exhausted D: drive while alternate approved capacity existed elsewhere',
    0.970,
    'fixture_rule_disk_exhaustion_effective_path',
    COALESCE((SELECT diagnosis_id FROM diag), (SELECT diagnosis_id FROM health_diagnoses WHERE trace_id='trc_fixture_npm_enospc_001'))
  WHERE NOT EXISTS (
    SELECT 1 FROM hardware_anomalies WHERE diagnosis_id = COALESCE((SELECT diagnosis_id FROM diag), (SELECT diagnosis_id FROM health_diagnoses WHERE trace_id='trc_fixture_npm_enospc_001'))
  )
  RETURNING anomaly_id
), plan AS (
  INSERT INTO health_remediation_plans (
    trace_id, diagnosis_id, device_id, workspace_id, policy_mode, requires_approval,
    estimated_risk, estimated_recovery_probability, confidence_score, plan_steps, reversal_strategy
  )
  SELECT
    'trc_fixture_npm_enospc_001',
    COALESCE((SELECT diagnosis_id FROM diag), (SELECT diagnosis_id FROM health_diagnoses WHERE trace_id='trc_fixture_npm_enospc_001')),
    'dev_nexus_01',
    'ws_system_health',
    'safe_auto_remediate',
    FALSE,
    'low',
    0.940,
    0.930,
    '[
      {"step_id":"step_01","action_type":"record_baseline_snapshot","target_path":"C:\\Projects\\system_health","rationale":"Capture pre-state","risk_level":"low","reversible":true,"approval_requirement":"none"},
      {"step_id":"step_02","action_type":"clean_npm_cache","target_path":"D:\\Temp\\npm","rationale":"Remove exhausted cache artifacts","risk_level":"low","reversible":false,"approval_requirement":"none"},
      {"step_id":"step_03","action_type":"remove_project_node_modules","target_path":"C:\\Projects\\system_health\\node_modules","rationale":"Free install artifacts","risk_level":"medium","reversible":false,"approval_requirement":"none"},
      {"step_id":"step_04","action_type":"rebind_cache_to_approved_path","target_path":"E:\\npm-cache","rationale":"Prefer relocation over destructive cleanup","risk_level":"low","reversible":true,"approval_requirement":"none"},
      {"step_id":"step_05","action_type":"retry_install","target_path":"C:\\Projects\\system_health","rationale":"Verify recovery","risk_level":"low","reversible":false,"approval_requirement":"none"}
    ]'::jsonb,
    '{"restore_env":{"npm_config_cache":"D:\\Temp\\npm"}}'::jsonb
  WHERE NOT EXISTS (
    SELECT 1 FROM health_remediation_plans WHERE trace_id='trc_fixture_npm_enospc_001'
  )
  RETURNING plan_id
), action_1 AS (
  INSERT INTO health_action_events (
    trace_id, plan_id, diagnosis_id, device_id, workspace_id,
    action_type, target, execution_mode, result_status, exit_code,
    started_at, ended_at, command_payload, timeout_sec, idempotency_key
  )
  SELECT
    'trc_fixture_npm_enospc_001',
    COALESCE((SELECT plan_id FROM plan), (SELECT plan_id FROM health_remediation_plans WHERE trace_id='trc_fixture_npm_enospc_001')),
    (SELECT diagnosis_id FROM health_diagnoses WHERE trace_id='trc_fixture_npm_enospc_001'),
    'dev_nexus_01',
    'ws_system_health',
    'rebind_cache_to_approved_path',
    'E:\\npm-cache',
    'auto_safe',
    'success',
    0,
    now(),
    now(),
    '{"env_var":"npm_config_cache","new_value":"E:\\npm-cache"}'::jsonb,
    30,
    'fixture-npm-enospc-step-rebind'
  WHERE NOT EXISTS (
    SELECT 1 FROM health_action_events WHERE idempotency_key='fixture-npm-enospc-step-rebind'
  )
  RETURNING action_event_id
), verify AS (
  INSERT INTO health_verification_results (
    trace_id, plan_id, diagnosis_id, device_id, workspace_id,
    checks, overall_pass, verification_status, confidence_score,
    verification_confidence_breakdown, followup_required, followup_reason
  )
  SELECT
    'trc_fixture_npm_enospc_001',
    COALESCE((SELECT plan_id FROM plan), (SELECT plan_id FROM health_remediation_plans WHERE trace_id='trc_fixture_npm_enospc_001')),
    (SELECT diagnosis_id FROM health_diagnoses WHERE trace_id='trc_fixture_npm_enospc_001'),
    'dev_nexus_01',
    'ws_system_health',
    '[
      {"check":"effective_cache_path != D:\\Temp\\npm","status":"pass"},
      {"check":"effective_cache_path == E:\\npm-cache","status":"pass"},
      {"check":"project_drive_free_space_gb >= 2","status":"pass","observed":7.2},
      {"check":"cache_drive_free_space_gb >= 2","status":"pass","observed":900},
      {"check":"npm_install_exit_code == 0","status":"pass","observed":0}
    ]'::jsonb,
    TRUE,
    'pass',
    0.950,
    '{"config_verification":0.97,"capacity_verification":0.99,"command_verification":0.90}'::jsonb,
    FALSE,
    NULL
  WHERE NOT EXISTS (
    SELECT 1 FROM health_verification_results WHERE trace_id='trc_fixture_npm_enospc_001'
  )
  RETURNING verification_result_id
)
INSERT INTO health_incidents (
  trace_id, title, incident_type, severity, first_seen_at,
  device_id, workspace_id, primary_diagnosis_id, action_event_ids,
  verification_result_id, outcome_ref, status
)
SELECT
  'trc_fixture_npm_enospc_001',
  'npm install ENOSPC despite available overall system capacity',
  'dependency_install_health_failure',
  'high',
  now(),
  'dev_nexus_01',
  'ws_system_health',
  (SELECT diagnosis_id FROM health_diagnoses WHERE trace_id='trc_fixture_npm_enospc_001'),
  ARRAY[(SELECT action_event_id FROM health_action_events WHERE idempotency_key='fixture-npm-enospc-step-rebind')],
  (SELECT verification_result_id FROM health_verification_results WHERE trace_id='trc_fixture_npm_enospc_001'),
  '{"recommended_action":"move_cache_to_approved_drive","verification_passed":true}'::jsonb,
  'resolved'
WHERE NOT EXISTS (
  SELECT 1 FROM health_incidents WHERE trace_id='trc_fixture_npm_enospc_001'
);

COMMIT;

