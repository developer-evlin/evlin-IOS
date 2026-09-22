"""The one place that knows Gemini's actual wire format. Both Chat and
(later) Milestones-AI call generate() — neither knows or cares the other
exists; this module has no knowledge of either feature's own tables or
routes, just "give me a system prompt, a message history, and optionally
some tools, get back text or a function call."

Uses httpx (already a dependency) directly against the REST API rather
than a Google SDK — this project consistently avoids adding a dependency
for something a plain HTTP call already covers (see storage.py/R2 doing
the same thing via boto3's lower-level client, not a higher-level wrapper).
"""
import os
import httpx

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
_MODEL = "gemini-2.0-flash"
_BASE_URL = f"https://generativelanguage.googleapis.com/v1beta/models/{_MODEL}:generateContent"


def gemini_configured() -> bool:
    return bool(GEMINI_API_KEY)


class FunctionCall:
    def __init__(self, name: str, args: dict):
        self.name = name
        self.args = args


def _to_gemini_tools(tools: list[dict]) -> list[dict]:
    """tools: [{"name", "description", "parameters"}] (parameters already
    JSON-Schema-shaped, "OBJECT"/"STRING" etc.) -> Gemini's
    tools: [{"function_declarations": [...]}] wrapper."""
    return [{"function_declarations": tools}]


async def generate(
    system_prompt: str,
    messages: list[dict],
    tools: list[dict] | None = None,
) -> tuple[str | None, FunctionCall | None]:
    """messages: [{"role": "user"|"model", "text": "..."}] — the running
    conversation, oldest first. Returns (text, None) for a plain reply, or
    (None, FunctionCall) when the model calls one of `tools`. Raises on a
    real API/network failure — callers decide how to surface that (see
    routers/chat.py, which doesn't swallow it into a fake reply)."""
    if not GEMINI_API_KEY:
        raise RuntimeError("GEMINI_API_KEY is not configured")

    body: dict = {
        "system_instruction": {"parts": [{"text": system_prompt}]},
        "contents": [{"role": m["role"], "parts": [{"text": m["text"]}]} for m in messages],
    }
    if tools:
        body["tools"] = _to_gemini_tools(tools)

    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(f"{_BASE_URL}?key={GEMINI_API_KEY}", json=body)
        resp.raise_for_status()
        data = resp.json()

    candidates = data.get("candidates") or []
    if not candidates:
        # A real response with no candidates (e.g. blocked by safety
        # filters) — surface as a plain, honest reply rather than crashing
        # the caller on a KeyError.
        return "I couldn't come up with a reply to that — try rephrasing?", None

    parts = candidates[0].get("content", {}).get("parts") or []
    for part in parts:
        if "functionCall" in part:
            fc = part["functionCall"]
            return None, FunctionCall(name=fc["name"], args=fc.get("args", {}))
    text = "".join(p.get("text", "") for p in parts).strip()
    return (text or "..."), None
