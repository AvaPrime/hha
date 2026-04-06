# Mission Control ↔ Health Adapter Integration Contract v1.0

## Status
Draft for implementation

## Purpose
Define the authoritative runtime contract between Mission Control Gateway and the Codessa Health Adapter so that health sensing, diagnosis, remediation planning, execution, verification, and device fitness can be invoked deterministically, audited cleanly, and routed safely.

This contract turns the Health Adapter from an architecture concept into an immediately implementable system boundary.

---

## Contract Doctrine

### Core rule
Mission Control is the authoritative runtime entry point.
Health Adapter is the authoritative health diagnosis and remediation subsystem.

Mission Control may:
- authenticate
- authorize
- trace
- route
- normalize errors
- enforce policy envelopes
- cache selected fitness outputs
- record request/response events

Health Adapter may:
- resolve effective paths
- inspect config layers
- measure capacity and pressure
- diagnose failure classes
- score confidence inputs for ECL
- generate remediation plans
- execute approved safe or guarded actions when authorized
- verify post-state
- emit health artifacts and canonical health objects

Health Adapter may not:
- bypass Mission Control policy gating
- execute actions outside the received execution mode
- mutate unrelated system state
- return untyped shell-only responses

---

## Strategic Outcome

This contract ensures Codessa can answer, in a single typed boundary:
- what failed
- where it failed
- why it failed
- whether it is safe to continue
- whether local execution should proceed
- whether automatic remediation is permitted
- whether the result is trustworthy enough to route downstream action

---

## Interaction Model

```text
Client / Agent / Automation
          |
          v
Mission Control Gateway
  - auth
  - policy envelope
  - tracing
  - rate limits
  - error normalization
          |
          v
Health Adapter API
  - diagnose
  - plan
  - execute
  - verify
  - fitness
          |
          v
Health Probes / Diagnosis / Planner / Executor / Verification
          |
          v
Artifacts + Canonical Ledger + ECL Inputs
```

---

## Boundary Principles

1. **Typed in, typed out**
   No free-form shell contract between Mission Control and Health Adapter.

2. **Trace-first**
   Every request carries a canonical trace identity.

3. **Policy-envelope first**
   Mission Control specifies the maximum authority level for this run.

4. **Evidence before action**
   Health Adapter must diagnose before execution unless explicitly running a previously approved plan.

5. **Verification required**
   Action success is not sufficient; post-state verification is required for completion.

6. **Fitness is compact**
   Mission Control consumes a compact health fitness summary, not the entire probe graph, for routing decisions.

---

## Versioning

### Contract identifier
- `contract_name`: `mission_control.health_adapter`
- `contract_version`: `1.0`
- `schema_version`: `1.0`

### Compatibility rule
- additive fields allowed in minor revisions
- enum expansion allowed only when documented
- breaking field or semantic changes require `2.x`

All requests and responses must include:
- `contract_name`
- `contract_version`
- `schema_version`

---

## Execution Modes

Mission Control controls maximum execution authority via `execution_mode`.

### Allowed values
- `observe_only`
- `diagnose_only`
- `plan_only`
- `diagnose_and_plan`
- `diagnose_and_remediate_safe`
- `diagnose_and_remediate_guarded`
- `execute_approved_plan`
- `verify_only`
- `fitness_only`

### Semantics
- `observe_only`: collect facts only, no diagnosis required beyond raw observations
- `diagnose_only`: return diagnosis, no plan execution
- `plan_only`: generate plan from provided symptom/context, no actions
- `diagnose_and_plan`: diagnose and produce plan
- `diagnose_and_remediate_safe`: may execute only safe actions
- `diagnose_and_remediate_guarded`: may execute safe + guarded actions if policy permits
- `execute_approved_plan`: execute a plan already approved or previously generated
- `verify_only`: check current system against expected conditions
- `fitness_only`: return compact fitness summary for routing

---

## Policy Envelope

Mission Control sends an explicit policy envelope with every mutating-capable request.

```json
{
  "policy_envelope": {
    "policy_mode": "safe_auto_remediate",
    "allow_persistent_config_changes": true,
    "allow_env_var_mutation": true,
    "allow_cache_cleanup": true,
    "allow_temp_cleanup": true,
    "allow_project_install_artifact_removal": true,
    "allow_cross_drive_cache_relocation": true,
    "allow_guarded_actions": false,
    "approved_target_roots": [
      "C:\\Projects",
      "C:\\Temp",
      "E:\\npm-cache"
    ],
    "min_free_space_bytes": 2147483648,
    "max_temp_cleanup_scope": "approved_roots_only"
  }
}
```

