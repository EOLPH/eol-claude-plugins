---
name: eol-time-log-hours
description: Log hours to EOL Time (time.eol.agency, EOL's Harvest replacement) for the user. Finds the project and task, confirms date, duration and note, then creates the time entry over the EOL Time MCP server or the REST API with a time-tracking-only API key. Use when the user asks to log, record, add or track time or hours in EOL Time, or to turn what they did today (this conversation, git commits) into a timesheet entry.
compatibility: Needs network access to the EOL Time server and either the EOL Time MCP server or a shell with curl. The user supplies an API key in the EOL_TIME_API_KEY environment variable.
metadata:
  title: Log hours in EOL Time
  version: "1.1"
---

# Log hours in EOL Time

You write time entries for the signed-in user only, never for anyone else (a manager logging for a teammate uses the `eol-time-approvals` skill). Nothing is written until the user has confirmed it.

## 1. Check setup

- **MCP path:** if you have tools named `eol.project.list`, `eol.task.list` and `eol.time.create` (Claude Code shows them as `mcp__<server>__…`), use them and skip the shell checks.
- **REST path:** otherwise check the key is present without printing it:

  ```bash
  test -n "$EOL_TIME_API_KEY" && echo "EOL_TIME_API_KEY is set" || echo "EOL_TIME_API_KEY is missing"
  ```

- If neither works, stop and walk the user through [references/setup.md](references/setup.md). Don't continue until they're done.

### Key rules

- Never print, echo, log, paste or write the key anywhere. That includes files, commits and chat.
- A key's start shows its access: `eol_time_` is time tracking only, `eol_full_` is everything the user can do. Keys made before 2026-10-20 have no prefix.
- Always refer to it as `$EOL_TIME_API_KEY`. If the user pastes a key into the chat, tell them to revoke it at `<base>/settings/api-keys` and mint a new one.
- The server is `${EOL_TIME_URL:-https://time.eol.agency}`. Every command below already falls back to production, so only set `EOL_TIME_URL` for another server, such as https://time-dev.eol.agency.

## 2. Work out what to log

Get four things from the user: **date**, **duration**, **project (and task)** and **note**.

- **Date:** default to today in the user's local time (`date +%F`). Turn "yesterday" or "Monday" into `YYYY-MM-DD`.
- **Duration:** send whole minutes. Examples: "1.5h" is `90`, "1:15" is `75`, "45m" is `45`. Don't round it yourself; the workspace applies its own rounding on reports and invoices.
- **Clock times** ("9 to 11:30", "from 2pm until 4"): over MCP, send `started_time` and `ended_time` (e.g. `"9:00am"` and `"11:30am"`, or `"14:30"`) instead of `duration_minutes`, never both and never only one; the server works out the duration. Say which you read ("9:00am to 11:30am, 2:30"). The response's `clock_times` is `stored`, or `duration_only` when the workspace keeps durations only; say so then. Over REST, send the minutes.
- **Note:** use one or two plain sentences about the work. Leave out secrets, keys and customer data that doesn't belong on a timesheet.
- **"Log what I did today":** you may draft the note and a duration estimate from this conversation and from `git log --since=midnight --author="$(git config user.email)" --oneline`. Present it as a draft; the user confirms or edits it.

## 3. Find the project and task (never invent an id)

1. List the projects the user can see.
   - REST: `GET /api/v1/projects` (curl in [references/rest-api.md](references/rest-api.md#list-projects)).
   - MCP: `eol.project.list` with `{"search": "<words>"}`.
   - Rows carry `id`, `name`, `code`, `client_name`, `archived` and `teamMembers` (`[{id, name}]`).
2. Match the user's words against `name`, `code` and `client_name`, ignoring case.
   - Prefer projects whose `teamMembers` include the user's own id (`GET /api/v1/users/_me`, `user.id`). They can't log to a project they aren't on unless they're an owner or admin.
   - **Exactly one match:** use it.
   - **Several matches or none:** show up to 10 candidates as `Client / Project (code)` and ask. Don't guess.
3. List that project's tasks.
   - REST: `GET /api/v1/projects/<id>/project_tasks`.
   - MCP: `eol.task.list` with `{"project_id": <id>}`.
   - Skip rows with `archived: true`.
   - Write the row's **`task_id`**, not its `id`.
   - **One task:** use it. **The user named one:** match on `task_name`. **Otherwise:** ask, listing the task names.
   - The task decides whether the time is billable, so don't skip it when the project has tasks.

Use only ids that came back from these calls in this session.

## 4. Confirm, then write

1. Show the user one line and wait for a yes:

   > Log **1:30** on **2026-10-20** to **Acme / Website redesign**, task **Design**, note "Homepage hero variants". OK?

2. Create the entry.
   - **REST:** `POST /api/v1/cli/timesheet_entries` (exact curl in [references/rest-api.md](references/rest-api.md#create-an-entry)).
   - **MCP:** `eol.time.create` with:

     ```json
     {"project_id": 123, "task_id": 45, "duration_minutes": 90, "work_date": "2026-10-20", "note": "Homepage hero variants", "source_metadata": {"tool": "claude", "skill": "eol-time-log-hours"}, "idempotency_key": "<a fresh random string>"}
     ```

     An MCP tool result is JSON text `{"status": <http status>, "data": {...}}`. `data` is the same body REST returns.
3. Report back from the response's `entry`:
   - `id`, `project`, `task_name`, `work_date` and `note`;
   - `duration` (minutes; show it as H:MM);
   - any `billing_warnings`.

   Don't claim anything the response didn't say.

Log several entries one at a time, each confirmed, or confirm the whole list once and then write them in order. Stop at the first error.

## 5. When the server says no

Show the server's own message (`errors` or `error`) to the user word for word. Don't retry a refused write with changed data unless the user tells you to.

| Status | Meaning | What to do |
|---|---|---|
| 401 | Key missing, wrong, expired or revoked | Ask the user to mint a new key (setup.md) |
| 403 `agent_key_time_only` | The key is time-only and this isn't time tracking (expenses, approvals and reports need an `eol_full_` key) | Stay within this skill's calls |
| 403 `errors` | Not allowed, e.g. a locked or approved entry, or a book keeper (who can't track time) | Show the message |
| 404 | Project, task or entry not visible to the user | Re-list, then ask the user |
| 422 | A write rule refused it, e.g. "not assigned to this project", task not on the project, archived task, period locked, or a timer still running on that entry | Show the message and ask what to change |
| 429 | Rate limit (about 120 requests a minute, 30 writes per 10 s per key) | Wait the `Retry-After` seconds (the curl line prints `retry-after=`), then retry once |

Editing or deleting an entry you just wrote: [references/rest-api.md](references/rest-api.md#edit-or-delete-an-entry), or MCP `eol.time.update` / `eol.time.delete`. Confirm with the user first.

For a running stopwatch rather than a finished block of time, use the `eol-time-timer` skill. To review the week and submit it for approval (a time-tracking key can), use `eol-time-my-week`. Expenses are `eol-time-expenses`.
