#!/bin/sh
# EOL Time: opt-in time capture for Claude Code (plugin 1.3.0).
#
# Usage (from hooks.json): sh capture.sh <kind>
#   kind: session_start prompt tool_start tool_end stop session_end
#
# WHAT LEAVES THIS COMPUTER, and nothing else: the session id, a timestamp,
# the event kind, the tool-use id, the computer's time zone name, the folder
# NAME (never the full path), the git branch and the subject lines of the
# person's own commits from the last 3 hours. Never prompts, replies, code,
# file names, paths or transcripts. Nothing at all is queued or sent while
# capture is off (the default) or paused, or from a folder on the person's
# ignored list (as last sent by the server).
#
# Claude Code facts this relies on, checked 2026-10-30 against
# https://code.claude.com/docs/en/plugins-reference (Plugin manifest
# reference: "User configuration", "Environment variables") and
# https://code.claude.com/docs/en/hooks (Hooks reference):
#   - userConfig values reach hook processes as CLAUDE_PLUGIN_OPTION_<KEY>,
#     "exported to hook processes for every option, with <KEY> uppercased",
#     so the plugin's api_key is $CLAUDE_PLUGIN_OPTION_API_KEY. A shell-form
#     hook command may NOT reference ${user_config.*} (it fails to run).
#   - CLAUDE_PLUGIN_DATA is exported to hook processes: ~/.claude/plugins/
#     data/<id>/, created on first reference, kept across plugin updates.
#     CLAUDE_PLUGIN_ROOT changes on every update, so no state is kept there.
#   - Hooks get JSON on stdin with session_id, transcript_path, cwd,
#     permission_mode and hook_event_name; PreToolUse/PostToolUse also carry
#     tool_name, tool_input and tool_use_id. A failed tool fires
#     PostToolUseFailure instead of PostToolUse, so hooks.json maps both to
#     tool_end.
#   - SessionStart (and UserPromptSubmit) add plain-text stdout to Claude's
#     context; hookSpecificOutput.additionalContext is the JSON form. Every
#     other event's stdout goes to the debug log only. So this script prints
#     nothing at all except the SessionStart note.
#   - Shell-form hook commands run in Git Bash on Windows (PowerShell only
#     when Git Bash is missing), so POSIX sh plus curl is what we can count on.
#     No jq, Node or Python is assumed.
#   - The default command timeout is 600 s (30 s on UserPromptSubmit) and
#     SessionEnd hooks get 1.5 s in all; hooks.json sets 5 s. Anything slow
#     (git, curl) runs in a detached background job with all output
#     redirected, so Claude Code never waits on the network.
#
# Every hook reads all of stdin, even with capture off (a hook that exits
# early drains it with cat), so a large PostToolUse payload never meets a
# closed pipe in Claude Code. Prompt and tool hooks read it in
# the foreground and append their line before exiting; SessionStart, Stop and
# SessionEnd hand it to their background job, which also runs git.
#
# Dev testing only: EOL_TIME_BASE_URL (default https://time.eol.agency).

kind=$1
base=${EOL_TIME_BASE_URL:-https://time.eol.agency}
base=${base%/}
key=${CLAUDE_PLUGIN_OPTION_API_KEY:-}
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  dir=$CLAUDE_PLUGIN_DATA
else
  dir=${HOME:-.}/.eol-time
fi
state=$dir/state.json
queue=$dir/queue.jsonl

QUEUE_MAX_BYTES=1048576
QUEUE_KEEP_BYTES=900000
BATCH_MAX=500
FLUSH_EVERY=60

OFFER="EOL Time can record when you work in Claude Code (times and folder names only, never your code or conversation). Unsorted time is yours alone. Want to turn it on?"

case $kind in
  session_start|prompt|tool_start|tool_end|stop|session_end) ;;
  *) cat >/dev/null 2>&1; exit 0 ;;
esac

[ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || { cat >/dev/null 2>&1; exit 0; }

# ---- small helpers (shell builtins only on the hot path) -------------------

# json_get KEY TEXT: the first "KEY": value in TEXT, unquoted, into $jv.
json_get() {
  jv=
  case $2 in *"\"$1\":"*) ;; *) return 1 ;; esac
  jv=${2#*\"$1\":}
  jv=${jv# }
  case $jv in
    \"*) jv=${jv#\"}; jv=${jv%%\"*} ;;
    *) jv=${jv%%[,\}]*} ;;
  esac
  return 0
}

state_load() {
  st=
  [ -f "$state" ] && IFS= read -r st < "$state"
  json_get enabled "$st"; S_enabled=${jv:-false}
  json_get paused "$st"; S_paused=${jv:-false}
  json_get unsorted_minutes "$st"; S_unsorted=${jv:-0}
  json_get yesterday_unsorted_minutes "$st"; S_yesterday=${jv:-0}
  json_get checked_at "$st"; S_checked_at=$jv
  json_get offered_at "$st"; S_offered_at=$jv
  json_get nudged_on "$st"; S_nudged_on=$jv
  json_get last_flush "$st"; S_last_flush=${jv:-0}
  json_get time_zone "$st"; S_time_zone=$jv
  json_get checked_on "$st"; S_checked_on=$jv
  ignored_from "$st"; S_ignored=$iv
  case $S_unsorted in ''|*[!0-9]*) S_unsorted=0 ;; esac
  case $S_yesterday in ''|*[!0-9]*) S_yesterday=0 ;; esac
  case $S_last_flush in ''|*[!0-9]*) S_last_flush=0 ;; esac
}

# state_save [direct]: write the S_ variables back. Background jobs write a
# temporary file and rename it over state.json; the SessionStart foreground
# writes in place ("direct"), which saves an `mv` process.
state_save() {
  tmp=$state.$$
  [ "${1:-}" = direct ] && tmp=$state
  printf '{"enabled":%s,"paused":%s,"unsorted_minutes":%s,"yesterday_unsorted_minutes":%s,"checked_at":"%s","checked_on":"%s","offered_at":"%s","nudged_on":"%s","last_flush":%s,"time_zone":"%s","ignored_folders":[%s]}\n' \
    "$S_enabled" "$S_paused" "$S_unsorted" "$S_yesterday" "$S_checked_at" "$S_checked_on" "$S_offered_at" \
    "$S_nudged_on" "$S_last_flush" "$S_time_zone" "$S_ignored" 2>/dev/null > "$tmp" || return 0
  [ "$tmp" = "$state" ] && return 0
  mv -f "$tmp" "$state" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# ignored_from TEXT: the inside of the first "ignored_folders":[...] in TEXT
# (JSON strings, comma separated) into $iv; empty when there is none.
ignored_from() {
  iv=
  case $1 in *'"ignored_folders":['*) ;; *) return 0 ;; esac
  iv=${1#*'"ignored_folders":['}
  iv=${iv%%]*}
}

# Settings from a server answer (GET /settings, or POST /activity's
# "settings") into the S_ variables, with when (and on which local date)
# they were read.
settings_from() {
  json_get enabled "$1" && case $jv in true|false) S_enabled=$jv ;; esac
  json_get paused "$1" && case $jv in true|false) S_paused=$jv ;; esac
  json_get unsorted_minutes "$1" && case $jv in ''|*[!0-9]*) ;; *) S_unsorted=$jv ;; esac
  json_get yesterday_unsorted_minutes "$1" && case $jv in ''|*[!0-9]*) ;; *) S_yesterday=$jv ;; esac
  case $1 in *'"ignored_folders":'*) ignored_from "$1"; S_ignored=$iv ;; esac
  now; S_checked_at=$now_iso
  local_date; S_checked_on=$today
  return 0
}

# local_date: this computer's date into $today: bash's printf builtin where
# it has %()T, else `date`.
local_date() {
  today=
  printf -v today '%(%Y-%m-%d)T' -1 2>/dev/null
  case $today in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) today=$(date +%Y-%m-%d 2>/dev/null) ;;
  esac
}

