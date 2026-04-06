# Codessa Health Adapter — Production Architecture Spec v1.0

## Status
Draft for implementation

## Purpose
Turn low-level workstation, runtime, and toolchain health failures into canonical, confidence-scored, policy-aware operational signals that Codessa can observe, reason about, and act on.

This adapter exists to prevent a class of silent infrastructure failures where capacity exists somewhere in the system, but execution fails because the active path, cache, temp location, mount, or policy points to the wrong place.

The npm `ENOSPC` incident is the reference case:
- project drive had adequate free space
- alternate drive had ample free space
- effective npm cache path pointed to a tiny exhausted partition
- install failed despite overall system capacity being sufficient

The Health Adapter converts these conditions into structured observations, anomaly signals, remediations, and routeable system actions.

---

## Strategic Role in Codessa

The Health Adapter is not a generic monitoring agent.
It is a Codessa-native operational cognition adapter.

It sits at the boundary between:
- local machine reality
- toolchain execution state
- confidence and governance logic
- Mission Control routing decisions

It answers:
- what resource or path is actually failing?
- is the failure local, environmental, configurational, or policy-induced?
- does the system have enough alternate capacity to self-heal?
- how trustworthy is the diagnosis?
- should Codessa warn, remediate, reroute, or halt?

It does not answer:
- broader business workflow prioritization
- deep package ecosystem debugging unrelated to health state
- arbitrary command execution without policy approval

---

## Mission

Provide deterministic health sensing, diagnosis, and remediation planning for workstation, runtime, storage, cache, temp-path, dependency-install, and local execution environments.

Translate health events into canonical Codessa objects that can be:
- stored in the Memory Cortex
- confidence-scored by ECL
- observed and adjudicated by MCL
- surfaced through XHive
- used by Mission Control for route and policy decisions

---

## Primary Use Cases

1. **Disk exhaustion with misrouted cache/temp paths**
2. **Dependency install failures** (`npm`, `pnpm`, `yarn`, `pip`, `uv`, `cargo`, etc.)
3. **Corrupt or oversized local caches**
4. **Broken environment overrides**
5. **Mismatched workspace/runtime path assumptions**
6. **Insufficient workspace headroom before planned execution**
7. **Drive-level risk scoring for local-first execution routing**
8. **Health-gated build/deploy/test execution**
9. **Autonomous remediation recommendation or execution**
10. **Operational postmortem trace generation**

---

## Product Doctrine

### Core doctrine
**Codessa must distinguish capacity failure from path failure.**

A system is not truly “out of space” if required writes are merely pointed at an exhausted location while alternate approved capacity exists elsewhere.

### Operational doctrine
- never trust nominal free space alone
- always inspect effective write path
- always distinguish project drive, temp drive, cache drive, and target output drive
- always capture both configured path and effective path
- treat environment-variable overrides as first-class causal signals
- remediations must be explicit, reversible, and policy-checked

---

## Placement in the Codessa Ecosystem

### Mission Control Gateway
Receives health requests, validates auth/policy, routes to Health Adapter, records trace IDs, returns structured results.

### Memory Cortex
Stores health observations, environment snapshots, incidents, remediations, and outcome links.

### ECL
Scores diagnosis confidence, remediation confidence, path attribution confidence, and anomaly severity confidence.

### MCL
Detects contradictions, repeated failures, drift, and systemic patterns across sessions and devices.

### XHive
Operational dashboard for device health, risk heatmaps, incidents, and remediation status.

### Agora
Can invoke health explanation mode for conversational troubleshooting and operator-guided recovery.

---

## System Boundary

### In scope
- local filesystem health
- active cache locations
- temp directories
- workspace sizing
- environment overrides
- toolchain config resolution
- deterministic cleanup plans
- safe remediations
- verification loops
- artifact generation

### Out of scope
- kernel-level disk repair
- partition resizing
- unsafe registry surgery without approval
- arbitrary destructive cleanup outside approved paths
- remote enterprise observability replacement

