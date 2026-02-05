# Session Context — 2026-02-05

## Current Work: Uplift Analysis V2 (No Crash Exclusion)

### What Was Done Today

Created **v2 versions** of the uplift analysis that treat the full v5.17 period (Jan 10 - Feb 4) as one unit WITHOUT crash exclusion:

1. **`sql/analysis/uplift_analysis_queries_v2.sql`** — All queries with `in_crash_window` filters removed
2. **`docs/personalized_vs_static_uplift_report_v2.md`** — Complete report with actual query results

Committed as `d97ff82` — "Add uplift analysis v2 without crash exclusion"

### Critical Finding

**The v1 "reversal story" was an artifact of crash exclusion.**

| Metric | V1 (crash excluded) | V2 (full period) |
|--------|---------------------|------------------|
| v5.17 P sends (fitment) | 749 | 3,537 |
| v5.17 S CTR (fitment) | 0.00% | **16.87%** |
| DiD (CTR opens) | +13.13pp (P wins) | **-4.90pp (S wins)** |
| CTR winner v5.17 | Personalized | **Static** |

With full v5.17 data:
- **Static outperforms Personalized in BOTH periods** (v5.7 and v5.17)
- Static CTR: 12.68% → 16.87% (improved)
- Personalized CTR: 5.15% → 4.44% (declined)
- DiD is **negative** (-4.90pp), meaning Static improved MORE than Personalized

### Files Changed

| File | Change |
|------|--------|
| `sql/analysis/uplift_analysis_queries_v2.sql` | NEW - 655 lines, no crash filters |
| `docs/personalized_vs_static_uplift_report_v2.md` | NEW - 300 lines, complete report |

Original v1 files unchanged:
- `sql/analysis/uplift_analysis_queries.sql`
- `docs/personalized_vs_static_uplift_report_2026_02_05.md`

---

## Branch State
- Branch: `main`
- Up to date with `origin/main`
- Working tree: **clean**
- Last commit: `d97ff82` — Add uplift analysis v2 without crash exclusion

---

## Key References

### Uplift Analysis
- V1 queries (crash excluded): `sql/analysis/uplift_analysis_queries.sql`
- V1 report: `docs/personalized_vs_static_uplift_report_2026_02_05.md`
- **V2 queries (full period)**: `sql/analysis/uplift_analysis_queries_v2.sql`
- **V2 report**: `docs/personalized_vs_static_uplift_report_v2.md`
- Base table: `sql/analysis/uplift_base_table.sql`

### Pipeline
- Pipeline v5.17: `sql/recommendations/v5_17_*.sql`
- Pipeline v5.18: `sql/recommendations/v5_18_revenue_ab_test.sql`
- QA checks: `sql/validation/qa_checks.sql`

### Experiment Setup
- Experiment doc: `docs/holley_experiment_setup.md`
- Treatment configs: `configs/personalized_treatments.csv`, `configs/static_treatments.csv`

---

## Next Steps (Potential)

1. **Discuss implications** with stakeholders — Static (Apparel) consistently beats Personalized (Vehicle Parts)
2. **Investigate why** — Is it category preference? Timing? User behavior?
3. **Consider hybrid approach** — Mix vehicle parts + apparel recommendations
4. **Deploy v5.18** with proper A/B test design (not 100x boost factor)
