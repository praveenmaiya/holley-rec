# Pipeline Run Statistics

Historical record of recommendation pipeline runs with comparison stats.

---

## Run History

| Date | Version | Users | Notes |
|------|---------|-------|-------|
| Dec 11, 2025 | v5.6.2 (v3) | 456,119 | Commodity filter ($50 min, PartType exclusions) |
| Dec 11, 2025 | v5.6.1 (v2) | 458,826 | Variant dedup fix |
| Dec 11, 2025 | v5.6.1 (v1) | 459,540 | Sep 1 intent window |
| Dec 2, 2025 | v5.6 | 458,859 | Initial production |

---

## Dec 11, 2025: v5.6.2 Commodity Filter

### Changes Made
- Raised price floor from $20 to $50
- Added PartType keyword exclusions (gaskets, decals, bolts, etc.)
- Whitelisted high-value items: Engine Cylinder Head Bolt, Engine Bolt Kit, Distributor Cap Kits, Wheel Hub Cap
- Excluded UNKNOWN parts under $3,000

### PartType Exclusions
| Pattern | Examples |
|---------|----------|
| `%Gasket%` | Manifold gaskets, valve cover gaskets |
| `%Decal%` | Fender decals, engine decals |
| `%Key%` | Woodruff keys |
| `%Washer%` | Fluid reservoirs, nozzles |
| `%Clamp%` | Fuel hose clamps |
| `%Bolt%` (except Engine Bolt Kit) | Oil pan bolts, header bolts |
| `%Cap%` (except Distributor/Wheel) | Valve caps, oil filler caps |

### Comparison: v3 (Commodity Filter) vs v2 (Variant Fix)

#### Summary Stats
| Metric | v3 (Commodity) | v2 (Variant) | Change |
|--------|----------------|--------------|--------|
| Users | 456,119 | 458,826 | -2,707 |
| Avg Price | $465.87 | $282.69 | +65% |
| Min Price | $50.57 | $20.00 | +$30 |
| Avg Score | 11.046 | 11.604 | -4.8% |

#### User Counts
| Metric | Count |
|--------|-------|
| Users in both | 456,097 |
| Dropped (< 4 non-commodity recs) | 2,729 |
| New users | 22 |

#### Recommendation Stability (456,097 common users)
| Metric | Count | % |
|--------|-------|---|
| Exactly same | 146,144 | 32.04% |
| Different SKUs | 309,953 | 67.96% |

68% of users had recommendations change because commodity parts were replaced with higher-quality alternatives.

#### Price Bucket Shift
| Bucket | v2 | v3 | Change |
|--------|----|----|--------|
| $20-50 | 534,696 | 0 | -100% (eliminated) |
| $50-100 | 193,732 | 137,289 | -29% |
| $100-250 | 367,019 | 619,583 | +69% |
| $250-500 | 576,924 | 688,006 | +19% |
| $500-1000 | 102,545 | 173,708 | +69% |
| $1000+ | 60,388 | 205,890 | +241% |

#### Revenue Potential Per User
| Position | v2 Avg | v3 Avg | Change |
|----------|--------|--------|--------|
| Position 1 | $240.85 | $339.68 | +41% |
| Position 2 | $305.55 | $380.79 | +25% |
| Position 3 | $288.55 | $476.74 | +65% |
| Position 4 | $295.83 | $666.26 | +125% |
| **Total/User** | **$1,130.78** | **$1,863.48** | **+65%** |

#### Revenue Potential (at 1% conversion)
| Version | Users | Potential Revenue |
|---------|-------|-------------------|
| v2 | 458,826 | $5.2M |
| v3 | 456,119 | $8.5M |
| **Increase** | | **+$3.3M (+64%)** |

#### Top SKUs Removed (under $50)
| SKU | Price | v2 Count | Reason |
|-----|-------|----------|--------|
| 71223029HKR | $43.21 | 212,431 | Below $50 |
| 71223015HKR | $20.44 | 111,093 | Below $50 |
| 71221018HKR | $46.62 | 62,579 | Below $50 |
| 60850G (Oil Pan Bolt Set) | $34.11 | 12,803 | Below $50 |

#### Top SKUs Gained (replacements)
| SKU | Price | v3 Count | Type |
|-----|-------|----------|------|
| 550-849K | $1,499.95 | 171,315 | Fuel Injection Conversion Kit |
| LFRB135 | - | 122,641 | Performance |
| 0-80350 | $579.95 | 75,682 | Carburetor |
| BR-67276 | - | 31,461 | Performance |

#### Tables
| Table | Content |
|-------|---------|
| `company_1950_jp.final_vehicle_recommendations` | Production (v3 with commodity filter) |
| `company_1950_jp.final_vehicle_recommendations_2025_12_11_v3` | Backup (v3) |
| `company_1950_jp.final_vehicle_recommendations_2025_12_11_v2` | Backup (v2 variant fix) |

---

## Dec 11, 2025: v5.6.1 Variant Dedup Fix

### Changes Made
- Fixed variant dedup regex to catch single-character suffixes (B, R, G, P)
- Before: `(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{2})$`
- After: `(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2}|[BRGP])$`

### Comparison: After Fix (v2) vs Before Fix (v1)

#### User Counts
| Metric | After Fix | Before Fix | Diff |
|--------|-----------|------------|------|
| Total Users | 458,826 | 459,540 | -714 |
| Users in both | 458,805 | 458,805 | 0 |
| Dropped (< 4 unique recs) | - | 735 | -735 |
| New users | 21 | - | +21 |

#### Recommendation Stability (458,805 common users)
| Metric | Count | % |
|--------|-------|---|
| Exactly same | 424,266 | 92.47% |
| Same SKUs, diff order | 1,493 | 0.33% |
| Different SKUs | 33,046 | 7.20% |

