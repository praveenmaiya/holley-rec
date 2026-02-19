"""GNN data loader: BigQuery exports to DataFrames with ID mappings."""

import logging
from pathlib import Path
from typing import Any

import pandas as pd
from google.api_core.exceptions import NotFound

from src.bq_client import BQClient

logger = logging.getLogger(__name__)

SQL_DIR = Path(__file__).resolve().parent.parent.parent / "sql" / "gnn"


class GNNDataLoader:
    """Load GNN graph data from BigQuery exports."""

    def __init__(self, config: dict[str, Any], bq_client: BQClient = None):
        self.config = config
        bq_cfg = config["bigquery"]
        self.bq = bq_client or BQClient(
            project=bq_cfg["project_id"],
            dataset=bq_cfg["dataset"],
        )
        self.project_id = bq_cfg["project_id"]
        self.dataset = bq_cfg["dataset"]

        # Node ID mappings (built during load)
        self.user_to_id: dict[str, int] = {}
        self.product_to_id: dict[str, int] = {}
        self.vehicle_to_id: dict[str, int] = {}

    def run_exports(self) -> None:
        """Run SQL export queries to populate BQ tables."""
        baseline_table = (
            self.config.get("eval", {}).get("baseline_table")
            or self.config.get("output", {}).get("baseline_table")
            or "auxia-reporting.company_1950_jp.final_vehicle_recommendations"
        )
        params = {
            "PROJECT_ID": self.project_id,
            "GNN_DATASET": self.dataset,
            "SOURCE_PROJECT": self.config["bigquery"]["source_project"],
            "BASELINE_TABLE": baseline_table,
        }
        for sql_file in ["export_nodes.sql", "export_edges.sql", "export_test_set.sql",
                         "export_sql_baseline.sql", "export_user_purchases.sql"]:
            path = SQL_DIR / sql_file
            logger.info(f"Running {sql_file}...")
            self.bq.run_query_file(str(path), params=params)
            logger.info(f"Completed {sql_file}")

    def load_nodes(self) -> dict[str, pd.DataFrame]:
        """Load node DataFrames and build ID mappings."""
        table_prefix = f"{self.project_id}.{self.dataset}"

        users = self.bq.run_query(f"SELECT * FROM `{table_prefix}.user_nodes`")
        products = self.bq.run_query(f"SELECT * FROM `{table_prefix}.product_nodes`")
        vehicles = self.bq.run_query(f"SELECT * FROM `{table_prefix}.vehicle_nodes`")

        # Canonical ordering and deduplication ensure deterministic ID mapping and
        # stable feature alignment across train/eval/score.
        users = (
            users.drop_duplicates(subset=["email_lower"])
            .sort_values("email_lower")
            .reset_index(drop=True)
        )
        products = (
            products.drop_duplicates(subset=["base_sku"])
            .sort_values("base_sku")
            .reset_index(drop=True)
        )
        vehicles = (
            vehicles.drop_duplicates(subset=["make", "model"])
            .sort_values(["make", "model"])
            .reset_index(drop=True)
        )

        logger.info(f"Loaded nodes: {len(users)} users, {len(products)} products, {len(vehicles)} vehicles")

        # Build deterministic mappings in canonical DataFrame order.
        self.user_to_id = {
            email: i for i, email in enumerate(users["email_lower"].tolist())
        }
        self.product_to_id = {
            sku: i for i, sku in enumerate(products["base_sku"].tolist())
        }
        self.vehicle_to_id = {
            f"{row['make']}|{row['model']}": i
            for i, row in vehicles.iterrows()
        }

        return {"users": users, "products": products, "vehicles": vehicles}

    def load_edges(self) -> dict[str, pd.DataFrame]:
        """Load edge DataFrames."""
        table_prefix = f"{self.project_id}.{self.dataset}"

        interactions = self.bq.run_query(
            f"SELECT * FROM `{table_prefix}.interaction_edges`"
        )
        fitment = self.bq.run_query(
            f"SELECT * FROM `{table_prefix}.fitment_edges`"
        )
        ownership = self.bq.run_query(
            f"SELECT * FROM `{table_prefix}.ownership_edges`"
        )
        copurchase = self.bq.run_query(
            f"SELECT * FROM `{table_prefix}.copurchase_edges`"
        )

        logger.info(
            f"Loaded edges: {len(interactions)} interactions, {len(fitment)} fitment, "
            f"{len(ownership)} ownership, {len(copurchase)} copurchase"
        )

        return {
            "interactions": interactions,
            "fitment": fitment,
            "ownership": ownership,
            "copurchase": copurchase,
        }

    def load_test_set(self) -> pd.DataFrame:
        """Load test set interactions."""
        table_prefix = f"{self.project_id}.{self.dataset}"
        df = self.bq.run_query(f"SELECT * FROM `{table_prefix}.test_interactions`")
        logger.info(f"Loaded {len(df)} test interactions")
        return df

    def load_sql_baseline(self) -> pd.DataFrame:
        """Load SQL baseline recommendations."""
        table_prefix = f"{self.project_id}.{self.dataset}"
        df = self.bq.run_query(f"SELECT * FROM `{table_prefix}.sql_baseline`")
        logger.info(f"Loaded {len(df)} SQL baseline recommendations")
        return df

    def load_user_purchases(self) -> dict[str, set[str]]:
        """Load 365-day purchase history for exclusion.

        Returns:
            email_lower -> set of base_sku strings.
        """
        table_prefix = f"{self.project_id}.{self.dataset}"
        try:
            df = self.bq.run_query(
                f"SELECT email_lower, base_sku FROM `{table_prefix}.user_purchases`"
            )
        except NotFound as exc:
            logger.warning(
                "user_purchases table not found; proceeding without purchase exclusion: %s",
                exc,
            )
            return {}
        logger.info(f"Loaded {len(df)} user-purchase rows")

        required_cols = {"email_lower", "base_sku"}
        missing_cols = required_cols - set(df.columns)
        if missing_cols:
            raise ValueError(
                "user_purchases table missing required columns: "
                + ", ".join(sorted(missing_cols))
            )

        purchases: dict[str, set[str]] = {}
        for email, group in df.groupby("email_lower"):
            purchases[email] = set(group["base_sku"].tolist())
        logger.info(f"Purchase exclusion: {len(purchases)} users with purchases")
        return purchases

    def get_id_mappings(self) -> dict[str, dict]:
        """Return all ID mappings."""
        return {
            "user_to_id": self.user_to_id,
            "product_to_id": self.product_to_id,
            "vehicle_to_id": self.vehicle_to_id,
        }
