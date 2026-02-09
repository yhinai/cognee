"""
Unified AI Service: LLM and Embeddings.
Handles local GGUF models (llama-cpp-python) and remote OpenAI-compatible APIs.
"""

import logging
import os
import requests

# Suppress Metal/GGML logging
os.environ.setdefault("GGML_LOG_LEVEL", "4")

logger = logging.getLogger(__name__)

# ── Shared State ─────────────────────────────────────────────────────────────
_llm_model = None
_embed_model = None
_llm_mode = None
_embed_mode = None


# ── LLM Logic ────────────────────────────────────────────────────────────────

def _get_llm_mode():
    return os.getenv("LLM_MODE", "local")

def init_llm(model_paths: list[tuple[str, str]] | None = None):
    """
    Initialize the LLM backend.
    """
    global _llm_model, _llm_mode
    _llm_mode = _get_llm_mode()

    if _llm_mode == "remote":
        logger.info("LLM mode: remote (%s)", os.getenv("LLM_API_URL", "not set"))
        return

    from llama_cpp import Llama

    if model_paths is None:
        model_paths = []

    for path, name in model_paths:
        if os.path.exists(path):
            logger.info("Loading %s LLM from %s...", name, path)
            _llm_model = Llama(model_path=path, n_ctx=4096, n_batch=512, verbose=False)
            logger.info("%s LLM loaded.", name)
            return

    logger.warning("No LLM model found. LLM features disabled.")

def get_llm_response(system_prompt: str, user_prompt: str, max_tokens: int = 256) -> str:
    """Generate a chat completion."""
    mode = _llm_mode or _get_llm_mode()
    if mode == "remote":
        return _remote_llm_completion(system_prompt, user_prompt, max_tokens)
    return _local_llm_completion(system_prompt, user_prompt, max_tokens)

def _local_llm_completion(system_prompt: str, user_prompt: str, max_tokens: int) -> str:
    if _llm_model is None:
        return "No local LLM loaded."
    
    response = _llm_model.create_chat_completion(
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        max_tokens=max_tokens,
        temperature=0.3,
        repeat_penalty=1.3,
        stop=["[/INST]", "[INST]", "</s>", "<|im_end|>", "<|endoftext|>"],
    )
    text = response["choices"][0]["message"]["content"].strip()
    # Guard against repetition
    for marker in ["[/INST]", "\n\n\n"]:
        if marker in text:
            text = text[:text.index(marker)].strip()
            break
    return text

def _remote_llm_completion(system_prompt: str, user_prompt: str, max_tokens: int) -> str:
    api_url = os.getenv("LLM_API_URL")
    api_key = os.getenv("LLM_API_KEY", "")
    model_name = os.getenv("LLM_MODEL_NAME", "distil-labs-slm")

    if not api_url:
        return "LLM_API_URL not set."

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    payload = {
        "model": model_name,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "max_tokens": max_tokens,
        "temperature": 0.3,
    }

    try:
        r = requests.post(f"{api_url.rstrip('/')}/chat/completions", headers=headers, json=payload, timeout=60)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
    except Exception as e:
        return f"Remote LLM error: {e}"

def is_llm_available() -> bool:
    mode = _llm_mode or _get_llm_mode()
    if mode == "remote":
        return bool(os.getenv("LLM_API_URL"))
    return _llm_model is not None

def get_llm_model_name() -> str:
    mode = _llm_mode or _get_llm_mode()
    if mode == "remote":
        return os.getenv("LLM_MODEL_NAME", "remote")
    if _llm_model is not None:
        return "distil-labs-local"
    return "none"


# ── Embedding Logic ──────────────────────────────────────────────────────────

def _get_embed_mode():
    return os.getenv("EMBED_MODE", "local")

def init_embeddings(model_path: str | None = None):
    """Initialize the embedding backend."""
    global _embed_model, _embed_mode
    _embed_mode = _get_embed_mode()

    if _embed_mode == "remote":
        logger.info("Embedding mode: remote (%s)", os.getenv("EMBED_API_URL", "not set"))
        return

    from llama_cpp import Llama
    if model_path and os.path.exists(model_path):
        logger.info("Loading nomic-embed-text model...")
        _embed_model = Llama(
            model_path=model_path,
            embedding=True,
            n_ctx=2048,
            n_batch=512,
            verbose=False,
        )
        logger.info("Embedding model loaded.")
    else:
        logger.warning("Embedding model not found at %s", model_path)

def get_embedding(text: str) -> list[float]:
    """Embed text."""
    mode = _embed_mode or _get_embed_mode()
    if mode == "remote":
        return _remote_embed(text)
    return _local_embed(text)

def _local_embed(text: str) -> list[float]:
    if _embed_model is None:
        raise RuntimeError("No local embedding model loaded.")
    result = _embed_model.embed(f"search_query: {text}")
    return result[0] if isinstance(result[0], list) else result

def _remote_embed(text: str) -> list[float]:
    api_url = os.getenv("EMBED_API_URL")
    api_key = os.getenv("EMBED_API_KEY", "")
    model_name = os.getenv("EMBED_MODEL_NAME", "nomic-embed-text")

    if not api_url:
        raise RuntimeError("EMBED_API_URL not set.")

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    r = requests.post(
        f"{api_url.rstrip('/')}/embeddings",
        headers=headers,
        json={"model": model_name, "input": f"search_query: {text}"},
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["data"][0]["embedding"]

def is_embedding_available() -> bool:
    mode = _embed_mode or _get_embed_mode()
    if mode == "remote":
        return bool(os.getenv("EMBED_API_URL"))
    return _embed_model is not None

def get_embed_model_name() -> str:
    mode = _embed_mode or _get_embed_mode()
    if mode == "remote":
        return os.getenv("EMBED_MODEL_NAME", "remote")
    if _embed_model is not None:
        return "nomic-embed-text-local"
    return "none"
