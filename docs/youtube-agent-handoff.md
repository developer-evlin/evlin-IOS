# YouTube agent: handoff from the chat side

For whoever is building the YouTube agent. Written 2026-10-07 by the session
that owns chat (`routers/chat.py`, `tool_calls/`). It covers how the YouTube
agent should plug into chat, what the database has today, and what it's
missing. Code that already exists is linked; everything else is a
proposal for you to decide on.

## How it should behave

> **Update (later on 2026-10-07):** the chat side of the handoff is now
> built. The parent switches to the YouTube agent with the "Find YouTube
> videos" tile or the play button by the text field, and the agent gets its
> own short session memory. See "What's built now" below; it replaces the
> handoff tool and contract sketched further down.

The parent talks to one chat. When a request is about videos, chat hands it
to the YouTube agent **inside the same thread**:

1. Parent: "She loves dinosaurs, find her a few videos."
2. The chat model calls a handoff tool with a short brief (topic, count,
   anything the parent specified). Chat stops there.
3. The YouTube agent runs its own loop: search, hard filter, look at
   results, search again, rank. The parent sees it working in the thread
   (a status line per step is enough).
4. It finishes with a **proposal** posted into the thread as a card. The
   parent approves or dismisses it there.
5. The next parent message goes back to the **main chat agent**. The
   YouTube agent has no conversation of its own; each run starts fresh and
   ends with its proposal.

The chat model only ever sees a one-line summary of a run in its history
(for example `[YouTube agent proposed 3 dinosaur videos — parent approved 2]`),
never the agent's steps or reasoning. That keeps chat's context and cost flat.

## What's built now (use this, not the contract below)

- `chat_messages.agent` is `'chat'` or `'youtube'` (with a migration and an
  `_EXPECTED_COLUMNS` entry). The app sends `"agent": "youtube"` while
  YouTube mode is on, and labels the agent's replies "YouTube agent".
- `POST /children/{id}/chat` with `agent: "youtube"` saves the parent's
  message and calls **your** entry point:

  ```python
  # evlin-backend/youtube_agent/__init__.py
  async def respond(db, child, context: agent_sessions.AgentContext, now) -> list[tuple[str, str | None, dict | None]]:
      ...  # (text, tool_call, tool_args) per message, first one carries the text
  ```

  Until that package exists, the parent gets "The YouTube agent isn't set
  up yet…". Each returned entry becomes a stored message with
  `agent='youtube'`; cards render through `ScreenChat.cardFor` (add yours
  there). `tool_args` values are stored as strings, like chat's.
- **Your memory** is `agent_sessions.youtube_context(db, conversation_id)`,
  given to you as `context`:
  - `messages`: the current YouTube session only. A session ends at a
    main-chat message or a pause over 2 hours. It's always the session's
    first request, plus at least the last 3 exchanges, plus older turns
    while they fit about 1,500 tokens. Ready to pass to `generate_all`.
  - `latest_card`: your newest card's `(tool_call, tool_args)` in this
    session, even after its message has left the window ("the second one").
  - `session_length`, `session_started_at`.

  The reasoning is in the module docstring of `agent_sessions.py`.
- **Isolation, both ways:** main chat never sees YouTube turns, and
  YouTube turns don't feed chat's long-term memory (`memory.py`). What
  should carry across sessions (approved and rejected videos, blocked
  channels) belongs in your own tables, looked up per turn.
- Not done yet, and yours if you want it: a one-line summary of a YouTube
  session in main chat's history; recording the parent's decision on your
  cards.

## What chat already does, and what it expects from you

As of today:
- Chat has **no** video tools, cards or context. `draft_video_queue` was
  removed from `tool_calls/`.