### Policy modes
- `observe_only`
- `recommend_only`
- `safe_auto_remediate`
- `guarded_auto_remediate`
- `halt_and_escalate`

### Rule
Health Adapter must never exceed the received envelope even if it has internal capability to do so.

---

## Authentication and Trust Context

Mission Control remains responsible for upstream authentication and trust admission.

Health Adapter receives:
- `request_id`
- `trace_id`
- `actor_id`
- `device_id`
- `workspace_id`
- `auth_context`
- `policy_envelope`

Health Adapter does not independently decide actor authorization; it enforces only the provided execution and policy constraints.

---

## Core Request Envelope

All requests use a shared envelope.

```json
{
  "contract_name": "mission_control.health_adapter",
  "contract_version": "1.0",
  "schema_version": "1.0",
  "request_id": "req_01",
  "trace_id": "trc_01",
  "timestamp": "2026-04-06T08:00:00Z",
  "actor": {
    "actor_id": "user_ava",
    "actor_type": "user"
  },
  "device": {
    "device_id": "dev_nexus_01",
    "device_class": "workstation",
    "os_family": "windows"
  },
  "workspace": {
    "workspace_id": "ws_system_health",
    "project_path": "C:\\Projects\\system_health",
    "project_id": "proj_system_health"
  },
  "target": {
    "toolchain": "npm",
    "operation": "install",
    "symptom": "install_failed_enospc"
  },
  "execution_mode": "diagnose_and_remediate_safe",
  "policy_envelope": {},
  "context": {
    "expected_free_space_floor_bytes": 2147483648,
    "capture_artifacts": true,
    "include_probe_details": true,
    "requested_checks": []
  }
}
```

---

## Endpoint Contract

## 1. Diagnose
`POST /v1/health/diagnose`

### Purpose
Collect evidence, resolve config/path state, and return structured diagnosis.

### Request additions
Optional:
- `target.toolchain`
- `target.operation`
- `target.symptom`
- `context.provided_error_text`
- `context.provided_logs[]`

### Response
```json
{
  "contract_name": "mission_control.health_adapter",
  "contract_version": "1.0",
  "schema_version": "1.0",
  "request_id": "req_01",
  "trace_id": "trc_01",
  "status": "completed",
  "result_type": "diagnosis_result",
  "diagnosis": {
    "primary_diagnosis": "cache_path_misrouted",
    "secondary_diagnoses": [
      "disk_exhaustion_effective_path",
      "env_override_conflict"
    ],
    "symptom": "npm install returned ENOSPC",
    "immediate_cause": "write to effective cache path failed",
    "root_cause": "process/user env override forced npm cache to exhausted reserved partition",
    "contributing_factors": [
      "effective cache path on D: reserved partition",
      "configured global npm cache shadowed",
      "D: free space below threshold"
    ],
    "severity": "high",
    "impact_scope": "local_dependency_install",
    "recoverability": "recoverable_with_safe_actions"
  },
  "ecl_inputs": {
    "diagnosis_confidence": 0.96,
    "path_attribution_confidence": 0.98,
    "config_stability": 0.22
  },
  "artifacts": [],
  "probe_summary": {
    "project_drive": "C:",
    "effective_cache_drive": "D:",
    "effective_cache_path": "D:\\Temp\\npm",
    "declared_cache_path": "E:\\npm-cache",
    "path_mismatch_detected": true
  },
  "errors": []
}
```

---

## 2. Plan
`POST /v1/health/plan`

### Purpose
Produce ordered remediation plan without mutation.

### Request
Same envelope, typically with `execution_mode=plan_only` or `diagnose_and_plan`.

