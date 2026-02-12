# Performance Optimization Workflow

Visual guide to the performance optimization process.

## Overview Flowchart

```
┌─────────────────────────────────────────────────────────────────┐
│                    Performance Issue Detected                    │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │  What's the symptom?  │
                    └───────────┬───────────┘
                                │
                ┌───────────────┼───────────────┐
                │               │               │
                ▼               ▼               ▼
        ┌──────────┐    ┌─────────────┐   ┌──────────┐
        │   Slow   │    │   Vector    │   │ Resource │
        │ Queries  │    │   Search    │   │  Issues  │
        └─────┬────┘    └──────┬──────┘   └────┬─────┘
              │                │                │
              ▼                ▼                ▼
    ┌──────────────────┐ ┌────────────────┐ ┌─────────────────┐
    │ analyze-slow-    │ │ optimize-      │ │ tune-postgresql │
    │   queries.sh     │ │   ruvector.sh  │ │      .sh        │
    └────────┬─────────┘ └───────┬────────┘ └────────┬────────┘
             │                   │                    │
             ▼                   ▼                    ▼
    ┌──────────────┐     ┌──────────────┐    ┌──────────────┐
    │ Add Indexes  │     │ Tune HNSW    │    │ Apply Config │
    │ VACUUM       │     │ Parameters   │    │ Restart DB   │
    └──────┬───────┘     └──────┬───────┘    └──────┬───────┘
           │                    │                    │
           └────────────────────┴────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │   benchmark-cluster   │
                    │    .sh run            │
                    └───────────┬───────────┘
                                │
                                ▼
                        ┌───────────────┐
                        │  Improved?    │
                        └───┬───────┬───┘
                            │       │
                        Yes │       │ No
                            │       │
                            ▼       ▼
                        ┌─────┐ ┌──────────┐
                        │Done │ │ Iterate  │
                        └─────┘ └────┬─────┘
                                     │
                                     └──────► Back to diagnosis
```

## Detailed Workflows

### 1. Initial Setup Workflow

```
┌─────────────────────┐
│  Fresh Installation │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────────────────────┐
│ 1. analyze-slow-queries.sh setup   │
└──────────┬──────────────────────────┘
           │
           ▼
┌─────────────────────────────────────┐
│ 2. docker restart ruvector-db       │
└──────────┬──────────────────────────┘
           │
           ▼
┌─────────────────────────────────────┐
│ 3. benchmark-cluster.sh baseline    │
└──────────┬──────────────────────────┘
           │
           ▼
┌─────────────────────────────────────┐
│ 4. tune-postgresql.sh analyze       │
└──────────┬──────────────────────────┘
           │
           ▼
┌─────────────────────────────────────┐
│ 5. optimize-ruvector.sh analyze     │
└──────────┬──────────────────────────┘
           │
           ▼
┌─────────────────────────────────────┐
│        Baseline Established         │
└─────────────────────────────────────┘
```

### 2. Weekly Maintenance Workflow

```
┌──────────────┐
│ Week Start   │
└──────┬───────┘
       │
       ▼
┌────────────────────────────────┐
│ 1. tune-postgresql.sh vacuum   │
│    (Reclaim space, update stats)
└──────┬─────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 2. analyze-slow-queries.sh report  │
│    (Find slow queries)              │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 3. tune-postgresql.sh indexes      │
│    (Check index usage)              │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 4. benchmark-cluster.sh run        │
│    (Compare with baseline)          │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│  Issues Found?                      │
└──────┬──────────────────────────┬───┘
       │ Yes                      │ No
       ▼                          ▼
┌──────────────┐          ┌──────────────┐
│ Deep Dive    │          │ Report OK    │
│ (See below)  │          └──────────────┘
└──────────────┘
```

### 3. Deep Dive Optimization Workflow

```
┌──────────────────────┐
│ Performance Issue    │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────────────────────┐
│ 1. Comprehensive Analysis            │
│    - analyze-slow-queries.sh report  │
│    - optimize-ruvector.sh profile    │
│    - benchmark-cluster.sh run        │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│ 2. Identify Root Cause               │
│    - Slow queries? → Missing indexes │
│    - Vector slow? → HNSW params      │
│    - Resource? → Config tuning       │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│ 3. Apply Targeted Optimization       │
│    Query:  Add indexes + ANALYZE     │
│    Vector: Tune HNSW or ef_search    │
│    Config: tune-postgresql.sh        │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│ 4. Verify Improvements               │
│    - benchmark-cluster.sh run        │
│    - Compare with baseline           │
│    - Check regression                │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│ 5. Document Changes                  │
│    - Update baseline if better       │
│    - Note configuration changes      │
│    - Record lessons learned          │
└──────────────────────────────────────┘
```

