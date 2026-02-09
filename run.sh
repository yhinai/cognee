#!/bin/bash
# ============================================================================
# Clippy AI — run.sh (single entry point)
#
# Usage:
#   ./run.sh                   Launch all services + Clippy.app
#   ./run.sh --debug           Launch all + Clippy.app in debug mode (logs visible)
#   ./run.sh --test            Launch services + run full pipeline test
#   ./run.sh --no-app          Backend services only (skip Swift build)
#   ./run.sh --download        Download GGUF models only
#   ./run.sh --build           Build Clippy.app only (no backend)
#   ./run.sh --stop            Stop all services
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"
MODELS_DIR="$SCRIPT_DIR/models"
BUILD_DIR="$SCRIPT_DIR/build"
PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/bin/python3.12}"

BACKEND_PORT=8420
QDRANT_PORT=6333

# ── Parse args ─────────────────────────────────────────────────────────────
SKIP_APP=false
RUN_TEST=false
DEBUG_MODE=false
CMD_DOWNLOAD=false
CMD_BUILD=false
CMD_STOP=false
SWIFT_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --no-app)     SKIP_APP=true ;;
        --test)       RUN_TEST=true ;;
        --debug|-d)   DEBUG_MODE=true ;;
        --download)   CMD_DOWNLOAD=true ;;
        --build)      CMD_BUILD=true ;;
        --stop)       CMD_STOP=true ;;
        --swift-only) SWIFT_ONLY=true ;;
        --help|-h)
            echo "Usage: ./run.sh [OPTIONS]"
            echo ""
            echo "  (no args)     Launch all: Docker, Qdrant, backend, Clippy.app"
            echo "  --debug, -d   Launch all + run Clippy.app with visible logs"
            echo "  --test        Launch services + run 10-endpoint pipeline test"
            echo "  --no-app      Backend services only, skip Swift build"
            echo "  --download    Download GGUF models (nomic-embed-text, Distil Labs SLM, Qwen3-4B)"
            echo "  --build       Build Clippy.app only (no backend)"
            echo "  --stop        Stop all services (backend, Qdrant)"
            echo "  --swift-only  Swift-only mode: Qdrant + Clippy.app (no Python backend)"
            echo "  --help, -h    Show this help"
            exit 0
            ;;
    esac
done

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log() { echo -e "${BLUE}[Clippy]${NC} $1"; }
ok()  { echo -e "${GREEN}  [OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[FAIL]${NC} $1"; }

# ═══════════════════════════════════════════════════════════════════════════
# --stop: kill everything and exit
# ═══════════════════════════════════════════════════════════════════════════

if [ "$CMD_STOP" = true ]; then
    log "Stopping all services..."
    killall -9 Clippy 2>/dev/null && log "Stopped Clippy.app" || true
    pkill -f "uvicorn app:app" 2>/dev/null && log "Stopped backend" || true
    cd "$SCRIPT_DIR" && docker compose stop qdrant 2>/dev/null && log "Stopped Qdrant" || true
    ok "All services stopped."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# --download: download GGUF models
# ═══════════════════════════════════════════════════════════════════════════

