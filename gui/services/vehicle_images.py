"""Fetch vehicle images from BigQuery vehicle_images table."""

from services.bq_client import run_query

_TABLE = "auxia-reporting.temp_holley_v5_18.vehicle_images"

_by_ymm: dict[str, str] = {}  # year|make|model -> url
_by_mm: dict[str, str] = {}  # make|model -> url (fallback)
_loaded = False


def _load_all():
    """Load all vehicle images into memory (small table, ~200 rows)."""
    global _loaded
    if _loaded:
        return
    query = f"SELECT v1_year, v1_make, v1_model, image_url FROM `{_TABLE}`"
    df = run_query(query)
    for _, row in df.iterrows():
        ymm = f"{row['v1_year']}|{row['v1_make']}|{row['v1_model']}"
        mm = f"{row['v1_make']}|{row['v1_model']}"
        _by_ymm[ymm] = row["image_url"]
        # Keep first image per make+model as fallback
        if mm not in _by_mm:
            _by_mm[mm] = row["image_url"]
    _loaded = True


def get_vehicle_image(year: str, make: str, model: str) -> str | None:
    """Get vehicle image URL. Falls back to make+model match if exact year not found."""
    _load_all()
    make_u, model_u = make.upper(), model.upper()
    # Try exact year+make+model first, then fall back to make+model
    return _by_ymm.get(f"{year}|{make_u}|{model_u}") or _by_mm.get(f"{make_u}|{model_u}")
