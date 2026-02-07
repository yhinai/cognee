#!/bin/bash
# ============================================================================
# Download GGUF models for Clippy Backend
# Models are saved to models/ (gitignored)
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/models"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[Models]${NC} $1"; }
ok()  { echo -e "${GREEN}[  OK  ]${NC} $1"; }
warn(){ echo -e "${YELLOW}[ WARN ]${NC} $1"; }

echo ""
echo "=========================================="
echo "  Clippy Model Downloader"
echo "=========================================="
echo ""

# Check for huggingface-cli or curl
HAS_HF=false
if command -v huggingface-cli &>/dev/null; then
    HAS_HF=true
fi

download_hf_file() {
    local repo="$1"
    local filename="$2"
    local output_dir="$3"
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
        local url="https://huggingface.co/$repo/resolve/main/$filename"
        curl -L -o "$output_file" "$url" --progress-bar
    fi

    if [ -f "$output_file" ]; then
        ok "$filename downloaded"
    else
        warn "Failed to download $filename"
    fi
}

# 1. nomic-embed-text (embedding model, ~260 MB)
log "1/3: nomic-embed-text (embedding model)"
download_hf_file \
    "nomic-ai/nomic-embed-text-v1.5-GGUF" \
    "nomic-embed-text-v1.5.f16.gguf" \
    "$MODELS_DIR/nomic-embed-text"

# 2. Distil Labs SLM (primary LLM)
log "2/3: Distil Labs SLM (primary LLM)"
download_hf_file \
    "distillabs/cognee-distillabs-gguf-quantized" \
    "model-quantized.gguf" \
    "$MODELS_DIR/cognee-distillabs-model-gguf-quantized"

# 3. Qwen3-4B (fallback LLM)
log "3/3: Qwen3-4B Q4_K_M (fallback LLM)"
download_hf_file \
    "unsloth/Qwen3-4B-GGUF" \
    "Qwen3-4B-Q4_K_M.gguf" \
    "$MODELS_DIR/Qwen3-4B-Q4_K_M"

echo ""
echo "=========================================="
echo "  Model Download Complete"
echo "=========================================="
echo ""
echo "  Models directory: $MODELS_DIR"
ls -lh "$MODELS_DIR"/*/*.gguf 2>/dev/null || warn "No .gguf files found"
echo ""
