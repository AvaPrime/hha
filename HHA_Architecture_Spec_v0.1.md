# Codessa Hardware Health Agent
## System Architecture Specification v0.1
**Date:** April 6, 2026  
**Status:** Implementation-ready baseline  
**Subsystem:** Hardware Health Agent (HHA)  
**Parent system:** Codessa OS / NEXUS Runtime

---

## 1. Architecture Purpose

This document defines the internal architecture of the Hardware Health Agent — its layer decomposition, component responsibilities, data flow contracts, adapter abstraction model, and integration seams with upstream Codessa systems.

It is the authoritative reference for implementation teams building HHA v0.1.

---

## 2. Architectural Principles

| Principle | Enforcement |
|---|---|
| Observe before orchestrate | No action without a scored observation |
| Adapter isolation | Source-specific logic never leaks into core engine |
| Confidence-first scoring | Every output carries an epistemic confidence score |
| Evidence chaining | Every anomaly and incident references supporting observation IDs |
| Memory persistence | All meaningful outputs are written to canonical ledger |
| Graceful degradation | Sensor failures reduce confidence, they do not crash the pipeline |
| Policy-driven outcomes | Thresholds and escalation logic live in policy config, not code |
| Separation of concerns | Collection, normalization, scoring, inference, and projection are distinct stages |

---

## 3. System Layer Stack

```
┌─────────────────────────────────────────────────────────┐
│                    PROJECTION LAYER                      │
│         XHive Dashboard  ·  Mission Control API          │
├─────────────────────────────────────────────────────────┤
│                    INFERENCE LAYER                       │
│    Anomaly Engine  ·  Incident Manager  ·  Fitness       │
│    Classifier  ·  Recommendation Engine  ·  MCL Bridge   │
├─────────────────────────────────────────────────────────┤
│                    SCORING LAYER                         │
│    Component Scorer  ·  System Scorer  ·  ECL Bridge     │
│    Baseline Engine  ·  Trend Analyzer                    │
├─────────────────────────────────────────────────────────┤
│                  NORMALIZATION LAYER                     │
│    Canonical Observation Builder  ·  Metric Registry     │
│    Unit Normalizer  ·  Source Trust Mapper               │
├─────────────────────────────────────────────────────────┤
│                   COLLECTION LAYER                       │
│    Passive Monitor  ·  Diagnostic Orchestrator           │
│    Benchmark Runner  ·  Event Log Listener               │
├─────────────────────────────────────────────────────────┤
│                    ADAPTER LAYER                         │
│  OS Telemetry  ·  Sensor  ·  Benchmark  ·  SMART         │
│  GPU Vendor  ·  Event Log  ·  Memory Diag                │
├─────────────────────────────────────────────────────────┤
│                   HARDWARE SUBSTRATE                     │
│       CPU  ·  GPU  ·  RAM  ·  Storage  ·  Cooling        │
└─────────────────────────────────────────────────────────┘
```

---

## 4. Layer Definitions

### 4.1 Adapter Layer

**Responsibility:** Source-specific I/O. Translates raw OS/vendor/tool output into raw metric payloads.

**Design rule:** Zero business logic here. Adapters know how to read. They do not know what the reading means.

**Adapter interface contract:**

```typescript
interface HardwareAdapter {
  adapterId: string;
  adapterType: AdapterType;           // os_telemetry | sensor | benchmark | smart | event_log | gpu_vendor | memory_diag
  platform: Platform;                 // linux | windows | cross
  trustTier: 'high' | 'medium' | 'low';

  discoverComponents(): Promise<RawComponentDescriptor[]>;
  collectMetrics(scope: ComponentScope): Promise<RawMetricPayload[]>;
  runTest(profile: TestProfile): Promise<RawTestResult>;
  validateSourceHealth(): Promise<AdapterHealthStatus>;
}
```

**v0.1 Adapter inventory:**

