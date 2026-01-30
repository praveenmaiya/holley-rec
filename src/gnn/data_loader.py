"""BigQuery data loader for GNN node and edge tables."""

import logging
from pathlib import Path

import pandas as pd

from src.bq_client import BQClient

logger = logging.getLogger(__name__)


class GNNDataLoader:
    """Load GNN node and edge data from BigQuery."""

    TABLES = {
        "user_nodes": "user_nodes",
        "product_nodes": "product_nodes",
        "vehicle_nodes": "vehicle_nodes",
        "edges_user_product": "edges_user_product",
        "edges_product_vehicle": "edges_product_vehicle",
        "edges_user_vehicle": "edges_user_vehicle",
        "edges_product_product": "edges_product_product",
        "test_clicks": "test_clicks",
    }

    def __init__(
        self,
        project: str = "auxia-reporting",
        dataset: str = "temp_holley_gnn",
    ):
        self.bq = BQClient(project=project, dataset=dataset)
        self.project = project
        self.dataset = dataset
        self._cache: dict[str, pd.DataFrame] = {}

    def load_table(self, table_name: str) -> pd.DataFrame:
        """Load a table from BigQuery, with caching."""
        if table_name in self._cache:
            return self._cache[table_name]

        full_table = f"{self.project}.{self.dataset}.{table_name}"
        query = f"SELECT * FROM `{full_table}`"
        df = self.bq.run_query(query)
        logger.info(f"Loaded {table_name}: {len(df)} rows")
        self._cache[table_name] = df
        return df

    def load_all(self) -> dict[str, pd.DataFrame]:
        """Load all node and edge tables."""
        data = {}
        for key, table in self.TABLES.items():
            data[key] = self.load_table(table)
        return data

    def export_parquet(self, output_dir: str) -> None:
        """Export all tables to Parquet files for local training."""
        out = Path(output_dir)
        out.mkdir(parents=True, exist_ok=True)

        for key, table in self.TABLES.items():
            df = self.load_table(table)
            path = out / f"{key}.parquet"
            df.to_parquet(path, index=False)
            logger.info(f"Exported {key} → {path} ({len(df)} rows)")

    def load_parquet(self, input_dir: str) -> dict[str, pd.DataFrame]:
        """Load all tables from local Parquet files."""
        inp = Path(input_dir)
        data = {}
        for key in self.TABLES:
            path = inp / f"{key}.parquet"
            if path.exists():
                data[key] = pd.read_parquet(path)
                logger.info(f"Loaded {key} from parquet: {len(data[key])} rows")
            else:
                logger.warning(f"Missing parquet: {path}")
        return data

    def summary(self) -> dict[str, int]:
        """Return row counts for all loaded tables."""
        return {k: len(v) for k, v in self._cache.items()}
