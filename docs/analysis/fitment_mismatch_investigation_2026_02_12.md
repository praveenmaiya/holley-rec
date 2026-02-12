# Fitment Mismatch Investigation — Feb 12, 2026

**Date:** February 12, 2026
**Trigger:** Employee complaint (Tom Patton, tpatton@goapr.com) — 2019 Volkswagen Golf received 3/4 incorrect product recommendations
**Scope:** All users in production recommendations (`final_vehicle_recommendations`)
**Pipeline version:** v5.17

## Executive Summary

A Holley employee reported that 3 of 4 recommended products for their 2019 Volkswagen Golf don't fit the vehicle (including a carburetor for a modern fuel-injected car). Investigation confirms the complaint is valid and reveals a **systemic pipeline flaw**: 51.2% of users with vehicle data (258K users) receive zero vehicle-specific fitment products in their recommendations. Of those, 84.2% (217K users) actually had fitment parts available — the pipeline had the right products but scored them too low.

**Root cause:** The v5.17 scoring algorithm has no slot reservation for fitment products. Universal products compete equally on popularity score and systematically outscore fitment products due to broader purchase history.

## The Complaint

From Tom Patton (APR/Holley employee):
> "Apparently, I need a Carburetor and Installation Kit for my 2019 VOLKSWAGEN GOLF that looks like a G82. 1 applicable product and 3 that don't even make sense."

The Holley product team for Euro confirmed: the APR ignition coil (1st product) is correct, the other 3 would not be appropriate.

## Complaint Validation

### Products Recommended to 2019 VW Golf Owners

| Slot | SKU | Product | PartType | Fits Golf? | UniversalPart Flag |
|:----:|------|---------|----------|:----------:|:------------------:|
| 1 | MS100192 | APR Ignition Coil | Ignition Coil | Yes | 0 |
| 2 | 554-102 | Fuel Injection Pressure Sensor | Fuel Injection Pressure Sensor | **No** | 1 |
| 3 | 145-160 | Accelerator Pedal Assembly | Accelerator Pedal Assembly | **No** | 0 (but zero fitment data) |
| 4 | 190004 | Carburetor and Installation Kit | Carburetor and Installation Kit | **No** | 1 |

All 12 users with a 2019 VW Golf received the identical 4 recommendations.

### Fitment Data Quality Is Sound

- **99 products** have actual vehicle fitment data for 2019 VW Golf in `vehicle_product_fitment_data`
- These include legitimate Golf-specific parts: diagnostic scan tools, brake conversion kits, hydraulic line sets, cold air intakes, oil catch cans, boost gauges, active suspension modules
- **939 eligible parts** remain after all quality filters ($50+ price, HTTPS image, non-refurbished) across 41 distinct part types
- The data is correct — the algorithm is wrong

## Root Cause Analysis

### How the v5.17 Pipeline Scores Products

```
final_score = intent_score + popularity_score
```

The pipeline creates two candidate pools (fitment + universal), scores them identically, then takes the **top 4 by final_score regardless of product type**. There is no slot reservation for fitment products.

### Why Universal Products Win

Popularity scoring uses a 3-tier fallback with different weights:

| Tier | Scope | Weight | Threshold |
|------|-------|:------:|-----------|
| 1 - Segment | Same make + model buyers | 10.0 | Min 5 segment orders |
| 2 - Make | Same make buyers | 8.0 | Fallback |
| 3 - Global | All buyers | 2.0 | Last resort |

**The problem:** Universal products accumulate purchases across the entire 500K+ user base. A universal oil filter might have 5+ orders from Golf owners, 5+ from Mustang owners, 5+ from Corvette owners — achieving **tier 1 segment-level scoring (weight 10.0) across multiple segments**.

Meanwhile, Golf-specific fitment products can only accumulate segment popularity from Golf owners — a much smaller pool.

### VW Golf Specifically

| Metric | Value |
|--------|-------|
| Products with Golf fitment data | 99 |
| Eligible parts after filters | 939 (41 part types) |
| Products with segment purchase history | **2** (MS100192 and MS100137, 2 orders each) |
| Segment popularity threshold (tier 1) | 5 orders minimum |

Only 2 of 939 Golf fitment products have any purchase history from Golf owners, and neither meets the tier 1 threshold of 5 orders. This forces 937 fitment products to fall back to make-level (weight 8.0) or global (weight 2.0) scoring — dramatically reducing their competitiveness against universals with tier 1 scores.

### Scoring Example (2019 Golf)