| Adapter | Platform | Trust | Metrics |
|---|---|---|---|
| `LinuxSensorsAdapter` | Linux | Medium | CPU/GPU temp, fan RPM via `lm-sensors` |
| `SysfsAdapter` | Linux | High | CPU freq, throttle flags, power via `/sys` |
| `NvidiaAdapter` | Linux/Win | High | GPU temp, VRAM, clocks, power via `nvidia-smi` |
| `SmartctlAdapter` | Linux/Win | High | Storage health, temp, wear via `smartctl` |
| `MemtestAdapter` | Cross | High | Memory error counts via `memtester` or MemTest86 output |
| `SysbenchAdapter` | Linux | Medium | CPU benchmark via `sysbench` |
| `FioAdapter` | Linux | Medium | Storage I/O benchmark via `fio` |
| `WmiAdapter` | Windows | Medium | CPU/memory/thermal via WMI |
| `EventLogAdapter` | Windows | Medium | System crash/reboot correlation |

**Confidence floor by trust tier:**

```
high   → 0.80 base confidence
medium → 0.60 base confidence
low    → 0.35 base confidence
```

---

### 4.2 Collection Layer

**Responsibility:** Orchestrates adapter invocations. Manages polling schedules, diagnostic runs, and event listeners. Does not transform data.

**Components:**

**PassiveMonitor**
- Runs scheduled metric collection loops per operational mode
- Manages sampling intervals (idle: 60s, active: 10s, incident: 5s)
- Routes raw payloads to Normalization Layer
- Emits no observations itself — only passes through

**DiagnosticOrchestrator**
- Accepts `RunDiagnostic` commands (operator or Mission Control triggered)
- Selects and sequences the appropriate adapters for a test profile
- Manages test lifecycle (started, running, completed, failed, interrupted)
- Writes benchmark run records to persistence

**BenchmarkRunner**
- Wraps specific test tool invocations
- Handles timeouts, process management, output parsing
- Returns `RawTestResult` to DiagnosticOrchestrator

**EventLogListener**
- Listens for OS crash/reboot/shutdown events
- Enriches anomaly context when instability signals are present

**Operational mode → sampling interval table:**

| Mode | Passive interval | Active on load | Trigger |
|---|---|---|---|
| Idle | 60s | No | Default |
| Active monitoring | 10s | Yes | Heavy workload started |
| Diagnostic | On-demand | Yes | Operator/MC trigger |
| Incident | 5s | Yes | Open incident exists |

---

### 4.3 Normalization Layer

**Responsibility:** Converts raw adapter payloads into canonical `TelemetryObservation` objects. Enforces schema consistency across all sources.

**Components:**

**CanonicalObservationBuilder**
- Accepts `RawMetricPayload`
- Maps source-specific field names to canonical metric names via `MetricRegistry`
- Normalizes units (e.g., millidegrees → Celsius, KB → GB)
- Assigns source trust confidence modifier
- Constructs `TelemetryObservation` record
- Preserves `raw_payload_ref` for auditability

**MetricRegistry**
- Central lookup: `source_metric_name` → `canonical_metric_name + unit`
- Versioned; new adapter metrics register here, not in adapter code

**Canonical metric name examples:**

| Canonical name | Canonical unit | Source example |
|---|---|---|
| `cpu.package_temp` | celsius | lm-sensors `Package id 0` |
| `cpu.core_freq_mhz` | MHz | `/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq` |
| `gpu.core_temp` | celsius | nvidia-smi `temperature.gpu` |
| `gpu.hotspot_temp` | celsius | nvidia-smi `temperature.memory` |
| `gpu.vram_used_mb` | MB | nvidia-smi `memory.used` |
| `gpu.power_draw_w` | watts | nvidia-smi `power.draw` |
| `mem.error_count` | count | memtester errors |
| `storage.smart_health_pct` | percent | smartctl `Percentage Used` inverted |
| `storage.read_throughput_mbps` | MBps | fio |
| `cooling.cpu_fan_rpm` | RPM | lm-sensors |
| `cooling.case_fan_rpm` | RPM | lm-sensors |

**SourceTrustMapper**
- Applies adapter trust tier as confidence modifier
- Cross-signal agreement check: if multiple adapters report the same metric within tolerance, confidence is boosted
- Contradiction detection: if two high-trust adapters disagree beyond threshold, confidence is penalized and a `cross_signal_contradiction` anomaly is queued

