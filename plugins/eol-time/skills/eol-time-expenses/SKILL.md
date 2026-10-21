---
name: eol-time-expenses
description: Log, list, show and edit the user's own expenses in EOL Time (time.eol.agency, EOL's Harvest replacement). Finds the project and the expense category, handles unit-priced categories such as mileage, the date, billable and notes, and confirms before it saves. Receipts can't be uploaded this way. Needs an eol_full_ API key. Use when the user asks to log, add, record, claim, check, change or fix an expense, mileage, a receipt amount or a reimbursement in EOL Time.
compatibility: Needs network access to the EOL Time server and the EOL Time MCP server (the eol-time Claude plugin sets it up) with a full-access (eol_full_) API key.
metadata:
  title: Log and edit expenses in EOL Time
  version: "1.0"
---

# Log and edit expenses in EOL Time

You write expenses for the signed-in user only. Nothing is saved or changed until the user has confirmed it. Edit only expenses the user filed themselves.

## 1. Check access first

- **Tools:** `eol.expense.categories`, `eol.expense.list`, `eol.expense.show`, `eol.expense.create`, `eol.expense.update` and `eol.project.list` (Claude Code shows them as `mcp__<server>__…`). This skill has no REST path.
- **Key:** expenses need a **full-access** key (`eol_full_…`). A time-tracking key (`eol_time_…`) gets 403 `agent_key_time_only` (MCP: HTTP 403, JSON-RPC error -32003). Tell the user plainly: make a Full access key at Settings → API keys and configure the plugin with it (`/plugin` → `eol-time` → configure). Never print, echo or paste a key.
- **Module on?** `eol.capabilities` `workspace_settings.modules.expenses` (or `expenses_enabled` in the `eol.expense.categories` answer) says whether expenses are switched on in the workspace. If they're off, say so and stop.
- **Receipts:** there is no upload here. After saving, tell the user to attach the receipt to the expense in the app (Expenses).

Each MCP result is JSON text `{"status": <http status>, "data": {...}}`; `data` is the REST body.

## 2. Work out the expense

Get these from the user:

- **Project:** `eol.expense.list` returns `data.projects`, the projects the user may file on (assigned ones; owners and admins any), each with `id`, `name`, `client_name`, `currency` and `billable_by_default`. Match the user's words on `name` and `client_name` (`eol.project.list` with `{"search": "..."}` also matches `code`). One match: use it. Several or none: show up to 10 as `Client / Project (code)` and ask. Never invent an id.
- **Category:** `eol.expense.categories` returns `data.expense_categories` (`id`, `name`, `unit_based`, `unit_name`, `unit_price`). Match the user's words to a `name`. Ambiguous: list the names and ask. Send `expense_category_id`; if a category has no `id`, send its name as `category_name`.
- **Amount or units:**
  - A unit-based category (`unit_based: true`, e.g. Mileage): ask for the **units** (e.g. 42 miles) and send `units`, not `amount`. The total is units × the category's price; show it as that sum.
  - Any other category: the **amount** in the project's `currency`.
- **Date:** default to today in the user's local time; turn "yesterday" or "Friday" into `YYYY-MM-DD`.
- **Billable:** leave it out to take the project's default (`billable_by_default`). Set it only when the user says billable or not billable.
- **Notes:** a short plain description (`description`). Optional `vendor_name`. Leave out card numbers and anything that doesn't belong on an expense report.

## 3. Confirm, then save

1. One line, then wait for a yes:

   > Log **42 miles** of **Mileage** (42 × 0.70 = 29.40 USD) on **2026-10-20** to **Acme / Website redesign**, billable, note "Client workshop drive". OK?

2. `eol.expense.create` with, for example:

   ```json
   {"project_id": 123, "expense_category_id": 7, "units": 42, "date": "2026-10-20", "description": "Client workshop drive", "idempotency_key": "<a fresh random string>"}
   ```

   Add `"billable": true/false` only if the user chose. For an amount-based category send `amount` instead of `units`.
3. Report from `data.expense`: `id`, `date`, `project_name`, `category_name`, `units` and `unit_name` or `amount`, `currency`, `billable` and `status`. Remind them about the receipt.

Log several expenses one at a time, each confirmed, or confirm the whole list once and save them in order. Stop at the first error.

## 4. List and show

- **List:** `eol.expense.list` (optional `{"query": "words"}`). `data.expenses` rows carry `id`, `date`, `category_name`, `amount`, `currency`, `description`, `project_name`, `client_name`, `billable`, `approval_status`, `locked_reason` and `submitter_name`. Managers also see their people's expenses; show and edit only the user's own unless they ask to read others.
- **One expense:** `eol.expense.show` with `{"id": EXPENSE_ID}` for full detail.

Show a short table: date, project, category, amount (or units), billable, status.

## 5. Edit

1. `eol.expense.show` first. If `locked_reason` is set, or `approval_status` is `approved` or `invoiced` is true, it can't be changed: say why. Otherwise the server decides; a submitted expense can usually still be edited until it is approved.
2. Show the before and after on one line and wait for a yes.
3. `eol.expense.update` with `{"id": EXPENSE_ID, ...only the changed fields..., "idempotency_key": "..."}`. The field names are the same as for create (`amount` or `units`, `date`, `project_id`, `expense_category_id`, `billable`, `description`).
4. Report the saved values from the response.

There is no delete here; the user deletes an expense in the app.

## 6. Submitting

Expenses go for approval together with the week's time. Use the `eol-time-my-week` skill to submit the week.

## Errors and anything else

Show the server's message (`errors` or `error`) word for word. Don't retry a refused write with changed data unless the user asks.

| Status | Meaning | Do |
|---|---|---|
| 401 | Key bad, expired or revoked | The user makes a new one |
| 403 `agent_key_time_only` | A time-tracking key | Needs an `eol_full_` key (step 1) |
| 403 | Not allowed, e.g. someone else's or a locked expense | Show the message |
| 404 | Expense or project not visible to the user | Re-list, then ask |
| 422 | A rule refused it: not assigned to the project, category required, units on an amount-based category, locked period | Show the message and ask what to change |
| 429 | Rate limit | Wait `Retry-After` seconds, retry once |

- **How-to questions** ("how do I attach a receipt?"): `eol.help.search` with `{"query": "..."}`.
- **Can't be done here** (receipt upload, delete), or a bug or friction: offer `eol.feedback.submit` with `{"body": "..."}`: the user's words as a feature request or bug report (what they wanted, what happened), up to 2000 characters, no keys or passwords. Send it after they agree, and say it was sent.
- **Hours, not money:** for time use `eol-time-log-hours`.
