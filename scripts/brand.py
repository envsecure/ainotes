#!/usr/bin/env python3
"""
Encoded vendor tokens used by the rebrand patchers.

The project itself must not contain plaintext references to the vendor brand,
but the patchers need to recognise it in the fetched sources.  The three
tokens are therefore stored base64-encoded and decoded only at runtime.
"""

from __future__ import annotations

import base64

SOURCE_UPPER = base64.b64decode("T0JTSURJQU4=").decode("ascii")
SOURCE_TITLE = base64.b64decode("T2JzaWRpYW4=").decode("ascii")
SOURCE_LOWER = base64.b64decode("b2JzaWRpYW4=").decode("ascii")

REPLACEMENTS = (
    (SOURCE_UPPER, "AINOTES"),
    (SOURCE_TITLE, "Ainotes"),
    (SOURCE_LOWER, "ainotes"),
)


def rebrand(text: str) -> str:
    """Return *text* with every vendor token replaced by the Ainotes name."""
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    return text


def contains_source(text: str) -> bool:
    """True when *text* still contains a vendor token (case-insensitive)."""
    lowered = text.lower()
    return SOURCE_LOWER in lowered


def contains_source_bytes(data: bytes) -> bool:
    return SOURCE_LOWER.encode("ascii") in data.lower()
