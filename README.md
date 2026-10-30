# EOL Claude plugins

A Claude plugin marketplace with one plugin, **`eol-time`**, which lets Claude log your hours, log a whole day in one message, run your timer, submit your week, log expenses and work the approval queue in [EOL Time](https://time.eol.agency) (EOL's Harvest replacement). In Claude Code it can also record when you work, if you switch that on, so you can sort the time into your timesheet later.

The plugin gives Claude:

- the **EOL Time MCP server** (`https://time.eol.agency/mcp`), signed in with your API key;
- seven skills:
  - **`eol-time-log-hours`**: finds the project and task, offers your workspace's task types (optional), confirms date, duration and note, then logs the entry;
  - **`eol-time-timer`**: checks, starts and stops your one running timer;
  - **`eol-time-my-week`**: checks your week for gaps and a running timer, then submits it for approval when you say yes;
  - **`eol-time-expenses`**: logs, lists and edits your own expenses (no receipt upload). Needs an `eol_full_` key;
  - **`eol-time-approvals`**: for managers, admins and owners, approves, rejects or withdraws your team's weeks, shows hours by project or person, and logs time or submits a week for a teammate. Hours only. Needs an `eol_full_` key;
  - **`eol-time-log-my-day`**: describe your day in one message ("about 7 hours: Acme homepage, a client call, admin"); Claude splits it across your projects and tasks, shows a table and logs it when you say yes. Works in the Claude desktop app too;
  - **`eol-time-sort-my-time`**: sorts your captured Claude Code time (the **To sort** tray) into entries, removes or restores blocks, and turns capture on, off, paused or resumed;
- **time capture hooks** (Claude Code only, **off until you turn it on**): see [Time capture](#time-capture-claude-code).

## Install in Claude Code

**Already installed?** Run `/plugin marketplace update eol`, then restart Claude Code. New features (task types in 1.2.0; log my day, sort my time and time capture in 1.3.0) arrive only after an update.

1. Create an API key at https://time.eol.agency/settings/api-keys. Choose **Time tracking only** unless you need more. The key's start shows its access:
   - `eol_time_…`: reads your projects and tasks, logs, edits and deletes your own time and timer, submits your own timesheet, searches the help and sends feedback. Nothing else.
   - `eol_full_…`: everything you can do in EOL Time, at your role. Expenses and approvals need this one.
2. In Claude Code:

   ```
   /plugin marketplace add EOLPH/eol-claude-plugins
   /plugin install eol-time@eol
   ```

3. Paste the key when asked. Claude Code masks it and keeps it in your system's credential store, not in a settings file.
4. Restart Claude Code, then run `/mcp`: `eol-time` should show as connected.
5. Test it. Ask Claude: *What projects am I on?* Then: *Log 30 minutes on [one of them], today, task type Meeting: testing the plugin.* Delete the test entry afterwards.

Try: "log 1h30 on <project> today in EOL Time", "log my day", "start my EOL Time timer on <project>", "what am I tracking?", "sort my time", "check my week and submit it".

Update the plugin with `/plugin marketplace update eol` (in claude.ai: Customize → Plugins → Add → Manage marketplaces → ⋮ → Check for updates). Change the key later with `/plugin` → `eol-time` → configure, or `claude plugin configure eol-time@eol`.

## Time capture (Claude Code)

Optional and **off for everyone** until you turn it on: say "turn on time capture" to Claude, or use the **Record my Claude Code time** switch on the **To sort** page in EOL Time (under Time Tracking). The first Claude Code session after you update to 1.3.0 offers it once.

While it is on, the plugin's hooks note **when** you work: each message you send, each step Claude takes and each reply it finishes. Gaps longer than your idle limit (15 minutes by default; 5 to 60, set on the To sort page) end a block, so a sleeping laptop or a session left open overnight records nothing. The time waits in your **To sort** tray until you sort it ("sort my time", or the To sort page); it never counts as hours until you do.

- **What is sent:** the session id, timestamps, the event kind, the tool-use id, your computer's time zone name, the **folder name** (not the full path), the git branch and the subject lines of your own commits. Never your prompts, Claude's replies, code, file names, paths or transcripts.
- **Who sees it:** only you. Not managers, admins or owners.
- **Pause:** "pause time capture" / "resume time capture", or the switch on the To sort page. It applies on every computer.
- **Ignored folders:** "ignore the folder X in time capture", or the list on the To sort page.
- **On your computer:** the hooks keep a small queue in Claude Code's plugin data folder (`~/.claude/plugins/data/`), send it at most once a minute and when Claude finishes a reply, and keep it when there is no network. While capture is off or paused they queue and send nothing. They never show errors or slow Claude Code down.

## Claude Desktop or claude.ai (secondary)

Claude Code is the main target. In claude.ai or the desktop app, **Customize → Plugins → Add → Add marketplace** `EOLPH/eol-claude-plugins` installs the skills, but those apps don't fill in the key prompt: connecting `eol-time` there asks you to set up the connector by hand. Plugins added there also reach Claude Code on the same account. Time capture needs Claude Code; in the desktop app, say "log my day" instead (the daily reminder email points to it).

## Troubleshooting

| You see | Means | Do |
|---|---|---|
| `eol-time` fails to connect, or 401 | The key is wrong, expired or revoked | Make a new key and configure the plugin again |
| 403 `agent_key_time_only` | An `eol_time_` key was asked for something outside time tracking, such as expenses or approvals | Expected. Use an `eol_full_` key only if you need those |
| 429 | Rate limit (about 120 requests a minute, 30 writes per 10 seconds per key) | Wait the `Retry-After` seconds |
| Nothing in the To sort tray | Capture is off or paused, the folder is ignored, or you are on a plugin older than 1.3.0 | Say "show my time capture settings"; update the plugin |

Revoke a key at Settings → API keys; it stops working at once.

## For maintainers

- The skills here are a copy. Edit them in the EOL Time repo's `skills/` and copy them across (its `skills/README.md`); an end-to-end test there fails when the copies differ.
- Check the manifests with `claude plugin validate .` and `claude plugin validate plugins/eol-time`.
- Bump `version` in `plugins/eol-time/.claude-plugin/plugin.json` on every change, or installed copies won't update.
- The capture hooks are `plugins/eol-time/hooks/hooks.json` and `hooks/capture.sh` (POSIX sh and curl; the Claude Code facts it relies on are listed at its top). Check them with `sh plugins/eol-time/hooks/test/run.sh` (needs Node for the stub server). `EOL_TIME_BASE_URL=https://time-dev.eol.agency` points the hooks at the dev server; users never set it.
- Publish a version with hooks only after the production deploy that has `/api/v1/time_capture`.