---

## High-Level Architecture

```text
User / Agent / Automation
        |
        v
Mission Control Gateway
        |
        v
Health Adapter Orchestrator
  |        |         |         |
  |        |         |         |
  v        v         v         v
Path    Resource   Toolchain  Remediation
Probe   Probe      Resolver   Planner
  |        |         |         |
  +--------+----+----+---------+
               |
               v
Diagnosis Engine
               |
        +------+------+
        |             |
        v             v
    ECL Scoring     Policy Check
        |             |
        +------+------+
               |
               v
        Action Executor
               |
               v
     Verification + Artifact Writer
               |
               v
Canonical Ledger / Memory Cortex
```

---

## Adapter Components

## 1. Health Adapter Orchestrator
Coordinates the run.

Responsibilities:
- accept typed health request
- generate trace correlation IDs
- invoke probes in deterministic order
- assemble evidence graph
- call diagnosis engine
- call ECL scoring
- apply policy gates
- optionally execute remediations
- verify post-state
- emit artifacts

### Deterministic run phases
1. Context resolution
2. Path resolution
3. Resource measurement
4. Toolchain config resolution
5. Failure classification
6. Remediation planning
7. Policy evaluation
8. Action execution
9. Verification
10. Canonical writeback

---

## 2. Path Probe
Determines where writes actually go.

Collects:
- project root path
- project drive / mount
- effective cache path
- effective temp path
- tool-specific config paths
- env-var overrides
- local config files (`.npmrc`, `.env`, tool config files)
- symlink / junction resolution
- writable path test results

### Output example
- project path: `C:\Projects\system_health`
- project drive: `C:`
- effective npm cache: `D:\Temp\npm`
- configured global npm cache: `E:\npm-cache`
- env override source: `npm_config_cache`
- effective temp path: `D:\Temp`
- path mismatch detected: true

---

## 3. Resource Probe
Measures available capacity and local pressure.

Collects:
- free/used bytes by drive
- filesystem type
- reserved/system partition markers
- project size
- cache size
- temp size
- lockfile presence
- node_modules size
- inode / file count pressure where available
- threshold compliance against policy

### Derived metrics
- project_headroom_ratio
- cache_drive_headroom_ratio
- temp_drive_headroom_ratio
- safe_install_capacity_estimate
- drive_risk_score

---

## 4. Toolchain Resolver
Builds the effective config graph for target toolchains.

### Initial targets
- npm
- pnpm
- yarn
- pip
- uv
- cargo
- docker build cache

### npm-specific resolution
Order of precedence should be modeled explicitly:
1. environment overrides
2. project `.npmrc`
3. user `.npmrc`
4. global npmrc
5. builtin default

Must emit both:
- declared config graph
- effective config graph

This distinction is critical for diagnosing cases where the operator believes a value is set correctly but the runtime uses something else.

---

## 5. Diagnosis Engine
Transforms probe evidence into typed failure diagnoses.

### Core diagnosis categories
- `disk_exhaustion_absolute`
- `disk_exhaustion_effective_path`
- `cache_path_misrouted`
- `temp_path_misrouted`
- `workspace_oversized`
- `cache_corruption_or_bloat`
- `install_artifact_conflict`
- `env_override_conflict`
- `config_shadowing`
- `unsafe_cleanup_required`
- `headroom_below_policy`
- `unknown_health_failure`

### Reference classification for the npm case
Primary diagnosis:
- `cache_path_misrouted`

Secondary diagnoses:
- `disk_exhaustion_effective_path`
- `env_override_conflict`
- `temp_path_misrouted`

### Causality model
The engine should separate:
- symptom
- immediate cause
- root cause
- contributing factors
- available recovery paths

Example:
- symptom: `npm install` returns `ENOSPC`
- immediate cause: write to `D:\Temp\npm` failed
- root cause: `npm_config_cache` env override forced cache to exhausted drive
- contributing factor: D drive is tiny reserved partition
- recovery path: move cache to `E:\npm-cache`

