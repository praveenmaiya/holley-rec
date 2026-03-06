"""Build user timeline with purchase-to-email attribution."""

from dataclasses import dataclass
from datetime import timedelta

import pandas as pd

ATTRIBUTION_WINDOW_DAYS = 30


@dataclass
class TimelineEvent:
    """A single event in the user timeline."""

    date: pd.Timestamp
    event_type: str  # "purchase_before", "email", "purchase_after"
    # Purchase fields
    sku: str | None = None
    part_type: str | None = None
    is_hit: bool | None = None
    matched_slot: int | None = None
    attributed_to_treatment: int | None = None
    # Email fields
    treatment_id: int | None = None
    opened: bool | None = None
    clicked: bool | None = None
    treatment_tracking_id: str | None = None


def build_timeline(
    purchases: pd.DataFrame,
    emails: pd.DataFrame,
    recs: list[dict],
) -> list[TimelineEvent]:
    """Build chronological timeline from purchases, emails, and recs."""
    events: list[TimelineEvent] = []

    if emails.empty:
        for _, row in purchases.iterrows():
            events.append(
                TimelineEvent(
                    date=row["order_date"],
                    event_type="purchase_before",
                    sku=row["sku"],
                    part_type=row.get("part_type"),
                )
            )
        events.sort(key=lambda e: e.date)
        return events

    first_email_date = emails["sent_date"].min()
    rec_skus = {r["sku"]: r["slot"] for r in recs}

    # Email events
    for _, row in emails.iterrows():
        events.append(
            TimelineEvent(
                date=row["sent_date"],
                event_type="email",
                treatment_id=int(row["treatment_id"]),
                opened=bool(row["opened"]),
                clicked=bool(row["clicked"]),
                treatment_tracking_id=row.get("treatment_tracking_id"),
            )
        )

    # Sort emails by date for attribution
    email_dates = emails.sort_values("sent_date")[["sent_date", "treatment_id"]].values.tolist()

    for _, row in purchases.iterrows():
        purchase_date = row["order_date"]
        sku = row["sku"]

        if purchase_date < first_email_date:
            events.append(
                TimelineEvent(
                    date=purchase_date,
                    event_type="purchase_before",
                    sku=sku,
                    part_type=row.get("part_type"),
                )
            )
        else:
            # Attribute to most recent prior email within window
            attributed_treatment = None
            for email_date, treatment_id in reversed(email_dates):
                if email_date <= purchase_date:
                    delta = purchase_date - email_date
                    if delta <= timedelta(days=ATTRIBUTION_WINDOW_DAYS):
                        attributed_treatment = int(treatment_id)
                    break

            is_hit = sku in rec_skus
            events.append(
                TimelineEvent(
                    date=purchase_date,
                    event_type="purchase_after",
                    sku=sku,
                    part_type=row.get("part_type"),
                    is_hit=is_hit,
                    matched_slot=rec_skus.get(sku),
                    attributed_to_treatment=attributed_treatment,
                )
            )

    events.sort(key=lambda e: e.date)
    return events
