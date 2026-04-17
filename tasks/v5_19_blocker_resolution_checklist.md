# V5.19 Blocker Resolution Checklist

Date: 2026-04-16
Purpose: resolve the remaining contract blockers from [specs/v5_19_updated_ticket_design.md](/Users/praveenm/dev/auxia/holley-rec/specs/v5_19_updated_ticket_design.md) before writing the SQL-shaping spec.

## Exit criteria

All three resolved as of 2026-04-16 pass 7 (see "Observed results" below). SQL-shaping spec work is unblocked.

1. ✅ Cadence — user confirmed daily recommender + batched daily sends.
2. ✅ Browse-recovery `N` — parameterized via DECLARE with default `7`, changeable in one place; campaign-ops SLA is a tuning follow-up, not a blocker.
3. ✅ Cart-state derivation — verified across 7 queries; latest CART UPDATE snapshot is the agreed offline derivation. Residual: post-checkout staleness, covered by Layer 2 lifetime-purchase exclusion.

## Decision checklist

### Blocker 1: Build cadence

Owner:
- send-platform team

Decision needed:
- Is `daily batch pre-compute + next-day sends` acceptable for this single-table design?

Exact question to resolve:
- Do any browse-recovery or abandoned-cart sends require same-day or sub-day trigger accuracy against cart/view state?
- Is up to `24h` staleness on cart/view exclusion acceptable for `final_vehicle_recommendations`?

Acceptable answer:
- `Yes` only if the send platform consumes a daily-built table for next-day sends and accepts that events after the build cutoff are not reflected until the next build.

If the answer is `No`:
- The current single-table offline design is not sufficient.
- The architecture must be revisited before SQL spec work.

### Blocker 2: Browse-recovery lookback

Owner:
- campaign-ops team

Decision needed:
- What is the maximum time between a browse event and a browse-recovery send?

Exact question to resolve:
- What is the browse-recovery email flow SLA in whole days?

Resolution rule:
- If the browse-recovery flow can fire up to `3` days after view, set `N = 3`.
- If it can fire up to `7` days after view, set `N = 7`.
- In general, set `N` equal to the maximum browse-to-send delay of the browse-recovery campaign.

If `N` is not fixed:
- SQL should not be written with a placeholder.
- The exclusion semantics remain ambiguous.

### Blocker 3: Cart-state derivation

Owner:
- data / pipeline owner

Decision needed:
- Is `latest CART UPDATE per user -> unnest items_N.productid` reliable enough to represent the active cart as of build time?

What must be checked:
- cart-clear behavior
- checkout transition behavior
- multi-user-id-per-email edge cases
- SKU normalization parity with recommendation filters

## BigQuery verification queries

Run these in order. They are meant to verify the cart-state assumption, not to define the final SQL yet.

### Query 1: Confirm cart-event mix

```sql
SELECT
  UPPER(event_name) AS event_name,
  COUNT(*) AS n
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
WHERE DATE(client_event_timestamp) >= CURRENT_DATE() - 30
  AND UPPER(event_name) LIKE '%CART%'
GROUP BY 1
ORDER BY n DESC;
```

Expected use:
- Verify `CART UPDATE` is the dominant cart-state source.
- Confirm that `AUTOMATIC ABANDONED CART PROMO` is outbound noise, not user cart state.

### Query 2: Inspect a known CART UPDATE payload

```sql
SELECT
  user_id,
  client_event_timestamp,
  UPPER(event_name) AS event_name,
  ARRAY_AGG(
    STRUCT(
      event_property.property_name AS property_name,
      COALESCE(
        CAST(event_property.string_value AS STRING),
        CAST(event_property.long_value AS STRING),
        CAST(event_property.double_value AS STRING)
      ) AS property_value
    )
    ORDER BY event_property.property_name
  ) AS props
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`,
UNNEST(event_properties) AS event_property
WHERE user_id = '01KPAEZN91NXPVA3Y07WE4F5BV'
  AND UPPER(event_name) = 'CART UPDATE'