---

### 4.4 Scoring Layer

**Responsibility:** Converts normalized observations into health scores, band classifications, and baselines. The scoring layer is the epistemic heart of HHA.

**Components:**

**ComponentScorer**

Produces a `HealthAssessment` for a single component.

Scoring dimensions:

```
thermal_score    = f(current_temp, expected_temp, trend_direction)
stability_score  = f(error_count, crash_correlation, throttle_events)
performance_score = f(benchmark_vs_baseline, clock_vs_nominal)
error_score      = f(hardware_error_count, smart_reallocated_sectors)
trend_score      = f(rolling_delta_over_window, slope_direction)

component_health_score = weighted_average(
  thermal_score    × 0.30,
  stability_score  × 0.30,
  performance_score × 0.20,
  error_score      × 0.15,
  trend_score      × 0.05
)
```

**SystemScorer**

Aggregates component scores into system-wide health.

```
system_health_score = weighted_average(
  cpu_health    × 0.25,
  gpu_health    × 0.25,
  memory_health × 0.20,
  storage_health × 0.15,
  cooling_health × 0.15
)
```

Weights are policy-configurable.

**Health band mapping:**

| Score range | Band |
|---|---|
| 0.90 – 1.00 | excellent |
| 0.75 – 0.89 | good |
| 0.60 – 0.74 | watch |
| 0.40 – 0.59 | degraded |
| 0.00 – 0.39 | critical |

**BaselineEngine**

- Maintains rolling baseline snapshots per component per mode (idle, load)
- Baseline types: `idle_baseline`, `load_baseline`, `benchmark_baseline`
- Baseline recalculated after maintenance events or significant regime changes
- Anomaly scoring depends on baseline to distinguish structural change from normal variance

**TrendAnalyzer**

- Computes slope of metric time series over configurable window (default: 7 days, 30 days)
- Outputs: `improving`, `stable`, `degrading`, `volatile`
- Feeds into component score `trend_score` and MCL bridge

**ECLBridge**

- Wraps final assessment before persistence
- Adds ECL-standard fields: `confidence_score`, `evidence_refs`, `corroboration_count`
- Supplies confidence modifiers based on:
  - Source trust tier
  - Number of agreeing signals
  - Observation recency (decay function over time)
  - Consistency across repeated samples

---

### 4.5 Inference Layer

**Responsibility:** Derives higher-order meaning from scored observations. Creates anomalies, forms incidents, classifies workload fitness, and generates recommendations.

**Components:**

**AnomalyEngine**

Evaluates observations and assessments against policy rules to create `AnomalyEvent` records.

Detection classes:

| Class | Detection logic |
|---|---|
| `threshold_breach` | Metric exceeds policy ceiling for ≥ 1 sample |
| `persistence_anomaly` | Threshold exceeded across N consecutive samples within window |
| `baseline_deviation` | Metric deviates from baseline by > policy % |
| `benchmark_underperformance` | Benchmark score < (baseline − tolerance%) |
| `cooling_under_response` | Fan RPM increase lags temp rise beyond response window |
| `cross_signal_contradiction` | Two high-trust adapters disagree beyond threshold |
| `instability_event` | Crash/reboot event correlates with high-load telemetry |
| `thermal_throttling` | Temp rises + effective clock drops while utilization remains high |

Rules are defined in policy config and evaluated by the rule engine — no hardcoded conditionals.

**IncidentManager**

- Monitors open anomalies for escalation conditions
- Escalates anomaly → incident when:
  - Anomaly persists beyond `incident_escalation_window` (default: 15 min for high severity)
  - Same anomaly type recurs N times within `recurrence_window`
  - High-severity anomaly first occurrence (memory errors, GPU instability)
- Incident lifecycle: `open` → `monitoring` → `resolved` / `suppressed`
- Links maintenance events to affected incidents for before/after comparison

**WorkloadFitnessClassifier**

Evaluates current system state against workload class requirements.

```
For each workload_class:
  evaluate: [cpu_health, gpu_health, memory_health, storage_health, cooling_health]
  apply:    workload-specific thresholds from policy profile
  output:   fit | fit_with_constraints | not_fit
  emit:     WorkloadFitnessProfile record with constraints[] and reasoning
```

