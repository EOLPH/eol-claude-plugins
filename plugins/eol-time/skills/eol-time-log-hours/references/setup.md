# Setting up EOL Time for Claude

The user does steps 1 and 2 themselves. You never see the key, and you never write it into a file, a commit or the chat.

## 1. Mint a time-tracking-only API key

1. Sign in at https://time.eol.agency.
2. Open **Settings → API keys** (`https://time.eol.agency/settings/api-keys`) and create a key:
   - **Name:** something like "Claude on my laptop".
   - **Access:** **Time tracking only** (preselected). It can read projects and tasks, write the user's own time and timer, submit (and take back) the user's own timesheet, search the in-app help and send feedback, and nothing else: no expenses, approvals, invoices, clients, reports or other people's time. Expenses and approving other people's weeks need **Full access**.
   - **Duration:** 30 days is a sensible default. A key that runs out answers 401; mint a new one then.
3. Copy the key once; it is never shown again. A time-tracking key starts with `eol_time_` (a full-access one with `eol_full_`). If the API keys page is missing, ask a workspace admin.

## 2. Put it in an environment variable

- **macOS or Linux:** add these to `~/.zshrc` or `~/.bashrc`, outside any git repo:

  ```bash
  export EOL_TIME_API_KEY='<paste the key here, in your own terminal>'
  # Optional; production is the default.
  # export EOL_TIME_URL='https://time.eol.agency'
  ```

- **Windows** (PowerShell, stored for your user):

  ```powershell
  [Environment]::SetEnvironmentVariable("EOL_TIME_API_KEY", "<paste the key here>", "User")
  ```

Then quit and restart Claude Code (or Claude Desktop) so it picks the variable up.

To check it without showing it:

```bash
test -n "$EOL_TIME_API_KEY" && echo set || echo missing
```

That is all the REST path needs. Steps 3 and 4 add the MCP server, which is optional.

## 3. Claude Code: add the MCP server (optional)

```bash
claude mcp add --transport http eol-time https://time.eol.agency/mcp \
  --header "Authorization: Bearer $EOL_TIME_API_KEY" --scope user
```

- Your shell expands `$EOL_TIME_API_KEY` when you run the command, and Claude Code stores the resulting header in `~/.claude.json`. That file is local and never goes in a repo.
- **Keeping the key out of that file:** add the server to a project's `.mcp.json` instead. Claude Code expands variables there when it starts:

  ```json
  {
    "mcpServers": {
      "eol-time": {
        "type": "http",
        "url": "${EOL_TIME_URL:-https://time.eol.agency}/mcp",
        "headers": { "Authorization": "Bearer ${EOL_TIME_API_KEY}" }
      }
    }
  }
  ```

- **Check it:** run `claude mcp list` (`eol-time` should show as connected), or `/mcp` inside Claude Code. A 401 there means the key is wrong, expired or revoked.

## 4. Claude Desktop (optional)

EOL Time's MCP server takes a bearer key and has no OAuth sign-in, so the **Connectors → Add custom connector** screen can't use it. Use the `mcp-remote` bridge (MIT, needs Node.js) in `claude_desktop_config.json` instead:

```json
{
  "mcpServers": {
    "eol-time": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://time.eol.agency/mcp", "--header", "Authorization:${AUTH_HEADER}"],
      "env": { "AUTH_HEADER": "Bearer <paste the key here>" }
    }
  }
}
```

- `Authorization:${AUTH_HEADER}` has no space after the colon on purpose. Claude Desktop on Windows mangles spaces inside `args`.
- This file holds the key in plain text on your machine. Keep it out of backups you share, and revoke the key at Settings → API keys if the file ever leaks.
- Restart Claude Desktop after editing.

claude.ai in the browser can't reach EOL Time yet: there is no OAuth connector, and its sandbox can't call the API.

## Revoking

Settings → API keys → Revoke. The key stops working at once (401) on REST and MCP.
