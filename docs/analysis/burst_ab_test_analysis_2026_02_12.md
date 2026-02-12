# Burst A/B Test Analysis — Feb 11, 2026

**Date:** February 12, 2026
**Arms:** A (29113222, MSD Highlight) vs B (29113227, Personalized Vehicle Fitment)
**Burst start:** Feb 11, 10:00 AM PST (18:00 UTC)
**Status:** Both treatments paused post-burst

## Executive Summary

Personalized Vehicle Fitment recommendations (Arm B) **outperformed MSD Highlight (Arm A) by 2.85x on CTR of opens** (5.10% vs 1.79%, z=14.6, p<0.01). All three engagement metrics — open rate, CTR of opens, CTR of triggered — were statistically significant in B's favor.

However, **67% of triggered emails were never delivered** due to ESP rate limit saturation. The burst pushed ~3,400 emails/minute against an ESP capacity of ~1,100/minute. Despite this, both arms were equally affected, preserving the validity of the A/B comparison.

## Test Design

| Property | Value |
|----------|-------|
| User overlap between arms | **0 (clean A/B split)** |
| Users in Arm A | 124,611 |
| Users in Arm B | 123,993 |
| Triggers per user per arm | 1.01 (dedup working) |
| Burst window | 18:06–18:42 UTC + 20:06–20:57 UTC |
| Total burst duration | ~70 minutes of active sending |

## Key Findings

### 1. Engagement Results (statistically significant)

| Metric | A: MSD Highlight | B: Personalized Fitment | Lift | z-score | Significance |
|--------|:----------------:|:-----------------------:|:----:|:-------:|:------------:|
| Open rate (of delivered) | 28.04% | 31.74% | +3.70pp | 11.69 | p<0.01 |
| CTR of opens | 1.79% | **5.10%** | +3.31pp | 14.59 | p<0.01 |
| CTR of triggered | 0.16% | **0.53%** | +0.36pp | 15.66 | p<0.01 |

### 2. Full Funnel

| Stage | A: MSD Highlight | B: Personalized Fitment | Notes |
|-------|:----------------:|:-----------------------:|-------|
| Scheduled (treatment_history_sent) | 191,125 | 190,291 | Includes duplicate schedules |
| Triggered (AuxiaEmailTriggered) | 128,386 | 127,611 | ~1 per user (dedup removed duplicates) |
| Delivered (Received Email) | 42,094 (32.8%) | 41,652 (32.6%) | ESP rate limit |
| Opened | 11,805 (28.0%) | 13,220 (31.7%) | |
| Clicked | 211 (1.79%) | 674 (5.10%) | |
| Bounced | — | — | 584 total across both arms |

### 3. Revenue

Only 1 attributable order ($229.95, from Arm B). Too sparse for revenue conclusions.

## Delivery Failure Investigation

### Root Cause: ESP Rate Limit Saturation

The ESP is hard-capped at **~1,100 emails/minute**. The burst pushed **~3,400/minute — 3.1x over capacity**.

| Metric | Value |
|--------|-------|
| ESP throughput cap | ~1,100 emails/min (~66K/hour) |
| Burst trigger rate | ~3,400 emails/min (~204K/hour) |
| Overshoot factor | 3.1x |
| Normal daily volume (Feb 3–9 avg) | ~9,300/day |
| Burst volume | 256K in 70 min (**25x normal daily**) |

### Minute-Level Evidence

Delivery rate held steady at ~33% regardless of trigger volume, confirming a hard rate limit:

