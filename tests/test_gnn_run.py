"""Integration-style tests for run.py mode wiring and checkpoint mapping restore."""

from types import SimpleNamespace

import pandas as pd
import pytest


class _DummyLoader:
    def __init__(self):
        self.user_to_id = {"orig_user@test.com": 0}
        self.product_to_id = {"P001": 0}
        self.vehicle_to_id = {"FORD|MUSTANG": 0}

    def get_id_mappings(self):
        return {
            "user_to_id": self.user_to_id,
            "product_to_id": self.product_to_id,
            "vehicle_to_id": self.vehicle_to_id,
        }

    def load_test_set(self):
        return pd.DataFrame({"email_lower": ["orig_user@test.com"], "base_sku": ["P001"]})

    def load_sql_baseline(self):
        return pd.DataFrame({"email_lower": ["orig_user@test.com"], "sku": ["P001"], "rank": [1]})


def _graph_triplet():
    data = {
        "user": SimpleNamespace(num_nodes=1),
        "product": SimpleNamespace(num_nodes=1),
        "vehicle": SimpleNamespace(num_nodes=1),
    }
    split_masks = {"test_mask": [True]}
    metadata = {"n_part_types": 1}
    return data, split_masks, metadata


def test_load_torch_checkpoint_roundtrip(tmp_path):
    torch = pytest.importorskip("torch")
    from src.gnn import run as run_module

    checkpoint = {
        "model_state_dict": {"w": torch.tensor([1.0, 2.0])},
        "id_mappings": {
            "user_to_id": {"u@test.com": 0},
            "product_to_id": {"P001": 0},
            "vehicle_to_id": {"FORD|MUSTANG": 0},
        },
    }
    path = tmp_path / "ckpt.pt"
    torch.save(checkpoint, path)

    loaded = run_module._load_torch_checkpoint(str(path))

    assert torch.equal(loaded["model_state_dict"]["w"], checkpoint["model_state_dict"]["w"])
    assert loaded["id_mappings"] == checkpoint["id_mappings"]


def test_mode_evaluate_uses_checkpoint_mappings_when_present(mocker):
    from src.gnn import run as run_module

    loader = _DummyLoader()
    nodes = {"users": pd.DataFrame({"email_lower": ["orig_user@test.com"], "engagement_tier": ["cold"]})}
    checkpoint_mappings = {
        "user_to_id": {"ckpt_user@test.com": 0},
        "product_to_id": {"P999": 0},
        "vehicle_to_id": {"CHEVY|CAMARO": 0},
    }

    mocker.patch.object(run_module, "init_wandb")
    mocker.patch.object(run_module, "finish_run")
    mocker.patch.object(run_module, "download_model")
    mocker.patch.object(run_module, "load_data", return_value=(loader, nodes, {}))
    mocker.patch.object(run_module, "build_graph", return_value=_graph_triplet())
    mocker.patch.object(run_module, "build_engagement_tiers", return_value={0: "cold"})
    mocker.patch.object(
        run_module,
        "_load_torch_checkpoint",
        return_value={"model_state_dict": {"w": 1}, "id_mappings": checkpoint_mappings},
    )
    model = mocker.Mock(parameters=mocker.Mock(return_value=[]))
    mocker.patch.object(run_module, "_build_model", return_value=model)

    evaluator_cls = mocker.Mock()
    mocker.patch.object(run_module, "_get_evaluator_cls", return_value=evaluator_cls)
    evaluator = evaluator_cls.return_value
    evaluator.generate_report.return_value = {
        "go_no_go": {},
        "gnn_pre_rules": {},
        "gnn_post_rules": {},
        "sql_baseline": {},
    }

    run_module.mode_evaluate({"output": {"model_gcs": "gs://x/"}, "eval": {}})

    assert loader.user_to_id == checkpoint_mappings["user_to_id"]
    assert loader.product_to_id == checkpoint_mappings["product_to_id"]
    assert loader.vehicle_to_id == checkpoint_mappings["vehicle_to_id"]
    assert evaluator_cls.call_args.kwargs["id_mappings"] == checkpoint_mappings
    model.load_state_dict.assert_called_once_with({"w": 1})


