# Overview

This repo contains two compatible subsystems:

- **Hardware Health Agent (HHA v0.1):** hardware telemetry and health scoring used for workload fitness and incident management.
- **Codessa Health Adapter (v1.0):** operational cognition for toolchain/runtime failures (diagnosis → remediation planning → execution → verification).

The **Codessa Health Schema Pack v1.0** unifies both subsystems at the data layer by:

- Preserving the original HHA tables as the hardware substrate.
- Adding Health Adapter CMOs (`health_*` tables) for causal/actionable lifecycle.
- Adding cross-links so hardware anomalies/incidents can reference diagnoses and verification.

Key reference docs:

- `HHA_Architecture_Spec_v0.1.md`
- `HHA_Canonical_Schema_v0.1.sql`
- `codessa_health_adapter_spec_v_1_0.md`
- `mission_control_health_adapter_integration_contract_v_1_0.md`
- `Codessa_Health_Schema_Pack_v1.0.sql`

