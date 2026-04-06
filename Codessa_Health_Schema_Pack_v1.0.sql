-- =============================================================================
-- CODESSA HEALTH SCHEMA PACK v1.0
-- Unified canonical schema for:
--   1) Hardware Health Agent (HHA) v0.1
--   2) Codessa Health Adapter / operational diagnosis-remediation lifecycle v1.0
-- Date: 2026-04-06
-- Target: PostgreSQL 15+ (Supabase-compatible)
--
-- Design goals:
-- - migration-safe (IF NOT EXISTS guards where feasible)
-- - Supabase-ready
-- - aligned with existing HHA canonical schema and architecture spec
-- - extends observational/assessment pipeline with diagnosis/remediation/verification CMOs
-- - includes seed fixture for npm ENOSPC misrouted-cache incident
--
-- Notes:
-- - PostgreSQL does not support CREATE TYPE IF NOT EXISTS consistently across all environments,
--   so enum creation is wrapped in DO blocks.
-- - Array refs are used where the canonical design favors evidence chaining over strict join-table normalization.
-- - This pack preserves the HHA ledger convention: every table carries ledger_sequence + subsystem.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- ENUMS
-- =============================================================================

DO $$ BEGIN
  CREATE TYPE component_type AS ENUM (
    'cpu', 'gpu', 'memory', 'storage', 'cooling', 'motherboard', 'power_inferred'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE health_band AS ENUM (
    'excellent', 'good', 'watch', 'degraded', 'critical'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE sampling_mode AS ENUM ('passive', 'active_test');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE operational_mode AS ENUM ('idle', 'active_monitoring', 'diagnostic', 'incident');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE benchmark_type AS ENUM (
    'cpu_stress', 'cpu_benchmark', 'gpu_stress', 'gpu_benchmark',
    'memory_diagnostic', 'storage_benchmark', 'full_system'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE pass_fail_status AS ENUM ('pass', 'fail', 'partial', 'interrupted', 'error');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE anomaly_type AS ENUM (
    'threshold_breach',
    'persistence_anomaly',
    'baseline_deviation',
    'benchmark_underperformance',
    'cooling_under_response',
    'thermal_throttling',
    'cross_signal_contradiction',
    'instability_event',
    'effective_path_low_capacity',
    'configured_vs_effective_path_mismatch',
    'env_override_shadowing',
    'disk_exhaustion_effective_path',
    'tool_cache_reserved_partition',
    'cache_temp_exhausted_colocation',
    'high_growth_cache_low_verification_success'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE severity AS ENUM ('info', 'low', 'medium', 'high', 'critical');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE incident_status AS ENUM ('open', 'monitoring', 'resolved', 'suppressed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE workload_class AS ENUM (
    'light_interactive', 'development', 'embedding_batch',
    'llm_7b', 'llm_14b', 'gpu_heavy', 'stress_diagnostic',
    'local_build', 'dependency_install', 'workspace_repair'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE fit_status AS ENUM ('fit', 'fit_with_constraints', 'not_fit');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE trend_direction AS ENUM ('improving', 'stable', 'degrading', 'volatile');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE adapter_type AS ENUM (
    'os_telemetry', 'sensor', 'benchmark', 'smart', 'event_log',
    'gpu_vendor', 'memory_diag', 'path_probe', 'resource_probe',
    'toolchain_resolver', 'env_probe', 'filesystem_probe', 'temp_probe'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE trust_tier AS ENUM ('high', 'medium', 'low');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE component_status AS ENUM ('active', 'degraded', 'failed', 'replaced', 'unknown');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE diagnosis_status AS ENUM ('active', 'superseded', 'resolved', 'invalidated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE diagnosis_category AS ENUM (
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
    'unknown_health_failure'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE policy_mode AS ENUM (
    'observe_only', 'recommend_only', 'safe_auto_remediate',
    'guarded_auto_remediate', 'halt_and_escalate'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE execution_mode AS ENUM ('dry_run', 'manual_guided', 'auto_safe', 'auto_guarded');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE action_result_status AS ENUM (
    'planned', 'running', 'success', 'partial_success', 'failed', 'rolled_back', 'cancelled', 'skipped'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE artifact_type AS ENUM (
    'before_snapshot', 'after_snapshot', 'diagnosis_report', 'remediation_plan',
    'action_log', 'verification_report', 'install_log', 'incident_summary',
    'raw_stdout', 'raw_stderr', 'config_graph', 'path_graph'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE verification_status AS ENUM ('pass', 'fail', 'partial', 'inconclusive');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE observation_kind AS ENUM (
    'hardware_metric', 'path_fact', 'resource_fact', 'toolchain_config', 'env_override', 'filesystem_test'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- =============================================================================
-- CORE HHA TABLES
-- =============================================================================

CREATE TABLE IF NOT EXISTS hardware_components (
  component_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_fingerprint          TEXT NOT NULL UNIQUE,
  component_type              component_type NOT NULL,
  device_role                 TEXT NOT NULL,
  vendor                      TEXT,
  model                       TEXT,
  serial_number               TEXT,
  firmware_version            TEXT,
  expected_operating_profile  JSONB NOT NULL DEFAULT '{}',
  status                      component_status NOT NULL DEFAULT 'active',
  installed_at                TIMESTAMPTZ,
  discovered_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hardware_components_type ON hardware_components (component_type);
CREATE INDEX IF NOT EXISTS idx_hardware_components_status ON hardware_components (status);

CREATE TABLE IF NOT EXISTS hardware_sensor_sources (
  source_id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  adapter_id                  TEXT NOT NULL UNIQUE,
  adapter_type                adapter_type NOT NULL,
  platform                    TEXT NOT NULL,
  trust_tier                  trust_tier NOT NULL DEFAULT 'medium',
  tool_name                   TEXT,
  tool_version                TEXT,
  is_healthy                  BOOLEAN NOT NULL DEFAULT TRUE,
  last_validated_at           TIMESTAMPTZ,
  degradation_reason          TEXT,
  registered_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sensor_sources_adapter_type ON hardware_sensor_sources (adapter_type);
CREATE INDEX IF NOT EXISTS idx_sensor_sources_trust ON hardware_sensor_sources (trust_tier);

CREATE TABLE IF NOT EXISTS hardware_benchmark_runs (
  benchmark_run_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  benchmark_type              benchmark_type NOT NULL,
  tool_name                   TEXT NOT NULL,
  tool_version                TEXT,
  components_tested           UUID[] NOT NULL,
  test_profile                JSONB NOT NULL DEFAULT '{}',
  status                      TEXT NOT NULL DEFAULT 'running'
                                CHECK (status IN ('running', 'completed', 'failed', 'interrupted', 'cancelled')),
  triggered_by                TEXT NOT NULL DEFAULT 'operator',
  pass_fail_status            pass_fail_status,
  result_summary              JSONB NOT NULL DEFAULT '{}',
  evidence_observation_ids    UUID[] NOT NULL DEFAULT '{}',
  confidence_score            NUMERIC(4,3)
                                CHECK (confidence_score IS NULL OR (confidence_score >= 0 AND confidence_score <= 1)),
  started_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at                    TIMESTAMPTZ,
  duration_sec                INTEGER GENERATED ALWAYS AS (
                                CASE WHEN ended_at IS NULL THEN NULL
                                ELSE EXTRACT(EPOCH FROM (ended_at - started_at))::INTEGER END
                              ) STORED,
  notes                       TEXT,
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'hha'
);

CREATE INDEX IF NOT EXISTS idx_benchmark_type ON hardware_benchmark_runs (benchmark_type);
CREATE INDEX IF NOT EXISTS idx_benchmark_status ON hardware_benchmark_runs (status);
CREATE INDEX IF NOT EXISTS idx_benchmark_started ON hardware_benchmark_runs (started_at DESC);
CREATE INDEX IF NOT EXISTS idx_benchmark_pass_fail ON hardware_benchmark_runs (pass_fail_status);

CREATE TABLE IF NOT EXISTS hardware_observations (
  observation_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  component_id                UUID NOT NULL REFERENCES hardware_components (component_id),
  source_id                   UUID REFERENCES hardware_sensor_sources (source_id),
  benchmark_run_id            UUID REFERENCES hardware_benchmark_runs (benchmark_run_id),
  metric_name                 TEXT NOT NULL,
  metric_value                NUMERIC(12,4) NOT NULL,
  metric_unit                 TEXT NOT NULL,
  sampling_mode               sampling_mode NOT NULL DEFAULT 'passive',
  operational_mode            operational_mode,
  collection_context          JSONB NOT NULL DEFAULT '{}',
  confidence_score            NUMERIC(4,3) NOT NULL CHECK (confidence_score >= 0 AND confidence_score <= 1),
  corroboration_count         SMALLINT NOT NULL DEFAULT 1,
  raw_payload_ref             JSONB,
  observed_at                 TIMESTAMPTZ NOT NULL,
  ingested_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'hha'
);

CREATE INDEX IF NOT EXISTS idx_obs_component_metric ON hardware_observations (component_id, metric_name, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_obs_observed_at ON hardware_observations (observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_obs_metric_name ON hardware_observations (metric_name);
CREATE INDEX IF NOT EXISTS idx_obs_sampling_mode ON hardware_observations (sampling_mode);
CREATE INDEX IF NOT EXISTS idx_obs_confidence ON hardware_observations (confidence_score);
CREATE INDEX IF NOT EXISTS idx_obs_ledger_seq ON hardware_observations (ledger_sequence);

CREATE TABLE IF NOT EXISTS hardware_assessments (
  assessment_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type                TEXT NOT NULL CHECK (subject_type IN ('component', 'system', 'benchmark_run')),
  component_id                UUID REFERENCES hardware_components (component_id),
  benchmark_run_id            UUID REFERENCES hardware_benchmark_runs (benchmark_run_id),
  health_score                NUMERIC(4,3) NOT NULL CHECK (health_score >= 0 AND health_score <= 1),
  thermal_score               NUMERIC(4,3) CHECK (thermal_score IS NULL OR (thermal_score >= 0 AND thermal_score <= 1)),
  stability_score             NUMERIC(4,3) CHECK (stability_score IS NULL OR (stability_score >= 0 AND stability_score <= 1)),
  performance_score           NUMERIC(4,3) CHECK (performance_score IS NULL OR (performance_score >= 0 AND performance_score <= 1)),
  error_score                 NUMERIC(4,3) CHECK (error_score IS NULL OR (error_score >= 0 AND error_score <= 1)),
  trend_score                 NUMERIC(4,3) CHECK (trend_score IS NULL OR (trend_score >= 0 AND trend_score <= 1)),
  health_band                 health_band NOT NULL,
  trend_direction             trend_direction,
  confidence_score            NUMERIC(4,3) NOT NULL CHECK (confidence_score >= 0 AND confidence_score <= 1),
  evidence_observation_ids    UUID[] NOT NULL DEFAULT '{}',
  explanation                 TEXT NOT NULL,
  score_breakdown             JSONB NOT NULL DEFAULT '{}',
  recommended_actions         JSONB NOT NULL DEFAULT '[]',
  assessed_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  assessment_window_start     TIMESTAMPTZ,
  assessment_window_end       TIMESTAMPTZ,
  policy_version              TEXT,
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'hha'
);

CREATE INDEX IF NOT EXISTS idx_assessments_component ON hardware_assessments (component_id, assessed_at DESC);
CREATE INDEX IF NOT EXISTS idx_assessments_system ON hardware_assessments (subject_type, assessed_at DESC);
CREATE INDEX IF NOT EXISTS idx_assessments_health_band ON hardware_assessments (health_band);
CREATE INDEX IF NOT EXISTS idx_assessments_assessed_at ON hardware_assessments (assessed_at DESC);

CREATE TABLE IF NOT EXISTS hardware_incidents (
  incident_id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title                       TEXT NOT NULL,
  description                 TEXT NOT NULL,
  severity                    severity NOT NULL,
  status                      incident_status NOT NULL DEFAULT 'open',
  component_ids               UUID[] NOT NULL,
  anomaly_ids                 UUID[] NOT NULL DEFAULT '{}',
  evidence_observation_ids    UUID[] NOT NULL DEFAULT '{}',
  root_cause_hypothesis       TEXT,
  suspected_causes            JSONB NOT NULL DEFAULT '[]',
  operator_actions_taken      JSONB NOT NULL DEFAULT '[]',
  resolution_notes            TEXT,
  maintenance_event_ids       UUID[] NOT NULL DEFAULT '{}',
  primary_diagnosis_id        UUID,
  verification_result_id      UUID,
  remediation_plan_ids        UUID[] NOT NULL DEFAULT '{}',
  opened_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_activity_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at                 TIMESTAMPTZ,
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'hha'
);

CREATE INDEX IF NOT EXISTS idx_incidents_status ON hardware_incidents (status);
CREATE INDEX IF NOT EXISTS idx_incidents_severity ON hardware_incidents (severity);
CREATE INDEX IF NOT EXISTS idx_incidents_opened ON hardware_incidents (opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_incidents_open ON hardware_incidents (status, opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_incidents_components ON hardware_incidents USING GIN (component_ids);

CREATE TABLE IF NOT EXISTS hardware_anomalies (
  anomaly_id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  component_id                UUID NOT NULL REFERENCES hardware_components (component_id),
  anomaly_type                anomaly_type NOT NULL,
  severity                    severity NOT NULL,
  metric_name                 TEXT,
  observed_value              NUMERIC(12,4),
  threshold_value             NUMERIC(12,4),
  baseline_value              NUMERIC(12,4),
  deviation_pct               NUMERIC(7,2),
  supporting_observation_ids  UUID[] NOT NULL DEFAULT '{}',
  first_detected_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_observed_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  detection_sample_count      INTEGER NOT NULL DEFAULT 1,
  is_persistent               BOOLEAN NOT NULL DEFAULT FALSE,
  is_resolved                 BOOLEAN NOT NULL DEFAULT FALSE,
  resolved_at                 TIMESTAMPTZ,
  suspected_causes            JSONB NOT NULL DEFAULT '[]',
  detection_basis             TEXT NOT NULL,
  confidence_score            NUMERIC(4,3) NOT NULL CHECK (confidence_score >= 0 AND confidence_score <= 1),
  incident_id                 UUID REFERENCES hardware_incidents (incident_id),
  diagnosis_id                UUID,
  detected_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  policy_rule_id              TEXT,
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'hha'
);

CREATE INDEX IF NOT EXISTS idx_anomalies_component ON hardware_anomalies (component_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_anomalies_type ON hardware_anomalies (anomaly_type);
CREATE INDEX IF NOT EXISTS idx_anomalies_severity ON hardware_anomalies (severity);
CREATE INDEX IF NOT EXISTS idx_anomalies_persistent ON hardware_anomalies (is_persistent) WHERE is_persistent = TRUE;
CREATE INDEX IF NOT EXISTS idx_anomalies_unresolved ON hardware_anomalies (is_resolved, detected_at DESC) WHERE is_resolved = FALSE;
CREATE INDEX IF NOT EXISTS idx_anomalies_incident ON hardware_anomalies (incident_id) WHERE incident_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS hardware_maintenance_events (
  maintenance_event_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  component_ids               UUID[] NOT NULL,
  incident_ids                UUID[] NOT NULL DEFAULT '{}',
  maintenance_type            TEXT NOT NULL,
  description                 TEXT NOT NULL,
  pre_maintenance_assessment_id  UUID REFERENCES hardware_assessments (assessment_id),
  post_maintenance_assessment_id UUID REFERENCES hardware_assessments (assessment_id),
  health_delta                NUMERIC(4,3),
  performed_by                TEXT NOT NULL DEFAULT 'operator',
  tools_used                  TEXT[],
  parts_replaced              JSONB NOT NULL DEFAULT '[]',
  notes                       TEXT,
  performed_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  recorded_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'hha'
);

CREATE INDEX IF NOT EXISTS idx_maintenance_components ON hardware_maintenance_events USING GIN (component_ids);
CREATE INDEX IF NOT EXISTS idx_maintenance_performed ON hardware_maintenance_events (performed_at DESC);
CREATE INDEX IF NOT EXISTS idx_maintenance_type ON hardware_maintenance_events (maintenance_type);

CREATE TABLE IF NOT EXISTS hardware_workload_fitness_profiles (
  profile_id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workload_class              workload_class NOT NULL,
  fit_status                  fit_status NOT NULL,
  system_assessment_id        UUID REFERENCES hardware_assessments (assessment_id),
  component_assessment_ids    JSONB NOT NULL DEFAULT '{}',
  open_incident_ids           UUID[] NOT NULL DEFAULT '{}',
  constraints                 JSONB NOT NULL DEFAULT '[]',
  blocking_factors            JSONB NOT NULL DEFAULT '[]',
  health_blockers             JSONB NOT NULL DEFAULT '[]',
  reasoning_summary           TEXT NOT NULL,
  confidence_score            NUMERIC(4,3) NOT NULL CHECK (confidence_score >= 0 AND confidence_score <= 1),
  assessed_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at                  TIMESTAMPTZ NOT NULL,
  policy_version              TEXT,
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'hha'
);

CREATE INDEX IF NOT EXISTS idx_fitness_workload ON hardware_workload_fitness_profiles (workload_class, assessed_at DESC);
CREATE INDEX IF NOT EXISTS idx_fitness_status ON hardware_workload_fitness_profiles (fit_status);
CREATE INDEX IF NOT EXISTS idx_fitness_recent ON hardware_workload_fitness_profiles (workload_class, expires_at DESC);

CREATE TABLE IF NOT EXISTS hardware_baselines (
  baseline_id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  component_id                UUID NOT NULL REFERENCES hardware_components (component_id),
  baseline_type               TEXT NOT NULL CHECK (baseline_type IN ('idle', 'load', 'benchmark', 'thermal_stabilization')),
  metrics                     JSONB NOT NULL,
  sample_count                INTEGER NOT NULL,
  sample_window_days          INTEGER NOT NULL,
  is_current                  BOOLEAN NOT NULL DEFAULT TRUE,
  superseded_by               UUID REFERENCES hardware_baselines (baseline_id),
  established_after_maintenance_event_id UUID REFERENCES hardware_maintenance_events (maintenance_event_id),
  established_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  window_start                TIMESTAMPTZ NOT NULL,
  window_end                  TIMESTAMPTZ NOT NULL,
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'hha'
);

CREATE INDEX IF NOT EXISTS idx_baselines_component ON hardware_baselines (component_id, baseline_type);
CREATE INDEX IF NOT EXISTS idx_baselines_current ON hardware_baselines (component_id, is_current) WHERE is_current = TRUE;

CREATE TABLE IF NOT EXISTS hardware_policy_profiles (
  policy_id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_version              TEXT NOT NULL UNIQUE,
  policy_config               JSONB NOT NULL,
  description                 TEXT,
  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  activated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  deactivated_at              TIMESTAMPTZ,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_policy_active ON hardware_policy_profiles (is_active) WHERE is_active = TRUE;

-- =============================================================================
-- HEALTH ADAPTER / OPERATIONAL CMO TABLES
-- =============================================================================

CREATE TABLE IF NOT EXISTS health_artifacts (
  artifact_id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id                    TEXT NOT NULL,
  artifact_type               artifact_type NOT NULL,
  title                       TEXT,
  format                      TEXT NOT NULL DEFAULT 'json',
  storage_ref                 TEXT,
  content_json                JSONB,
  content_text                TEXT,
  checksum_sha256             TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'health_adapter'
);

CREATE INDEX IF NOT EXISTS idx_health_artifacts_trace ON health_artifacts (trace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_artifacts_type ON health_artifacts (artifact_type);

CREATE TABLE IF NOT EXISTS health_observations (
  health_observation_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id                    TEXT NOT NULL,
  device_id                   TEXT NOT NULL,
  workspace_id                TEXT,
  component_id                UUID REFERENCES hardware_components (component_id),
  source_id                   UUID REFERENCES hardware_sensor_sources (source_id),
  observation_kind            observation_kind NOT NULL,
  observation_type            TEXT NOT NULL,
  path                        TEXT,
  drive                       TEXT,
  metric_name                 TEXT,
  metric_value_numeric        NUMERIC(18,4),
  metric_value_text           TEXT,
  unit                        TEXT,
  source_adapter              TEXT,
  evidence_artifact_ids       UUID[] NOT NULL DEFAULT '{}',
  evidence_refs               JSONB NOT NULL DEFAULT '[]',
  raw_payload_ref             JSONB,
  observed_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  confidence_score            NUMERIC(4,3) CHECK (confidence_score IS NULL OR (confidence_score >= 0 AND confidence_score <= 1)),
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'health_adapter'
);

CREATE INDEX IF NOT EXISTS idx_health_observations_trace ON health_observations (trace_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_observations_device_ws ON health_observations (device_id, workspace_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_observations_type ON health_observations (observation_type);
CREATE INDEX IF NOT EXISTS idx_health_observations_path ON health_observations (path);

CREATE TABLE IF NOT EXISTS health_diagnoses (
  diagnosis_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id                    TEXT NOT NULL,
  device_id                   TEXT NOT NULL,
  workspace_id                TEXT,
  primary_diagnosis           diagnosis_category NOT NULL,
  secondary_diagnoses         diagnosis_category[] NOT NULL DEFAULT '{}',
  symptom                     TEXT NOT NULL,
  immediate_cause             TEXT,
  root_cause                  TEXT,
  contributing_factors        JSONB NOT NULL DEFAULT '[]',
  impact_scope                TEXT,
  severity                    severity NOT NULL,
  confidence_score            NUMERIC(4,3) NOT NULL CHECK (confidence_score >= 0 AND confidence_score <= 1),
  confidence_breakdown        JSONB NOT NULL DEFAULT '{}',
  related_anomaly_ids         UUID[] NOT NULL DEFAULT '{}',
  evidence_observation_ids    UUID[] NOT NULL DEFAULT '{}',
  status                      diagnosis_status NOT NULL DEFAULT 'active',
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at                 TIMESTAMPTZ,
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'health_adapter'
);

CREATE INDEX IF NOT EXISTS idx_health_diagnoses_trace ON health_diagnoses (trace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_diagnoses_primary ON health_diagnoses (primary_diagnosis);
CREATE INDEX IF NOT EXISTS idx_health_diagnoses_status ON health_diagnoses (status);
CREATE INDEX IF NOT EXISTS idx_health_diagnoses_device_ws ON health_diagnoses (device_id, workspace_id, created_at DESC);

CREATE TABLE IF NOT EXISTS health_remediation_plans (
  plan_id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id                    TEXT NOT NULL,
  diagnosis_id                UUID REFERENCES health_diagnoses (diagnosis_id),
  device_id                   TEXT NOT NULL,
  workspace_id                TEXT,
  policy_mode                 policy_mode NOT NULL,
  requires_approval           BOOLEAN NOT NULL DEFAULT TRUE,
  estimated_risk              severity,
  estimated_recovery_probability NUMERIC(4,3) CHECK (estimated_recovery_probability IS NULL OR (estimated_recovery_probability >= 0 AND estimated_recovery_probability <= 1)),
  confidence_score            NUMERIC(4,3) CHECK (confidence_score IS NULL OR (confidence_score >= 0 AND confidence_score <= 1)),
  plan_steps                  JSONB NOT NULL,
  reversal_strategy           JSONB NOT NULL DEFAULT '{}',
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_at                 TIMESTAMPTZ,
  approved_by                 TEXT,
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'health_adapter'
);

CREATE INDEX IF NOT EXISTS idx_health_plans_trace ON health_remediation_plans (trace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_plans_diagnosis ON health_remediation_plans (diagnosis_id);
CREATE INDEX IF NOT EXISTS idx_health_plans_policy_mode ON health_remediation_plans (policy_mode);

CREATE TABLE IF NOT EXISTS health_action_events (
  action_event_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id                    TEXT NOT NULL,
  plan_id                     UUID REFERENCES health_remediation_plans (plan_id),
  diagnosis_id                UUID REFERENCES health_diagnoses (diagnosis_id),
  device_id                   TEXT NOT NULL,
  workspace_id                TEXT,
  action_type                 TEXT NOT NULL,
  target                      TEXT,
  execution_mode              execution_mode NOT NULL DEFAULT 'dry_run',
  result_status               action_result_status NOT NULL DEFAULT 'planned',
  exit_code                   INTEGER,
  started_at                  TIMESTAMPTZ,
  ended_at                    TIMESTAMPTZ,
  stdout_artifact_id          UUID REFERENCES health_artifacts (artifact_id),
  stderr_artifact_id          UUID REFERENCES health_artifacts (artifact_id),
  artifact_ids                UUID[] NOT NULL DEFAULT '{}',
  command_payload             JSONB NOT NULL DEFAULT '{}',
  rollback_metadata           JSONB NOT NULL DEFAULT '{}',
  timeout_sec                 INTEGER,
  idempotency_key             TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'health_adapter'
);

CREATE INDEX IF NOT EXISTS idx_health_actions_trace ON health_action_events (trace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_actions_plan ON health_action_events (plan_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_actions_result ON health_action_events (result_status);
CREATE INDEX IF NOT EXISTS idx_health_actions_idempotency ON health_action_events (idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS health_verification_results (
  verification_result_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id                    TEXT NOT NULL,
  plan_id                     UUID REFERENCES health_remediation_plans (plan_id),
  diagnosis_id                UUID REFERENCES health_diagnoses (diagnosis_id),
  device_id                   TEXT NOT NULL,
  workspace_id                TEXT,
  checks                      JSONB NOT NULL,
  overall_pass                BOOLEAN NOT NULL,
  verification_status         verification_status NOT NULL,
  confidence_score            NUMERIC(4,3) CHECK (confidence_score IS NULL OR (confidence_score >= 0 AND confidence_score <= 1)),
  verification_confidence_breakdown JSONB NOT NULL DEFAULT '{}',
  followup_required           BOOLEAN NOT NULL DEFAULT FALSE,
  followup_reason             TEXT,
  verified_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'health_adapter'
);

CREATE INDEX IF NOT EXISTS idx_health_verification_trace ON health_verification_results (trace_id, verified_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_verification_plan ON health_verification_results (plan_id);
CREATE INDEX IF NOT EXISTS idx_health_verification_overall ON health_verification_results (overall_pass, verified_at DESC);

CREATE TABLE IF NOT EXISTS health_incidents (
  health_incident_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id                    TEXT NOT NULL,
  title                       TEXT NOT NULL,
  incident_type               TEXT NOT NULL,
  severity                    severity NOT NULL,
  first_seen_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at                 TIMESTAMPTZ,
  device_id                   TEXT NOT NULL,
  workspace_id                TEXT,
  primary_diagnosis_id        UUID REFERENCES health_diagnoses (diagnosis_id),
  action_event_ids            UUID[] NOT NULL DEFAULT '{}',
  verification_result_id      UUID REFERENCES health_verification_results (verification_result_id),
  outcome_ref                 JSONB NOT NULL DEFAULT '{}',
  status                      incident_status NOT NULL DEFAULT 'open',
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'health_adapter'
);

CREATE INDEX IF NOT EXISTS idx_health_incidents_trace ON health_incidents (trace_id, first_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_incidents_status ON health_incidents (status, first_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_incidents_device_ws ON health_incidents (device_id, workspace_id, first_seen_at DESC);

CREATE TABLE IF NOT EXISTS device_health_fitness_profiles (
  device_fitness_profile_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id                   TEXT NOT NULL,
  workspace_id                TEXT,
  storage_fitness             fit_status NOT NULL,
  temp_path_fitness           fit_status NOT NULL,
  cache_path_fitness          fit_status NOT NULL,
  install_fitness             fit_status NOT NULL,
  workspace_headroom_fitness  fit_status NOT NULL,
  overall_fitness             fit_status NOT NULL,
  blocking_conditions         JSONB NOT NULL DEFAULT '[]',
  contributing_diagnosis_ids  UUID[] NOT NULL DEFAULT '{}',
  stale_after                 TIMESTAMPTZ NOT NULL,
  confidence_score            NUMERIC(4,3) NOT NULL CHECK (confidence_score >= 0 AND confidence_score <= 1),
  assessed_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  policy_version              TEXT,
  ledger_sequence             BIGSERIAL,
  subsystem                   TEXT NOT NULL DEFAULT 'health_adapter'
);

CREATE INDEX IF NOT EXISTS idx_device_fitness_device_ws ON device_health_fitness_profiles (device_id, workspace_id, assessed_at DESC);
CREATE INDEX IF NOT EXISTS idx_device_fitness_overall ON device_health_fitness_profiles (overall_fitness, assessed_at DESC);

-- =============================================================================
-- FORWARD FKs AFTER HEALTH TABLES EXIST
-- =============================================================================

DO $$ BEGIN
  ALTER TABLE hardware_incidents
    ADD CONSTRAINT fk_hardware_incidents_primary_diagnosis
    FOREIGN KEY (primary_diagnosis_id) REFERENCES health_diagnoses (diagnosis_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE hardware_incidents
    ADD CONSTRAINT fk_hardware_incidents_verification
    FOREIGN KEY (verification_result_id) REFERENCES health_verification_results (verification_result_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE hardware_anomalies
    ADD CONSTRAINT fk_hardware_anomalies_diagnosis
    FOREIGN KEY (diagnosis_id) REFERENCES health_diagnoses (diagnosis_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- =============================================================================
-- UTILITY VIEWS
-- =============================================================================

CREATE OR REPLACE VIEW vw_current_system_health AS
SELECT
  a.assessment_id,
  a.health_score,
  a.health_band,
  a.trend_direction,
  a.confidence_score,
  a.explanation,
  a.recommended_actions,
  a.assessed_at
FROM hardware_assessments a
WHERE a.subject_type = 'system'
ORDER BY a.assessed_at DESC
LIMIT 1;

CREATE OR REPLACE VIEW vw_current_component_health AS
SELECT DISTINCT ON (a.component_id)
  c.component_id,
  c.component_type,
  c.device_role,
  c.vendor,
  c.model,
  a.health_score,
  a.health_band,
  a.thermal_score,
  a.stability_score,
  a.performance_score,
  a.trend_direction,
  a.confidence_score,
  a.explanation,
  a.assessed_at
FROM hardware_assessments a
JOIN hardware_components c ON c.component_id = a.component_id
WHERE a.subject_type = 'component'
ORDER BY a.component_id, a.assessed_at DESC;

CREATE OR REPLACE VIEW vw_open_incidents AS
SELECT
  i.incident_id,
  i.title,
  i.severity,
  i.status,
  i.component_ids,
  i.root_cause_hypothesis,
  i.opened_at,
  i.last_activity_at,
  EXTRACT(EPOCH FROM (now() - i.opened_at))/3600 AS open_hours
FROM hardware_incidents i
WHERE i.status IN ('open', 'monitoring')
ORDER BY
  CASE i.severity
    WHEN 'critical' THEN 1
    WHEN 'high' THEN 2
    WHEN 'medium' THEN 3
    WHEN 'low' THEN 4
    ELSE 5
  END,
  i.opened_at ASC;

CREATE OR REPLACE VIEW vw_current_workload_fitness AS
SELECT DISTINCT ON (f.workload_class)
  f.profile_id,
  f.workload_class,
  f.fit_status,
  f.constraints,
  f.blocking_factors,
  f.health_blockers,
  f.reasoning_summary,
  f.confidence_score,
  f.assessed_at,
  f.expires_at,
  (f.expires_at < now()) AS is_stale
FROM hardware_workload_fitness_profiles f
ORDER BY f.workload_class, f.assessed_at DESC;

CREATE OR REPLACE VIEW vw_recent_benchmarks AS
SELECT
  benchmark_run_id,
  benchmark_type,
  tool_name,
  status,
  pass_fail_status,
  components_tested,
  started_at,
  ended_at,
  duration_sec,
  confidence_score,
  result_summary
FROM hardware_benchmark_runs
ORDER BY started_at DESC
LIMIT 50;

CREATE OR REPLACE VIEW vw_current_device_health_fitness AS
SELECT DISTINCT ON (d.device_id, COALESCE(d.workspace_id, ''))
  d.device_fitness_profile_id,
  d.device_id,
  d.workspace_id,
  d.storage_fitness,
  d.temp_path_fitness,
  d.cache_path_fitness,
  d.install_fitness,
  d.workspace_headroom_fitness,
  d.overall_fitness,
  d.blocking_conditions,
  d.contributing_diagnosis_ids,
  d.confidence_score,
  d.assessed_at,
  d.stale_after,
  (d.stale_after < now()) AS is_stale
FROM device_health_fitness_profiles d
ORDER BY d.device_id, COALESCE(d.workspace_id, ''), d.assessed_at DESC;

CREATE OR REPLACE VIEW vw_active_health_incidents AS
SELECT
  hi.health_incident_id,
  hi.trace_id,
  hi.title,
  hi.incident_type,
  hi.severity,
  hi.status,
  hi.device_id,
  hi.workspace_id,
  hi.first_seen_at,
  hi.primary_diagnosis_id,
  hd.primary_diagnosis,
  hd.root_cause,
  hi.verification_result_id
FROM health_incidents hi
LEFT JOIN health_diagnoses hd ON hd.diagnosis_id = hi.primary_diagnosis_id
WHERE hi.status IN ('open', 'monitoring')
ORDER BY hi.first_seen_at DESC;

CREATE OR REPLACE VIEW vw_latest_health_diagnosis_per_trace AS
SELECT DISTINCT ON (trace_id)
  diagnosis_id,
  trace_id,
  device_id,
  workspace_id,
  primary_diagnosis,
  secondary_diagnoses,
  severity,
  confidence_score,
  status,
  created_at
FROM health_diagnoses
ORDER BY trace_id, created_at DESC;

-- =============================================================================
-- SCHEMA VERSION TRACKING
-- =============================================================================

CREATE TABLE IF NOT EXISTS hha_schema_versions (
  version                     TEXT PRIMARY KEY,
  applied_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  description                 TEXT
);

INSERT INTO hha_schema_versions (version, description)
VALUES
  ('0.1.0', 'Original HHA canonical schema baseline'),
  ('1.0.0', 'Unified Codessa Health Schema Pack with Health Adapter CMOs and incident seed fixture')
ON CONFLICT (version) DO NOTHING;

-- =============================================================================
-- SEED FIXTURE: npm ENOSPC misrouted cache incident
-- Idempotent-ish seed using stable fingerprints and deterministic values.
-- =============================================================================

-- Components
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