# ignored: the current folder is on the person's ignored list (from the last
# settings the server sent). Its events are never queued, so the name never
# leaves the computer. The server drops them too.
ignored() {
  case ",$S_ignored," in *",\"$folder\","*) return 0 ;; esac
  return 1
}

# drain: read and throw away the rest of stdin, so Claude Code's write of a
# large payload never meets a closed pipe after this script has exited.
drain() { cat >/dev/null 2>&1; }

pad2() { case $1 in ?) p=0$1 ;; *) p=$1 ;; esac; }

# now: $now_s (epoch seconds) and $now_iso (UTC, milliseconds). bash 5 has
# EPOCHREALTIME, which saves a `date` process (slow to start on Windows).
now() {
  t=${EPOCHREALTIME:-}
  # Older shells (macOS /bin/sh is bash 3.2): one perl process for the
  # milliseconds, else whole seconds from date.
  [ -n "$t" ] || t=$(perl -MTime::HiRes=time -e 'printf "%.6f", time' 2>/dev/null)
  case $t in
    [0-9]*[.,][0-9]*)
      now_s=${t%%[.,]*}
      ms=${t#*[.,]}000
      ms=${ms%"${ms#???}"}
      ;;
    *)
      now_s=$(date -u +%s)
      ms=000
      ;;
  esac
  days=$((now_s / 86400)); rem=$((now_s % 86400))
  z=$((days + 719468)); era=$((z / 146097)); doe=$((z - era * 146097))
  yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
  y=$((yoe + era * 400)); doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
  mp=$(((5 * doy + 2) / 153)); d=$((doy - (153 * mp + 2) / 5 + 1))
  if [ "$mp" -lt 10 ]; then m=$((mp + 3)); else m=$((mp - 9)); fi
  [ "$m" -le 2 ] && y=$((y + 1))
  pad2 "$m"; m=$p; pad2 "$d"; d=$p
  pad2 $((rem / 3600)); hh=$p; pad2 $((rem % 3600 / 60)); mi=$p; pad2 $((rem % 60)); ss=$p
  now_iso="$y-$m-${d}T$hh:$mi:$ss.${ms}Z"
}

# JSON-escaped backslashes (\\) back to one, for a cwd handed to git.
unescape() {
  r=; s=$1
  while :; do
    case $s in
      *'\\'*) r=$r${s%%'\\'*}'\'; s=${s#*'\\'} ;;
      *) r=$r$s; break ;;
    esac
  done
}

# ---- the event ---------------------------------------------------------------

state_load
now

capture_on=0
[ "$S_enabled" = true ] && [ "$S_paused" != true ] && capture_on=1

# Off: every hook but SessionStart stops here, after draining stdin.
if [ "$capture_on" != 1 ] && [ "$kind" != session_start ]; then
  drain
  exit 0
fi

