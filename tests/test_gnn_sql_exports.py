"""Regression tests for GNN SQL export temporal boundaries."""

from pathlib import Path


def test_temporal_boundaries_prevent_train_test_overlap():
    sql_dir = Path(__file__).resolve().parents[1] / "sql" / "gnn"
    edges_sql = (sql_dir / "export_edges.sql").read_text()
    test_sql = (sql_dir / "export_test_set.sql").read_text()
    nodes_sql = (sql_dir / "export_nodes.sql").read_text()

    # Training interactions and co-purchase must stop at train_cutoff (T-30).
    assert "DATE(a.event_timestamp) BETWEEN intent_start AND train_cutoff" in edges_sql
    assert (
        "SAFE.PARSE_DATE('%Y-%m-%d', SUBSTR(ORDER_DATE, 1, 10)) BETWEEN intent_start AND train_cutoff"
        in edges_sql
    )

    # Test window starts at cutoff + 1 day to avoid overlap.
    assert (
        "DECLARE test_start DATE DEFAULT DATE_ADD(DATE_SUB(CURRENT_DATE(), INTERVAL test_window_days DAY), INTERVAL 1 DAY);"
        in test_sql
    )
    assert "DATE(a.event_timestamp) BETWEEN test_start AND test_end" in test_sql

    # Product popularity features in node export should also be capped at train_cutoff.
    assert "DECLARE train_cutoff DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL test_window_days DAY);" in nodes_sql
    assert "BETWEEN intent_start AND train_cutoff" in nodes_sql
