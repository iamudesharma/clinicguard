"""Embeddings client for the RAG knowledge base.

Any OpenAI-compatible ``/embeddings`` endpoint works. Provider preference:

1. Explicit ``EMBEDDING_BASE_URL`` / ``EMBEDDING_API_KEY`` / ``EMBEDDING_MODEL``
   in ``server/.env``;
2. OpenAI ``text-embedding-3-small`` when ``OPENAI_API_KEY`` is set;
3. Free default: OpenRouter ``nvidia/nemotron-3-embed-1b:free`` (2048-dim)
   when ``OPENROUTER_API_KEY`` is set.

The ``knowledge_chunks.embedding`` column is an unconstrained vector, so any
dimension works without schema changes.
"""

from __future__ import annotations

import os
from typing import Sequence

from openai import OpenAI

from config import get_settings

_OPENROUTER_BASE = "https://openrouter.ai/api/v1"
_FREE_EMBEDDING = "nvidia/nemotron-3-embed-1b:free"
_OPENAI_DEFAULT = "text-embedding-3-small"


def _configured() -> tuple[str, str, str]:
    s = get_settings()
    if s.embedding_base_url and s.embedding_api_key and s.embedding_model:
        return s.embedding_base_url, s.embedding_api_key, s.embedding_model
    if os.environ.get("OPENAI_API_KEY"):
        return "https://api.openai.com/v1", os.environ["OPENAI_API_KEY"], _OPENAI_DEFAULT
    if s.openrouter_api_key:
        return _OPENROUTER_BASE, s.openrouter_api_key, _FREE_EMBEDDING
    return "", "", ""


def is_configured() -> bool:
    _, key, _ = _configured()
    return bool(key)


def client() -> OpenAI:
    base, key, _ = _configured()
    return OpenAI(base_url=base, api_key=key)


def model_name() -> str:
    return _configured()[2]


def embed_texts(texts: Sequence[str], *, batch_size: int = 32) -> list[list[float]]:
    """Embed texts in batches; raises RuntimeError when no provider is configured."""
    if not is_configured():
        raise RuntimeError(
            "no embeddings provider configured: set EMBEDDING_BASE_URL/API_KEY/MODEL, "
            "OPENAI_API_KEY, or OPENROUTER_API_KEY (free nemotron-3-embed-1b)"
        )
    c = client()
    model = model_name()
    out: list[list[float]] = []
    for i in range(0, len(texts), batch_size):
        batch = [t for t in texts[i : i + batch_size] if t.strip()]
        if not batch:
            continue
        resp = c.embeddings.create(model=model, input=batch, encoding_format="float")
        for item in sorted(resp.data, key=lambda d: d.index):
            out.append(item.embedding)
    return out


def embed_query(text: str) -> list[float]:
    if not is_configured():
        raise RuntimeError(
            "no embeddings provider configured: set EMBEDDING_BASE_URL/API_KEY/MODEL, "
            "OPENAI_API_KEY, or OPENROUTER_API_KEY (free nemotron-3-embed-1b)"
        )
    resp = client().embeddings.create(
        model=model_name(), input=[text], encoding_format="float"
    )
    return resp.data[0].embedding
