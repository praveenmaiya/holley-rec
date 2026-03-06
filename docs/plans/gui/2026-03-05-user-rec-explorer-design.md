# User Recommendation Explorer — Design Doc

**Date**: 2026-03-05
**Status**: Approved
**Stack**: Streamlit + BigQuery + Plotly

## Problem

We have 450K+ users with vehicle-fitted recommendations, purchase history, and email engagement data spread across 7+ BigQuery tables. There's no way to see the full picture for a single user — what they bought before, what we recommended, what email they got, and what they bought after. Metabase covers aggregate metrics but not this user-level inspection.

## Solution

A Streamlit-based **User Recommendation Explorer** that presents a chronological timeline for any user: purchase history, email events with recommendation cards (including product images), and post-email purchases with hit/miss attribution.

## Audience

- Primary: Praveen (operational — spot-check quality, debug misses, validate exclusions)
- Secondary: Holley stakeholders (demo real user stories, show personalization impact)

## Core Feature: User Journey Timeline

For any user, display a chronological stream:

1. **Vehicle info**: Year/Make/Model
2. **Purchase history** (before any email): products with images, prices, dates, part types
3. **Email events** (interleaved chronologically):
   - Treatment name + type (Personalized vs Static)
   - 4 recommendation cards with product images, names, prices, scores, score tier
   - Open/click status, which slot was clicked
4. **Post-email purchases**: attributed to most recent prior email (30-day window)
   - Hit (matched a rec) vs Miss (not in recs)
   - Time-to-purchase from email
5. **Per-email purchase exclusion verification**: did we correctly skip already-owned items?
6. **Summary**: total emails, hit rate, revenue from recs, avg time to purchase

### Multi-Email Handling

Users receive multiple emails over time. Each email is a separate event in the timeline with its own rec cards and attributed purchases. Purchases are attributed to the most recent prior email within a 30-day attribution window. If a purchase matches a rec from an older email, it's flagged with the source email noted.

## Navigation & Search

- **Search by**: user ID, email (partial), vehicle (year/make/model dropdowns)
- **Quick filters**: All Users, Buyers Only, Hit >= 1, All Misses, by Score Tier
- **Vehicle filter**: Year/Make/Model dropdowns (cascading)
- **Sort by**: Random Sample, Most Purchases, Highest Revenue, Most Recent Buy, Global Tier First
- **Pagination**: Prev/Next user navigation

## Data Sources

| Section | BQ Table | Key Fields |
|---------|----------|------------|
| Vehicle | `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` | year, make, model via user attributes |
| Purchase history | `auxia-gcp.data_company_1950.import_orders` | SKU, price, date, user_id |
| Product catalog | `auxia-gcp.data_company_1950.import_items` | name, image_url, part_type |
| Recommendations | `auxia-reporting.company_1950_jp.final_vehicle_recommendations` | 4 SKUs, scores, images, prices per user |
| Email sent | `auxia-gcp.company_1950.treatment_history_sent` | user_id, treatment_id, sent_date |
| Email interactions | `auxia-gcp.company_1950.treatment_interaction` | VIEWED, CLICKED, timestamp |
| Fitment | `auxia-gcp.data_company_1950.vehicle_product_fitment_data` | vehicle-to-SKU mapping |
| Treatment config | `configs/personalized_treatments.csv`, `configs/static_treatments.csv` | treatment names, types |

## Architecture

```
holley-rec/gui/
├── app.py                  # Entry point, page navigation, sidebar
├── pages/
│   └── user_explorer.py    # Main page: timeline view
├── services/
│   ├── bq_client.py        # Cached BQ client, query helper
│   ├── user_data.py        # Fetch user vehicle, purchases, recs, emails
│   └── attribution.py      # Hit/miss logic, purchase-to-email attribution
├── components/
│   ├── timeline.py         # Render chronological timeline
│   ├── product_card.py     # Render product image + metadata
│   └── filters.py          # Search, vehicle filter, sort controls
├── pyproject.toml          # uv: streamlit, google-cloud-bigquery, plotly, pandas
└── README.md
```

### Key Design Decisions

- **Streamlit** for speed to ship + Python reuse
- **`@st.cache_data(ttl=300)`** on all BQ queries — 5-min TTL avoids repeated billing
- **Services layer** keeps SQL out of page code
- **Product images** rendered via `st.image()` from CDN URLs (already HTTPS)
- **Attribution window**: 30 days (configurable)
- **Pagination**: server-side (LIMIT/OFFSET in BQ), not loading 450K users

### Query Strategy

1. **User search** → lightweight query returning user_id + vehicle (fast)
2. **On user select** → parallel queries for purchases, recs, emails (cached per user)
3. **Fitment check** → join in BQ, not client-side
4. **Images** → loaded from CDN URLs already in the recommendations table

## Hosting

- Local first (`streamlit run gui/app.py`)
- Deploy-ready: single Dockerfile → Cloud Run when needed

## Future Extensions (Not in v1)

- Aggregate view: hit rates, revenue, patterns across all users
- Side-by-side: compare two users with same vehicle
- Version comparison: same user's recs across pipeline versions
- Export: CSV/PDF of user story for stakeholder presentations
