"""
Clippy Backend Configuration — all settings in one place.
"""

import os

# Paths
BASE_DIR = os.path.dirname(__file__)
REPO_ROOT = os.path.abspath(os.path.join(BASE_DIR, ".."))
MODELS_DIR = os.path.join(REPO_ROOT, "models")
DATA_DIR = os.path.join(REPO_ROOT, ".data")
COGNEE_DATA_DIR = os.path.join(DATA_DIR, "cognee")
ENV_PATH = os.path.join(DATA_DIR, ".env")

EMBED_MODEL_PATH = os.path.join(MODELS_DIR, "nomic-embed-text", "nomic-embed-text-v1.5.f16.gguf")
LLM_MODEL_PATH = os.path.join(MODELS_DIR, "cognee-distillabs-model-gguf-quantized", "model-quantized.gguf")
LLM_FALLBACK_PATH = os.path.join(MODELS_DIR, "Qwen3-4B-Q4_K_M", "Qwen3-4B-Q4_K_M.gguf")

# Qdrant
QDRANT_URL = os.getenv("QDRANT_URL", "http://localhost:6333")
COLLECTION = "clippy_items"
VECTOR_DIM = 768

# Server
BACKEND_PORT = 8420

# Timeouts (seconds)
COGNEE_ADD_TIMEOUT = 60
COGNEE_COGNIFY_TIMEOUT = 180
COGNEE_SEARCH_TIMEOUT = 30

# Limits
DEFAULT_SEARCH_LIMIT = 20
MAX_SEARCH_LIMIT = 100
RAG_CONTEXT_LIMIT = 5
RAG_MAX_TOKENS = 80