# read_input: session_id and cwd from the hook's stdin, the FIRST of each
# (Claude Code puts its own fields before tool_input); tool_use_id the LAST
# (it comes after tool_input, which may hold a decoy), for tool events only;
# and the folder NAME from cwd. One sed process reads all of stdin; nothing
# else is kept.
read_input() {
  sid=; cwd=; tuid=
  fields=$(sed -n -E '
h
s/"session_id" *: *"/@@EOLS@@/
s/.*@@EOLS@@([^"]*)".*/S=\1/p
g
s/"cwd" *: *"/@@EOLC@@/
s/.*@@EOLC@@(([^"\\]|\\.)*)".*/C=\1/p
g
s/.*"tool_use_id" *: *"([^"]*)".*/T=\1/p
' 2>/dev/null)
  nl='
'
  while [ -n "$fields" ]; do
    f=${fields%%"$nl"*}
    case $f in
      S=*) [ -z "$sid" ] && sid=${f#S=} ;;
      C=*) [ -z "$cwd" ] && cwd=${f#C=} ;;
      T=*) [ -z "$tuid" ] && tuid=${f#T=} ;;
    esac
    case $fields in *"$nl"*) fields=${fields#*"$nl"} ;; *) fields= ;; esac
  done
  case $sid in ''|*[!A-Za-z0-9_-]*) sid= ;; esac
  case $tuid in *[!A-Za-z0-9_-]*) tuid= ;; esac
  case $kind in tool_start|tool_end) ;; *) tuid= ;; esac

  # The folder NAME only: the last segment of cwd, / or \ separated.
  folder=$cwd
  while :; do
    case $folder in
      */) folder=${folder%/} ;;
      *'\\') folder=${folder%'\\'} ;;
      *) break ;;
    esac
  done
  folder=${folder##*/}
  folder=${folder##*\\}
  case $folder in *[\"\\]*|'') folder=unknown ;; esac
  [ -n "$cwd" ] || folder=unknown
}

event_line() {
  line="{\"session_id\":\"$sid\",\"at\":\"$now_iso\",\"kind\":\"$kind\""
  [ -n "$tuid" ] && line="$line,\"tool_use_id\":\"$tuid\""
  line="$line,\"folder\":\"$folder\""
  [ -n "$branch" ] && line="$line,\"branch\":\"$branch\""
  [ -n "$commits" ] && line="$line,\"commits\":[$commits]"
  [ -n "$S_time_zone" ] && line="$line,\"time_zone\":\"$S_time_zone\""
  line="$line}"
}

# ---- background work (git and network): never waited on ---------------------

# utf8_clean: stdin to stdout with bytes that aren't UTF-8 removed (iconv -c),
# so one odd commit subject can't make a batch unreadable. Without iconv,
# lines with any non-ASCII byte are dropped instead.
utf8_clean() {
  if command -v iconv >/dev/null 2>&1; then
    iconv -c -f UTF-8 -t UTF-8 2>/dev/null
  else
    LC_ALL=C grep -v '[^ -~]' 2>/dev/null
  fi
}

git_branch() {
  branch=
  [ -n "$cwd" ] || return 0
  unescape "$cwd"
  branch=$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null | utf8_clean)
  case $branch in HEAD|*[\"\\]*|*[[:cntrl:]]*) branch= ;; esac
}

git_commits() {
  commits=
  [ -n "$cwd" ] || return 0
  unescape "$cwd"
  email=$(git -C "$r" config user.email 2>/dev/null)
  [ -n "$email" ] || return 0
  commits=$(git -C "$r" log --since="3 hours ago" --author="$email" --format=%s -n 20 2>/dev/null | utf8_clean |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]/ /g' -e 's/.*/"&"/' | paste -sd, - 2>/dev/null)
}

# The shape of a queue line, as event_line writes it. Anything else (a line
# cut short by a full disk, a hand edit) is dropped before sending, so it
# can't make the server refuse the whole batch.
SHAPE='^\{"session_id":"[A-Za-z0-9_-]+","at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z","kind":"(session_start|prompt|tool_start|tool_end|stop|session_end)"(,"tool_use_id":"[A-Za-z0-9_-]+")?,"folder":"[^"\\]*"(,"branch":"[^"\\]*")?(,"commits":\[("([^"\\]|\\.)*"(,"([^"\\]|\\.)*")*)?\])?(,"time_zone":"[A-Za-z0-9_/+-]+")?\}$'

# capture_stopped: the settings just read say off or paused.
capture_stopped() { [ "$S_enabled" != true ] || [ "$S_paused" = true ]; }

# The computer's IANA zone, or nothing.
detect_tz() {
  tz=${TZ#:}
  case $tz in */*) ;; *) tz= ;; esac
  if [ -z "$tz" ] && [ -L /etc/localtime ]; then
    link=$(readlink /etc/localtime 2>/dev/null)
    case $link in */zoneinfo/*) tz=${link#*/zoneinfo/} ;; esac
  fi
  if [ -z "$tz" ] && command -v tzutil >/dev/null 2>&1; then
    # Windows. Only the zones EOL works in; the UTC+8 zones without daylight
    # saving that a Philippine Windows install may carry all mean Manila here.
    case $(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' tzutil /g 2>/dev/null) in
      "Singapore Standard Time"|"Taipei Standard Time"|"China Standard Time") tz=Asia/Manila ;;
      "Pacific Standard Time") tz=America/Los_Angeles ;;
      "Eastern Standard Time") tz=America/New_York ;;
      UTC|"Coordinated Universal Time") tz=UTC ;;
    esac
  fi
  case $tz in *[!A-Za-z0-9_/+-]*) tz= ;; esac
}

