---
name: eol-time-sort-my-time
description: Sort the user's captured Claude Code time (the To sort tray in EOL Time, time.eol.agency, EOL's Harvest replacement) into timesheet entries. Lists the unsorted blocks by day with their folders, branches and commit subjects, suggests a split across the user's own projects and tasks, and saves it only after a yes. Also removes or restores blocks and turns time capture on, off, paused or resumed. Use when the user asks to sort, review or clear their unsorted or captured time or their To sort tray, when a session note says there is unsorted time from yesterday, or says turn on, turn off, pause or resume time capture in EOL Time.
compatibility: Needs the EOL Time MCP server (the eol-time Claude plugin sets it up). An eol_time_ (time tracking only) key is enough. Capture itself needs the plugin's hooks in Claude Code; sorting works from any Claude with the connector.
metadata:
  title: Sort my captured time in EOL Time
  version: "1.0"
---

# Sort my captured time in EOL Time

When capture is on, the eol-time plugin records **when** the user works in Claude Code (times, folder names, git branch and commit subjects only; never code, prompts or replies). That time waits in the user's **To sort** tray until it is sorted into timesheet entries. Unsorted time never counts as hours anywhere. Only the user sees their tray; never sort, remove or read anyone else's. Nothing is saved, removed or changed until the user has said yes.

## 1. Check setup

- **Tools:** `eol.capture.blocks`, `eol.capture.sort`, `eol.capture.remove`, `eol.capture.restore`, `eol.capture.settings`, plus `eol.workspace.whoami`, `eol.project.list`, `eol.task.list`, `eol.task.types` and `eol.time.list` (Claude Code shows them as `mcp__<server>__…`).
- **No capture tools:** the plugin or the server is older. The user updates the plugin (`/plugin marketplace update eol`, then restart Claude Code). Without the MCP server, the same tray is on the **To sort** page in EOL Time (under Time Tracking).
- Never print, echo or paste a key. If the user pastes one into the chat, tell them to revoke it at Settings → API keys and make a new one.

Each MCP result is JSON text `{"status": <http status>, "data": {...}}`; `data` is the REST body.

## 2. Read the tray

`eol.capture.blocks` with no arguments lists the last 14 days, unsorted (or pass `from` / `to` as `YYYY-MM-DD`, up to 62 days). `data.days` has one row per day with blocks: `date`, `logged_minutes` and `blocks`. Each block has `id`, `started_at`, `ended_at`, `minutes`, `folders` (`name`, `minutes`), `branches`, `commits`, `flags` and `suggestion`. `data.unsorted_minutes` is the total.

Show it per day, times in the user's local time and lengths as H:MM:

| Block | Time | Length | Folders | Branch, commits |
|---|---|---|---|---|
| 1 | 09:12 to 11:40 | 2:28 | eol-web 2:00, docs 0:28 | feature/tray: "Add tray page" |

- `flags` `long` (over 4 hours) or `night` (time between 22:00 and 06:00): mark the block **check this**. Never drop or trim it yourself; ask.
- `logged_minutes` above zero: add "Already logged H:MM this day" under that day.
- Nothing unsorted: say so and stop.

## 3. Suggest a split

For each day the user wants to sort, build rows of **project, task, task type (optional), minutes, note**:

1. **Projects and tasks the user is on, only.** `eol.project.list` (rows whose `teamMembers` include the user's id from `eol.workspace.whoami`), then `eol.task.list` with `{"project_id": ID}` for the task (send its `task_id`, skip `archived`). Never invent an id.
2. **Start from the block's `suggestion`** (the project, task and task type last chosen for that folder). With none, match the folder name, branch and commit subjects against project names, codes and clients. Still nothing: the user's most recent project and task (`eol.time.list` for the last week), or ask.
3. **Split by folder minutes** when a block's folders belong to different projects. Round each row to whole minutes.
4. **Don't double the day.** If the day already has `logged_minutes`, say how much and ask whether the captured time is on top of it or partly the same work; trim the rows if it is.
5. **Task type:** `eol.task.types`. Offer the names once; send one only when the user picks it (or the suggestion carried one). Never guess.
6. **Note:** one short plain line from the commit subjects or folder, e.g. "Tray page and docs". No file names or paths.

Show the plan, one table per day, and the day's total against the captured total (they may differ; the user can add reading time or trim):

> **2026-10-29**: captured 3:10, already logged 1:00
>
> | Project | Task | Type | Time | Note |
> |---|---|---|---|---|
> | Acme / Website redesign | Development | Coding | 2:30 | Tray page |
> | Internal | Admin | | 0:40 | Docs |
>
> Save these 2 entries (3:10) and mark blocks 1 and 2 sorted?

Wait for a yes. Change anything the user asks, then show the table again.

## 4. Save

One `eol.capture.sort` call **per day** (blocks must share a date):

```json
{"block_ids": [101, 102], "rows": [{"project_id": 12, "task_id": 34, "task_type": "Coding", "minutes": 150, "note": "Tray page"}, {"project_id": 7, "task_id": 9, "minutes": 40, "note": "Docs"}], "idempotency_key": "<a fresh random string>"}
```

Leave out `task_type` when none was picked. Report from `data`: how many entries (`entry_ids`) and blocks (`blocks_sorted`). The entries are normal timesheet entries on that date; they can be edited on the timesheet like any other.

| Answer | Means | Do |
|---|---|---|
| 409 `blocks_changed` | New activity changed the blocks since you listed them | List again, show the new blocks, confirm again |
| 422 `mixed_dates` | Blocks from two days in one call | One call per day |
| 422 other | An entry rule refused a row (not on the project, task not on the project, task type not on the list, locked week) | Show the message; nothing was saved |
| 403 | The key or role can't log time | Show the message |

## 5. Remove and restore

- **Remove** (time that wasn't work, or already logged by hand): confirm the exact blocks, then `eol.capture.remove` with `{"block_ids": [...]}`. Removed blocks can be restored for 30 days.
- **Restore:** `eol.capture.blocks` with `{"status": "removed"}` lists them; confirm, then `eol.capture.restore` with `{"block_ids": [...]}`.

## 6. Capture settings

`eol.capture.settings` with no arguments reads them: `enabled`, `paused`, `idle_minutes`, `ignored_folders`, `time_zone`.

- "Turn on / turn off time capture": `{"enabled": true}` or `{"enabled": false}`. Before turning it on, say what is recorded: times, folder names, git branch and commit subjects, never code or conversation, and only the user sees it.
- "Pause / resume time capture": `{"paused": true}` or `{"paused": false}`. It applies on every computer; while paused, activity is ignored.
- "Ignore the folder X": read the list first, then send the whole list with X added as `ignored_folders`.
- Idle limit: `{"idle_minutes": N}`, 5 to 60 (default 15). A gap this long ends a block.

Confirm each change in one line first, then report the settings that come back.

## Errors and anything else

Show the server's message word for word. 401: the key is bad, expired or revoked; the user makes a new one. 429: wait the `Retry-After` seconds, then retry once. How-to questions: `eol.help.search`. Submitting the week is the `eol-time-my-week` skill; a day described in words (no captured time) is `eol-time-log-my-day`.