download_models() {
    echo ""
    echo -e "${CYAN}${BOLD}  Clippy AI — Model Downloader${NC}"
    echo ""

    local HAS_HF=false
    command -v huggingface-cli &>/dev/null && HAS_HF=true

    download_hf_file() {
        local repo="$1" filename="$2" output_dir="$3"
        local output_file="$output_dir/$filename"
        mkdir -p "$output_dir"

        if [ -f "$output_file" ]; then
            ok "$filename already exists"
            return 0
        fi

        log "Downloading $filename from $repo..."
        if $HAS_HF; then
            huggingface-cli download "$repo" "$filename" --local-dir "$output_dir"
        else
            curl -L -o "$output_file" "https://huggingface.co/$repo/resolve/main/$filename" --progress-bar
        fi

        [ -f "$output_file" ] && ok "$filename downloaded" || warn "Failed to download $filename"
    }

    log "1/3: nomic-embed-text (embedding model)"
    download_hf_file "nomic-ai/nomic-embed-text-v1.5-GGUF" "nomic-embed-text-v1.5.f16.gguf" "$MODELS_DIR/nomic-embed-text"

    log "2/3: Distil Labs SLM (primary LLM)"
    download_hf_file "distillabs/cognee-distillabs-gguf-quantized" "model-quantized.gguf" "$MODELS_DIR/cognee-distillabs-model-gguf-quantized"

    log "3/3: Qwen3-4B Q4_K_M (fallback LLM)"
    download_hf_file "unsloth/Qwen3-4B-GGUF" "Qwen3-4B-Q4_K_M.gguf" "$MODELS_DIR/Qwen3-4B-Q4_K_M"

    echo ""
    ok "Models directory: $MODELS_DIR"
    ls -lhL "$MODELS_DIR"/*/*.gguf 2>/dev/null || warn "No .gguf files found"
    echo ""
}

if [ "$CMD_DOWNLOAD" = true ]; then
    download_models
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# --build: build Swift app only
# ═══════════════════════════════════════════════════════════════════════════

build_app() {
    killall -9 Clippy 2>/dev/null || true

    log "Building Clippy.app..."
    xcodebuild -project "$SCRIPT_DIR/Clippy.xcodeproj" \
               -scheme Clippy \
               -destination 'platform=macOS,arch=arm64' \
               -configuration Debug \
               SYMROOT="$BUILD_DIR" \
               CODE_SIGN_IDENTITY="" \
               CODE_SIGNING_REQUIRED=NO \
               CODE_SIGNING_ALLOWED=NO \
               -quiet

    if [ $? -ne 0 ]; then
        err "Build failed"
        return 1
    fi
    ok "Build succeeded"
    return 0
}

launch_app() {
    local app_path="$BUILD_DIR/Debug/Clippy.app"
    if [ ! -d "$app_path" ]; then
        err "App not found at $app_path"
        return 1
    fi

    if [ "$DEBUG_MODE" = true ]; then
        log "Launching Clippy.app (DEBUG — logs below)..."
        "$app_path/Contents/MacOS/Clippy"
    else
        open "$app_path"
        ok "Clippy.app launched"
    fi
}

if [ "$CMD_BUILD" = true ]; then
    build_app && launch_app
    exit $?
fi

# ═══════════════════════════════════════════════════════════════════════════
# Default: full-stack launch
# ═══════════════════════════════════════════════════════════════════════════

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

# ── 1. Python ──────────────────────────────────────────────────────────────
if [ ! -f "$PYTHON_BIN" ]; then
    PYTHON_BIN=$(which python3.12 2>/dev/null || which python3.11 2>/dev/null || which python3 2>/dev/null)
fi
if [ -z "$PYTHON_BIN" ]; then
    err "Python 3.10+ not found. Install: brew install python@3.12"
    exit 1
fi
ok "Python: $($PYTHON_BIN --version 2>&1)"

# ── 2. Docker + Qdrant ────────────────────────────────────────────────────
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

# ── 3. Model files (auto-download if missing) ─────────────────────────────
# Note: GGUF models are only used by Python backend (llama-cpp-python)
# Swift uses MLX models which are downloaded separately by LocalAIService
if [ "$SWIFT_ONLY" = true ]; then
    ok "Swift-only mode: skipping GGUF model check (using MLX models)"
else
    EMBED_MODEL="$MODELS_DIR/nomic-embed-text/nomic-embed-text-v1.5.f16.gguf"
    LLM_MODEL="$MODELS_DIR/cognee-distillabs-model-gguf-quantized/model-quantized.gguf"
    LLM_FALLBACK="$MODELS_DIR/Qwen3-4B-Q4_K_M/Qwen3-4B-Q4_K_M.gguf"

    if [ ! -f "$EMBED_MODEL" ] || { [ ! -f "$LLM_MODEL" ] && [ ! -f "$LLM_FALLBACK" ]; }; then
        warn "Models missing — downloading automatically..."
        download_models
    fi

    if [ -f "$EMBED_MODEL" ]; then
        ok "Embed model: nomic-embed-text ($(du -shL "$EMBED_MODEL" | cut -f1))"
    else
        err "Embedding model missing. Run: ./run.sh --download"
        exit 1
    fi

    if [ -f "$LLM_MODEL" ]; then
        ok "LLM model:   Distil Labs SLM ($(du -shL "$LLM_MODEL" | cut -f1))"
    elif [ -f "$LLM_FALLBACK" ]; then
        ok "LLM model:   Qwen3-4B fallback ($(du -shL "$LLM_FALLBACK" | cut -f1))"
        warn "Distil Labs SLM not found — using Qwen3-4B"
    else
        err "No LLM model. Run: ./run.sh --download"
        exit 1
    fi
fi

# ── 4. Python venv + deps ─────────────────────────────────────────────────
if [ "$SWIFT_ONLY" = true ]; then
    ok "Swift-only mode: skipping Python backend"
else
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
fi

# ── 5. FastAPI backend ────────────────────────────────────────────────────
if [ "$SWIFT_ONLY" = true ]; then
    ok "Swift-only mode: skipping FastAPI backend (using native MLX)"
elif curl -s "http://localhost:$BACKEND_PORT/health" > /dev/null 2>&1; then
    ok "Backend already running (port $BACKEND_PORT)"
else
    log "Starting backend (loading GGUF models on Metal GPU)..."
    cd "$BACKEND_DIR"
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

# ── 6. Print status ───────────────────────────────────────────────────────
echo ""
if [ "$SWIFT_ONLY" = true ]; then
    echo -e "${CYAN}${BOLD}  Swift-Only Mode Active${NC}"
    echo "    ✓ Qdrant:      http://localhost:$QDRANT_PORT"
    echo "    ✓ Local AI:    MLX (Qwen2.5-1.5B + Qwen3-Embedding)"
    echo "    ✗ Python:      Disabled"
else
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
fi

# ── 7. Optional: pipeline test ─────────────────────────────────────────────
if [ "$RUN_TEST" = true ]; then
    if [ "$SWIFT_ONLY" = true ]; then
        warn "Pipeline tests require Python backend. Skipping in Swift-only mode."
    else
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
            json.loads(r.read())
            ms = round((time.time()-t0)*1000)
            print(f'  \033[0;32m✓\033[0m {label} ({ms}ms)')
            passed += 1
    except Exception as e:
        ms = round((time.time()-t0)*1000)
        print(f'  \033[0;31m✗\033[0m {label} ({ms}ms): {e}')
        failed += 1

test('GET',  '/health', label='Health check')
test('GET',  '/collections', label='Qdrant collections')
test('POST', '/add-item', {'content':'Test item','content_type':'text','app_name':'Test'}, 'Add item (embed+Qdrant)')
test('GET',  '/search?q=test&limit=2', label='Search (RRF Fusion)')
test('GET',  '/search/grouped?q=test&group_by=appName&limit=2', label='Grouped search')
test('GET',  '/filter?q=test&type_filter=text&limit=2', label='Filtered search')
test('GET',  '/ask?q=What+is+a+test%3F&limit=2', label='RAG (Distil Labs SLM)')
test('POST', '/v1/chat/completions', {'model':'slm','messages':[{'role':'user','content':'Hi'}],'max_tokens':16}, 'OpenAI-compat endpoint')
test('POST', '/add-knowledge', {'text':'The Eiffel Tower is in Paris, France.'}, 'Cognee add+cognify')
test('GET',  '/cognee-search?q=Eiffel+Tower&search_type=CHUNKS', label='Cognee search')

print(f'\n  Results: {passed} passed, {failed} failed')
"
    fi
fi

# ── 8. Build & launch Clippy.app ──────────────────────────────────────────
if [ "$SKIP_APP" = false ]; then
    echo ""
    build_app || exit 1
    if [ "$DEBUG_MODE" = true ]; then
        launch_app
    else
        launch_app &
        APP_PID=$!
        sleep 2
    fi
fi

echo ""
echo -e "${CYAN}${BOLD}  Press Ctrl+C to stop all services${NC}"
echo ""

wait