trim() {
  [ -f "$1" ] || return 0
  size=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  case $size in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -gt "$QUEUE_MAX_BYTES" ] || return 0
  tail -c "$QUEUE_KEEP_BYTES" "$1" | sed 1d > "$1.trim" && mv -f "$1.trim" "$1"
}

curl_key() {
  printf 'header = "Authorization: Bearer %s"\n' "$key"
}

# Send the queue: queue.jsonl -> sending.jsonl, lines not in the event shape
# dropped, POSTed 500 at a time. A 2xx drops what was sent and saves the
# answer's settings (if they say off or paused, the rest of the queue is
# thrown away); 400/413/422 (a batch the server will never take) drops it
# too; anything else (no network, a bad or revoked key, a 5xx) puts it back
# on the queue, capped near 1 MB, for the next send.
flush() {
  cd "$dir" || return 0
  # flush.lock/at holds when the lock was taken; a lock older than 2 minutes
  # is a send that died, and is taken over. A lock with no `at` yet was
  # probably taken a moment ago; it counts as dead only when the last send
  # started over 5 minutes ago. (No `find -mmin`: on Windows PATH may give
  # System32's find.exe instead.)
  now
  if ! mkdir flush.lock 2>/dev/null; then
    at=
    [ -f flush.lock/at ] && IFS= read -r at < flush.lock/at
    case $at in
      ''|*[!0-9]*)
        state_load
        [ $((now_s - S_last_flush)) -gt 300 ] || return 0
        ;;
      *) [ $((now_s - at)) -gt 120 ] || return 0 ;;
    esac
    rm -rf flush.lock 2>/dev/null
    mkdir flush.lock 2>/dev/null || return 0
  fi
  printf '%s\n' "$now_s" > flush.lock/at 2>/dev/null
  state_load; S_last_flush=$now_s; state_save

  if [ -s queue.jsonl ] && mv -f queue.jsonl "queue.$$" 2>/dev/null; then
    cat "queue.$$" >> sending.jsonl && rm -f "queue.$$"
  fi
  trim sending.jsonl
  if [ -f sending.jsonl ]; then
    LC_ALL=C grep -E "$SHAPE" sending.jsonl > sending.ok 2>/dev/null
    mv -f sending.ok sending.jsonl 2>/dev/null
  fi

  sent=0
  while [ -n "$key" ] && [ -s sending.jsonl ] && [ "$sent" -lt 10 ]; do
    sent=$((sent + 1))
    head -n "$BATCH_MAX" sending.jsonl > batch.jsonl
    { printf '{"events":['; sed '$!s/$/,/' batch.jsonl | tr -d '\n'; printf ']}'; } > body.json
    rm -f resp.json
    code=$(curl_key | curl -sS -m 10 -K - -X POST \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      --data-binary @body.json -o resp.json -w '%{http_code}' \
      "$base/api/v1/time_capture/activity" 2>/dev/null)
    case $code in
      2??|400|413|422)
        tail -n +"$((BATCH_MAX + 1))" sending.jsonl > sending.rest && mv -f sending.rest sending.jsonl
        case $code in
          2??)
            body=; [ -f resp.json ] && IFS= read -r body < resp.json
            state_load; settings_from "$body"; state_save
            # Turned off or paused (on the web, say): the rest is never sent.
            if capture_stopped; then
              rm -f sending.jsonl queue.jsonl
              break
            fi
            ;;
        esac
        ;;
      *) break ;;
    esac
  done

  if [ -s sending.jsonl ]; then
    cat sending.jsonl >> queue.jsonl
  fi
  rm -f sending.jsonl sending.rest batch.jsonl body.json resp.json
  trim queue.jsonl
  rm -rf flush.lock 2>/dev/null
  return 0
}