### 4. Slow Query Investigation

```
┌─────────────────────────────────┐
│ Query Performance Issue         │
└──────────┬──────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│ 1. analyze-slow-queries.sh report   │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│ Identify Problem Category            │
└──┬─────────┬─────────┬──────────┬────┘
   │         │         │          │
   ▼         ▼         ▼          ▼
┌──────┐ ┌──────┐ ┌────────┐ ┌──────────┐
│ High │ │Freq. │ │ High   │ │Sequential│
│Total │ │Calls │ │Variance│ │  Scans   │
│Time  │ │      │ │        │ │          │
└──┬───┘ └──┬───┘ └───┬────┘ └────┬─────┘
   │        │         │           │
   │        │         │           ▼
   │        │         │      ┌──────────┐
   │        │         │      │   Add    │
   │        │         │      │ Indexes  │
   │        │         │      └────┬─────┘
   │        │         │           │
   └────────┴─────────┴───────────┘
                │
                ▼
┌────────────────────────────────────┐
│ 2. EXPLAIN ANALYZE problematic     │
│    queries                         │
└──────────┬─────────────────────────┘
           │
           ▼
┌────────────────────────────────────┐
│ 3. Apply Optimizations:            │
│    - Create missing indexes        │
│    - Rewrite inefficient queries   │
│    - Update statistics (ANALYZE)   │
└──────────┬─────────────────────────┘
           │
           ▼
┌────────────────────────────────────┐
│ 4. Verify with benchmark           │
└────────────────────────────────────┘
```

### 5. Vector Performance Optimization

```
┌──────────────────────────┐
│ Vector Search Slow       │
└──────────┬───────────────┘
           │
           ▼
┌─────────────────────────────────┐
│ 1. optimize-ruvector.sh analyze │
└──────────┬──────────────────────┘
           │
           ▼
┌─────────────────────────────────┐
│ Check Current Configuration     │
│ - m value                       │
│ - ef_construction               │
│ - Index size                    │
│ - Usage statistics              │
└──────────┬──────────────────────┘
           │
           ▼
┌─────────────────────────────────┐
│ Determine Issue                 │
└──┬──────────────────┬───────────┘
   │                  │
   ▼                  ▼
┌──────────────┐  ┌───────────────┐
│ Build Time   │  │ Search Time   │
│ Too Long     │  │ Too Long      │
└──┬───────────┘  └───┬───────────┘
   │                  │
   ▼                  ▼
┌────────────────┐ ┌──────────────────┐
│ Lower          │ │ Increase         │
│ef_construction │ │ef_search at query│
│or m            │ │time              │
└────┬───────────┘ └────┬─────────────┘
     │                  │
     └────────┬─────────┘
              │
              ▼
┌──────────────────────────────────┐
│ Option: Rebuild Index            │
│ optimize-ruvector.sh tune        │
└──────────┬───────────────────────┘
           │
           ▼
┌──────────────────────────────────┐
│ Benchmark and Compare            │
└──────────────────────────────────┘
```

### 6. Resource Optimization

```
┌─────────────────────────┐
│ High Memory/CPU Usage   │
└──────────┬──────────────┘
           │
           ▼
┌────────────────────────────────┐
│ 1. tune-postgresql.sh analyze  │
└──────────┬─────────────────────┘
           │
           ▼
┌────────────────────────────────┐
│ System Analysis                │
│ - Available RAM                │
│ - CPU cores                    │
│ - Disk space                   │
│ - Workload pattern             │
└──────────┬─────────────────────┘
           │
           ▼
┌────────────────────────────────┐
│ Calculate Optimal Parameters   │
│ - shared_buffers               │
│ - work_mem                     │
│ - maintenance_work_mem         │
│ - max_connections              │
└──────────┬─────────────────────┘
           │
           ▼
┌────────────────────────────────┐
│ Apply Configuration            │
└──────────┬─────────────────────┘
           │
           ▼
┌────────────────────────────────┐
│ Restart PostgreSQL             │
└──────────┬─────────────────────┘
           │
           ▼
┌────────────────────────────────┐
│ Monitor Cache Hit Ratio        │
│ Target: > 95%                  │
└────────────────────────────────┘
```

