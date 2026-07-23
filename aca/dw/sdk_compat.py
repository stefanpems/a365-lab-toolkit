# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""SDK compatibility shims.

Import this module BEFORE any ``microsoft_agents.activity.Activity`` validation
happens (i.e. at the very top of the host entry point).

Why this exists
---------------
The Agent 365 agentic / Teams channel sends the ``productInfo`` entity with a
camelCase ``type`` value (``"productInfo"``), which matches the SDK's own
docstring ("entity type: 'productInfo'"). However every published version of
``microsoft-agents-activity`` (1.0.0 through 1.2.0.dev7) defines
``EntityTypes.PRODUCT_INFO = "ProductInfo"`` and pins the model with
``type: Literal["ProductInfo"]``.

As a result, ``Activity.model_validate(body)`` raises a pydantic
``literal_error`` for every inbound message that carries a ``productInfo``
entity, so the agent replies ``500`` on ``POST /api/messages`` and never
processes the turn. See the container logs:

    ValidationError: 1 validation error for ProductInfo
    type: Input should be 'ProductInfo' [input_value='productInfo']

This shim replaces the ``ProductInfo`` model used at the
``Activity._convert_entity`` call site with a relaxed variant that accepts both
``"productInfo"`` and ``"ProductInfo"``, restoring correct parsing (and the
derived ``channel_id`` sub-channel).

Remove this shim once the upstream SDK ships a fixed ``ProductInfo`` model.
"""

from typing import Literal, Optional


def apply_product_info_compat() -> None:
    """Patch ProductInfo to accept camelCase 'productInfo' entity types."""
    try:
        import microsoft_agents.activity.activity as _activity_mod
        from microsoft_agents.activity.entity import Entity
    except Exception:
        # SDK layout changed or not installed; nothing to patch.
        return

    class ProductInfoCompat(Entity):
        """ProductInfo entity accepting both camelCase and PascalCase type."""

        type: Literal["productInfo", "ProductInfo"] = "productInfo"
        id: Optional[str] = None

    # get_product_info_entity() converts the raw entity via the module-level
    # ``ProductInfo`` name in activity.py, so patching that name is sufficient.
    _activity_mod.ProductInfo = ProductInfoCompat
