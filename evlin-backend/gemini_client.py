"""The one place that knows Gemini's actual wire format. Chat and memory
extraction call generate(); this module has no knowledge of either
feature's own tables or routes, just "give me a system prompt, a message history, and optionally
some tools, get back text or a function call."

Uses httpx (already a dependency) directly against the REST API rather
than a Google SDK — this project consistently avoids adding a dependency
for something a plain HTTP call already covers (see storage.py/R2 doing
the same thing via boto3's lower-level client, not a higher-level wrapper).
"""
import os
import httpx

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
# The rolling alias, not a pinned version: the previously hardcoded
# "gemini-2.0-flash" was retired by Google and every call started 404ing
# with "no longer available". The alias tracks whatever the current flash
# model is, so that breakage can't recur on the next rotation.
_MODEL = os.getenv("GEMINI_MODEL", "gemini-flash-latest")
_BASE_URL = f"https://generativelanguage.googleapis.com/v1beta/models/{_MODEL}:generateContent"

# How hard the model thinks before answering. Its default thought for
# 200-2,000 tokens per reply, billed as output, and was most of the time a
# parent waited. "low", measured on the chat cases (9 kinds, 27 runs): all
# still right, thinking down 50-80%, about 1.7 s faster per reply. Every
# caller here — chat, memory, video ranking — is a short, bounded decision.
# Set GEMINI_THINKING_LEVEL="" to send nothing and get the model's default,
# e.g. for a model that doesn't accept a level.
_THINKING_LEVEL = os.getenv("GEMINI_THINKING_LEVEL", "low")


def request_body(system_prompt: str, messages: list[dict], tools: list[dict] | None = None) -> dict:
    """The generateContent request, in Gemini's wire format."""
    body: dict = {
        "system_instruction": {"parts": [{"text": system_prompt}]},
        "contents": [{"role": m["role"], "parts": [{"text": m["text"]}]} for m in messages],
    }
    if tools:
        body["tools"] = _to_gemini_tools(tools)
    if _THINKING_LEVEL:
        body["generationConfig"] = {"thinkingConfig": {"thinkingLevel": _THINKING_LEVEL}}
    return body


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
    (None, FunctionCall) when the model calls one of `tools` — the first,
    if it called several (generate_all keeps them all). Raises on a
    real API/network failure — callers decide how to surface that (see
    routers/chat.py, which doesn't swallow it into a fake reply)."""
    text, calls = await generate_all(system_prompt, messages, tools)
    return (None, calls[0]) if calls else (text, None)


async def generate_all(
    system_prompt: str,
    messages: list[dict],
    tools: list[dict] | None = None,
) -> tuple[str | None, list[FunctionCall]]:
    """generate(), keeping every function call in the reply. The model
    calls a tool once per item when it's asked for several things at once
    ("piano at 5 and tidy her room on Saturday"), so a caller that can
    show several cards needs all of them, in order."""
    if not GEMINI_API_KEY:
        raise RuntimeError("GEMINI_API_KEY is not configured")

    body = request_body(system_prompt, messages, tools)

    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(f"{_BASE_URL}?key={GEMINI_API_KEY}", json=body)
        resp.raise_for_status()
        data = resp.json()

    candidates = data.get("candidates") or []
    if not candidates:
        # A real response with no candidates (e.g. blocked by safety
        # filters) — surface as a plain, honest reply rather than crashing
        # the caller on a KeyError.
        return "I couldn't come up with a reply to that — try rephrasing?", []

    parts = candidates[0].get("content", {}).get("parts") or []
    calls = [FunctionCall(name=p["functionCall"]["name"], args=p["functionCall"].get("args", {}))
             for p in parts if "functionCall" in p]
    if calls:
        return None, calls
    text = "".join(p.get("text", "") for p in parts).strip()
    return (text or "..."), []
