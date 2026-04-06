-- =============================================================================
-- CODESSA HARDWARE HEALTH AGENT
-- Canonical Schema + SQL Table Design v0.1
-- Date: April 6, 2026
-- Target: PostgreSQL 15+ (Supabase-compatible)
-- Conventions: Codessa canonical ledger field naming
-- =============================================================================
--
-- FIELD CLASSIFICATION (Codessa SSFIL standard):
--   SOV  = Sovereign / immutable identity field
--   ECL  = Epistemic Confidence Layer field
--   AUD  = Audit / provenance field
--   STD  = Standard operational field
--
-- TABLE DEPENDENCY ORDER (create in this sequence):
--   1. hardware_components
--   2. hardware_sensor_sources        (optional in v0.1 but recommended)
--   3. hardware_observations
--   4. hardware_benchmark_runs
--   5. hardware_assessments
--   6. hardware_anomalies
--   7. hardware_incidents
--   8. hardware_maintenance_events
--   9. hardware_workload_fitness_profiles
--  10. hardware_baselines             (Phase 3)
--  11. hardware_policy_profiles       (Phase 3)
-- =============================================================================


-- =============================================================================
-- ENUMS
-- =============================================================================

CREATE TYPE component_type AS ENUM (
  'cpu',
  'gpu',
  'memory',
  'storage',
  'cooling',
  'motherboard',
  'power_inferred'
);

CREATE TYPE health_band AS ENUM (
  'excellent',   -- 0.90 – 1.00
  'good',        -- 0.75 – 0.89
  'watch',       -- 0.60 – 0.74
  'degraded',    -- 0.40 – 0.59
  'critical'     -- 0.00 – 0.39
);

CREATE TYPE sampling_mode AS ENUM (
  'passive',
  'active_test'
);

CREATE TYPE operational_mode AS ENUM (
  'idle',
  'active_monitoring',
  'diagnostic',
  'incident'
);

CREATE TYPE benchmark_type AS ENUM (
  'cpu_stress',
  'cpu_benchmark',
  'gpu_stress',
  'gpu_benchmark',
  'memory_diagnostic',
  'storage_benchmark',
  'full_system'
);

CREATE TYPE pass_fail_status AS ENUM (
  'pass',
  'fail',
  'partial',
  'interrupted',
  'error'
);

CREATE TYPE anomaly_type AS ENUM (
  'threshold_breach',
  'persistence_anomaly',
  'baseline_deviation',
  'benchmark_underperformance',
  'cooling_under_response',
  'thermal_throttling',
  'cross_signal_contradiction',
  'instability_event'
);

CREATE TYPE severity AS ENUM (
  'info',      -- notable but harmless
  'low',       -- watch condition
  'medium',    -- degraded but usable
  'high',      -- likely harmful or unstable
  'critical'   -- unsafe / unfit / data integrity risk
);

CREATE TYPE incident_status AS ENUM (
  'open',
  'monitoring',
  'resolved',
  'suppressed'
);

CREATE TYPE workload_class AS ENUM (
  'light_interactive',
  'development',
  'embedding_batch',
  'llm_7b',
  'llm_14b',
  'gpu_heavy',
  'stress_diagnostic'
);

CREATE TYPE fit_status AS ENUM (
  'fit',
  'fit_with_constraints',
  'not_fit'
);

CREATE TYPE trend_direction AS ENUM (
  'improving',
  'stable',
  'degrading',
  'volatile'
);

CREATE TYPE adapter_type AS ENUM (
  'os_telemetry',
  'sensor',
  'benchmark',
  'smart',
  'event_log',
  'gpu_vendor',
  'memory_diag'
);

CREATE TYPE trust_tier AS ENUM (
  'high',
  'medium',
  'low'
);

CREATE TYPE component_status AS ENUM (
  'active',
  'degraded',
  'failed',
  'replaced',
  'unknown'
);


-- =============================================================================
-- TABLE 1: hardware_components
-- Canonical registry of physical hardware units discovered on the workstation.
-- SOV: component_id, device_fingerprint
-- One record per physical device. Stable across reboots and rereads.
-- =============================================================================