## Decision Matrix

### When to Use Each Tool

```
┌──────────────────────────────────────────────────────────────┐
│                        SYMPTOM                               │
├─────────────────────┬────────────────────────────────────────┤
│ Slow overall perf   │ → benchmark-cluster.sh run             │
│ Specific slow query │ → analyze-slow-queries.sh report       │
│ Vector search slow  │ → optimize-ruvector.sh profile         │
│ High memory usage   │ → tune-postgresql.sh analyze           │
│ Table bloat         │ → tune-postgresql.sh vacuum            │
│ Unused indexes      │ → tune-postgresql.sh indexes           │
│ Need baseline       │ → benchmark-cluster.sh baseline        │
│ After optimization  │ → benchmark-cluster.sh run (compare)   │
└─────────────────────┴────────────────────────────────────────┘
```

## Performance Metrics Dashboard

```
┌─────────────────────────────────────────────────────────────┐
│                   PERFORMANCE DASHBOARD                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Connection Time        [ ████████░░ ] 8.5ms    Target: <10ms
│  Simple Query          [ ███████░░░ ] 7.2ms    Target: <10ms
│  Index Scan            [ ██████████ ] 12ms     Target: <50ms
│  Vector Search         [ ████████░░ ] 45ms     Target: <50ms
│  Write Performance     [ █████████░ ] 380ms    Target: <500ms
│  Cache Hit Ratio       [ ██████████ ] 96.8%    Target: >95%
│  Connection Usage      [ ████░░░░░░ ] 38%      Target: <50%
│                                                             │
│  Status: ✓ All metrics within target                       │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  Last Optimization: 2026-02-10                              │
│  Last Benchmark:    2026-02-12                              │
│  Trend:            ↗ Improving                              │
└─────────────────────────────────────────────────────────────┘
```

## Automation Schedule

```
Daily (2 AM)
├── tune-postgresql.sh vacuum
└── benchmark-cluster.sh run

Weekly (Sunday 3 AM)
├── analyze-slow-queries.sh report
├── tune-postgresql.sh indexes
└── optimize-ruvector.sh analyze

Monthly (1st of month, 4 AM)
├── Full index rebuild (if needed)
├── Statistics update (ANALYZE)
└── Comprehensive benchmark report

Quarterly
├── Hardware assessment
├── Capacity planning review
└── Configuration audit
```

## Troubleshooting Decision Tree

```
                    ┌─────────────────┐
                    │ Performance Bad │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │ Cache hit < 90%?│
                    └────┬────────┬───┘
                        YES      NO
                         │        │
            ┌────────────▼──┐    ▼
            │ Increase      │ ┌──────────────┐
            │ shared_buffers│ │Query slow?   │
            └───────────────┘ └┬─────────┬───┘
                              YES       NO
                               │         │
                    ┌──────────▼──┐     ▼
                    │ Missing     │ ┌────────────┐
                    │ indexes?    │ │Vector slow?│
                    └┬────────┬───┘ └┬───────┬───┘
                    YES      NO     YES     NO
                     │        │      │       │
            ┌────────▼──┐ ┌──▼───┐ │   ┌───▼────┐
            │Add indexes│ │VACUUM│ │   │Check   │
            └───────────┘ └──────┘ │   │logs for│
                                   │   │errors  │
                    ┌──────────────▼─┐ └────────┘
                    │ Tune HNSW      │
                    │ parameters     │
                    └────────────────┘
```

## Success Criteria

```
┌────────────────────────────────────────────────────────────┐
│                   OPTIMIZATION SUCCESS                     │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  ✓ All metrics within target range                        │
│  ✓ No regression from baseline                            │
│  ✓ Cache hit ratio > 95%                                   │
│  ✓ No slow queries > 500ms                                 │
│  ✓ Connection usage < 80%                                  │
│  ✓ Table bloat < 10%                                       │
│  ✓ All indexes being used                                  │
│                                                            │
│  Optional:                                                 │
│  □ Baseline updated                                        │
│  □ Documentation updated                                   │
│  □ Team notified                                           │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

---

**Last Updated:** 2026-02-12
**Version:** 1.0.0
