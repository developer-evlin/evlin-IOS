# Tool calls

The tools the chat assistant can use. There's no calendar (removed
2026-10-28), so no event tool. It has exactly three, one file each:

| Tool | File | What it does | Card it opens |
|---|---|---|---|
| `draft_task` | [draft_task.py](draft_task.py) | Assigns a task: title, emoji, instructions, date, time, recurrence, whether it gates apps, bonus minutes | Add Task |
| `draft_app_block` | [draft_app_block.py](draft_app_block.py) | Blocks one app for a length of time, matched to Evlin's catalog, with a one-line reason | Block an app |
| `ask_follow_up` | [ask_follow_up.py](ask_follow_up.py) | Asks one question when a request is too vague to draft | None; the question is the message |

**The model never writes.** Every tool pre-fills a card; the parent's tap is
what creates the task or block.

To add a tool, add a module with `TOOL` and `REPLY` (and
`SPEAKS_FOR_ITSELF = True` if its argument is the reply), list it in
`_MODULES` in [`__init__.py`](__init__.py), handle its card in the app
(`ScreenChat.cardFor`), and update this table.

The model can call several tools in one reply ("piano at 5 and block YouTube
for an hour"); each becomes its own card, in order. If it also asks a
question, only the question is shown.

A tool whose draft can be incomplete exports
`follow_up_for(args, child_name, today) -> str | None`. When it returns a
question, the server asks that instead of showing any card. `draft_task`
asks when a one-off has no day, so the model can't quietly pick a date. `today` is the
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
`routers/chat.py`): one leading emoji for what it's doing (📝 a task, ⛔ a
block, ❓ a question, 💡 a suggestion) and a task's emoji beside its name,
never a row of them.

A task the parent types gets one on the phone when it's created
(`Evlin/Data/EmojiSuggest.swift`: Unicode's own emoji names and keywords,
plus chore synonyms); renaming it re-guesses unless the agent picked it.
Parents never see the emoji, only the kid's list does. The server only
checks it's a single emoji (`schemas.TaskCreate`).

## Blocking apps is by time, not by task

When a parent blocks an app, the block lasts **for a set time**: 30
minutes, an hour, a custom length, the rest of the child's day, or with
no end time until the parent lifts it. It is not attached to a task.
Screen time is already earned through tasks (the task gate and bonus
minutes); a block is a separate, plain control a parent sets by the clock.

What this means for any agent, this one or a future one:
- Don't suggest or draft a block that waits on a task ("no YouTube until
  homework is done"). Offer a length of time instead.
- Say a block's length the way the app does: "for 1 hour", "until 9:00 PM",
  "no end time". Not "until you lift it".
- Two ways in, one result: the child's screen time page, Blocked apps → Add
  (`Parent/AddBlockedAppsSheet.swift`), and this assistant's
  `draft_app_block` card (`Parent/AppBlockCards.swift`). Both use the same
  length picker and save, as `duration` or `indefinite` blocks
  (`routers/app_blocks.py`). The server still accepts `until_task` and
  `scheduled` blocks from older builds; nothing new makes them.

### `draft_app_block`

One card per app. The server matches what the parent typed ("yt",
"insta") to Evlin's catalog (`match_app`: name or alias, else the one app
whose name contains it, never a guess between two). If the app isn't in the
catalog, or no app was named, it asks instead of drafting; if it's already
blocked, it says so. When the parent gave no length, the model picks one
from what they said and the time where the child is, and its `reason`
sentence introduces the card. The parent can change the app or the length
before tapping Block. The "Block an app" tile asks "Which app should I block
for …, and for how long?" without calling the model (`block_app` shortcut).

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
