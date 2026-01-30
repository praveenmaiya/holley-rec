#!/usr/bin/env python3
"""Metaflow pipeline for GNN batch scoring.

Steps: start → load_model → generate_recs → write_to_bigquery → end

Usage:
    python flows/score_gnn.py run --with kubernetes
    # Or locally:
    python flows/score_gnn.py run
"""

from metaflow import FlowSpec, step, Parameter, kubernetes

import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class ScoreGNNFlow(FlowSpec):
    """Generate GNN recommendations and write to BigQuery."""

    config_path = Parameter(
        "config", default="configs/gnn_config.yaml", help="Path to GNN config"
    )
    data_dir = Parameter(
        "data_dir", default="/tmp/gnn_data", help="Local data directory"
    )
    checkpoint_path = Parameter(
        "checkpoint", default="checkpoints/gnn/best_model.pt", help="Model checkpoint"
    )
    top_k = Parameter("top_k", default=20, help="Number of recs per user")

    @step
    def start(self):
        """Load config."""
        import yaml
        from pathlib import Path

        config_file = Path(self.config_path)
        if config_file.exists():
            with open(config_file) as f:
                self.config = yaml.safe_load(f)
        else:
            self.config = {}

        logger.info("Starting GNN scoring pipeline")
        self.next(self.load_model)

    @kubernetes(cpu=8, memory=65536, service_account="ksa-metaflow")
    @step
    def load_model(self):
        """Load trained model and build graph."""
        import torch

        from src.gnn.data_loader import GNNDataLoader
        from src.gnn.graph_builder import HolleyGraphBuilder
        from src.gnn.model import HolleyGAT

        loader = GNNDataLoader()
        data = loader.load_parquet(self.data_dir)

        self.graph_builder = HolleyGraphBuilder()
        self.hetero_data = self.graph_builder.build(data)

        model_config = self.config.get("model", {})
        self.model = HolleyGAT(
            num_users=self.hetero_data["user"].num_nodes,
            num_products=self.hetero_data["product"].num_nodes,
            num_vehicles=self.hetero_data["vehicle"].num_nodes,
            num_part_types=self.graph_builder.num_part_types,
            embedding_dim=model_config.get("embedding_dim", 128),
            hidden_dim=model_config.get("hidden_dim", 256),
            num_heads=model_config.get("num_heads", 4),
            dropout=model_config.get("dropout", 0.1),
        )

        checkpoint = torch.load(self.checkpoint_path, map_location="cpu", weights_only=False)
        self.model.load_state_dict(checkpoint["model_state_dict"])
        logger.info(f"Loaded model from {self.checkpoint_path}")

        self.next(self.generate_recs)

    @kubernetes(cpu=8, memory=65536, service_account="ksa-metaflow")
    @step
    def generate_recs(self):
        """Generate top-K recommendations for all users."""
        from src.gnn.evaluator import GNNEvaluator

        evaluator = GNNEvaluator(
            model=self.model,
            data=self.hetero_data,
            graph_builder=self.graph_builder,
            top_k=self.top_k,
            device="cpu",
        )

        self.recs_df = evaluator.generate_recommendations()
        logger.info(f"Generated {len(self.recs_df)} recommendations")

        self.next(self.write_to_bigquery)

    @kubernetes(cpu=4, memory=16384, service_account="ksa-metaflow")
    @step
    def write_to_bigquery(self):
        """Write recommendations to BigQuery."""
        from src.bq_client import BQClient

        bq_config = self.config.get("bigquery", {})
        scoring_config = self.config.get("scoring", {})

        project = bq_config.get("project", "auxia-reporting")
        dataset = bq_config.get("dataset", "temp_holley_gnn")
        table = scoring_config.get("output_table", "gnn_recommendations")

        client = BQClient(project=project, dataset=dataset)
        table_id = f"{project}.{dataset}.{table}"

        client.write_table(self.recs_df, table_id)
        logger.info(f"Wrote {len(self.recs_df)} recs → {table_id}")

        self.next(self.end)

    @step
    def end(self):
        """Done."""
        logger.info("GNN scoring pipeline complete")


if __name__ == "__main__":
    ScoreGNNFlow()
