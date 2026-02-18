"""Unit tests for checkpoint metadata restoration helpers."""

import pytest

from src.gnn.checkpoint_utils import restore_id_mappings_from_checkpoint


class _DummyLoader:
    def __init__(self):
        self.user_to_id = {"old_user@test.com": 0}
        self.product_to_id = {"OLD001": 0}
        self.vehicle_to_id = {"FORD|MUSTANG": 0}


def test_restore_id_mappings_from_valid_checkpoint():
    loader = _DummyLoader()
    mappings = {
        "user_to_id": {"new_user@test.com": 0},
        "product_to_id": {"NEW001": 0},
        "vehicle_to_id": {"CHEVY|CAMARO": 0},
    }

    restored = restore_id_mappings_from_checkpoint(loader, {"id_mappings": mappings})

    assert restored is True
    assert loader.user_to_id == mappings["user_to_id"]
    assert loader.product_to_id == mappings["product_to_id"]
    assert loader.vehicle_to_id == mappings["vehicle_to_id"]


def test_restore_id_mappings_returns_false_when_metadata_missing():
    loader = _DummyLoader()
    original = (
        loader.user_to_id.copy(),
        loader.product_to_id.copy(),
        loader.vehicle_to_id.copy(),
    )

    restored = restore_id_mappings_from_checkpoint(loader, {"model_state_dict": {}})

    assert restored is False
    assert loader.user_to_id == original[0]
    assert loader.product_to_id == original[1]
    assert loader.vehicle_to_id == original[2]


def test_restore_id_mappings_raises_for_invalid_schema():
    loader = _DummyLoader()
    malformed = {
        "id_mappings": {
            "user_to_id": {"new_user@test.com": 0},
            "product_to_id": ["not", "a", "dict"],
            # vehicle_to_id intentionally missing
        }
    }

    with pytest.raises(ValueError, match="missing required keys"):
        restore_id_mappings_from_checkpoint(loader, malformed)
    assert loader.user_to_id == {"old_user@test.com": 0}


def test_restore_id_mappings_raises_when_root_not_dict():
    loader = _DummyLoader()

    with pytest.raises(ValueError, match="must be a dict"):
        restore_id_mappings_from_checkpoint(loader, {"id_mappings": ["bad"]})
