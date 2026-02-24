"""
Holley GNN Recommendation Flow — Corrected Skeleton (Round 4)
=============================================================

This is the reference implementation for gnn_recommendation_flow.py
that will live at:
  auxia.prediction.metaflow/flows/modeltraining/holley/gnn_recommendation_flow.py

All API calls have been verified against the actual source repo:
  - CostMonitor: cost_monitoring.py (project_id required, label required for Sql)
  - sql(): sql.py (compile-time string literals ONLY, SqlParam.int/string factory methods)
  - export_to_gcs(): cost_monitoring.py:136 (GCS-backed artifacts for large data)
  - BQ write: load_table_from_dataframe + LoadJobConfig (not to_gbq)
  - Parquet read: polars pl.scan_parquet() (NOT pandas — handles GCS globs natively)

Architecture: 2-step flow
  Step 1 (start):           Layer 1 — BQ export → GCS parquet (no self.dataframes pickle)
  Step 2 (train_and_score): Layers 2+3 — GNN train/eval/score + BQ write

Verified against patterns in:
  - bandit_click_model.py (CostMonitor init, result.to_dataframe())
  - 1943_auto_cluster_contextual_bandit_click_model.py (export_to_gcs, pl.scan_parquet)
  - saturation_metrics.py (load_table_from_dataframe + LoadJobConfig)
  - 1887_position_frequency_model.py (idempotent BQ write pattern)

Round 4 fixes (Codex sign-off):
  C1: Switched pd.read_parquet → pl.scan_parquet (handles GCS globs natively)
  C2: Split nodes UNION ALL into 3 separate exports (column schema mismatch)
  C3: YAML config via IncludeFile (packaged into Metaflow task automatically)
  H1: Price floor 25 → 50 (matches QA rule)
  M1: score_only skips test_set export
"""

from metaflow import FlowSpec, step, Parameter, IncludeFile, retry, current
from auxia.prediction.colab.metaflow.kubernetes import kubernetes
from pathlib import Path
import yaml
import logging

logger = logging.getLogger(__name__)