- The chat system prompt currently tells the parent that videos are in the
  Library tab. That's a placeholder: when your handoff tool exists, it
  replaces that line ([chat.py](../evlin-backend/routers/chat.py), "Videos
  belong to the YouTube agent").
- The model is sent the newest 50 messages of a thread (`HISTORY_WINDOW`).
- One model reply can contain several tool calls, each becoming its own
  card; a question (`ask_follow_up`) wins over cards. See `_replies` in
  chat.py.
- `generate_all()` in [gemini_client.py](../evlin-backend/gemini_client.py)
  isn't tied to chat; use it. It returns every function call in a reply but
  does **not** yet support sending tool results back to the model, which a
  loop needs. Add that there (function-response turns) rather than writing
  a second client.

The contract I'd suggest:

| Piece | Owner | Shape |
|---|---|---|
| Handoff tool `hand_to_youtube_agent` | you write it in `tool_calls/`, I'll wire the prompt | args: `brief` (string), `count` (int). Returns no card; the server starts a run and stores a chat message pointing at it |
| Starting a run | you | `start_run(db, child, conversation_id, brief) -> run_id`, called from chat's `_replies` |
| Run progress and result in the thread | you (backend) + iOS `ScreenChat.cardFor` | a chat message with `tool_call="youtube_agent"` and `tool_args={"run_id": ...}`; the card reads the run |
| Summary line back to chat's history | you provide `summary_for(run) -> str` | chat puts it in place of the card's text when building history |

## Database review

### What exists

| Table | What it holds | Notes |
|---|---|---|
| `child_video_profiles` | per-child settings: allowed categories, blocked keywords, allowed/blocked channels, daily minutes, max video length | Settings sheet (`LibrarySettingsSheet.swift`) reads and writes it |
| `video_queue_items` | one approved video per child per day, with a metadata snapshot and `watched_seconds` | Only a parent's approval writes it. **Nothing in the app writes to it at the moment**, and its docstring still mentions the chat card, which is gone |

Supporting code: `video_filter.py` (hard filters, pure functions),
`video_curation.py` (search + filter + one ranking call), `youtube_client.py`,
`routers/videos.py`. None of it is used by chat any more; it's yours.

### What the Library UI needs that the database doesn't have

The Library UI (`ScreenLibrary.swift`, `ScreenTabletLibrary.swift`) runs on
`LibrarySampleData.swift`: **bundles** of videos, three per child, one video
per bundle per day, with progress through each bundle. Progress is kept in
memory on one device, so the parent's phone and the kid's iPad don't share it.
None of that is in the database:

1. **Bundles and their videos.** Suggested:
   - `video_bundles` (id, child_id, name, subject, ages, why, created_by_run_id, created_at)
   - `video_bundle_items` (bundle_id, position, video_id, title, channel_id, channel_title, thumbnail_url, duration_seconds)

   I've made bundles per child rather than a shared catalog on purpose:
   CLAUDE.md lists shared course content as removed, and per-child bundles
   built by the agent avoid bringing it back.
2. **The child's shelf.** `child_bundles` (child_id, bundle_id, slot 0–2, added_at, removed_at). Swapping a bundle ends one row and starts another.
3. **Progress.** `bundle_progress` (child_id, bundle_id, finished_count, last_finished_local_date). Compute "done today" on read by comparing `last_finished_local_date` with the child's local date (`blocks.local_now`). Never store it, per the "reads must not write" rule.
4. **Agent runs.** `youtube_agent_runs`:
   - who and where: id, child_id, conversation_id, chat_message_id
   - what: brief, status (`running` / `needs_review` / `approved` / `dismissed` / `cancelled` / `failed`), proposal (JSON), parent_decision (JSON: which items were kept or removed), error
   - cost: input_tokens, thinking_tokens, output_tokens
   - when: started_at, finished_at

   A run stuck at `running` after a deploy should be **reported** as failed on read once it's older than a couple of minutes, not rewritten by a job.
5. **Step log** (debugging only, no UI, per CLAUDE.md): `youtube_agent_steps` (run_id, n, tool, args JSON, result_summary, tokens, created_at).

### Problems I found

- **Category mismatch.** The backend's categories (`video_filter.CATEGORIES`) include `mindful`; the iOS `LibrarySubject` has `calm` instead. The other seven match. Pick one before bundles store a subject.
- **Made-for-kids against the sample shelf.** `video_filter.filter_candidates` drops anything YouTube doesn't flag as made for kids. The sample shelf is Kurzgesagt, which isn't flagged, so the agent could never produce the shelf the UI was designed around. `allowed_channels` currently only boosts ranking ("preferred") and doesn't get past that filter. Whether a parent-trusted channel should get past it is a safety decision for the user, not the agent.
- **Live updates won't reach the chat.** `live_updates._SILENT` excludes `ChatMessage` and `ChatConversation`, and `ScreenChat` doesn't listen to live updates at all. A result posted into the thread by a background run would stay invisible until the parent reopens the thread. Leave chat messages silent; announce **run** rows instead (they're child-scoped, so the commit hook will pick them up if the model isn't in `_SILENT`), and have the chat screen refresh its open thread when a run it shows changes.
- **Migrations.** Every new table and column needs a statement in `main.py` `_MIGRATIONS` and an entry in `_EXPECTED_COLUMNS`. `tests/test_migrations.py` catches a missing one. Postgres-only SQL must be checked on a real Postgres.

## Rules that apply (from CLAUDE.md)

- **The AI never writes.** The agent's tools search and propose; the parent's tap writes. Approving a proposal should go through **one** function that writes the bundles, shelf or queue items, the way task approval goes through `_review`.
- **Reads must not write**; expiry and "today" are computed on read.
- **"Today" is the child's**, from `blocks.local_now`.
- **Every child-scoped route checks ownership** through `access.py`.
- **No screen for AI internals** (steps, reasoning, memory) unless the user asks.

## Cancelling

- A parent can stop a running run from its card: set `status=cancelled`. The loop checks the status before each step and exits. Cancel its asyncio task too, so in-flight requests to Gemini and YouTube are dropped.
- Nothing needs undoing, because nothing was written.
- A cancelled or dismissed run teaches nothing: no memory from it, and chat's summary line says it was cancelled.

## Open decisions for the user

1. `mindful` or `calm`.
2. Whether parent-trusted channels can get past the made-for-kids filter.
3. Whether the YouTube agent reads chat's memory facts (`memory.facts_for`). I'd say read-only yes; its own learning goes in `parent_decision` on runs.
4. Whether the parent can also start a run from the Library tab, without chat.