fetch_settings() {
  [ -n "$key" ] || return 0
  cd "$dir" || return 0
  rm -f "settings.$$"
  code=$(curl_key | curl -sS -m 10 -K - -H 'Accept: application/json' \
    -o "settings.$$" -w '%{http_code}' "$base/api/v1/time_capture/settings" 2>/dev/null)
  case $code in
    2??)
      body=; [ -f "settings.$$" ] && IFS= read -r body < "settings.$$"
      state_load; settings_from "$body"; state_save
      capture_stopped && rm -f queue.jsonl
      ;;
  esac
  rm -f "settings.$$"
}

# background FN: run FN detached, all output thrown away. A background job's
# stdin is /dev/null unless we hand it over, so the hook's stdin goes along
# on fd 3 for the jobs that read it (SessionStart, Stop, SessionEnd): reading
# it there keeps a process start (slow on Windows) off the foreground.
background() {
  ( "$@" ) </dev/null >/dev/null 2>&1 &
}
background_with_input() {
  exec 3<&0
  ( exec 0<&3 3<&-; "$@" ) >/dev/null 2>&1 &
  exec 3<&-
}

bg_session_start() {
  read_input
  exec 0</dev/null
  fetch_settings
  detect_tz
  state_load
  if [ -n "$tz" ] && [ "$tz" != "$S_time_zone" ]; then
    S_time_zone=$tz; state_save
  fi
  [ "$S_enabled" = true ] && [ "$S_paused" != true ] || return 0
  [ -n "$sid" ] || return 0
  ignored && return 0
  git_branch
  event_line
  printf '%s\n' "$line" >> "$queue"
  flush
}

bg_stop() {
  read_input
  exec 0</dev/null
  if [ -z "$sid" ] || ignored; then
    flush
    return 0
  fi
  [ "$kind" = stop ] && git_branch
  git_commits
  event_line
  printf '%s\n' "$line" >> "$queue"
  flush
}

case $kind in
  session_start)
    background_with_input bg_session_start
    [ -n "$key" ] || exit 0
    if [ "$S_enabled" != true ]; then
      if [ -z "$S_offered_at" ]; then
        S_offered_at=$now_iso; state_save direct
        printf '%s\n' "EOL Time plugin note, shown once on this computer: in your first reply, call eol.capture.settings with no arguments. If enabled is already true, say nothing about this. Otherwise offer the user this, once, in these words: \"$OFFER\" If they say yes, call eol.capture.settings with {\"enabled\": true}. If they say no, leave it; they can turn it on later on the To sort page or by saying \"turn on time capture\"."
      fi
    elif [ "$S_yesterday" -gt 0 ]; then
      # Only a total read today means "yesterday": an older one would be the
      # day before's. The first session of a day refreshes it in the
      # background, so the note can come from the next one.
      local_date
      if [ "$S_checked_on" = "$today" ] && [ "$S_nudged_on" != "$today" ]; then
        S_nudged_on=$today; state_save direct
        pad2 $((S_yesterday % 60))
        printf '%s\n' "EOL Time: $((S_yesterday / 60)):$p unsorted from yesterday. Offer once to sort it with the eol-time-sort-my-time skill."
      fi
    fi
    ;;
  stop|session_end)
    background_with_input bg_stop
    ;;
  *)
    read_input
    [ -n "$sid" ] || exit 0
    ignored && exit 0
    branch=; commits=
    event_line
    printf '%s\n' "$line" 2>/dev/null >> "$queue"
    if [ $((now_s - S_last_flush)) -gt "$FLUSH_EVERY" ]; then
      background flush
    fi
    ;;
esac
exit 0
