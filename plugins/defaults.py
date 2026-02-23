"""Default plugin implementations for the recommendation engine.

Provides sensible defaults for all hooks. Suitable for clients that
don't need custom behavior beyond basic normalization.
"""

from __future__ import annotations

import hashlib
import logging
import os

from rec_engine.plugins import RecEnginePlugin

logger = logging.getLogger(__name__)


class DefaultPlugin(RecEnginePlugin):
    """Default plugin with minimal normalization and no special behavior.

    Uses a simple hash for user ID normalization. Clients with PII
    requirements should override normalize_user_id with their own
    salted hashing strategy.
    """

    def __init__(self, salt: str | None = None):
        self._salt = salt or os.environ.get("REC_ENGINE_USER_SALT", "")
        if not self._salt:
            self._salt = "default-salt"
            logger.warning(
                "No user salt provided (set REC_ENGINE_USER_SALT or pass salt= to constructor). "
                "Using default — all deployments will produce identical user ID hashes."
            )

    def normalize_user_id(self, raw_id: str) -> str:
        """Hash user ID with salt for privacy."""
        cleaned = raw_id.strip().lower()
        return hashlib.sha256(
            f"{self._salt}:{cleaned}".encode()
        ).hexdigest()[:16]

    def normalize_product_id(self, raw_id: str) -> str:
        """Strip whitespace from product ID."""
        return raw_id.strip()
