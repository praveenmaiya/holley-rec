"""Render the user journey timeline in Streamlit."""

import streamlit as st
from services.attribution import TimelineEvent
from services.treatments import get_treatment_name, get_treatment_type

from components.product_card import render_purchase_card, render_rec_card


def render_timeline(timeline: list[TimelineEvent], recs: list[dict]):
    """Render chronological timeline with email events interleaved."""
    # Always show recommendations if we have them
    if recs:
        emails = [e for e in timeline if e.event_type == "email"]
        if not emails:
            st.subheader("📦 Current Recommendations")
            rec_cols = st.columns(len(recs))
            for i, rec in enumerate(recs):
                with rec_cols[i]:
                    render_rec_card(rec)

    if not timeline:
        if not recs:
            st.info("No events found for this user.")
        return

    before = [e for e in timeline if e.event_type == "purchase_before"]
    rest = [e for e in timeline if e.event_type != "purchase_before"]

    # --- Purchase History ---
    if before:
        st.subheader(f"🔧 Purchase History ({len(before)} orders)")
        cols = st.columns(min(len(before), 4))
        for i, event in enumerate(before):
            with cols[i % 4]:
                render_purchase_card(event.sku, event.date, event.part_type)

    # --- Email Events + Post-Email Purchases ---
    current_email = None
    post_purchases: list[TimelineEvent] = []

    for event in rest:
        if event.event_type == "email":
            # Flush previous email's purchases
            if current_email is not None:
                _render_post_purchases(post_purchases)
                post_purchases = []

            current_email = event
            st.divider()
            treatment_name = get_treatment_name(event.treatment_id)
            treatment_type = get_treatment_type(event.treatment_id)
            type_badge = "🟣" if treatment_type == "Personalized" else "🔵"

            st.subheader(f"📧 {treatment_name}")
            st.caption(
                f"{type_badge} {treatment_type} | Sent: {event.date} | "
                f"Opened: {'✅' if event.opened else '❌'} | "
                f"Clicked: {'✅' if event.clicked else '❌'}"
            )

            # Render recommendation cards for this email
            if recs:
                rec_cols = st.columns(len(recs))
                hit_skus = {
                    e.sku
                    for e in rest
                    if e.event_type == "purchase_after"
                    and e.is_hit
                    and e.attributed_to_treatment == event.treatment_id
                }
                for i, rec in enumerate(recs):
                    with rec_cols[i]:
                        render_rec_card(rec, hit=rec["sku"] in hit_skus)

        elif event.event_type == "purchase_after":
            post_purchases.append(event)

    # Flush final email's purchases
    if post_purchases:
        _render_post_purchases(post_purchases)


def _render_post_purchases(purchases: list[TimelineEvent]):
    """Render post-email purchase section."""
    if not purchases:
        return
    st.markdown(f"**🛒 Purchases after email ({len(purchases)})**")
    cols = st.columns(min(len(purchases), 4))
    for i, event in enumerate(purchases):
        with cols[i % 4]:
            render_purchase_card(
                event.sku,
                event.date,
                event.part_type,
                is_hit=event.is_hit,
                matched_slot=event.matched_slot,
            )


def render_summary(timeline: list[TimelineEvent], recs: list[dict]):
    """Render summary stats at the top."""
    after = [e for e in timeline if e.event_type == "purchase_after"]
    emails = [e for e in timeline if e.event_type == "email"]
    hits = [e for e in after if e.is_hit]

    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Emails Received", len(emails))
    col2.metric("Hit Rate", f"{len(hits)}/{len(recs)}" if recs else "N/A")
    col3.metric("Post-Email Purchases", len(after))

    hit_skus = {h.sku for h in hits}
    revenue = sum(r["price"] for r in recs if r["sku"] in hit_skus)
    col4.metric("Revenue from Recs", f"${revenue:,.2f}")
