-- =============================================================================
-- CODESSA HEALTH CMO SCHEMA PACK v1.0
-- Health Adapter + Environment Audit Layer
-- Date: April 6, 2026
-- Status: Migration-ready, Supabase/PostgreSQL 15+
-- Depends on: HHA_Canonical_Schema_v0.1.sql (must be applied first)
-- =============================================================================
--
-- MIGRATION STRATEGY:
--   This file is additive. It does NOT modify or drop any table from v0.1.
--   It extends the HHA schema with:
--     A. Health Adapter CMOs (diagnosis, remediation, execution, verification, incidents)
--     B. Config Conflict Resolution CMOs
--     C. Environment Audit Layer CMOs
--     D. Extensions to existing HHA tables (ALTER TABLE only)
--     E. Views for Mission Control and XHive projection surfaces
--     F. Gold test fixture for npm ENOSPC reference incident
--
-- SUBSYSTEM TAG: All new tables use subsystem = 'ha' (Health Adapter)
--               Environment Audit tables use subsystem = 'ea'
--               Original HHA tables retain subsystem = 'hha'
--
-- FIELD CLASSIFICATION (Codessa SSFIL standard):
--   SOV  = Sovereign / immutable identity
--   ECL  = Epistemic Confidence Layer field
--   AUD  = Audit / provenance
--   STD  = Standard operational field
-- =============================================================================


-- =============================================================================
-- SECTION A: ENUM ADDITIONS
-- =============================================================================

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
  'config_persistence_conflict',
  'env_override_reinjection',
  'config_shadowing_persistent',
  'config_source_ambiguity',
  'unsafe_cleanup_required',
  'headroom_below_policy',
  'unknown_health_failure',
  -- Environment Audit additions
  'environment_scope_conflict',
  'runtime_missing_from_path',
  'declared_runtime_unavailable',
  'path_shadowing_high_risk',
  'process_env_stale_after_persistent_fix',
  'restart_required_for_env_convergence',
  'temp_route_reserved_partition',
  'cwd_assumption_invalid',
  'tool_launcher_misresolved',
  'declared_effective_env_mismatch'
);

CREATE TYPE execution_mode AS ENUM (
  'observe_only',
  'diagnose_only',
  'plan_only',
  'diagnose_and_plan',
  'diagnose_and_remediate_safe',
  'diagnose_and_remediate_guarded',
  'execute_approved_plan',
  'verify_only',
  'fitness_only'
);

CREATE TYPE policy_mode AS ENUM (
  'observe_only',
  'recommend_only',
  'safe_auto_remediate',
  'guarded_auto_remediate',
  'halt_and_escalate'
);

CREATE TYPE action_type AS ENUM (
  'capture_snapshot',
  'clean_tool_cache',
  'remove_node_modules',
  'remove_lockfile',
  'prune_temp_directory',
  'rebind_cache_path',
  'rebind_temp_path',
  'set_env_var_user',
  'set_env_var_machine',
  'clear_env_var_user',
  'clear_env_var_machine',
  'rewrite_tool_config',
  'run_target_command',
  'verify_thresholds',
  'restart_required_flag',
  'install_runtime',
  'expose_runtime_to_path',
  'capture_env_snapshot',
  'other'
);

CREATE TYPE action_risk AS ENUM (
  'low',
  'medium',
  'high'
);

CREATE TYPE verification_status AS ENUM (
  'not_required',
  'required',
  'pending',
  'passed',
  'failed',
  'stale'
);

CREATE TYPE recoverability AS ENUM (
  'fully_recoverable',
  'recoverable_with_safe_actions',
  'recoverable_with_guarded_actions',
  'requires_operator_intervention',
  'not_recoverable_in_scope'
);

CREATE TYPE ha_incident_status AS ENUM (
  'open',
  'remediating',
  'verifying',
  'resolved',
  'escalated',
  'suppressed'
);

CREATE TYPE toolchain AS ENUM (
  'npm',
  'pnpm',
  'yarn',
  'pip',
  'uv',
  'cargo',
  'docker_build',
  'java_maven',
  'java_gradle',
  'dotnet',
  'general'
);

CREATE TYPE env_scope AS ENUM (
  'process',
  'user',
  'machine',
  'shell_profile',
  'tool_config',
  'app_launch_context'
);

CREATE TYPE conflict_type AS ENUM (
  'scope_conflict_process_user',
  'scope_conflict_user_machine',
  'config_shadowing',
  'path_shadowing',
  'env_override_reinjection',
  'declared_effective_mismatch',
  'runtime_missing_from_path',
  'temp_route_unsafe',
  'duplicate_conflicting_runtime'
);

CREATE TYPE command_resolution_status AS ENUM (
  'resolved',
  'not_found',
  'ambiguous',
  'spawn_failed',
  'access_denied',
  'version_mismatch'
);


-- =============================================================================
-- SECTION B: HEALTH ADAPTER CMOs
-- =============================================================================

-- =============================================================================
-- TABLE: ha_traces
-- Canonical trace correlation record for every Health Adapter run.
-- All downstream CMOs reference trace_id → this table.
-- =============================================================================

