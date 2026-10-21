---
name: eol-time-my-week
description: Review and submit the user's own week in EOL Time (time.eol.agency, EOL's Harvest replacement). Shows per-day totals, flags empty or light days and a running timer, offers fixes, then submits the week for approval only after the user says yes. Explains submitted, approved, rejected and locked weeks, and takes a pending week back. Use when the user asks to check, review, finish, close or submit their timesheet or week, asks what they logged this week, why a week is locked or rejected, or wants to unsubmit a week in EOL Time.
compatibility: Needs network access to the EOL Time server and either the EOL Time MCP server (the eol-time Claude plugin sets it up) or a shell with curl. An eol_time_ (time tracking only) key is enough.
metadata:
  title: Review and submit my week in EOL Time
  version: "1.1"
---

# Review and submit my week in EOL Time

You review and submit the signed-in user's **own** week only. Never edit, submit or unsubmit anyone else's here, even if the key could; a manager submitting for a teammate uses the `eol-time-approvals` skill. Nothing is changed or submitted until the user has said yes.

## 1. Check setup

- **MCP:** use the tools `eol.capabilities`, `eol.time.list`, `eol.timer.current`, `eol.timesheet.list`, `eol.timesheet.submit` and `eol.timesheet.unsubmit` (Claude Code shows them as `mcp__<server>__…`).
- **No MCP tools:** use REST with `$EOL_TIME_API_KEY` and `${EOL_TIME_URL:-https://time.eol.agency}`, the same way as the `eol-time-log-hours` skill's `references/rest-api.md` (which covers reading and editing entries and the timer). The week's submissions are `GET /api/v1/timesheets/submissions?from=FROM&to=TO`, submitting is `POST /api/v1/timesheets/submissions` with `{"period_start": "YYYY-MM-DD"}`, and taking one back is `DELETE /api/v1/timesheets/submissions/ID`. The bodies match the MCP `data` below. No key yet: `eol-time-log-hours`' `references/setup.md`.
- **Key:** a time-tracking key may list, submit and unsubmit the user's own week. To know which key is in use, read `key.scope` (`time` or `full`) from `eol.workspace.whoami`; don't guess it from the tool list. Never print, echo or paste a key. If the user pastes one into the chat, tell them to revoke it at Settings → API keys and make a new one.

Each MCP result is JSON text `{"status": <http status>, "data": {...}}`; `data` is the REST body.

## 2. Learn the workspace's rules

Call `eol.capabilities` once and read `workspace_settings`:

- **`timesheet_approval.submission_required`:** if false, approval is off and there is nothing to submit: logged time is final. Review the week (step 3), then stop. `timesheet_approval.note` says how this workspace submits (`mode` `weekly` or `flexible`).
- **`week_start_day`:** pick the week's first and last day from it. If it isn't reported, use Monday to Sunday and say so.
- **`notes_required`** and **`time_locked_through`:** flag entries with no note when notes are required; nothing on or before the lock date can change.

"This week" is the week containing today in the user's local time; "last week" is the one before. Turn other words into dates and say which dates you used.

## 3. Review the week

1. `eol.time.list` with `{"from": "FIRST_DAY", "to": "LAST_DAY"}`. `data.entries` is keyed by date; each entry has `id`, `project`, `client`, `task_name`, `note`, `duration` (minutes) and, when approval is on, `approval_status`, `approval_locked`, `period_locked`, `locked`, `invoiced` and `timer_running`. Rows with `type: "leave"` are time off.
2. `eol.timer.current`. A running timer blocks submitting.
3. Show a short table, one line per day, durations as H:MM:

   | Day | Total | Entries |
   |---|---|---|
   | Mon 2026-10-12 | 7:30 | Acme / Website redesign, Design 5:00; Internal, Admin 2:30 |

   Then the week total.
4. Flag, without guessing a target:
   - working days with no time and no time off;
   - working days well below the rest of the week (say what the others were);
   - a running timer (project, task and time so far);
   - entries with no task, or an empty note (always when `notes_required`, otherwise when other entries have one);
   - locked rows (`locked`, `approval_locked`, `period_locked`, `invoiced`). Those can't be edited.

## 4. Offer fixes (each confirmed first)

