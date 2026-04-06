# Codessa Hardware Health Agent (HHA) + Health Adapter

This repository contains the canonical specifications and baseline implementation artifacts for two compatible subsystems:

- **Hardware Health Agent (HHA v0.1):** hardware telemetry → normalization → scoring → anomalies/incidents → workload fitness for routing.
- **Codessa Health Adapter (v1.0):** operational diagnosis/remediation lifecycle for toolchain/runtime failures (path resolution, capacity checks, planning, execution, verification).

The **Codessa Health Schema Pack v1.0** unifies both subsystems at the data layer.

## Repository Contents

- Specifications:
  - `HHA_Architecture_Spec_v0.1.md`
  - `HHA_Canonical_Schema_v0.1.sql`
  - `codessa_health_adapter_spec_v_1_0.md`
  - `mission_control_health_adapter_integration_contract_v_1_0.md`
  - `ADR001`
- Unified schema pack:
  - `Codessa_Health_Schema_Pack_v1.0.sql`
  - `supabase/migrations/0001_codessa_health_schema_pack_v1_0.sql`
  - `supabase/migrations/0002_seed_fixture_npm_enospc.sql`
- Minimal Health Adapter code skeleton:
  - `health_adapter/`

## Installation

Prerequisites:

- Python 3.13+

Install dependencies:

```bash
python -m pip install -r requirements.txt
```

## Usage

### Run the Health Adapter API (development)

```bash
python -m pip install -r requirements.txt
python -m uvicorn health_adapter.api.app:app --reload --port 8080
```

Example request:

```bash
curl -X POST http://localhost:8080/v1/health/diagnose \
  -H "Content-Type: application/json" \
  -d "{\"device_id\":\"dev_nexus_01\",\"workspace_id\":\"ws_system_health\",\"target_toolchain\":\"npm\",\"project_path\":\"C:\\\\Projects\\\\system_health\",\"symptom\":\"install_failed_enospc\",\"mode\":\"diagnose_and_plan\",\"env_overrides\":{\"npm_config_cache\":\"D:\\\\Temp\\\\npm\"},\"effective_cache_path\":\"D:\\\\Temp\\\\npm\",\"configured_cache_path\":\"E:\\\\npm-cache\",\"effective_temp_path\":\"D:\\\\Temp\"}"
```

### Run tests

```bash
python -m unittest discover -s health_adapter/tests -p "test_*.py" -v
```

## Database

The authoritative unified schema is provided in:

- `Codessa_Health_Schema_Pack_v1.0.sql`

For Supabase-compatible migrations, use:

- `supabase/migrations/0001_codessa_health_schema_pack_v1_0.sql`
- `supabase/migrations/0002_seed_fixture_npm_enospc.sql`

The seed fixture installs a gold reference trace for the npm `ENOSPC` misrouted-cache incident.

## Contributing

See `CONTRIBUTING.md` for development setup, code style, and pull request process.

## Security

Do not commit secrets (API keys, tokens, `.env` files). This repository is intended to be safe for public publication.

## Contact

For maintainership and roadmap questions:

- Project owner: Codessa engineering
- Contact: open an issue or submit a pull request

