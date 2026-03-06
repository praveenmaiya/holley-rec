"""Holley Recommendation Explorer — User Journey Timeline."""

import streamlit as st
from components.timeline import render_summary, render_timeline
from services.attribution import build_timeline
from services.emails import get_email_events
from services.purchases import get_purchase_history
from services.recommendations import get_user_recommendations
from services.user_data import get_random_users, search_users

st.set_page_config(
    page_title="Holley Rec Explorer",
    page_icon="🔧",
    layout="wide",
)

st.title("🔧 Holley Recommendation Explorer")

# --- Sidebar: Search ---
with st.sidebar:
    st.header("Search User")

    search_tab = st.radio("Search by", ["Email", "Vehicle"], horizontal=True)

    if search_tab == "Email":
        email_input = st.text_input("Email (partial match)")
        search_clicked = st.button("Search", type="primary")
    else:
        year_input = st.text_input("Year (e.g. 2019)")
        make_input = st.text_input("Make (e.g. Ford)")
        model_input = st.text_input("Model (e.g. Mustang)")
        search_clicked = st.button("Search", type="primary")

    st.divider()
    st.header("Quick Actions")
    random_clicked = st.button("🎲 Random 10 Users")
    buyers_clicked = st.button("🎲 Random 10 Buyers")

# --- Handle search actions ---
if search_clicked:
    if search_tab == "Email" and email_input:
        results = search_users(email=email_input)
    elif search_tab == "Vehicle":
        results = search_users(
            year=year_input or None,
            make=make_input or None,
            model=model_input or None,
        )
    else:
        results = None

    if results is not None and not results.empty:
        st.session_state["search_results"] = results
    elif results is not None:
        st.warning("No users found.")

if random_clicked:
    st.session_state["search_results"] = get_random_users(10)

if buyers_clicked:
    st.session_state["search_results"] = get_random_users(10, buyers_only=True)

# --- User Selector + Timeline ---
if "search_results" in st.session_state:
    results = st.session_state["search_results"]

    if results.empty:
        st.warning("No users found.")
    else:

        def _format_option(row):
            year = row.get("v1_year") or ""
            make = row.get("v1_make") or ""
            model = row.get("v1_model") or ""
            vehicle = f"{year} {make} {model}".strip()
            return f"{row['email_lower']} — {vehicle or 'No vehicle'}"

        options = [_format_option(row) for _, row in results.iterrows()]
        selected_idx = st.selectbox(
            "Select user", range(len(options)), format_func=lambda i: options[i]
        )
        selected_email = results.iloc[selected_idx]["email_lower"]

        # --- Use data from search results (no extra BQ query) ---
        user = results.iloc[selected_idx].to_dict()

        # Vehicle header
        year = user.get("v1_year") or "?"
        make = user.get("v1_make") or "?"
        model = user.get("v1_model") or "?"
        vehicle_str = f"{year} {make} {model}"
        if vehicle_str.strip() == "? ? ?":
            vehicle_str = "No vehicle on file"
        st.header(f"🚗 {vehicle_str}")
        st.caption(f"User ID: `{user.get('user_id', 'N/A')}` | Email: `{selected_email}`")

        # Fetch all data
        with st.spinner("Loading recommendations..."):
            recs = get_user_recommendations(selected_email)
        with st.spinner("Loading purchase history..."):
            purchases = get_purchase_history(selected_email)
        with st.spinner("Loading email events..."):
            emails = get_email_events(user.get("user_id", ""))

        # Build and render timeline
        timeline = build_timeline(purchases, emails, recs)

        # Summary at top
        render_summary(timeline, recs)
        st.divider()

        # Full timeline
        render_timeline(timeline, recs)

else:
    st.info("👈 Use the sidebar to search for a user by email or vehicle.")
