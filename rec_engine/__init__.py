"""Auxia Recommendation Engine — generic GNN-based recommendation framework."""

__version__ = "1.0.0"
CONTRACT_VERSION = "1.0"


def is_valid_scalar(val) -> bool:
    """Scalar-safe null check: handles None, NaN, pd.NA without list-like issues.

    Unlike ``pd.notna()``, this never raises ``ValueError`` on list-like inputs
    (e.g. ``pd.notna([1, 2])`` returns an array whose truth value is ambiguous)
    and explicitly rejects common container types (list, tuple, dict, set).

    Returns ``True`` only when *val* is a non-null scalar value.
    """
    if val is None:
        return False
    if isinstance(val, (list, tuple, dict, set)):
        return False
    try:
        import pandas as _pd  # noqa: F811 — lazy import avoids circular deps
        return bool(_pd.notna(val))
    except (ValueError, TypeError):
        return False
