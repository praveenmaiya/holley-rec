"""Tests for rec_engine.run — CLI entry point and orchestration."""

import numpy as np
import pandas as pd
import pytest
import torch

from plugins.defaults import DefaultPlugin
from rec_engine import is_valid_scalar
from rec_engine.run import (
    _load_model_from_checkpoint,
    load_plugin,
    mode_evaluate,
    mode_score,
    mode_train,
    preprocess_dataframes,
)


class TestIsValidScalar:
    """Direct tests for the shared is_valid_scalar utility."""

    def test_none(self):
        assert is_valid_scalar(None) is False

    def test_pd_na(self):
        assert is_valid_scalar(pd.NA) is False

    def test_float_nan(self):
        assert is_valid_scalar(float("nan")) is False

    def test_np_nan(self):
        assert is_valid_scalar(np.nan) is False

    def test_valid_string(self):
        assert is_valid_scalar("hello") is True

    def test_empty_string(self):
        assert is_valid_scalar("") is True  # empty but not null

    def test_valid_int(self):
        assert is_valid_scalar(42) is True

    def test_valid_float(self):
        assert is_valid_scalar(3.14) is True

    def test_valid_bool(self):
        assert is_valid_scalar(True) is True

    def test_list_like(self):
        assert is_valid_scalar([1, 2]) is False

    def test_tuple_like(self):
        assert is_valid_scalar((1, 2)) is False

    def test_dict_like(self):
        assert is_valid_scalar({"a": 1}) is False

    def test_numpy_array(self):
        assert is_valid_scalar(np.array([1, 2])) is False

    def test_set_like(self):
        assert is_valid_scalar({1, 2}) is False

    def test_np_int64(self):
        assert is_valid_scalar(np.int64(3)) is True

    def test_np_float64(self):
        assert is_valid_scalar(np.float64(2.5)) is True

    def test_np_float64_nan(self):
        assert is_valid_scalar(np.float64("nan")) is False


class TestLoadPlugin:
    def test_default_plugin_when_none(self):
        config = {}
        plugin = load_plugin(config)
        assert type(plugin).__name__ == "DefaultPlugin"

    def test_load_default_plugin_by_path(self):
        config = {"plugin": "plugins.defaults.DefaultPlugin"}
        plugin = load_plugin(config)
        assert type(plugin).__name__ == "DefaultPlugin"

    def test_load_holley_plugin(self):
        config = {"plugin": "src.gnn.holley_plugins.HolleyPlugin"}
        plugin = load_plugin(config)
        assert type(plugin).__name__ == "HolleyPlugin"

    def test_invalid_plugin_path(self):
        config = {"plugin": "nonexistent.module.Plugin"}
        with pytest.raises((ImportError, ModuleNotFoundError)):
            load_plugin(config)


