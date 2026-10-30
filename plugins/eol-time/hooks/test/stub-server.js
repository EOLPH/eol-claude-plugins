// Stub EOL Time server for hooks/test/run.sh. Not used by the plugin itself.
//
//   node stub-server.js MODE PORT_FILE LOG_FILE
//
// MODE:
//   200        capture on
//   200off     capture off (and the activity answer says so)
//   200ignore  capture on, with the folders "other" and "myproj" ignored
//   422        activity batches refused as malformed (settings still 200)
//   500        every request fails
// Answers after DELAY_MS, so run.sh can tell a hook that waits on the
// network from one that doesn't. Writes the port it listens on to PORT_FILE
// and one JSON line per request to LOG_FILE (utf8: whether the raw body was
// valid UTF-8; valid: whether it parsed as JSON; events: the batch size).
const fs = require("fs");
const http = require("http");

const [mode, portFile, logFile] = process.argv.slice(2);
const DELAY_MS = 400;
const settings = {
  enabled: mode !== "200off",
  paused: false,
  idle_minutes: 15,
  ignored_folders: mode === "200ignore" ? ["other", "myproj"] : [],
  time_zone: "Asia/Manila",
  unsorted_minutes: 200,
  yesterday_unsorted_minutes: 95,
};
const strictUtf8 = new TextDecoder("utf-8", { fatal: true });

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", chunk => chunks.push(chunk));
  req.on("end", () => {
    const rawBytes = Buffer.concat(chunks);
    let raw = "";
    let utf8 = true;
    try {
      raw = strictUtf8.decode(rawBytes);
    } catch {
      utf8 = false;
      raw = rawBytes.toString("utf8");
    }
    const entry = {
      method: req.method,
      path: req.url,
      auth: req.headers.authorization === "Bearer eol-test-dummy-key",
      utf8,
      valid: null,
      events: null,
      body: raw,
    };
    if (raw) {
      try {
        const parsed = JSON.parse(raw);
        entry.valid = true;
        entry.events = Array.isArray(parsed.events) ? parsed.events.length : null;
      } catch {
        entry.valid = false;
      }
    }
    fs.appendFileSync(logFile, JSON.stringify(entry) + "\n");

    const activity = req.url.startsWith("/api/v1/time_capture/activity");
    setTimeout(() => {
      if (mode === "500") {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end('{"error":"stub failure"}');
        return;
      }
      if (mode === "422" && activity) {
        res.writeHead(422, { "Content-Type": "application/json" });
        res.end('{"errors":"stub: malformed batch"}');
        return;
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      if (activity) {
        res.end(JSON.stringify({ accepted: entry.events || 0, settings }));
      } else {
        res.end(JSON.stringify(settings));
      }
    }, DELAY_MS);
  });
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
