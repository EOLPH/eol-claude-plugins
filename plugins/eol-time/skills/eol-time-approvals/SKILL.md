---
name: eol-time-approvals
description: Work the timesheet approval queue in EOL Time (time.eol.agency, EOL's Harvest replacement) for managers, admins and owners. Lists pending weeks by person, project or client, approves and locks them, rejects one with a reason, or withdraws an approval, always summarising what will change and asking first. Also answers hours by project or person, who is on a project, and logs time, runs a timer or submits a week for a named teammate. Hours only, never rates or money. Needs an eol_full_ API key and an approving role. Use when the user asks what is waiting for approval, to approve, reject or unlock timesheets, who has not submitted, how many hours the team or a project logged, who is on a project, or to log time, start a timer or submit a week for a teammate in EOL Time.
compatibility: Needs network access to the EOL Time server and the EOL Time MCP server (the eol-time Claude plugin sets it up) with a full-access (eol_full_) API key. The user must be a manager, admin or owner in the workspace.
metadata:
  title: EOL Time timesheet approvals
  version: "1.0"
---

# EOL Time timesheet approvals

You act for an approver (manager, admin or owner) on the people and projects the server lets them approve. Nothing is approved, rejected or withdrawn until the user has seen exactly what will change and said yes.

**Hours only.** Never show, total or repeat a rate, a cost, an amount or a budget, even if a response contains one and even for an admin. Money stays in the app.

## 1. Check access first

- **Tools:** `eol.approval.list`, `eol.approval.approve`, `eol.approval.reject`, `eol.approval.withdraw`, `eol.report.time`, `eol.project.assignments` and `eol.user.list`, plus the time, timer and timesheet tools for step 9 (Claude Code shows them as `mcp__<server>__…`). This skill has no REST path.
- **Key:** these tools need a **full-access** key (`eol_full_…`). A time-tracking key (`eol_time_…`) gets 403 `agent_key_time_only` (MCP: HTTP 403, JSON-RPC error -32003). Tell the user plainly: make a Full access key at Settings → API keys and configure the plugin with it (`/plugin` → `eol-time` → configure). Never print, echo or paste a key.
- **Role:** `eol.workspace.whoami` returns `company_role`. Employees get 403 from every approval call; say approvals are for managers, admins and owners.
- **Approval on?** `eol.capabilities` `workspace_settings.timesheet_approval.submission_required` says whether timesheet approval is on. If it's off (or a call answers 404 `approvals_off`), there is no queue; say so.

Each MCP result is JSON text `{"status": <http status>, "data": {...}}`; `data` is the REST body.

## 2. Pick the timeframe

Default to last week (most teams approve the week just finished); say which dates you used. Use `workspace_settings.week_start_day` from `eol.capabilities`, or Monday to Sunday if it isn't reported. Every approve and withdraw needs both `from` and `to` (YYYY-MM-DD). Never approve without a timeframe.

## 3. Show the queue

`eol.approval.list` with `{"from": "FROM", "to": "TO", "status": "pending", "group_by": "person"}`. Add `project_ids`, `client_ids` or `user_ids` when the user names them (ids from `eol.project.list` or `eol.user.list`; never invent one).

`data.groups` rows carry `label`, `status`, `user_ids`, `entry_count`, `expense_count`, `hours`, `billable_hours`, `open_submission_ids`, `running_timer`, `running_timer_users`, `approvable`, `withdrawable` and `scope` (the filter that means "just this row").

Show one line per row, hours as H:MM:

> **Ana Reyes**: 38:30 (31:00 billable), 14 entries, 1 expense. Approvable.
> **Ben Cruz**: 40:00, 12 entries. Timer running on Acme / Website redesign: skipped until it stops.

Other tabs: `"status": "unsubmitted"` shows who hasn't submitted; `"status": "approved"` shows what's already approved.

## 4. Approve (locks the time)

1. Decide the filters: the whole list, or one row (merge its `scope`, e.g. `{"user_ids": [12]}`, into the same `from` / `to` and filters). **List and approve with the same filters**: they decide what gets approved.
2. Summarise and wait for a yes:

   > Approve and lock **Ana Reyes, 2026-10-12 to 2026-10-18**: 38:30 over 14 entries and 1 expense. Locked time can't be edited until approval is withdrawn. Projects with a running timer are skipped. Approve?

3. `eol.approval.approve` with those filters and a fresh `idempotency_key`.
4. Report from `data`: `notice`, `entry_count`, `expense_count` and `skipped_project_ids` (name those projects and say they were skipped for a running timer).

Approvers' own time is skipped unless the workspace allows self-approval; say so if the user's own row didn't move.

## 5. Reject one week

Rejecting returns one person's week to them with a comment, and the server emails them.

1. List with `"group_by": "person"` and take the row's `open_submission_ids`. Exactly one id: use it. Several: ask which week.
2. A comment is required. Ask the user what has to change; don't write it for them unless they ask, and show it before sending.
3. Confirm:

   > Return **Ana Reyes**'s week **2026-10-12 to 2026-10-18** with the comment "Please add tasks to Thursday's entries"? It goes back to them to fix and resubmit, and they are emailed.

4. `eol.approval.reject` with `{"submission_id": ID, "comment": "...", "idempotency_key": "..."}`. Report `notice`, `entry_count` and `expense_count`.

## 6. Withdraw approval (unlock)

For admins, and managers with the withdraw-approvals permission (`data.can_withdraw` on the list).

1. List with `"status": "approved"` and the same filters; rows with `withdrawable: true` can be withdrawn.
2. Confirm: what goes back to pending (person, dates, hours, entries, expenses), and that invoiced time and time before the lock date stay locked.
3. `eol.approval.withdraw` with those `from` / `to` filters and a fresh `idempotency_key`. Report `notice` and the counts.

## 7. Hours by project or person

`eol.report.time` with `{"date_range": "this_week", "group_by": "project"}` (or `"team_member"`, `"client"`, `"task"`; or `from` / `to` instead of `date_range`).

- `data.summary`: `totalMinutes`, `billableMinutes`, `nonBillableMinutes`.
- `data.groupTotals`: one row per group (`id`, `totalMinutes`, `billableMinutes`).
- `data.reports`: `label` and `id` per group with its entries (50 entries a page; `page` for more). Match `groupTotals` to `reports` on `id` for the names.

Show hours as H:MM. **Ignore any amount fields** (`billableAmounts`, `uninvoicedAmounts`). Managers see their managed scope; employees only their own time.

## 8. Who's on a project and what they've logged

`eol.project.assignments` with `{"project_id": ID, "type": "people", "from": "FROM", "to": "TO"}` (project id from `eol.project.list`; the range defaults to this week) lists the people on the project: `name`, `is_project_manager`, `hours_logged` and `billable_hours`. `"type": "tasks"` lists the project's tasks (`name`, `billable`). Show names and hours as H:MM only. When `rates_visible` is true the rows also carry `hourly_rate` and `use_default_rates`; **never print them**, whoever asks.

## 9. Acting for a teammate

Managers and admins with a full key may act for someone in their scope by adding `user_id` to `eol.time.list`, `eol.time.create`, `eol.timer.current`, `eol.timer.start` or `eol.timesheet.submit`. `eol.time.update` has no `user_id`: it edits only the user's own entries. Never with a time key (`eol_time_…`): it acts for its owner only and gets 403.

1. Find the person with `eol.user.list` and confirm them **by name** before anything else: "Log this for **Ana Reyes** (ana@…)?" Several matches or none: ask. Never guess an id.
2. Then follow the same flow as the user's own (the `eol-time-log-hours`, `eol-time-timer` or `eol-time-my-week` skill), with `user_id` added, and name the person again in the final confirmation:

   > Log **2:00** on **2026-10-20** for **Ana Reyes** to **Acme / Website redesign**, task **Design**. OK?

3. Report whose entry, timer or week it was. A 403 means that person isn't in the user's scope; show the message.

**`scope_limited: true`** (top level, next to `status` and `data`, on `eol.time.list`, `eol.timer.current`, `eol.report.time`, `eol.report.detailed_time` and `eol.project.assignments`) means the user's permissions trimmed the result. Say so. It never means "nothing logged".

## Errors and anything else

Show the server's message (`errors` or `error`) word for word, and don't retry a refused write with different filters unless the user asks.

| Status | Meaning | Do |
|---|---|---|
| 401 | Key bad, expired or revoked | The user makes a new one |
| 403 `agent_key_time_only` | A time-tracking key | Needs an `eol_full_` key (step 1) |
| 403 | Not an approver, or not for that person or project | Say who can do it: managers, admins, owners |
| 404 `approvals_off` | Approval is off | No queue to work |
| 422 `invalid_filter` | A date or id couldn't be read | Fix the value; nothing was done |
| 422 | Nothing to approve or withdraw, or a missing comment | Show the message |
| 429 | Rate limit | Wait `Retry-After` seconds, retry once |

- **How-to questions** ("how does self-approval work?"): `eol.help.search` with `{"query": "..."}`.
- **Can't be done here**, or a bug or friction: offer `eol.feedback.submit` with `{"body": "..."}`: the user's words as a feature request or bug report (what they wanted, what happened), up to 2000 characters, no keys or passwords. Send it after they agree, and say it was sent.
- **Their own week:** use the `eol-time-my-week` skill.
