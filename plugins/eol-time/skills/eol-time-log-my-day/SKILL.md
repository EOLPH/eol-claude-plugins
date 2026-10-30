---
name: eol-time-log-my-day
description: Log a whole day to EOL Time (time.eol.agency, EOL's Harvest replacement) from one message. The user describes what they worked on in plain words with a rough total; Claude splits it across the user's own projects and tasks, shows a table, and creates the entries only after a yes. Works in the Claude desktop app and claude.ai with the EOL Time connector, and in Claude Code. Use when the user says log my day, log today, here is what I did today, fill in my timesheet for today or yesterday, or answers the daily EOL Time reminder email.
compatibility: Needs the EOL Time MCP server (the eol-time Claude plugin, or the connector set up in Help). An eol_time_ (time tracking only) key is enough.
metadata:
  title: Log my day in EOL Time
  version: "1.0"
---

# Log my day in EOL Time

The user tells you about a finished day in one message ("about 7 hours: the Acme homepage most of the morning, a client call, then admin"). You turn it into timesheet entries on their own projects and tasks. This goes straight to entries; it doesn't use the To sort tray. You write the signed-in user's own time only, and nothing is saved until they say yes.

## 1. Check setup

- **Tools:** `eol.workspace.whoami`, `eol.project.list`, `eol.task.list`, `eol.task.types`, `eol.time.list` and `eol.time.create` (Claude Code shows them as `mcp__<server>__…`). No tools: walk the user through Help → **Log your hours with Claude**, or use the `eol-time-log-hours` skill's REST path.
- Never print, echo or paste a key. If the user pastes one into the chat, tell them to revoke it at Settings → API keys and make a new one.

Each MCP result is JSON text `{"status": <http status>, "data": {...}}`; `data` is the REST body.

## 2. Work out the day

- **Date:** today in the user's local time unless they say otherwise ("yesterday", "Monday" → `YYYY-MM-DD`). Say which date you used.
- **Total:** take the rough total they give. With none, ask once ("About how many hours in all?").
- **Already logged:** `eol.time.list` with `{"from": "DATE", "to": "DATE"}`. If the day has entries, show them with their total and ask whether the new time is on top. Never log the same work twice.
- **Captured time:** if you have `eol.capture.blocks`, call it with `{"from": "DATE", "to": "DATE"}`. If that day has unsorted blocks, say so and offer to sort them instead (the `eol-time-sort-my-time` skill); that time is already recorded.

## 3. Split it across their projects and tasks

1. `eol.workspace.whoami` gives the user's id. `eol.project.list` (with `{"search": "words"}` for each thing they named); keep projects whose `teamMembers` include that id. Match their words against `name`, `code` and `client_name`.
2. `eol.task.list` with `{"project_id": ID}` for each project; send the row's `task_id`, skip `archived`. One task: use it. Otherwise match their words, or ask.
3. Several matches or none for something they named: show up to 10 candidates as `Client / Project (code)` and ask. Never invent an id or put time on a project they aren't on.
4. **Minutes:** use the times they gave. Where they gave none ("most of the morning", "a bit of admin"), split the rest of the total sensibly and say these are estimates. Whole minutes; rows add up to the total.
5. **Task type** (optional): `eol.task.types`. Offer the names once; send one only when the user picks it or named it ("call" → Meeting only if they agree). Never guess.
6. **Note:** a short plain line per row from their own words. Leave out anything that doesn't belong on a timesheet.

Show the table and wait for a yes:

> **Thursday 2026-10-29**, 7:00 in all:
>
> | Project | Task | Type | Time | Note |
> |---|---|---|---|---|
> | Acme / Website redesign | Development | | 4:00 | Homepage build |
> | Acme / Website redesign | Meetings | Meeting | 1:00 | Client call |
> | Internal | Admin | | 2:00 | Admin and email |
>
> Log these 3 entries? (2:00 on Admin is an estimate.)

Change anything the user asks, then show the table again.

## 4. Save

`eol.time.create` once per row, in order, each with a fresh `idempotency_key`:

```json
{"project_id": 12, "task_id": 34, "duration_minutes": 240, "work_date": "2026-10-29", "note": "Homepage build", "source_metadata": {"tool": "claude", "skill": "eol-time-log-my-day"}, "idempotency_key": "<a fresh random string>"}
```

Add `"task_type": "Meeting"` only when one was picked. Stop at the first error and say which rows were saved and which weren't. Then report each saved `entry` (`project`, `task_name`, `duration` as H:MM, `note`) and the day's new total.

## When the server says no

Show the server's own message word for word, and don't retry with changed data unless the user asks.

| Status | Meaning | Do |
|---|---|---|
| 401 | Key missing, wrong, expired or revoked | The user makes a new key |
| 403 | Not allowed (a locked or approved week, or a role that can't track time) | Show the message |
| 422 | A rule refused it: not on the project, task not on the project, task type not on the list, locked period, notes required | Show the message and ask what to change |
| 429 | Rate limit | Wait the `Retry-After` seconds, then retry once |

Checking and submitting the week is the `eol-time-my-week` skill; one entry at a time is `eol-time-log-hours`.
