# Architecture

## Layer model (high level)

HHA v0.1:

- Adapter → Collection → Normalization → Scoring → Inference → Projection

Health Adapter v1.0 adds an operational cognition chain:

- Probes (paths/resources/toolchain config) → Diagnosis → Remediation Planning → Execution → Verification → Fitness

## Schema mapping

- Evidence:
  - Hardware evidence: `hardware_observations`
  - Operational evidence: `health_observations`, `health_artifacts`
- Decision-grade health objects:
  - Hardware: `hardware_assessments`, `hardware_anomalies`, `hardware_incidents`, `hardware_workload_fitness_profiles`
  - Operational: `health_diagnoses`, `health_remediation_plans`, `health_action_events`, `health_verification_results`, `device_health_fitness_profiles`, `health_incidents`

## Cross-links

- `hardware_anomalies.diagnosis_id` links a hardware anomaly to an operational diagnosis when applicable.
- `hardware_incidents.primary_diagnosis_id` and `hardware_incidents.verification_result_id` connect incident memory to the diagnosis/verifications that explain and validate remediation.