def test_mode_evaluate_keeps_loader_mappings_without_checkpoint_mappings(mocker):
    from src.gnn import run as run_module

    loader = _DummyLoader()
    original = loader.get_id_mappings().copy()
    nodes = {"users": pd.DataFrame({"email_lower": ["orig_user@test.com"], "engagement_tier": ["cold"]})}

    mocker.patch.object(run_module, "init_wandb")
    mocker.patch.object(run_module, "finish_run")
    mocker.patch.object(run_module, "download_model")
    mocker.patch.object(run_module, "load_data", return_value=(loader, nodes, {}))
    mocker.patch.object(run_module, "build_graph", return_value=_graph_triplet())
    mocker.patch.object(run_module, "build_engagement_tiers", return_value={0: "cold"})
    mocker.patch.object(run_module, "_load_torch_checkpoint", return_value={"model_state_dict": {}})
    mocker.patch.object(run_module, "_build_model", return_value=mocker.Mock(parameters=mocker.Mock(return_value=[])))

    evaluator_cls = mocker.Mock()
    mocker.patch.object(run_module, "_get_evaluator_cls", return_value=evaluator_cls)
    evaluator_cls.return_value.generate_report.return_value = {
        "go_no_go": {},
        "gnn_pre_rules": {},
        "gnn_post_rules": {},
        "sql_baseline": {},
    }

    run_module.mode_evaluate({"output": {"model_gcs": "gs://x/"}, "eval": {}})

    assert loader.get_id_mappings() == original
    assert evaluator_cls.call_args.kwargs["id_mappings"] == original


def test_mode_evaluate_raises_on_invalid_checkpoint_mappings(mocker):
    from src.gnn import run as run_module

    loader = _DummyLoader()
    nodes = {"users": pd.DataFrame({"email_lower": ["orig_user@test.com"], "engagement_tier": ["cold"]})}
    invalid_mappings = {
        "user_to_id": {"ckpt_user@test.com": 0},
        "product_to_id": {"P999": 0},
        # vehicle_to_id missing on purpose
    }

    mocker.patch.object(run_module, "init_wandb")
    mocker.patch.object(run_module, "finish_run")
    mocker.patch.object(run_module, "download_model")
    mocker.patch.object(run_module, "load_data", return_value=(loader, nodes, {}))
    mocker.patch.object(
        run_module,
        "_load_torch_checkpoint",
        return_value={"model_state_dict": {"w": 1}, "id_mappings": invalid_mappings},
    )

    with pytest.raises(ValueError, match="missing required keys"):
        run_module.mode_evaluate({"output": {"model_gcs": "gs://x/"}, "eval": {}})


def test_mode_score_uses_checkpoint_mappings_when_present(mocker):
    from src.gnn import run as run_module

    loader = _DummyLoader()
    nodes = {"users": pd.DataFrame({"email_lower": ["orig_user@test.com"], "has_email_consent": [True]})}
    checkpoint_mappings = {
        "user_to_id": {"ckpt_user@test.com": 0},
        "product_to_id": {"P999": 0},
        "vehicle_to_id": {"CHEVY|CAMARO": 0},
    }

    mocker.patch.object(run_module, "init_wandb")
    mocker.patch.object(run_module, "finish_run")
    mocker.patch.object(run_module, "download_model")
    mocker.patch.object(run_module, "log_metrics")
    mocker.patch.object(run_module, "load_data", return_value=(loader, nodes, {}))
    mocker.patch.object(run_module, "build_graph", return_value=_graph_triplet())
    mocker.patch.object(
        run_module,
        "_load_torch_checkpoint",
        return_value={"model_state_dict": {"w": 1}, "id_mappings": checkpoint_mappings},
    )
    mocker.patch.object(run_module, "_build_model", return_value=mocker.Mock(parameters=mocker.Mock(return_value=[])))

    scorer_cls = mocker.Mock()
    mocker.patch.object(run_module, "_get_scorer_cls", return_value=scorer_cls)
    scorer = scorer_cls.return_value
    out_df = pd.DataFrame({"email_lower": ["ckpt_user@test.com"]})
    scorer.score_all_users.return_value = out_df

    result = run_module.mode_score({"output": {"model_gcs": "gs://x/", "refresh_exports": False}})

    assert loader.user_to_id == checkpoint_mappings["user_to_id"]
    assert scorer_cls.call_args.kwargs["id_mappings"] == checkpoint_mappings
    scorer.write_shadow_table.assert_called_once_with(out_df)
    assert result.equals(out_df)


def test_mode_score_raises_on_invalid_checkpoint_mappings(mocker):
    from src.gnn import run as run_module

    loader = _DummyLoader()
    nodes = {"users": pd.DataFrame({"email_lower": ["orig_user@test.com"], "has_email_consent": [True]})}
    invalid_mappings = {
        "user_to_id": {"ckpt_user@test.com": 0},
        # product_to_id intentionally missing
        "vehicle_to_id": {"CHEVY|CAMARO": 0},
    }

    mocker.patch.object(run_module, "init_wandb")
    mocker.patch.object(run_module, "finish_run")
    mocker.patch.object(run_module, "download_model")
    mocker.patch.object(run_module, "load_data", return_value=(loader, nodes, {}))
    mocker.patch.object(
        run_module,
        "_load_torch_checkpoint",
        return_value={"model_state_dict": {"w": 1}, "id_mappings": invalid_mappings},
    )

    with pytest.raises(ValueError, match="missing required keys"):
        run_module.mode_score({"output": {"model_gcs": "gs://x/", "refresh_exports": False}})


