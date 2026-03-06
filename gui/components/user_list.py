"""Render the scrollable user list with recommendation thumbnails."""

import pandas as pd
import streamlit as st


def render_user_list(results: pd.DataFrame):
    """Render a scrollable list of users with rec thumbnails. Returns selected email or None."""
    st.subheader(f"Users ({len(results)})")

    for idx, row in results.iterrows():
        email = row["email_lower"]
        vehicle = f"{row['v1_year']} {row['v1_make']} {row['v1_model']}"

        with st.container():
            top_col, btn_col = st.columns([5, 1])
            with top_col:
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
