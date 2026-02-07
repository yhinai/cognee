#!/bin/bash
# ============================================================================
# Clippy AI — run.sh
# One command to launch everything:
#   Docker → Qdrant → Python Backend (Cognee + Qdrant + Distil Labs SLM) → Clippy.app
#
# Usage:
#   ./run.sh              Launch all services + Clippy.app
#   ./run.sh --no-app     Launch backend services only (skip Swift build)
#   ./run.sh --test       Launch services + run full pipeline test
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/clippy-backend"
MODELS_DIR="$SCRIPT_DIR/models"
PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/bin/python3.12}"

BACKEND_PORT=8420
QDRANT_PORT=6333

# Parse args
SKIP_APP=false
RUN_TEST=false
for arg in "$@"; do
    case "$arg" in
        --no-app)  SKIP_APP=true ;;
        --test)    RUN_TEST=true ;;
    esac
done

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log() { echo -e "${BLUE}[Clippy]${NC} $1"; }
ok()  { echo -e "${GREEN}  [OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[FAIL]${NC} $1"; }

# ── Cleanup on exit ─────────────────────────────────────────────────────────
cleanup() {
    echo ""
    log "Shutting down..."
    [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null && log "Stopped backend (PID $BACKEND_PID)"
    cd "$SCRIPT_DIR" && docker compose stop qdrant 2>/dev/null
    log "All services stopped."
    exit 0
}
trap cleanup INT TERM

echo ""
echo -e "${CYAN}${BOLD}==========================================${NC}"
echo -e "${CYAN}${BOLD}  Clippy AI — Full Stack Launcher${NC}"
echo -e "${CYAN}${BOLD}  Cognee + Qdrant + Distil Labs SLM${NC}"
echo -e "${CYAN}${BOLD}==========================================${NC}"
echo ""

# ── 1. Python ────────────────────────────────────────────────────────────────
if [ ! -f "$PYTHON_BIN" ]; then
    PYTHON_BIN=$(which python3.12 2>/dev/null || which python3.11 2>/dev/null || which python3 2>/dev/null)
fi
if [ -z "$PYTHON_BIN" ]; then
    err "Python 3.10+ not found. Install: brew install python@3.12"
    exit 1
fi
ok "Python: $($PYTHON_BIN --version 2>&1)"

# ── 2. Docker + Qdrant ──────────────────────────────────────────────────────
if curl -s "http://localhost:$QDRANT_PORT/healthz" > /dev/null 2>&1; then
    ok "Qdrant already running (port $QDRANT_PORT)"
else
    if ! command -v docker &>/dev/null; then
        err "Docker not found. Install: https://docker.com/products/docker-desktop"
        exit 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        log "Starting Docker Desktop..."
        open -a Docker 2>/dev/null
        for i in $(seq 1 30); do
            docker info &>/dev/null 2>&1 && break
            sleep 2
        done
        if ! docker info &>/dev/null 2>&1; then
            err "Docker daemon failed to start"
            exit 1
        fi
    fi
    log "Starting Qdrant (Docker)..."
    cd "$SCRIPT_DIR" && docker compose up -d qdrant 2>&1 | grep -v "^$"
    for i in $(seq 1 20); do
        curl -s "http://localhost:$QDRANT_PORT/healthz" > /dev/null 2>&1 && break
        sleep 1
    done
    if ! curl -s "http://localhost:$QDRANT_PORT/healthz" > /dev/null 2>&1; then
        err "Qdrant failed to start. Check: docker compose logs qdrant"
        exit 1
    fi
    ok "Qdrant ready (port $QDRANT_PORT)"
fi

# ── 3. Model files ──────────────────────────────────────────────────────────
EMBED_MODEL="$MODELS_DIR/nomic-embed-text/nomic-embed-text-v1.5.f16.gguf"
LLM_MODEL="$MODELS_DIR/cognee-distillabs-model-gguf-quantized/model-quantized.gguf"
LLM_FALLBACK="$MODELS_DIR/Qwen3-4B-Q4_K_M/Qwen3-4B-Q4_K_M.gguf"

if [ -f "$EMBED_MODEL" ]; then
    ok "Embed model: nomic-embed-text ($(du -sh "$EMBED_MODEL" | cut -f1))"
else
    err "Embedding model missing: $EMBED_MODEL"
    err "Run: ./download-models.sh"
    exit 1
fi

if [ -f "$LLM_MODEL" ]; then
    ok "LLM model:   Distil Labs SLM ($(du -sh "$LLM_MODEL" | cut -f1))"
elif [ -f "$LLM_FALLBACK" ]; then
    ok "LLM model:   Qwen3-4B fallback ($(du -sh "$LLM_FALLBACK" | cut -f1))"
    warn "Distil Labs SLM not found — using Qwen3-4B"
else
    err "No LLM model. Run: ./download-models.sh"
    exit 1
fi

# ── 4. Python venv + deps ───────────────────────────────────────────────────
cd "$BACKEND_DIR"
if [ ! -d "venv" ]; then
    log "Creating Python venv..."
    "$PYTHON_BIN" -m venv venv
fi
source venv/bin/activate

if ! python -c "import fastapi, qdrant_client, llama_cpp" 2>/dev/null; then
    log "Installing dependencies..."
    pip install -q -r requirements.txt 2>&1 | tail -3
fi

COGNEE_OK="no"
python -c "import cognee" 2>/dev/null && COGNEE_OK="yes"
ok "Dependencies ready (cognee: $COGNEE_OK)"

# ── 5. FastAPI backend ──────────────────────────────────────────────────────
if curl -s "http://localhost:$BACKEND_PORT/health" > /dev/null 2>&1; then
    ok "Backend already running (port $BACKEND_PORT)"
else
    log "Starting backend (loading GGUF models on Metal GPU)..."
    cd "$BACKEND_DIR"
    # Filter out harmless noisy messages from log
    uvicorn app:app --host 127.0.0.1 --port "$BACKEND_PORT" --workers 1 2>&1 \
        | grep -v "ggml_metal_init: skipping" \
        | grep -v "n_ctx_per_seq.*n_ctx_train" \
        | grep -v "Failed to import playwright" \
        | grep -v "multi-user access control mode" \
        > /tmp/clippy-backend.log &
    BACKEND_PID=$!

    for i in $(seq 1 45); do
        if curl -s "http://localhost:$BACKEND_PORT/health" > /dev/null 2>&1; then
            break
        fi
        [ $((i % 5)) -eq 0 ] && echo -ne "${BLUE}[Clippy]${NC} Loading models... ${i}s\r"
        sleep 1
    done
    echo ""

    if ! curl -s "http://localhost:$BACKEND_PORT/health" > /dev/null 2>&1; then
        err "Backend failed to start. Logs:"
        tail -20 /tmp/clippy-backend.log
        exit 1
    fi
    ok "Backend ready (port $BACKEND_PORT, PID $BACKEND_PID)"
fi

# ── 6. Print status ─────────────────────────────────────────────────────────
echo ""
HEALTH=$(curl -s "http://localhost:$BACKEND_PORT/health" 2>/dev/null)
echo -e "${CYAN}${BOLD}  Services:${NC}"
echo "$HEALTH" | python3 -c "
import sys, json
try:
    h = json.load(sys.stdin)
    for svc, ok in h.get('services', {}).items():
        icon = '\033[0;32m✓\033[0m' if ok else '\033[0;31m✗\033[0m'
        print(f'    {icon} {svc}')
    print()
    print('  \033[1mModels:\033[0m')
    for k, v in h.get('models', {}).items():
        print(f'    {k}: {v}')
    coll = h.get('collection', {})
    print(f'    qdrant: {coll.get(\"name\",\"?\")} ({coll.get(\"points\",0)} points)')
except: pass
" 2>/dev/null

echo ""
echo -e "${CYAN}${BOLD}  URLs:${NC}"
echo "    API docs:  http://localhost:$BACKEND_PORT/docs"
echo "    Qdrant:    http://localhost:$QDRANT_PORT/dashboard"
echo "    Health:    http://localhost:$BACKEND_PORT/health"
echo ""
echo -e "${CYAN}${BOLD}  Endpoints:${NC}"
echo "    GET  /search          Prefetch+RRF Fusion semantic search"
echo "    GET  /search/grouped  Group by appName or contentType"
echo "    GET  /discover        Discovery API (more/less like this)"
echo "    GET  /recommend       Recommend API"
echo "    GET  /filter          Payload-filtered search"
echo "    GET  /ask             RAG: retrieve + Distil Labs SLM answer"
echo "    GET  /cognee-search   Cognee graph-aware search"
echo "    POST /add-knowledge   Cognee add + cognify (OpenAI gpt-4o-mini)"
echo "    POST /add-item        Embed + upsert to Qdrant"
echo "    POST /extract-entities Entity extraction"

# ── 7. Optional: full pipeline test ─────────────────────────────────────────
if [ "$RUN_TEST" = true ]; then
    echo ""
    log "Running full pipeline test..."
    python3 -c "
import json, time, urllib.request

BASE = 'http://localhost:$BACKEND_PORT'
passed = 0; failed = 0

def test(method, path, body=None, label='', timeout=30):
    global passed, failed
    t0 = time.time()
    try:
        if body:
            data = json.dumps(body).encode()
            req = urllib.request.Request(f'{BASE}{path}', data=data, headers={'Content-Type':'application/json'})
        else:
            req = urllib.request.Request(f'{BASE}{path}')
        with urllib.request.urlopen(req, timeout=timeout) as r:
            result = json.loads(r.read())
            ms = round((time.time()-t0)*1000)
            print(f'  \033[0;32m✓\033[0m {label} ({ms}ms)')
            passed += 1
            return result
    except Exception as e:
        ms = round((time.time()-t0)*1000)
        print(f'  \033[0;31m✗\033[0m {label} ({ms}ms): {e}')
        failed += 1
        return None

test('GET',  '/health', label='Health check')
test('GET',  '/collections', label='Qdrant collections')
test('POST', '/add-item', {'content':'Test item','content_type':'text','app_name':'Test'}, 'Add item (embed+Qdrant)')
test('GET',  '/search?q=test&limit=2', label='Search (RRF Fusion)')
test('GET',  '/search/grouped?q=test&group_by=appName&limit=2', label='Grouped search')
test('GET',  '/filter?q=test&field=contentType&value=text&limit=2', label='Filtered search')
test('GET',  '/ask?q=What+is+a+test%3F&limit=2', label='RAG (Distil Labs SLM)')
test('POST', '/v1/chat/completions', {'model':'slm','messages':[{'role':'user','content':'Hi'}],'max_tokens':16}, 'OpenAI-compat endpoint')
test('POST', '/add-knowledge', {'text':'The Eiffel Tower is in Paris, France.'}, 'Cognee add+cognify')
test('GET',  '/cognee-search?q=Eiffel+Tower&search_type=CHUNKS', label='Cognee search')

print(f'\n  Results: {passed} passed, {failed} failed')
"
fi

# ── 8. Build & launch Clippy.app ────────────────────────────────────────────
if [ "$SKIP_APP" = false ] && [ -f "$SCRIPT_DIR/build-app.sh" ]; then
    echo ""
    log "Building and launching Clippy.app..."
    cd "$SCRIPT_DIR"
    bash build-app.sh &
    APP_PID=$!
    sleep 3
    ok "Clippy.app launched"
fi

echo ""
echo -e "${CYAN}${BOLD}  Press Ctrl+C to stop all services${NC}"
echo ""

wait