CREATE TABLE hardware_components (
  -- SOV: Identity
  component_id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  device_fingerprint    TEXT          NOT NULL UNIQUE,          -- deterministic hash from vendor+model+serial/capacity
  
  -- STD: Classification
  component_type        component_type NOT NULL,
  device_role           TEXT          NOT NULL,                 -- e.g. 'primary_cpu', 'primary_gpu', 'nvme_boot'
  
  -- STD: Hardware metadata
  vendor                TEXT,
  model                 TEXT,
  serial_number         TEXT,                                   -- may be null if not exposed
  firmware_version      TEXT,
  
  -- STD: Capability profile
  expected_operating_profile JSONB    NOT NULL DEFAULT '{}',    -- nominal temp range, TDP, clock range, etc.
  
  -- STD: Lifecycle
  status                component_status NOT NULL DEFAULT 'active',
  installed_at          TIMESTAMPTZ,                            -- operator-supplied; null = unknown
  
  -- AUD: Ledger
  discovered_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
  last_seen_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE hardware_components IS 'Canonical registry of discovered hardware components. One record per physical device. Stable component_id is the system-wide reference for all telemetry.';
COMMENT ON COLUMN hardware_components.device_fingerprint IS 'Deterministic SHA-256 hash: sha256(vendor || model || serial_or_capacity). Used to match device across adapter reads without duplication.';
COMMENT ON COLUMN hardware_components.expected_operating_profile IS 'JSON: { max_temp_celsius, nominal_clock_mhz, tdp_watts, vram_mb, capacity_gb, etc. } — component-type-specific nominal operating envelope.';

CREATE INDEX idx_hardware_components_type ON hardware_components (component_type);
CREATE INDEX idx_hardware_components_status ON hardware_components (status);


-- =============================================================================
-- TABLE 2: hardware_sensor_sources  (optional v0.1, recommended)
-- Registry of adapter/sensor sources that produced observations.
-- Enables confidence scoring and adapter health tracking.
-- =============================================================================

CREATE TABLE hardware_sensor_sources (
  -- SOV
  source_id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  adapter_id            TEXT          NOT NULL UNIQUE,          -- e.g. 'linux_sensors_v1', 'nvidia_smi_v1'
  
  -- STD
  adapter_type          adapter_type  NOT NULL,
  platform              TEXT          NOT NULL,                 -- 'linux' | 'windows' | 'cross'
  trust_tier            trust_tier    NOT NULL DEFAULT 'medium',
  tool_name             TEXT,                                   -- e.g. 'lm-sensors', 'nvidia-smi', 'smartctl'
  tool_version          TEXT,
  
  -- STD: Health
  is_healthy            BOOLEAN       NOT NULL DEFAULT TRUE,
  last_validated_at     TIMESTAMPTZ,
  degradation_reason    TEXT,
  
  -- AUD
  registered_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE hardware_sensor_sources IS 'Registry of adapter/sensor sources. Used to track adapter health and apply trust-tier confidence modifiers to observations.';

CREATE INDEX idx_sensor_sources_adapter_type ON hardware_sensor_sources (adapter_type);
CREATE INDEX idx_sensor_sources_trust ON hardware_sensor_sources (trust_tier);


-- =============================================================================
-- TABLE 3: hardware_observations
-- Normalized, canonical telemetry observations.
-- The atomic unit of hardware evidence. Immutable once written.
-- High write volume — partition by time if volume warrants it.
-- =============================================================================

CREATE TABLE hardware_observations (
  -- SOV: Identity
  observation_id        UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- SOV: Lineage
  component_id          UUID          NOT NULL REFERENCES hardware_components (component_id),
  source_id             UUID          REFERENCES hardware_sensor_sources (source_id),
  benchmark_run_id      UUID,                                   -- FK added after benchmark_runs table created
  
  -- STD: Metric payload
  metric_name           TEXT          NOT NULL,                 -- canonical metric name (e.g. 'cpu.package_temp')
  metric_value          NUMERIC(12,4) NOT NULL,
  metric_unit           TEXT          NOT NULL,                 -- 'celsius' | 'MHz' | 'MB' | 'percent' | 'RPM' | etc.
  
  -- STD: Context
  sampling_mode         sampling_mode NOT NULL DEFAULT 'passive',
  operational_mode      operational_mode,                       -- mode at time of observation
  collection_context    JSONB         NOT NULL DEFAULT '{}',    -- workload info, concurrent processes, etc.
  
  -- ECL: Confidence
  confidence_score      NUMERIC(4,3)  NOT NULL                  -- 0.000 – 1.000
                        CHECK (confidence_score >= 0 AND confidence_score <= 1),
  corroboration_count   SMALLINT      NOT NULL DEFAULT 1,       -- number of adapters agreeing on this value
  
  -- AUD: Provenance
  raw_payload_ref       JSONB,                                  -- original source output for audit
  observed_at           TIMESTAMPTZ   NOT NULL,                 -- when the metric was actually measured
  ingested_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),   -- when HHA processed it
  
  -- AUD: Ledger sequencing
  ledger_sequence       BIGSERIAL,                              -- monotonic within subsystem
  subsystem             TEXT          NOT NULL DEFAULT 'hha'
);

COMMENT ON TABLE hardware_observations IS 'Canonical, immutable telemetry observations. The atomic evidence unit of the HHA. All higher-layer records (assessments, anomalies) reference these.';
COMMENT ON COLUMN hardware_observations.metric_name IS 'Canonical metric name from MetricRegistry. Examples: cpu.package_temp, gpu.hotspot_temp, mem.error_count, storage.smart_health_pct, cooling.cpu_fan_rpm.';
COMMENT ON COLUMN hardware_observations.confidence_score IS 'ECL confidence in this observation. Derived from source trust_tier, corroboration_count, cross-signal agreement, and observation recency.';
COMMENT ON COLUMN hardware_observations.raw_payload_ref IS 'Full raw output from the adapter for this metric. Retained for audit and re-interpretation.';

CREATE INDEX idx_obs_component_metric ON hardware_observations (component_id, metric_name, observed_at DESC);
CREATE INDEX idx_obs_observed_at ON hardware_observations (observed_at DESC);
CREATE INDEX idx_obs_metric_name ON hardware_observations (metric_name);
CREATE INDEX idx_obs_sampling_mode ON hardware_observations (sampling_mode);
CREATE INDEX idx_obs_confidence ON hardware_observations (confidence_score);
CREATE INDEX idx_obs_ledger_seq ON hardware_observations (ledger_sequence);

-- Recommended: partition by month for high-volume deployments
-- PARTITION BY RANGE (observed_at)


-- =============================================================================
-- TABLE 4: hardware_benchmark_runs
-- Tracks intentional active diagnostic/benchmark test sessions.
-- Parent record for benchmark-mode observations.
-- =============================================================================

CREATE TABLE hardware_benchmark_runs (
  -- SOV
  benchmark_run_id      UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- STD: Classification
  benchmark_type        benchmark_type NOT NULL,
  tool_name             TEXT          NOT NULL,                 -- e.g. 'sysbench', 'fio', 'memtester', 'nvidia-smi-stress'
  tool_version          TEXT,
  
  -- STD: Scope
  components_tested     UUID[]        NOT NULL,                 -- array of component_ids
  test_profile          JSONB         NOT NULL DEFAULT '{}',    -- test parameters: duration, threads, load_pct, etc.
  
  -- STD: Lifecycle
  status                TEXT          NOT NULL DEFAULT 'running'
                        CHECK (status IN ('running', 'completed', 'failed', 'interrupted', 'cancelled')),
  triggered_by          TEXT          NOT NULL DEFAULT 'operator',  -- 'operator' | 'mission_control' | 'policy'
  
  -- STD: Results
  pass_fail_status      pass_fail_status,                       -- null while running
  result_summary        JSONB         NOT NULL DEFAULT '{}',    -- scored result fields, benchmark-type-specific
  evidence_observation_ids UUID[],                              -- TelemetryObservation IDs collected during run
  
  -- ECL
  confidence_score      NUMERIC(4,3)                            -- overall run confidence
                        CHECK (confidence_score IS NULL OR (confidence_score >= 0 AND confidence_score <= 1)),
  
  -- AUD
  started_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
  ended_at              TIMESTAMPTZ,
  duration_sec          INTEGER GENERATED ALWAYS AS (
                          EXTRACT(EPOCH FROM (ended_at - started_at))::INTEGER
                        ) STORED,
  notes                 TEXT,
  
  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'hha'
);

COMMENT ON TABLE hardware_benchmark_runs IS 'Active diagnostic and benchmark test sessions. Parent of benchmark-mode observations. Tracks lifecycle from triggered to result.';
COMMENT ON COLUMN hardware_benchmark_runs.result_summary IS 'Benchmark-type-specific scored results. CPU: {score, multithread_score, vs_baseline_pct}. GPU: {score, fps, stability_pct}. Storage: {read_mbps, write_mbps, latency_ms}. Memory: {error_count, throughput_gbps}.';

CREATE INDEX idx_benchmark_type ON hardware_benchmark_runs (benchmark_type);
CREATE INDEX idx_benchmark_status ON hardware_benchmark_runs (status);
CREATE INDEX idx_benchmark_started ON hardware_benchmark_runs (started_at DESC);
CREATE INDEX idx_benchmark_pass_fail ON hardware_benchmark_runs (pass_fail_status);

-- Apply FK from observations to benchmark_runs (deferred to after table creation)
ALTER TABLE hardware_observations
  ADD CONSTRAINT fk_obs_benchmark_run
  FOREIGN KEY (benchmark_run_id) REFERENCES hardware_benchmark_runs (benchmark_run_id);


-- =============================================================================
-- TABLE 5: hardware_assessments
-- Synthesized health evaluations for components or the whole system.
-- These are the primary decision-grade health objects.
-- =============================================================================

CREATE TABLE hardware_assessments (
  -- SOV
  assessment_id         UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- SOV: Subject
  subject_type          TEXT          NOT NULL
                        CHECK (subject_type IN ('component', 'system', 'benchmark_run')),
  component_id          UUID          REFERENCES hardware_components (component_id),  -- null if subject_type = 'system'
  benchmark_run_id      UUID          REFERENCES hardware_benchmark_runs (benchmark_run_id),
  
  -- STD: Scores (all 0.0 – 1.0)
  health_score          NUMERIC(4,3)  NOT NULL
                        CHECK (health_score >= 0 AND health_score <= 1),
  thermal_score         NUMERIC(4,3)
                        CHECK (thermal_score IS NULL OR (thermal_score >= 0 AND thermal_score <= 1)),
  stability_score       NUMERIC(4,3)
                        CHECK (stability_score IS NULL OR (stability_score >= 0 AND stability_score <= 1)),
  performance_score     NUMERIC(4,3)
                        CHECK (performance_score IS NULL OR (performance_score >= 0 AND performance_score <= 1)),
  error_score           NUMERIC(4,3)
                        CHECK (error_score IS NULL OR (error_score >= 0 AND error_score <= 1)),
  trend_score           NUMERIC(4,3)
                        CHECK (trend_score IS NULL OR (trend_score >= 0 AND trend_score <= 1)),
  
  -- STD: Classification
  health_band           health_band   NOT NULL,
  trend_direction       trend_direction,
  
  -- ECL
  confidence_score      NUMERIC(4,3)  NOT NULL
                        CHECK (confidence_score >= 0 AND confidence_score <= 1),
  evidence_observation_ids UUID[]     NOT NULL DEFAULT '{}',    -- supporting TelemetryObservation IDs
  
  -- STD: Explanation (operator-facing)
  explanation           TEXT          NOT NULL,
  score_breakdown       JSONB         NOT NULL DEFAULT '{}',    -- detailed dimension scores and weights used
  recommended_actions   JSONB         NOT NULL DEFAULT '[]',    -- array of {action_type, description, urgency}
  
  -- AUD
  assessed_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
  assessment_window_start TIMESTAMPTZ,                          -- observation window used for this assessment
  assessment_window_end   TIMESTAMPTZ,
  policy_version        TEXT,                                   -- policy config version used
  
  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'hha'
);

COMMENT ON TABLE hardware_assessments IS 'Synthesized health evaluations. Component-level assessments roll up to system-level. Primary decision artifact for workload routing and operator alerts.';
COMMENT ON COLUMN hardware_assessments.evidence_observation_ids IS 'Array of TelemetryObservation IDs that contributed to this assessment. Required for ECL auditability.';
COMMENT ON COLUMN hardware_assessments.score_breakdown IS 'JSON showing per-dimension scores, weights, and contributing observations. Example: {thermal: {score: 0.82, weight: 0.30, key_obs: [...]}}.';
COMMENT ON COLUMN hardware_assessments.recommended_actions IS 'JSON array of recommendations. Example: [{action_type: "operator_action", description: "Check CPU cooling", urgency: "medium"}].';

CREATE INDEX idx_assessments_component ON hardware_assessments (component_id, assessed_at DESC);
CREATE INDEX idx_assessments_system ON hardware_assessments (subject_type, assessed_at DESC)
  WHERE subject_type = 'system';
CREATE INDEX idx_assessments_health_band ON hardware_assessments (health_band);
CREATE INDEX idx_assessments_assessed_at ON hardware_assessments (assessed_at DESC);


-- =============================================================================
-- TABLE 6: hardware_anomalies
-- Detected abnormal conditions relative to baseline or policy thresholds.
-- Input to incident formation. Immutable once created; status tracked separately.
-- =============================================================================

CREATE TABLE hardware_anomalies (
  -- SOV
  anomaly_id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- SOV: Subject
  component_id          UUID          NOT NULL REFERENCES hardware_components (component_id),
  
  -- STD: Classification
  anomaly_type          anomaly_type  NOT NULL,
  severity              severity      NOT NULL,
  
  -- STD: Evidence
  metric_name           TEXT,                                   -- primary metric triggering anomaly (if applicable)
  observed_value        NUMERIC(12,4),                          -- value that triggered the anomaly
  threshold_value       NUMERIC(12,4),                          -- policy threshold breached (if applicable)
  baseline_value        NUMERIC(12,4),                          -- baseline value for deviation anomalies
  deviation_pct         NUMERIC(7,2),                          -- % deviation from baseline
  
  supporting_observation_ids UUID[]   NOT NULL DEFAULT '{}',
  
  -- STD: Persistence tracking
  first_detected_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  last_observed_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
  detection_sample_count INTEGER      NOT NULL DEFAULT 1,       -- how many consecutive samples triggered this
  is_persistent         BOOLEAN       NOT NULL DEFAULT FALSE,   -- true once persistence_window is exceeded
  is_resolved           BOOLEAN       NOT NULL DEFAULT FALSE,
  resolved_at           TIMESTAMPTZ,
  
  -- STD: Interpretation
  suspected_causes      JSONB         NOT NULL DEFAULT '[]',    -- array of hypothesis strings
  detection_basis       TEXT          NOT NULL,                 -- human-readable rule description
  
  -- ECL
  confidence_score      NUMERIC(4,3)  NOT NULL
                        CHECK (confidence_score >= 0 AND confidence_score <= 1),
  
  -- STD: Incident linkage
  incident_id           UUID,                                   -- FK applied after incidents table created
  
  -- AUD
  detected_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
  policy_rule_id        TEXT,                                   -- which policy rule triggered this
  
  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'hha'
);

COMMENT ON TABLE hardware_anomalies IS 'Detected abnormal conditions. Created by AnomalyEngine from policy rule evaluation. Persistent anomalies escalate to HardwareIncidents.';
COMMENT ON COLUMN hardware_anomalies.is_persistent IS 'True when the anomaly has been sustained across the persistence window defined in policy config.';
COMMENT ON COLUMN hardware_anomalies.suspected_causes IS 'Hypothesized root causes generated by RecommendationEngine. Example: ["dust buildup in CPU cooler", "fan bearing degradation"].';

CREATE INDEX idx_anomalies_component ON hardware_anomalies (component_id, detected_at DESC);
CREATE INDEX idx_anomalies_type ON hardware_anomalies (anomaly_type);
CREATE INDEX idx_anomalies_severity ON hardware_anomalies (severity);
CREATE INDEX idx_anomalies_persistent ON hardware_anomalies (is_persistent) WHERE is_persistent = TRUE;
CREATE INDEX idx_anomalies_unresolved ON hardware_anomalies (is_resolved, detected_at DESC) WHERE is_resolved = FALSE;
CREATE INDEX idx_anomalies_incident ON hardware_anomalies (incident_id) WHERE incident_id IS NOT NULL;


-- =============================================================================
-- TABLE 7: hardware_incidents
-- Confirmed operational issues requiring tracking and resolution.
-- Formed from persistent or high-severity anomalies.
-- =============================================================================

CREATE TABLE hardware_incidents (
  -- SOV
  incident_id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- STD: Identity
  title                 TEXT          NOT NULL,
  description           TEXT          NOT NULL,
  
  -- STD: Classification
  severity              severity      NOT NULL,
  status                incident_status NOT NULL DEFAULT 'open',
  
  -- STD: Scope
  component_ids         UUID[]        NOT NULL,                 -- components involved
  anomaly_ids           UUID[]        NOT NULL DEFAULT '{}',    -- anomalies that triggered this incident
  evidence_observation_ids UUID[]     NOT NULL DEFAULT '{}',
  
  -- STD: Causal reasoning
  root_cause_hypothesis TEXT,                                   -- MCL or RecommendationEngine output
  suspected_causes      JSONB         NOT NULL DEFAULT '[]',
  
  -- STD: Resolution
  operator_actions_taken JSONB        NOT NULL DEFAULT '[]',    -- array of {action, performed_at, notes}
  resolution_notes      TEXT,
  maintenance_event_ids  UUID[]       NOT NULL DEFAULT '{}',    -- linked maintenance events
  
  -- AUD: Timeline
  opened_at             TIMESTAMPTZ   NOT NULL DEFAULT now(),
  last_activity_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
  resolved_at           TIMESTAMPTZ,
  
  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'hha'
);

COMMENT ON TABLE hardware_incidents IS 'Confirmed hardware incidents requiring tracking and operator action. Formed from persistent or high-severity anomalies. First-class memory objects.';
COMMENT ON COLUMN hardware_incidents.operator_actions_taken IS 'JSON array of documented operator actions. Example: [{action: "Cleaned dust filters", performed_at: "...", notes: "Heavy buildup found"}].';

-- Apply FK from anomalies to incidents
ALTER TABLE hardware_anomalies
  ADD CONSTRAINT fk_anomaly_incident
  FOREIGN KEY (incident_id) REFERENCES hardware_incidents (incident_id);

CREATE INDEX idx_incidents_status ON hardware_incidents (status);
CREATE INDEX idx_incidents_severity ON hardware_incidents (severity);
CREATE INDEX idx_incidents_opened ON hardware_incidents (opened_at DESC);
CREATE INDEX idx_incidents_open ON hardware_incidents (status, opened_at DESC)
  WHERE status = 'open';
CREATE INDEX idx_incidents_components ON hardware_incidents USING GIN (component_ids);


-- =============================================================================
-- TABLE 8: hardware_maintenance_events
-- Operator-recorded physical interventions.
-- First-class memory objects enabling before/after health comparison.
-- =============================================================================

CREATE TABLE hardware_maintenance_events (
  -- SOV
  maintenance_event_id  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- STD: Scope
  component_ids         UUID[]        NOT NULL,                 -- components affected
  incident_ids          UUID[]        NOT NULL DEFAULT '{}',    -- incidents this addresses
  
  -- STD: Classification
  maintenance_type      TEXT          NOT NULL,                 -- 'dust_cleaned' | 'thermal_paste' | 'fan_replaced' | 'driver_updated' | 'ram_reseated' | 'storage_replaced' | 'other'
  description           TEXT          NOT NULL,                 -- operator narrative
  
  -- STD: Before/after
  pre_maintenance_assessment_id UUID  REFERENCES hardware_assessments (assessment_id),
  post_maintenance_assessment_id UUID REFERENCES hardware_assessments (assessment_id),
  health_delta          NUMERIC(4,3),                           -- post_score - pre_score (computed on post-assessment)
  
  -- STD: Operator context
  performed_by          TEXT          NOT NULL DEFAULT 'operator',
  tools_used            TEXT[],
  parts_replaced        JSONB         NOT NULL DEFAULT '[]',    -- [{part_name, model, vendor}]
  notes                 TEXT,
  
  -- AUD
  performed_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  recorded_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
  
  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'hha'
);

COMMENT ON TABLE hardware_maintenance_events IS 'Operator-recorded physical interventions. Enables before/after health comparison and maintenance effectiveness tracking.';
COMMENT ON COLUMN hardware_maintenance_events.health_delta IS 'Computed as post_maintenance_health_score - pre_maintenance_health_score. Positive = improvement. Populated after post-maintenance assessment.';

CREATE INDEX idx_maintenance_components ON hardware_maintenance_events USING GIN (component_ids);
CREATE INDEX idx_maintenance_performed ON hardware_maintenance_events (performed_at DESC);
CREATE INDEX idx_maintenance_type ON hardware_maintenance_events (maintenance_type);


-- =============================================================================
-- TABLE 9: hardware_workload_fitness_profiles
-- Decision records for workload routing.
-- Consumed by Mission Control to determine local vs cloud routing.
-- =============================================================================

CREATE TABLE hardware_workload_fitness_profiles (
  -- SOV
  profile_id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- STD: Classification
  workload_class        workload_class NOT NULL,
  fit_status            fit_status    NOT NULL,
  
  -- STD: Evidence
  system_assessment_id  UUID          REFERENCES hardware_assessments (assessment_id),
  component_assessment_ids JSONB      NOT NULL DEFAULT '{}',    -- {component_id: assessment_id, ...}
  open_incident_ids     UUID[]        NOT NULL DEFAULT '{}',    -- incidents active at time of evaluation
  
  -- STD: Decision detail
  constraints           JSONB         NOT NULL DEFAULT '[]',    -- array of {constraint_type, description, severity}
  blocking_factors      JSONB         NOT NULL DEFAULT '[]',    -- factors that caused not_fit or constraints
  reasoning_summary     TEXT          NOT NULL,
  
  -- ECL
  confidence_score      NUMERIC(4,3)  NOT NULL
                        CHECK (confidence_score >= 0 AND confidence_score <= 1),
  
  -- STD: Cache validity
  assessed_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
  expires_at            TIMESTAMPTZ   NOT NULL,                 -- staleness TTL (default: now() + 30s)
  policy_version        TEXT,
  
  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'hha'
);

COMMENT ON TABLE hardware_workload_fitness_profiles IS 'Workload routing decision records. Consumed by Mission Control. Cached with TTL. Retained permanently for historical reasoning.';
COMMENT ON COLUMN hardware_workload_fitness_profiles.constraints IS 'JSON array of active constraints on a fit_with_constraints result. Example: [{constraint_type: "thermal", description: "GPU temp elevated, avoid sustained sessions > 30min", severity: "medium"}].';
COMMENT ON COLUMN hardware_workload_fitness_profiles.expires_at IS 'Cache expiry. Mission Control re-queries after this time. Default TTL: 30 seconds for active monitoring mode.';

CREATE INDEX idx_fitness_workload ON hardware_workload_fitness_profiles (workload_class, assessed_at DESC);
CREATE INDEX idx_fitness_status ON hardware_workload_fitness_profiles (fit_status);
CREATE INDEX idx_fitness_recent ON hardware_workload_fitness_profiles (workload_class, expires_at DESC);


-- =============================================================================
-- TABLE 10: hardware_baselines  (Phase 3)
-- Canonical expected operating envelopes per component per mode.
-- Required for baseline_deviation anomaly detection.
-- =============================================================================

CREATE TABLE hardware_baselines (
  -- SOV
  baseline_id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  component_id          UUID          NOT NULL REFERENCES hardware_components (component_id),
  
  -- STD: Classification
  baseline_type         TEXT          NOT NULL                  -- 'idle' | 'load' | 'benchmark'
                        CHECK (baseline_type IN ('idle', 'load', 'benchmark', 'thermal_stabilization')),
  
  -- STD: Baseline values
  metrics               JSONB         NOT NULL,                 -- {metric_name: {mean, p50, p95, p99, stddev}}
  sample_count          INTEGER       NOT NULL,
  sample_window_days    INTEGER       NOT NULL,
  
  -- STD: Validity
  is_current            BOOLEAN       NOT NULL DEFAULT TRUE,
  superseded_by         UUID          REFERENCES hardware_baselines (baseline_id),
  
  -- STD: Context
  established_after_maintenance_event_id UUID
    REFERENCES hardware_maintenance_events (maintenance_event_id),
  
  -- AUD
  established_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
  window_start          TIMESTAMPTZ   NOT NULL,
  window_end            TIMESTAMPTZ   NOT NULL,
  
  -- AUD: Ledger
  ledger_sequence       BIGSERIAL,
  subsystem             TEXT          NOT NULL DEFAULT 'hha'
);

COMMENT ON TABLE hardware_baselines IS 'Canonical expected operating envelopes per component per mode. Required for baseline_deviation anomaly class. Recalculated after maintenance events.';
COMMENT ON COLUMN hardware_baselines.metrics IS 'JSON statistical profile per metric. Example: {"cpu.package_temp": {"mean": 42.3, "p50": 41.0, "p95": 58.0, "p99": 67.0, "stddev": 4.2}}.';

CREATE INDEX idx_baselines_component ON hardware_baselines (component_id, baseline_type);
CREATE INDEX idx_baselines_current ON hardware_baselines (component_id, is_current)
  WHERE is_current = TRUE;


-- =============================================================================
-- TABLE 11: hardware_policy_profiles  (Phase 3)
-- Versioned policy config snapshots.
-- Allows retrospective understanding of which thresholds were active.
-- =============================================================================

CREATE TABLE hardware_policy_profiles (
  -- SOV
  policy_id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_version        TEXT          NOT NULL UNIQUE,          -- e.g. 'v0.1.0'
  
  -- STD
  policy_config         JSONB         NOT NULL,                 -- full policy YAML parsed to JSON
  description           TEXT,
  is_active             BOOLEAN       NOT NULL DEFAULT TRUE,
  
  -- AUD
  activated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  deactivated_at        TIMESTAMPTZ,
  created_at            TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE hardware_policy_profiles IS 'Versioned policy config snapshots. Allows anomalies and assessments to reference the exact policy active at assessment time.';

CREATE INDEX idx_policy_active ON hardware_policy_profiles (is_active) WHERE is_active = TRUE;


-- =============================================================================
-- UTILITY VIEWS
-- =============================================================================

-- Current system health snapshot
CREATE VIEW vw_current_system_health AS
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

COMMENT ON VIEW vw_current_system_health IS 'Most recent system-level health assessment. Primary source for Mission Control pre-flight checks.';


-- Current component health cards
CREATE VIEW vw_current_component_health AS
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

COMMENT ON VIEW vw_current_component_health IS 'Most recent health assessment per component. Used by XHive component cards.';


-- Open incidents summary
CREATE VIEW vw_open_incidents AS
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
    WHEN 'high'     THEN 2
    WHEN 'medium'   THEN 3
    WHEN 'low'      THEN 4
    ELSE 5
  END,
  i.opened_at ASC;

COMMENT ON VIEW vw_open_incidents IS 'Active incidents ordered by severity then age. Primary source for XHive incident panel and Mission Control fitness evaluation.';


-- Workload fitness latest per class
CREATE VIEW vw_current_workload_fitness AS
SELECT DISTINCT ON (f.workload_class)
  f.profile_id,
  f.workload_class,
  f.fit_status,
  f.constraints,
  f.blocking_factors,
  f.reasoning_summary,
  f.confidence_score,
  f.assessed_at,
  f.expires_at,
  f.expires_at < now() AS is_stale
FROM hardware_workload_fitness_profiles f
ORDER BY f.workload_class, f.assessed_at DESC;

COMMENT ON VIEW vw_current_workload_fitness IS 'Most recent fitness profile per workload class. is_stale = TRUE when expires_at has passed; Mission Control should re-query.';


-- Recent benchmark history
CREATE VIEW vw_recent_benchmarks AS
SELECT
  br.benchmark_run_id,
  br.benchmark_type,
  br.tool_name,
  br.status,
  br.pass_fail_status,
  br.components_tested,
  br.result_summary,
  br.confidence_score,
  br.started_at,
  br.duration_sec,
  br.triggered_by
FROM hardware_benchmark_runs br
ORDER BY br.started_at DESC
LIMIT 50;

COMMENT ON VIEW vw_recent_benchmarks IS 'Last 50 benchmark runs. Used by XHive diagnostics history view.';


-- =============================================================================
-- CORE QUERY PATTERNS
-- =============================================================================

-- Get workload fitness for Mission Control
-- SELECT * FROM vw_current_workload_fitness WHERE workload_class = 'llm_14b';

-- Check if fitness profile is stale and needs refresh
-- SELECT is_stale FROM vw_current_workload_fitness WHERE workload_class = 'llm_14b';

-- Get 7-day temperature trend for GPU
-- SELECT metric_value, observed_at
-- FROM hardware_observations
-- WHERE component_id = '<gpu_id>'
--   AND metric_name = 'gpu.core_temp'
--   AND observed_at > now() - interval '7 days'
-- ORDER BY observed_at;

-- Find anomalies that have not been linked to an incident
-- SELECT * FROM hardware_anomalies
-- WHERE is_persistent = TRUE AND incident_id IS NULL AND is_resolved = FALSE
-- ORDER BY severity, detected_at;

-- Before/after maintenance comparison
-- SELECT
--   pre.health_score  AS before_score,
--   post.health_score AS after_score,
--   me.maintenance_type,
--   me.performed_at
-- FROM hardware_maintenance_events me
-- LEFT JOIN hardware_assessments pre  ON pre.assessment_id  = me.pre_maintenance_assessment_id
-- LEFT JOIN hardware_assessments post ON post.assessment_id = me.post_maintenance_assessment_id
-- WHERE me.component_ids @> ARRAY['<component_id>']::UUID[];

-- How many times was llm_14b not_fit in the last 7 days?
-- SELECT COUNT(*) FROM hardware_workload_fitness_profiles
-- WHERE workload_class = 'llm_14b'
--   AND fit_status = 'not_fit'
--   AND assessed_at > now() - interval '7 days';


-- =============================================================================
-- INDEXES SUMMARY
-- =============================================================================
--
-- Primary access patterns and their supporting indexes:
--
-- Mission Control fitness query   → idx_fitness_recent (workload_class, expires_at)
-- XHive component cards           → idx_assessments_component (component_id, assessed_at)
-- XHive incident panel            → idx_incidents_open (status, opened_at)
-- Anomaly escalation check        → idx_anomalies_persistent, idx_anomalies_unresolved
-- Telemetry trend queries         → idx_obs_component_metric (component_id, metric_name, observed_at)
-- Benchmark history               → idx_benchmark_started
-- Ledger sequencing               → idx_obs_ledger_seq, per-table ledger_sequence
--
-- =============================================================================


-- =============================================================================
-- RETENTION NOTES
-- =============================================================================
--
-- hardware_observations: High volume. Recommend 90-day active retention.
--   Archive cold data to long-term store after 90 days.
--   Partitioning by month recommended once daily volume exceeds 100K rows.
--
-- hardware_assessments: Retain 365 days active. Archive thereafter.
--
-- hardware_anomalies / incidents / maintenance_events: Retain indefinitely.
--   These are canonical memory objects — permanent ledger records.
--
-- hardware_workload_fitness_profiles: Retain 90 days for trend queries.
--
-- hardware_baselines: Retain current + 3 prior versions per component per type.
--
-- =============================================================================


-- =============================================================================
-- SCHEMA VERSION RECORD
-- =============================================================================

CREATE TABLE IF NOT EXISTS hha_schema_versions (
  version       TEXT        PRIMARY KEY,
  applied_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  description   TEXT
);

INSERT INTO hha_schema_versions (version, description)
VALUES ('0.1.0', 'Initial HHA canonical schema — all core tables, enums, views, indexes');

-- =============================================================================
-- END: HHA Canonical Schema v0.1
-- Codessa Hardware Health Agent
-- =============================================================================
