"""Reusable product card rendering for Streamlit."""

import streamlit as st

TIER_COLORS = {
    "segment": "🟢",
    "make": "🟡",
    "global": "🔴",
    "none": "⚪",
}


def render_rec_card(rec: dict, hit: bool | None = None):
    """Render a recommendation product card with image."""
    tier_icon = TIER_COLORS.get(rec.get("score_tier", ""), "⚪")

    st.image(rec["image"], width=150)
    st.markdown(f"**{rec['sku']}**")
    st.caption(f"${rec['price']:,.2f} | Score: {rec['score']:.1f}")
    st.caption(f"{tier_icon} {rec.get('score_tier', 'unknown').title()}")

    if hit is True:
        st.success("Bought!", icon="✅")


def render_purchase_card(
    sku: str,
    date,
    part_type: str | None = None,
    is_hit: bool | None = None,
    matched_slot: int | None = None,
):
    """Render a purchase card."""
    st.markdown(f"**{sku}**")
    st.caption(f"{date}")
    if part_type:
        st.caption(f"🏷️ {part_type}")
    if is_hit is True:
        st.success(f"Hit! (Rec #{matched_slot})", icon="🟢")
    elif is_hit is False:
        st.caption("⚪ Not from recs")