| Product | Type | Score | Popularity Source |
|---------|------|:-----:|:-----------------:|
| MS100192 (APR Ignition Coil) | fitment | 15.57 | make (rank 2 in VW) |
| 554-102 (Fuel Pressure Sensor) | universal | 11.09 | make (rank 4 in VW) |
| 145-160 (Accelerator Pedal) | universal | ~10+ | segment/make |
| 190004 (Carburetor Kit) | universal | ~10+ | segment/make |

MS100192 won slot 1 as the top fitment product, but the remaining 3 slots went to universal products that outscored the other 938 fitment products.

## Scale of the Problem

### Fitment Distribution Across All Users

| Fitment Recs (of 4) | Users | % of Users |
|:--------------------:|------:|-----------:|
| **0** | **258,188** | **51.2%** |
| 1 | 119,156 | 23.6% |
| 2 | 73,570 | 14.6% |
| 3 | 45,734 | 9.1% |
| 4 | 7,628 | 1.5% |
| **Total with vehicle data** | **504,276** | **100%** |

**Half of all users with vehicle data receive zero vehicle-specific recommendations.**

### Users With Available Parts But 0 Fitment Recs

| Metric | Value |
|--------|-------|
| Users with 0 fitment recs | 258,188 |
| Of those, had fitment parts available | **217,393 (84.2%)** |
| Average available fitment parts per user | 353 |
| Range | 4 to 1,182 parts |

**217K users have hundreds of vehicle-specific parts available but receive only universal products.**

### Most Affected Vehicle Segments

These are Holley's core customer segments — getting zero fitment recs despite having thousands of eligible parts:

| Make | Model | Affected Users | Eligible Parts | % of Total Affected |
|------|-------|---------------:|---------------:|--------------------:|
| Ford | Mustang | **52,554** | 2,835 | 22.4% |
| Chevrolet | Camaro | 16,642 | 1,621 | 7.1% |
| Chevrolet | Chevelle | 11,896 | 969 | 5.1% |
| Chevrolet | Corvette | 11,202 | 1,056 | 4.8% |
| Chevrolet | C10 | 11,076 | 1,130 | 4.7% |
| Ford | F-150 | 9,448 | 820 | 4.0% |
| Pontiac | Firebird | 8,388 | 1,231 | 3.6% |
| Chevrolet | Nova | 6,133 | 887 | 2.6% |
| Chevrolet | Impala | 3,772 | 940 | 1.6% |
| Ford | Bronco | 3,562 | 583 | 1.5% |
| Chevrolet | Malibu | 3,416 | 1,150 | 1.5% |
| Chevrolet | Chevy II | 3,275 | 707 | 1.4% |
| Ford | Fairlane | 1,950 | 640 | 0.8% |
| GMC | Sierra | 1,862 | 97 | 0.8% |
| Ford | F-250 | 1,850 | 649 | 0.8% |
| Chevrolet | S10 | 1,672 | 232 | 0.7% |
| Chevrolet | Caprice | 1,622 | 895 | 0.7% |
| Dodge | Charger | 1,561 | 695 | 0.7% |
| Honda | Accord | 1,479 | 56 | 0.6% |
| Chevrolet | Silverado 1500 | 1,432 | 414 | 0.6% |

Ford Mustang alone accounts for 22% of all affected users — 52K people seeing no Mustang parts despite 2,835 eligible SKUs.

## Recommendations

### Immediate Fix: Fitment Slot Reservation

Implement a slot reservation policy in the next pipeline version:

- **Reserve at least 2-3 of 4 slots** for fitment products when available
- Only allow universal products to fill remaining slots, or when fewer fitment products exist
- This would fix the issue for the 217K users who have fitment parts available

### Scoring Improvements

1. **Penalize universal products** when fitment alternatives exist — add a type-based score adjustment
2. **Cold-start handling for fitment products** — when a segment has <5 orders, boost fitment products to prevent universal takeover
3. **Cap universal product representation** — never more than 1 universal in a 4-product recommendation set when fitment options exist

### Data Pipeline

4. **Add monitoring** for fitment-to-universal ratio in production recs — alert if >50% of users receive 0 fitment
5. **Track segment purchase coverage** — identify segments where <5% of fitment products have purchase history (cold-start risk)

## Data Sources

- **Production recs:** `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
- **Eligible parts:** `auxia-reporting.temp_holley_v5_17.eligible_parts`
- **Segment popularity:** `auxia-reporting.temp_holley_v5_17.segment_popularity`
- **Scored recs:** `auxia-reporting.temp_holley_v5_17.scored_recommendations`
- **Fitment data:** `auxia-gcp.data_company_1950.vehicle_product_fitment_data`
- **Product catalog:** `auxia-gcp.data_company_1950.import_items`