def test_mode_train_saves_checkpoint_with_loader_mappings(mocker):
    from src.gnn import run as run_module

    loader = _DummyLoader()
    nodes = {"users": pd.DataFrame({"email_lower": ["orig_user@test.com"], "engagement_tier": ["cold"]})}
    graph_data, split_masks, metadata = _graph_triplet()

    mocker.patch.object(run_module, "init_wandb")
    mocker.patch.object(run_module, "finish_run")
    mocker.patch.object(run_module, "load_data", return_value=(loader, nodes, {}))
    mocker.patch.object(run_module, "build_graph", return_value=(graph_data, split_masks, metadata))
    mocker.patch.object(run_module, "upload_model")
    mocker.patch.object(run_module, "log_artifact")
    mocker.patch.object(run_module, "log_metrics")
    mocker.patch.object(run_module, "build_engagement_tiers", return_value={0: "cold"})

    param = mocker.Mock()
    param.numel.return_value = 1
    model = mocker.Mock()
    model.parameters.return_value = [param]
    mocker.patch.object(run_module, "_build_model", return_value=model)

    trainer = mocker.Mock()
    trainer.train.return_value = {"best_epoch": 0, "best_val_hit_rate_at_4": 0.1, "total_epochs": 1}
    trainer_cls = mocker.Mock(return_value=trainer)
    mocker.patch.object(run_module, "_get_trainer_cls", return_value=trainer_cls)

    evaluator = mocker.Mock()
    evaluator.generate_report.return_value = {
        "go_no_go": {"decision": "MAYBE"},
        "gnn_pre_rules": {},
        "gnn_post_rules": {},
        "sql_baseline": {},
    }
    evaluator_cls = mocker.Mock(return_value=evaluator)
    mocker.patch.object(run_module, "_get_evaluator_cls", return_value=evaluator_cls)

    report = run_module.mode_train({"output": {"model_gcs": "gs://x/"}})

    trainer.save_checkpoint.assert_called_once()
    checkpoint_call = trainer.save_checkpoint.call_args
    assert checkpoint_call.kwargs["id_mappings"] == loader.get_id_mappings()
    run_module.upload_model.assert_called_once()
    run_module.log_artifact.assert_called_once()
    assert report["go_no_go"]["decision"] == "MAYBE"


def test_mode_train_propagates_training_error(mocker):
    from src.gnn import run as run_module

    loader = _DummyLoader()
    nodes = {"users": pd.DataFrame({"email_lower": ["orig_user@test.com"], "engagement_tier": ["cold"]})}
    graph_data, split_masks, metadata = _graph_triplet()

    mocker.patch.object(run_module, "init_wandb")
    mocker.patch.object(run_module, "finish_run")
    mocker.patch.object(run_module, "load_data", return_value=(loader, nodes, {}))
    mocker.patch.object(run_module, "build_graph", return_value=(graph_data, split_masks, metadata))
    mocker.patch.object(run_module, "upload_model")
    mocker.patch.object(run_module, "log_artifact")
    mocker.patch.object(run_module, "log_metrics")

    model = mocker.Mock()
    model.parameters.return_value = []
    mocker.patch.object(run_module, "_build_model", return_value=model)

    trainer = mocker.Mock()
    trainer.train.side_effect = RuntimeError("train boom")
    trainer_cls = mocker.Mock(return_value=trainer)
    mocker.patch.object(run_module, "_get_trainer_cls", return_value=trainer_cls)

    with pytest.raises(RuntimeError, match="train boom"):
        run_module.mode_train({"output": {"model_gcs": "gs://x/"}})

    run_module.upload_model.assert_not_called()
    run_module.log_artifact.assert_not_called()


@pytest.mark.parametrize("mode_name", ["train", "evaluate", "score"])
def test_main_dispatches_to_selected_mode(mocker, mode_name):
    from src.gnn import run as run_module

    mocker.patch.object(
        run_module.argparse.ArgumentParser,
        "parse_args",
        return_value=SimpleNamespace(config="configs/gnn.yaml", mode=mode_name),
    )
    mocker.patch.object(run_module, "load_config", return_value={"dummy": True})

    mode_train = mocker.patch.object(run_module, "mode_train")
    mode_evaluate = mocker.patch.object(run_module, "mode_evaluate")
    mode_score = mocker.patch.object(run_module, "mode_score")

    run_module.main()

    expected_calls = {
        "train": (mode_train, mode_evaluate, mode_score),
        "evaluate": (mode_evaluate, mode_train, mode_score),
        "score": (mode_score, mode_train, mode_evaluate),
    }
    selected, first_other, second_other = expected_calls[mode_name]
    selected.assert_called_once_with({"dummy": True})
    first_other.assert_not_called()
    second_other.assert_not_called()