GROUP BY 1, 2, 3
ORDER BY client_event_timestamp DESC
LIMIT 5;
```

Expected use:
- Confirm the payload really is a full cart snapshot with `items_N.productid`.
- Confirm whether price/image fields line up by `N` as expected.

### Query 3: Reconstruct cart snapshots for one user across a session

```sql
WITH cart_events AS (
  SELECT
    user_id,
    client_event_timestamp AS event_ts,
    UPPER(event_name) AS event_name,
    REGEXP_EXTRACT(LOWER(ep.property_name), r'^items_([0-9]+)\\.productid$') AS item_idx,
    UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)))) AS sku
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
       UNNEST(e.event_properties) ep
  WHERE user_id = '01KPAEZN91NXPVA3Y07WE4F5BV'
    AND UPPER(event_name) IN ('CART UPDATE', 'PLACED ORDER', 'ORDERED PRODUCT', 'CONSUMER WEBSITE ORDER')
),
cart_snapshots AS (
  SELECT
    user_id,
    event_ts,
    event_name,
    ARRAY_AGG(sku ORDER BY SAFE_CAST(item_idx AS INT64), sku) AS cart_skus
  FROM cart_events
  WHERE event_name = 'CART UPDATE'
    AND item_idx IS NOT NULL
    AND sku IS NOT NULL
  GROUP BY 1, 2, 3
)
SELECT *
FROM cart_snapshots
ORDER BY event_ts DESC;
```

Expected use:
- Inspect whether successive `CART UPDATE` events look like full cart replacements.
- Check whether later snapshots actually remove prior items.

### Query 4: Find candidate cart-clear sessions

```sql
WITH cart_event_counts AS (
  SELECT
    user_id,
    client_event_timestamp AS event_ts,
    COUNTIF(REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\\.productid$')) AS item_count
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
       UNNEST(e.event_properties) ep
  WHERE DATE(client_event_timestamp) >= CURRENT_DATE() - 30
    AND UPPER(event_name) = 'CART UPDATE'
  GROUP BY 1, 2
)
SELECT *
FROM cart_event_counts
WHERE item_count = 0
ORDER BY event_ts DESC
LIMIT 50;
```

Expected use:
- Determine whether cart-clear emits a `CART UPDATE` with zero `items_N.productid`.
- If this returns nothing, stale-cart risk remains and must be documented.

### Query 5: Checkout transition spot check

```sql
WITH timeline AS (
  SELECT
    user_id,
    client_event_timestamp AS event_ts,
    UPPER(event_name) AS event_name,
    ARRAY_AGG(
      DISTINCT UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING))))
      IGNORE NULLS
    ) AS skus
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
       UNNEST(e.event_properties) ep
  WHERE DATE(client_event_timestamp) >= CURRENT_DATE() - 30
    AND UPPER(event_name) IN ('CART UPDATE', 'PLACED ORDER', 'ORDERED PRODUCT', 'CONSUMER WEBSITE ORDER')
    AND (
      REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\\.productid$')
      OR REGEXP_CONTAINS(LOWER(ep.property_name), r'^prod(?:uct)?id$')
      OR REGEXP_CONTAINS(LOWER(ep.property_name), r'^skus_[0-9]+$')
    )
  GROUP BY 1, 2, 3
),
ordered_users AS (
  SELECT DISTINCT user_id
  FROM timeline
  WHERE event_name IN ('PLACED ORDER', 'ORDERED PRODUCT', 'CONSUMER WEBSITE ORDER')
)
SELECT *
FROM timeline
WHERE user_id IN (SELECT user_id FROM ordered_users)
ORDER BY user_id, event_ts DESC
LIMIT 200;
```

Expected use:
- Inspect whether carts disappear cleanly after checkout.
- Check whether a post-purchase `CART UPDATE` persists purchased items.

### Query 6: Multi-user-id-per-email collision check

```sql
WITH latest_email AS (
  SELECT
    t.user_id,
    LOWER(TRIM(p.string_value)) AS email_lower,
    ROW_NUMBER() OVER (
      PARTITION BY t.user_id
      ORDER BY t.update_timestamp DESC, t.auxia_insertion_timestamp DESC
    ) AS rn
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` t,
       UNNEST(t.user_properties) p
  WHERE LOWER(p.property_name) = 'email'
    AND p.string_value IS NOT NULL
    AND TRIM(p.string_value) != ''
),
cart_users AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE DATE(client_event_timestamp) >= CURRENT_DATE() - 30
    AND UPPER(event_name) = 'CART UPDATE'
)
SELECT
  e.email_lower,
  COUNT(DISTINCT e.user_id) AS user_ids_with_cart_updates,
  ARRAY_AGG(DISTINCT e.user_id ORDER BY e.user_id LIMIT 10) AS sample_user_ids
FROM latest_email e
JOIN cart_users c ON e.user_id = c.user_id
WHERE e.rn = 1
GROUP BY 1
HAVING COUNT(DISTINCT e.user_id) > 1
ORDER BY user_ids_with_cart_updates DESC, email_lower
LIMIT 100;
```

Expected use:
- Quantify how often email-level merging can affect cart-state derivation.
- Decide whether “latest cart snapshot per chosen user_id” is acceptable, or whether cart seeds must merge across user_ids sharing an email.

### Query 7: SKU normalization parity check

```sql
WITH latest_cart AS (
  SELECT
    user_id,
    client_event_timestamp AS event_ts,
    UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)))) AS raw_sku
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
       UNNEST(e.event_properties) ep
  WHERE DATE(client_event_timestamp) >= CURRENT_DATE() - 30
    AND UPPER(event_name) = 'CART UPDATE'
    AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\\.productid$')
),
normalized AS (
  SELECT
    raw_sku,
    REGEXP_REPLACE(raw_sku, r'([0-9])[BRGP]$', r'\\1') AS sku_norm
  FROM latest_cart
  WHERE raw_sku IS NOT NULL
)
SELECT
  COUNT(*) AS cart_rows,
  COUNT(DISTINCT raw_sku) AS distinct_raw_skus,
  COUNT(DISTINCT sku_norm) AS distinct_normalized_skus
FROM normalized;
```

Expected use:
- Verify cart SKUs normalize into the same SKU space as purchase exclusion and catalog eligibility.

## Resolution template

Record the outcome in one short block:

```md
Cadence:
- Owner:
- Decision:
- Evidence:

Browse SLA / N:
- Owner:
- Decision:
- Evidence:

Cart-state derivation:
- Verified queries:
- Result:
- Accepted residual risk:
```

## Observed results (2026-04-16)

Cadence:
- Owner: send-platform team
- Decision: **resolved (user, pass 7)** — recommender runs once per day; email sends happen in batches throughout the day from that single daily-refreshed recommendation table. Up-to-24h staleness accepted.
- Evidence: user confirmation. Empirical cross-check: `treatment_history_sent` shows intra-day send distribution (multiple batches per day), consistent with sends pulling from a daily-built rec table.

Browse SLA / N:
- Owner: campaign-ops team
- Decision: **parameterized (user, pass 7)** — not a hard value. Implemented as a BigQuery scripting DECLARE `browse_recovery_lookback_days INT64 DEFAULT 7;`. Default `7` is the working value; changeable in one place once campaign-ops returns the actual SLA. No longer a blocker.
- Evidence: user directive "make it parameterized, don't hardcode, keep it 7 days now, later we can change."

Cart-state derivation:
- Verified queries:
  - Query 1: cart-event mix
  - Query 2: known `CART UPDATE` payload inspection
  - Query 3: cart snapshot reconstruction for sample user `01KPAEZN91NXPVA3Y07WE4F5BV`
  - Query 4: zero-item cart update detection
  - Query 5: checkout transition spot check
  - Query 6: multi-user-id-per-email collision check
  - Query 7: SKU normalization parity check
- Result:
  - `CART UPDATE` is the dominant cart event in the last 30 days: `49,642` rows, versus `2,006` `AUTOMATIC ABANDONED CART PROMO` and `708` `ADDED TO CART`.
  - Sample payloads confirm `CART UPDATE` carries full cart snapshots via `Items_N.ProductId`.
  - Session reconstruction for user `01KPAEZN91NXPVA3Y07WE4F5BV` showed real cart-state transitions:
    - `[50-1200]`
    - `[50-1200, 50-1235]`
    - `[50-1235]`
  - Zero-item cart updates do exist: `57` zero-item `CART UPDATE` events across `51` users in the last 30 days.
  - A raw zero-item example is confirmed for user `01KP94YERCQAWMGFK7A6J16FH6` on `2026-04-15 18:03:55`, with `value=0` and no `Items_N.ProductId` properties.
  - Multi-user-id-per-email collisions were not observed in the 30-day cart sample query.
  - SKU normalization is aligned with the recommendation SKU space:
    - `117,768` cart item rows
    - `8,635` distinct raw SKUs
    - `8,581` distinct normalized SKUs
  - Checkout cleanup is not timely/reliable enough to treat post-order cart clearing as guaranteed:
    - `11,210` users had a non-empty cart before an order
    - `93` had any `CART UPDATE` within `1h` after order
    - `0` had a zero-item `CART UPDATE` within `1h` after order
- Accepted residual risk:
  - `latest CART UPDATE -> items_N.productid` is acceptable as the offline cart snapshot derivation for exclusion logic.
  - Empty-cart events exist, so cart clears are representable.
  - However, post-checkout cart clearing is not timely/reliable; the latest cart snapshot can remain stale after purchase until a later cart event arrives.
  - `lifetime purchase exclusion` protects against recommending the purchased SKU itself, but abandon-cart exclusion may still reflect stale pre-checkout cart contents until the next observed cart snapshot.

## Next move after resolution

All three blockers are resolved (pass 7, 2026-04-16). Remaining work:

1. ✅ [specs/v5_19_updated_ticket_design.md](/Users/praveenm/dev/auxia/holley-rec/specs/v5_19_updated_ticket_design.md) updated with final blocker outcomes (pass-7 revision).
2. Draft the SQL-shaping spec. Use `DECLARE browse_recovery_lookback_days INT64 DEFAULT 7;` — no placeholder.
3. Reshape `sql/recommendations/v5_19_non_fitment_recommendations.sql` per the SQL-shaping spec.