- **Add missing time:** hand over to the `eol-time-log-hours` skill, or call `eol.time.create` the way it says.
- **Change an entry:** `eol.time.update` needs `id`, `project_id`, `work_date` and `duration_minutes` (or `started_time` + `ended_time`) every time, plus `task_id` and `note`. Send the current values for what isn't changing. Show the before and after on one line and wait for a yes.
- **Delete an entry:** `eol.time.delete` with `{"id": ENTRY_ID}`, after the user confirms that exact entry.
- **Running timer:** the `eol-time-timer` skill stops it, or `eol.timer.stop` with `{}` after a yes. Stopping saves the elapsed time to that entry.

Use a fresh `idempotency_key` on every write. Stop at the first error and show it.

## 5. Submit

1. Check `eol.timesheet.list` with `{"from": "FIRST_DAY", "to": "LAST_DAY"}` for a live submission of this week first (step 6 says what each status means).
2. Confirm in one line and wait for a yes:

   > Submit **2026-10-12 to 2026-10-18** for approval: **38:30** over 5 days, plus any expenses in that week. Your approver is told; once they approve it, it's locked. OK?

3. `eol.timesheet.submit` with `{"period_start": "FIRST_DAY", "idempotency_key": "<fresh random string>"}`. Never pass `user_id`; that submits someone else's week.
4. Report from `data`: `submission.period_start`, `period_end`, `status`, `entry_count` and `expense_count`.

Time and expenses go up together. The server refuses the submit (422, with a `code`) when:

| `code` | Means | Do |
|---|---|---|
| `running_timer` | A timer is running in that week | Offer to stop it, then try again |
| `unreviewed_agent_entries` | Agent-created entries await review (`entry_ids`) | The user reviews them in the app |
| `already_submitted` | The week is already up | Show its status (step 6) |
| `period_locked` | An admin locked time up to a date | Nothing to do; it's final |
| `forbidden` | The user may not submit this week | Show the message |

A 404 with `code: "approvals_off"` means approval is off: nothing to submit.

## 6. Explain a week's state

`eol.timesheet.list` (optionally `from` / `to`) returns `submissions`, newest first, each with `id`, `period_start`, `period_end`, `status`, `submitted_at`, `decided_at`, `rejection_reason` and `can_unsubmit`.

- **submitted:** waiting for an approver. The user can still edit the entries until they're approved. To pull the whole week back first, unsubmit it (step 7) while `can_unsubmit` is true.
- **partially_approved:** some of it is approved, so it can't be taken back. Ask an approver to reject it or withdraw approval.
- **approved:** locked. Only an approver withdrawing approval unlocks it.
- **rejected:** back with the user. Show `rejection_reason` word for word, help fix the entries, then submit again.
- **unsubmitted** or **withdrawn:** taken back earlier; that row is history. Submit again when ready.

Invoiced time and time before the workspace's lock date stay locked whatever the status.

## 7. Take a week back (unsubmit)

Only while its status is `submitted` (`can_unsubmit: true`). Confirm first:

> Take back your submission for **2026-10-12 to 2026-10-18**? It leaves your approver's queue, and you'll need to submit it again afterwards.

Then `eol.timesheet.unsubmit` with `{"submission_id": ID}` (or `{"period_start": "FIRST_DAY"}`) and a fresh `idempotency_key`. Report the `notice`.

## Errors and anything else

Show the server's message (`errors` or `error`) word for word, and don't retry a refused write with changed data unless the user asks.

- **401:** the key is bad, expired or revoked. The user makes a new one.
- **403 `agent_key_time_only` (MCP -32003):** that call is outside a time key's reach. Approving other people's weeks is the `eol-time-approvals` skill and needs an `eol_full_` key.
- **429:** wait the `Retry-After` seconds, then retry once.
- **How-to questions** ("how does approval work here?"): `eol.help.search` with `{"query": "..."}` and answer from what it returns.
- **Can't be done here**, or the user reports a bug or friction: offer `eol.feedback.submit` with `{"body": "..."}`: their words as a feature request or bug report (what they wanted, what happened), up to 2000 characters, no keys or passwords. Send it only after they agree, and tell them it was sent.
