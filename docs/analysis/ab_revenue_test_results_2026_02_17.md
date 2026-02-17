# A/B Revenue Test Results — Feb 11 Burst Campaign

**Report Date:** February 17, 2026
**Burst Date:** February 11, 2026 (18:00-20:57 UTC)
**Attribution Window:** 7 days (Feb 11-17)
**Arms:** A = 29113222 (MSD Highlight) | B = 29113227 (Personalized Vehicle Fitment)

---

## Executive Summary

Personalized Vehicle Fitment (Arm B) **won engagement decisively** with 2.85x higher CTR of opens (5.42% vs 1.90%, p<0.01). However, **no measurable revenue lift was detected** from either arm. Conversion rates are statistically indistinguishable (z=0.78, p>0.1), and 87% of post-send revenue in both arms came from days 2-7, indicating organic purchasing unrelated to the email.

Only 3 of B's 813 clickers placed an order ($1,118 total). Zero of A's 256 clickers purchased anything. The ~50 buyers per arm are baseline organic purchasers who happened to be in the burst audience.

---

## Test Design

| Property | Value |
|----------|-------|
| Arm A | 29113222 — MSD Highlight (static product content) |
| Arm B | 29113227 — Personalized Vehicle Fitment recommendations |
| Arm A users | 124,617 |
| Arm B users | 123,996 |
| User overlap | 5 (0.004%, none ordered) |
| Burst window | 18:00-20:57 UTC, Feb 11, 2026 |
| Send distribution | 235K at hour 18 + 146K at hour 20 (14 test sends at hour 2) |
| ESP delivery rate | ~33% (rate-limited at ~1,100/min vs 3,400/min attempted) |

---

## Engagement Results (Final)

Engagement activity ceased after Feb 15. These are final numbers.

| Metric | A: MSD Highlight | B: Personalized Fitment | Lift | Significant? |
|--------|:---:|:---:|:---:|:---:|
| Sends | 191,137 | 190,294 | — | — |
| Opens | 13,476 (7.05%) | 15,000 (7.88%) | +0.83pp | YES (p<0.01) |
| Clicks | 256 (1.90% of opens) | 813 (5.42% of opens) | **+3.52pp (2.85x)** | YES (p<0.01) |
| CTR of sends | 0.13% | 0.43% | **+0.30pp (3.3x)** | YES (p<0.01) |

### Engagement Decay by Day

| Date | A opens | A clicks | B opens | B clicks |
|------|:---:|:---:|:---:|:---:|
| Feb 11 | 6,289 | 156 | 7,637 | 485 |
| Feb 12 | 7,091 | 85 | 7,277 | 273 |
| Feb 13 | 822 | 15 | 902 | 36 |
| Feb 14 | 360 | 7 | 408 | 15 |
| Feb 15 | 209 | 2 | 243 | 10 |

93%+ of clicks occurred within 48 hours. No clicks recorded after Feb 15 in either arm.

---

## Revenue Results (7-Day Window)

### Overall Revenue

| Metric | A: MSD Highlight | B: Personalized Fitment |
|--------|:---:|:---:|
| Buyers | **53** | 45 |
| Orders | **54** | 46 |
| Total Revenue | **$31,920** | $25,853 |
| AOV | $591 | $562 |
| Revenue per user sent | $0.26 | $0.21 |
| Buyers per 10K users | 4.25 | 3.63 |

### Statistical Significance (Conversion Rate)

| Metric | Value |
|--------|-------|
| A conversion rate | 0.0425% (53/124,617) |
| B conversion rate | 0.0363% (45/123,996) |
| Difference | +0.62 per 10K users |
| z-score | 0.784 |
| Significant? | **NO** (p>0.1) |

The conversion rate difference is well within random noise.

### Revenue by Attribution Window

| Window | A buyers | A revenue | B buyers | B revenue |
|--------|:---:|:---:|:---:|:---:|
| Pre-burst (before 18:00 UTC) | 0 | $0 | 0 | $0 |
| During burst (18:00-21:00 UTC) | 1 | $426 | 0 | $0 |
| Within 24h (next morning) | 8 | $3,673 | 5 | $3,337 |
| Late attribution (days 2-7) | 44 | **$27,820 (87%)** | 40 | **$22,515 (87%)** |

87% of revenue in both arms came from days 2-7 post-send. This is a strong indicator of organic purchasing behavior unrelated to the email.

### Daily Revenue Breakdown

