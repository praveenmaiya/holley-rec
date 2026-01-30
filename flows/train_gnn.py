#!/usr/bin/env python3
"""Metaflow pipeline for GNN model training.

Steps: start → export_data → build_graph → train_model → evaluate → end

Usage:
    python flows/train_gnn.py run --with kubernetes
    # Or locally:
    python flows/train_gnn.py run
"""

from metaflow import FlowSpec, step, Parameter, kubernetes

import logging
import json

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class TrainGNNFlow(FlowSpec):
    """Train Holley GNN recommendation model."""

    config_path = Parameter(
        "config", default="configs/gnn_config.yaml", help="Path to GNN config"
    )
    data_dir = Parameter(
        "data_dir", default="/tmp/gnn_data", help="Local data directory for parquet cache"
    )
    checkpoint_dir = Parameter(
        "checkpoint_dir", default="checkpoints/gnn", help="Model checkpoint directory"
    )
    device = Parameter(
        "device", default="cuda", help="Training device (cuda or cpu)"
    )

    @step
    def start(self):
        """Initialize and validate config."""
        import yaml
        from pathlib import Path

        config_file = Path(self.config_path)
        if config_file.exists():
            with open(config_file) as f:
                self.config = yaml.safe_load(f)
        else:
            logger.warning(f"Config not found at {self.config_path}, using defaults")
            self.config = {}

        logger.info("Starting GNN training pipeline")
        self.next(self.export_data)

    @kubernetes(cpu=4, memory=16384, service_account="ksa-metaflow")
    @step
    def export_data(self):
        """Export node and edge data from BigQuery to Parquet."""
        from src.gnn.data_loader import GNNDataLoader

        bq_config = self.config.get("bigquery", {})
        loader = GNNDataLoader(
            project=bq_config.get("project", "auxia-reporting"),
            dataset=bq_config.get("dataset", "temp_holley_gnn"),
        )

        loader.export_parquet(self.data_dir)
        self.data_summary = loader.summary()
        logger.info(f"Data export complete: {self.data_summary}")

        self.next(self.build_graph)

    @kubernetes(cpu=8, memory=65536, service_account="ksa-metaflow")
    @step
    def build_graph(self):
        """Build PyG HeteroData graph from exported data."""
        import pickle

        from src.gnn.data_loader import GNNDataLoader
        from src.gnn.graph_builder import HolleyGraphBuilder

        loader = GNNDataLoader()
        data = loader.load_parquet(self.data_dir)

        builder = HolleyGraphBuilder()
        self.hetero_data = builder.build(data)
        self.graph_builder = builder

        logger.info(f"Graph built: {self.hetero_data}")
        self.next(self.train_model)

    @kubernetes(cpu=16, memory=131072, gpu=1, service_account="ksa-metaflow")
    @step
    def train_model(self):
        """Train the HolleyGAT model."""
        import torch

        from src.gnn.model import HolleyGAT
        from src.gnn.trainer import GNNTrainer, TrainConfig

        model_config = self.config.get("model", {})
        train_config_dict = self.config.get("training", {})

        device = self.device if torch.cuda.is_available() else "cpu"
        logger.info(f"Training on device: {device}")

        model = HolleyGAT(
            num_users=self.hetero_data["user"].num_nodes,
            num_products=self.hetero_data["product"].num_nodes,
            num_vehicles=self.hetero_data["vehicle"].num_nodes,
            num_part_types=self.graph_builder.num_part_types,
            embedding_dim=model_config.get("embedding_dim", 128),
            hidden_dim=model_config.get("hidden_dim", 256),
            num_heads=model_config.get("num_heads", 4),
            dropout=model_config.get("dropout", 0.1),
        )

        train_config = TrainConfig(
            epochs=train_config_dict.get("epochs", 100),
            emb_lr=train_config_dict.get("emb_lr", 0.001),
            gnn_lr=train_config_dict.get("gnn_lr", 0.01),
            patience=train_config_dict.get("patience", 10),
            checkpoint_dir=self.checkpoint_dir,
        )

        trainer = GNNTrainer(model, self.hetero_data, train_config, device=device)
        self.history = trainer.train()

        self.model = model
        logger.info(f"Training complete. Best val loss: {trainer.best_val_loss:.4f}")

        self.next(self.evaluate)

    @kubernetes(cpu=8, memory=65536, service_account="ksa-metaflow")
    @step
    def evaluate(self):
        """Evaluate GNN vs SQL baseline."""
        from src.gnn.data_loader import GNNDataLoader
        from src.gnn.evaluator import GNNEvaluator

        loader = GNNDataLoader()
        data = loader.load_parquet(self.data_dir)

        evaluator = GNNEvaluator(
            model=self.model,
            data=self.hetero_data,
            graph_builder=self.graph_builder,
            device="cpu",
        )

        test_clicks = data.get("test_clicks")
        user_nodes = data.get("user_nodes")

        if test_clicks is not None and user_nodes is not None:
            metrics = evaluator.evaluate_against_clicks(test_clicks, user_nodes)
            self.eval_results = {
                tier: m.to_dict() for tier, m in metrics.items()
            }
            logger.info("Evaluation results:")
            for tier, m in self.eval_results.items():
                logger.info(f"  {tier}: MRR={m['MRR']:.4f}, Recall@10={m['Recall@10']:.4f}")
        else:
            logger.warning("No test clicks available for evaluation")
            self.eval_results = {}

        self.next(self.end)

    @step
    def end(self):
        """Log final results."""
        logger.info("GNN training pipeline complete")
        if hasattr(self, "eval_results") and self.eval_results:
            logger.info(f"Final metrics: {json.dumps(self.eval_results, indent=2)}")


if __name__ == "__main__":
    TrainGNNFlow()
