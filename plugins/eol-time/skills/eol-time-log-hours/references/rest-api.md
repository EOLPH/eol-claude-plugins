# EOL Time REST calls for logging hours

Every call takes the time-only key as a bearer token and sends and receives JSON. Copy the commands as written and replace only the UPPERCASE placeholders:

| Placeholder | Value |
|---|---|
| `PROJECT_ID` | A project `id` from the project list |
| `TASK_ID` | A `task_id` from that project's task list |
| `MINUTES` | Whole minutes |
| `WORK_DATE`, `FROM`, `TO` | Dates as `YYYY-MM-DD` |
| `ENTRY_ID` | An entry `id` |
| `NOTE` | The note, JSON-escaped: `\"` for a quote, `\\` for a backslash, `\n` for a new line |

The body goes through a quoted heredoc (`<<'JSON'`), so apostrophes and `$` in a note need no shell escaping.

The last line of the output is `HTTP <status> retry-after=<seconds>`. `retry-after` is only filled in on a 429.

## Who am I

```bash eol-request:whoami
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/users/_me" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

You get `{ "user": { "id", "first_name", "last_name", "email", ... }, "company": { "id", "name", "project_billing_mode", ... }, "company_role": ... }`.

## List projects

```bash eol-request:list-projects
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/projects" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

- The response is `{ "projects": [ { "id", "name", "code", "client_id", "client_name", "billable", "archived", "teamMembers": [{ "id", "name" }], ... } ], "clients": [...], "total_count" }`.
- Only active projects are listed.
- To narrow the list, append `?search_term=WORDS`, URL-encoded.

## List a project's tasks

```bash eol-request:list-project-tasks
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/projects/PROJECT_ID/project_tasks" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

- The response is `{ "project_tasks": [ { "id", "project_id", "task_id", "task_name", "billable", "archived" } ], "total_count" }`.
- Write **`task_id`** into the entry, not `id`.
- Rows with `archived: true` can't be tracked to.

## Create an entry

```bash eol-request:create-entry
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X POST "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/cli/timesheet_entries" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @- <<'JSON'
{"timesheet_entry": {"project_id": PROJECT_ID, "task_id": TASK_ID, "duration_minutes": MINUTES, "work_date": "WORK_DATE", "note": "NOTE", "source_metadata": {"tool": "claude", "skill": "eol-time-log-hours"}}}
JSON
```

- **200** returns `{ "notice", "entry": { "id", "project", "project_id", "client", "duration", "note", "work_date", "task_id", "task_name", "billable", "billing_warnings", "source", "source_label", ... } }`.
- `duration` is in minutes.
- Leave `task_id` out only when the project has no tasks.
- Don't send `bill_status` or `billable`. Billability is derived from the project and task, and a sent value is dropped with a warning.
- With approvals on, the entry also carries `approval_status`, `approval_locked` and `period_locked`.

## Read entries back

```bash eol-request:list-entries
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/timesheet_entry?from=FROM&to=TO" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

- The response is `{ "entries": { "YYYY-MM-DD": [ { "id", "duration", "note", "project", "project_id", "client", "task_id", "task_name", "billable", "timer_running", ... } ] }, "holiday_infos", "leave_types" }`.
- Entries are grouped by date. Rows with `"type": "leave"` are time off, not entries.

One entry:

```bash eol-request:show-entry
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/timesheet_entry/ENTRY_ID" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

## Edit or delete an entry

Edit (own entries only). Send all three of `project_id`, `duration_minutes` and `work_date` every time, even when they don't change; a missing one fails the save.

```bash eol-request:update-entry
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X PATCH "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/cli/timesheet_entries/ENTRY_ID" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @- <<'JSON'
{"timesheet_entry": {"project_id": PROJECT_ID, "task_id": TASK_ID, "duration_minutes": MINUTES, "work_date": "WORK_DATE", "note": "NOTE"}}
JSON
```

Delete (own entries only):

```bash eol-request:delete-entry
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X DELETE "${EOL_TIME_URL:-https://time.eol.agency}/api/v1/cli/timesheet_entries/ENTRY_ID" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY"
```

You can't change the duration of an entry whose timer is running (422 "Stop the timer first"). Entries that are approved or inside a locked period are refused for non-admins.

## Error bodies

| Status | Body |
|---|---|
| 401 | `{ "error": "..." }` |
| 403 | `{ "errors": "..." }`, or `{ "error": "This API key is limited to time tracking", "code": "agent_key_time_only" }` |
| 404 | `{ "errors": "..." }` |
| 422 | `{ "errors": "<first validation message>" }` |
| 429 | `{ "error": "Too many requests. Please try again later." }`, plus a `Retry-After` header in seconds |
