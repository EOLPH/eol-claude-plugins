#!/bin/sh
# Checks for hooks/capture.sh against a stub server (stub-server.js, Node).
# Not part of the plugin's behaviour; Claude Code ships plugin folders whole,
# so these files travel with it and do nothing.
#
#   sh claude-plugin/plugins/eol-time/hooks/test/run.sh
#   HOOK_SHELL=dash sh .../run.sh    (run capture.sh under another POSIX shell)
#
# What it proves, for every hook kind, with the server answering 200, 500, or
# not there at all:
#   - nothing on stdout or stderr, except SessionStart's note;
#   - exit 0 every time;
#   - capture off (the default) or paused queues and sends nothing;
#   - only session id, time, kind, tool-use id, folder NAME, branch, commit
#     subjects and time zone are queued: never the prompt, tool input or
#     output, the reply or a path;
#   - after a 500 or with no server the queue keeps its events; after a 200
#     it is empty, the batch was valid JSON, and the answer's settings were
#     saved; a long queue goes up 500 events at a time; the queue is capped;
#   - every run returns in under 300 ms wall time although the stub takes
#     400 ms to answer (so no run waits on the network).

here=$(cd "$(dirname "$0")" && pwd)
script=$here/../capture.sh
stub=$here/stub-server.js
work=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/eol-capture-test.$$")
mkdir -p "$work"

pass=0
fail=0
max_ms=0
LIMIT_MS=300
OFFER="EOL Time can record when you work in Claude Code (times and folder names only, never your code or conversation). Unsorted time is yours alone. Want to turn it on?"

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
expect() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

# Milliseconds since the epoch into $MS, without a subprocess where possible.
ms_now() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    t=$EPOCHREALTIME
    s=${t%%[.,]*}
    f=${t#*[.,]}000
    f=${f%"${f#???}"}
    MS=$((s * 1000 + 1${f} - 1000))
  else
    n=$(date +%s%N 2>/dev/null)
    case $n in
      *N|'') MS=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000') ;;
      *) MS=$((n / 1000000)) ;;
    esac
  fi
}

