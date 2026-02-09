#!/usr/bin/env python3
"""
Cognee Worker — runs Cognee operations in an isolated subprocess.

Bypasses two deadlocks in Cognee v0.5.2:
  1. send_telemetry() uses blocking requests.post() with no timeout
  2. setup_and_check_environment() calls test_llm_connection() /
     test_embedding_connection() which block when the configured
     LLM_ENDPOINT is our own backend (self-referencing deadlock) or
     when LiteLLM's instructor wrapper hangs on a local GGUF model.

Strategy: set _first_run_done = True on the correct module so that
          setup_and_check_environment() skips the connectivity tests.
          We still get table creation (create_relational_db_and_tables,
          create_pgvector_db_and_tables) which are either needed or no-ops.

Usage (pipe JSON on stdin, get JSON on stdout):
    echo '{"action":"add","text":"hello"}' | python cognee_worker.py
    echo '{"action":"cognify"}' | python cognee_worker.py
    echo '{"action":"search","query":"hello","search_type":"CHUNKS"}' | python cognee_worker.py
    echo '{"action":"prune"}' | python cognee_worker.py
"""

import json
import os
import sys

# ── Env vars BEFORE any imports ──────────────────────────────────────────────
from dotenv import load_dotenv

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(BASE_DIR, ".."))
DATA_DIR = os.path.join(REPO_ROOT, ".data")
ENV_PATH = os.path.join(DATA_DIR, ".env")
COGNEE_DATA_DIR = os.path.join(DATA_DIR, "cognee")

load_dotenv(ENV_PATH)

os.environ.setdefault("GGML_LOG_LEVEL", "4")  # errors only — suppress Metal bf16 noise
os.environ.setdefault("ENABLE_BACKEND_ACCESS_CONTROL", "false")
os.environ.setdefault("TELEMETRY_DISABLED", "1")
os.environ.setdefault("ENV", "dev")
os.environ.setdefault("VECTOR_DB_PROVIDER", "qdrant")
os.environ.setdefault("VECTOR_DB_URL", os.getenv("QDRANT_URL", "http://localhost:6333"))
os.environ.setdefault("VECTOR_DATASET_DATABASE_HANDLER", "qdrant")

import asyncio  # noqa: E402

# Register the Qdrant community adapter (side-effect import)
try:
    import cognee_community_vector_adapter_qdrant.register  # noqa: F401
except ImportError:
    pass

# ── Monkey-patch: skip test_llm_connection / test_embedding_connection ───────
# The flag lives in cognee.modules.pipelines.layers.setup_and_check_environment
# (NOT in cognee.modules.pipelines.operations.pipeline — that was the wrong module).
try:
    import cognee.modules.pipelines.layers.setup_and_check_environment as _env_check_mod

    _env_check_mod._first_run_done = True
except Exception:
    pass

import cognee  # noqa: E402


def _configure_cognee():
    """Set Cognee runtime config: Qdrant backend + project-level data dir."""
    os.makedirs(COGNEE_DATA_DIR, exist_ok=True)
    cognee.config.data_root_directory(COGNEE_DATA_DIR)
    cognee.config.system_root_directory(COGNEE_DATA_DIR)
    cognee.config.set_vector_db_provider("qdrant")
    cognee.config.set_vector_db_url(os.getenv("QDRANT_URL", "http://localhost:6333"))

    # Configure LLM for cognify() — OpenAI for knowledge graph extraction
    llm_provider = os.getenv("LLM_PROVIDER", "openai")
    llm_model = os.getenv("LLM_MODEL", "gpt-4o-mini")
    llm_endpoint = os.getenv("LLM_ENDPOINT", "https://api.openai.com/v1")
    llm_api_key = os.getenv("LLM_API_KEY_COGNEE", "")
    cognee.config.set_llm_api_key(llm_api_key)
    cognee.config.set_llm_provider(llm_provider)
    cognee.config.set_llm_model(llm_model)
    cognee.config.set_llm_endpoint(llm_endpoint)


# ── Actions ──────────────────────────────────────────────────────────────────

async def do_add(text: str, dataset_name: str = "main_dataset") -> dict:
    """Add text to Cognee."""
    await cognee.add(text, dataset_name=dataset_name)
    return {"status": "ok"}


async def do_cognify() -> dict:
    """Run Cognee's cognify pipeline (LLM-based knowledge graph extraction)."""
    await cognee.cognify()
    return {"status": "ok"}


async def do_search(query: str, search_type: str = "CHUNKS") -> list:
    """Search Cognee knowledge graph."""
    from cognee.api.v1.search import SearchType

    st = getattr(SearchType, search_type.upper(), SearchType.CHUNKS)
    results = await cognee.search(query_text=query, query_type=st)
    return [str(r) for r in (results or [])[:20]]


async def do_prune() -> dict:
    """Reset all Cognee data."""
    await cognee.prune.prune_data()
    await cognee.prune.prune_system(metadata=True)
    return {"pruned": True}


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    _configure_cognee()

    raw = sys.stdin.read().strip()
    if not raw:
        print(json.dumps({"ok": False, "error": "No input"}))
        sys.exit(1)

    try:
        cmd = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"ok": False, "error": f"Invalid JSON: {e}"}))
        sys.exit(1)

    action = cmd.get("action", "")

    try:
        if action == "add":
            result = asyncio.run(
                do_add(cmd.get("text", ""), cmd.get("dataset_name", "main_dataset"))
            )
        elif action == "cognify":
            result = asyncio.run(do_cognify())
        elif action == "search":
            result = asyncio.run(
                do_search(cmd.get("query", ""), cmd.get("search_type", "CHUNKS"))
            )
        elif action == "prune":
            result = asyncio.run(do_prune())
        else:
            print(json.dumps({"ok": False, "error": f"Unknown action: {action}"}))
            sys.exit(1)

        print(json.dumps({"ok": True, "result": result}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
