"""
Clippy Backend — FastAPI server with Cognee + Qdrant + Distil Labs SLM.

General-purpose clipboard intelligence backend:
- nomic-embed-text (768-dim) embeddings via llama-cpp-python
- Qdrant advanced search: Prefetch+RRF Fusion, Discovery, Recommend, Group, Filtered
- Cognee knowledge graph memory
- Distil Labs SLM + Qwen3-4B fallback for RAG
- General-purpose entity extraction
- OpenAI-compatible /v1/chat/completions endpoint for Cognee's cognify()
"""

import asyncio
import json
import logging
import os
import re
import subprocess
import sys
import time
import uuid
from contextlib import asynccontextmanager

# ── Environment bootstrap (must happen BEFORE any library imports) ────────────
# Suppress noisy ggml Metal bf16 "not supported" messages during model loading.
# Must be set before llama_cpp is imported. Level 4 = errors only.
os.environ.setdefault("GGML_LOG_LEVEL", "4")
# Cognee's pydantic-settings config is frozen at import time; env vars must exist first.
os.environ.setdefault("ENABLE_BACKEND_ACCESS_CONTROL", "false")
# Disable Cognee telemetry — send_telemetry() uses blocking requests.post()
# with no timeout inside async code, causing an event-loop deadlock when the
# proxy server is unreachable.
os.environ.setdefault("TELEMETRY_DISABLED", "1")

from dotenv import load_dotenv
load_dotenv()

# Cognee vector backend config (must be set before cognee is imported)
os.environ.setdefault("VECTOR_DB_PROVIDER", "qdrant")
os.environ.setdefault("VECTOR_DB_URL", os.getenv("QDRANT_URL", "http://localhost:6333"))
os.environ.setdefault("VECTOR_DATASET_DATABASE_HANDLER", "qdrant")
from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance,
    FieldCondition,
    Filter,
    MatchValue,
    PayloadSchemaType,
    PointStruct,
    Prefetch,
    Fusion,
    FusionQuery,
    VectorParams,
    DiscoverQuery,
    DiscoverInput,
    ContextPair,
    RecommendQuery,
    RecommendInput,
    RecommendStrategy,
)

from shared.embeddings import init_embeddings, get_embedding, is_available as embed_available, get_model_name as embed_model_name
from shared.llm import init_llm, get_llm_response, is_available as llm_available, get_model_name as llm_model_name

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s: %(message)s")
logger = logging.getLogger("clippy-backend")

# ═══════════════════════════════════════════════════════════════════════
# Paths
# ═══════════════════════════════════════════════════════════════════════
BASE_DIR = os.path.dirname(__file__)
MODELS_DIR = os.path.join(BASE_DIR, "..", "models")

EMBED_MODEL_PATH = os.path.join(MODELS_DIR, "nomic-embed-text", "nomic-embed-text-v1.5.f16.gguf")
LLM_MODEL_PATH = os.path.join(MODELS_DIR, "cognee-distillabs-model-gguf-quantized", "model-quantized.gguf")
LLM_FALLBACK_PATH = os.path.join(MODELS_DIR, "Qwen3-4B-Q4_K_M", "Qwen3-4B-Q4_K_M.gguf")

QDRANT_URL = os.getenv("QDRANT_URL", "http://localhost:6333")
COLLECTION = "clippy_items"
VECTOR_DIM = 768

# ═══════════════════════════════════════════════════════════════════════
# Qdrant Client
# ═══════════════════════════════════════════════════════════════════════
qdrant = QdrantClient(url=QDRANT_URL)

# ═══════════════════════════════════════════════════════════════════════
# Cognee (optional, graceful fallback)
# ═══════════════════════════════════════════════════════════════════════
cognee_available = False
try:
    import cognee
    cognee_available = True
except ImportError:
    pass


# ═══════════════════════════════════════════════════════════════════════
# Pydantic Models
# ═══════════════════════════════════════════════════════════════════════

class AddItemRequest(BaseModel):
    content: str
    app_name: str | None = None
    content_type: str = "text"
    tags: list[str] = []
    title: str | None = None
    is_favorite: bool = False


class AddKnowledgeRequest(BaseModel):
    text: str


class ExtractEntitiesRequest(BaseModel):
    content: str


class EntityResult(BaseModel):
    type: str
    value: str


# ═══════════════════════════════════════════════════════════════════════
# Entity Extraction (regex-based)
# ═══════════════════════════════════════════════════════════════════════

