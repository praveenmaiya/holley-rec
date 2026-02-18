"""Helpers for restoring checkpoint metadata in eval/score flows."""

from __future__ import annotations

from typing import Any


def restore_id_mappings_from_checkpoint(loader: Any, checkpoint: dict[str, Any]) -> bool:
    """Restore loader ID mappings from checkpoint metadata.

    Returns:
        True if mappings were restored.
        False if checkpoint metadata is absent.

    Raises:
        ValueError: if checkpoint includes ``id_mappings`` but schema is invalid.
    """
    if "id_mappings" not in checkpoint:
        return False

    mappings = checkpoint["id_mappings"]
    if not isinstance(mappings, dict):
        raise ValueError(
            "Checkpoint id_mappings must be a dict, "
            f"got {type(mappings).__name__}"
        )

    required = {"user_to_id", "product_to_id", "vehicle_to_id"}
    missing = sorted(required - set(mappings))
    if missing:
        raise ValueError(
            "Checkpoint id_mappings missing required keys: "
            + ", ".join(missing)
        )

    user_to_id = mappings["user_to_id"]
    product_to_id = mappings["product_to_id"]
    vehicle_to_id = mappings["vehicle_to_id"]
    if not isinstance(user_to_id, dict):
        raise ValueError("Checkpoint id_mappings.user_to_id must be a dict")
    if not isinstance(product_to_id, dict):
        raise ValueError("Checkpoint id_mappings.product_to_id must be a dict")
    if not isinstance(vehicle_to_id, dict):
        raise ValueError("Checkpoint id_mappings.vehicle_to_id must be a dict")

    loader.user_to_id = user_to_id
    loader.product_to_id = product_to_id
    loader.vehicle_to_id = vehicle_to_id
    return True
