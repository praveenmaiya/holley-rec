# Known Issues & Gotchas

Living document of issues discovered during development. Update when new gotchas are found.

---

## BigQuery

| Issue | Impact | Workaround |
|-------|--------|------------|
| Cart event fires AFTER purchase | Can't use cart timestamp for conversion ordering | Use presence-based matching, not timestamp comparison |
| `treatment_interaction` has ~1 day lag | Real-time CTR not possible | Use 60-day aggregates for analysis |
| `ProductId` vs `ProductID` case sensitivity | Query fails silently or returns empty | Cart events: `ProductId` (lowercase d), Order events: `ProductID` (uppercase D) |
| Protocol-relative URLs (`//cdn.example.com`) | Email clients don't render images | Use `REPLACE(url, '//cdn', 'https://cdn')` |
| `\d` not supported in BigQuery regex | Regex fails | Use `[0-9]` instead of `\d` |
| PARSE_DATE blocks partition pruning | Full table scan | Filter with string LIKE first, then PARSE_DATE |

## Data Quality

| Issue | Impact | Workaround |
|-------|--------|------------|
| Some users have multiple vehicles | Could get mixed recommendations | Currently use first vehicle (by event_timestamp) |
| Empty string vs NULL in properties | Inconsistent filtering | Always use `COALESCE(string_value, CAST(long_value AS STRING))` and check for both |
| Refurbished items in catalog | Should be excluded from recs | Filter via `import_items_tags` where `Tags != 'Refurbished'` |
| Service SKUs (EXT-, GIFT-, etc.) | Not real products | Exclude with prefix filter in eligible_parts |

## Treatment System

| Issue | Impact | Workaround |
|-------|--------|------------|
| Personalized treatments require vehicle data | Users without vehicle can't receive personalized | Filter to eligible users when comparing |
| Bandit model sends to low-score users | Open rate appears lower than random | This is intentional exploration - compare CTR/open, not CTR/send |
| Treatment boost_factor varies 100x | Unfair comparison if not normalized | Always check boost_factor when analyzing |
| Some treatments are paused | Skews recent data | Filter `is_paused = false` or check dates |

## Pipeline

| Issue | Impact | Workaround |
|-------|--------|------------|
| Sep 1, 2025 boundary is hardcoded | Historical vs recent data split | Don't change - this is intentional for consistency |
| Diversity filter (max 2/PartType) can drop good recs | User might miss relevant products | Intentional trade-off for variety |
| Cold-start users (~98%) get popularity-only scores | Less personalized | Expected behavior - intent data sparse |
| Price threshold $50 may exclude relevant cheap items | Some accessories excluded | Business decision - focus on higher-value items |

---

## How to Add New Issues

When you discover a new gotcha:

1. Identify the category (BigQuery, Data Quality, Treatment, Pipeline)
2. Add row to appropriate table with:
   - **Issue**: Brief description
   - **Impact**: What goes wrong
   - **Workaround**: How to handle it
3. If significant, also add to `CLAUDE.md` Common Failures table
