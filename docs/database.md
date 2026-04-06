# Database

## Canonical schema sources

- Historical baseline: `HHA_Canonical_Schema_v0.1.sql`
- Unified install target: `Codessa_Health_Schema_Pack_v1.0.sql`
- Supabase migrations:
  - `supabase/migrations/0001_codessa_health_schema_pack_v1_0.sql`
  - `supabase/migrations/0002_seed_fixture_npm_enospc.sql`

## Backward compatibility rules

- HHA v0.1 tables are preserved.
- Schema pack changes are additive:
  - new tables for Health Adapter CMOs
  - new enum values
  - new columns/FKs added with `IF NOT EXISTS` guards

## Enum migration safety

PostgreSQL enums cannot be “recreated” safely on existing databases.
Migrations therefore include `ALTER TYPE ... ADD VALUE IF NOT EXISTS` for enum expansion.

## Gold fixture

The `0002_seed_fixture_npm_enospc.sql` migration installs a deterministic trace for the npm misrouted-cache `ENOSPC` reference case.