### Response
```json
{
  "contract_name": "mission_control.health_adapter",
  "contract_version": "1.0",
  "schema_version": "1.0",
  "request_id": "req_02",
  "trace_id": "trc_02",
  "status": "completed",
  "result_type": "remediation_plan_result",
  "plan": {
    "plan_id": "plan_01",
    "policy_mode": "safe_auto_remediate",
    "requires_approval": false,
    "estimated_risk": "low",
    "estimated_recovery_probability": 0.94,
    "steps": [
      {
        "step_id": "step_01",
        "action_type": "capture_snapshot",
        "target": "workspace_and_relevant_drives",
        "risk": "low",
        "reversible": false
      },
      {
        "step_id": "step_02",
        "action_type": "clean_tool_cache",
        "target": "npm_cache",
        "risk": "low",
        "reversible": false
      },
      {
        "step_id": "step_03",
        "action_type": "set_effective_cache_path",
        "target": "E:\\npm-cache",
        "risk": "low",
        "reversible": true
      },
      {
        "step_id": "step_04",
        "action_type": "retry_operation",
        "target": "npm install",
        "risk": "low",
        "reversible": false
      }
    ]
  },
  "errors": []
}
```

---

## 3. Execute
`POST /v1/health/execute`

### Purpose
Execute an approved plan or execute inline safe/guarded remediation as permitted.

### Request
```json
{
  "contract_name": "mission_control.health_adapter",
  "contract_version": "1.0",
  "schema_version": "1.0",
  "request_id": "req_03",
  "trace_id": "trc_03",
  "execution_mode": "execute_approved_plan",
  "plan_ref": {
    "plan_id": "plan_01"
  },
  "policy_envelope": {
    "policy_mode": "safe_auto_remediate"
  }
}
```

### Response
```json
{
  "contract_name": "mission_control.health_adapter",
  "contract_version": "1.0",
  "schema_version": "1.0",
  "request_id": "req_03",
  "trace_id": "trc_03",
  "status": "completed",
  "result_type": "execution_result",
  "execution": {
    "plan_id": "plan_01",
    "overall_status": "completed",
    "steps_executed": 4,
    "steps_succeeded": 4,
    "steps_failed": 0,
    "action_events": [
      {
        "step_id": "step_02",
        "action_type": "clean_tool_cache",
        "result_status": "success",
        "exit_code": 0
      },
      {
        "step_id": "step_03",
        "action_type": "set_effective_cache_path",
        "result_status": "success",
        "exit_code": 0
      }
    ]
  },
  "artifacts": [],
  "errors": []
}
```

---

## 4. Verify
`POST /v1/health/verify`

### Purpose
Validate current state against expected health conditions.

### Request
```json
{
  "contract_name": "mission_control.health_adapter",
  "contract_version": "1.0",
  "schema_version": "1.0",
  "request_id": "req_04",
  "trace_id": "trc_04",
  "execution_mode": "verify_only",
  "workspace": {
    "workspace_id": "ws_system_health",
    "project_path": "C:\\Projects\\system_health"
  },
  "target": {
    "toolchain": "npm",
    "operation": "install"
  },
  "context": {
    "requested_checks": [
      "effective_cache_path_not_on_reserved_partition",
      "project_drive_free_space_gte_floor",
      "cache_drive_free_space_gte_floor",
      "operation_exit_code_zero"
    ]
  }
}
```

### Response
```json
{
  "contract_name": "mission_control.health_adapter",
  "contract_version": "1.0",
  "schema_version": "1.0",
  "request_id": "req_04",
  "trace_id": "trc_04",
  "status": "completed",
  "result_type": "verification_result",
  "verification": {
    "overall_pass": true,
    "checks": [
      {
        "check_name": "effective_cache_path_not_on_reserved_partition",
        "status": "pass"
      },
      {
        "check_name": "project_drive_free_space_gte_floor",
        "status": "pass",
        "observed_value": 7645179904
      },
      {
        "check_name": "cache_drive_free_space_gte_floor",
        "status": "pass",
        "observed_value": 975020388352
      },
      {
        "check_name": "operation_exit_code_zero",
        "status": "pass",
        "observed_value": 0
      }
    ]
  },
  "errors": []
}
```

---

## 5. Fitness
`POST /v1/health/fitness`

### Purpose
Return compact device/workspace execution fitness for Mission Control routing.

### Request
Same shared envelope with `execution_mode=fitness_only`.