**Workload class definitions (v0.1):**

| Class | Key constraints |
|---|---|
| `light_interactive` | No critical incidents; any health > 0.40 |
| `development` | No critical incidents; CPU/mem health > 0.60 |
| `embedding_batch` | CPU health > 0.70; memory health > 0.75; no mem errors |
| `llm_7b` | GPU health > 0.70; VRAM headroom > 8GB; no GPU incidents |
| `llm_14b` | GPU health > 0.80; VRAM headroom > 14GB; GPU temp < 80°C sustained |
| `gpu_heavy` | GPU health > 0.85; cooling health > 0.70; no thermal incidents |
| `stress_diagnostic` | No hard constraints; operator override |

**RecommendationEngine**

- Evaluates open incidents and anomalies
- Maps condition → recommendation template
- Outputs: operator-facing maintenance recommendations + runtime reflex suggestions

Recommendation categories:

```
operator_action  → physical/manual intervention needed
runtime_reflex   → routing or scheduling change
defer_workload   → specific class should not run now
monitor_watch    → no action, but escalate if persists
```

**MCLBridge**

- Feeds TrendAnalyzer outputs, anomaly history, and incident lineage to Memory Cortex
- Formats data for MCL reasoning queries
- Supports: "has GPU thermal trend worsened over 30 days?", "how many times has this machine been not-fit in the past week?"

---

### 4.6 Projection Layer

**Responsibility:** Exposes HHA state to external consumers. No business logic here — only serialization, filtering, and formatting.

**XHiveProjector**
- Builds dashboard-ready payloads for each major view
- Computes display-layer fields: `status_label`, `color_code`, `action_urgency`
- Does not compute any scores or make decisions

**MissionControlGateway**
- Exposes synchronous query endpoints for routing decisions
- Returns current fitness profile on `should_route_locally()` queries
- Can return cached fitness profile with TTL (default: 30s staleness tolerance)

**MemoryWriter**
- Persists all meaningful outputs to canonical ledger tables
- Writes in order: observations → assessments → anomalies → incidents → fitness profiles
- Enforces ledger sequencing: every record gets a monotonic sequence number within its type

---

## 5. Primary Data Flows

### 5.1 Passive Telemetry Flow

```
Hardware Substrate
  → Adapter (reads sensor, normalizes to RawMetricPayload)
  → PassiveMonitor (routes to Normalization)
  → CanonicalObservationBuilder (produces TelemetryObservation)
  → ComponentScorer (produces HealthAssessment per component)
  → SystemScorer (aggregates system HealthAssessment)
  → AnomalyEngine (evaluates rules, creates AnomalyEvents)
  → IncidentManager (monitors for escalation)
  → MemoryWriter (persists all records)
  → XHiveProjector (updates dashboard state)
```

### 5.2 Active Diagnostic Flow

```
Trigger (Operator / Mission Control)
  → DiagnosticOrchestrator (creates BenchmarkRun record, status=running)
  → BenchmarkRunner (invokes adapter test, waits for completion)
  → RawTestResult → CanonicalObservationBuilder (benchmark observations)
  → ComponentScorer (scores benchmark result vs baseline)
  → AnomalyEngine (evaluates benchmark underperformance rules)
  → BenchmarkRun record updated (status=completed, result_summary, pass_fail)
  → MemoryWriter (persists full run)
  → BaselineEngine (optionally updates baseline if run qualifies)
```

### 5.3 Workload Fitness Query Flow

```
Mission Control → GET /hardware/workload-fitness/{class}
  → WorkloadFitnessClassifier
      ← current HealthAssessments (from Scoring Layer cache)
      ← open HardwareIncidents (from IncidentManager)
      ← policy profile for workload_class
  → WorkloadFitnessProfile (fit | fit_with_constraints | not_fit + constraints + reasoning)
  → Mission Control receives routing signal
  → MemoryWriter persists fitness profile record
```

### 5.4 Incident Formation Flow