class TestPreprocessDataframes:
    """C1: Plugin normalization hooks are wired into engine pipeline."""

    @pytest.fixture
    def plugin(self):
        return DefaultPlugin(salt="test-salt")

    @pytest.fixture
    def raw_dataframes(self):
        return {
            "users": pd.DataFrame({"user_id": ["alice@test.com", "bob@test.com"]}),
            "products": pd.DataFrame({
                "product_id": ["SKU-001", "SKU-002"],
                "price": [50.0, 100.0],
                "popularity": [1.0, 2.0],
            }),
            "interactions": pd.DataFrame({
                "user_id": ["alice@test.com", "bob@test.com"],
                "product_id": ["SKU-001", "SKU-002"],
                "interaction_type": ["view", "cart"],
                "weight": [1.0, 1.0],
            }),
        }

    def test_user_ids_normalized(self, raw_dataframes, plugin):
        result = preprocess_dataframes(raw_dataframes, plugin, {})
        # IDs should be transformed (DefaultPlugin strips whitespace + hashes)
        assert result["users"]["user_id"].tolist() != ["alice@test.com", "bob@test.com"]
        # Normalization should be consistent
        assert result["users"]["user_id"][0] == result["interactions"]["user_id"][0]

    def test_product_ids_normalized(self, raw_dataframes, plugin):
        result = preprocess_dataframes(raw_dataframes, plugin, {})
        # DefaultPlugin strips whitespace
        assert result["products"]["product_id"][0] == plugin.normalize_product_id("SKU-001")
        assert result["interactions"]["product_id"][0] == plugin.normalize_product_id("SKU-001")

    def test_originals_not_mutated(self, raw_dataframes, plugin):
        original_ids = raw_dataframes["users"]["user_id"].tolist()
        preprocess_dataframes(raw_dataframes, plugin, {})
        assert raw_dataframes["users"]["user_id"].tolist() == original_ids

    def test_interaction_weight_mapping(self, raw_dataframes):
        """Plugin weight mapping overrides weight column."""
        class WeightPlugin(DefaultPlugin):
            def map_interaction_weight(self, interaction_type):
                return {"view": 1.0, "cart": 3.0}.get(interaction_type)

        plugin = WeightPlugin(salt="test")
        result = preprocess_dataframes(raw_dataframes, plugin, {})
        assert result["interactions"]["weight"][1] == 3.0

    def test_copurchase_product_ids_normalized(self, raw_dataframes, plugin):
        raw_dataframes["copurchase"] = pd.DataFrame({
            "product_a": ["SKU-001"], "product_b": ["SKU-002"], "weight": [2.0],
        })
        result = preprocess_dataframes(raw_dataframes, plugin, {})
        assert result["copurchase"]["product_a"][0] == plugin.normalize_product_id("SKU-001")

    def test_test_interactions_normalized(self, raw_dataframes, plugin):
        raw_dataframes["test_interactions"] = pd.DataFrame({
            "user_id": ["alice@test.com"],
            "product_id": ["SKU-001"],
        })
        result = preprocess_dataframes(raw_dataframes, plugin, {})
        assert result["test_interactions"]["user_id"][0] == plugin.normalize_user_id("alice@test.com")
        assert result["test_interactions"]["product_id"][0] == plugin.normalize_product_id("SKU-001")


class TestPreprocessNullHandling:
    """CRITICAL: Null IDs must not be silently coerced to valid strings."""

    def test_null_user_ids_preserved_as_null(self):
        plugin = DefaultPlugin(salt="test")
        dfs = {
            "users": pd.DataFrame({"user_id": ["u1", None]}),
        }
        result = preprocess_dataframes(dfs, plugin, {})
        # None should remain as null, not become hash of "None"
        assert result["users"]["user_id"].isna().sum() == 1

    def test_null_product_ids_preserved_as_null(self):
        plugin = DefaultPlugin(salt="test")
        dfs = {
            "products": pd.DataFrame({
                "product_id": ["p1", None],
                "price": [10.0, 20.0],
                "popularity": [1.0, 2.0],
            }),
        }
        result = preprocess_dataframes(dfs, plugin, {})
        assert result["products"]["product_id"].isna().sum() == 1

    def test_list_like_cell_does_not_crash(self):
        """pd.notna on list-like values must not raise ValueError."""
        plugin = DefaultPlugin(salt="test")
        dfs = {
            "users": pd.DataFrame({"user_id": ["u1", [1, 2]]}),
        }
        # Should not raise ValueError from pd.notna on list-like
        result = preprocess_dataframes(dfs, plugin, {})
        # List-like treated as null (invalid scalar)
        assert result["users"]["user_id"].isna().sum() == 1


class TestModeEvaluate:
    """H6: mode_evaluate orchestration."""

    def test_evaluate_from_train_result(self, all_dataframes_2node, config_2node):
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        results = mode_evaluate(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
        )
        assert "go_no_go" in results
        assert "gnn_pre_rules" in results
        assert results["n_evaluable"] >= 0

    def test_evaluate_without_model_raises(self, all_dataframes_2node, config_2node):
        """Evaluate without train_result or checkpoint must raise."""
        plugin = DefaultPlugin(salt="test")
        with pytest.raises(ValueError, match="train_result or model_checkpoint"):
            mode_evaluate(config_2node, all_dataframes_2node, plugin)


