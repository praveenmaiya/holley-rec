"""Render the user journey timeline with styled components."""

import streamlit as st
from services.attribution import TimelineEvent
from services.treatments import get_treatment_name, get_treatment_type

from components.product_card import render_purchase_cards, render_rec_cards


def render_timeline(timeline: list[TimelineEvent], recs: list[dict]):
    """Render chronological timeline with email events interleaved."""
    if recs:
        emails = [e for e in timeline if e.event_type == "email"]
        if not emails:
            st.markdown(
                '<p class="section-title">Current Recommendations</p>',
                unsafe_allow_html=True,
            )
            render_rec_cards(recs)

    if not timeline:
        if not recs:
            st.info("No events found for this user.")
        return

    before = [e for e in timeline if e.event_type == "purchase_before"]
    rest = [e for e in timeline if e.event_type != "purchase_before"]

    if before:
        st.markdown(
            f'<p class="section-title">Purchase History ({len(before)} orders)</p>',
            unsafe_allow_html=True,
        )
        render_purchase_cards(before)

    current_email = None
    post_purchases: list[TimelineEvent] = []

    for event in rest:
        if event.event_type == "email":
            if current_email is not None:
                _render_post_purchases(post_purchases)
                post_purchases = []

            current_email = event
            treatment_name = get_treatment_name(event.treatment_id)
            treatment_type = get_treatment_type(event.treatment_id)
            badge_class = (
                "badge-personalized" if treatment_type == "Personalized" else "badge-static"
            )
            opened = "Opened" if event.opened else "Not opened"
            clicked = "Clicked" if event.clicked else "Not clicked"

            st.markdown(
                f"""
                <div class="email-block">
                    <p class="email-title">{treatment_name}</p>
                    <p class="email-meta">
                        <span class="{badge_class}">{treatment_type}</span>
                        &nbsp; Sent {event.date} &nbsp;|&nbsp; {opened} &nbsp;|&nbsp; {clicked}
                    </p>
                </div>
            """,
                unsafe_allow_html=True,
            )

            if recs:
                hit_skus = {
                    e.sku
                    for e in rest
                    if e.event_type == "purchase_after"
                    and e.is_hit
                    and e.attributed_to_treatment == event.treatment_id
                }
                engagement = {"opened": event.opened, "clicked": event.clicked}
                render_rec_cards(recs, hit_skus, email_engagement=engagement)

        elif event.event_type == "purchase_after":
            post_purchases.append(event)

    if post_purchases:
        _render_post_purchases(post_purchases)


def _render_post_purchases(purchases: list[TimelineEvent]):
    if not purchases:
        return
    st.markdown(
        f'<p class="section-title">Purchases After Email ({len(purchases)})</p>',
        unsafe_allow_html=True,
    )
    render_purchase_cards(purchases)


def render_summary(timeline: list[TimelineEvent], recs: list[dict]):
    """Render summary stats as styled metric cards."""
    after = [e for e in timeline if e.event_type == "purchase_after"]
    emails = [e for e in timeline if e.event_type == "email"]
    hits = [e for e in after if e.is_hit]

    hit_rate = f"{len(hits)}/{len(recs)}" if recs else "N/A"
    hit_skus = {h.sku for h in hits}
    revenue = sum(r["price"] for r in recs if r["sku"] in hit_skus)

    all_purchases = [e for e in timeline if e.event_type in ("purchase_before", "purchase_after")]
    total_spent = sum(e.unit_price for e in all_purchases if e.unit_price)

    st.markdown(
        f"""
        <div class="metrics-row">
            <div class="metric-card">
                <p class="metric-label">Emails Received</p>
                <p class="metric-value">{len(emails)}</p>
            </div>
            <div class="metric-card">
                <p class="metric-label">Hit Rate</p>
                <p class="metric-value">{hit_rate}</p>
            </div>
            <div class="metric-card">
                <p class="metric-label">Post-Email Purchases</p>
                <p class="metric-value">{len(after)}</p>
            </div>
            <div class="metric-card">
                <p class="metric-label">Revenue from Recs</p>
                <p class="metric-value">${revenue:,.2f}</p>
            </div>
            <div class="metric-card">
                <p class="metric-label">Total Spent</p>
                <p class="metric-value">${total_spent:,.2f}</p>
            </div>
        </div>
    """,
        unsafe_allow_html=True,
    )
