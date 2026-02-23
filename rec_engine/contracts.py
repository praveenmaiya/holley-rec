"""Data contracts for the recommendation engine.

Defines canonical DataFrame schemas that all client data must conform to.
Validated at engine entry to fail fast with clear error messages.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from typing import Any

import numpy as np
import pandas as pd

from rec_engine import CONTRACT_VERSION

logger = logging.getLogger(__name__)

# Supported contract version range (major.minor)
_SUPPORTED_MAJOR = 1


@dataclass(frozen=True)
class ColumnSpec:
    """Specification for a required DataFrame column."""

    name: str
    dtype: str  # "str", "float", "int", "bool", "datetime"
    nullable: bool = False


@dataclass(frozen=True)
class UserContract:
    """Required columns for user nodes."""

    columns: list[ColumnSpec] = field(default_factory=lambda: [
        ColumnSpec("user_id", "str"),
    ])


@dataclass(frozen=True)
class ProductContract:
    """Required columns for product nodes."""

    columns: list[ColumnSpec] = field(default_factory=lambda: [
        ColumnSpec("product_id", "str"),
        ColumnSpec("price", "float"),
        ColumnSpec("popularity", "float"),
    ])


@dataclass(frozen=True)
class EntityContract:
    """Required columns for secondary entity nodes (optional, 3-node topology only)."""

    columns: list[ColumnSpec] = field(default_factory=lambda: [
        ColumnSpec("entity_id", "str"),
    ])


@dataclass(frozen=True)
class InteractionContract:
    """Required columns for user-product interaction edges."""

    columns: list[ColumnSpec] = field(default_factory=lambda: [
        ColumnSpec("user_id", "str"),
        ColumnSpec("product_id", "str"),
        ColumnSpec("interaction_type", "str"),
        ColumnSpec("weight", "float"),
    ])


@dataclass(frozen=True)
class FitmentContract:
    """Required columns for product-entity fitment edges (3-node topology only)."""

    columns: list[ColumnSpec] = field(default_factory=lambda: [
        ColumnSpec("product_id", "str"),
        ColumnSpec("entity_id", "str"),
    ])


@dataclass(frozen=True)
class OwnershipContract:
    """Required columns for user-entity ownership edges (3-node topology only)."""

    columns: list[ColumnSpec] = field(default_factory=lambda: [
        ColumnSpec("user_id", "str"),
        ColumnSpec("entity_id", "str"),
    ])


class ContractValidationError(Exception):
    """Raised when input data violates a contract."""


def check_contract_version(config_version: str) -> None:
    """Check that client config targets a supported contract version.

    Raises ContractValidationError if the major version is unsupported
    or the format is not 'major.minor'.
    """
    if not isinstance(config_version, str):
        raise ContractValidationError(
            f"contract_version must be a string, got {type(config_version).__name__}: "
            f"{config_version!r}"
        )
    if not re.fullmatch(r"\d+\.\d+", config_version):
        raise ContractValidationError(
            f"Invalid contract_version format: {config_version!r} "
            f"(expected 'major.minor', e.g. '1.0')"
        )
    major = int(config_version.split(".")[0])

    if major != _SUPPORTED_MAJOR:
        raise ContractValidationError(
            f"Unsupported contract version {config_version}. "
            f"Engine supports major version {_SUPPORTED_MAJOR} "
            f"(current: {CONTRACT_VERSION})"
        )


def _check_columns(
    df: pd.DataFrame,
    contract_columns: list[ColumnSpec],
    table_name: str,
) -> list[str]:
    """Check a DataFrame against a contract. Returns list of error messages."""
    errors: list[str] = []

    for spec in contract_columns:
        if spec.name not in df.columns:
            errors.append(f"{table_name}: missing required column '{spec.name}'")
            continue

        col = df[spec.name]

        # Null check on non-nullable ID columns
        if not spec.nullable and col.isna().any():
            n_nulls = col.isna().sum()
            errors.append(
                f"{table_name}.{spec.name}: {n_nulls} null values "
                f"(column is non-nullable)"
            )

        # Type-specific checks
        if spec.dtype == "float":
            if not pd.api.types.is_numeric_dtype(col):
                errors.append(
                    f"{table_name}.{spec.name}: expected numeric type, "
                    f"got {col.dtype}"
                )
        elif spec.dtype == "str":
            if pd.api.types.is_string_dtype(col):
                pass  # StringDtype — all values are strings
            elif pd.api.types.is_object_dtype(col):
                # object dtype can contain mixed types; verify non-null values are strings
                non_null = col.dropna()
                if len(non_null) > 0:
                    non_str = non_null[~non_null.apply(lambda v: isinstance(v, str))]
                    if len(non_str) > 0:
                        errors.append(
                            f"{table_name}.{spec.name}: {len(non_str)} non-string values "
                            f"in object column (e.g. {non_str.iloc[0]!r})"
                        )
            else:
                errors.append(
                    f"{table_name}.{spec.name}: expected string type, "
                    f"got {col.dtype}"
                )

    return errors


def _check_non_negative_prices(
    df: pd.DataFrame,
    price_col: str,
    table_name: str,
) -> list[str]:
    """Check that prices are non-negative."""
    errors: list[str] = []
    if price_col in df.columns:
        negative = (df[price_col].dropna() < 0).sum()
        if negative > 0:
            errors.append(
                f"{table_name}.{price_col}: {negative} negative values"
            )
    return errors


def _check_uniqueness(
    df: pd.DataFrame,
    id_col: str,
    table_name: str,
) -> list[str]:
    """Check ID column uniqueness."""
    errors: list[str] = []
    if id_col in df.columns:
        n_dupes = df[id_col].duplicated().sum()
        if n_dupes > 0:
            errors.append(
                f"{table_name}.{id_col}: {n_dupes} duplicate values"
            )
    return errors


def _check_referential_integrity(
    edge_df: pd.DataFrame,
    edge_col: str,
    node_df: pd.DataFrame,
    node_col: str,
    edge_table: str,
    node_table: str,
) -> list[str]:
    """Check that edge IDs reference existing node IDs."""
    errors: list[str] = []
    if edge_col in edge_df.columns and node_col in node_df.columns:
        node_ids = set(node_df[node_col].dropna())
        edge_ids = set(edge_df[edge_col].dropna())
        orphans = edge_ids - node_ids
        if orphans:
            errors.append(
                f"{edge_table}.{edge_col}: {len(orphans)} IDs not found in "
                f"{node_table}.{node_col}"
            )
    return errors


def validate(
    dataframes: dict[str, pd.DataFrame],
    config: dict[str, Any],
) -> None:
    """Validate all input DataFrames against contracts.

    Args:
        dataframes: Dict with keys: 'users', 'products', 'interactions'.
            Optional: 'entities', 'fitment', 'ownership'.
        config: Engine configuration dict (must include 'contract_version' and 'topology').

    Raises:
        ContractValidationError: if any validation fails, with all errors listed.
    """
    # Contract version check
    config_version = config.get("contract_version", CONTRACT_VERSION)
    check_contract_version(config_version)

    topology = config.get("topology", "user-product")
    is_3node = topology == "user-entity-product"

    errors: list[str] = []

    # --- Required tables ---
    required_tables = ["users", "products", "interactions"]
    if is_3node:
        required_tables.extend(["entities", "fitment", "ownership"])

    for table in required_tables:
        if table not in dataframes:
            errors.append(f"Missing required table: '{table}'")

    if errors:
        raise ContractValidationError(
            f"Contract validation failed ({len(errors)} errors):\n"
            + "\n".join(f"  - {e}" for e in errors)
        )

    # --- Column validation ---
    users_df = dataframes["users"]
    products_df = dataframes["products"]
    interactions_df = dataframes["interactions"]

    errors.extend(_check_columns(users_df, UserContract().columns, "users"))
    errors.extend(_check_columns(products_df, ProductContract().columns, "products"))
    errors.extend(_check_columns(interactions_df, InteractionContract().columns, "interactions"))

    if is_3node:
        entities_df = dataframes["entities"]
        fitment_df = dataframes["fitment"]
        ownership_df = dataframes["ownership"]
        errors.extend(_check_columns(entities_df, EntityContract().columns, "entities"))
        errors.extend(_check_columns(fitment_df, FitmentContract().columns, "fitment"))
        errors.extend(_check_columns(ownership_df, OwnershipContract().columns, "ownership"))

    # --- Value checks ---
    errors.extend(_check_non_negative_prices(products_df, "price", "products"))
    errors.extend(_check_uniqueness(users_df, "user_id", "users"))
    errors.extend(_check_uniqueness(products_df, "product_id", "products"))
    if is_3node and "entities" in dataframes:
        errors.extend(_check_uniqueness(dataframes["entities"], "entity_id", "entities"))

    # --- Interaction weight validation ---
    if "weight" in interactions_df.columns and pd.api.types.is_numeric_dtype(interactions_df["weight"]):
        weights = interactions_df["weight"].dropna()
        n_neg = (weights < 0).sum()
        if n_neg > 0:
            errors.append(f"interactions.weight: {n_neg} negative values")
        n_nan = interactions_df["weight"].isna().sum()
        if n_nan > 0:
            errors.append(f"interactions.weight: {n_nan} NaN values")
        if hasattr(weights, 'values'):
            vals = weights.values
            n_inf = int(np.isinf(vals).sum()) if hasattr(np, 'isinf') else 0
            if n_inf > 0:
                errors.append(f"interactions.weight: {n_inf} Inf values")

    # --- Referential integrity ---
    errors.extend(_check_referential_integrity(
        interactions_df, "user_id", users_df, "user_id",
        "interactions", "users",
    ))
    errors.extend(_check_referential_integrity(
        interactions_df, "product_id", products_df, "product_id",
        "interactions", "products",
    ))

    if is_3node:
        fitment_df = dataframes["fitment"]
        ownership_df = dataframes["ownership"]
        entities_df = dataframes["entities"]

        errors.extend(_check_referential_integrity(
            fitment_df, "product_id", products_df, "product_id",
            "fitment", "products",
        ))
        errors.extend(_check_referential_integrity(
            fitment_df, "entity_id", entities_df, "entity_id",
            "fitment", "entities",
        ))
        errors.extend(_check_referential_integrity(
            ownership_df, "user_id", users_df, "user_id",
            "ownership", "users",
        ))
        errors.extend(_check_referential_integrity(
            ownership_df, "entity_id", entities_df, "entity_id",
            "ownership", "entities",
        ))

    if errors:
        raise ContractValidationError(
            f"Contract validation failed ({len(errors)} errors):\n"
            + "\n".join(f"  - {e}" for e in errors)
        )

    logger.info(
        "Contract validation passed: %d users, %d products, %d interactions%s",
        len(users_df),
        len(products_df),
        len(interactions_df),
        f", {len(dataframes.get('entities', []))} entities" if is_3node else "",
    )