| 5-min Window (UTC) | Triggered | Delivered | Delivery % |
|:--------------------|----------:|----------:|-----------:|
| 18:05–18:10 | 6,896 | 1,849 | 26.8% |
| 18:10–18:15 | 15,868 | 4,996 | 31.5% |
| 18:15–18:20 | 17,459 | 5,824 | 33.4% |
| 18:20–18:25 | 17,132 | 5,802 | 33.9% |
| 18:25–18:30 | 16,908 | 5,359 | 31.7% |
| 18:30–18:35 | 16,969 | 4,405 | 26.0% |
| 18:35–18:40 | 17,086 | 5,641 | 33.0% |
| 18:40–18:45 (burst ends) | 3,996 | 61 | 1.5% |
| *~80 min gap* | | | |
| 20:05–20:10 | 9,942 | 2,933 | 29.5% |
| 20:10–20:15 | 14,633 | 4,997 | 34.1% |
| 20:15–20:40 (steady) | ~14K/5min | ~4.7K/5min | 30–35% |
| 20:50–20:57 (tail) | 4,371 | 2,125 | 48.6% |

At the tail (20:50+), when trigger volume drops, delivery % rises to ~49% as the ESP catches up on backlog.

### What Happened to ~172K Undelivered Emails?

| Outcome | Count | % of Triggered |
|---------|------:|:--------------:|
| Delivered | 83,746 | 32.7% |
| Bounced | 584 | 0.2% |
| **Silently dropped** | **~171,700** | **67.1%** |

The ESP did not generate bounce/error events for rate-limited emails — they were silently dropped from the queue.

### Not the Cause

| Factor | Impact | Why It's Not the Cause |
|--------|--------|------------------------|
| Pre-existing suppressions | 8,111 users (3.2%) | Too small to explain 67% |
| Post-burst unsubscribes | 200 users | Normal churn |
| Spam marks | 9 users | Negligible |
| Scheduled→triggered gap | 381K→256K | Dedup working correctly (1.01 triggers/user) |

## Interaction Tracking Issue

The `treatment_interaction` table shows **near-zero data** for both burst treatments. Only 2 internal QA test accounts registered (21 opens, 3 clicks).

Real engagement data exists in Klaviyo events (`ingestion_unified_schema_incremental`) but is not flowing through to `treatment_interaction`. Attribution was performed by chaining:

```
AuxiaEmailTriggered (sendId = treatment_tracking_id)
  → Received Email (matched by user_id + 5-min window → Transmission ID)
    → Opened Email / Clicked Email (matched by Transmission ID)
```

This pipeline gap means the bandit model and standard reporting dashboards cannot see burst campaign performance.

## Feb 10 Simulation Data

All data on Feb 10 was simulation/testing:
- 281K entries in `treatment_history_sent` on Feb 10, but 0 `AuxiaEmailTriggered` events
- Only 2 QA users (`01K9C1SJZA8MHK9CKGAN64DMHW`, `01K9R0PFS7Z1A7BW37D70MX3R2`) had actual interactions
- First 4 test sends had blank subject lines (before subject was configured)
- A third test treatment (29113252, MSD) received 15 QA sends only

## Recommendations

### Immediate
1. **Fix interaction tracking** — burst treatment opens/clicks must flow to `treatment_interaction` for the bandit model and reporting
2. **Implement send pacing** — stay under ~1,000/min. A 256K burst should be spread over ~4.5 hours minimum

### For Future A/B Tests
3. **Clean A/B split was achieved** — this test design works; continue using it
4. **Exclude simulation data** — filter by `treatment_sent_timestamp >= burst start time`
5. **Account for 67% delivery loss** in sample size calculations — effective audience is ~33% of targeted

### Business Decision
6. **Personalized Fitment (Arm B) is the clear winner** — 2.85x CTR with p<0.01 significance. Recommend scaling Personalized Fitment content for future burst campaigns.

## Methodology

- **Data sources:** `treatment_history_sent`, `treatment_interaction`, `ingestion_unified_schema_incremental` (Klaviyo events)
- **Attribution method:** AuxiaEmailTriggered → Received Email chain via user_id + 5-minute time window + Transmission ID
- **Statistical test:** Two-proportion z-test
- **Time window:** Feb 11 18:00 UTC onwards (10:00 AM PST, confirmed burst start)

## SQL Queries

Queries used in this analysis are in `sql/analysis/burst_ab_test_feb11.sql` (original) with additional ad-hoc queries run during investigation.
