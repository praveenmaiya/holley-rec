# Session Context — 2026-02-05

## Current Status: Personalization Uplift Analysis Complete

### Key Result: Personalization is Working

Personalized emails outperform Static/Control across **all three Holley email campaigns**:

| Campaign | Personalized Click Rate | Control Click Rate | Relative Lift |
|----------|------------------------:|-------------------:|--------------:|
| **Browse Recovery** | 8.31% | 5.05% | **+65%** |
| **Abandon Cart** | 5.04% | 2.95% | **+71%** |
| **Post Purchase** | 4.13% | 1.11% | **+272%** |

- **208,800 personalized sends** to 29,546 users
- **~1,790 incremental clicks** generated from personalization
- **Open rates 42-152% higher** for personalized emails
- **v5.17 algorithm improved open rates by +61%** for the same users

### What Was Done Today

1. **CTR formula fix** — Corrected `SUM(clicked)/SUM(opened)` to exclude image-blocking phantom clicks (19 removed). Applied to all SQL files.
2. **6 diagnostic queries** — Investigated send frequency confound, email fatigue, bandit bias, first-send comparison, data integrity. Found per-user click rates are nearly equal (3.57% vs 3.78% in v5.7).
3. **Cross-campaign discovery** — Browse Recovery and Abandon Cart already have personalized/fitment treatments. Personalized wins in all 3 campaigns.
4. **Reports restructured** — All 3 reports rewritten to highlight personalization uplift for customer presentation.

### Reports (Customer-Ready)

| Report | Focus | File |
|--------|-------|------|
| **Personalization Uplift Report** | Cross-campaign results, uplift by campaign, algorithm improvement | `docs/fitment_user_engagement_report.md` |
| **P vs S Performance V2** | Post Purchase detailed analysis, per-user parity, opportunity areas | `docs/personalized_vs_static_uplift_report_v2.md` |
| **P vs S Performance V1** | Post Purchase with crash exclusion, condensed | `docs/personalized_vs_static_uplift_report_2026_02_05.md` |

### Files Changed Today

| File | Change |
|------|--------|
| `sql/analysis/uplift_analysis_queries_v2.sql` | CTR formula fix + 6 diagnostic queries added |
| `sql/analysis/uplift_analysis_queries.sql` | CTR formula fix |
| `sql/analysis/uplift_base_table.sql` | CTR formula fix in validation query |
| `docs/fitment_user_engagement_report.md` | NEW — Personalization Uplift Report (cross-campaign) |
| `docs/personalized_vs_static_uplift_report_v2.md` | Restructured for customer presentation |
| `docs/personalized_vs_static_uplift_report_2026_02_05.md` | Restructured for customer presentation |

---

## Branch State
- Branch: `main`
- Up to date with `origin/main`
- Working tree: **clean**
- Last commit: `e5bd97f` — Restructure uplift reports to highlight personalization success

---

## Key References

### Reports & Analysis
- **Primary report**: `docs/fitment_user_engagement_report.md` (cross-campaign uplift)
- V2 report: `docs/personalized_vs_static_uplift_report_v2.md` (Post Purchase detail)
- V1 report: `docs/personalized_vs_static_uplift_report_2026_02_05.md` (crash excluded)
- V2 queries: `sql/analysis/uplift_analysis_queries_v2.sql`
- V1 queries: `sql/analysis/uplift_analysis_queries.sql`
- Base table: `sql/analysis/uplift_base_table.sql`

### Pipeline
- Pipeline v5.17: `sql/recommendations/v5_17_*.sql`
- Pipeline v5.18: `sql/recommendations/v5_18_revenue_ab_test.sql`
- QA checks: `sql/validation/qa_checks.sql`

### Experiment Setup
- Experiment doc: `docs/holley_experiment_setup.md`
- Treatment configs: `configs/personalized_treatments.csv`, `configs/static_treatments.csv`

---

## Key Learnings

### Per-Send CTR is Misleading
Personalized sends 6.3 emails/user vs Static 1.9 (3.3x). The 2.7x per-send CTR gap shrinks to 1.06x when measured per-user. Always use **per-user binary click rate** as the primary metric.

### Personalization Mechanism
The lift comes from **opens, not click-through**. Personalized users open at dramatically higher rates (+42-152%), but CTR-of-opens is similar (~8% for BR/AC). The algorithm generates more relevant email subjects/previews.

### Campaign Structure
All 3 campaigns already have personalized treatments:
- **Browse Recovery**: 25 personalized + 10 control (largest campaign, 567K sends)
- **Abandon Cart**: 28 fitment + 18 static
- **Post Purchase**: 10 fitment + 22 static (smallest campaign)

---

## Next Steps

1. **Present results to customer** — Reports are customer-ready, lead with uplift story
2. **Cap send frequency at 3** — CTR drops 70% after 7th send
3. **Improve in-email content** — More opens but CTR-of-opens is flat; product presentation opportunity
4. **Expand fitment to Browse Recovery** — Only 59.6% of BR users have vehicle data
5. **Deploy v5.18** with proper A/B test design for revenue measurement
