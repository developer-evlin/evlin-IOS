"""ask_follow_up — ask before drafting.

Asking is a tool rather than a line in the prompt ("ask if you're unsure"),
so the model has to commit to it. It opens no card and offers no suggested
answers: tappable answers turn an open question into multiple choice and
put the model back to guessing. The parent answers by typing.
"""

TOOL = {
    "name": "ask_follow_up",
    "description": (
        "Ask the parent for one thing you need before you can draft something. Use this when a request "
        "doesn't say what the task or event actually is, or when a detail you'd otherwise have to invent "
        "is missing. A drafted card with a made-up title is worse than a question."
    ),
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "question": {"type": "STRING", "description": "One short question. Ask for a single thing, not several."},
        },
        "required": ["question"],
    },
}

# The question the model wrote *is* the reply; a canned line in front of it
# would only be noise.
REPLY = None
SPEAKS_FOR_ITSELF = True
