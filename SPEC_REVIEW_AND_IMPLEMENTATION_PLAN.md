# Spec Review and Implementation Plan

## Latest authoritative decisions

- The system comprises two compatible subsystems: HHA v0.1 (hardware telemetry/scoring) and Health Adapter v1.0 (diagnosis/remediation lifecycle). The latest decision is to unify them at the data layer via a single schema pack.
- The canonical storage model evolves from `Observation → Assessment → Anomaly → Incident` into a dual-chain model that adds `Diagnosis → Remediation Plan → Action → Verification` while preserving the original HHA chain.
- ECL/MCL compatibility remains mandatory: all decision-grade objects carry confidence and evidence lineage.

## Document inventory reviewed

- [ADR001](file:///c:/Projects/hha/ADR001)
- [codessa_health_adapter_spec_v_1_0.md](file:///c:/Projects/hha/codessa_health_adapter_spec_v_1_0.md)
- [Codessa_Health_Schema_Pack_v1.0.sql](file:///c:/Projects/hha/Codessa_Health_Schema_Pack_v1.0.sql)
- [HHA_Architecture_Spec_v0.1.md](file:///c:/Projects/hha/HHA_Architecture_Spec_v0.1.md)
- [HHA_Canonical_Schema_v0.1.sql](file:///c:/Projects/hha/HHA_Canonical_Schema_v0.1.sql)

## Confirmed schema changes (v1.0 pack vs HHA v0.1)

- Adds Health Adapter CMOs: `health_observations`, `health_diagnoses`, `health_remediation_plans`, `health_action_events`, `health_verification_results`, `health_incidents`, `health_artifacts`, `device_health_fitness_profiles`.
- Extends HHA records for linkage:
  - `hardware_anomalies.diagnosis_id`
  - `hardware_incidents.primary_diagnosis_id`, `hardware_incidents.verification_result_id`, `hardware_incidents.remediation_plan_ids`
  - `hardware_workload_fitness_profiles.health_blockers`
- Extends enums to cover Health Adapter concepts:
  - `anomaly_type` gains path/capacity/override-related anomaly codes
  - `adapter_type` gains probe/resolver types
  - `workload_class` gains `local_build`, `dependency_install`, `workspace_repair`
  - Adds new enums: `diagnosis_category`, `diagnosis_status`, `policy_mode`, `execution_mode`, `action_result_status`, `artifact_type`, `verification_status`, `observation_kind`

## Discrepancies and resolutions

- ADR001 uses simplified table sketches.
  - Resolution: treat [Codessa_Health_Schema_Pack_v1.0.sql](file:///c:/Projects/hha/Codessa_Health_Schema_Pack_v1.0.sql) as the canonical SQL because it is the only document that fully specifies types, indexes, and forward FKs.
- Naming mismatch: ADR001 proposes `verification_id`; schema pack uses `verification_result_id`.
  - Resolution: keep `verification_result_id` to match `health_verification_results.verification_result_id` and maintain referential clarity.
- Subsystem default for new Health Adapter CMOs: ADR001 sketches default `subsystem='hha'`, while schema pack uses `subsystem='health_adapter'`.
  - Resolution: keep `health_adapter` to preserve subsystem separation while keeping cross-links via FKs.
- Migration safety for enums: `CREATE TYPE` guarded blocks alone do not update existing enums.
  - Resolution: implement `ALTER TYPE ... ADD VALUE IF NOT EXISTS` blocks for extended enums.

## Implementation plan (synchronized to latest specs)

### Phase 1: Lock database layer (schema pack)

- Maintain `HHA_Canonical_Schema_v0.1.sql` as historical baseline.
- Treat `Codessa_Health_Schema_Pack_v1.0.sql` as the canonical install target.
- Provide migration-safe Supabase migrations:
  - `supabase/migrations/0001_codessa_health_schema_pack_v1_0.sql` creates/extends types and tables.
  - `supabase/migrations/0002_seed_fixture_npm_enospc.sql` installs the reference ENOSPC fixture.

### Phase 2: Lock adapter requirements into implementation contracts

- Adopt the Health Adapter run phases as a deterministic pipeline in code: resolve context → resolve paths → measure resources → resolve toolchain config → classify failure → plan remediation → policy gate → execute (optional) → verify → ledger writeback.
- Enforce governance requirements:
  - Every output tied to `trace_id`.
  - Action execution uses typed commands, not arbitrary shell strings.
  - Verification results are written even when remediation is not executed.

### Phase 3: Backward compatibility

- Preserve all v0.1 HHA tables and enums; only add new enum values and additive columns.
- Keep existing view names; extend view payloads additively.

## Verification plan

- SQL-level verification:
  - Applying migrations in order should succeed on a clean database.
  - Applying migrations on a v0.1 database should succeed without destructive changes.
- Behavioral verification:
  - The seed fixture should materialize one end-to-end trace across `health_*` tables and one linked `hardware_anomalies` row.

