"""Holley Recommendation Explorer — List + Detail views."""

import streamlit as st
from components.styles import inject_styles
from components.timeline import render_summary, render_timeline
from components.user_list import render_user_list
from services.attribution import build_timeline
from services.emails import get_email_events
from services.purchases import get_purchase_history
from services.recommendations import get_user_recommendations
from services.user_data import get_random_users, search_users
from services.vehicle_images import get_vehicle_image

st.set_page_config(
    page_title="Holley Rec Explorer",
    page_icon="🔧",
    layout="wide",
)
inject_styles()


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
    year = user.get("v1_year", "?")
    make = user.get("v1_make", "?")
    model = user.get("v1_model", "?")
    vehicle_str = f"{year} {make} {model}"
    vehicle_img = get_vehicle_image(str(year), str(make), str(model))
    user_id = user.get("user_id", "N/A")

    if vehicle_img:
        img_col, hdr_col = st.columns([1, 4])
        with img_col:
            st.image(vehicle_img, width=180)
        with hdr_col:
            st.markdown(
                f'<p class="detail-vehicle-name">{vehicle_str}</p>'
                f'<p class="detail-user-meta"><code>{user_id}</code> &nbsp; {email}</p>',
                unsafe_allow_html=True,
            )
    else:
        st.markdown(
            f'<p class="detail-vehicle-name">{vehicle_str}</p>'
            f'<p class="detail-user-meta"><code>{user_id}</code> &nbsp; {email}</p>',
            unsafe_allow_html=True,
        )

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
    render_timeline(timeline, recs)


def _load_browse_page(cursor: str | None = None):
    """Load a page of users via keyset pagination and update session state."""
    from services.user_data import get_users_page

    page_size = 25
    results = get_users_page(cursor=cursor, page_size=page_size)
    has_next = len(results) > page_size
    if has_next:
        results = results.iloc[:page_size]
    st.session_state["search_results"] = results
    st.session_state["has_next_page"] = has_next
    st.session_state["page_mode"] = "browse"


def _show_list():
    """List page with search sidebar and scrollable user cards."""
    st.markdown('<p class="page-title">Holley Recommendation Explorer</p>', unsafe_allow_html=True)

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
        random_clicked = st.button("Random 25 Users")
        buyers_clicked = st.button("Random 25 Buyers")

    # --- Handle search actions ---
    if search_clicked:
        st.session_state["page_mode"] = "search"
        st.session_state.pop("page_cursors_stack", None)
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
        st.session_state["page_mode"] = "random"
        st.session_state.pop("page_cursors_stack", None)
        st.session_state["search_results"] = get_random_users(25)

    if buyers_clicked:
        st.session_state["page_mode"] = "random"
        st.session_state.pop("page_cursors_stack", None)
        st.session_state["search_results"] = get_random_users(25, buyers_only=True)

    # --- Default: load first browse page ---
    if "search_results" not in st.session_state:
        _load_browse_page()
        if "page_cursors_stack" not in st.session_state:
            st.session_state["page_cursors_stack"] = []

    # --- Render user list ---
    results = st.session_state.get("search_results")
    if results is None or results.empty:
        st.warning("No users found.")
    else:
        page_mode = st.session_state.get("page_mode", "browse")
        if page_mode == "browse":
            render_user_list(results, subtitle="Showing 25 users (alphabetical)")
        else:
            render_user_list(results)

        # --- Pagination buttons for browse mode ---
        if page_mode == "browse":
            cursors_stack = st.session_state.get("page_cursors_stack", [])
            has_next = st.session_state.get("has_next_page", False)

            col_prev, col_next = st.columns(2)
            with col_prev:
                if cursors_stack:
                    if st.button("← Previous"):
                        cursors_stack.pop()
                        prev_cursor = cursors_stack[-1] if cursors_stack else None
                        st.session_state["page_cursors_stack"] = cursors_stack
                        _load_browse_page(prev_cursor)
                        st.rerun()
            with col_next:
                if has_next and not results.empty:
                    if st.button("Next →"):
                        last_email = results.iloc[-1]["email_lower"]
                        cursors_stack.append(st.session_state.get("page_cursor"))
                        st.session_state["page_cursors_stack"] = cursors_stack
                        st.session_state["page_cursor"] = last_email
                        _load_browse_page(last_email)
                        st.rerun()


# --- Route between list and detail ---
if "selected_email" in st.session_state:
    _show_detail()
else:
    _show_list()