class TestModeScore:
    """H6: mode_score orchestration."""

    def test_score_from_train_result(self, all_dataframes_2node, config_2node):
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        df = mode_score(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
        )
        assert isinstance(df, pd.DataFrame)
        assert "user_id" in df.columns
        assert "rec1_product_id" in df.columns

    def test_score_without_model_raises(self, all_dataframes_2node, config_2node):
        """Score without train_result or checkpoint must raise."""
        plugin = DefaultPlugin(salt="test")
        with pytest.raises(ValueError, match="train_result or model_checkpoint"):
            mode_score(config_2node, all_dataframes_2node, plugin)

    def test_target_user_ids_normalized(self, all_dataframes_2node, config_2node):
        """Runtime target_user_ids should be normalized by plugin before scoring."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        # Pass raw IDs — they should be normalized to match graph IDs
        raw_target = {"user_0", "user_1"}
        df = mode_score(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
            target_user_ids=raw_target,
        )
        # Must have exactly 2 scored users
        assert len(df) == 2
        # Returned user_ids should be the canonical (normalized) forms
        expected_canonical = {plugin.normalize_user_id("user_0"), plugin.normalize_user_id("user_1")}
        assert set(df["user_id"].tolist()) == expected_canonical
        # At least one rec should be model-scored (non-sentinel score)
        sentinel = config_2node["fallback"]["score_sentinel"]
        has_model_scored = (df["rec1_score"] != sentinel).any()
        assert has_model_scored, "All recs are fallback-only — normalization likely failed"

    def test_already_normalized_ids_not_double_hashed(self, all_dataframes_2node, config_2node):
        """Passing already-normalized IDs must NOT double-hash them."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        # Get the canonical IDs that are actually in the graph
        canonical_ids = set(train_result["id_mappings"]["user_to_id"].keys())
        # Pick two canonical IDs and pass them directly
        two_canonical = set(list(canonical_ids)[:2])
        df = mode_score(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
            target_user_ids=two_canonical,
        )
        assert len(df) == 2
        assert set(df["user_id"].tolist()) == two_canonical

    def test_user_purchases_excludes_purchased_products(self, all_dataframes_2node, config_2node):
        """Purchased products must not appear in recommendations."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        # Get canonical product IDs from the graph
        product_to_id = train_result["id_mappings"]["product_to_id"]
        canonical_pids = sorted(product_to_id.keys())
        # Mark first 2 products as purchased for user_0
        purchased = {canonical_pids[0], canonical_pids[1]}
        # Get canonical UID for user_0
        canon_uid = plugin.normalize_user_id("user_0")
        purchases = {canon_uid: purchased}
        df = mode_score(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
            user_purchases=purchases,
            target_user_ids={canon_uid},
        )
        assert len(df) == 1
        # Verify excluded products don't appear in recommendations
        rec_pids = set()
        for i in range(1, config_2node["scoring"]["total_slots"] + 1):
            val = df[f"rec{i}_product_id"].iloc[0]
            if pd.notna(val):
                rec_pids.add(val)
        # Purchased PIDs (after dedup_variant) should be excluded
        for pid in purchased:
            deduped = plugin.dedup_variant(pid)
            assert deduped not in rec_pids, f"Purchased product {deduped} should be excluded"

    def test_user_purchases_bare_string_not_split(self, all_dataframes_2node, config_2node):
        """A bare string PID value must not be iterated as characters."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        # Get a canonical PID from the graph
        canonical_pids = sorted(train_result["id_mappings"]["product_to_id"].keys())
        bare_pid = canonical_pids[0]
        canon_uid = plugin.normalize_user_id("user_0")
        # Pass bare string instead of set — should be auto-wrapped, not split into chars
        purchases = {canon_uid: bare_pid}
        df = mode_score(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
            user_purchases=purchases,
            target_user_ids={canon_uid},
        )
        assert isinstance(df, pd.DataFrame)
        assert len(df) == 1
        # The bare_pid should be excluded as a whole product, not char-split
        rec_pids = set()
        for i in range(1, config_2node["scoring"]["total_slots"] + 1):
            val = df[f"rec{i}_product_id"].iloc[0]
            if pd.notna(val):
                rec_pids.add(val)
        deduped = plugin.dedup_variant(bare_pid)
        assert deduped not in rec_pids, f"Bare-string PID {deduped} should be excluded"

    def test_user_purchases_uid_collision_merges(self, all_dataframes_2node, config_2node):
        """Two raw UIDs normalizing to same canonical should merge purchases."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        # Construct dict with two different raw keys that normalize to the
        # same canonical UID. Since "user_0" and " user_0 " both strip to
        # "user_0" which then hashes identically, their purchases should merge.
        canonical_pids = sorted(train_result["id_mappings"]["product_to_id"].keys())
        pid_a = canonical_pids[0]
        pid_b = canonical_pids[1]
        purchases = dict()
        purchases["user_0"] = {pid_a}
        purchases[" user_0 "] = {pid_b}
        canon_uid = plugin.normalize_user_id("user_0")
        df = mode_score(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
            user_purchases=purchases,
            target_user_ids={canon_uid},
        )
        assert len(df) == 1
        # Both PIDs should be excluded (merged)
        rec_pids = set()
        for i in range(1, config_2node["scoring"]["total_slots"] + 1):
            val = df[f"rec{i}_product_id"].iloc[0]
            if pd.notna(val):
                rec_pids.add(val)
        for pid in [pid_a, pid_b]:
            deduped = plugin.dedup_variant(pid)
            assert deduped not in rec_pids, f"Merged purchase {deduped} should be excluded"

    def test_user_purchases_non_iterable_skipped(self, all_dataframes_2node, config_2node):
        """Non-iterable purchase values (None, int) should be skipped, not crash."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        canon_uid = plugin.normalize_user_id("user_0")
        # None and int are non-iterable — should be skipped gracefully
        purchases = {canon_uid: None}
        df = mode_score(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
            user_purchases=purchases,
        )
        assert isinstance(df, pd.DataFrame)

    def test_target_user_ids_bare_string_not_split(self, all_dataframes_2node, config_2node):
        """A bare string target_user_ids must not be iterated as characters."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        # Pass a bare string — should be auto-wrapped to {"user_0"}, not split into chars
        df = mode_score(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
            target_user_ids="user_0",
        )
        assert isinstance(df, pd.DataFrame)
        assert len(df) == 1  # one user, not one-per-character

    def test_target_user_ids_non_iterable_raises(self, all_dataframes_2node, config_2node):
        """Non-iterable target_user_ids (int, float) must raise TypeError."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        with pytest.raises(TypeError, match="target_user_ids must be an iterable"):
            mode_score(
                config_2node, all_dataframes_2node, plugin,
                train_result=train_result,
                target_user_ids=42,
            )

    def test_user_purchases_unhashable_elements_skipped(self, all_dataframes_2node, config_2node):
        """Nested lists in purchase values should be skipped, not crash."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        canonical_pids = sorted(train_result["id_mappings"]["product_to_id"].keys())
        canon_uid = plugin.normalize_user_id("user_0")
        # Mix of valid PID and unhashable nested list — nested list should be skipped
        purchases = {canon_uid: [canonical_pids[0], ["nested", "list"]]}
        df = mode_score(
            config_2node, all_dataframes_2node, plugin,
            train_result=train_result,
            user_purchases=purchases,
            target_user_ids={canon_uid},
        )
        assert isinstance(df, pd.DataFrame)
        assert len(df) == 1
        # The valid PID should still be excluded
        rec_pids = set()
        for i in range(1, config_2node["scoring"]["total_slots"] + 1):
            val = df[f"rec{i}_product_id"].iloc[0]
            if pd.notna(val):
                rec_pids.add(val)
        deduped = plugin.dedup_variant(canonical_pids[0])
        assert deduped not in rec_pids, f"Valid PID {deduped} should still be excluded"

    def test_user_purchases_non_mapping_raises(self, all_dataframes_2node, config_2node):
        """Non-mapping user_purchases (list, tuple) must raise TypeError."""
        plugin = DefaultPlugin(salt="test")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        with pytest.raises(TypeError, match="user_purchases must be a dict-like mapping"):
            mode_score(
                config_2node, all_dataframes_2node, plugin,
                train_result=train_result,
                user_purchases=[("uid", {"pid"})],
            )


class TestEndToEnd3Node:
    """I5: Integration test for 3-node topology through full pipeline."""

    def test_train_evaluate_score_3node(self, all_dataframes_3node, config_3node):
        """Full train → evaluate → score for user-entity-product topology."""
        plugin = DefaultPlugin(salt="test-3node")

        # Train
        train_result = mode_train(config_3node, all_dataframes_3node, plugin)
        assert "model" in train_result
        assert "data" in train_result
        assert train_result["strategy"].is_entity_topology

        # Evaluate
        eval_result = mode_evaluate(
            config_3node, all_dataframes_3node, plugin,
            train_result=train_result,
        )
        assert "go_no_go" in eval_result
        assert eval_result["go_no_go"]["decision"] in {"GO", "MAYBE", "SKIP", "INVESTIGATE"}

        # Score all users
        df = mode_score(
            config_3node, all_dataframes_3node, plugin,
            train_result=train_result,
        )
        assert isinstance(df, pd.DataFrame)
        assert len(df) > 0
        assert "user_id" in df.columns
        assert "rec1_product_id" in df.columns
        # Every scored user should have at least rec1 filled
        assert df["rec1_product_id"].notna().all()

    def test_score_with_target_users_3node(self, all_dataframes_3node, config_3node):
        """Score a subset of users in 3-node topology."""
        plugin = DefaultPlugin(salt="test-3node")
        train_result = mode_train(config_3node, all_dataframes_3node, plugin)
        # Target first 3 raw user IDs
        df = mode_score(
            config_3node, all_dataframes_3node, plugin,
            train_result=train_result,
            target_user_ids={"user_0", "user_1", "user_2"},
        )
        assert len(df) == 3

    def test_score_with_purchase_exclusion_3node(self, all_dataframes_3node, config_3node):
        """Purchase exclusion works with 3-node entity-grouped scoring."""
        plugin = DefaultPlugin(salt="test-3node")
        train_result = mode_train(config_3node, all_dataframes_3node, plugin)
        product_to_id = train_result["id_mappings"]["product_to_id"]
        canonical_pids = sorted(product_to_id.keys())
        canon_uid = plugin.normalize_user_id("user_0")
        purchased = {canonical_pids[0], canonical_pids[1]}
        df = mode_score(
            config_3node, all_dataframes_3node, plugin,
            train_result=train_result,
            user_purchases={canon_uid: purchased},
            target_user_ids={canon_uid},
        )
        assert len(df) == 1
        rec_pids = set()
        for i in range(1, config_3node["scoring"]["total_slots"] + 1):
            val = df[f"rec{i}_product_id"].iloc[0]
            if pd.notna(val):
                rec_pids.add(val)
        for pid in purchased:
            deduped = plugin.dedup_variant(pid)
            assert deduped not in rec_pids


class TestCheckpointRoundTrip:
    """Codex M2: Positive-path test for _load_model_from_checkpoint."""

    def test_checkpoint_round_trip_2node(self, all_dataframes_2node, config_2node, tmp_path):
        """Train → save → load → verify identical embeddings (2-node)."""
        plugin = DefaultPlugin(salt="test-ckpt")
        train_result = mode_train(config_2node, all_dataframes_2node, plugin)
        model = train_result["model"]
        data = train_result["data"]

        # Save checkpoint (matches format expected by _load_model_from_checkpoint)
        ckpt_path = str(tmp_path / "model.pt")
        torch.save({"model_state_dict": model.state_dict()}, ckpt_path)

        # Load via the helper
        loaded_model = _load_model_from_checkpoint(
            ckpt_path,
            data,
            train_result["id_mappings"],
            train_result["metadata"],
            train_result["strategy"],
            config_2node,
        )

        # Both models should produce identical embeddings
        model.eval()
        loaded_model.eval()
        with torch.no_grad():
            orig_user, orig_prod = model(data)
            loaded_user, loaded_prod = loaded_model(data)

        assert torch.allclose(orig_user, loaded_user, atol=1e-6), "User embedding mismatch"
        assert torch.allclose(orig_prod, loaded_prod, atol=1e-6), "Product embedding mismatch"

    def test_checkpoint_round_trip_3node(self, all_dataframes_3node, config_3node, tmp_path):
        """Train → save → load → verify identical embeddings (3-node)."""
        plugin = DefaultPlugin(salt="test-ckpt")
        train_result = mode_train(config_3node, all_dataframes_3node, plugin)
        model = train_result["model"]
        data = train_result["data"]

        ckpt_path = str(tmp_path / "model.pt")
        torch.save({"model_state_dict": model.state_dict()}, ckpt_path)

        loaded_model = _load_model_from_checkpoint(
            ckpt_path,
            data,
            train_result["id_mappings"],
            train_result["metadata"],
            train_result["strategy"],
            config_3node,
        )

        model.eval()
        loaded_model.eval()
        with torch.no_grad():
            orig_user, orig_prod = model(data)
            loaded_user, loaded_prod = loaded_model(data)

        assert torch.allclose(orig_user, loaded_user, atol=1e-6), "User embedding mismatch"
        assert torch.allclose(orig_prod, loaded_prod, atol=1e-6), "Product embedding mismatch"
