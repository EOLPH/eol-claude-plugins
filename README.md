# EOL Claude plugins

A Claude plugin marketplace with one plugin, **`eol-time`**, which lets Claude log your hours and run your timer in [EOL Time](https://time.eol.agency) (EOL's Harvest replacement).

The plugin gives Claude:

- the **EOL Time MCP server** (`https://time.eol.agency/mcp`), signed in with your API key;
- two skills: **`eol-time-log-hours`** (finds the project and task, confirms date, duration and note, then logs the entry) and **`eol-time-timer`** (checks, starts and stops your one running timer).

## Install in Claude Code

1. Create an API key at https://time.eol.agency/settings/api-keys. Choose **Time tracking only** unless you need more. The key's start shows its access:
   - `eol_time_…`: reads your projects and tasks, and logs, edits and deletes your own time and timer. Nothing else.
   - `eol_full_…`: everything you can do in EOL Time, at your role.
2. In Claude Code:

   ```
   /plugin marketplace add EOLPH/eol-claude-plugins
   /plugin install eol-time@eol
   ```

3. Paste the key when asked. Claude Code masks it and keeps it in your system's credential store, not in a settings file.
4. Restart Claude Code, then run `/mcp`: `eol-time` should show as connected.

Try: "log 1h30 on <project> today in EOL Time", "start my EOL Time timer on <project>", "what am I tracking?".

Change the key later with `/plugin` → `eol-time` → configure, or `claude plugin configure eol-time@eol`.

## Claude Desktop or claude.ai (secondary)

Claude Code is the main target. In claude.ai or the desktop app, **Customize → Plugins → Add → Add marketplace** `EOLPH/eol-claude-plugins` installs the skills, but those apps don't fill in the key prompt: connecting `eol-time` there asks you to set up the connector by hand. Plugins added there also reach Claude Code on the same account.

## Troubleshooting

| You see | Means | Do |
|---|---|---|
| `eol-time` fails to connect, or 401 | The key is wrong, expired or revoked | Make a new key and configure the plugin again |
| 403 `agent_key_time_only` | An `eol_time_` key was asked for something outside time tracking | Expected. Use an `eol_full_` key only if you really need it |
| 429 | Rate limit (about 120 requests a minute, 30 writes per 10 seconds per key) | Wait the `Retry-After` seconds |

Revoke a key at Settings → API keys; it stops working at once.

## For maintainers

- The skills here are a copy. Edit them in the EOL Time repo's `skills/` and copy them across (its `skills/README.md`); an end-to-end test there fails when the copies differ.
- Check the manifests with `claude plugin validate .` and `claude plugin validate plugins/eol-time`.
- Bump `version` in `plugins/eol-time/.claude-plugin/plugin.json` on every change, or installed copies won't update.