#### Position-Level Changes
| Position | Unchanged | Changed | % Unchanged |
|----------|-----------|---------|-------------|
| Position 1 | 458,740 | 65 | 99.99% |
| Position 2 | 444,442 | 14,363 | 96.87% |
| Position 3 | 427,079 | 31,726 | 93.09% |
| Position 4 | 427,847 | 30,958 | 93.25% |

#### Score Distribution
| Run | Avg Score | Pos 1 | Pos 2 | Pos 3 | Pos 4 |
|-----|-----------|-------|-------|-------|-------|
| After Fix | 11.604 | 13.375 | 11.686 | 10.925 | 10.431 |
| Before Fix | 11.652 | 13.354 | 11.722 | 11.014 | 10.516 |

#### Top SKUs Removed (Variant Dedup)
| SKU | After | Before | Diff | Reason |
|-----|-------|--------|------|--------|
| RA003R | 405 | 31,311 | -30,906 | Deduped with RA003B |
| RA003G | 0 | 400 | -400 | Deduped with RA003B |
| 140333 | 0 | 505 | -505 | Variant deduped |
| 140085K | 0 | 469 | -469 | Variant deduped |
| 140084K | 0 | 311 | -311 | Variant deduped |

#### Top SKUs Added (Replacements)
| SKU | After | Before | Diff | Type |
|-----|-------|--------|------|------|
| 8245 | 52,775 | 41,385 | +11,390 | Replacement |
| FRRA003X | 5,772 | 12 | +5,760 | Multi-Function Module |
| 60850G | 12,803 | 7,878 | +4,925 | Replacement |
| 8733 | 10,125 | 5,663 | +4,462 | Replacement |
| 6665G | 8,390 | 5,683 | +2,707 | Replacement |

#### Tables
| Table | Content |
|-------|---------|
| `company_1950_jp.final_vehicle_recommendations` | Production (v2 with fix) |
| `company_1950_jp.final_vehicle_recommendations_2025_12_11_v2` | Backup (v2) |
| `company_1950_jp.final_vehicle_recommendations_2025_12_11` | Backup (v1 pre-fix) |

---

## Dec 11, 2025: v5.6.1 vs Dec 2 v5.6 (Fresh Data Comparison)

### Changes Made
- Intent window: Rolling 93 days → Fixed Sep 1, 2025 start
- Added 9 days of fresh behavioral data (Dec 3-11)

### Comparison: Dec 11 (v1) vs Dec 2

#### User Counts
| Metric | Dec 11 | Dec 2 | Diff |
|--------|--------|-------|------|
| Total Users | 459,540 | 458,859 | +681 |
| Users in both | 458,788 | 458,788 | 0 |
| New users | 752 | - | +752 |
| Dropped users | - | 71 | -71 |

#### Recommendation Stability (458,788 common users)
| Metric | Count | % |
|--------|-------|---|
| Exactly same | 393,462 | 85.76% |
| Same SKUs, diff order | 21,444 | 4.67% |
| Different SKUs | 43,882 | 9.56% |

#### Position-Level Changes
| Position | Unchanged | Changed | % Unchanged |
|----------|-----------|---------|-------------|
| Position 1 | 450,423 | 8,365 | 98.18% |
| Position 2 | 443,887 | 14,901 | 96.75% |
| Position 3 | 434,494 | 24,294 | 94.70% |
| Position 4 | 406,397 | 52,391 | 88.58% |

#### Score Distribution
| Run | Avg Score | Pos 1 Avg | Pos 4 Avg | Max |
|-----|-----------|-----------|-----------|-----|
| Dec 11 | 11.652 | 13.354 | 10.516 | 55.74 |
| Dec 2 | 11.527 | 13.179 | 10.413 | 55.58 |

Scores increased +1.1% due to additional 9 days of intent data.

#### Why Recommendations Changed
| Reason | Users | % |
|--------|-------|---|
| No intent (popularity shift) | 62,495 | 95.67% |
| 1-3 intent SKUs | 1,972 | 3.02% |
| 4-10 intent SKUs | 672 | 1.03% |
| 10+ intent SKUs | 187 | 0.29% |

#### Top SKUs with Movement
| SKU | Dec 11 | Dec 2 | Change |
|-----|--------|-------|--------|
| 8202 | 99,567 | 87,685 | +11,882 |
| 71221018HKR | 62,580 | 73,691 | -11,111 |
| 0-80350 | 18,214 | 7,836 | +10,378 |
| 0-4412S | 7,878 | 18,235 | -10,357 |

---

## Validation Checks (Current Production)

| Check | Expected | Dec 11 v3 |
|-------|----------|-----------|
| Users | ≥400,000 | 456,119 ✅ |
| Recs per user | 4 | 4 ✅ |
| Duplicate SKUs | 0 | 0 ✅ |
| Min price | ≥$50 | $50.57 ✅ |
| Commodity parts | 0 | 0 ✅ |
| Refurbished | 0 | 0 ✅ |
| Variant duplicates | 0 | 0 ✅ |

---

## Backup Inventory

| Table | Date | Users | Notes |
|-------|------|-------|-------|
| `final_vehicle_recommendations` | Dec 11 | 456,119 | Current production (v3 commodity filter) |
| `final_vehicle_recommendations_2025_12_11_v3` | Dec 11 | 456,119 | Backup with commodity filter |
| `final_vehicle_recommendations_2025_12_11_v2` | Dec 11 | 458,826 | Backup with variant fix |
| `final_vehicle_recommendations_2025_12_11` | Dec 11 | 459,540 | Pre-fix run |
| `final_vehicle_recommendations_2025_12_02` | Dec 2 | 458,859 | Previous production |
