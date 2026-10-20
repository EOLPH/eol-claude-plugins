---
name: eol-time-timer
description: Start, stop or check the user's running timer in EOL Time (time.eol.agency, EOL's Harvest replacement). Each person has one timer, and starting a new one stops the old one, so it warns first. Use when the user says start/stop/pause my timer, "what am I tracking", "how long have I been on this", or "start tracking a project" in EOL Time. For logging a finished block of time, use eol-time-log-hours instead.
compatibility: Needs network access to the EOL Time server and either the EOL Time MCP server or a shell with curl. The user supplies an API key in the EOL_TIME_API_KEY environment variable.
metadata:
  title: EOL Time timer
  version: "1.0"
---

# EOL Time timer

A person has **one** running timer across the whole app (web, mobile, desktop, MCP). A running timer **is** a time entry. Stopping it saves the elapsed time on that entry, so there is nothing else to log afterwards.

## Setup

- **MCP:** if you have the tools `eol.timer.current`, `eol.timer.start` and `eol.timer.stop`, use them.
- **REST:** otherwise use the curl calls below. They need `$EOL_TIME_API_KEY`. Check it with `test -n "$EOL_TIME_API_KEY" && echo set || echo missing`, and never print the key.
- **Neither:** the user mints a **Time tracking only** key at `https://time.eol.agency/settings/api-keys`, stores it in `EOL_TIME_API_KEY` and restarts Claude. The `eol-time-log-hours` skill's `references/setup.md` has the details.
- **Server:** `${EOL_TIME_URL:-https://time.eol.agency}`.

Each command prints a last line `HTTP <status> retry-after=<seconds>`.

## Check the timer

```bash eol-request:timer-current
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/timer" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

- **REST response:** `{ "current_timer": { "running", "timesheet_entry_id", "project_id", "project_name", "client_name", "task_id", "task_name", "note", "work_date", "timer_started_at", "duration_minutes", "elapsed_minutes", "elapsed_seconds" } }`. When nothing runs it's `{ "running": false, "timesheet_entry_id": null }`.
- **MCP:** `eol.timer.current` returns `{status, data: {current_timer: {...}}}` with `running`, `timesheet_entry_id`, `project_name`, `task_name`, `notes` and `elapsed_ms`.
- Tell the user in one line, e.g. "Running: Acme / Website redesign, Design, 'Hero variants', 0:42 so far", or "No timer running".

## Start a timer

**Step 1: find the project and task.** Never invent an id; use only ids from these responses.

```bash eol-request:list-projects
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/projects" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

```bash eol-request:list-project-tasks
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/projects/PROJECT_ID/project_tasks" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

- Match the user's words against the project's `name`, `code` and `client_name`.
- Use the task row's `task_id` (not `id`) and skip `archived: true` rows.
- **Ambiguous or no match:** list the candidates and ask.
- **MCP:** `eol.project.list` with `{"search": "..."}`, then `eol.task.list` with `{"project_id": ...}`.

**Step 2: check what's running** (above). If a timer is running, warn and wait for a yes:

> Your timer is running on **Acme / Website redesign** (0:42). Starting a new one stops it and saves 0:42 to that entry. Go ahead?

**Step 3: confirm** the project, task and note with the user, then start:

```bash eol-request:timer-start
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X POST "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/timer/start" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @- <<'JSON'
{"timer": {"project_id": PROJECT_ID, "task_id": TASK_ID, "note": "NOTE", "source_metadata": {"tool": "claude", "skill": "eol-time-timer"}}}
JSON
```

- `NOTE` is JSON-escaped (`\"`, `\\`, `\n`). `work_date` defaults to today in the user's own timezone; add `"work_date": "YYYY-MM-DD"` only if the user asks for another day.
- **MCP:** `eol.timer.start` with `{"project_id": ..., "task_id": ..., "note": "...", "idempotency_key": "<fresh random string>"}`.
- **Resume, not duplicate:** the same project, task, date and note resumes today's entry instead of making a second one.
- **Restart an existing entry:** send `"timesheet_entry_id": ENTRY_ID` instead of `project_id`.

**Step 4: report** from the response: `current_timer` (what's running now) and `stopped_timesheet_entry_id`. If that last field isn't null, the earlier timer was stopped and its time saved.

## Stop the timer

Stopping needs no id; it stops whatever is running.

```bash eol-request:timer-stop
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X POST "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/timer/stop" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

- **MCP:** `eol.timer.stop` with `{}`.
- **Report:** the response has `stopped_timer` with `project_name`, `task_name`, `note` and `duration_minutes` (the total saved on the entry). Show it as H:MM, e.g. "Stopped: Acme / Website redesign, Design, 1:05 saved to today".
- **Nothing running:** the server answers 200 with a notice and `current_timer.running: false`. Say so; it isn't an error.

## Errors

Show the server's message (`errors` or `error`) word for word.

- **401:** the key is bad, expired or revoked. Ask the user to mint a new one.
- **403 `agent_key_time_only`:** the call is outside a time key's scope.
- **404:** the project or entry isn't visible to the user.
- **422:**
  - "project required";
  - the user isn't assigned to the project;
  - the task isn't on the project, or is archived;
  - a timer is running in another workspace.

  Ask what to change.
- **429:** wait the `retry-after` seconds, then retry once.

While a timer runs, only its project, task and note can change. Its duration can't (422 "Stop the timer first").