class HolleyGNNFlow(FlowSpec):
    """Holley GNN recommendation pipeline.

    2-step architecture:
      start:           Layer 1 — BQ data export to GCS parquet
      train_and_score: Layers 2+3 — GNN engine + BQ output write
    """

    # --- Standard Parameters (matching bandit_click_model.py pattern) ---
    company_id = Parameter("company_id", type=int, default=1950)
    tier = Parameter("tier", type=str, default="medium",
                     help="Cost tier for BigQuery usage: 'low', 'medium', or 'high'")
    project_id = Parameter("project_id", type=str, default="auxia-ml",
                           help="GCP project for BigQuery client")
    data_project = Parameter("data_project", type=str, default="auxia-gcp",
                             help="GCP project containing BigQuery data")

    # --- GNN-Specific Parameters ---
    mode = Parameter("mode", type=str, default="train_score",
                     help="Pipeline mode: train_score | score_only | evaluate_only")
    checkpoint_uri = Parameter("checkpoint_uri", type=str, default="",
                               help="GCS URI of existing checkpoint (required for score_only)")

    # --- Config as IncludeFile ---
    # IncludeFile reads file at submission time and packages it as a data artifact.
    # Solves: Metaflow only packages .py files by default — YAML would be missing on K8s.
    # (Round 4 C3 fix)
    config_file = IncludeFile(
        "config_file",
        default=str(Path(__file__).resolve().parent / "config" / "holley_gnn.yaml"),
        help="Path to GNN config YAML file",
    )

    # ─── Step 1: Data Export (Layer 1) ───────────────────────────────
    @kubernetes(cpu=2, memory=8192, disk=50000)
    @retry(times=2)
    @step
    def start(self):
        """Layer 1: Export data from BigQuery to GCS parquet.

        Uses CostMonitor.export_to_gcs() for large datasets (repo-mandated pattern).
        Passes GCS paths (strings) to next step — no large DataFrame pickle.

        SQL is inline (compile-time literals) because sql() requires AST-verified
        string constants. External .sql files are incompatible with the sql() builder.
        """
        from auxia.prediction.colab.datageneration.utils.sql import sql, SqlParam, SqlIdentifier
        from auxia.prediction.colab.datageneration.utils.cost_monitoring import CostMonitor

        # Validate mode early
        valid_modes = ("train_score", "score_only", "evaluate_only")
        if self.mode not in valid_modes:
            raise ValueError(f"Invalid mode '{self.mode}'. Must be one of: {valid_modes}")

        # score_only requires a checkpoint (still exports graph data for inference)
        if self.mode == "score_only" and not self.checkpoint_uri:
            raise ValueError("checkpoint_uri is required for score_only mode")

        # CostMonitor: project_id is required (verified: cost_monitoring.py:11)
        # model_name must be registered in cost_mapping.py (add gnn_recommendation)
        cost_monitor = CostMonitor(
            project_id=self.project_id,
            tier=self.tier,
            model_name="gnn_recommendation",
        )

        # BQ table references as safe identifiers
        # SqlIdentifier.quote() for dotted names (verified: sql.py:182)
        company_dataset = SqlIdentifier.quote(f"{self.data_project}.company_{self.company_id}")
        data_dataset = SqlIdentifier.quote(f"{self.data_project}.data_company_{self.company_id}")

        # --- Export Nodes: 3 separate queries (Round 4 C2 fix) ---
        # sql() requires compile-time string literal (AST-verified: sql.py:608)
        # Cannot load from .sql file — would fail: "must be a compile-time constant string"
        #
        # Separate exports per node type because users/products/vehicles have
        # different column schemas — UNION ALL would fail in BigQuery.
        users_query = sql(
            """
            SELECT DISTINCT
              LOWER(TRIM(ua.v1_email)) AS user_id,
              ua.v1_year AS year,
              ua.v1_make AS make,
              ua.v1_model AS model
            FROM {company_dataset}.ingestion_unified_attributes_schema_incremental ua
            WHERE ua.v1_email IS NOT NULL
              AND ua.v1_email != ''
              AND ua.v1_year IS NOT NULL
            """,
            company_dataset=company_dataset,
        )

        products_query = sql(
            """
            SELECT DISTINCT
              REGEXP_REPLACE(ii.sku, r'([0-9])[BRGP]$', r'\\1') AS product_id,
              ii.name AS product_name,
              ii.PartType AS part_type,
              COALESCE(ii.price, 0) AS price,
              ii.image AS image_url,
              ii.url AS product_url,
              LOG(1 + COALESCE(order_counts.order_count, 0)) AS log_popularity,
              CASE WHEN LOWER(ii.PartType) LIKE '%universal%' THEN TRUE ELSE FALSE END AS is_universal
            FROM {data_dataset}.import_items ii
            LEFT JOIN (
              SELECT ProductID, COUNT(*) AS order_count
              FROM {data_dataset}.import_orders
              GROUP BY ProductID
            ) order_counts ON ii.sku = order_counts.ProductID
            WHERE ii.price >= 50
            """,
            data_dataset=data_dataset,
        )

        vehicles_query = sql(
            """
            SELECT DISTINCT
              CONCAT(vpf.Year, ':', vpf.Make, ':', vpf.Model) AS vehicle_key,
              vpf.Year AS year,
              vpf.Make AS make,
              vpf.Model AS model,
              COUNT(DISTINCT vpf.sku) AS product_count
            FROM {data_dataset}.vehicle_product_fitment_data vpf
            GROUP BY vpf.Year, vpf.Make, vpf.Model
            """,
            data_dataset=data_dataset,
        )

        # --- Export Edges (interactions + fitment + ownership + co-purchase) ---
        edges_query = sql(
            """
            WITH interactions AS (
              SELECT
                LOWER(TRIM(ua.v1_email)) AS user_id,
                REGEXP_REPLACE(
                  COALESCE(e.string_value, CAST(e.long_value AS STRING)),
                  r'([0-9])[BRGP]$', r'\\1'
                ) AS product_id,
                e.event_name AS interaction_type,
                e.event_timestamp AS event_timestamp
              FROM {company_dataset}.ingestion_unified_schema_incremental e
              JOIN {company_dataset}.ingestion_unified_attributes_schema_incremental ua
                ON e.user_id = ua.user_id
              WHERE e.event_name IN ('Viewed Product', 'Added to Cart', 'Placed Order')
                AND ua.v1_email IS NOT NULL
                AND DATE(e.event_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL {lookback_days} DAY)
            ),
            fitment AS (
              SELECT DISTINCT
                REGEXP_REPLACE(vpf.sku, r'([0-9])[BRGP]$', r'\\1') AS product_id,
                CONCAT(vpf.Year, ':', vpf.Make, ':', vpf.Model) AS vehicle_key
              FROM {data_dataset}.vehicle_product_fitment_data vpf
            ),
            ownership AS (
              SELECT DISTINCT
                LOWER(TRIM(ua.v1_email)) AS user_id,
                CONCAT(ua.v1_year, ':', ua.v1_make, ':', ua.v1_model) AS vehicle_key
              FROM {company_dataset}.ingestion_unified_attributes_schema_incremental ua
              WHERE ua.v1_email IS NOT NULL
                AND ua.v1_year IS NOT NULL
            )
            SELECT 'interaction' AS edge_type, user_id, product_id,
                   CAST(NULL AS STRING) AS vehicle_key,
                   interaction_type, event_timestamp
            FROM interactions
            UNION ALL
            SELECT 'fitment' AS edge_type, CAST(NULL AS STRING) AS user_id,
                   product_id, vehicle_key,
                   CAST(NULL AS STRING) AS interaction_type,
                   CAST(NULL AS TIMESTAMP) AS event_timestamp
            FROM fitment
            UNION ALL
            SELECT 'ownership' AS edge_type, user_id,
                   CAST(NULL AS STRING) AS product_id, vehicle_key,
                   CAST(NULL AS STRING) AS interaction_type,
                   CAST(NULL AS TIMESTAMP) AS event_timestamp
            FROM ownership
            """,
            company_dataset=company_dataset,
            data_dataset=data_dataset,
            lookback_days=SqlParam.int(180),
        )

        # --- Export Test Set (recent purchases for evaluation) ---
        test_set_query = sql(
            """
            SELECT
              LOWER(TRIM(ua.v1_email)) AS user_id,
              REGEXP_REPLACE(
                COALESCE(e.string_value, CAST(e.long_value AS STRING)),
                r'([0-9])[BRGP]$', r'\\1'
              ) AS product_id,
              e.event_timestamp AS purchase_timestamp
            FROM {company_dataset}.ingestion_unified_schema_incremental e
            JOIN {company_dataset}.ingestion_unified_attributes_schema_incremental ua
              ON e.user_id = ua.user_id
            WHERE e.event_name = 'Placed Order'
              AND ua.v1_email IS NOT NULL
              AND DATE(e.event_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL {test_window_days} DAY)
            """,
            company_dataset=company_dataset,
            test_window_days=SqlParam.int(30),
        )

        # --- Export User Purchases (for exclusion in scoring) ---
        purchases_query = sql(
            """
            SELECT DISTINCT
              LOWER(TRIM(ua.v1_email)) AS user_id,
              REGEXP_REPLACE(
                COALESCE(e.string_value, CAST(e.long_value AS STRING)),
                r'([0-9])[BRGP]$', r'\\1'
              ) AS product_id
            FROM {company_dataset}.ingestion_unified_schema_incremental e
            JOIN {company_dataset}.ingestion_unified_attributes_schema_incremental ua
              ON e.user_id = ua.user_id
            WHERE e.event_name = 'Placed Order'
              AND ua.v1_email IS NOT NULL
            """,
            company_dataset=company_dataset,
        )

        # Export to GCS parquet via CostMonitor.export_to_gcs()
        # (repo-mandated pattern: CLAUDE.md:235, verified in 1943_auto_cluster flow)
        # Returns GCS glob path (string), stored as self.* artifact — pickle-safe
        self.users_gcs_path = cost_monitor.export_to_gcs(
            users_query, "users", label="export_users"
        )
        self.products_gcs_path = cost_monitor.export_to_gcs(
            products_query, "products", label="export_products"
        )
        self.vehicles_gcs_path = cost_monitor.export_to_gcs(
            vehicles_query, "vehicles", label="export_vehicles"
        )
        self.edges_gcs_path = cost_monitor.export_to_gcs(
            edges_query, "edges", label="export_edges"
        )
        self.purchases_gcs_path = cost_monitor.export_to_gcs(
            purchases_query, "purchases", label="export_user_purchases"
        )

        # test_set only needed for train_score and evaluate_only (Round 4 M1 fix)
        if self.mode != "score_only":
            self.test_set_gcs_path = cost_monitor.export_to_gcs(
                test_set_query, "test_set", label="export_test_set"
            )
        else:
            self.test_set_gcs_path = None  # Not needed — score_only skips evaluation

        logger.info(
            f"Data export complete to GCS:\n"
            f"  users:     {self.users_gcs_path}\n"
            f"  products:  {self.products_gcs_path}\n"
            f"  vehicles:  {self.vehicles_gcs_path}\n"
            f"  edges:     {self.edges_gcs_path}\n"
            f"  test_set:  {self.test_set_gcs_path}\n"
            f"  purchases: {self.purchases_gcs_path}"
        )

        self.next(self.train_and_score)

    # ─── Step 2: Train + Score (Layers 2+3) ──────────────────────────
    @kubernetes(cpu=8, memory=65536, disk=100000)
    @step
    def train_and_score(self):
        """Layers 2+3: GNN training, evaluation, scoring, and BQ output.

        All PyTorch/PyG work in a single step — avoids pickle serialization
        of C++ extension types between Metaflow steps.

        Loads data from GCS parquet (exported in step 1).
        Saves checkpoint to GCS for auditability and future step splitting.
        Writes recommendations via load_table_from_dataframe (not to_gbq).

        No @retry — training takes 30-60 min. Retry would re-run entire training.
        If needed later, make all side effects idempotent first.
        """
        import os
        import torch
        import polars as pl
        from google.cloud import bigquery, storage

        # Import GNN engine via package-level public API
        # (verified: gnn/__init__.py exports mode_train, mode_score, mode_evaluate)
        from auxia.prediction.colab.algorithms.gnn import (
            mode_train, mode_score, mode_evaluate, CONTRACT_VERSION
        )
        from auxia.prediction.colab.algorithms.customer_models.holley_gnn_plugin import (
            HolleyPlugin
        )

        # Load config from IncludeFile (packaged into Metaflow task at submission time)
        # Round 4 C3 fix: YAML is not in default .py-only packaging
        config = yaml.safe_load(self.config_file)

        # Contract version check — explicit exception, not assert
        config_version = config.get("contract_version")
        if config_version != CONTRACT_VERSION:
            raise RuntimeError(
                f"Contract version mismatch: config has '{config_version}', "
                f"engine requires '{CONTRACT_VERSION}'. "
                f"Update config or engine to match."
            )

        # Initialize plugin — secret from K8s secret mount or env
        # (TODO: Wire HOLLEY_USER_SALT via K8s Secret / Secret Manager)
        salt = os.environ.get("HOLLEY_USER_SALT")
        if not salt:
            raise RuntimeError(
                "HOLLEY_USER_SALT not set. "
                "Configure via K8s Secret mount or GCP Secret Manager."
            )
        plugin = HolleyPlugin(salt=salt)

        # Load DataFrames from GCS parquet (exported in step 1)
        # Uses Polars pl.scan_parquet() — handles GCS globs natively
        # (Round 4 C1 fix: pandas can't read gs://.../*.parquet globs)
        # Verified: 1943_auto_cluster uses pl.scan_parquet(self.*_gcs_path)
        dataframes = {
            "users": pl.scan_parquet(self.users_gcs_path).collect().to_pandas(),
            "products": pl.scan_parquet(self.products_gcs_path).collect().to_pandas(),
            "vehicles": pl.scan_parquet(self.vehicles_gcs_path).collect().to_pandas(),
            "edges": pl.scan_parquet(self.edges_gcs_path).collect().to_pandas(),
            "user_purchases": pl.scan_parquet(self.purchases_gcs_path).collect().to_pandas(),
        }
        if self.test_set_gcs_path:
            dataframes["test_set"] = (
                pl.scan_parquet(self.test_set_gcs_path).collect().to_pandas()
            )

        logger.info(
            f"Loaded from GCS: "
            f"{len(dataframes['users'])} users, "
            f"{len(dataframes['products'])} products, "
            f"{len(dataframes['vehicles'])} vehicles, "
            f"{len(dataframes['edges'])} edges, "
            f"{len(dataframes.get('test_set', []))} test rows, "
            f"{len(dataframes['user_purchases'])} purchase rows"
        )

        # === LAYER 2: Generic Engine ===

        train_result = None
        self.eval_metrics = None
        self.go_no_go_passed = None

        if self.mode in ("train_score", "evaluate_only"):
            # Train
            train_result = mode_train(config, dataframes, plugin)
            logger.info("Training complete")

            # Evaluate (go/no-go thresholds from config YAML, NOT from plugin)
            eval_result = mode_evaluate(
                config, dataframes, plugin, train_result=train_result
            )
            self.eval_metrics = eval_result.metrics
            self.go_no_go_passed = eval_result.passed_go_no_go

            if not eval_result.passed_go_no_go:
                logger.error(
                    f"Go/no-go FAILED: {eval_result.failed_checks}. "
                    f"Thresholds: {eval_result.thresholds}"
                )
                if self.mode == "evaluate_only":
                    self.next(self.end)
                    return
                # train_score: log warning but continue (shadow mode)
                logger.warning(
                    "Proceeding to score despite go/no-go failure (shadow mode)"
                )
            else:
                logger.info(f"Go/no-go PASSED: {eval_result.metrics}")

            # Save checkpoint to GCS — run-unique path using current.run_id
            run_id = current.run_id  # Metaflow's unique run identifier
            checkpoint_uri = (
                f"gs://auxia-models/{config['client']['id']}/gnn/"
                f"{config['output']['model_version']}/{run_id}/model.pt"
            )
            local_path = "/tmp/gnn_checkpoint.pt"
            torch.save({
                'model_state_dict': train_result.model.state_dict(),
                'config': config,
                'metrics': eval_result.metrics,
                'contract_version': CONTRACT_VERSION,
                'run_id': run_id,
            }, local_path)

            bucket_name, blob_path = checkpoint_uri.replace("gs://", "").split("/", 1)
            storage.Client().bucket(bucket_name).blob(blob_path).upload_from_filename(
                local_path
            )
            self.checkpoint_uri_result = checkpoint_uri  # String — pickle-safe
            logger.info(f"Checkpoint saved: {checkpoint_uri}")

        if self.mode in ("train_score", "score_only"):
            # Determine checkpoint source
            if self.mode == "score_only":
                score_checkpoint_uri = self.checkpoint_uri  # From Parameter
            else:
                score_checkpoint_uri = None  # Use train_result directly

            # Score
            recs_df = mode_score(
                config, dataframes, plugin,
                train_result=train_result,
                checkpoint_uri=score_checkpoint_uri,
            )

            # === LAYER 3: Write to BigQuery ===
            output_table = config["output"]["shadow_table"]
            logger.info(f"Writing {len(recs_df)} recommendations to {output_table}")

            # Use load_table_from_dataframe + LoadJobConfig (repo pattern)
            # Verified: saturation_metrics.py:197, 1887_position_frequency_model.py:1062
            bq_client = bigquery.Client(project=self.data_project)
            job_config = bigquery.LoadJobConfig(
                write_disposition="WRITE_TRUNCATE",  # Idempotent: full table replace
            )
            load_job = bq_client.load_table_from_dataframe(
                recs_df, output_table, job_config=job_config
            )
            load_job.result()  # Wait for completion

            self.recs_count = len(recs_df)
            logger.info(
                f"Output complete: {self.recs_count} recommendations "
                f"written to {output_table}"
            )

        self.next(self.end)

    # ─── End ─────────────────────────────────────────────────────────
    @step
    def end(self):
        """Summary step — logs final results."""
        if self.eval_metrics is not None:
            logger.info(f"Evaluation metrics: {self.eval_metrics}")
        if self.go_no_go_passed is not None:
            logger.info(f"Go/no-go passed: {self.go_no_go_passed}")
        if hasattr(self, 'recs_count'):
            logger.info(f"Recommendations written: {self.recs_count}")
        if hasattr(self, 'checkpoint_uri_result'):
            logger.info(f"Checkpoint: {self.checkpoint_uri_result}")


if __name__ == "__main__":
    HolleyGNNFlow()