```
AnomalyEvent created
  → IncidentManager evaluates escalation policy:
      - is severity high/critical on first occurrence?  → open incident immediately
      - has this anomaly persisted beyond window?       → escalate to incident
      - has this anomaly recurred N times?             → open incident
  → HardwareIncident created (status=open)
  → RecommendationEngine generates operator_action and runtime_reflex items
  → MemoryWriter persists incident + recommendations
  → XHiveProjector updates incident panel
  → MissionControlGateway cache invalidated (next fitness query re-evaluates)
```

---

## 6. Internal API Contracts

### 6.1 HHA Core API (internal service boundary)

```
// Scoring Layer → Inference Layer
interface AssessmentQuery {
  getComponentAssessment(componentId: string): Promise<HealthAssessment>;
  getSystemAssessment(): Promise<HealthAssessment>;
  getComponentTrend(componentId: string, windowDays: number): Promise<TrendSummary>;
}

// Inference Layer → Projection Layer
interface HHAStateQuery {
  getSystemHealth(): Promise<SystemHealthSummary>;
  getWorkloadFitness(workloadClass: WorkloadClass): Promise<WorkloadFitnessProfile>;
  getOpenIncidents(): Promise<HardwareIncident[]>;
  getRecentAnomalies(limit: number): Promise<AnomalyEvent[]>;
  getComponentHealth(componentId: string): Promise<HealthAssessment>;
  getBenchmarkHistory(componentId?: string, limit?: number): Promise<BenchmarkRun[]>;
}

// Diagnostic control
interface DiagnosticControl {
  runScan(): Promise<ScanResult>;
  runTest(testProfile: TestProfile): Promise<BenchmarkRun>;
  recordMaintenanceEvent(event: MaintenanceEventInput): Promise<MaintenanceEvent>;
}
```

### 6.2 Mission Control Integration Contract

Mission Control queries HHA via the following synchronous interface:

```
GET /hardware/health
  Response: { system_score, health_band, open_incident_count, assessed_at }

GET /hardware/workload-fitness/{class}
  Response: {
    workload_class,
    fit_status,          // fit | fit_with_constraints | not_fit
    constraints[],
    reasoning_summary,
    expires_at           // cache TTL
  }

GET /hardware/incidents?status=open
  Response: HardwareIncident[]

POST /hardware/scan
  Response: { scan_id, status, components_scanned, triggered_at }
```

**Routing integration pattern:**

```typescript
// Mission Control pre-flight check
const fitness = await hha.getWorkloadFitness('llm_14b');

if (fitness.fit_status === 'not_fit') {
  return routeToCloud(request);
}
if (fitness.fit_status === 'fit_with_constraints') {
  return routeLocalWithConstraints(request, fitness.constraints);
}
return routeLocal(request);
```

### 6.3 Memory Cortex Integration Contract

All writes to Memory Cortex follow ledger conventions:

```typescript
interface LedgerRecord {
  record_id: string;          // UUID v4
  record_type: string;        // entity type name
  subsystem: 'hha';
  sequence_number: number;    // monotonic per subsystem
  created_at: timestamp;
  payload: object;            // full entity record
  evidence_refs: string[];    // referenced record IDs
  confidence_score: number;
}
```

Memory Cortex queries supported by HHA:

```
"Has GPU thermal condition worsened over the last 30 days?"
  → TrendAnalyzer output + historical HealthAssessments

"When did storage health first show degradation?"
  → AnomalyEvent history filtered by component + metric

"Did thermal paste replacement improve CPU stability?"
  → MaintenanceEvent timestamp + before/after HealthAssessments

"How many times has this machine been not_fit for llm_14b in the past 7 days?"
  → WorkloadFitnessProfile history
```

### 6.4 ECL Integration Contract

Every `HealthAssessment` and `AnomalyEvent` passes through ECL enrichment before persistence:

```typescript
interface ECLEnrichedRecord {
  confidence_score: number;      // 0.0 – 1.0
  confidence_factors: {
    source_trust: number;
    corroboration_count: number;
    observation_recency: number;
    cross_signal_agreement: number;
    tool_known_limitations: number;
  };
  evidence_refs: string[];       // TelemetryObservation IDs
  confidence_band: 'high' | 'medium' | 'low' | 'unreliable';
}
```