CREATE TABLE ha_traces (
  -- SOV
  trace_id              TEXT          PRIMARY KEY,              -- 'trc_<nanoid>' or caller-provided
  request_id            TEXT          NOT NULL,

  -- STD: Context
  device_id             TEXT          NOT NULL,
  workspace_id          TEXT,
  actor_id              TEXT,
  actor_type            TEXT,

  -- STD: Target
  toolchain             toolchain,
  operation             TEXT,                                   -- 'install', 'build', 'test', etc.
  symptom               TEXT,                                   -- reported symptom string

  -- STD: Execution
  execution_mode        execution_mode NOT NULL,
  policy_mode           policy_mode   NOT NULL DEFAULT 'recommend_only',

  -- STD: Outcome
  final_status          TEXT          NOT NULL DEFAULT 'pending'
                        CHECK (final_status IN ('pending', 'completed', 'completed_with_warnings', 'partial', 'failed', 'denied')),
  adapter_runtime_ms    INTEGER,

  -- AUD
  started_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
  completed_at          TIMESTAMPTZ,
  contract_version      TEXT          NOT NULL DEFAULT '1.0',

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_traces IS 'Canonical trace correlation records. Every Health Adapter CMO references a trace_id. One trace per diagnosis/remediation session.';

CREATE INDEX idx_ha_traces_device ON ha_traces (device_id, started_at DESC);
CREATE INDEX idx_ha_traces_status ON ha_traces (final_status);
CREATE INDEX idx_ha_traces_toolchain ON ha_traces (toolchain);


-- =============================================================================
-- TABLE: ha_health_observations
-- Raw measured facts from Health Adapter probes.
-- Distinct from hardware_observations — these are path/config/env facts.
-- =============================================================================

CREATE TABLE ha_health_observations (
  -- SOV
  observation_id        UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          NOT NULL REFERENCES ha_traces (trace_id),

  -- STD: Probe source
  source_adapter        TEXT          NOT NULL,                 -- 'path_probe', 'resource_probe', 'toolchain_resolver', etc.
  observation_type      TEXT          NOT NULL,                 -- 'path_fact', 'capacity_fact', 'config_fact', 'env_fact'

  -- STD: Payload
  path                  TEXT,                                   -- filesystem path if applicable
  drive                 TEXT,                                   -- drive letter or mount point
  metric_name           TEXT          NOT NULL,                 -- canonical fact name
  metric_value          TEXT          NOT NULL,                 -- string-serialized value (path, number, bool, JSON)
  metric_unit           TEXT,                                   -- 'bytes', 'path', 'boolean', 'string', 'json'

  -- STD: Context
  device_id             TEXT          NOT NULL,
  workspace_id          TEXT,
  toolchain             toolchain,

  -- ECL
  confidence_score      NUMERIC(4,3)  NOT NULL DEFAULT 1.0
                        CHECK (confidence_score >= 0 AND confidence_score <= 1),

  -- AUD
  observed_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
  raw_evidence_ref      JSONB,                                  -- raw probe output for audit

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_health_observations IS 'Raw measured facts from Health Adapter probes. Covers path resolution, capacity, config resolution, and environment state. Distinct from hardware_observations which covers sensor telemetry.';
COMMENT ON COLUMN ha_health_observations.metric_name IS 'Canonical fact names: effective_cache_path, project_drive_free_bytes, effective_temp_path, npm_config_source, path_mismatch_detected, etc.';

CREATE INDEX idx_ha_obs_trace ON ha_health_observations (trace_id);
CREATE INDEX idx_ha_obs_device ON ha_health_observations (device_id, observed_at DESC);
CREATE INDEX idx_ha_obs_metric ON ha_health_observations (metric_name);


-- =============================================================================
-- TABLE: ha_health_diagnoses
-- Normalized structured conclusions about failure state.
-- One primary diagnosis per trace; secondary diagnoses in array.
-- =============================================================================

CREATE TABLE ha_health_diagnoses (
  -- SOV
  diagnosis_id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          NOT NULL REFERENCES ha_traces (trace_id),

  -- STD: Classification
  primary_diagnosis     diagnosis_category NOT NULL,
  secondary_diagnoses   diagnosis_category[] NOT NULL DEFAULT '{}',

  -- STD: Causality chain
  symptom               TEXT          NOT NULL,
  immediate_cause       TEXT,
  root_cause            TEXT,
  contributing_factors  JSONB         NOT NULL DEFAULT '[]',    -- array of strings
  impact_scope          TEXT,                                   -- 'local_dependency_install', 'build_local', etc.

  -- STD: Severity + recoverability
  severity              severity      NOT NULL,
  recoverability        recoverability NOT NULL DEFAULT 'recoverable_with_safe_actions',

  -- STD: Recommended next action
  recommended_next_action TEXT,                                 -- 'plan_safe_remediation', 'escalate_to_operator', etc.

  -- ECL
  confidence_score      NUMERIC(4,3)  NOT NULL
                        CHECK (confidence_score >= 0 AND confidence_score <= 1),
  evidence_observation_ids UUID[]     NOT NULL DEFAULT '{}',    -- ha_health_observations IDs

  -- STD: Status
  status                TEXT          NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'superseded', 'resolved', 'invalid')),

  -- AUD
  diagnosed_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  policy_version        TEXT,

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_health_diagnoses IS 'Normalized failure diagnoses from the Diagnosis Engine. Structured causality chain: symptom → immediate cause → root cause. Primary input to remediation planning.';
COMMENT ON COLUMN ha_health_diagnoses.contributing_factors IS 'JSON array of causal strings. Example: ["effective cache path on D: reserved partition", "env var shadows global config", "D: free space below threshold"].';

CREATE INDEX idx_ha_diag_trace ON ha_health_diagnoses (trace_id);
CREATE INDEX idx_ha_diag_primary ON ha_health_diagnoses (primary_diagnosis);
CREATE INDEX idx_ha_diag_severity ON ha_health_diagnoses (severity);
CREATE INDEX idx_ha_diag_active ON ha_health_diagnoses (status) WHERE status = 'active';


-- =============================================================================
-- TABLE: ha_remediation_plans
-- Ordered, policy-checked remediation plans.
-- Plans are generated before execution and may be approved or rejected.
-- =============================================================================

CREATE TABLE ha_remediation_plans (
  -- SOV
  plan_id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          NOT NULL REFERENCES ha_traces (trace_id),
  diagnosis_id          UUID          REFERENCES ha_health_diagnoses (diagnosis_id),

  -- STD: Policy
  policy_mode           policy_mode   NOT NULL,
  requires_approval     BOOLEAN       NOT NULL DEFAULT TRUE,

  -- STD: Plan content
  plan_steps            JSONB         NOT NULL,                 -- ordered array of step objects
  approved_target_roots TEXT[]        NOT NULL DEFAULT '{}',    -- filesystem roots approved for mutation

  -- STD: Risk estimate
  estimated_risk        action_risk   NOT NULL DEFAULT 'low',
  estimated_recovery_probability NUMERIC(4,3)
                        CHECK (estimated_recovery_probability IS NULL OR (estimated_recovery_probability >= 0 AND estimated_recovery_probability <= 1)),

  -- STD: Lifecycle
  plan_status           TEXT          NOT NULL DEFAULT 'generated'
                        CHECK (plan_status IN ('generated', 'approved', 'executing', 'completed', 'failed', 'cancelled', 'superseded')),
  approved_at           TIMESTAMPTZ,
  approved_by           TEXT,

  -- ECL
  confidence_score      NUMERIC(4,3)
                        CHECK (confidence_score IS NULL OR (confidence_score >= 0 AND confidence_score <= 1)),

  -- AUD
  generated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_remediation_plans IS 'Ordered remediation plans generated by the Remediation Planner. Each step is policy-checked. Plans may be approved, executed, and referenced by action events.';
COMMENT ON COLUMN ha_remediation_plans.plan_steps IS 'JSON array of step objects: [{step_id, action_type, target, rationale, risk, reversible, approval_required, estimated_freed_bytes, verification_check}].';

CREATE INDEX idx_ha_plan_trace ON ha_remediation_plans (trace_id);
CREATE INDEX idx_ha_plan_diagnosis ON ha_remediation_plans (diagnosis_id);
CREATE INDEX idx_ha_plan_status ON ha_remediation_plans (plan_status);


-- =============================================================================
-- TABLE: ha_action_events
-- Individual executed remediation steps.
-- One row per step execution. Immutable audit records.
-- =============================================================================

CREATE TABLE ha_action_events (
  -- SOV
  action_event_id       UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          NOT NULL REFERENCES ha_traces (trace_id),
  plan_id               UUID          REFERENCES ha_remediation_plans (plan_id),

  -- STD: Step reference
  step_id               TEXT          NOT NULL,                 -- step_id from plan_steps JSON
  step_sequence         SMALLINT      NOT NULL,                 -- execution order within plan

  -- STD: Action
  action_type           action_type   NOT NULL,
  target                TEXT,                                   -- filesystem path, env var name, command, etc.
  parameters            JSONB         NOT NULL DEFAULT '{}',    -- action-specific params

  -- STD: Execution context
  execution_mode        TEXT          NOT NULL,                 -- 'dry_run', 'auto_safe', 'auto_guarded', 'manual_guided'
  idempotency_key       TEXT,                                   -- for replay safety

  -- STD: Outcome
  result_status         TEXT          NOT NULL DEFAULT 'pending'
                        CHECK (result_status IN ('pending', 'success', 'failed', 'skipped', 'timeout', 'dry_run_only')),
  exit_code             INTEGER,
  stdout_ref            JSONB,                                  -- captured stdout (truncated/ref)
  stderr_ref            JSONB,                                  -- captured stderr (truncated/ref)
  error_message         TEXT,

  -- STD: Artifacts produced
  artifact_ids          UUID[]        NOT NULL DEFAULT '{}',    -- ha_artifacts IDs

  -- AUD
  started_at            TIMESTAMPTZ,
  ended_at              TIMESTAMPTZ,
  duration_ms           INTEGER GENERATED ALWAYS AS (
                          EXTRACT(EPOCH FROM (ended_at - started_at))::INTEGER * 1000
                        ) STORED,

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_action_events IS 'Individual executed remediation steps. Immutable once written. All system mutations are traceable through this table.';
COMMENT ON COLUMN ha_action_events.idempotency_key IS 'If set, duplicate action_event with same key and plan_id will return existing result rather than re-executing.';

CREATE INDEX idx_ha_action_trace ON ha_action_events (trace_id);
CREATE INDEX idx_ha_action_plan ON ha_action_events (plan_id);
CREATE INDEX idx_ha_action_type ON ha_action_events (action_type);
CREATE INDEX idx_ha_action_result ON ha_action_events (result_status);


-- =============================================================================
-- TABLE: ha_verification_results
-- Post-execution state validation.
-- Confirms whether remediation actually resolved the issue.
-- =============================================================================

CREATE TABLE ha_verification_results (
  -- SOV
  verification_id       UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          NOT NULL REFERENCES ha_traces (trace_id),
  plan_id               UUID          REFERENCES ha_remediation_plans (plan_id),

  -- STD: Checks
  checks                JSONB         NOT NULL,                 -- array of {check_name, status, observed_value, expected_value, detail}
  overall_pass          BOOLEAN       NOT NULL,
  followup_required     BOOLEAN       NOT NULL DEFAULT FALSE,
  followup_notes        TEXT,

  -- STD: Verification context
  verification_status   verification_status NOT NULL DEFAULT 'pending',
  verified_operation    TEXT,                                   -- e.g. 'npm_install', 'cache_path_rebind'

  -- ECL
  confidence_score      NUMERIC(4,3)
                        CHECK (confidence_score IS NULL OR (confidence_score >= 0 AND confidence_score <= 1)),

  -- AUD
  verified_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_verification_results IS 'Post-remediation state verification. Each check is typed with observed vs expected value. overall_pass determines whether Mission Control may resume gated operations.';
COMMENT ON COLUMN ha_verification_results.checks IS 'JSON array: [{check_name: "effective_cache_path_updated", status: "pass", observed_value: "E:\\npm-cache", expected_value: "E:\\npm-cache"}].';

CREATE INDEX idx_ha_verify_trace ON ha_verification_results (trace_id);
CREATE INDEX idx_ha_verify_plan ON ha_verification_results (plan_id);
CREATE INDEX idx_ha_verify_pass ON ha_verification_results (overall_pass);
CREATE INDEX idx_ha_verify_status ON ha_verification_results (verification_status);


-- =============================================================================
-- TABLE: ha_incidents
-- Human-meaningful operational incidents.
-- Higher-order objects formed from diagnoses and action chains.
-- =============================================================================

CREATE TABLE ha_incidents (
  -- SOV
  incident_id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),

  -- STD: Identity
  title                 TEXT          NOT NULL,
  incident_type         TEXT          NOT NULL,                 -- e.g. 'cache_path_misrouted', 'runtime_unavailable', 'env_drift'
  severity              severity      NOT NULL,

  -- STD: Scope
  device_id             TEXT          NOT NULL,
  workspace_id          TEXT,
  toolchain             toolchain,

  -- STD: Lifecycle
  status                ha_incident_status NOT NULL DEFAULT 'open',
  opened_at             TIMESTAMPTZ   NOT NULL DEFAULT now(),
  resolved_at           TIMESTAMPTZ,
  last_activity_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),

  -- STD: Evidence lineage
  primary_trace_id      TEXT          REFERENCES ha_traces (trace_id),
  all_trace_ids         TEXT[]        NOT NULL DEFAULT '{}',
  primary_diagnosis_id  UUID          REFERENCES ha_health_diagnoses (diagnosis_id),
  diagnosis_ids         UUID[]        NOT NULL DEFAULT '{}',
  plan_ids              UUID[]        NOT NULL DEFAULT '{}',
  action_event_ids      UUID[]        NOT NULL DEFAULT '{}',
  verification_ids      UUID[]        NOT NULL DEFAULT '{}',

  -- STD: Causal narrative
  root_cause_summary    TEXT,
  resolution_notes      TEXT,
  operator_actions      JSONB         NOT NULL DEFAULT '[]',    -- [{action, performed_at, notes}]

  -- ECL
  diagnosis_confidence  NUMERIC(4,3)
                        CHECK (diagnosis_confidence IS NULL OR (diagnosis_confidence >= 0 AND diagnosis_confidence <= 1)),

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_incidents IS 'Human-meaningful operational incidents. Permanent memory objects. Aggregates diagnosis, action, and verification lineage for a single incident thread.';

CREATE INDEX idx_ha_inc_device ON ha_incidents (device_id, opened_at DESC);
CREATE INDEX idx_ha_inc_status ON ha_incidents (status);
CREATE INDEX idx_ha_inc_severity ON ha_incidents (severity);
CREATE INDEX idx_ha_inc_open ON ha_incidents (status, opened_at DESC) WHERE status = 'open';
CREATE INDEX idx_ha_inc_type ON ha_incidents (incident_type);


-- =============================================================================
-- TABLE: ha_artifacts
-- Typed, versioned deliverables produced by Health Adapter runs.
-- =============================================================================

CREATE TABLE ha_artifacts (
  -- SOV
  artifact_id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          NOT NULL REFERENCES ha_traces (trace_id),

  -- STD: Classification
  artifact_type         TEXT          NOT NULL,                 -- 'disk_snapshot_before', 'diagnosis_report', 'action_log', 'verification_report', etc.
  format                TEXT          NOT NULL DEFAULT 'json',  -- 'json', 'markdown', 'text', 'html'

  -- STD: Content
  uri                   TEXT,                                   -- 'artifact://health/{trace_id}/{filename}'
  content_hash          TEXT,                                   -- sha256 of content
  size_bytes            INTEGER,
  content_inline        JSONB,                                  -- inline content for small artifacts

  -- AUD
  produced_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_artifacts IS 'Typed audit artifacts produced by Health Adapter runs: before/after snapshots, diagnosis reports, action logs, verification reports.';

CREATE INDEX idx_ha_artifacts_trace ON ha_artifacts (trace_id);
CREATE INDEX idx_ha_artifacts_type ON ha_artifacts (artifact_type);


-- =============================================================================
-- TABLE: ha_device_fitness_snapshots
-- Compact routing-grade fitness records for Mission Control consumption.
-- One snapshot per device per assessment event.
-- =============================================================================

CREATE TABLE ha_device_fitness_snapshots (
  -- SOV
  snapshot_id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          REFERENCES ha_traces (trace_id),

  -- STD: Subject
  device_id             TEXT          NOT NULL,
  workspace_id          TEXT,
  toolchain             toolchain,

  -- STD: Fitness dimensions (all 0.0 – 1.0)
  storage_fitness       NUMERIC(4,3)  CHECK (storage_fitness IS NULL OR (storage_fitness >= 0 AND storage_fitness <= 1)),
  temp_path_fitness     NUMERIC(4,3)  CHECK (temp_path_fitness IS NULL OR (temp_path_fitness >= 0 AND temp_path_fitness <= 1)),
  cache_path_fitness    NUMERIC(4,3)  CHECK (cache_path_fitness IS NULL OR (cache_path_fitness >= 0 AND cache_path_fitness <= 1)),
  install_fitness       NUMERIC(4,3)  CHECK (install_fitness IS NULL OR (install_fitness >= 0 AND install_fitness <= 1)),
  workspace_headroom_fitness NUMERIC(4,3) CHECK (workspace_headroom_fitness IS NULL OR (workspace_headroom_fitness >= 0 AND workspace_headroom_fitness <= 1)),
  overall_fitness       NUMERIC(4,3)  NOT NULL
                        CHECK (overall_fitness >= 0 AND overall_fitness <= 1),

  -- STD: Decision
  fit_status            fit_status    NOT NULL,
  blocking_conditions   JSONB         NOT NULL DEFAULT '[]',    -- [{factor_type, severity, description}]
  advisories            JSONB         NOT NULL DEFAULT '[]',    -- non-blocking notes

  -- STD: Cache validity
  assessed_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
  expires_at            TIMESTAMPTZ   NOT NULL,                 -- now() + 30s default
  is_stale              BOOLEAN       GENERATED ALWAYS AS (now() > expires_at) STORED,

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_device_fitness_snapshots IS 'Compact routing-grade fitness records. Mission Control queries these for local execution decisions. is_stale is computed and indexed for fast staleness checks.';

CREATE INDEX idx_ha_fitness_device ON ha_device_fitness_snapshots (device_id, toolchain, assessed_at DESC);
CREATE INDEX idx_ha_fitness_stale ON ha_device_fitness_snapshots (device_id, expires_at DESC);
CREATE INDEX idx_ha_fitness_status ON ha_device_fitness_snapshots (fit_status);


-- =============================================================================
-- SECTION C: CONFIG CONFLICT RESOLUTION CMOs
-- =============================================================================

-- =============================================================================
-- TABLE: ha_config_resolution_events
-- Captures per-key config resolution: declared → effective, with conflict attribution.
-- The "configuration truth" record for a single config key in a given trace.
-- =============================================================================

CREATE TABLE ha_config_resolution_events (
  -- SOV
  config_event_id       UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          NOT NULL REFERENCES ha_traces (trace_id),

  -- STD: Key identity
  toolchain             toolchain     NOT NULL,
  config_key            TEXT          NOT NULL,                 -- e.g. 'cache', 'prefix', 'tmp'

  -- STD: Values by layer
  declared_value        TEXT,                                   -- value in global config / tool config
  effective_value       TEXT,                                   -- value actually used at runtime
  path_mismatch_detected BOOLEAN     NOT NULL DEFAULT FALSE,

  -- STD: Override source graph
  override_sources      JSONB         NOT NULL DEFAULT '[]',    -- [{scope, level, value, source_path}]
  winning_scope         env_scope,
  losing_scopes         env_scope[]  NOT NULL DEFAULT '{}',

  -- STD: Conflict classification
  conflict_type         conflict_type,
  resolution_status     TEXT          NOT NULL DEFAULT 'no_conflict'
                        CHECK (resolution_status IN ('no_conflict', 'conflict_detected', 'conflict_resolved', 'conflict_unresolvable')),

  -- ECL
  confidence_score      NUMERIC(4,3)  NOT NULL DEFAULT 1.0
                        CHECK (confidence_score >= 0 AND confidence_score <= 1),

  -- AUD
  resolved_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ha'
);

COMMENT ON TABLE ha_config_resolution_events IS 'Per-key config truth records. Captures declared vs effective value, override source graph, and conflict classification. Critical for diagnosing env_override_conflict and config_persistence_conflict cases.';
COMMENT ON COLUMN ha_config_resolution_events.override_sources IS 'JSON: [{scope: "process", level: "process", value: "D:\\Temp\\npm", source_path: "env:npm_config_cache"}]. Ordered by precedence descending.';

CREATE INDEX idx_ha_cfg_trace ON ha_config_resolution_events (trace_id);
CREATE INDEX idx_ha_cfg_key ON ha_config_resolution_events (toolchain, config_key);
CREATE INDEX idx_ha_cfg_conflict ON ha_config_resolution_events (conflict_type) WHERE conflict_type IS NOT NULL;
CREATE INDEX idx_ha_cfg_mismatch ON ha_config_resolution_events (path_mismatch_detected) WHERE path_mismatch_detected = TRUE;


-- =============================================================================
-- SECTION D: ENVIRONMENT AUDIT LAYER CMOs
-- =============================================================================

-- =============================================================================
-- TABLE: ea_environment_snapshots
-- Complete point-in-time capture of the runtime environment by scope.
-- =============================================================================

CREATE TABLE ea_environment_snapshots (
  -- SOV
  snapshot_id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          REFERENCES ha_traces (trace_id),

  -- STD: Subject
  device_id             TEXT          NOT NULL,
  workspace_id          TEXT,
  snapshot_purpose      TEXT          NOT NULL DEFAULT 'audit',  -- 'before', 'after', 'audit', 'baseline'

  -- STD: Environment scopes
  process_env_subset    JSONB         NOT NULL DEFAULT '{}',    -- key-value pairs, sensitive values redacted
  user_env_subset       JSONB         NOT NULL DEFAULT '{}',
  machine_env_subset    JSONB         NOT NULL DEFAULT '{}',
  effective_env_subset  JSONB         NOT NULL DEFAULT '{}',    -- resolved effective values

  -- STD: PATH resolution
  path_entries          JSONB         NOT NULL DEFAULT '[]',    -- [{entry, exists, accessible, sequence}]
  path_dead_count       SMALLINT      NOT NULL DEFAULT 0,
  path_duplicate_count  SMALLINT      NOT NULL DEFAULT 0,

  -- STD: Critical routing paths
  effective_temp        TEXT,
  effective_tmp         TEXT,
  effective_home        TEXT,
  effective_userprofile TEXT,
  cwd                   TEXT,

  -- STD: Toolchain-specific paths
  toolchain_env_refs    JSONB         NOT NULL DEFAULT '{}',    -- {npm_cache, pip_cache, cargo_home, etc.}

  -- AUD
  captured_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ea'
);

COMMENT ON TABLE ea_environment_snapshots IS 'Complete runtime environment captures by scope. Before/after snapshots enable diff-based audit of env changes after remediation.';
COMMENT ON COLUMN ea_environment_snapshots.process_env_subset IS 'Captured process-level env vars. Sensitive values (tokens, passwords, keys) must be redacted by the probe before storage.';

CREATE INDEX idx_ea_env_trace ON ea_environment_snapshots (trace_id);
CREATE INDEX idx_ea_env_device ON ea_environment_snapshots (device_id, captured_at DESC);
CREATE INDEX idx_ea_env_purpose ON ea_environment_snapshots (snapshot_purpose);


-- =============================================================================
-- TABLE: ea_command_resolution_results
-- Records how specific commands resolve (or fail to resolve) in the environment.
-- =============================================================================

CREATE TABLE ea_command_resolution_results (
  -- SOV
  resolution_id         UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          REFERENCES ha_traces (trace_id),

  -- STD: Command identity
  command_name          TEXT          NOT NULL,                 -- 'uv', 'node', 'npm', 'python', 'git', etc.
  device_id             TEXT          NOT NULL,

  -- STD: Resolution outcome
  resolution_status     command_resolution_status NOT NULL,
  resolved_path         TEXT,                                   -- null if not resolved
  candidate_paths       JSONB         NOT NULL DEFAULT '[]',   -- [{path, source_dir, accessible}]

  -- STD: Spawn test
  spawn_test_attempted  BOOLEAN       NOT NULL DEFAULT FALSE,
  spawn_test_pass       BOOLEAN,
  spawn_error_message   TEXT,                                   -- 'spawn uv ENOENT', etc.
  version_output        TEXT,                                   -- stdout of version check

  -- STD: Conflict analysis
  duplicate_resolutions JSONB         NOT NULL DEFAULT '[]',   -- multiple paths found — which wins?
  runtime_family_conflict BOOLEAN     NOT NULL DEFAULT FALSE,  -- e.g. python2 vs python3 both in PATH

  -- ECL
  confidence_score      NUMERIC(4,3)  NOT NULL DEFAULT 1.0
                        CHECK (confidence_score >= 0 AND confidence_score <= 1),

  -- AUD
  tested_at             TIMESTAMPTZ   NOT NULL DEFAULT now(),

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ea'
);

COMMENT ON TABLE ea_command_resolution_results IS 'Records how commands actually resolve in the effective environment. Captures the declared_runtime_unavailable and runtime_missing_from_path failure classes. Reference: uv ENOENT MCP launch failure.';

CREATE INDEX idx_ea_cmd_trace ON ea_command_resolution_results (trace_id);
CREATE INDEX idx_ea_cmd_name ON ea_command_resolution_results (command_name);
CREATE INDEX idx_ea_cmd_status ON ea_command_resolution_results (resolution_status);
CREATE INDEX idx_ea_cmd_failed ON ea_command_resolution_results (resolution_status)
  WHERE resolution_status IN ('not_found', 'spawn_failed', 'access_denied');


-- =============================================================================
-- TABLE: ea_environment_conflicts
-- Normalized per-key conflict records from the Conflict Resolver.
-- =============================================================================

CREATE TABLE ea_environment_conflicts (
  -- SOV
  conflict_id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          REFERENCES ha_traces (trace_id),

  -- STD: Key identity
  key_name              TEXT          NOT NULL,                 -- TEMP, TMP, PATH, npm_config_cache, etc.
  toolchain             toolchain,                              -- null if system-level key

  -- STD: Conflict facts
  conflict_type         conflict_type NOT NULL,
  declared_value        TEXT,
  effective_value       TEXT,
  winning_scope         env_scope     NOT NULL,
  losing_scopes         env_scope[]   NOT NULL DEFAULT '{}',
  source_of_winning     TEXT,                                   -- path or mechanism

  -- STD: Persistence
  persistence_level     TEXT          NOT NULL DEFAULT 'process'
                        CHECK (persistence_level IN ('process', 'user', 'machine', 'tool_config', 'shell_profile')),
  restart_required      BOOLEAN       NOT NULL DEFAULT FALSE,   -- true if fix requires session restart
  reinjection_risk      BOOLEAN       NOT NULL DEFAULT FALSE,   -- true if override may re-appear after fix

  -- STD: Severity
  severity              severity      NOT NULL,

  -- ECL
  confidence_score      NUMERIC(4,3)  NOT NULL DEFAULT 1.0
                        CHECK (confidence_score >= 0 AND confidence_score <= 1),

  -- AUD
  detected_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ea'
);

COMMENT ON TABLE ea_environment_conflicts IS 'Normalized per-key environment conflicts. Records why declared config differs from effective runtime state, and the persistence risk of the override. Feeds the config_stability ECL score.';

CREATE INDEX idx_ea_conflict_trace ON ea_environment_conflicts (trace_id);
CREATE INDEX idx_ea_conflict_key ON ea_environment_conflicts (key_name);
CREATE INDEX idx_ea_conflict_type ON ea_environment_conflicts (conflict_type);
CREATE INDEX idx_ea_conflict_reinjection ON ea_environment_conflicts (reinjection_risk) WHERE reinjection_risk = TRUE;
CREATE INDEX idx_ea_conflict_restart ON ea_environment_conflicts (restart_required) WHERE restart_required = TRUE;


-- =============================================================================
-- TABLE: ea_environment_fitness_snapshots
-- Compact environment fitness records for Mission Control routing.
-- =============================================================================

CREATE TABLE ea_environment_fitness_snapshots (
  -- SOV
  snapshot_id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id              TEXT          REFERENCES ha_traces (trace_id),

  -- STD: Subject
  device_id             TEXT          NOT NULL,
  workspace_id          TEXT,
  toolchain             toolchain,

  -- STD: Fitness dimensions (all 0.0 – 1.0)
  env_consistency_score    NUMERIC(4,3) CHECK (env_consistency_score IS NULL OR (env_consistency_score >= 0 AND env_consistency_score <= 1)),
  path_integrity_score     NUMERIC(4,3) CHECK (path_integrity_score IS NULL OR (path_integrity_score >= 0 AND path_integrity_score <= 1)),
  runtime_availability_score NUMERIC(4,3) CHECK (runtime_availability_score IS NULL OR (runtime_availability_score >= 0 AND runtime_availability_score <= 1)),
  temp_route_safety_score  NUMERIC(4,3) CHECK (temp_route_safety_score IS NULL OR (temp_route_safety_score >= 0 AND temp_route_safety_score <= 1)),
  cache_route_safety_score NUMERIC(4,3) CHECK (cache_route_safety_score IS NULL OR (cache_route_safety_score >= 0 AND cache_route_safety_score <= 1)),
  session_freshness_score  NUMERIC(4,3) CHECK (session_freshness_score IS NULL OR (session_freshness_score >= 0 AND session_freshness_score <= 1)),
  overall_environment_fitness NUMERIC(4,3) NOT NULL
                        CHECK (overall_environment_fitness >= 0 AND overall_environment_fitness <= 1),

  -- STD: Decision
  blocking_conditions   JSONB         NOT NULL DEFAULT '[]',
  advisories            JSONB         NOT NULL DEFAULT '[]',
  restart_required      BOOLEAN       NOT NULL DEFAULT FALSE,

  -- STD: Cache validity
  assessed_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
  expires_at            TIMESTAMPTZ   NOT NULL,
  is_stale              BOOLEAN       GENERATED ALWAYS AS (now() > expires_at) STORED,

  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'ea'
);

COMMENT ON TABLE ea_environment_fitness_snapshots IS 'Compact environment fitness for Mission Control routing. Covers env consistency, PATH integrity, runtime availability, temp/cache safety, and session freshness.';

CREATE INDEX idx_ea_env_fitness_device ON ea_environment_fitness_snapshots (device_id, toolchain, assessed_at DESC);
CREATE INDEX idx_ea_env_fitness_stale ON ea_environment_fitness_snapshots (device_id, expires_at DESC);
CREATE INDEX idx_ea_env_fitness_restart ON ea_environment_fitness_snapshots (restart_required) WHERE restart_required = TRUE;


-- =============================================================================
-- SECTION E: EXTENSIONS TO EXISTING HHA TABLES
-- =============================================================================

-- Extend hardware_incidents to support diagnosis/remediation lifecycle linkage
ALTER TABLE hardware_incidents
  ADD COLUMN IF NOT EXISTS primary_ha_diagnosis_id UUID
    REFERENCES ha_health_diagnoses (diagnosis_id),
  ADD COLUMN IF NOT EXISTS ha_remediation_plan_ids UUID[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS ha_verification_id UUID
    REFERENCES ha_verification_results (verification_id);

COMMENT ON COLUMN hardware_incidents.primary_ha_diagnosis_id IS 'Links hardware_incidents to Health Adapter diagnosis when the incident was caused by a path/config/env failure rather than a pure hardware issue.';

-- Extend hardware_anomalies to support Health Adapter diagnosis linkage
ALTER TABLE hardware_anomalies
  ADD COLUMN IF NOT EXISTS ha_diagnosis_id UUID
    REFERENCES ha_health_diagnoses (diagnosis_id);

COMMENT ON COLUMN hardware_anomalies.ha_diagnosis_id IS 'Links anomaly to a Health Adapter diagnosis when the anomaly was caused by path/config/env mismatch rather than raw telemetry threshold breach.';

-- Extend hardware_workload_fitness_profiles to include HA-level blockers
ALTER TABLE hardware_workload_fitness_profiles
  ADD COLUMN IF NOT EXISTS ha_fitness_snapshot_id UUID
    REFERENCES ha_device_fitness_snapshots (snapshot_id),
  ADD COLUMN IF NOT EXISTS ea_fitness_snapshot_id UUID
    REFERENCES ea_environment_fitness_snapshots (snapshot_id),
  ADD COLUMN IF NOT EXISTS health_blockers JSONB NOT NULL DEFAULT '[]';

COMMENT ON COLUMN hardware_workload_fitness_profiles.health_blockers IS 'HA/EA-sourced blocking conditions that override hardware fitness. Example: env misconfiguration making llm_14b locally unrunnable even if GPU health is good.';


-- =============================================================================
-- SECTION F: UNIFIED VIEWS FOR MISSION CONTROL AND XHIVE
-- =============================================================================

-- Complete current device fitness (hardware + HA + EA combined)
CREATE VIEW vw_unified_device_fitness AS
SELECT
  d.device_id,
  d.toolchain,

  -- Hardware fitness
  h.health_score          AS hw_health_score,
  h.health_band           AS hw_health_band,

  -- HA fitness
  ha.overall_fitness      AS ha_overall_fitness,
  ha.fit_status           AS ha_fit_status,
  ha.blocking_conditions  AS ha_blocking_conditions,
  ha.assessed_at          AS ha_assessed_at,
  ha.is_stale             AS ha_is_stale,

  -- Environment fitness
  ea.overall_environment_fitness AS ea_env_fitness,
  ea.restart_required     AS env_restart_required,
  ea.blocking_conditions  AS ea_blocking_conditions,
  ea.assessed_at          AS ea_assessed_at,
  ea.is_stale             AS ea_is_stale,

  -- Combined routing signal
  CASE
    WHEN ha.fit_status = 'not_fit' OR ea.overall_environment_fitness < 0.40 THEN 'not_fit'
    WHEN ha.fit_status = 'fit_with_constraints' OR ea.overall_environment_fitness < 0.70 THEN 'fit_with_constraints'
    ELSE 'fit'
  END AS combined_fit_status

FROM (
  SELECT DISTINCT device_id, toolchain FROM ha_device_fitness_snapshots
) d
LEFT JOIN LATERAL (
  SELECT health_score, health_band
  FROM hardware_assessments
  WHERE subject_type = 'system'
  ORDER BY assessed_at DESC
  LIMIT 1
) h ON TRUE
LEFT JOIN LATERAL (
  SELECT overall_fitness, fit_status, blocking_conditions, assessed_at, is_stale
  FROM ha_device_fitness_snapshots
  WHERE device_id = d.device_id AND toolchain = d.toolchain
  ORDER BY assessed_at DESC
  LIMIT 1
) ha ON TRUE
LEFT JOIN LATERAL (
  SELECT overall_environment_fitness, restart_required, blocking_conditions, assessed_at, is_stale
  FROM ea_environment_fitness_snapshots
  WHERE device_id = d.device_id AND toolchain = d.toolchain
  ORDER BY assessed_at DESC
  LIMIT 1
) ea ON TRUE;

COMMENT ON VIEW vw_unified_device_fitness IS 'Combined hardware + HA + environment fitness for Mission Control routing. combined_fit_status is the authoritative routing signal.';


-- Current HA incidents summary
CREATE VIEW vw_ha_open_incidents AS
SELECT
  i.incident_id,
  i.title,
  i.incident_type,
  i.severity,
  i.status,
  i.device_id,
  i.toolchain,
  i.root_cause_summary,
  i.opened_at,
  i.last_activity_at,
  EXTRACT(EPOCH FROM (now() - i.opened_at))/3600 AS open_hours,
  d.primary_diagnosis,
  d.confidence_score AS diagnosis_confidence
FROM ha_incidents i
LEFT JOIN ha_health_diagnoses d ON d.diagnosis_id = i.primary_diagnosis_id
WHERE i.status IN ('open', 'remediating', 'verifying')
ORDER BY
  CASE i.severity
    WHEN 'critical' THEN 1
    WHEN 'high'     THEN 2
    WHEN 'medium'   THEN 3
    WHEN 'low'      THEN 4
    ELSE 5
  END,
  i.opened_at ASC;

COMMENT ON VIEW vw_ha_open_incidents IS 'Active HA incidents with diagnosis. Mission Control uses this to determine whether to block or warn before local execution.';


-- Config conflicts requiring attention
CREATE VIEW vw_active_config_conflicts AS
SELECT
  c.conflict_id,
  c.trace_id,
  c.key_name,
  c.toolchain,
  c.conflict_type,
  c.declared_value,
  c.effective_value,
  c.winning_scope,
  c.severity,
  c.persistence_level,
  c.restart_required,
  c.reinjection_risk,
  c.detected_at
FROM ea_environment_conflicts c
JOIN ha_traces t ON t.trace_id = c.trace_id
WHERE t.started_at > now() - interval '24 hours'
ORDER BY
  CASE c.severity
    WHEN 'critical' THEN 1
    WHEN 'high'     THEN 2
    WHEN 'medium'   THEN 3
    ELSE 4
  END,
  c.reinjection_risk DESC,
  c.detected_at DESC;

COMMENT ON VIEW vw_active_config_conflicts IS 'Config conflicts detected in the last 24 hours. Ordered by severity and reinjection risk. XHive uses this for the environment integrity panel.';


-- Command resolution failures
CREATE VIEW vw_failed_command_resolutions AS
SELECT
  r.resolution_id,
  r.trace_id,
  r.command_name,
  r.device_id,
  r.resolution_status,
  r.spawn_error_message,
  r.runtime_family_conflict,
  r.tested_at
FROM ea_command_resolution_results r
WHERE r.resolution_status IN ('not_found', 'spawn_failed', 'access_denied')
ORDER BY r.tested_at DESC;

COMMENT ON VIEW vw_failed_command_resolutions IS 'Commands that failed to resolve or spawn. Feeds declared_runtime_unavailable and runtime_missing_from_path diagnoses. Reference: uv ENOENT MCP launch failure.';


-- Full trace audit view (diagnosis + plan + verification in one row)
CREATE VIEW vw_trace_audit_summary AS
SELECT
  t.trace_id,
  t.device_id,
  t.toolchain,
  t.symptom,
  t.execution_mode,
  t.final_status,
  t.started_at,
  t.completed_at,
  d.primary_diagnosis,
  d.severity              AS diagnosis_severity,
  d.confidence_score      AS diagnosis_confidence,
  d.recoverability,
  p.plan_status,
  p.estimated_risk,
  p.estimated_recovery_probability,
  v.overall_pass          AS verification_pass,
  v.verification_status,
  i.incident_id,
  i.status                AS incident_status
FROM ha_traces t
LEFT JOIN ha_health_diagnoses d ON d.trace_id = t.trace_id AND d.status = 'active'
LEFT JOIN ha_remediation_plans p ON p.trace_id = t.trace_id AND p.plan_status != 'cancelled'
LEFT JOIN ha_verification_results v ON v.trace_id = t.trace_id
LEFT JOIN ha_incidents i ON i.primary_trace_id = t.trace_id
ORDER BY t.started_at DESC;

COMMENT ON VIEW vw_trace_audit_summary IS 'Full trace audit: one row per trace with diagnosis, plan, verification, and incident linkage. XHive diagnostics history view and postmortem tooling.';


-- =============================================================================
-- SECTION G: GOLD TEST FIXTURE — npm ENOSPC MISROUTED CACHE
-- Reference incident for P0 integration testing
-- =============================================================================

DO $$
DECLARE
  v_trace_id     TEXT := 'trc_npm_enospc_gold_001';
  v_diag_id      UUID;
  v_plan_id      UUID;
  v_verify_id    UUID;
  v_incident_id  UUID;
  v_snap_id      UUID;
  v_env_snap_id  UUID;
  v_fit_snap_id  UUID;
  v_ea_fit_id    UUID;
BEGIN

  -- Trace
  INSERT INTO ha_traces (
    trace_id, request_id, device_id, workspace_id, actor_id, actor_type,
    toolchain, operation, symptom,
    execution_mode, policy_mode, final_status, adapter_runtime_ms,
    started_at, completed_at
  ) VALUES (
    v_trace_id, 'req_npm_enospc_gold_001',
    'dev_nexus_01', 'ws_system_health', 'user_phoenix', 'user',
    'npm', 'install', 'install_failed_enospc',
    'diagnose_and_remediate_safe', 'safe_auto_remediate', 'completed', 1840,
    '2026-04-06T08:00:00Z', '2026-04-06T08:00:01.84Z'
  ) ON CONFLICT (trace_id) DO NOTHING;

  -- Health observations
  INSERT INTO ha_health_observations (
    trace_id, source_adapter, observation_type, path, drive,
    metric_name, metric_value, metric_unit, device_id, workspace_id, toolchain,
    confidence_score, observed_at
  ) VALUES
    (v_trace_id, 'resource_probe', 'capacity_fact', 'D:', 'D',
     'drive_free_bytes', '0', 'bytes', 'dev_nexus_01', 'ws_system_health', 'npm', 1.0, '2026-04-06T08:00:00Z'),
    (v_trace_id, 'resource_probe', 'capacity_fact', 'C:', 'C',
     'drive_free_bytes', '7645179904', 'bytes', 'dev_nexus_01', 'ws_system_health', 'npm', 1.0, '2026-04-06T08:00:00Z'),
    (v_trace_id, 'resource_probe', 'capacity_fact', 'E:', 'E',
     'drive_free_bytes', '975020388352', 'bytes', 'dev_nexus_01', 'ws_system_health', 'npm', 1.0, '2026-04-06T08:00:00Z'),
    (v_trace_id, 'path_probe', 'path_fact', 'D:\Temp\npm', 'D',
     'effective_cache_path', 'D:\Temp\npm', 'path', 'dev_nexus_01', 'ws_system_health', 'npm', 1.0, '2026-04-06T08:00:00Z'),
    (v_trace_id, 'path_probe', 'path_fact', 'E:\npm-cache', 'E',
     'declared_cache_path', 'E:\npm-cache', 'path', 'dev_nexus_01', 'ws_system_health', 'npm', 1.0, '2026-04-06T08:00:00Z'),
    (v_trace_id, 'path_probe', 'path_fact', NULL, NULL,
     'path_mismatch_detected', 'true', 'boolean', 'dev_nexus_01', 'ws_system_health', 'npm', 1.0, '2026-04-06T08:00:00Z'),
    (v_trace_id, 'toolchain_resolver', 'config_fact', NULL, NULL,
     'npm_config_cache_override_source', 'npm_config_cache env var (process/user)', 'string',
     'dev_nexus_01', 'ws_system_health', 'npm', 0.98, '2026-04-06T08:00:00Z');

  -- Diagnosis
  INSERT INTO ha_health_diagnoses (
    trace_id, primary_diagnosis, secondary_diagnoses,
    symptom, immediate_cause, root_cause, contributing_factors,
    impact_scope, severity, recoverability,
    confidence_score, recommended_next_action, status, diagnosed_at
  ) VALUES (
    v_trace_id,
    'cache_path_misrouted',
    ARRAY['disk_exhaustion_effective_path', 'env_override_conflict']::diagnosis_category[],
    'npm install returned ENOSPC',
    'write to effective cache path failed — D:\Temp\npm has 0 bytes free',
    'npm_config_cache environment variable overrode the correct global config (E:\npm-cache), routing all cache writes to a tiny reserved partition with no free space',
    '["effective cache path on D: reserved partition (100 MB total)", "npm_config_cache env var shadowing global config", "D: free space = 0 bytes", "E: has 975 GB free but was bypassed"]'::jsonb,
    'local_dependency_install', 'high', 'recoverable_with_safe_actions',
    0.96, 'plan_safe_remediation', 'active', '2026-04-06T08:00:00.5Z'
  ) RETURNING diagnosis_id INTO v_diag_id;

  -- Config resolution event
  INSERT INTO ha_config_resolution_events (
    trace_id, toolchain, config_key,
    declared_value, effective_value, path_mismatch_detected,
    override_sources, winning_scope, losing_scopes,
    conflict_type, resolution_status, confidence_score, resolved_at
  ) VALUES (
    v_trace_id, 'npm', 'cache',
    'E:\npm-cache', 'D:\Temp\npm', TRUE,
    '[{"scope": "process", "level": "process", "value": "D:\\\\Temp\\\\npm", "source_path": "env:npm_config_cache"}, {"scope": "user", "level": "user", "value": "E:\\\\npm-cache", "source_path": ".npmrc global"}]'::jsonb,
    'process', ARRAY['user']::env_scope[],
    'scope_conflict_process_user', 'conflict_detected', 0.98, '2026-04-06T08:00:00.5Z'
  );

  -- Environment conflict record
  INSERT INTO ea_environment_conflicts (
    trace_id, key_name, toolchain,
    conflict_type, declared_value, effective_value,
    winning_scope, losing_scopes, source_of_winning,
    persistence_level, restart_required, reinjection_risk,
    severity, confidence_score, detected_at
  ) VALUES (
    v_trace_id, 'npm_config_cache', 'npm',
    'scope_conflict_process_user', 'E:\npm-cache', 'D:\Temp\npm',
    'process', ARRAY['user']::env_scope[], 'env:npm_config_cache',
    'user', FALSE, TRUE,
    'high', 0.98, '2026-04-06T08:00:00.5Z'
  );

  -- Environment snapshot (before)
  INSERT INTO ea_environment_snapshots (
    trace_id, device_id, workspace_id, snapshot_purpose,
    process_env_subset, user_env_subset, machine_env_subset, effective_env_subset,
    path_entries, path_dead_count, path_duplicate_count,
    effective_temp, effective_tmp,
    toolchain_env_refs, captured_at
  ) VALUES (
    v_trace_id, 'dev_nexus_01', 'ws_system_health', 'before',
    '{"npm_config_cache": "D:\\\\Temp\\\\npm", "TEMP": "D:\\\\Temp", "TMP": "D:\\\\Temp"}'::jsonb,
    '{"npm_config_cache": "E:\\\\npm-cache"}'::jsonb,
    '{}'::jsonb,
    '{"npm_config_cache": "D:\\\\Temp\\\\npm", "TEMP": "D:\\\\Temp", "TMP": "D:\\\\Temp"}'::jsonb,
    '[]'::jsonb, 0, 0,
    'D:\Temp', 'D:\Temp',
    '{"npm_cache": "D:\\\\Temp\\\\npm", "npm_cache_declared": "E:\\\\npm-cache"}'::jsonb,
    '2026-04-06T08:00:00Z'
  ) RETURNING snapshot_id INTO v_env_snap_id;

  -- Remediation plan
  INSERT INTO ha_remediation_plans (
    trace_id, diagnosis_id, policy_mode, requires_approval,
    plan_steps, approved_target_roots, estimated_risk,
    estimated_recovery_probability, plan_status, confidence_score, generated_at
  ) VALUES (
    v_trace_id, v_diag_id, 'safe_auto_remediate', FALSE,
    '[
      {"step_id": "step_01", "action_type": "capture_snapshot", "target": "workspace_and_relevant_drives", "risk": "low", "reversible": false},
      {"step_id": "step_02", "action_type": "clean_tool_cache", "target": "npm_cache", "risk": "low", "reversible": false},
      {"step_id": "step_03", "action_type": "remove_node_modules", "target": "C:\\\\Projects\\\\system_health\\\\node_modules", "risk": "low", "reversible": false},
      {"step_id": "step_04", "action_type": "rebind_cache_path", "target": "E:\\\\npm-cache", "risk": "low", "reversible": true},
      {"step_id": "step_05", "action_type": "verify_thresholds", "target": "all_relevant_drives", "risk": "low", "reversible": false},
      {"step_id": "step_06", "action_type": "run_target_command", "target": "npm install", "risk": "low", "reversible": false}
    ]'::jsonb,
    ARRAY['C:\Projects', 'E:\npm-cache'],
    'low', 0.94, 'completed', 0.94, '2026-04-06T08:00:01Z'
  ) RETURNING plan_id INTO v_plan_id;

  -- Action events
  INSERT INTO ha_action_events (
    trace_id, plan_id, step_id, step_sequence, action_type, target,
    execution_mode, result_status, exit_code, started_at, ended_at
  ) VALUES
    (v_trace_id, v_plan_id, 'step_02', 1, 'clean_tool_cache', 'npm_cache',
     'auto_safe', 'success', 0, '2026-04-06T08:00:01.1Z', '2026-04-06T08:00:01.3Z'),
    (v_trace_id, v_plan_id, 'step_03', 2, 'remove_node_modules', 'C:\Projects\system_health\node_modules',
     'auto_safe', 'success', 0, '2026-04-06T08:00:01.3Z', '2026-04-06T08:00:01.5Z'),
    (v_trace_id, v_plan_id, 'step_04', 3, 'rebind_cache_path', 'E:\npm-cache',
     'auto_safe', 'success', 0, '2026-04-06T08:00:01.5Z', '2026-04-06T08:00:01.6Z'),
    (v_trace_id, v_plan_id, 'step_06', 4, 'run_target_command', 'npm install',
     'auto_safe', 'success', 0, '2026-04-06T08:00:01.6Z', '2026-04-06T08:00:01.84Z');

  -- Verification result
  INSERT INTO ha_verification_results (
    trace_id, plan_id,
    checks, overall_pass, followup_required,
    verification_status, verified_operation,
    confidence_score, verified_at
  ) VALUES (
    v_trace_id, v_plan_id,
    '[
      {"check_name": "effective_cache_path_not_on_reserved_partition", "status": "pass", "observed_value": "E:\\\\npm-cache"},
      {"check_name": "project_drive_free_space_gte_floor", "status": "pass", "observed_value": 7645179904, "expected_value": 2147483648},
      {"check_name": "cache_drive_free_space_gte_floor", "status": "pass", "observed_value": 975020388352, "expected_value": 2147483648},
      {"check_name": "operation_exit_code_zero", "status": "pass", "observed_value": 0}
    ]'::jsonb,
    TRUE, FALSE, 'passed', 'npm_install',
    0.97, '2026-04-06T08:00:01.9Z'
  ) RETURNING verification_id INTO v_verify_id;

  -- Device fitness snapshot
  INSERT INTO ha_device_fitness_snapshots (
    trace_id, device_id, workspace_id, toolchain,
    storage_fitness, temp_path_fitness, cache_path_fitness,
    install_fitness, workspace_headroom_fitness, overall_fitness,
    fit_status, blocking_conditions, advisories,
    assessed_at, expires_at
  ) VALUES (
    v_trace_id, 'dev_nexus_01', 'ws_system_health', 'npm',
    0.91, 0.88, 0.97, 0.95, 0.84, 0.91,
    'fit',
    '[]'::jsonb,
    '["D: reserved partition should remain excluded from temp/cache routing"]'::jsonb,
    '2026-04-06T08:00:02Z', '2026-04-06T08:00:32Z'
  ) RETURNING snapshot_id INTO v_fit_snap_id;

  -- Environment fitness snapshot (after remediation)
  INSERT INTO ea_environment_fitness_snapshots (
    trace_id, device_id, workspace_id, toolchain,
    env_consistency_score, path_integrity_score, runtime_availability_score,
    temp_route_safety_score, cache_route_safety_score, session_freshness_score,
    overall_environment_fitness,
    blocking_conditions, advisories, restart_required,
    assessed_at, expires_at
  ) VALUES (
    v_trace_id, 'dev_nexus_01', 'ws_system_health', 'npm',
    0.91, 0.85, 0.95, 0.88, 0.97, 0.80, 0.89,
    '[]'::jsonb,
    '["D: is a reserved partition — permanently exclude from temp/cache routing", "Consider moving TEMP/TMP from D: to C:\\\\Temp for full environment convergence"]'::jsonb,
    FALSE,
    '2026-04-06T08:00:02Z', '2026-04-06T08:00:32Z'
  ) RETURNING snapshot_id INTO v_ea_fit_id;

  -- HA incident record
  INSERT INTO ha_incidents (
    device_id, workspace_id, toolchain,
    title, incident_type, severity, status,
    primary_trace_id, all_trace_ids,
    primary_diagnosis_id, diagnosis_ids,
    plan_ids, verification_ids,
    root_cause_summary, resolution_notes,
    diagnosis_confidence,
    opened_at, resolved_at, last_activity_at
  ) VALUES (
    'dev_nexus_01', 'ws_system_health', 'npm',
    'npm install ENOSPC due to misrouted cache path on reserved partition',
    'cache_path_misrouted', 'high', 'resolved',
    v_trace_id, ARRAY[v_trace_id],
    v_diag_id, ARRAY[v_diag_id],
    ARRAY[v_plan_id], ARRAY[v_verify_id],
    'npm_config_cache env var (process/user scope) overrode correct global config (E:\npm-cache), routing all cache writes to D:\Temp\npm — a 100 MB reserved system partition with 0 bytes free. Project drive (C:) and alternate drive (E:) both had sufficient capacity. This is a path-routing failure, not a true storage exhaustion.',
    'Cache rebound to E:\npm-cache. npm_config_cache env var cleared at user scope. npm install confirmed with exit code 0. Verification passed on all 4 checks.',
    0.96,
    '2026-04-06T08:00:00Z', '2026-04-06T08:00:02Z', '2026-04-06T08:00:02Z'
  ) RETURNING incident_id INTO v_incident_id;

  RAISE NOTICE 'Gold fixture inserted: trace=%, diag=%, plan=%, verify=%, incident=%',
    v_trace_id, v_diag_id, v_plan_id, v_verify_id, v_incident_id;

END $$;


-- =============================================================================
-- SECTION H: SCHEMA VERSION
-- =============================================================================

INSERT INTO hha_schema_versions (version, description)
VALUES (
  '1.0.0',
  'Health CMO Schema Pack v1.0 — Health Adapter CMOs (traces, observations, diagnoses, plans, actions, verifications, incidents, artifacts, fitness), Environment Audit CMOs (env snapshots, command resolution, env conflicts, env fitness), Config Resolution Events, extensions to hardware_incidents/anomalies/fitness, unified views, npm ENOSPC gold fixture'
);


-- =============================================================================
-- RETENTION NOTES
-- =============================================================================
--
-- ha_traces:                    Retain 365 days. Permanent for incidents.
-- ha_health_observations:       Retain 90 days. Archive thereafter.
-- ha_health_diagnoses:          Retain 365 days. Permanent for incidents.
-- ha_remediation_plans:         Retain 365 days.
-- ha_action_events:             Retain 365 days. Immutable audit log.
-- ha_verification_results:      Retain 365 days.
-- ha_incidents:                 Permanent. Canonical memory objects.
-- ha_artifacts:                 Retain 90 days unless referenced by incident.
-- ha_device_fitness_snapshots:  Retain 90 days.
-- ha_config_resolution_events:  Retain 90 days.
-- ea_environment_snapshots:     Retain 90 days.
-- ea_command_resolution_results:Retain 90 days.
-- ea_environment_conflicts:     Retain 90 days. Permanent if linked to incident.
-- ea_environment_fitness_snapshots: Retain 90 days.
-- =============================================================================

-- =============================================================================
-- END: Codessa Health CMO Schema Pack v1.0
-- =============================================================================