_ENTITY_PATTERNS = [
    ("url", re.compile(r'https?://[^\s<>"{}|\\^`\[\]]+', re.IGNORECASE)),
    ("email", re.compile(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')),
    ("phone", re.compile(r'(?:\+\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}')),
    ("ip_address", re.compile(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b')),
    ("money", re.compile(r'\$[\d,]+(?:\.\d{2})?|\b(?:USD|EUR|GBP)\s*[\d,]+(?:\.\d{2})?', re.IGNORECASE)),
    ("date", re.compile(r'\b\d{4}[-/]\d{1,2}[-/]\d{1,2}\b|\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\b')),
    ("file_path", re.compile(r'(?:/[\w.-]+){2,}|[A-Z]:\\(?:[\w.-]+\\?)+')),
    ("code_keyword", re.compile(r'\b(?:function|class|def|import|export|const|let|var|struct|enum|protocol)\s+[\w]+', re.IGNORECASE)),
]


def _fix_perspective(text: str) -> str:
    """Fix first-person pronouns to second-person in LLM answers.
    Small local models often ignore the 'use second person' instruction."""
    # Order matters: longer phrases first to avoid partial replacements
    replacements = [
        (r'\bI was\b', 'You were'),
        (r'\bI am\b', 'You are'),
        (r'\bI have\b', 'You have'),
        (r'\bI had\b', 'You had'),
        (r'\bI\'m\b', "You're"),
        (r'\bI\'ve\b', "You've"),
        (r'\bI\'d\b', "You'd"),
        (r'\bI\'ll\b', "You'll"),
        (r'\bI will\b', 'You will'),
        (r'\bI can\b', 'You can'),
        (r'\bI could\b', 'You could'),
        (r'\bI would\b', 'You would'),
        (r'\bI should\b', 'You should'),
        (r'\bI need\b', 'You need'),
        (r'\bI want\b', 'You want'),
        (r'\bI did\b', 'You did'),
        (r'\bI do\b', 'You do'),
        (r'\bmy\b', 'your'),
        (r'\bMy\b', 'Your'),
        (r'\bmine\b', 'yours'),
        (r'\bmyself\b', 'yourself'),
    ]
    # Only replace "I" as a standalone word at the start of a sentence or after punctuation
    # to avoid replacing "I" inside words
    for pattern, replacement in replacements:
        text = re.sub(pattern, replacement, text)
    # Standalone "I " at sentence start
    text = re.sub(r'(?<=[.!?]\s)I\b', 'You', text)
    text = re.sub(r'^I\b', 'You', text)
    return text


def extract_entities(text: str) -> list[dict]:
    """Extract general-purpose entities from text using regex patterns."""
    entities = []
    seen = set()
    for entity_type, pattern in _ENTITY_PATTERNS:
        for match in pattern.finditer(text):
            value = match.group().strip()
            key = (entity_type, value)
            if key not in seen:
                seen.add(key)
                entities.append({"type": entity_type, "value": value})
    return entities


def _point_to_dict(point) -> dict:
    """Convert a Qdrant ScoredPoint to a JSON-serializable dict."""
    payload = point.payload or {}
    return {
        "id": str(point.id),
        "score": point.score,
        "content": payload.get("content", ""),
        "contentType": payload.get("contentType", ""),
        "appName": payload.get("appName", ""),
        "title": payload.get("title", ""),
        "tags": payload.get("tags", []),
    }


async def _run_cognee_worker(action_payload: dict, timeout_s: int = 30) -> dict:
    """Run a cognee_worker.py subprocess and return parsed JSON result."""
    worker_path = os.path.join(BASE_DIR, "cognee_worker.py")
    venv_python = os.path.join(BASE_DIR, "venv", "bin", "python")
    python_exe = venv_python if os.path.exists(venv_python) else sys.executable

    proc = await asyncio.get_event_loop().run_in_executor(
        None,
        lambda: subprocess.run(
            [python_exe, worker_path],
            input=json.dumps(action_payload),
            capture_output=True, text=True, timeout=timeout_s,
            cwd=BASE_DIR,
        ),
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "unknown error")[-300:]
        raise RuntimeError(f"Worker failed (rc={proc.returncode}): {err}")
    result = json.loads(proc.stdout)
    if not result.get("ok"):
        raise RuntimeError(result.get("error", "unknown error"))
    return result


# ═══════════════════════════════════════════════════════════════════════
# Qdrant Helpers
# ═══════════════════════════════════════════════════════════════════════

def ensure_collection():
    """Create the clippy_items collection if it does not exist."""
    collections = [c.name for c in qdrant.get_collections().collections]
    if COLLECTION not in collections:
        qdrant.create_collection(
            collection_name=COLLECTION,
            vectors_config=VectorParams(size=VECTOR_DIM, distance=Distance.COSINE),
        )
        logger.info(f"Created collection '{COLLECTION}' ({VECTOR_DIM}-dim, cosine)")
    else:
        info = qdrant.get_collection(COLLECTION)
        logger.info(f"Collection '{COLLECTION}': {info.points_count} points")


def setup_payload_indexes():
    """Create payload indexes for fast filtering on key fields."""
    indexes = [
        ("contentType", PayloadSchemaType.KEYWORD),
        ("appName", PayloadSchemaType.KEYWORD),
        ("tags", PayloadSchemaType.KEYWORD),
        ("isFavorite", PayloadSchemaType.BOOL),
    ]
    for field_name, schema in indexes:
        try:
            qdrant.create_payload_index(
                collection_name=COLLECTION,
                field_name=field_name,
                field_schema=schema,
            )
        except Exception:
            pass


# ═══════════════════════════════════════════════════════════════════════
# Lifespan
# ═══════════════════════════════════════════════════════════════════════

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting Clippy Backend...")
    init_embeddings(EMBED_MODEL_PATH)
    init_llm([(LLM_MODEL_PATH, "Distil Labs"), (LLM_FALLBACK_PATH, "Qwen3-4B")])

    ensure_collection()
    setup_payload_indexes()

    if cognee_available:
        try:
            # Register the Qdrant adapter with Cognee's vector engine factory
            import cognee_community_vector_adapter_qdrant.register  # noqa: F401

            # Set Cognee's data directory to project-level (avoid site-packages)
            cognee_data_dir = os.path.join(BASE_DIR, ".cognee_data")
            os.makedirs(cognee_data_dir, exist_ok=True)
            cognee.config.data_root_directory(cognee_data_dir)
            cognee.config.system_root_directory(cognee_data_dir)

            cognee.config.set_vector_db_provider("qdrant")
            cognee.config.set_vector_db_url(QDRANT_URL)

            # Force the vector dataset handler to qdrant (clear lru_cache + override)
            from cognee.infrastructure.databases.vector.config import get_vectordb_config
            get_vectordb_config.cache_clear()
            config = get_vectordb_config()
            object.__setattr__(config, "vector_db_provider", "qdrant")
            object.__setattr__(config, "vector_db_url", QDRANT_URL)
            object.__setattr__(config, "vector_dataset_database_handler", "qdrant")

            # Configure Cognee's LLM for cognify() — OpenAI for knowledge graph extraction
            cognee_llm_provider = os.getenv("LLM_PROVIDER", "openai")
            cognee_llm_model = os.getenv("LLM_MODEL", "gpt-4o-mini")
            cognee_llm_endpoint = os.getenv("LLM_ENDPOINT", "https://api.openai.com/v1")
            cognee.config.set_llm_api_key(os.getenv("LLM_API_KEY_COGNEE", ""))
            cognee.config.set_llm_provider(cognee_llm_provider)
            cognee.config.set_llm_model(cognee_llm_model)
            cognee.config.set_llm_endpoint(cognee_llm_endpoint)
            logger.info(f"Cognee LLM: {cognee_llm_provider}/{cognee_llm_model} -> {cognee_llm_endpoint}")

            # Mark Cognee's first-run check as done so it doesn't try to
            # call test_llm_connection() / test_embedding_connection() at
            # request time.  Those tests would call our own /v1/chat/completions
            # endpoint, creating a self-referencing deadlock with workers=1.
            # NOTE: The flag lives in setup_and_check_environment, NOT pipeline.
            try:
                import cognee.modules.pipelines.layers.setup_and_check_environment as _env_check
                _env_check._first_run_done = True
            except Exception:
                pass

            logger.info("Cognee initialized with Qdrant backend.")
        except ImportError:
            logger.warning("Cognee available but Qdrant adapter not installed.")
        except Exception as e:
            logger.warning(f"Cognee init error: {e}")
    else:
        logger.info("Cognee not installed. /cognee-search and /add-knowledge disabled.")

    logger.info("Ready.")
    yield
    logger.info("Shutting down Clippy Backend.")


# ═══════════════════════════════════════════════════════════════════════
# App
# ═══════════════════════════════════════════════════════════════════════

app = FastAPI(title="Clippy Backend", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ═══════════════════════════════════════════════════════════════════════
# Health
# ═══════════════════════════════════════════════════════════════════════

@app.get("/health")
async def health():
    """Per-service health status."""
    collection_count = 0
    qdrant_ok = False
    try:
        info = qdrant.get_collection(COLLECTION)
        collection_count = info.points_count
        qdrant_ok = True
    except Exception:
        pass

    return {
        "status": "ok",
        "services": {
            "embeddings": embed_available(),
            "llm": llm_available(),
            "qdrant": qdrant_ok,
            "cognee": cognee_available,
        },
        "models": {
            "embed": embed_model_name(),
            "llm": llm_model_name(),
        },
        "collection": {
            "name": COLLECTION,
            "points": collection_count,
        },
    }


# ═══════════════════════════════════════════════════════════════════════
# Search — Prefetch + RRF Fusion
# ═══════════════════════════════════════════════════════════════════════

@app.get("/search")
async def search(
    q: str = Query(...),
    collection: str = Query(COLLECTION),
    limit: int = Query(20, ge=1, le=100),
    use_fusion: bool = Query(True),
):
    """Qdrant Prefetch + RRF Fusion semantic search."""
    t0 = time.time()
    query_vector = get_embedding(q)
    embed_ms = round((time.time() - t0) * 1000, 1)

    t1 = time.time()
    if use_fusion:
        results = qdrant.query_points(
            collection_name=collection,
            prefetch=[
                Prefetch(query=query_vector, limit=100),
                Prefetch(query=query_vector, limit=50),
            ],
            query=FusionQuery(fusion=Fusion.RRF),
            limit=limit,
            with_payload=True,
        )
    else:
        results = qdrant.query_points(
            collection_name=collection,
            query=query_vector,
            limit=limit,
            with_payload=True,
        )
    search_ms = round((time.time() - t1) * 1000, 1)

    items = [_point_to_dict(p) for p in results.points]

    return {
        "query": q,
        "results": items,
        "total": len(items),
        "time_ms": round((time.time() - t0) * 1000, 1),
        "embed_ms": embed_ms,
        "search_ms": search_ms,
        "method": "prefetch_rrf_fusion" if use_fusion else "basic_query",
    }


# ═══════════════════════════════════════════════════════════════════════
# Grouped Search
# ═══════════════════════════════════════════════════════════════════════

@app.get("/search/grouped")
async def search_grouped(
    q: str = Query(...),
    collection: str = Query(COLLECTION),
    group_by: str = Query("contentType"),
    limit: int = Query(20),
):
    """Search with results grouped by a payload field (e.g. appName or contentType)."""
    t0 = time.time()
    query_vector = get_embedding(q)
    embed_ms = round((time.time() - t0) * 1000, 1)

    t1 = time.time()
    groups = qdrant.query_points_groups(
        collection_name=collection,
        query=query_vector,
        group_by=group_by,
        limit=limit,
        group_size=5,
        with_payload=True,
    )
    search_ms = round((time.time() - t1) * 1000, 1)

    result_groups = {}
    total = 0
    for group in groups.groups:
        key = str(group.id)
        result_groups[key] = [_point_to_dict(hit) for hit in group.hits]
        total += len(result_groups[key])

    return {
        "query": q,
        "groups": result_groups,
        "total": total,
        "time_ms": round((time.time() - t0) * 1000, 1),
        "embed_ms": embed_ms,
        "search_ms": search_ms,
    }


# ═══════════════════════════════════════════════════════════════════════
# Discovery API
# ═══════════════════════════════════════════════════════════════════════

@app.get("/discover")
async def discover(
    q: str = Query(...),
    collection: str = Query(COLLECTION),
    positive_id: str = Query(None, description="Point ID for positive context"),
    negative_id: str = Query(None, description="Point ID for negative context"),
    limit: int = Query(20),
):
    """
    Qdrant Discovery API: search with a target vector constrained by context pairs.
    Steers results toward the positive example and away from the negative one.
    """
    t0 = time.time()
    query_vector = get_embedding(q)
    embed_ms = round((time.time() - t0) * 1000, 1)

    t1 = time.time()
    if positive_id and negative_id:
        results = qdrant.query_points(
            collection_name=collection,
            query=DiscoverQuery(
                discover=DiscoverInput(
                    target=query_vector,
                    context=[ContextPair(positive=positive_id, negative=negative_id)],
                )
            ),
            limit=limit,
            with_payload=True,
        )
    elif positive_id:
        results = qdrant.query_points(
            collection_name=collection,
            query=RecommendQuery(
                recommend=RecommendInput(
                    positive=[positive_id],
                    strategy=RecommendStrategy.AVERAGE_VECTOR,
                )
            ),
            limit=limit,
            with_payload=True,
        )
    elif negative_id:
        results = qdrant.query_points(
            collection_name=collection,
            query=RecommendQuery(
                recommend=RecommendInput(
                    positive=[query_vector],
                    negative=[negative_id],
                    strategy=RecommendStrategy.BEST_SCORE,
                )
            ),
            limit=limit,
            with_payload=True,
        )
    else:
        results = qdrant.query_points(
            collection_name=collection,
            query=query_vector,
            limit=limit,
            with_payload=True,
        )
    search_ms = round((time.time() - t1) * 1000, 1)

    items = [_point_to_dict(p) for p in results.points]

    method = "discovery_api" if (positive_id and negative_id) else "recommend_api" if (positive_id or negative_id) else "basic_query"
    return {
        "query": q,
        "positive_id": positive_id,
        "negative_id": negative_id,
        "results": items,
        "time_ms": round((time.time() - t0) * 1000, 1),
        "embed_ms": embed_ms,
        "search_ms": search_ms,
        "method": method,
    }


# ═══════════════════════════════════════════════════════════════════════
# Recommend API
# ═══════════════════════════════════════════════════════════════════════

@app.get("/recommend")
async def recommend(
    positive_ids: str = Query(..., description="Comma-separated positive point IDs"),
    negative_ids: str = Query("", description="Comma-separated negative point IDs"),
    collection: str = Query(COLLECTION),
    strategy: str = Query("average_vector", description="average_vector or best_score"),
    limit: int = Query(10),
):
    """Qdrant Recommend API: find similar items using positive/negative point IDs."""
    t0 = time.time()
    pos = [pid.strip() for pid in positive_ids.split(",") if pid.strip()]
    neg = [pid.strip() for pid in negative_ids.split(",") if pid.strip()]
    strat = RecommendStrategy.BEST_SCORE if strategy == "best_score" else RecommendStrategy.AVERAGE_VECTOR

    results = qdrant.query_points(
        collection_name=collection,
        query=RecommendQuery(
            recommend=RecommendInput(
                positive=pos,
                negative=neg if neg else None,
                strategy=strat,
            )
        ),
        limit=limit,
        with_payload=True,
    )

    items = [_point_to_dict(p) for p in results.points]

    return {
        "results": items,
        "time_ms": round((time.time() - t0) * 1000, 1),
        "method": f"recommend_{strategy}",
    }


# ═══════════════════════════════════════════════════════════════════════
# Filtered Search
# ═══════════════════════════════════════════════════════════════════════

@app.get("/filter")
async def filtered_search(
    q: str = Query(...),
    collection: str = Query(COLLECTION),
    type_filter: str = Query(None, description="Filter by contentType"),
    app_filter: str = Query(None, description="Filter by appName"),
    limit: int = Query(20),
):
    """Semantic search with payload filter using indexed fields."""
    t0 = time.time()
    query_vector = get_embedding(q)

    conditions = []
    if type_filter:
        conditions.append(FieldCondition(key="contentType", match=MatchValue(value=type_filter)))
    if app_filter:
        conditions.append(FieldCondition(key="appName", match=MatchValue(value=app_filter)))

    query_filter = Filter(must=conditions) if conditions else None

    results = qdrant.query_points(
        collection_name=collection,
        query=query_vector,
        query_filter=query_filter,
        limit=limit,
        with_payload=True,
    )

    items = [_point_to_dict(p) for p in results.points]

    return {"results": items, "time_ms": round((time.time() - t0) * 1000, 1)}


# ═══════════════════════════════════════════════════════════════════════
# Ask (RAG)
# ═══════════════════════════════════════════════════════════════════════

@app.get("/ask")
async def ask(
    q: str = Query(...),
    collection: str = Query(COLLECTION),
    limit: int = Query(5),
):
    """RAG Q&A: retrieve context via Qdrant Prefetch+Fusion, then generate answer with LLM."""
    t0 = time.time()
    query_vector = get_embedding(q)

    # Retrieve context via Prefetch + RRF Fusion
    results = qdrant.query_points(
        collection_name=collection,
        prefetch=[
            Prefetch(query=query_vector, limit=50),
            Prefetch(query=query_vector, limit=20),
        ],
        query=FusionQuery(fusion=Fusion.RRF),
        limit=limit,
        with_payload=True,
    )

    context_docs = []
    for p in results.points:
        payload = p.payload or {}
        content = payload.get("content", "")
        app_name = payload.get("appName", "")
        title = payload.get("title", "")
        prefix = f"[{app_name}] {title}: " if title else f"[{app_name}] " if app_name else ""
        context_docs.append(f"{prefix}{content[:500]}")

    context = "\n---\n".join(context_docs)
    retrieval_ms = round((time.time() - t0) * 1000, 1)

    # LLM generation
    t1 = time.time()
    try:
        answer = get_llm_response(
            "You are a clipboard search assistant. Rules:\n"
            "- Answer ONLY using the context provided below.\n"
            "- Reply with JUST the answer in one short sentence. No commentary, no corrections, no extra explanation.\n"
            "- Refer to the user as 'you/your' (second person). Never use 'I/my'.\n"
            "- If asked for a specific value (name, number, URL), return ONLY that value.\n"
            "- Do NOT mention yourself or your role.",
            f"Context:\n{context}\n\nQuestion: {q}",
            max_tokens=80,
        )
        # Fix first-person → second-person (small models often ignore this instruction)
        answer = _fix_perspective(answer)
    except Exception as e:
        answer = f"LLM error: {e}"
    llm_ms = round((time.time() - t1) * 1000, 1)

    return {
        "question": q,
        "answer": answer,
        "sources": len(context_docs),
        "retrieval_ms": retrieval_ms,
        "llm_ms": llm_ms,
        "model": llm_model_name(),
    }


# ═══════════════════════════════════════════════════════════════════════
# Cognee: Graph-aware search + knowledge ingestion
# ═══════════════════════════════════════════════════════════════════════

@app.get("/cognee-search")
async def cognee_search(
    q: str = Query(...),
    search_type: str = Query("CHUNKS"),
):
    """Cognee graph-aware search via subprocess worker."""
    if not cognee_available:
        return {"error": "Cognee not installed. Run: pip install cognee cognee-community-vector-adapter-qdrant"}

    t0 = time.time()
    try:
        result = await _run_cognee_worker(
            {"action": "search", "query": q, "search_type": search_type}, timeout_s=30,
        )
        items = result["result"]
    except subprocess.TimeoutExpired:
        return {"error": "Cognee search timed out (30s).", "time_ms": round((time.time() - t0) * 1000, 1)}
    except Exception as e:
        return {"error": f"Cognee search failed: {e}", "time_ms": round((time.time() - t0) * 1000, 1)}

    return {
        "query": q,
        "search_type": search_type,
        "results": items,
        "total": len(items),
        "time_ms": round((time.time() - t0) * 1000, 1),
        "method": "cognee_graph_search",
    }


@app.post("/add-knowledge")
async def add_knowledge(request: AddKnowledgeRequest):
    """Add text to the Cognee knowledge graph via subprocess worker.

    Cognee operations run in a subprocess to avoid two deadlocks:
      1. send_telemetry() uses blocking requests.post() with no timeout
      2. cognify() calls our own /v1/chat/completions, deadlocking workers=1
    """
    if not cognee_available:
        return {"error": "Cognee not installed. Run: pip install cognee cognee-community-vector-adapter-qdrant"}

    t0 = time.time()

    # Step 1: cognee.add()
    try:
        await _run_cognee_worker({"action": "add", "text": request.text}, timeout_s=60)
    except subprocess.TimeoutExpired:
        return {"error": "Cognee add timed out (60s).", "time_ms": round((time.time() - t0) * 1000, 1)}
    except Exception as e:
        return {"error": f"Cognee add failed: {e}", "time_ms": round((time.time() - t0) * 1000, 1)}

    add_ms = round((time.time() - t0) * 1000, 1)

    # Step 2: cognee.cognify() — uses LLM via OpenAI gpt-4o-mini
    try:
        await _run_cognee_worker({"action": "cognify"}, timeout_s=180)
        cognify_status = "ok"
    except subprocess.TimeoutExpired:
        cognify_status = "timeout (180s)"
    except Exception as e:
        cognify_status = f"failed: {e}"

    return {
        "status": "ok",
        "message": "Knowledge added to Cognee.",
        "add_ms": add_ms,
        "cognify_status": cognify_status,
        "time_ms": round((time.time() - t0) * 1000, 1),
    }


# ═══════════════════════════════════════════════════════════════════════
# Add Item (embed + upsert)
# ═══════════════════════════════════════════════════════════════════════

@app.post("/add-item")
async def add_item(request: AddItemRequest):
    """Embed clipboard content with nomic-embed-text and upsert into Qdrant."""
    t0 = time.time()

    try:
        vector = get_embedding(request.content)
    except Exception as e:
        return {"error": f"Embedding failed: {e}"}

    point_id = str(uuid.uuid4())
    payload = {
        "content": request.content,
        "appName": request.app_name or "Unknown",
        "contentType": request.content_type,
        "tags": request.tags,
        "title": request.title or "",
        "timestamp": time.time(),
        "isFavorite": request.is_favorite,
        "entities": [e["value"] for e in extract_entities(request.content)],
    }

    qdrant.upsert(
        collection_name=COLLECTION,
        points=[PointStruct(id=point_id, vector=vector, payload=payload)],
    )

    return {
        "status": "ok",
        "point_id": point_id,
        "time_ms": round((time.time() - t0) * 1000, 1),
    }


# ═══════════════════════════════════════════════════════════════════════
# Entity Extraction
# ═══════════════════════════════════════════════════════════════════════

@app.post("/extract-entities")
async def extract_entities_endpoint(request: ExtractEntitiesRequest):
    """General-purpose entity extraction: URLs, emails, dates, money, code identifiers, etc."""
    entities = extract_entities(request.content)
    return {"entities": entities, "total": len(entities)}


# ═══════════════════════════════════════════════════════════════════════
# Collections Info
# ═══════════════════════════════════════════════════════════════════════

@app.get("/collections")
async def list_collections():
    """List Qdrant collections and point counts."""
    result = {}
    try:
        for c in qdrant.get_collections().collections:
            info = qdrant.get_collection(c.name)
            result[c.name] = {
                "points": info.points_count,
                "vectors_size": info.config.params.vectors.size if hasattr(info.config.params.vectors, 'size') else None,
            }
    except Exception as e:
        return {"error": str(e)}
    return result


# ═══════════════════════════════════════════════════════════════════════
# OpenAI-compatible Chat Completions  (used by Cognee's cognify())
# ═══════════════════════════════════════════════════════════════════════

class ChatMessage(BaseModel):
    role: str
    content: str = ""

    model_config = {"extra": "allow"}


class ChatCompletionRequest(BaseModel):
    model: str = "distil-labs-slm"
    messages: list[ChatMessage]
    max_tokens: int = 2048
    temperature: float = 0.3
    response_format: dict | None = None
    top_p: float | None = None
    n: int | None = None
    stop: list[str] | str | None = None
    stream: bool = False

    model_config = {"extra": "allow"}


@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest):
    """OpenAI-compatible chat completions endpoint backed by the local SLM.
    This lets Cognee call cognify() against our own backend instead of
    requiring an external OpenAI API key."""
    system_prompt = ""
    user_prompt = ""
    for msg in request.messages:
        if msg.role == "system":
            system_prompt += (msg.content or "") + "\n"
        elif msg.role == "user":
            user_prompt += (msg.content or "") + "\n"
        elif msg.role == "assistant":
            # Context from prior turns — append to user prompt for single-turn LLM
            user_prompt += (msg.content or "") + "\n"

    system_prompt = system_prompt.strip()
    user_prompt = user_prompt.strip()

    # If response_format requests JSON, reinforce it in the system prompt
    if request.response_format and request.response_format.get("type") == "json_object":
        system_prompt += "\n\nIMPORTANT: You MUST respond with valid JSON only. No markdown, no explanation."

    try:
        answer = get_llm_response(system_prompt, user_prompt, max_tokens=request.max_tokens)
    except Exception as e:
        logger.error(f"LLM error in /v1/chat/completions: {e}")
        return JSONResponse(status_code=500, content={"error": str(e)})

    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": request.model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": answer},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="127.0.0.1", port=8420, workers=1, reload=True)
