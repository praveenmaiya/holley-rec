"""Load treatment configuration from CSV files with BQ PostgreSQL fallback."""

import csv
import logging
from functools import lru_cache
from pathlib import Path

_CONFIGS_DIR = Path(__file__).parent.parent.parent / "configs"
_pg_cache: dict[int, dict] = {}
log = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def _load_treatments() -> dict[int, dict]:
    """Load all treatments from CSV configs."""
    treatments = {}

    for csv_file, ttype in [
        ("personalized_treatments.csv", "Personalized"),
        ("static_treatments.csv", "Static"),
    ]:
        path = _CONFIGS_DIR / csv_file
        if not path.exists():
            continue
        with open(path) as f:
            reader = csv.DictReader(f)
            for row in reader:
                tid = int(row["treatment_id"])
                treatments[tid] = {
                    "name": row.get("treatment_name", ""),
                    "type": ttype,
                }
    return treatments


def _lookup_from_pg(treatment_id: int) -> dict:
    """Fallback: look up treatment from PostgreSQL via BQ federated query."""
    if treatment_id in _pg_cache:
        return _pg_cache[treatment_id]

    try:
        from services.bq_client import run_query  # noqa: C0415

        query = f"""
        SELECT * FROM EXTERNAL_QUERY(
          "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
          "SELECT treatment_id, name FROM treatment WHERE treatment_id = {int(treatment_id)}"
        )
        """
        df = run_query(query)
        if not df.empty:
            name = df.iloc[0]["name"]
            ttype = "Personalized" if "personalized" in name.lower() else "Static"
            result = {"name": name, "type": ttype}
        else:
            result = {}
    except Exception:
        log.warning("Failed to look up treatment %s from PostgreSQL", treatment_id)
        result = {}

    _pg_cache[treatment_id] = result
    return result


def _get_treatment(treatment_id: int) -> dict:
    """Get treatment info from CSV configs, falling back to PostgreSQL."""
    t = _load_treatments().get(treatment_id)
    if t:
        return t
    return _lookup_from_pg(treatment_id)


def get_treatment_name(treatment_id: int) -> str:
    """Get human-readable treatment name."""
    t = _get_treatment(treatment_id)
    return t.get("name", f"Treatment {treatment_id}")


def get_treatment_type(treatment_id: int) -> str:
    """Get treatment type: 'Personalized', 'Static', or 'Unknown'."""
    t = _get_treatment(treatment_id)
    return t.get("type", "Unknown")
