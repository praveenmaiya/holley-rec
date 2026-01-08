# V5.15 Investigation Summary

**Date**: 2026-01-07
**Issue**: Earlier backtest claimed +162% improvement, but re-running shows only +16%

---

## Key Finding: Earlier +162% Result Was Incorrect

The current backtest consistently shows:
- **December**: V5.12 (144) → V5.15 (167) = **+16%**
- **November**: V5.12 (230) → V5.15 (243) = **+5.7%**

The earlier +162% to +461% numbers were from a buggy or different version.

---

## Why V5.15 Improvement Is Limited

### Universal Products Displace Fitment Products

| Metric | V5.12 | V5.15 | Change |
|--------|-------|-------|--------|
| Fitment matches | 359 | 191 | **-47%** |
| Universal matches | 0 | 188 | +188 |
| Total matched users | 144 | 167 | +16% |

### Root Cause: Popularity Score Imbalance

Universal products have ~20% higher popularity scores:

| Product Type | Avg Score | Median | Min | Max |
|--------------|-----------|--------|-----|-----|
| Top 500 Universal | 8.22 | 7.74 | 6.73 | 20.27 |
| Top 500 Fitment | 6.84 | 6.52 | 5.42 | 12.44 |

This causes universal products to push fitment out of the top 4 recommendation slots.

---

## V5.15 Configuration (Confirmed)

- **Product Pool**: Fitment + Top 500 Universal
- **Popularity Source**: Global (all 2M users, NOT VFU-only)
- **Scoring**: `final_score = intent_score + popularity_score`

---

## Purchase Distribution (Nov vs Dec)

Both months show similar patterns - not a December-specific issue:

| Metric | November | December |
|--------|----------|----------|
| Total purchases | 5,251 | 8,455 |
| Fitment % | 31.3% | 28.4% |
| Top 500 Universal % | 40.3% | 42.5% |
| Long-tail % | 28.4% | 29.0% |

---

## Options Going Forward

1. **Deploy as-is**: Accept modest +5-16% improvement
2. **Reserved slots**: Guarantee 2 fitment + 2 universal (prevents displacement)
3. **Separate scoring**: Different scoring weights for fitment vs universal
4. **Monitor live**: Deploy and measure actual click/conversion rates

---

## Analysis Files Created

- `sql/analysis/dec_anomaly_investigation.sql` - Purchase distribution comparison
- `sql/analysis/dec_anomaly_investigation_2.sql` - Top 500 concentration analysis
- `sql/analysis/dec_anomaly_investigation_3.sql` - Buyer coverage analysis
- `sql/analysis/dec_anomaly_investigation_4.sql` - VFU timing analysis
- `sql/analysis/score_distribution.sql` - Popularity score comparison

---

*Investigation completed: 2026-01-07*
