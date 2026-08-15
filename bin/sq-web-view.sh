#!/usr/bin/env bash
# sq-web-view.sh - read-only web dashboard over a Squad base's operator state.
#
# Renders the state/<id>.meta, state/<id>.status, and state/<id>.busy-state
# records of one base as a single self-contained HTML page: one card per
# operator with the live busy classification, the last wake event, window,
# project, and the full status log. The viewer never writes anything: render
# prints HTML to stdout and serve answers HTTP requests with freshly rendered
# HTML.
#
# Why it exists: herdr ships a web dashboard, while Squad's tmux panes have no
# remote view. This is the smallest maintained equivalent - two subcommands, no
# framework, no daemon. serve uses only the Python 3 standard library for HTTP
# and re-runs the same bash renderer on every request, so there is exactly one
# renderer and the only process is the foreground server itself (Ctrl-C stops
# it).
#
# State-directory resolution, in order: --state <dir>, then
# $SQUAD_STATE_OVERRIDE, then $SQUAD_BASE/state, then the legacy
# $SQUAD_HOME/state, then <repo>/state. The same order as bin/sq-crew-state.sh,
# so a custom base needs no guessing.
#
# Usage:
#   sq-web-view.sh render [--state <dir>]    print the dashboard HTML to stdout
#   sq-web-view.sh serve  [--state <dir>] [--port <n>] [--bind <addr>]
#
# Options:
#   --state <dir>  state directory to read (default: resolved base state dir)
#   --port <n>     serve: TCP port to listen on (default 8080; 0 picks a free port)
#   --bind <addr>  serve: address to bind (default 127.0.0.1; use 0.0.0.0 to expose
#                  the unauthenticated, read-only dashboard on the LAN)
#   -h, --help     print this header
#
# Environment:
#   SQUAD_BASE, SQUAD_HOME, SQUAD_ROOT_OVERRIDE, SQUAD_STATE_OVERRIDE
#                  state-directory resolution, see above
#   SQ_WEB_VIEW_REFRESH
#                  seconds between automatic page reloads (default 10)
#
# serve requires python3 with only the standard library; render needs no
# python3 and runs on any POSIX bash (bash 3.2 included).
set -u

SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "$SELF")"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
REFRESH="${SQ_WEB_VIEW_REFRESH:-10}"
case "$REFRESH" in '' | *[!0-9]*) REFRESH=10 ;; esac

# shellcheck source=bin/sq-busy-lib.sh
. "$SCRIPT_DIR/sq-busy-lib.sh"

usage() {
  sed -n '2,/^[^#]/p' "$SELF" | sed '$d; s/^# \{0,1\}//'
}

fm_web_escape() {  # <string> -> HTML-escaped string
  local s=$1
  # In ${var//pat/repl}, an unescaped & in repl is the matched text, so every
  # replacement backslash-escapes its ampersand to emit a literal one.
  s=${s//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  s=${s//\"/\&quot;}
  printf '%s' "$s"
}

fm_web_mtime() {  # <path> -> epoch seconds (0 when unreadable)
  local p=$1
  stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null || printf '0'
}

fm_web_date() {  # <epoch> -> "YYYY-MM-DD HH:MM" (empty when unsupported)
  if date -d "@$1" '+%F %R' 2>/dev/null; then
    :
  else
    date -r "$1" '+%F %R' 2>/dev/null
  fi
}

fm_web_verb_color() {  # <verb> -> css pill class
  case "$1" in
    done) printf 'green' ;;
    working) printf 'amber' ;;
    blocked | failed) printf 'red' ;;
    needs-decision) printf 'blue' ;;
    paused) printf 'gray' ;;
    resolved) printf 'teal' ;;
    *) printf '' ;;
  esac
}