---

## 6. ECL Integration
Each diagnosis and remediation plan receives a confidence score with component breakdown.

### ECL-scored subjects
- path attribution
- root cause diagnosis
- remediation suitability
- verification success
- recurrence risk

### Suggested scoring dimensions
- configuration agreement
- filesystem evidence sufficiency
- path resolution consistency
- temporal freshness
- execution verification strength
- contradiction penalty

### Example score payload
```json
{
  "subject": "cache_path_misrouted",
  "score": 0.96,
  "components": {
    "config_agreement": 0.98,
    "filesystem_evidence": 1.0,
    "path_consistency": 0.95,
    "freshness": 0.99,
    "verification": 0.91
  }
}
```

---

## 7. Policy Layer
Controls what the adapter may do automatically.

### Policy classes
- observe-only
- recommend-only
- safe-auto-remediate
- guarded-auto-remediate
- halt-and-escalate

### Safe actions
- inspect config
- measure usage
- clean tool cache
- delete project-local `node_modules`
- delete generated lockfiles when allowed by policy
- relocate cache to approved drive
- regenerate install log

### Guarded actions
- clear temp folders outside project scope
- modify persistent environment variables
- remove shared caches
- change user/global config

### Forbidden by default
- repartition disks
- clear arbitrary user directories
- alter unrelated system paths
- execute shell actions outside allowlist

---

## 8. Remediation Planner
Builds an ordered, reversible remediation plan.

### Remediation plan structure
Each step contains:
- step ID
- action type
- target path
- rationale
- risk level
- reversibility
- expected freed bytes
- approval requirement
- verification check

### Example plan
1. record baseline disk/path snapshot
2. clean npm cache
3. remove project `node_modules`
4. remove stale lockfile
5. prune approved temp directories
6. rebind cache to approved path on high-capacity drive
7. verify free space thresholds
8. retry install
9. record outcome and artifacts

### Planner principles
- prefer minimal-impact actions first
- prefer relocation over destructive deletion when capacity exists elsewhere
- verify after each major step if high risk
- stop when policy threshold is satisfied

---

## 9. Action Executor
Runs approved remediations through a tightly-scoped execution interface.

### Requirements
- typed command actions, not raw arbitrary shell text
- allowlisted operation set
- dry-run mode
- rollback metadata where applicable
- captured stdout/stderr
- exit code normalization
- timeout handling
- idempotency markers

### Execution modes
- dry_run
- manual_guided
- auto_safe
- auto_guarded

---

## 10. Verification Engine
Confirms whether remediation actually resolved the failure.

### Verification checks
- effective config path updated
- required drive free space ≥ policy threshold
- target command succeeds
- exit code normalized to success
- expected artifact recreated
- no new conflicting override introduced

### Example success criteria for npm incident
- effective cache path != `D:\Temp\npm`
- effective cache path == `E:\npm-cache`
- project drive free space ≥ 2 GB
- cache drive free space ≥ 2 GB
- `npm install` exit code == 0

---

## 11. Artifact Writer
Produces human- and machine-consumable deliverables.

### Artifact types
- before snapshot
- after snapshot
- diagnosis report
- remediation plan
- action log
- verification report
- success/failure install log
- incident summary

### Default export formats
- JSON for machines
- Markdown for operators
- optional HTML/PDF later

---

## Canonical Object Model

## Core CMOs

### `health_observation`
Raw measured fact.

Fields:
- `id`
- `device_id`
- `workspace_id`
- `timestamp`
- `source_adapter`
- `observation_type`
- `path`
- `drive`
- `metric_name`
- `metric_value`
- `unit`
- `evidence_ref[]`

### `health_diagnosis`
Normalized conclusion about failure state.

Fields:
- `id`
- `trace_id`
- `primary_diagnosis`
- `secondary_diagnoses[]`
- `symptom`
- `immediate_cause`
- `root_cause`
- `contributing_factors[]`
- `impact_scope`
- `severity`
- `confidence_ref`
- `status`

