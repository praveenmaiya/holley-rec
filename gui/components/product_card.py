"""Reusable product card rendering with uniform image sizing."""

import streamlit as st

TIER_CSS = {
    "segment": "tier-segment",
    "make": "tier-make",
    "global": "tier-global",
}


def render_rec_cards(
    recs: list[dict],
    hit_skus: set | None = None,
    email_engagement: dict | None = None,
):
    """Render a 4-column grid of recommendation cards with uniform image boxes."""
    if not recs:
        return

    hit_skus = hit_skus or set()
    cols = st.columns(4)

    for i, rec in enumerate(recs):
        with cols[i]:
            tier = (rec.get("score_tier") or "").lower()
            tier_class = TIER_CSS.get(tier, "")
            tier_label = tier.title() if tier else "Unknown"
            price = rec.get("price", 0)
            score = rec.get("score", 0)

            # Image in a fixed-height container
            if rec.get("image"):
                st.image(rec["image"], use_container_width=True)

            hit_html = ""
            if rec["sku"] in hit_skus:
                hit_html = '<div class="hit-badge">Bought!</div>'

            engagement_html = ""
            if email_engagement is not None:
                if email_engagement.get("clicked"):
                    engagement_html = '<span class="engagement-badge badge-clicked">Clicked</span>'
                elif email_engagement.get("opened"):
                    engagement_html = '<span class="engagement-badge badge-opened">Opened</span>'
                else:
                    engagement_html = (
                        '<span class="engagement-badge badge-not-opened">Not Opened</span>'
                    )

            st.markdown(
                f'<p class="detail-sku">{rec["sku"]}</p>'
                f'<p class="detail-price">${price:,.2f}</p>'
                f'<p class="detail-score">Score: {score:.1f}</p>'
                f'<span class="tier-badge {tier_class}">{tier_label}</span>'
                f"{hit_html}{engagement_html}",
                unsafe_allow_html=True,
            )


def render_purchase_cards(purchases):
    """Render purchase history as compact cards with optional images and prices."""
    if not purchases:
        return

    cols = st.columns(min(len(purchases), 4))
    for i, event in enumerate(purchases):
        with cols[i % 4]:
            if event.image_url:
                st.image(event.image_url, use_container_width=True)

            part_html = f'<p class="part-type">{event.part_type}</p>' if event.part_type else ""
            price_html = (
                f'<p class="detail-price">${event.unit_price:,.2f}</p>' if event.unit_price else ""
            )
            hit_html = ""
            if event.is_hit is True:
                hit_html = f'<div class="hit-badge">Rec #{event.matched_slot}</div>'
            elif event.is_hit is False:
                hit_html = '<p class="part-type" style="color:#bbb">Not from recs</p>'

            st.markdown(
                f'<div class="purchase-card">'
                f'<p class="sku">{event.sku}</p>'
                f"{price_html}"
                f'<p class="date">{event.date}</p>'
                f"{part_html}{hit_html}"
                f"</div>",
                unsafe_allow_html=True,
            )