Confidence decay function (observation recency):

```
confidence_multiplier = max(0.5, 1.0 - (age_minutes / staleness_ceiling_minutes))
default staleness_ceiling = 30 minutes for passive telemetry
```

---

## 7. Adapter Abstraction Detail

### 7.1 Adapter lifecycle

```
1. Register: adapters declare capabilities on initialization
2. Discover: ComponentRegistry calls discoverComponents() on startup
3. Collect: PassiveMonitor calls collectMetrics() on schedule
4. Validate: AdapterHealthMonitor calls validateSourceHealth() periodically
5. Degrade: failed adapters are marked degraded; confidence reduced; not removed
```

### 7.2 Adapter failure handling

```
if adapter.validateSourceHealth() fails:
  mark adapter status = degraded
  set trust_tier = low
  reduce confidence floor to 0.20
  continue collecting from other adapters
  log AdapterDegradedEvent to MemoryWriter
  do NOT throw / crash pipeline
```

### 7.3 Multi-adapter corroboration

When multiple adapters report the same canonical metric:

```
if all_values within tolerance_pct (default 5%):
  confidence_boost = +0.15
  use average value

if any_value exceeds tolerance:
  flag cross_signal_contradiction anomaly
  confidence_penalty = -0.20
  use highest-trust adapter value
  log contradiction event
```

---

## 8. Policy Configuration Schema

All thresholds and escalation logic are externalized to policy config. No business logic hardcodes numeric thresholds.

```yaml
# hha_policy_v0.1.yaml

components:
  cpu:
    max_temp_celsius: 90
    throttle_detection_clock_drop_pct: 15
    benchmark_deviation_tolerance_pct: 10
    trend_window_days: 7

  gpu:
    max_core_temp_celsius: 85
    max_hotspot_temp_celsius: 95
    vram_headroom_min_mb: 1024
    benchmark_deviation_tolerance_pct: 10

  memory:
    max_error_count: 0
    swap_pressure_threshold_pct: 80

  storage:
    smart_health_min_pct: 80
    latency_spike_ms_threshold: 500
    wear_indicator_alert_pct: 90

  cooling:
    fan_response_lag_seconds: 30
    thermal_decay_rate_min: 5

anomaly:
  persistence_window_seconds: 300
  persistence_sample_count: 3
  recurrence_window_minutes: 60
  recurrence_count_for_incident: 3

incidents:
  escalation_window_minutes: 15
  high_severity_immediate_escalation: true

workload_fitness:
  llm_14b:
    gpu_health_min: 0.80
    gpu_temp_max_celsius: 80
    vram_headroom_min_mb: 14336
    cooling_health_min: 0.70
    block_on_open_gpu_incident: true

scoring:
  system_weights:
    cpu: 0.25
    gpu: 0.25
    memory: 0.20
    storage: 0.15
    cooling: 0.15

ecl:
  staleness_ceiling_minutes: 30
  min_confidence_floor: 0.20
```

---

## 9. Operational Mode State Machine

```
[IDLE]
  → trigger: heavy workload detected
  → [ACTIVE_MONITORING]

[ACTIVE_MONITORING]
  → trigger: workload ends
  → [IDLE]

[IDLE or ACTIVE_MONITORING]
  → trigger: operator/MC diagnostic command
  → [DIAGNOSTIC]

[DIAGNOSTIC]
  → trigger: test completes or fails
  → [IDLE or ACTIVE_MONITORING] (returns to prior state)

[IDLE or ACTIVE_MONITORING]
  → trigger: incident opened
  → [INCIDENT]

[INCIDENT]
  → trigger: all incidents resolved
  → [IDLE or ACTIVE_MONITORING]

Any mode
  → trigger: adapter health fails
  → mark adapter degraded; remain in current mode
```

---

## 10. Component Registry

On first run, HHA builds a `HardwareComponent` record per discovered device.

```
ComponentRegistry:
  - runs discoverComponents() on all adapters
  - deduplicates by (vendor, model, device_fingerprint)
  - assigns stable component_id (deterministic UUID from fingerprint)
  - stores in hardware_components table
  - subsequent runs match by component_id; no duplicates created
```

