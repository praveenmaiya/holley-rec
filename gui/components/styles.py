"""Global CSS styles for the Holley Recommendation Explorer."""

import streamlit as st

CUSTOM_CSS = """
<style>
@import url('https://fonts.googleapis.com/css2?family=DM+Sans:ital,opsz,wght@0,9..40,400;0,9..40,500;0,9..40,600;0,9..40,700;1,9..40,400&display=swap');

/* ── Global ── */
.stApp {
    font-family: 'DM Sans', sans-serif;
    background: #f7f7f8;
}
h1, h2, h3, h4, h5, h6, .stMetricLabel, .stMetricValue {
    font-family: 'DM Sans', sans-serif !important;
}

/* ── Reduce default Streamlit spacing ── */
.block-container {
    padding-top: 1.2rem !important;
    padding-bottom: 0.5rem !important;
}
hr {
    margin: 0.2rem 0 !important;
    border-color: #e8e8e8 !important;
}
/* Tighten vertical gaps between elements */
[data-testid="stVerticalBlock"] {
    gap: 0.15rem !important;
}
[data-testid="stHorizontalBlock"] {
    gap: 0.4rem !important;
    align-items: flex-start !important;
}

/* ── Uniform Product Image Boxes ── */
/* All st.image() elements */
[data-testid="stImage"] img {
    object-fit: contain;
    border-radius: 6px;
    background: #fff;
}
/* Fixed-size image container for rec cards in grids */
[data-testid="stHorizontalBlock"] > [data-testid="stColumn"] [data-testid="stImage"] {
    height: 130px;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    background: #fff;
    border: 1px solid #eaeaea;
    border-radius: 8px;
    margin-bottom: 2px;
    padding: 6px;
}
[data-testid="stHorizontalBlock"] > [data-testid="stColumn"] [data-testid="stImage"] img {
    max-height: 118px;
    max-width: 100%;
    width: auto;
    object-fit: contain;
}

/* ── Sidebar — Dark Theme ── */
section[data-testid="stSidebar"] {
    background: #111;
}
section[data-testid="stSidebar"] h1,
section[data-testid="stSidebar"] h2,
section[data-testid="stSidebar"] h3,
section[data-testid="stSidebar"] label,
section[data-testid="stSidebar"] p,
section[data-testid="stSidebar"] span {
    color: #e8e8e8 !important;
}
section[data-testid="stSidebar"] input {
    background: #1a1a1a !important;
    border: 1px solid #333 !important;
    color: #f0f0f0 !important;
    border-radius: 6px !important;
}
section[data-testid="stSidebar"] hr {
    border-color: #2a2a2a !important;
}
section[data-testid="stSidebar"] [data-testid="stRadio"] label {
    color: #bbb !important;
}

/* ── List View: User Row Card ── */
.user-card {
    background: #fff;
    border: 1px solid #eaeaea;
    border-radius: 10px;
    padding: 12px 16px 10px;
    margin-bottom: 6px;
    transition: box-shadow 0.15s ease;
}
.user-card:hover {
    box-shadow: 0 2px 8px rgba(0,0,0,0.06);
}
.vehicle-name {
    font-weight: 600;
    font-size: 15px;
    color: #1a1a1a;
    margin: 0;
    line-height: 1.3;
}
.user-email {
    font-size: 12px;
    color: #999;
    margin: 1px 0 0;
}
.rec-sku {
    font-size: 11px;
    font-weight: 600;
    color: #333;
    margin: 0;
    line-height: 1.2;
    text-align: center;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}
.rec-price {
    font-size: 10px;
    color: #999;
    margin: 0;
    text-align: center;
}

/* ── Page Title ── */
.page-title {
    font-size: 24px;
    font-weight: 700;
    color: #1a1a1a;
    margin: 0 0 2px;
    letter-spacing: -0.3px;
}
.page-subtitle {
    font-size: 12px;
    color: #999;
    font-weight: 500;
    margin: 0 0 8px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

/* ── Detail Page: Header ── */
.detail-header {
    display: flex;
    align-items: center;
    gap: 20px;
    padding: 8px 0 12px;
}
.detail-vehicle-img {
    width: 160px;
    height: 100px;
    object-fit: cover;
    border-radius: 8px;
    border: 1px solid #e0e0e0;
    flex-shrink: 0;
}
.detail-vehicle-name {
    font-size: 24px;
    font-weight: 700;
    color: #1a1a1a;
    margin: 0;
    letter-spacing: -0.3px;
}
.detail-user-meta {
    font-size: 13px;
    color: #888;
    margin: 4px 0 0;
}
.detail-user-meta code {
    background: #f0f0f0;
    padding: 1px 6px;
    border-radius: 3px;
    font-size: 11px;
    color: #555;
}

/* ── Detail Page: Rec Card Labels ── */
.detail-rec-card {
    text-align: center;
    padding-bottom: 8px;
}
.detail-sku {
    font-weight: 700;
    font-size: 13px;
    color: #1a1a1a;
    margin: 4px 0 2px;
}
.detail-price {
    font-size: 12px;
    color: #555;
    margin: 0;
}
.detail-score {
    font-size: 11px;
    color: #aaa;
    margin: 2px 0 4px;
}
.tier-badge {
    display: inline-block;
    font-size: 10px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 10px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}
.tier-segment { background: #e8f5e9; color: #2e7d32; }
.tier-make    { background: #fff8e1; color: #f57f17; }
.tier-global  { background: #fce4ec; color: #c62828; }

/* ── Metrics Row ── */
.metrics-row {
    display: grid;
    grid-template-columns: repeat(5, 1fr);
    gap: 10px;
    margin: 8px 0 16px;
}
.metric-card {
    background: #fff;
    border: 1px solid #eaeaea;
    border-radius: 10px;
    padding: 14px 16px;
    text-align: center;
}
.metric-label {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.8px;
    color: #999;
    margin: 0;
}
.metric-value {
    font-size: 24px;
    font-weight: 700;
    color: #1a1a1a;
    margin: 4px 0 0;
}

/* ── Section Headers (red underline) ── */
.section-title {
    font-size: 14px;
    font-weight: 700;
    color: #1a1a1a;
    margin: 16px 0 8px;
    padding-bottom: 5px;
    border-bottom: 2px solid #E31937;
    display: inline-block;
}

/* ── Email Event Block ── */
.email-block {
    background: #fff;
    border-left: 3px solid #E31937;
    border-radius: 0 10px 10px 0;
    padding: 12px 16px;
    margin: 14px 0 8px;
    border: 1px solid #eaeaea;
    border-left: 3px solid #E31937;
}
.email-title {
    font-size: 14px;
    font-weight: 600;
    color: #1a1a1a;
    margin: 0 0 4px;
}
.email-meta {
    font-size: 12px;
    color: #777;
    margin: 0;
}
.badge-personalized {
    background: #E8DEF8;
    color: #6A1B9A;
    font-size: 10px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 10px;
}
.badge-static {
    background: #D1E7FF;
    color: #1565C0;
    font-size: 10px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 10px;
}

/* ── Purchase Cards ── */
.purchase-card {
    background: #fff;
    border: 1px solid #eaeaea;
    border-radius: 8px;
    padding: 10px;
    margin-bottom: 4px;
}
.purchase-card .sku { font-weight: 600; font-size: 13px; color: #1a1a1a; margin: 0; }
.purchase-card .date { font-size: 11px; color: #999; margin: 2px 0; }
.purchase-card .part-type { font-size: 11px; color: #666; margin: 0; }
.hit-badge {
    display: inline-block;
    background: #e8f5e9;
    color: #2e7d32;
    font-size: 10px;
    font-weight: 600;
    padding: 2px 6px;
    border-radius: 8px;
    margin-top: 4px;
}

/* ── Engagement Badges ── */
.engagement-badge {
    display: inline-block;
    font-size: 10px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 10px;
    margin-left: 4px;
}
.badge-clicked { background: #e8f5e9; color: #2e7d32; }
.badge-opened  { background: #fff8e1; color: #f57f17; }
.badge-not-opened { background: #fce4ec; color: #c62828; }

/* ── Primary button styling ── */
button[data-testid="stBaseButton-primary"] {
    background: #1a1a1a !important;
    border: none !important;
    font-size: 12px !important;
    font-weight: 500 !important;
    padding: 6px 16px !important;
    border-radius: 6px !important;
}
button[data-testid="stBaseButton-primary"]:hover {
    background: #E31937 !important;
}

/* ── List view separator ── */
.user-separator {
    margin: 2px 0;
    border: none;
    border-top: 1px solid #eee;
}
</style>
"""


def inject_styles():
    """Inject custom CSS into the Streamlit page."""
    st.markdown(CUSTOM_CSS, unsafe_allow_html=True)
