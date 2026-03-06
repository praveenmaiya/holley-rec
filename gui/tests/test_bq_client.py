from unittest.mock import MagicMock, patch

from services.bq_client import get_bq_client, run_query


def test_get_bq_client_returns_client():
    with patch("services.bq_client.bigquery.Client") as mock_client:
        client = get_bq_client()
        assert client is not None
        mock_client.assert_called_once()


def test_run_query_returns_dataframe():
    mock_client = MagicMock()
    mock_df = MagicMock()
    mock_client.query.return_value.to_dataframe.return_value = mock_df

    with patch("services.bq_client.get_bq_client", return_value=mock_client):
        result = run_query("SELECT 1")
        assert result is mock_df


def test_run_query_substitutes_params():
    mock_client = MagicMock()
    mock_client.query.return_value.to_dataframe.return_value = MagicMock()

    with patch("services.bq_client.get_bq_client", return_value=mock_client):
        run_query("SELECT * FROM {table}", table="my_table")
        call_args = mock_client.query.call_args[0][0]
        assert "my_table" in call_args