**Component fingerprinting:**

```
cpu_fingerprint  = sha256(vendor + model + logical_core_count)
gpu_fingerprint  = sha256(vendor + model + vram_total_mb + pci_bus_id)
mem_fingerprint  = sha256(total_capacity_gb + slot_count)
disk_fingerprint = sha256(serial_number || model + capacity_bytes)
```

---

## 11. Deployment Topology

```
┌─────────────────────────────────┐
│         NEXUS Workstation       │
│                                 │
│  ┌──────────────────────────┐   │
│  │      HHA Service         │   │
│  │  (local daemon / process) │  │
│  │                          │   │
│  │  ┌────────────────────┐  │   │
│  │  │   Adapter Layer    │  │   │
│  │  │  (OS-privileged)   │  │   │
│  │  └────────────────────┘  │   │
│  │                          │   │
│  │  ┌────────────────────┐  │   │
│  │  │   Core Engine      │  │   │
│  │  │  (unprivileged)    │  │   │
│  │  └────────────────────┘  │   │
│  │                          │   │
│  │  ┌────────────────────┐  │   │
│  │  │   Local DB         │  │   │
│  │  │  (Supabase/SQLite) │  │   │
│  │  └────────────────────┘  │   │
│  └──────────────────────────┘   │
│                                 │
│  Integration: Mission Control   │
│  Integration: Memory Cortex     │
│  Integration: XHive Dashboard   │
└─────────────────────────────────┘
```

**Process isolation:** Adapter Layer runs with elevated OS permissions (sensor/SMART access). Core Engine runs unprivileged. Adapter → Core communication via local IPC or Unix socket.

**Database:** v0.1 targets Supabase (PostgreSQL) as local persistence layer, aligned with Codessa canonical schema conventions. SQLite fallback acceptable for offline/minimal mode.

---

## 12. v0.1 Implementation Sequence

### Phase 1 — Foundation
- ComponentRegistry + hardware_components table
- LinuxSensorsAdapter + SysfsAdapter + NvidiaAdapter
- PassiveMonitor (idle mode only)
- CanonicalObservationBuilder + MetricRegistry
- hardware_observations table
- ComponentScorer (thermal + stability dimensions only)
- hardware_assessments table
- XHive basic health card projection

### Phase 2 — Diagnostics
- BenchmarkRunner + SysbenchAdapter + FioAdapter + MemtestAdapter
- DiagnosticOrchestrator
- hardware_benchmark_runs table
- SystemScorer
- AnomalyEngine (threshold_breach + benchmark_underperformance rules)
- hardware_anomalies table
- WorkloadFitnessClassifier (basic)
- hardware_workload_fitness_profiles table
- Mission Control GET /hardware/health + /hardware/workload-fitness/{class}

### Phase 3 — Intelligence
- BaselineEngine
- TrendAnalyzer
- AnomalyEngine (persistence + baseline_deviation rules)
- IncidentManager
- hardware_incidents table
- MaintenanceEvent recording
- hardware_maintenance_events table
- RecommendationEngine
- ECLBridge enrichment

### Phase 4 — Codessa Coupling
- Full Mission Control routing integration
- MCLBridge + Memory Cortex writes
- XHive full dashboard (trends, incidents, maintenance log, diagnostics history)
- Active monitoring mode (high-frequency sampling under load)
- Incident mode sampling
- Policy config hot-reload

---

## 13. Integration Seam Summary

| Seam | Direction | Protocol | Blocking? |
|---|---|---|---|
| Mission Control → HHA | Inbound query | HTTP/REST | Yes (pre-flight) |
| HHA → Memory Cortex | Outbound write | Async ledger write | No |
| HHA → XHive | Outbound projection | Push or poll | No |
| ECL → HHA Assessment | Enrichment wrapper | In-process | Yes |
| MCL → HHA History | Inbound query | Async query | No |
| HHA → Agora (model runtime) | Fitness signal | Shared state / event | No |

---

*HHA Architecture Spec v0.1 — Codessa OS*  
*Next deliverable: Canonical Schema + SQL Table Design*
