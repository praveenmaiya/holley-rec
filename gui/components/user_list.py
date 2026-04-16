"""Render the scrollable user list with vehicle image + recommendation thumbnails."""

import pandas as pd
import streamlit as st
from services.vehicle_images import get_vehicle_image


def render_user_list(results: pd.DataFrame, subtitle: str | None = None):
    """Render a compact scrollable list of users with rec thumbnails."""
    display_text = subtitle or f"{len(results)} users found"
    st.markdown(
        f'<p class="page-subtitle">{display_text}</p>',
        unsafe_allow_html=True,
    )

    for idx, row in results.iterrows():
        email = row["email_lower"]
        year = str(row["v1_year"])
        make = str(row["v1_make"])
        model = str(row["v1_model"])
        vehicle = f"{year} {make} {model}"
        vehicle_img = get_vehicle_image(year, make, model)

        with st.container():
            # Row 1: vehicle image + info + view button
            if vehicle_img:
                img_col, info_col, btn_col = st.columns([1, 4, 1])
                with img_col:
                    st.image(vehicle_img, width=90)
            else:
                info_col, btn_col = st.columns([5, 1])

            with info_col:
                st.markdown(
                    f'<p class="vehicle-name">{vehicle}</p><p class="user-email">{email}</p>',
                    unsafe_allow_html=True,
                )
            with btn_col:
                if st.button("View", key=f"view_{idx}", type="primary"):
                    st.session_state["selected_email"] = email
                    st.rerun()

            # Row 2: rec thumbnails — uniform boxes
            images = []
            for i in range(1, 5):
                img = row.get(f"rec{i}_image")
                sku = row.get(f"rec_part_{i}")
                price = row.get(f"rec{i}_price")
                if pd.notna(img) and pd.notna(sku):
                    images.append((img, sku, price))

            if images:
                cols = st.columns(4)
                for i in range(4):
                    with cols[i]:
                        if i < len(images):
                            img, sku, price = images[i]
                            st.image(img, use_container_width=True)
                            price_str = f"${price:,.0f}" if pd.notna(price) else ""
                            st.markdown(
                                f'<p class="rec-sku">{sku}</p><p class="rec-price">{price_str}</p>',
                                unsafe_allow_html=True,
                            )

            st.markdown('<hr class="user-separator">', unsafe_allow_html=True)
