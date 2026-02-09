"""
Clippy Backend — FastAPI server with Cognee + Qdrant + Local LLM.

Lean, flat structure:
- config.py: all settings
- models.py: Pydantic models
- models.py: Pydantic models
- ai.py: Unified AI services (LLM + Embeddings)
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

# ── Environment bootstrap (BEFORE library imports) ────────────────────────────
os.environ.setdefault("GGML_LOG_LEVEL", "4")
os.environ.setdefault("ENABLE_BACKEND_ACCESS_CONTROL", "false")
os.environ.setdefault("TELEMETRY_DISABLED", "1")

from dotenv import load_dotenv
load_dotenv()

os.environ.setdefault("VECTOR_DB_PROVIDER", "qdrant")
os.environ.setdefault("VECTOR_DB_URL", os.getenv("QDRANT_URL", "http://localhost:6333"))

from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance, FieldCondition, Filter, MatchValue, PayloadSchemaType,
    PointStruct, Prefetch, Fusion, FusionQuery, VectorParams,
    DiscoverQuery, DiscoverInput, ContextPair,
    RecommendQuery, RecommendInput, RecommendStrategy,
)

from config import (
    EMBED_MODEL_PATH, LLM_MODEL_PATH, LLM_FALLBACK_PATH,
    QDRANT_URL, COLLECTION, VECTOR_DIM,
    COGNEE_ADD_TIMEOUT, COGNEE_COGNIFY_TIMEOUT, COGNEE_SEARCH_TIMEOUT,
    DEFAULT_SEARCH_LIMIT, MAX_SEARCH_LIMIT, RAG_CONTEXT_LIMIT, RAG_MAX_TOKENS,
)
from models import (
    AddItemRequest, AddKnowledgeRequest, ExtractEntitiesRequest,
    ChatCompletionRequest, point_to_dict,
)
from ai import (
    init_embeddings, get_embedding, is_embedding_available as embed_ok, get_embed_model_name as embed_name,
    init_llm, get_llm_response, is_llm_available as llm_ok, get_llm_model_name as llm_name
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s: %(message)s")
logger = logging.getLogger("clippy")

# ── Clients ───────────────────────────────────────────────────────────────────
qdrant = QdrantClient(url=QDRANT_URL)
BASE_DIR = os.path.dirname(__file__)

# ── Cognee (optional) ─────────────────────────────────────────────────────────
try:
    import cognee
    COGNEE_OK = True
except ImportError:
    COGNEE_OK = False

# ── Entity Patterns ───────────────────────────────────────────────────────────
ENTITY_PATTERNS = [
    ("url", re.compile(r'https?://[^\s<>"{}|\\^`\[\]]+', re.I)),
    ("email", re.compile(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')),
    ("phone", re.compile(r'(?:\+\d{1,3}[-.\\s]?)?\(?\d{3}\)?[-.\\s]?\d{3}[-.\\s]?\d{4}')),
    ("date", re.compile(r'\b\d{4}[-/]\d{1,2}[-/]\d{1,2}\b|\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\b')),
    ("money", re.compile(r'\$[\d,]+(?:\.\d{2})?', re.I)),
    ("file_path", re.compile(r'(?:/[\w.-]+){2,}|[A-Z]:\\(?:[\w.-]+\\?)+')),
]


def extract_entities(text: str) -> list[dict]:
    seen, out = set(), []
    for etype, pat in ENTITY_PATTERNS:
        for m in pat.finditer(text):
            v = m.group().strip()
            if (etype, v) not in seen:
                seen.add((etype, v))
                out.append({"type": etype, "value": v})
    return out





async def run_cognee_worker(payload: dict, timeout: int = 30) -> dict:
    """Run cognee_worker.py subprocess."""
    worker = os.path.join(BASE_DIR, "cognee_worker.py")
    python = os.path.join(BASE_DIR, "venv", "bin", "python") if os.path.exists(os.path.join(BASE_DIR, "venv")) else sys.executable
    proc = await asyncio.get_event_loop().run_in_executor(
        None, lambda: subprocess.run([python, worker], input=json.dumps(payload), capture_output=True, text=True, timeout=timeout, cwd=BASE_DIR)
    )
    if proc.returncode != 0:
        raise RuntimeError(f"Worker failed: {(proc.stderr or proc.stdout or '')[-300:]}")
    result = json.loads(proc.stdout)
    if not result.get("ok"):
        raise RuntimeError(result.get("error", "unknown"))
    return result


def ensure_collection():
    if COLLECTION not in [c.name for c in qdrant.get_collections().collections]:
        qdrant.create_collection(COLLECTION, VectorParams(size=VECTOR_DIM, distance=Distance.COSINE))
        logger.info(f"Created collection '{COLLECTION}'")
    for field, schema in [("contentType", PayloadSchemaType.KEYWORD), ("appName", PayloadSchemaType.KEYWORD), ("tags", PayloadSchemaType.KEYWORD)]:
        try:
            qdrant.create_payload_index(COLLECTION, field, schema)
        except Exception:
            pass


# ── Lifespan ──────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting Clippy Backend...")
    init_embeddings(EMBED_MODEL_PATH)
    init_llm([(LLM_MODEL_PATH, "Distil Labs"), (LLM_FALLBACK_PATH, "Qwen3-4B")])
    ensure_collection()
    
    if COGNEE_OK:
        try:
            import cognee_community_vector_adapter_qdrant.register  # noqa
            cognee_data = os.path.join(BASE_DIR, ".cognee_data")
            os.makedirs(cognee_data, exist_ok=True)
            cognee.config.data_root_directory(cognee_data)
            cognee.config.system_root_directory(cognee_data)
            cognee.config.set_vector_db_provider("qdrant")
            cognee.config.set_vector_db_url(QDRANT_URL)
            cognee.config.set_llm_api_key(os.getenv("LLM_API_KEY_COGNEE", ""))
            cognee.config.set_llm_provider(os.getenv("LLM_PROVIDER", "openai"))
            cognee.config.set_llm_model(os.getenv("LLM_MODEL", "gpt-4o-mini"))
            cognee.config.set_llm_endpoint(os.getenv("LLM_ENDPOINT", "https://api.openai.com/v1"))
            try:
                import cognee.modules.pipelines.layers.setup_and_check_environment as _e
                _e._first_run_done = True
            except Exception:
                pass
            logger.info("Cognee initialized.")
        except Exception as e:
            logger.warning(f"Cognee init error: {e}")
    
    logger.info("Ready.")
    yield
    logger.info("Shutting down.")


# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(title="Clippy Backend", version="2.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])


# ── Health ────────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    try:
        info = qdrant.get_collection(COLLECTION)
        pts = info.points_count
        qok = True
    except Exception:
        pts, qok = 0, False
    return {
        "status": "ok",
        "services": {"embeddings": embed_ok(), "llm": llm_ok(), "qdrant": qok, "cognee": COGNEE_OK},
        "models": {"embed": embed_name(), "llm": llm_name()},
        "collection": {"name": COLLECTION, "points": pts},
    }


# ── Search ────────────────────────────────────────────────────────────────────
@app.get("/search")
async def search(q: str = Query(...), limit: int = Query(DEFAULT_SEARCH_LIMIT, ge=1, le=MAX_SEARCH_LIMIT)):
    t0 = time.time()
    vec = get_embedding(q)
    results = qdrant.query_points(COLLECTION, prefetch=[Prefetch(query=vec, limit=100), Prefetch(query=vec, limit=50)], query=FusionQuery(fusion=Fusion.RRF), limit=limit, with_payload=True)
    return {"query": q, "results": [point_to_dict(p) for p in results.points], "time_ms": round((time.time() - t0) * 1000, 1)}


@app.get("/search/grouped")
async def search_grouped(q: str = Query(...), group_by: str = Query("contentType"), limit: int = Query(DEFAULT_SEARCH_LIMIT)):
    t0 = time.time()
    vec = get_embedding(q)
    groups = qdrant.query_points_groups(COLLECTION, query=vec, group_by=group_by, limit=limit, group_size=5, with_payload=True)
    return {"query": q, "groups": {str(g.id): [point_to_dict(h) for h in g.hits] for g in groups.groups}, "time_ms": round((time.time() - t0) * 1000, 1)}


@app.get("/discover")
async def discover(q: str = Query(...), positive_id: str = Query(None), negative_id: str = Query(None), limit: int = Query(DEFAULT_SEARCH_LIMIT)):
    t0 = time.time()
    vec = get_embedding(q)
    if positive_id and negative_id:
        results = qdrant.query_points(COLLECTION, query=DiscoverQuery(discover=DiscoverInput(target=vec, context=[ContextPair(positive=positive_id, negative=negative_id)])), limit=limit, with_payload=True)
    elif positive_id:
        results = qdrant.query_points(COLLECTION, query=RecommendQuery(recommend=RecommendInput(positive=[positive_id], strategy=RecommendStrategy.AVERAGE_VECTOR)), limit=limit, with_payload=True)
    else:
        results = qdrant.query_points(COLLECTION, query=vec, limit=limit, with_payload=True)
    return {"query": q, "results": [point_to_dict(p) for p in results.points], "time_ms": round((time.time() - t0) * 1000, 1)}


@app.get("/recommend")
async def recommend(positive_ids: str = Query(...), negative_ids: str = Query(""), limit: int = Query(10)):
    t0 = time.time()
    pos = [p.strip() for p in positive_ids.split(",") if p.strip()]
    neg = [n.strip() for n in negative_ids.split(",") if n.strip()]
    results = qdrant.query_points(COLLECTION, query=RecommendQuery(recommend=RecommendInput(positive=pos, negative=neg or None, strategy=RecommendStrategy.AVERAGE_VECTOR)), limit=limit, with_payload=True)
    return {"results": [point_to_dict(p) for p in results.points], "time_ms": round((time.time() - t0) * 1000, 1)}


@app.get("/filter")
async def filtered_search(q: str = Query(...), type_filter: str = Query(None), app_filter: str = Query(None), limit: int = Query(DEFAULT_SEARCH_LIMIT)):
    t0 = time.time()
    vec = get_embedding(q)
    conds = []
    if type_filter:
        conds.append(FieldCondition(key="contentType", match=MatchValue(value=type_filter)))
    if app_filter:
        conds.append(FieldCondition(key="appName", match=MatchValue(value=app_filter)))
    results = qdrant.query_points(COLLECTION, query=vec, query_filter=Filter(must=conds) if conds else None, limit=limit, with_payload=True)
    return {"results": [point_to_dict(p) for p in results.points], "time_ms": round((time.time() - t0) * 1000, 1)}


# ── RAG ───────────────────────────────────────────────────────────────────────
@app.get("/ask")
async def ask(q: str = Query(...), limit: int = Query(RAG_CONTEXT_LIMIT)):
    t0 = time.time()
    vec = get_embedding(q)
    results = qdrant.query_points(COLLECTION, prefetch=[Prefetch(query=vec, limit=50)], query=FusionQuery(fusion=Fusion.RRF), limit=limit, with_payload=True)
    
    docs = []
    for p in results.points:
        pl = p.payload or {}
        prefix = f"[{pl.get('appName','')}] " if pl.get('appName') else ""
        docs.append(f"{prefix}{pl.get('content','')[:500]}")
    context = "\n---\n".join(docs)
    
    try:
        answer = get_llm_response(
            "You are a helpful assistant. Use 'you/your' instead of 'I/my'. Answer using ONLY the context.",
            f"Context:\n{context}\n\nQuestion: {q}", 
            max_tokens=RAG_MAX_TOKENS
        )
    except Exception as e:
        answer = f"LLM error: {e}"
    
    return {"question": q, "answer": answer, "sources": len(docs), "time_ms": round((time.time() - t0) * 1000, 1), "model": llm_name()}


@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest):
    sys_prompt = "\n".join(m.content for m in request.messages if m.role == "system").strip()
    user_prompt = "\n".join(m.content for m in request.messages if m.role in ("user", "assistant")).strip()
    if request.response_format and request.response_format.get("type") == "json_object":
        sys_prompt += "\n\nIMPORTANT: Respond with valid JSON only."
    try:
        answer = get_llm_response(sys_prompt, user_prompt, max_tokens=request.max_tokens)
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": request.model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": answer}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


# ── Items ─────────────────────────────────────────────────────────────────────
@app.post("/add-item")
async def add_item(request: AddItemRequest):
    t0 = time.time()
    try:
        vec = get_embedding(request.content)
    except Exception as e:
        return {"error": f"Embedding failed: {e}"}
    
    pid = str(uuid.uuid4())
    qdrant.upsert(COLLECTION, [PointStruct(id=pid, vector=vec, payload={
        "content": request.content,
        "appName": request.app_name or "Unknown",
        "contentType": request.content_type,
        "tags": request.tags,
        "title": request.title or "",
        "timestamp": time.time(),
        "isFavorite": request.is_favorite,
        "entities": [e["value"] for e in extract_entities(request.content)],
    })])
    return {"status": "ok", "point_id": pid, "time_ms": round((time.time() - t0) * 1000, 1)}


@app.post("/extract-entities")
async def extract_entities_endpoint(request: ExtractEntitiesRequest):
    entities = extract_entities(request.content)
    return {"entities": entities, "total": len(entities)}


@app.get("/collections")
async def list_collections():
    try:
        return {c.name: {"points": qdrant.get_collection(c.name).points_count} for c in qdrant.get_collections().collections}
    except Exception as e:
        return {"error": str(e)}


# ── Cognee ────────────────────────────────────────────────────────────────────
@app.get("/cognee-search")
async def cognee_search(q: str = Query(...), search_type: str = Query("CHUNKS")):
    if not COGNEE_OK:
        return {"error": "Cognee not installed"}
    t0 = time.time()
    try:
        result = await run_cognee_worker({"action": "search", "query": q, "search_type": search_type}, COGNEE_SEARCH_TIMEOUT)
        return {"query": q, "results": result["result"], "time_ms": round((time.time() - t0) * 1000, 1)}
    except Exception as e:
        return {"error": str(e), "time_ms": round((time.time() - t0) * 1000, 1)}


@app.post("/add-knowledge")
async def add_knowledge(request: AddKnowledgeRequest):
    if not COGNEE_OK:
        return {"error": "Cognee not installed"}
    t0 = time.time()
    try:
        await run_cognee_worker({"action": "add", "text": request.text}, COGNEE_ADD_TIMEOUT)
        await run_cognee_worker({"action": "cognify"}, COGNEE_COGNIFY_TIMEOUT)
        return {"status": "ok", "time_ms": round((time.time() - t0) * 1000, 1)}
    except Exception as e:
        return {"error": str(e), "time_ms": round((time.time() - t0) * 1000, 1)}


# ── Main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="127.0.0.1", port=8420, workers=1, reload=True)
