"""Fetch vehicle images from Wikipedia and save to BigQuery."""

import time

import pandas as pd
import requests
from google.cloud import bigquery

BQ_TABLE = "auxia-reporting.temp_holley_v5_18.vehicle_images"

VEHICLES_SQL = """
SELECT v1_year, UPPER(v1_make) AS v1_make, UPPER(v1_model) AS v1_model,
       COUNT(*) AS user_count
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
GROUP BY 1, 2, 3
ORDER BY user_count DESC
LIMIT 200
"""

# Map make names to Wikipedia-friendly format
MAKE_WIKI = {
    "CHEVROLET": "Chevrolet",
    "FORD": "Ford",
    "DODGE": "Dodge",
    "RAM": "Ram",
    "JEEP": "Jeep",
    "PONTIAC": "Pontiac",
    "GMC": "GMC",
    "CHRYSLER": "Chrysler",
    "TOYOTA": "Toyota",
    "HONDA": "Honda",
    "BMW": "BMW",
}

# Model name overrides for Wikipedia article titles
MODEL_WIKI = {
    "C10 PICKUP": "C/K",
    "C10": "C/K",
    "C1500": "C/K",
    "CHEVY II": "Chevy II / Nova",
    "SILVERADO 1500": "Silverado",
    "SILVERADO 2500 HD": "Silverado",
    "F-150": "F-Series",
    "F-100": "F-Series",
    "RAM 1500": "Ram pickup",
    "DODGE RAM 1500": "Dodge Ram",
    "DODGE RAM 2500": "Dodge Ram",
    "RAM 2500": "Ram pickup",
    "SIERRA 1500": "Sierra",
    "TWO-TEN SERIES": "Bel Air",
    "BEL AIR": "Bel Air",
}


def fetch_wiki_image(year: str, make: str, model: str) -> str | None:
    """Fetch a vehicle image from Wikipedia."""
    make_wiki = MAKE_WIKI.get(make, make.title())
    model_wiki = MODEL_WIKI.get(model, model.title())

    # Try article titles in order of specificity
    candidates = [
        f"{make_wiki} {model_wiki}",
    ]

    for title in candidates:
        url = "https://en.wikipedia.org/w/api.php"
        params = {
            "action": "query",
            "titles": title,
            "prop": "pageimages",
            "pithumbsize": 300,
            "format": "json",
        }
        try:
            headers = {"User-Agent": "HolleyRecExplorer/1.0 (internal tool)"}
            resp = requests.get(url, params=params, headers=headers, timeout=10)
            data = resp.json()
            pages = data.get("query", {}).get("pages", {})
            for page in pages.values():
                thumb = page.get("thumbnail", {}).get("source")
                if thumb:
                    return thumb
        except Exception as e:
            print(f"  Wiki error for {title}: {e}")

    return None


def main():
    client = bigquery.Client(project="auxia-reporting")

    print("Fetching top vehicles...")
    df = client.query(VEHICLES_SQL).to_dataframe()
    print(f"Got {len(df)} vehicles")

    rows = []
    seen_models = {}  # cache by make+model (same image for different years)

    for _, row in df.iterrows():
        year, make, model = row["v1_year"], row["v1_make"], row["v1_model"]
        cache_key = f"{make}|{model}"

        if cache_key in seen_models:
            img = seen_models[cache_key]
            if img:
                rows.append({"v1_year": year, "v1_make": make, "v1_model": model, "image_url": img})
                print(f"  {year} {make} {model} -> cached")
            continue

        print(f"Fetching: {year} {make} {model} ({row['user_count']} users)...", end=" ")
        img = fetch_wiki_image(year, make, model)
        seen_models[cache_key] = img

        if img:
            rows.append({"v1_year": year, "v1_make": make, "v1_model": model, "image_url": img})
            print("OK")
        else:
            print("SKIP")
        time.sleep(0.2)

    print(f"\nGot images for {len(rows)}/{len(df)} vehicles")

    if not rows:
        print("No images to save.")
        return

    schema = [
        bigquery.SchemaField("v1_year", "STRING"),
        bigquery.SchemaField("v1_make", "STRING"),
        bigquery.SchemaField("v1_model", "STRING"),
        bigquery.SchemaField("image_url", "STRING"),
    ]
    job_config = bigquery.LoadJobConfig(
        schema=schema,
        write_disposition="WRITE_TRUNCATE",
    )
    out_df = pd.DataFrame(rows)
    job = client.load_table_from_dataframe(out_df, BQ_TABLE, job_config=job_config)
    job.result()
    print(f"Saved {len(rows)} vehicle images to {BQ_TABLE}")


if __name__ == "__main__":
    main()
