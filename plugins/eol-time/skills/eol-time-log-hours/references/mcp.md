# EOL Time over MCP

- **Server:** `<base>/mcp`, streamable HTTP, JSON-RPC over POST, stateless (no session id). `<base>` is https://time.eol.agency.
- **Auth:** `Authorization: Bearer <key>`.
- **Headers:** send `Content-Type: application/json` and `Accept: application/json, text/event-stream`.

## Tools a time-only key can call

A time-only key's `tools/list` contains exactly these 16 tools. A call to any other tool is refused with HTTP 403 and JSON-RPC error `-32003`, `data.error: "agent_key_time_only"`.

| Tool | Arguments | Does |
|---|---|---|
| `eol.workspace.whoami` | none | Who am I, which workspace |
| `eol.project.list` | `search?` | Projects visible to me (same rows as REST `GET /api/v1/projects`) |
| `eol.task.list` | `project_id?`, `include_archived?` | With `project_id`, the project's task assignments (use `task_id`) |
| `eol.time.list` | `from`, `to` (YYYY-MM-DD) | My entries in a date range |
| `eol.time.create` | `project_id`, `work_date` and either `duration_minutes` or `started_time` + `ended_time` (required); `task_id`, `note`, `source_metadata`, `dry_run`, `idempotency_key` | Create an entry |
| `eol.time.update` | `id`, `project_id`, `work_date` and either `duration_minutes` or `started_time` + `ended_time` (required); `task_id`, `note`, `source_metadata`, `dry_run`, `idempotency_key` | Edit my entry |
| `eol.time.delete` | `id`; `dry_run`, `idempotency_key` | Delete my entry |
| `eol.timer.current` | none | My running timer, or `running: false` |
| `eol.timer.start` | `project_id` (or `timesheet_entry_id`), `task_id`, `note`, `work_date`, `dry_run`, `idempotency_key` | Start my timer (stops any other) |
| `eol.timer.stop` | `dry_run`, `idempotency_key` | Stop my timer |
| `eol.timesheet.list` | `from?`, `to?` | My timesheet submissions (weeks sent for approval), newest first |
| `eol.timesheet.submit` | `period_start?`; `dry_run`, `idempotency_key` | Submit my week for approval |
| `eol.timesheet.unsubmit` | `submission_id` or `period_start`; `dry_run`, `idempotency_key` | Take back my pending week |
| `eol.help.search` | `query`; `top_k?` | Search the in-app help (never reads account data) |
| `eol.feedback.submit` | `body` (up to 2000 characters); `dry_run`, `idempotency_key` | Send feedback to the EOL Time team |
| `eol.capabilities` | none | The tool catalog and the workspace's settings |

How results come back:

- **Tool results:** `result.content[0].text` is JSON `{"status": <inner HTTP status>, "data": <the REST body>}`. When the inner status isn't 2xx, `result.isError` is `true` and the outer HTTP status is still 200. Show `data.errors` or `data.error` to the user.
- **`dry_run: true`:** returns the request that would be sent and writes nothing.
- **`idempotency_key`:** returns the first result again for 24 hours. Use a fresh one per entry, so a retried call can't log the time twice.
- **Labels:** every MCP write is labelled `source: "mcp"`. `source_metadata` keeps only `tool` and `skill`.

## Checking the connection by hand (curl)

These are the raw JSON-RPC calls an MCP client makes. Use them to check a key works, or when you have a shell but no MCP client. Placeholders are the same as in [rest-api.md](rest-api.md). `MCP_ID` is any string or number that identifies the request.

Initialize:

```bash eol-request:mcp-initialize
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X POST "${EOL_TIME_URL:-https://time.eol.agency}/mcp" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2025-03-26" \
  -H "MCP-Method: initialize" \
  --data-binary @- <<'JSON'
{"jsonrpc": "2.0", "id": "MCP_ID", "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "eol-time-log-hours", "version": "1.0"}}}
JSON
```

The answer's `result.serverInfo.name` is `eol_time_mcp_server`.

List the tools:

```bash eol-request:mcp-tools-list
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X POST "${EOL_TIME_URL:-https://time.eol.agency}/mcp" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2025-03-26" \
  -H "MCP-Method: tools/list" \
  --data-binary @- <<'JSON'
{"jsonrpc": "2.0", "id": "MCP_ID", "method": "tools/list", "params": {}}
JSON
```

Find the project, then its tasks:

```bash eol-request:mcp-project-list
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X POST "${EOL_TIME_URL:-https://time.eol.agency}/mcp" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2025-03-26" \
  -H "MCP-Method: tools/call" \
  --data-binary @- <<'JSON'
{"jsonrpc": "2.0", "id": "MCP_ID", "method": "tools/call", "params": {"name": "eol.project.list", "arguments": {"search": "SEARCH"}}}
JSON
```

```bash eol-request:mcp-task-list
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X POST "${EOL_TIME_URL:-https://time.eol.agency}/mcp" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2025-03-26" \
  -H "MCP-Method: tools/call" \
  --data-binary @- <<'JSON'
{"jsonrpc": "2.0", "id": "MCP_ID", "method": "tools/call", "params": {"name": "eol.task.list", "arguments": {"project_id": PROJECT_ID}}}
JSON
```

Log the time, only after the user has confirmed it. `IDEMPOTENCY_KEY` is a fresh random string.

```bash eol-request:mcp-log-time
curl -sS -w '\nHTTP %{http_code} retry-after=%header{retry-after}\n' \
  -X POST "${EOL_TIME_URL:-https://time.eol.agency}/mcp" \
  -H "Authorization: Bearer $EOL_TIME_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2025-03-26" \
  -H "MCP-Method: tools/call" \
  --data-binary @- <<'JSON'
{"jsonrpc": "2.0", "id": "MCP_ID", "method": "tools/call", "params": {"name": "eol.time.create", "arguments": {"project_id": PROJECT_ID, "task_id": TASK_ID, "duration_minutes": MINUTES, "work_date": "WORK_DATE", "note": "NOTE", "source_metadata": {"tool": "claude", "skill": "eol-time-log-hours"}, "idempotency_key": "IDEMPOTENCY_KEY"}}}
JSON
```

Transport-level refusals come back as a JSON-RPC `error` with a non-200 HTTP status:

| HTTP | `error.code` | Meaning |
|---|---|---|
| 401 | none | Bad, expired or revoked key |
| 403 | -32003 | A time-only key called a tool outside its list, or the workspace is suspended |
| 403 | -32001 | The request carried a browser `Origin` the server doesn't allow |
| 404 | -32004 | MCP is switched off on this server |
| 429 | none | Rate limit; wait `Retry-After` seconds |