### Response
```json
{
  "contract_name": "mission_control.health_adapter",
  "contract_version": "1.0",
  "schema_version": "1.0",
  "request_id": "req_05",
  "trace_id": "trc_05",
  "status": "completed",
  "result_type": "fitness_result",
  "fitness": {
    "device_id": "dev_nexus_01",
    "workspace_id": "ws_system_health",
    "toolchain": "npm",
    "storage_fitness": 0.91,
    "temp_path_fitness": 0.88,
    "cache_path_fitness": 0.97,
    "install_fitness": 0.95,
    "workspace_headroom_fitness": 0.84,
    "overall_fitness": 0.91,
    "blocking_conditions": [],
    "advisories": [
      "D: reserved partition should remain excluded from temp/cache routing"
    ],
    "stale_after": "2026-04-06T08:30:00Z"
  },
  "errors": []
}
```

---

## Error Contract

Mission Control needs deterministic error semantics.

### Error shape
```json
{
  "errors": [
    {
      "code": "POLICY_DENIED",
      "message": "Requested action exceeds policy envelope.",
      "retryable": false,
      "layer": "policy",
      "details": {
        "requested_action": "allow_env_var_mutation",
        "policy_mode": "recommend_only"
      }
    }
  ]
}
```

### Standard error codes
- `BAD_REQUEST`
- `UNSUPPORTED_TOOLCHAIN`
- `WORKSPACE_NOT_FOUND`
- `TARGET_NOT_WRITABLE`
- `PROBE_FAILED`
- `DIAGNOSIS_FAILED`
- `PLAN_NOT_FOUND`
- `POLICY_DENIED`
- `ACTION_NOT_ALLOWED`
- `EXECUTION_FAILED`
- `VERIFICATION_FAILED`
- `ARTIFACT_WRITE_FAILED`
- `LEDGER_WRITE_FAILED`
- `TIMEOUT`
- `INTERNAL_ERROR`

### Rule
Health Adapter must return structured errors, not shell-only failure text.

---

## Status Semantics

Top-level `status` allowed values:
- `completed`
- `completed_with_warnings`
- `partial`
- `failed`
- `denied`

### Meaning
- `completed`: requested operation finished successfully
- `completed_with_warnings`: success but non-blocking issues remain
- `partial`: some requested sub-work succeeded, some did not
- `failed`: operation could not complete
- `denied`: policy or authorization blocked the request

---

## Artifact Contract

Artifacts are returned as typed references, not just filenames.

```json
{
  "artifacts": [
    {
      "artifact_id": "art_01",
      "artifact_type": "disk_snapshot_before",
      "format": "json",
      "uri": "artifact://health/trc_01/disk_usage_before.json",
      "content_hash": "sha256:...",
      "size_bytes": 1842
    }
  ]
}
```

### Supported artifact types v1
- `disk_snapshot_before`
- `disk_snapshot_after`
- `diagnosis_report`
- `remediation_plan`
- `action_log`
- `verification_report`
- `operation_log`
- `incident_summary`
- `config_resolution_report`

---

## Canonical Writeback Contract

Mission Control should not need raw internal probe state; it needs canonical outputs.

### Health Adapter must emit or persist references to:
- `health_observation`
- `health_diagnosis`
- `health_remediation_plan`
- `health_action_event`
- `health_verification_result`
- `health_incident`
- `config_resolution_event`

### Returned references shape
```json
{
  "canonical_refs": {
    "diagnosis_ref": "hdiag_01",
    "plan_ref": "hplan_01",
    "incident_ref": "hinc_01",
    "verification_ref": "hver_01"
  }
}
```

---

## ECL Hand-off Contract

Mission Control does not score health confidence itself.
Health Adapter returns ECL-ready inputs or scored outputs depending on deployment mode.

### v1 allowed mode
Health Adapter returns scored outputs inline.

### Required confidence fields
- `diagnosis_confidence`
- `path_attribution_confidence`
- `remediation_confidence`
- `verification_confidence`
- `config_stability`

### Example
```json
{
  "ecl_inputs": {
    "diagnosis_confidence": 0.96,
    "path_attribution_confidence": 0.98,
    "remediation_confidence": 0.94,
    "verification_confidence": 0.97,
    "config_stability": 0.22
  }
}
```

---

## Mission Control Routing Rules

Mission Control may consume `fitness` and `diagnosis` outputs for routing.

### Suggested rules
- if `overall_fitness < 0.40` → halt local execution
- if `blocking_conditions` non-empty → require remediation or cloud fallback
- if `diagnosis.severity = critical` and `recoverability = not_recoverable_in_scope` → escalate
- if `execution_mode = fitness_only` and `overall_fitness >= threshold` → continue to target subsystem
- if `diagnose_and_remediate_safe` returns `verification.overall_pass = true` → resume planned operation

