# Tool calls

The tools the chat assistant can use. It has exactly three, one file each:

| Tool | File | What it does | Card it opens |
|---|---|---|---|
| `draft_task` | [draft_task.py](draft_task.py) | Assigns a task: title, emoji, instructions, date, time, recurrence, whether it gates apps, bonus minutes | Add Task |
| `draft_event` | [draft_event.py](draft_event.py) | Puts something on the child's calendar: title, date, start/end, recurrence | Add Event |
| `ask_follow_up` | [ask_follow_up.py](ask_follow_up.py) | Asks one question when a request is too vague to draft | None; the question is the message |

**The model never writes.** Every tool pre-fills a card; the parent's tap is
what creates the task or event.

To add a tool, add a module with `TOOL` and `REPLY` (and
`SPEAKS_FOR_ITSELF = True` if its argument is the reply), list it in
`_MODULES` in [`__init__.py`](__init__.py), handle its card in the app
(`ScreenChat.cardFor`), and update this table.

The model can call several tools in one reply ("piano at 5 and the dentist
on Thursday"); each becomes its own card, in order. If it also asks a
question, only the question is shown.

A tool whose draft can be incomplete exports
`follow_up_for(args, child_name, today) -> str | None`. When it returns a
question, the server asks that instead of showing any card. `draft_task`
asks when a one-off has no day, and `draft_event` asks when there's no day
or start time, so the model can't quietly pick a date. `today` is the
child's local date.

## Emoji

Every task has one emoji (`tasks.icon`), shown beside it on the kid's
phone. When the assistant drafts a task it picks it (`draft_task`'s
`emoji`), from all of Unicode:

> Pick the single emoji a 6-12 year old would instantly read as this task:
> the object or the action itself, not a mood or a face. As specific as
> possible (🦷 brushing teeth, 🧦 sorting socks, 🐠 feeding the fish, 🎻
> violin practice). ⭐ only when nothing fits. Exactly one emoji, no words.

Its replies use emoji the way Notion's assistant does (the system prompt in
`routers/chat.py`): one leading emoji for what it's doing (📝 a task, 📅 an
event, ❓ a question, 💡 a suggestion) and a task's emoji beside its name,
never a row of them.

A task the parent types gets one on the phone when it's created
(`Evlin/Data/EmojiSuggest.swift`: Unicode's own emoji names and keywords,
plus chore synonyms); renaming it re-guesses unless the agent picked it.
Parents never see the emoji, only the kid's list does. The server only
checks it's a single emoji (`schemas.TaskCreate`).

## Removed

Not available to the assistant any more:

- `generate_course`, `draft_special_task`: vetted YouTube courses. The
  course feature was removed. Videos now live in the Library, which has
  no assistant yet (a dedicated Library Agent is planned, separate from
  this one).
- `propose_reflection`: reflections were built on courses and went with them.
- `draft_app_block`, `draft_lift_block`: app blocking stays in the app (the
  "Block an app" card and Lift on the child's profile), but the assistant
  no longer drafts blocks.
