"""Render the scrollable user list with vehicle image + recommendation thumbnails."""

import pandas as pd
import streamlit as st
from services.vehicle_images import get_vehicle_image


def render_user_list(results: pd.DataFrame):
    """Render a scrollable list of users with vehicle image and rec thumbnails."""
    st.subheader(f"Users ({len(results)})")

    for idx, row in results.iterrows():
        email = row["email_lower"]
        year = str(row["v1_year"])
        make = str(row["v1_make"])
        model = str(row["v1_model"])
        vehicle = f"{year} {make} {model}"
        vehicle_img = get_vehicle_image(year, make, model)

        with st.container():
            # Vehicle image + info + View button
            if vehicle_img:
                img_col, info_col, btn_col = st.columns([1, 4, 1])
                with img_col:
                    st.image(vehicle_img, width=120)
            else:
                info_col, btn_col = st.columns([5, 1])

            with info_col:
                st.markdown(f"**{vehicle}**  \n`{email}`")
            with btn_col:
                if st.button("View →", key=f"view_{idx}"):
                    st.session_state["selected_email"] = email
                    st.rerun()

            # Show rec thumbnails in a row
            images = []
            for i in range(1, 5):
                img = row.get(f"rec{i}_image")
                sku = row.get(f"rec_part_{i}")
                price = row.get(f"rec{i}_price")
                if pd.notna(img) and pd.notna(sku):
                    images.append((img, sku, price))

            if images:
                cols = st.columns(len(images))
                for i, (img, sku, price) in enumerate(images):
                    with cols[i]:
                        st.image(img, width=80)
                        st.caption(f"{sku}\n${price:,.0f}" if pd.notna(price) else sku)

            st.divider()
