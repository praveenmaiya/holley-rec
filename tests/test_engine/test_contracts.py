"""Tests for rec_engine.contracts — data contract validation."""

import pandas as pd
import pytest

from rec_engine.contracts import (
    ContractValidationError,
    check_contract_version,
    validate,
)


class TestCheckContractVersion:
    def test_supported_version(self):
        check_contract_version("1.0")
        check_contract_version("1.1")

    def test_unsupported_major_version(self):
        with pytest.raises(ContractValidationError, match="Unsupported"):
            check_contract_version("2.0")

    def test_invalid_format(self):
        with pytest.raises(ContractValidationError, match="Invalid"):
            check_contract_version("abc")

    def test_empty_string(self):
        with pytest.raises(ContractValidationError):
            check_contract_version("")


class TestValidate:
    @pytest.fixture
    def valid_2node_data(self):
        users = pd.DataFrame({"user_id": ["u1", "u2"], "engagement_tier": ["cold", "warm"]})
        products = pd.DataFrame({"product_id": ["p1", "p2"], "price": [10.0, 20.0], "popularity": [1.0, 2.0]})
        interactions = pd.DataFrame({
            "user_id": ["u1", "u2"],
            "product_id": ["p1", "p2"],
            "interaction_type": ["view", "cart"],
            "weight": [1.0, 3.0],
        })
        return {"users": users, "products": products, "interactions": interactions}

    @pytest.fixture
    def valid_3node_data(self, valid_2node_data):
        data = dict(valid_2node_data)
        data["entities"] = pd.DataFrame({"entity_id": ["e1", "e2"]})
        data["fitment"] = pd.DataFrame({"product_id": ["p1", "p2"], "entity_id": ["e1", "e2"]})
        data["ownership"] = pd.DataFrame({"user_id": ["u1", "u2"], "entity_id": ["e1", "e2"]})
        return data

    def test_valid_2node(self, valid_2node_data):
        config = {"contract_version": "1.0", "topology": "user-product"}
        validate(valid_2node_data, config)

    def test_valid_3node(self, valid_3node_data):
        config = {"contract_version": "1.0", "topology": "user-entity-product"}
        validate(valid_3node_data, config)

    def test_missing_users_table(self, valid_2node_data):
        del valid_2node_data["users"]
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="Missing required table"):
            validate(valid_2node_data, config)

    def test_missing_column(self, valid_2node_data):
        valid_2node_data["users"] = pd.DataFrame({"wrong_col": ["u1"]})
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="missing required column"):
            validate(valid_2node_data, config)

    def test_null_ids(self, valid_2node_data):
        valid_2node_data["users"] = pd.DataFrame({"user_id": ["u1", None]})
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="null values"):
            validate(valid_2node_data, config)

    def test_negative_prices(self, valid_2node_data):
        valid_2node_data["products"]["price"] = [-1.0, 20.0]
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="negative"):
            validate(valid_2node_data, config)

    def test_duplicate_user_ids(self, valid_2node_data):
        valid_2node_data["users"] = pd.DataFrame({"user_id": ["u1", "u1"]})
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="duplicate"):
            validate(valid_2node_data, config)

    def test_referential_integrity_violation(self, valid_2node_data):
        valid_2node_data["interactions"]["user_id"] = ["u1", "u_missing"]
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="not found"):
            validate(valid_2node_data, config)

    def test_3node_missing_entities(self, valid_2node_data):
        config = {"contract_version": "1.0", "topology": "user-entity-product"}
        with pytest.raises(ContractValidationError, match="Missing required table"):
            validate(valid_2node_data, config)

    def test_wrong_contract_version(self, valid_2node_data):
        config = {"contract_version": "2.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="Unsupported"):
            validate(valid_2node_data, config)

    def test_major_only_version_rejected(self):
        """M7: major-only format should be rejected (requires major.minor)."""
        with pytest.raises(ContractValidationError, match="Invalid"):
            check_contract_version("1")

    def test_interaction_weight_nan_rejected(self, valid_2node_data):
        """M7: NaN interaction weights should be detected."""
        valid_2node_data["interactions"]["weight"] = [float("nan"), 3.0]
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="NaN"):
            validate(valid_2node_data, config)

    def test_interaction_weight_negative_rejected(self, valid_2node_data):
        """M7: Negative interaction weights should be detected."""
        valid_2node_data["interactions"]["weight"] = [-1.0, 3.0]
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="negative"):
            validate(valid_2node_data, config)

    def test_interaction_weight_inf_rejected(self, valid_2node_data):
        """M7: Inf interaction weights should be detected."""
        valid_2node_data["interactions"]["weight"] = [float("inf"), 3.0]
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="Inf"):
            validate(valid_2node_data, config)

    def test_str_type_enforcement(self, valid_2node_data):
        """M7: String columns should reject non-string types."""
        valid_2node_data["users"] = pd.DataFrame({"user_id": [1, 2]})
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="expected string"):
            validate(valid_2node_data, config)

    def test_non_string_contract_version_rejected(self):
        """Non-string contract_version must raise ContractValidationError."""
        for bad_version in [1, 1.0, None]:
            with pytest.raises(ContractValidationError, match="must be a string"):
                check_contract_version(bad_version)

    def test_three_part_version_rejected(self):
        """'1.0.1' is not valid major.minor format."""
        with pytest.raises(ContractValidationError, match="Invalid"):
            check_contract_version("1.0.1")

    def test_mixed_type_object_column_rejected(self, valid_2node_data):
        """Object column with non-string values should be caught."""
        valid_2node_data["users"] = pd.DataFrame({"user_id": ["u1", 42]})
        config = {"contract_version": "1.0", "topology": "user-product"}
        with pytest.raises(ContractValidationError, match="non-string"):
            validate(valid_2node_data, config)

    def test_negative_minor_version_rejected(self):
        """'1.-1' is not valid major.minor format."""
        with pytest.raises(ContractValidationError, match="Invalid"):
            check_contract_version("1.-1")

    def test_version_with_spaces_rejected(self):
        """'1. 2' is not valid major.minor format."""
        with pytest.raises(ContractValidationError, match="Invalid"):
            check_contract_version("1. 2")