### `health_remediation_plan`
Ordered action plan.

Fields:
- `id`
- `trace_id`
- `plan_steps[]`
- `policy_mode`
- `requires_approval`
- `estimated_risk`
- `estimated_recovery_probability`
- `confidence_ref`

### `health_action_event`
Executed step.

Fields:
- `id`
- `trace_id`
- `action_type`
- `target`
- `started_at`
- `ended_at`
- `result_status`
- `exit_code`
- `stdout_ref`
- `stderr_ref`
- `artifact_refs[]`

### `health_verification_result`
Outcome validation.

Fields:
- `id`
- `trace_id`
- `checks[]`
- `overall_pass`
- `verification_confidence_ref`
- `followup_required`

### `health_incident`
Human-meaningful operational incident object.

Fields:
- `id`
- `title`
- `incident_type`
- `severity`
- `first_seen_at`
- `resolved_at`
- `device_id`
- `workspace_id`
- `primary_diagnosis_ref`
- `action_refs[]`
- `outcome_ref`

---

## API Surface

## 1. Run diagnosis
`POST /v1/health/diagnose`

Request:
```json
{
  "device_id": "dev_nexus_01",
  "workspace_id": "ws_system_health",
  "target_toolchain": "npm",
  "project_path": "C:\\Projects\\system_health",
  "symptom": "install_failed_enospc",
  "mode": "diagnose_and_remediate_safe"
}
```

Response:
```json
{
  "trace_id": "trc_...",
  "status": "completed",
  "primary_diagnosis": "cache_path_misrouted",
  "severity": "high",
  "confidence": 0.96,
  "recommended_action": "move_cache_to_approved_drive",
  "artifacts": []
}
```

## 2. Plan only
`POST /v1/health/plan`

## 3. Execute approved plan
`POST /v1/health/execute`

## 4. Verify state
`POST /v1/health/verify`

## 5. Read incident
`GET /v1/health/incidents/{incident_id}`

## 6. Read device fitness
`GET /v1/health/devices/{device_id}/fitness`

---

## Device Fitness Model

Mission Control needs a compact runtime fitness view.

### Output fields
- storage_fitness
- temp_path_fitness
- cache_path_fitness
- install_fitness
- workspace_headroom_fitness
- overall_fitness
- blocking_conditions[]
- stale_after

### Routing usage
Mission Control may use this to decide:
- can local build proceed?
- should work be shifted to cloud?
- should health remediation run first?
- should user be warned before execution?

---

## Anomaly Rules v1

1. **Effective path on low-capacity reserved partition**
2. **Configured path != effective path**
3. **Environment override shadows safer global config**
4. **Target write drive below policy threshold**
5. **Repeated `ENOSPC` despite adequate alternate capacity**
6. **Tool cache on system-reserved drive**
7. **Temp and cache co-located on exhausted drive**
8. **High-growth cache with low verification success**

Each anomaly should emit:
- anomaly ID
- title
- severity
- evidence refs
- suggested remediation
- confidence score

---

## Policy Thresholds v1

### Default thresholds
- critical_free_space_floor_bytes: 2 GB
- warning_free_space_floor_bytes: 5 GB
- reserved_partition_do_not_use_bytes: < 1 GB total size
- temp_cleanup_max_scope: approved temp roots only
- cache_relocation_requires_approved_target: true
- persistent_env_mutation: guarded

### npm install fitness thresholds
- project drive free space ≥ 2 GB
- effective cache drive free space ≥ 2 GB
- effective temp drive free space ≥ 2 GB or same approved drive as cache/project

---

## Security and Governance

### Requirements
- every action tied to trace ID
- immutable action log
- policy decision recorded separately from execution result
- explicit source attribution for config values
- operator-visible diff for persistent config changes
- no silent destructive cleanup outside approved roots

### Auditability
The adapter must preserve:
- before state
- effective path graph
- diagnosis rationale
- approved action plan
- executed action outputs
- after state
- final verification

