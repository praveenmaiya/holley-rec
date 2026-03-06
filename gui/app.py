"""Holley Recommendation Explorer — List + Detail views."""

import streamlit as st
from components.timeline import render_summary, render_timeline
from components.user_list import render_user_list
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


def _show_detail():
    """Detail page for a single user."""
    email = st.session_state["selected_email"]
    results = st.session_state.get("search_results")

    # Back button
    if st.button("← Back to list"):
        del st.session_state["selected_email"]
        st.rerun()

    # Get user row from cached search results
    user = None
    if results is not None and not results.empty:
        match = results[results["email_lower"] == email]
        if not match.empty:
            user = match.iloc[0].to_dict()

    if user is None:
        st.error(f"User {email} not found in results.")
        return

    # Vehicle header
    vehicle_str = (
        f"{user.get('v1_year', '?')} {user.get('v1_make', '?')} {user.get('v1_model', '?')}"
    )
    st.header(f"🚗 {vehicle_str}")
    st.caption(f"User ID: `{user.get('user_id', 'N/A')}` | Email: `{email}`")

    # Fetch all data
    with st.spinner("Loading recommendations..."):
        recs = get_user_recommendations(email)
    with st.spinner("Loading purchase history..."):
        purchases = get_purchase_history(email)
    with st.spinner("Loading email events..."):
        emails = get_email_events(user.get("user_id", ""))

    # Build and render timeline
    timeline = build_timeline(purchases, emails, recs)
    render_summary(timeline, recs)
    st.divider()
    render_timeline(timeline, recs)


def _show_list():
    """List page with search sidebar and scrollable user cards."""
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
        random_clicked = st.button("🎲 Random 25 Users")
        buyers_clicked = st.button("🎲 Random 25 Buyers")

    # --- Handle search actions ---
    if search_clicked:
        if search_tab == "Email" and email_input:
            results = search_users(email=email_input, limit=25)
        elif search_tab == "Vehicle":
            results = search_users(
                year=year_input or None,
                make=make_input or None,
                model=model_input or None,
                limit=25,
            )
        else:
            results = None

        if results is not None and not results.empty:
            st.session_state["search_results"] = results
        elif results is not None:
            st.warning("No users found.")

    if random_clicked:
        st.session_state["search_results"] = get_random_users(25)

    if buyers_clicked:
        st.session_state["search_results"] = get_random_users(25, buyers_only=True)

    # --- Render user list ---
    if "search_results" in st.session_state:
        results = st.session_state["search_results"]
        if results.empty:
            st.warning("No users found.")
        else:
            render_user_list(results)
    else:
        st.info("👈 Use the sidebar to search for a user by email or vehicle.")


# --- Route between list and detail ---
if "selected_email" in st.session_state:
    _show_detail()
else:
    _show_list()
