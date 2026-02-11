# Session Context — 2026-02-07

## Current Status: Bandit Model Investigation Complete (Phase 1 + Phase 2)

### Key Result: Model Is Correct But Starving for Data

The Holley bandit model (195001001, NIG Thompson Sampling) is **mathematically correct** but **cannot learn** due to structural data sparsity. Not a software bug.

### Treatment Count (Corrected)

| Metric | Value |
|--------|-------|
| Treatments in bandit pool | **92** |
| Treatments with 100+ sends/day | **20** (75% of traffic) |
| Top 10 treatments share | **49%** of traffic |
| Per-user eligible (fitment-filtered) | **4-7** |
| Bottom 34 treatments | 1-7 sends/day (niche fitment) |

### Convergence Simulation (v2 — Opens-Based)

Model trains on opens (~750/day), not sends (~5000/day). CTR of opens: 5-12%.

| Scenario | Median Days | Never Converge |
|----------|------------|----------------|
| A: Current (20 trts, 37 opens/trt/day) | **115** | **37.5%** |
| B: 10 treatments (75 opens/trt/day) | **28** | **0%** |
| C: Per-user (7 trts, 107 opens/trt/day) | **44** | **0.5%** |
| D: 10 trts + informative prior | **28** | **0%** |

**Reducing 20 → 10 treatments = 4x faster convergence, 37.5% → 0% non-convergence.**

### Other Key Findings

- NIG posteriors are correct (Q13: scores match `clicks/(1+opens)` within 0.2-0.6pp)
- Training data is clean (0 dupes, 0 time-travel, 0.11% phantom clicks)
- Score > 1.0 anomaly: caused by 31 new treatments added Jan 23 with 1-29 sends
- 1,686 invalid scores total; self-corrected by Feb 1
- Informative priors don't help (overwhelmed by data in 1-2 days)

---

## Files Created/Modified in This Investigation

### Phase 1 (2026-02-06)
| File | Purpose |
|------|---------|
| `sql/analysis/bandit_investigation.sql` | 10 diagnostic queries (Q1-Q10) |
| `docs/bandit/bandit_investigation_report.md` | Phase 1 findings — model updates but doesn't learn |

### Phase 2 (2026-02-07)
| File | Purpose |
|------|---------|
| `sql/analysis/bandit_investigation_phase2.sql` | 6 queries (Q11-Q16): data quality, treatment count, NIG math, score forensics |
| `src/nig_convergence_simulation.py` | NIG TS convergence simulation (v2, opens-based, 4 scenarios) |
| `docs/bandit/bandit_investigation_report_v2.md` | Full root cause report with corrected treatment counts + simulation |

### Linear Issue
- **AUX-12221**: "Bandit model cannot learn: reduce treatment pool from 92 to 10"
- Status: Todo, assigned to Praveen
- Contains full findings + recommendations

---

## Branch State
- Branch: `main`
- Up to date with `origin/main`
- Working tree: clean (except `docs/fitment_user_engagement_report.docx` untracked)
- Last commit: `20ffc87` — Update simulation with corrected inputs

---

## Prior Work (2026-02-05)

### Personalization Uplift Analysis

Personalized emails outperform Static/Control across all 3 campaigns:

| Campaign | Personalized CTR | Control CTR | Lift |
|----------|----------------:|------------:|-----:|
| Browse Recovery | 8.31% | 5.05% | +65% |
| Abandon Cart | 5.04% | 2.95% | +71% |
| Post Purchase | 4.13% | 1.11% | +272% |

Reports: `docs/analysis/fitment_user_engagement_report.md`, `docs/analysis/personalized_vs_static_uplift_report_v2.md`

---

## Recommendations (Priority Order)

### Immediate
1. **Reduce treatment pool from 92 to 10** — 4x faster convergence, top 10 already handle 49%
2. **Clamp scores to [0, 1]** — prevent score > 1.0 anomaly

### Short-Term
3. **Cold-start warmup** — require >= 100 sends before entering bandit
4. **Revert to 10/90 split** (10% Random, 90% Bandit)

### Medium-Term
5. **Hierarchical/group-level learning** — share signal across similar treatments
6. **Contextual bandits** — current model ignores user features

---

## Key References

### Bandit Investigation
- Phase 1 report: `docs/bandit/bandit_investigation_report.md`
- Phase 2 report: `docs/bandit/bandit_investigation_report_v2.md`
- NIG math reference: `docs/bandit/bandit-models-deep-analysis.md`
- Phase 1 SQL: `sql/analysis/bandit_investigation.sql`
- Phase 2 SQL: `sql/analysis/bandit_investigation_phase2.sql`
- Simulation: `src/nig_convergence_simulation.py`

### Uplift Analysis
- Cross-campaign report: `docs/analysis/fitment_user_engagement_report.md`
- P vs S detail: `docs/analysis/personalized_vs_static_uplift_report_v2.md`
- Queries: `sql/analysis/uplift_analysis_queries_v2.sql`

### Pipeline
- Pipeline v5.17: `sql/recommendations/v5_17_*.sql`
- QA checks: `sql/validation/qa_checks.sql`
- Schema: `docs/architecture/bigquery_schema.md`