### Important rule
Mission Control makes the final routing decision.
Health Adapter provides the authoritative health truth used by that decision.

---

## Timeouts and Performance Targets

### Targets
- fitness-only: p95 under 500 ms when cached inputs available
- diagnose-only: p95 under 3 s for local workspace checks
- diagnose+safe-remediate: p95 under 30 s for standard npm case
- verify-only: p95 under 5 s excluding long-running target operations

### Timeout fields
Request may include:
- `timeout_ms`
- `artifact_capture_budget_ms`

Health Adapter must gracefully return `TIMEOUT` rather than hanging.

---

## Idempotency

Mutating requests must support idempotency.

### Request field
- `idempotency_key`

### Rule
If the same `idempotency_key` and equivalent request body are replayed, Health Adapter should return the existing result or a safe replay result without duplicating destructive actions.

---

## Caching

Mission Control may cache only compact fitness outputs.

### Cache guidance
- cache `fitness_result` for up to 30 seconds for fast routing
- do not cache mutating execution results as authoritative current state
- diagnosis results may be cached only within the same trace if no action has changed state

---

## Observability Contract

Every response should include:
- `trace_id`
- `request_id`
- `adapter_runtime_ms`
- `warnings[]`
- `errors[]`

Example:
```json
{
  "adapter_runtime_ms": 1840,
  "warnings": [
    "Reserved partition detected on D:; excluded from approved cache targets."
  ]
}
```

---

## NPM ENOSPC Reference Flow

## Step 1: Mission Control sends diagnosis request
```json
{
  "contract_name": "mission_control.health_adapter",
  "contract_version": "1.0",
  "schema_version": "1.0",
  "request_id": "req_npm_01",
  "trace_id": "trc_npm_01",
  "actor": { "actor_id": "user_ava", "actor_type": "user" },
  "device": { "device_id": "dev_nexus_01", "device_class": "workstation", "os_family": "windows" },
  "workspace": { "workspace_id": "ws_system_health", "project_path": "C:\\Projects\\system_health" },
  "target": { "toolchain": "npm", "operation": "install", "symptom": "install_failed_enospc" },
  "execution_mode": "diagnose_and_remediate_safe",
  "policy_envelope": {
    "policy_mode": "safe_auto_remediate",
    "allow_env_var_mutation": true,
    "allow_cache_cleanup": true,
    "allow_project_install_artifact_removal": true,
    "allow_cross_drive_cache_relocation": true,
    "min_free_space_bytes": 2147483648,
    "approved_target_roots": ["C:\\Projects", "E:\\npm-cache"]
  }
}
```

## Step 2: Health Adapter returns diagnosis + execution result
Key expected findings:
- `effective_cache_path = D:\\Temp\\npm`
- `declared_cache_path = E:\\npm-cache`
- `path_mismatch_detected = true`
- `primary_diagnosis = cache_path_misrouted`
- `secondary_diagnoses` includes `env_override_conflict`

## Step 3: Verification output
Key expected checks:
- effective cache path moved to `E:\\npm-cache`
- project drive free space ≥ 2 GB
- cache drive free space ≥ 2 GB
- npm install exit code = 0

This flow should be the P0 integration fixture.

---

## Security Constraints

- no raw shell passthrough in the public contract
- every mutation must be attributable to policy envelope + trace ID
- persistent config changes must be returned in artifact diff or config resolution report
- guarded actions require explicit policy capability
- all file targets must be within approved roots unless denied or escalated

---

## Acceptance Criteria

The integration contract is ready when:
- Mission Control can call diagnose/plan/execute/verify/fitness through typed requests
- Health Adapter returns structured diagnosis and compact fitness
- policy envelopes reliably constrain mutation scope
- errors are normalized and deterministic
- canonical refs are returned for ledgered objects
- npm ENOSPC misrouted-cache incident passes end-to-end as a fixture
- verification can prove remediation success using explicit checks

---

## Recommended Next Artifact

After this contract, the strongest implementation artifact is:
**SQL schema pack for health CMOs, config-resolution events, incidents, action logs, and fitness snapshots**

That would make the Health Adapter directly implementable against the Codessa substrate.