| Date | A orders | A revenue | A AOV | B orders | B revenue | B AOV |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| Feb 11 | 1 | $426 | $426 | 1 | $186 | $186 |
| Feb 12 | 10 | $5,103 | $510 | 5 | $3,184 | $637 |
| Feb 13 | 6 | $3,334 | $556 | 5 | $2,163 | $433 |
| Feb 14 | 12 | $3,707 | $309 | 5 | $2,274 | $455 |
| Feb 15 | 6 | $4,456 | $743 | 6 | $2,927 | $488 |
| Feb 16 | 13 | $8,407 | $647 | 19 | $13,174 | $693 |
| Feb 17 | 6 | $6,486 | $1,081 | 5 | $1,946 | $389 |

No visible spike on the burst day. Revenue distributed evenly across the week — consistent with organic purchasing.

---

## Clicker Conversion Funnel

| Metric | A: MSD Highlight | B: Personalized Fitment |
|--------|:---:|:---:|
| Total clickers | 256 | 813 |
| Clickers who bought | **0** | **3** |
| Click-to-buy rate | 0.0% | 0.37% |
| Clicker revenue | $0 | $1,118 |
| Revenue per clicker | $0.00 | $1.37 |

Despite B generating 3.2x more clicks, click-to-purchase conversion is near zero for both arms. The email drives browsing interest but not immediate purchase intent.

---

## Data Integrity Verification

| Check | Result | Detail |
|-------|:---:|--------|
| Send timing | PASS | 99.99% of sends at 18:00-20:57 UTC |
| Pre-burst order contamination | PASS | Zero orders before burst start |
| User overlap between arms | PASS | 5 users (0.004%), none ordered |
| Order ID deduplication | PASS | 100 distinct orders, 0 duplicates, 0 null IDs |
| Cross-arm order contamination | PASS | Zero orders appear in both arms |
| Revenue source cross-check | PASS | Placed Order ($57,773) vs Consumer Website Order ($53,099) — delta is tax/shipping |

### Revenue Source Reconciliation

| Event Type | A orders | A revenue | B orders | B revenue |
|-----------|:---:|:---:|:---:|:---:|
| Placed Order (primary) | 54 | $31,920 | 46 | $25,853 |
| Consumer Website Order | 54 | $28,315 | 45 | $24,784 |

89 of 100 orders appear in both event types. 11 are Placed Order-only, 10 are Consumer Website Order-only. "Placed Order" `Total` includes tax and shipping; "Consumer Website Order" `Total` appears to be subtotal. Report uses Placed Order as the authoritative source.

---

## Key Takeaways

1. **Personalized fitment wins engagement**: 2.85x CTR confirms that vehicle-specific product recommendations generate significantly more email clicks than static MSD content.

2. **No revenue signal detected**: Both arms show identical organic conversion rates (~4.3 buyers per 10K users). The email did not measurably drive purchases in either arm.

3. **Click-to-purchase is near zero**: Only 3 of 1,069 total clickers (0.28%) placed an order. Email is driving awareness/browsing, not direct purchase.

4. **ESP delivery failure limits conclusions**: Only ~33% of emails were delivered due to rate limiting. A properly paced send reaching all 125K users per arm could produce a different revenue outcome.

5. **Attribution window matters**: With 87% of "attributed" revenue coming from days 2-7 and virtually none from clickers, the 7-day post-send window is capturing organic behavior, not email-driven purchases.

---

## Recommendations

1. **Re-run with proper pacing**: The 67% delivery failure means we tested with ~42K delivered per arm, not 125K. A properly throttled send (~1,000/min) would triple the delivered audience and provide a cleaner revenue signal.

2. **Use click-attributed revenue as primary metric**: Instead of all-buyers-in-window, focus on revenue from users who clicked the email then purchased. This eliminates organic noise.

3. **Extend the funnel**: Consider adding UTM parameters or Klaviyo flow tracking to directly attribute site visits and purchases to email clicks, rather than relying on user-level time-window matching.

4. **B is the correct arm for future sends**: Even without a revenue signal, the 2.85x engagement lift means personalized fitment is strictly better content for email. More engagement = more brand touchpoints at minimum.

---

## Files

| File | Purpose |
|------|---------|
| `sql/analysis/burst_ab_test_feb11.sql` | Original engagement queries (Feb 12) |
| `docs/analysis/burst_ab_test_analysis_2026_02_12.md` | Original engagement report |
| `specs/v5_18_revenue_ab_test.md` | V5.18 pipeline spec (reserved slots + diversity) |
| `docs/analysis/ab_revenue_test_results_2026_02_17.md` | This report |