---

## Observability

### Metrics
- diagnosis_runs_total
- remediation_runs_total
- remediation_success_rate
- false_positive_rate_estimate
- path_mismatch_incidents_total
- disk_exhaustion_incidents_total
- average_recovery_time
- auto_remediation_rate
- verification_failure_rate

### Logs
Structured logs should include:
- trace_id
- device_id
- workspace_id
- toolchain
- diagnosis_code
- severity
- selected_action
- exit_code
- verification_pass

---

## Reference Incident Mapping

## Incident
`npm install ENOSPC despite available overall system capacity`

### Observed facts
- project on `C:`
- project drive had > 7 GB free
- effective npm cache on `D:\Temp\npm`
- `D:` had 0 bytes free
- global npm config pointed to `E:\npm-cache`
- env override shadowed safe config
- `E:` had > 900 GB free

### Diagnosis
- primary: `cache_path_misrouted`
- secondary: `env_override_conflict`, `disk_exhaustion_effective_path`

### Remediation
- clear cache
- prune temp
- remove install artifacts
- persist cache to `E:\npm-cache`
- verify free space
- rerun install

### Verification
- effective cache path updated to `E:\npm-cache`
- install exit code `0`

This incident should be preserved as a gold test fixture.

---

## Implementation Plan

## Phase P0 — Single-incident vertical slice
Build only enough to reproduce and resolve the npm ENOSPC case.

Deliver:
- typed health request/response models
- Windows path/resource probes
- npm config resolver
- diagnosis engine for 5 core categories
- safe remediation planner
- verification loop
- artifact writer
- canonical ledger writeback

### Acceptance criteria
- detects cache path on exhausted drive
- identifies env override shadowing global config
- recommends or executes approved relocation
- verifies ≥ 2 GB threshold on relevant drive(s)
- confirms `npm install` exit code success when recoverable

## Phase P1 — Multi-toolchain health
Add `pnpm`, `yarn`, `pip`, `uv`, `cargo`.

## Phase P2 — Device fitness and routing integration
Expose health fitness to Mission Control.

## Phase P3 — XHive operational dashboard
Fleet/device view, anomaly clustering, recurrence patterns.

## Phase P4 — Reflex engine
Policy-driven self-healing under guarded mode.

---

## Suggested Service Layout

```text
health_adapter/
  api/
    routes.py
    schemas.py
  domain/
    models.py
    diagnosis.py
    planner.py
    policy.py
    verification.py
  probes/
    filesystem_probe.py
    path_probe.py
    env_probe.py
    npm_probe.py
    temp_probe.py
  executors/
    action_executor.py
  writers/
    artifact_writer.py
    ledger_writer.py
  scoring/
    ecl_bridge.py
  tests/
    fixtures/
      npm_enospc_misrouted_cache/
```

---

## Recommended ADRs

1. **ADR-HA-001** Canonical health events are ledgered as first-class CMOs
2. **ADR-HA-002** Effective path graph is authoritative over nominal config declarations
3. **ADR-HA-003** Environment overrides are first-class causal evidence
4. **ADR-HA-004** Relocation is preferred over deletion when approved capacity exists
5. **ADR-HA-005** Health fitness may gate local execution routing
6. **ADR-HA-006** Auto-remediation requires policy mode and verification loop

---

## Production Readiness Checklist

- typed request/response contracts
- deterministic probe order
- allowlisted action executor
- idempotent cleanup semantics
- audit-grade artifact generation
- confidence scoring bridge
- policy enforcement
- verification loop
- structured logging
- test fixtures for real incidents

---

## Bottom Line

The Codessa Health Adapter should become the operational cognition layer that detects when infrastructure failure is not true capacity exhaustion, but a misalignment between effective write paths, environment overrides, and available system resources.

This makes Codessa materially stronger than ordinary local tooling:
not just because it can observe failure,
but because it can explain causality, score confidence, choose safe recovery paths, verify outcome, and feed the result back into the system’s memory and routing substrate.