STUB_PID=
PORT=
stop_stub() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  STUB_PID=
}
start_stub() { # mode
  stop_stub
  rm -f "$work/port" "$work/stub.log"
  : > "$work/stub.log"
  node "$stub" "$1" "$work/port" "$work/stub.log" &
  STUB_PID=$!
  i=0
  while [ ! -s "$work/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  PORT=$(cat "$work/port")
  export EOL_TIME_BASE_URL="http://127.0.0.1:$PORT"
}
no_server() {
  stop_stub
  : > "$work/stub.log"
  # A port nothing listens on: the stub's last one, now closed.
  export EOL_TIME_BASE_URL="http://127.0.0.1:${PORT:-9}"
}
trap 'stop_stub; rm -rf "$work" 2>/dev/null' EXIT INT TERM

# A fresh plugin data folder for each scenario.
use_data() {
  export CLAUDE_PLUGIN_DATA="$work/data-$1"
  rm -rf "$CLAUDE_PLUGIN_DATA"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  Q=$CLAUDE_PLUGIN_DATA/queue.jsonl
  ST=$CLAUDE_PLUGIN_DATA/state.json
}
write_state() { # enabled paused yesterday nudged_on offered_at [checked_on] [ignored_folders]
  ms_now
  printf '{"enabled":%s,"paused":%s,"unsorted_minutes":0,"yesterday_unsorted_minutes":%s,"checked_at":"","checked_on":"%s","offered_at":"%s","nudged_on":"%s","last_flush":%s,"time_zone":"Asia/Manila","ignored_folders":[%s]}\n' \
    "$1" "$2" "$3" "${6:-}" "$5" "$4" "$((MS / 1000))" "${7:-}" > "$ST"
}

export CLAUDE_PLUGIN_OPTION_API_KEY=eol-test-dummy-key

# A small git repo with one commit whose subject needs JSON escaping.
repo=$work/myproj
mkdir -p "$repo"
git -C "$repo" init -q 2>/dev/null
git -C "$repo" config user.email capture-test@example.com
git -C "$repo" config user.name "Capture Test"
git -C "$repo" config commit.gpgsign false
git -C "$repo" checkout -q -b feature/tray 2>/dev/null
git -C "$repo" commit -q --allow-empty -m 'fix "quoted" \ thing' 2>/dev/null
# A second commit whose subject has a byte that isn't UTF-8 (Latin-1 e-acute).
printf 'caf\351 menu\n' > "$work/msg"
git -C "$repo" commit -q --allow-empty -F "$work/msg" 2>/dev/null
# cwd as Claude Code sends it: a Windows path on Windows, JSON-escaped.
if command -v cygpath >/dev/null 2>&1; then
  cwd_native=$(cygpath -w "$repo")
else
  cwd_native=$repo
fi
cwd_json=$(printf '%s' "$cwd_native" | sed 's/\\/\\\\/g')

payload() { # event extra-json
  printf '{"session_id":"sess-test-1","transcript_path":"%s/SECRET-TRANSCRIPT.jsonl","cwd":"%s","permission_mode":"default","hook_event_name":"%s"%s}' \
    "$cwd_json" "$cwd_json" "$1" "$2"
}
P_START=$(payload SessionStart ',"source":"startup"')
P_PROMPT=$(payload UserPromptSubmit ',"tool_use_id":"toolu_NOTFORPROMPT","prompt":"SECRET-PROMPT-TEXT read C:\\\\secret\\\\file.txt"')
P_TOOL_START=$(payload PreToolUse ',"tool_name":"Bash","tool_input":{"command":"cat SECRET-FILE-NAME.txt","cwd":"/should/not/win","tool_use_id":"toolu_DECOY"},"tool_use_id":"toolu_01ABC"')
P_TOOL_END=$(payload PostToolUse ',"tool_name":"Bash","tool_input":{"command":"cat SECRET-FILE-NAME.txt"},"tool_response":{"stdout":"SECRET-OUTPUT"},"tool_use_id":"toolu_01ABC"')
P_STOP=$(payload Stop ',"stop_hook_active":false,"last_assistant_message":"SECRET-REPLY"')
P_END=$(payload SessionEnd ',"reason":"exit"')
# A PostToolUse after reading a big file: well over a pipe's buffer.
big=xxxxxxxxxxxxxxxx
while [ ${#big} -lt 300000 ]; do big=$big$big; done
P_BIG=$(payload PostToolUse ',"tool_name":"Read","tool_input":{"file_path":"x"},"tool_response":{"content":"'"$big"'"},"tool_use_id":"toolu_BIG"')

# run KIND PAYLOAD: $OUT (stdout and stderr), $RC, $ELAPSED (ms). The writer
# records whether its whole payload went into the pipe: a hook that exits
# without reading stdin makes a big write fail (EPIPE), as it would in Claude
# Code.
run() {
  rm -f "$work/wrc"
  ms_now; t0=$MS
  OUT=$( { printf '%s' "$2"; echo $? > "$work/wrc"; } 2>/dev/null | ${HOOK_SHELL:-sh} "$script" "$1" 2>&1)
  RC=$?
  ms_now; ELAPSED=$((MS - t0))
  [ "$(cat "$work/wrc" 2>/dev/null)" = 0 ] || bad "$1: the payload write failed (stdin not read)"
  [ "$ELAPSED" -gt "$max_ms" ] && max_ms=$ELAPSED
  [ "$RC" = 0 ] || bad "$1 exited $RC"
  [ "$ELAPSED" -lt "$LIMIT_MS" ] || bad "$1 took ${ELAPSED} ms (limit ${LIMIT_MS})"
  [ -n "${VERBOSE:-}" ] && printf '     %s: %s ms\n' "$1" "$ELAPSED"
  return 0
}
run_silent() { # label kind payload
  run "$2" "$3"
  [ -z "$OUT" ]; expect "$1: $2 prints nothing, exit 0" $?
}

lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
posts() { grep -c '"method":"POST"' "$work/stub.log" 2>/dev/null || true; }

# wait_until CMD [seconds]: poll until CMD succeeds.
wait_until() {
  limit=$(( ${2:-15} * 10 )); i=0
  while [ "$i" -lt "$limit" ]; do
    if eval "$1"; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
idle() { [ ! -d "$CLAUDE_PLUGIN_DATA/flush.lock" ] && [ ! -f "$CLAUDE_PLUGIN_DATA/sending.jsonl" ]; }

# Baseline: how long `sh` alone takes to start here.
ms_now; t0=$MS
for _ in 1 2 3 4 5; do printf '' | sh -c ':'; done
ms_now; SHELL_MS=$(((MS - t0) / 5))

echo "== capture off (the default) queues and sends nothing"
start_stub 200off
use_data off
for k in prompt:"$P_PROMPT" tool_start:"$P_TOOL_START" tool_end:"$P_TOOL_END" stop:"$P_STOP" session_end:"$P_END"; do
  run_silent "off" "${k%%:*}" "${k#*:}"
done
run_silent "off, $((${#P_BIG} / 1024)) KB payload" tool_end "$P_BIG"
sleep 0.6
[ ! -f "$Q" ]; expect "off: no queue file" $?
[ "$(posts)" = 0 ]; expect "off: nothing POSTed" $?

echo "== SessionStart: the opt-in offer, once"
run session_start "$P_START"
case $OUT in *"$OFFER"*) ok "offer printed word for word" ;; *) bad "offer missing: $OUT" ;; esac
wait_until 'grep -q "\"offered_at\":\"2" "$ST" && grep -q "/api/v1/time_capture/settings" "$work/stub.log"'
expect "offered_at saved and settings fetched in the background" $?
wait_until 'grep -q "\"checked_at\":\"2" "$ST"'
grep -q '"enabled":false' "$ST"; expect "server says off: state stays off" $?
run session_start "$P_START"
[ -z "$OUT" ]; expect "offer not repeated" $?
sleep 0.6
[ ! -f "$Q" ]; expect "off: SessionStart queued nothing" $?

echo "== no API key: silent, no offer, nothing sent"
use_data nokey
CLAUDE_PLUGIN_OPTION_API_KEY=
run session_start "$P_START"
CLAUDE_PLUGIN_OPTION_API_KEY=eol-test-dummy-key
[ -z "$OUT" ]; expect "no key: SessionStart prints nothing" $?

echo "== paused queues nothing"
use_data paused
write_state true true 0 "" "x"
for k in prompt:"$P_PROMPT" tool_start:"$P_TOOL_START" tool_end:"$P_TOOL_END"; do
  run_silent "paused" "${k%%:*}" "${k#*:}"
done
[ ! -f "$Q" ]; expect "paused: no queue file" $?

echo "== on, server answers 500: the queue keeps everything"
start_stub 500
use_data on500
write_state true false 0 "" "x"
for k in prompt:"$P_PROMPT" tool_start:"$P_TOOL_START" tool_end:"$P_TOOL_END"; do
  run_silent "on" "${k%%:*}" "${k#*:}"
done
[ "$(lines "$Q")" = 3 ]; expect "on: one line per hook (3)" $?
grep -q '"folder":"myproj"' "$Q"; expect "folder is the name only" $?
grep -q '"tool_use_id":"toolu_01ABC"' "$Q"; expect "tool_use_id carried" $?
if grep -q 'toolu_DECOY' "$Q"; then bad "took the tool_use_id inside tool_input"; else ok "tool_use_id is the top-level one, not the decoy in tool_input"; fi
if grep -q 'NOTFORPROMPT' "$Q"; then bad "a prompt event carried a tool_use_id"; else ok "only tool events carry a tool_use_id"; fi
grep -q '"kind":"prompt"' "$Q" && grep -q '"kind":"tool_start"' "$Q" && grep -q '"kind":"tool_end"' "$Q"
expect "kinds prompt, tool_start, tool_end" $?
grep -q '"time_zone":"Asia/Manila"' "$Q"; expect "time zone carried" $?
grep -q '"at":"20[0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]\.[0-9][0-9][0-9]Z"' "$Q"
expect "timestamps are ISO 8601 UTC" $?
if grep -q 'SECRET\|should/not/win\|Users\|\\\\' "$Q"; then bad "queue leaks content or a path"; else ok "no prompt, tool input/output, transcript or path queued"; fi
run_silent "on500" stop "$P_STOP"
wait_until '[ "$(posts)" -ge 1 ] && idle'
expect "stop sent the queue in the background" $?
[ "$(lines "$Q")" = 4 ]; expect "after a 500 the queue keeps all 4 events" $?
grep -q '"auth":true' "$work/stub.log"; expect "the key went as a Bearer header" $?
grep -q '"valid":true' "$work/stub.log"; expect "the batch was valid JSON" $?
grep -q '"branch":"feature/tray"' "$Q"; expect "stop carries the git branch" $?
grep -qF '"fix \"quoted\" \\ thing"' "$Q"; expect "stop carries commit subjects, JSON-escaped" $?
grep -q '"caf[^"]* menu"' "$Q"; expect "a subject with a byte that isn't UTF-8 is still sent (git or iconv makes it UTF-8)" $?
if grep -q '"utf8":false' "$work/stub.log"; then bad "a batch was not valid UTF-8"; else ok "every batch was valid UTF-8"; fi
if grep -q 'SECRET' "$Q"; then bad "stop leaked the reply"; else ok "stop sent no reply text"; fi

echo "== on, no server: the queue keeps everything"
no_server
# last_flush 0, so the wait below can tell "the send has started" (the
# background job stamps it while holding flush.lock) from "not yet".
sed 's/"last_flush":[0-9]*/"last_flush":0/' "$ST" > "$ST.t" && mv "$ST.t" "$ST"
run_silent "noserver" session_end "$P_END"
wait_until '! grep -q "\"last_flush\":0" "$ST" && idle && [ "$(lines "$Q")" = 5 ]' 20
expect "no server: queue keeps all 5 events" $?

echo "== on, server answers 200: the queue empties"
start_stub 200
run_silent "on200" stop "$P_STOP"
wait_until '[ ! -s "$Q" ] && idle'
expect "after a 200 the queue is empty" $?
grep -q '"events":6' "$work/stub.log"; expect "all 6 events went in one batch" $?
grep -q '"yesterday_unsorted_minutes":95' "$ST"; expect "the answer's settings were saved" $?

echo "== lines that aren't events are dropped before sending"
use_data shape
write_state true false 0 "" "x"
{
  printf '{"session_id":"s","at":"2026-10-30T01:00:00.000Z","kind":"prompt","folder":"good"}
'
  printf '{"session_id":"s","at":"2026-10-30T01:00:00.000Z","kind":"pro
'
  printf '{"session_id":"s","at":"2026-10-30T01:00:00.000Z","kind":"nap","folder":"bad-kind"}
'
  printf 'not json at all
'
} > "$Q"
before=$(posts)
run_silent "shape" stop "$P_STOP"
wait_until '[ ! -s "$Q" ] && idle'
expect "the queue is empty afterwards" $?
[ "$(posts)" = $((before + 1)) ] && tail -n 1 "$work/stub.log" | grep -q '"valid":true,"events":2'
expect "one valid batch with the 2 real events" $?

echo "== the server refuses a batch (422): it is dropped, not retried forever"
start_stub 422
use_data r422
write_state true false 0 "" "x"
printf '{"session_id":"s","at":"2026-10-30T01:00:00.000Z","kind":"prompt","folder":"f"}
' > "$Q"
run_silent "422" stop "$P_STOP"
wait_until '[ "$(posts)" -ge 1 ] && idle'
expect "the batch was sent" $?
[ ! -s "$Q" ]; expect "after a 422 the batch is dropped" $?

echo "== a send that learns capture is off clears the queue"
start_stub 200off
use_data learnoff
write_state true false 0 "" "x"
i=0
while [ "$i" -lt 700 ]; do
  printf '{"session_id":"s","at":"2026-10-30T01:00:00.000Z","kind":"prompt","folder":"f%s"}
' "$i"
  i=$((i + 1))
done > "$Q"
run_silent "learn off" stop "$P_STOP"
wait_until '[ "$(posts)" -ge 1 ] && idle'
expect "the first batch was sent" $?
[ "$(posts)" = 1 ]; expect "the rest was not sent" $?
[ ! -s "$Q" ]; expect "the queue was cleared" $?
grep -q '"enabled":false' "$ST"; expect "state now says off" $?
run_silent "learn off" tool_start "$P_TOOL_START"
[ ! -s "$Q" ]; expect "and the next hook queues nothing" $?

echo "== ignored folders never leave the computer"
use_data ignore
write_state true false 0 "" "x" "" '"other","myproj"'
for k in prompt:"$P_PROMPT" tool_start:"$P_TOOL_START" tool_end:"$P_TOOL_END" stop:"$P_STOP"; do
  run_silent "ignored" "${k%%:*}" "${k#*:}"
done
sleep 1
if [ -f "$Q" ] && grep -q myproj "$Q"; then bad "an ignored folder was queued"; else ok "nothing queued for an ignored folder"; fi
start_stub 200ignore
use_data ignore2
write_state true false 0 "" "x"
run session_start "$P_START"
wait_until 'idle && grep -q "\"checked_at\":\"2" "$ST"'
grep -qF '"ignored_folders":["other","myproj"]' "$ST"; expect "the server's ignored list is saved locally" $?
: > "$Q"
run_silent "ignored2" tool_start "$P_TOOL_START"
[ ! -s "$Q" ]; expect "and used: the folder is not queued" $?
sleep 0.5

echo "== a long queue goes 500 at a time"
start_stub 200
use_data batch
write_state true false 0 "" "x"
i=0
while [ "$i" -lt 1200 ]; do
  printf '{"session_id":"s","at":"2026-10-30T01:00:00.000Z","kind":"prompt","folder":"f%s"}\n' "$i"
  i=$((i + 1))
done > "$Q"
run_silent "batch" stop "$P_STOP"
wait_until '[ ! -s "$Q" ] && idle' 20
expect "1201 events sent" $?
[ "$(grep -c '"events":500' "$work/stub.log")" = 2 ] && grep -q '"events":201' "$work/stub.log"
expect "in batches of 500, 500 and 201" $?

echo "== a send that died (stale flush.lock) is taken over; a live one is not"
use_data stale
write_state true false 0 "" "x"
printf '{"session_id":"s","at":"2026-10-30T01:00:00.000Z","kind":"prompt","folder":"f"}\n' > "$Q"
mkdir "$CLAUDE_PLUGIN_DATA/flush.lock"
ms_now; printf '%s\n' "$((MS / 1000))" > "$CLAUDE_PLUGIN_DATA/flush.lock/at"
before=$(posts)
run_silent "live lock" stop "$P_STOP"
sleep 1
[ "$(posts)" = "$before" ] && [ "$(lines "$Q")" = 2 ]; expect "a live lock: nothing sent, both events kept" $?
printf '%s\n' "$((MS / 1000 - 600))" > "$CLAUDE_PLUGIN_DATA/flush.lock/at"
run_silent "stale lock" stop "$P_STOP"
wait_until '[ ! -s "$Q" ] && idle'
expect "a stale lock: taken over and all 3 events sent" $?

echo "== the queue is capped near 1 MB"
no_server
use_data cap
write_state true false 0 "" "x"
i=0
while [ "$i" -lt 12000 ]; do
  printf '{"session_id":"s","at":"2026-10-30T01:00:00.000Z","kind":"prompt","folder":"padding-padding-padding-%s"}\n' "$i"
  i=$((i + 1))
done > "$Q"
run_silent "cap" stop "$P_STOP"
wait_until 'idle && [ "$(wc -c < "$Q" | tr -d " ")" -le 1048576 ]' 20
expect "queue trimmed to at most 1 MB" $?
tail -n 1 "$Q" | grep -q '"kind":"stop"'; expect "the newest events are the ones kept" $?
head -n 1 "$Q" | grep -q '^{"session_id"'; expect "no half line left at the top" $?

echo "== SessionStart: yesterday's unsorted time, once a day"
start_stub 200
today=$(date +%Y-%m-%d)
use_data nudgeold
write_state true false 95 "" "x" "2020-01-01"
run session_start "$P_START"
[ -z "$OUT" ]; expect "no note when the total wasn't read today" $?
wait_until 'idle && grep -q "\"checked_on\":\"$today\"" "$ST"'
expect "the background read stamps checked_on with today" $?
sleep 1; wait_until 'idle'
use_data nudge
write_state true false 95 "" "x" "$today"
run session_start "$P_START"
case $OUT in *"1:35 unsorted from yesterday. Offer once to sort it with the eol-time-sort-my-time skill."*) ok "nudge printed" ;; *) bad "nudge missing: $OUT" ;; esac
case $OUT in *"$OFFER"*) bad "offer shown while on" ;; *) ok "no offer while on" ;; esac
wait_until 'idle && grep -q "\"checked_at\":\"2" "$ST"'
run session_start "$P_START"
[ -z "$OUT" ]; expect "nudge not repeated the same day" $?
# Let that SessionStart's background job (fetch, then send) finish.
sleep 1
wait_until 'idle'

stop_stub

echo "== hooks.json: every command exits 0 (exit 2 on PreToolUse would block the tool)"
hooks_json="$here/../hooks.json"
commands=$(grep -c '"command":' "$hooks_json")
guarded=$(grep -c '"command":.*capture\.sh [a-z_]* || true"' "$hooks_json")
[ "$commands" -gt 0 ] && [ "$commands" = "$guarded" ]
expect "all $commands commands end in || true" $?

echo
echo "slowest run: ${max_ms} ms wall (limit ${LIMIT_MS} ms); sh start-up alone: ${SHELL_MS} ms; script itself: about $((max_ms - SHELL_MS)) ms"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
