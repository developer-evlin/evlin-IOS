"""Every tool the chat assistant can call — see README.md for the list.

The model never writes. Each tool pre-fills one of the app's own
confirm-and-submit cards, or asks a question; the parent's tap on the card
is what creates anything. That keeps a misunderstood request at "wrong
draft shown", never "wrong thing done to a child's phone".

Adding a tool means adding one module here and listing it in _MODULES —
chat.py reads only what this package exports, so the tool set the model is
given, the prompt's description of it, and the replies can't drift apart.
"""
from tool_calls import ask_follow_up, draft_event, draft_task

_MODULES = (draft_task, draft_event, ask_follow_up)

# The declarations sent to the model, in this order.
TOOLS: list[dict] = [m.TOOL for m in _MODULES]

# What the assistant says while a tool's card does the rest.
REPLIES: dict[str, str] = {m.TOOL["name"]: m.REPLY for m in _MODULES if m.REPLY}
DEFAULT_REPLY = "Sure — let's set that up."

# Tools whose own argument is the reply (the question the model wrote).
SPEAKS_FOR_ITSELF: set[str] = {m.TOOL["name"] for m in _MODULES if getattr(m, "SPEAKS_FOR_ITSELF", False)}

NAMES: list[str] = [t["name"] for t in TOOLS]

# Tools that check their own draft before it becomes a card. Each takes
# (args, child_name, today) and returns a question to ask instead, or None
# when the draft is complete. The prompt asks the model not to guess a day;
# this is what holds it to that.
FOLLOW_UPS: dict = {m.TOOL["name"]: m.follow_up_for for m in _MODULES if hasattr(m, "follow_up_for")}