fm_web_busy_label() {  # <state> -> dot css class
  case "$1" in
    busy) printf 'busy' ;;
    idle) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_web_meta() {  # <meta-file> <key> -> value (empty when absent)
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_web_task_row: emit one card for a task id, reading live state records.
fm_web_task_row() {  # <state-dir> <id> <log-mtime>
  local state=$1 id=$2 log_mtime=$3
  local meta_file="$state/$id.meta" status_file="$state/$id.status"
  local window project harness kind mode effort model busy busy_rc b_state b_source
  local last_line verb color pill updated log_lines html_log line
  window=$(fm_web_meta "$meta_file" window)
  project=$(fm_web_meta "$meta_file" project)
  harness=$(fm_web_meta "$meta_file" harness)
  kind=$(fm_web_meta "$meta_file" kind)
  mode=$(fm_web_meta "$meta_file" mode)
  effort=$(fm_web_meta "$meta_file" effort)
  model=$(fm_web_meta "$meta_file" model)
  [ -n "$kind" ] || kind=strike

  busy=$(fm_busy_record_read "$state" "$id") && busy_rc=0 || busy_rc=$?
  if [ "$busy_rc" = 0 ]; then
    b_state=${busy%% *}
    b_source=${busy#* }
    b_source=${b_source%% *}
  else
    b_state=unknown
    b_source=$busy
  fi

  last_line=
  if [ -f "$status_file" ]; then
    last_line=$(grep -v '^[[:space:]]*$' "$status_file" 2>/dev/null | tail -1)
    log_lines=$(awk 'END { print NR }' "$status_file")
  else
    log_lines=0
  fi
  [ -n "${last_line:-}" ] || last_line='no wake events yet'

  verb=${last_line%%:*}
  verb=${verb%%\[key=*}
  verb=${verb#"${verb%%[![:space:]]*}"}
  verb=${verb%"${verb##*[![:space:]]}"}
  color=$(fm_web_verb_color "$verb")
  if [ -n "$color" ]; then
    pill="<span class=\"pill $color\">$(fm_web_escape "$verb")</span>"
  else
    pill=''
  fi

  updated=$(fm_web_date "$log_mtime")
  [ -n "$updated" ] && updated=" · updated $updated"

  html_log=''
  if [ "$log_lines" -gt 0 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      html_log="${html_log}$(fm_web_escape "$line")
"
    done < "$status_file"
  fi

  local project_name=$project
  case "$project_name" in
    */) project_name=${project_name%/} ;;
  esac
  project_name=${project_name##*/}
  local project_title=''
  [ -n "$project" ] && project_title=" title=\"$(fm_web_escape "$project")\""

  local window_html harness_html mode_html effort_html model_html meta_line
  window_html=$(fm_web_escape "$window")
  harness_html=$(fm_web_escape "$harness")
  mode_html=$(fm_web_escape "$mode")
  effort_html=$(fm_web_escape "$effort")
  model_html=$(fm_web_escape "$model")
  meta_line="window: $window_html"
  [ -n "$project" ] && meta_line="$meta_line · project: <span$project_title>$(fm_web_escape "$project_name")</span>"
  [ -n "$harness" ] && meta_line="$meta_line · $harness_html"
  [ -n "$mode" ] && meta_line="$meta_line · $mode_html"
  [ -n "$effort" ] && meta_line="$meta_line · effort $effort_html"
  [ -n "$model" ] && meta_line="$meta_line · model $model_html"
  [ -n "$updated" ] && meta_line="$meta_line$updated"

  printf '<article>
<div class="top"><span class="dot %s" title="%s: %s"></span><span class="id">%s</span>%s<span class="pill">%s</span></div>
<p class="meta">%s</p>
<p class="event">%s</p>' \
    "$(fm_web_busy_label "$b_state")" "$(fm_web_escape "$b_state")" "$(fm_web_escape "$b_source")" \
    "$(fm_web_escape "$id")" "$pill" "$(fm_web_escape "$kind")" \
    "$meta_line" \
    "$(fm_web_escape "$last_line")"

  if [ "$log_lines" -gt 0 ]; then
    printf '<details><summary>full status log · %s lines%s</summary><pre>%s</pre></details>' \
      "$log_lines" "$updated" "$html_log"
  fi
  printf '</article>
'
}

# fm_web_render: emit the complete dashboard HTML for a state directory.
fm_web_render() {  # <state-dir>
  local state=$1 now
  local -a rows
  local f id status_file mt status_mt sorted
  rows=()
  for f in "$state"/*.meta; do
    [ -f "$f" ] || continue
    id=${f##*/}
    id=${id%.meta}
    status_file="$state/$id.status"
    mt=$(fm_web_mtime "$f")
    status_mt=$(fm_web_mtime "$status_file")
    if [ "$status_mt" -gt "$mt" ] 2>/dev/null; then
      mt=$status_mt
    fi
    rows+=("$mt"$'\t'"$id")
  done

  now=$(date '+%F %R')
  printf '<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="%s">
<title>Squad operators</title>
<style>
:root{color-scheme:dark}
body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0f1115;color:#e6e8ec;margin:0;padding:1rem}
header,main,footer{max-width:56rem;margin-left:auto;margin-right:auto}
header{margin-bottom:1rem}
h1{font-size:1.25rem;margin:0 0 .25rem}
.sub{color:#9aa3af;font-size:.8rem;margin:0;overflow-wrap:anywhere}
main{display:grid;gap:.75rem}
article{background:#171a21;border:1px solid #262b36;border-radius:.5rem;padding:.75rem 1rem}
.top{display:flex;align-items:center;gap:.5rem;flex-wrap:wrap}
.id{font-weight:600;font-size:1rem}
.dot{width:.6rem;height:.6rem;border-radius:50%%;display:inline-block;flex:none}
.dot.busy{background:#34d399}
.dot.idle{background:#6b7280}
.dot.unknown{background:transparent;border:1px solid #6b7280}
.pill{font-size:.7rem;padding:.1rem .45rem;border-radius:999px;border:1px solid #3a4150;color:#cbd2dc}
.pill.green{color:#34d399;border-color:#1e3a2f}
.pill.amber{color:#fbbf24;border-color:#3f3317}
.pill.red{color:#f87171;border-color:#4a2323}
.pill.blue{color:#60a5fa;border-color:#1e3a5f}
.pill.gray{color:#9aa3af;border-color:#333a46}
.pill.teal{color:#2dd4bf;border-color:#164e43}
.meta{color:#9aa3af;font-size:.78rem;margin:.35rem 0 0;overflow-wrap:anywhere}
.event{margin:.45rem 0 0;font-size:.85rem;overflow-wrap:anywhere}
details{margin-top:.4rem;font-size:.75rem}
details summary{color:#9aa3af;cursor:pointer}
pre{background:#0b0d11;border:1px solid #262b36;border-radius:.35rem;padding:.5rem;overflow-x:auto;color:#cbd2dc;font-size:.72rem;white-space:pre-wrap;word-break:break-word}
footer{margin-top:1rem;color:#6b7280;font-size:.72rem}
code{background:#171a21;border:1px solid #262b36;border-radius:.25rem;padding:0 .25rem}
</style>
</head>
<body>
<header>
<h1>Squad operators</h1>
<p class="sub">Read-only view of <code>%s</code> · rendered %s · auto-refreshes every %s s</p>
</header>
<main>
' "$REFRESH" "$(fm_web_escape "$state")" "$(fm_web_escape "$now")" "$REFRESH"

  if [ "${#rows[@]}" -gt 0 ]; then
    sorted=$(printf '%s\n' "${rows[@]:-}" | sort -t $'\t' -k1,1nr -k2,2)
    while IFS=$'\t' read -r mt id; do
      fm_web_task_row "$state" "$id" "$mt"
    done <<< "$sorted"
    printf '<footer>%s operator(s) · read-only · each card shows the last wake event, not a reconciled current state</footer>
' "${#rows[@]}"
  else
    printf '<p class="sub">No operators found in %s. Start one with bin/sq-spawn.sh, or point --state at the base you want to watch.</p>
' "$(fm_web_escape "$state")"
  fi

  printf '</main>
</body>
</html>
'
}

cmd_render() {  # [--state <dir>]
  local state=$STATE
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state)
        [ "$#" -ge 2 ] || { echo "render: --state needs a value" >&2; exit 2; }
        state=$2
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "render: unknown option: $1" >&2
        exit 2
        ;;
    esac
  done
  if [ ! -d "$state" ]; then
    echo "render: state directory not found: $state" >&2
    exit 1
  fi
  fm_web_render "$state"
}

cmd_serve() {  # [--state <dir>] [--port <n>] [--bind <addr>]
  local state=$STATE port=8080 bind=127.0.0.1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state)
        [ "$#" -ge 2 ] || { echo "serve: --state needs a value" >&2; exit 2; }
        state=$2
        shift 2
        ;;
      --port)
        [ "$#" -ge 2 ] || { echo "serve: --port needs a value" >&2; exit 2; }
        port=$2
        shift 2
        ;;
      --bind)
        [ "$#" -ge 2 ] || { echo "serve: --bind needs a value" >&2; exit 2; }
        bind=$2
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "serve: unknown option: $1" >&2
        exit 2
        ;;
    esac
  done
  case "$port" in
    '' | *[!0-9]*)
      echo "serve: --port must be a number" >&2
      exit 2
      ;;
  esac
  if [ ! -d "$state" ]; then
    echo "serve: state directory not found: $state" >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "serve: python3 is required (standard library only)" >&2
    exit 1
  fi
  SQ_WEB_VIEW_BIND="$bind" SQ_WEB_VIEW_PORT="$port" exec python3 - "$SELF" render --state "$state" <<'PY'
import html
import http.server
import os
import subprocess
import sys

RENDER_CMD = sys.argv[1:]
BIND = os.environ.get("SQ_WEB_VIEW_BIND", "127.0.0.1")
PORT = int(os.environ.get("SQ_WEB_VIEW_PORT", "8080"))


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "sq-web-view"

    def do_GET(self):
        if self.path not in ("/", "/index.html"):
            self.send_error(404, "not found")
            return
        proc = subprocess.run(RENDER_CMD, capture_output=True, text=True)
        if proc.returncode != 0:
            detail = proc.stderr or proc.stdout or "render exited %s" % proc.returncode
            body = (
                "<!DOCTYPE html><html><body>"
                "<h1>sq-web-view render failed</h1><pre>"
                + html.escape(detail)
                + "</pre></body></html>"
            )
            status = 500
        else:
            body = proc.stdout
            status = 200
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass


httpd = http.server.ThreadingHTTPServer((BIND, PORT), Handler)
actual = httpd.server_address[1]
print("Serving Squad web view at http://%s:%s/ (Ctrl-C to stop)" % (BIND, actual), flush=True)
httpd.serve_forever()
PY
}

main() {
  local cmd=$1
  shift || true
  case "$cmd" in
    render) cmd_render "$@" ;;
    serve) cmd_serve "$@" ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown command: $cmd" >&2
      usage
      exit 2
      ;;
  esac
}

[ "$#" -ge 1 ] || { usage; exit 2; }
main "$@"
