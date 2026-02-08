"""
Clippy Backend Models — all Pydantic models in one place.
"""

from pydantic import BaseModel


# ─── Request Models ───────────────────────────────────────────────────────────

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


# ─── Response Helpers ─────────────────────────────────────────────────────────

def point_to_dict(point) -> dict:
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
