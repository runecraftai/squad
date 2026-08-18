#!/usr/bin/env bash
# Interactive decision card picker for Squad.
# Reads a decision card JSON on stdin, renders an interactive picker,
# outputs the selected option as JSON to stdout.
#
# Usage: echo '{"version":1,...}' | bin/sq-ask.sh [options]
#        bin/sq-ask.sh '{"version":1,...}' [options]
#
# Options:
#   --format <fmt>    Output format: json (default), text, id
#   --backend <tool>  Force picker backend: fzf, whiptail, dialog, bash (default: auto)
#   --no-interactive  Fail if no interactive terminal available
#   --validate        Validate card JSON and exit
#   --render          Render card text and exit (no picker)
#   --help            Show this help
#
# Picker backend priority: fzf > whiptail > dialog > bash (pure fallback)
# Output is always JSON to stdout (except --format text/id).
# Exit codes: 0=selected, 1=cancelled, 2=invalid card, 3=no terminal
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required but not found in PATH" >&2
  exit 2
fi

# --- JSON escaping helper ---
escape_json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# --- defaults ---
FORMAT="json"
BACKEND=""
NO_INTERACTIVE=false
VALIDATE_ONLY=false
RENDER_ONLY=false

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) FORMAT="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --no-interactive) NO_INTERACTIVE=true; shift ;;
    --validate) VALIDATE_ONLY=true; shift ;;
    --render) RENDER_ONLY=true; shift ;;
    --help)
      sed -n '2,/^set -eu/p' "$0" | head -n -1 | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *) break ;;
  esac
done

# --- read stdin or positional argument ---
CARD_JSON=""
if [[ $# -gt 0 ]]; then
  CARD_JSON="$1"
elif [[ -t 0 ]]; then
  echo "error: no decision card JSON on stdin or as argument" >&2
  exit 2
else
  CARD_JSON="$(cat)"
fi

# --- validate JSON structure ---
validate_card() {
  local json="$1"

  # Check it's valid JSON
  if ! printf '%s' "$json" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "error: invalid JSON" >&2
    return 1
  fi

  # Check required fields
  local version id title question default_option_id
  version=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',0))")
  id=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
  title=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))")
  question=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('question',''))")
  default_option_id=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_option_id',''))")

  if [[ "$version" != "1" ]]; then
    echo "error: unsupported schema version: $version (expected 1)" >&2
    return 1
  fi
  if [[ -z "$id" ]]; then
    echo "error: missing required field: id" >&2
    return 1
  fi
  if [[ -z "$title" ]]; then
    echo "error: missing required field: title" >&2
    return 1
  fi
  if [[ -z "$question" ]]; then
    echo "error: missing required field: question" >&2
    return 1
  fi
  if [[ -z "$default_option_id" ]]; then
    echo "error: missing required field: default_option_id" >&2
    return 1
  fi

  # Check options exist and have unique ids
  local opt_count
  opt_count=$(printf '%s' "$json" | python3 -c "
import sys,json
card = json.load(sys.stdin)
opts = card.get('options', [])
print(len(opts))
")
  if [[ "$opt_count" -lt 1 ]]; then
    echo "error: must have at least 1 option" >&2
    return 1
  fi

  # Check default references an existing option
  local has_default
  has_default=$(printf '%s' "$json" | python3 -c "
import sys,json
card = json.load(sys.stdin)
default_id = card.get('default_option_id','')
opts = card.get('options', [])
print('yes' if any(o.get('id') == default_id for o in opts) else 'no')
")
  if [[ "$has_default" != "yes" ]]; then
    echo "error: default_option_id '$default_option_id' not found in options" >&2
    return 1
  fi

  # Check option ids are unique
  local ids_unique
  ids_unique=$(printf '%s' "$json" | python3 -c "
import sys,json
card = json.load(sys.stdin)
opts = card.get('options', [])
ids = [o.get('id','') for o in opts]
print('yes' if len(ids) == len(set(ids)) else 'no')
")
  if [[ "$ids_unique" != "yes" ]]; then
    echo "error: option ids must be unique" >&2
    return 1
  fi

  # Check option labels exist
  local labels_ok
  labels_ok=$(printf '%s' "$json" | python3 -c "
import sys,json
card = json.load(sys.stdin)
opts = card.get('options', [])
print('yes' if all(o.get('label','') for o in opts) else 'no')
")
  if [[ "$labels_ok" != "yes" ]]; then
    echo "error: all options must have non-empty labels" >&2
    return 1
  fi

  return 0
}

# --- render card text ---
render_card() {
  local json="$1"

  printf '%s' "$json" | python3 -c "
import sys,json

card = json.load(sys.stdin)
title = card.get('title','')
question = card.get('question','')
context = card.get('context','')
options = card.get('options',[])
default_id = card.get('default_option_id','')
allow_free_text = card.get('allow_free_text', True)

# Title line
print('━━━ DECISION: {} ━━━'.format(title))
print()
print(question)

# Context
if context:
    print()
    print(context)

# Options
print()
print('Options:')
for i, opt in enumerate(options, 1):
    oid = opt.get('id','')
    label = opt.get('label','')
    desc = opt.get('description','')
    recommended = opt.get('recommended', False) or oid == default_id
    line = '  {}. {}'.format(i, label)
    if desc:
        line += ' - {}'.format(desc)
    if recommended:
        line += '  ← recommended'
    print(line)

# Free text hint
if allow_free_text:
    print('  0. Type something (free text)')

# Your call line
default_label = ''
for opt in options:
    if opt.get('id') == default_id:
        default_label = opt.get('label','')
        break
if allow_free_text:
    print()
    print('Your call [{}]: _'.format(default_label))
else:
    print()
    print('Your call [{}]: _'.format(default_label))
"
}

# --- validate mode ---
if $VALIDATE_ONLY; then
  if validate_card "$CARD_JSON"; then
    echo "valid"
    exit 0
  else
    exit 2
  fi
fi

# --- render mode ---
if $RENDER_ONLY; then
  render_card "$CARD_JSON"
  exit 0
fi

# --- validate before picking ---
if ! validate_card "$CARD_JSON"; then
  exit 2
fi

# --- detect picker backend ---
detect_backend() {
  if [[ -n "$BACKEND" ]]; then
    echo "$BACKEND"
    return
  fi

  if [[ -t 1 ]] && command -v fzf >/dev/null 2>&1; then
    echo "fzf"
  elif [[ -t 1 ]] && command -v whiptail >/dev/null 2>&1; then
    echo "whiptail"
  elif [[ -t 1 ]] && command -v dialog >/dev/null 2>&1; then
    echo "dialog"
  elif [[ -t 1 ]]; then
    echo "bash"
  else
    echo "none"
  fi
}

DETECTED_BACKEND=$(detect_backend)

if [[ "$DETECTED_BACKEND" == "none" ]]; then
  if $NO_INTERACTIVE; then
    echo "error: no interactive terminal available" >&2
    exit 3
  fi
  # Non-interactive: output default
  DETECTED_BACKEND="default"
fi

# --- extract card data for picker ---
CARD_DATA=$(printf '%s' "$CARD_JSON" | python3 -c "
import sys,json

card = json.load(sys.stdin)
title = card.get('title','')
question = card.get('question','')
context = card.get('context','')
options = card.get('options',[])
default_id = card.get('default_option_id','')
allow_free_text = card.get('allow_free_text', True)
card_id = card.get('id','')

# Find default index
default_idx = 0
for i, opt in enumerate(options):
    if opt.get('id') == default_id:
        default_idx = i
        break

# Output structured data
import json as j
output = {
    'card_id': card_id,
    'title': title,
    'question': question,
    'context': context,
    'allow_free_text': allow_free_text,
    'default_idx': default_idx,
    'options': []
}
for i, opt in enumerate(options):
    oid = opt.get('id','')
    label = opt.get('label','')
    desc = opt.get('description','')
    recommended = opt.get('recommended', False) or oid == default_id
    display = label
    if desc:
        display += ' - ' + desc
    if recommended:
        display += '  ← recommended'
    output['options'].append({
        'id': oid,
        'label': label,
        'display': display,
        'recommended': recommended
    })
print(j.dumps(output))
")

# Parse card data
CARD_ID=$(printf '%s' "$CARD_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['card_id'])")
TITLE=$(printf '%s' "$CARD_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
QUESTION=$(printf '%s' "$CARD_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['question'])")
CONTEXT=$(printf '%s' "$CARD_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['context'])")
ALLOW_FREE_TEXT=$(printf '%s' "$CARD_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['allow_free_text'])")
DEFAULT_IDX=$(printf '%s' "$CARD_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['default_idx'])")

# Get options as arrays
OPTION_IDS=()
OPTION_LABELS=()
OPTION_DISPLAYS=()
OPTION_RECOMMENDED=()

while IFS= read -r line; do
  OPTION_IDS+=("$line")
done < <(printf '%s' "$CARD_DATA" | python3 -c "import sys,json; [print(o['id']) for o in json.load(sys.stdin)['options']]")

while IFS= read -r line; do
  OPTION_LABELS+=("$line")
done < <(printf '%s' "$CARD_DATA" | python3 -c "import sys,json; [print(o['label']) for o in json.load(sys.stdin)['options']]")

while IFS= read -r line; do
  OPTION_DISPLAYS+=("$line")
done < <(printf '%s' "$CARD_DATA" | python3 -c "import sys,json; [print(o['display']) for o in json.load(sys.stdin)['options']]")

# --- pick using selected backend ---
pick_fzf() {
  local prompt="━━━ $TITLE ━━━ $QUESTION"
  local selected

  # Build fzf input
  local fzf_input=""
  for i in "${!OPTION_DISPLAYS[@]}"; do
    fzf_input+="$((i+1)). ${OPTION_DISPLAYS[$i]}"$'\n'
  done
  if [[ "$ALLOW_FREE_TEXT" == "True" ]]; then
    fzf_input+="0. Type something (free text)"$'\n'
  fi

  selected=$(printf '%s' "$fzf_input" | fzf \
    --prompt="$prompt " \
    --height=40% \
    --layout=reverse \
    --border \
    --header="$CONTEXT" \
    --pointer="▶" \
    --marker="✓" \
    2>/dev/null) || true

  if [[ -z "$selected" ]]; then
    echo "CANCELLED"
    return 1
  fi

  # Parse selection
  if [[ "$selected" =~ ^0\. ]]; then
    echo "FREE_TEXT"
  else
    local idx
    idx=$(echo "$selected" | sed 's/^\([0-9]*\)\..*/\1/')
    idx=$((idx - 1))
    if [[ $idx -ge 0 && $idx -lt ${#OPTION_IDS[@]} ]]; then
      echo "OPTION:${OPTION_IDS[$idx]}"
    else
      echo "CANCELLED"
      return 1
    fi
  fi
}

pick_whiptail() {
  local menu_items=()
  for i in "${!OPTION_DISPLAYS[@]}"; do
    menu_items+=("$((i+1))" "${OPTION_DISPLAYS[$i]}")
  done

  local choice
  choice=$(whiptail --title "━━━ $TITLE ━━━" \
    --menu "$QUESTION\n\n$CONTEXT" \
    20 70 10 \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || true

  if [[ -z "$choice" ]]; then
    echo "CANCELLED"
    return 1
  fi

  local idx=$((choice - 1))
  if [[ $idx -ge 0 && $idx -lt ${#OPTION_IDS[@]} ]]; then
    echo "OPTION:${OPTION_IDS[$idx]}"
  else
    echo "CANCELLED"
    return 1
  fi
}

pick_dialog() {
  local menu_items=()
  for i in "${!OPTION_DISPLAYS[@]}"; do
    menu_items+=("$((i+1))" "${OPTION_DISPLAYS[$i]}")
  done

  local choice
  choice=$(dialog --title "━━━ $TITLE ━━━" \
    --menu "$QUESTION\n\n$CONTEXT" \
    20 70 10 \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || true

  if [[ -z "$choice" ]]; then
    echo "CANCELLED"
    return 1
  fi

  local idx=$((choice - 1))
  if [[ $idx -ge 0 && $idx -lt ${#OPTION_IDS[@]} ]]; then
    echo "OPTION:${OPTION_IDS[$idx]}"
  else
    echo "CANCELLED"
    return 1
  fi
}

pick_bash() {
  # Pure bash fallback with read
  echo "━━━ DECISION: $TITLE ━━━" >&2
  echo "" >&2
  echo "$QUESTION" >&2
  if [[ -n "$CONTEXT" ]]; then
    echo "" >&2
    echo "$CONTEXT" >&2
  fi
  echo "" >&2
  echo "Options:" >&2
  for i in "${!OPTION_DISPLAYS[@]}"; do
    echo "  $((i+1)). ${OPTION_DISPLAYS[$i]}" >&2
  done
  if [[ "$ALLOW_FREE_TEXT" == "True" ]]; then
    echo "  0. Type something (free text)" >&2
  fi
  echo "" >&2

  local default_label="${OPTION_LABELS[$DEFAULT_IDX]}"
  echo -n "Your call [$default_label]: " >&2
  local _read_fd=0
  if [[ ! -t 0 ]]; then
    _read_fd=3
    exec 3<>/dev/tty
  fi
  read -r choice <&"$_read_fd"
  if [[ "$_read_fd" == "3" ]]; then
    exec 3<&-
  fi
  echo "" >&2

  if [[ -z "$choice" ]]; then
    # Use default
    echo "OPTION:${OPTION_IDS[$DEFAULT_IDX]}"
  elif [[ "$choice" =~ ^[0-9]+$ ]]; then
    if [[ "$choice" == "0" && "$ALLOW_FREE_TEXT" == "True" ]]; then
      echo "FREE_TEXT"
    elif [[ $choice -ge 1 && $choice -le ${#OPTION_IDS[@]} ]]; then
      local idx=$((choice - 1))
      echo "OPTION:${OPTION_IDS[$idx]}"
    else
      echo "CANCELLED"
      return 1
    fi
  else
    # Treat as free text
    echo "FREE_TEXT"
  fi
}

pick_default() {
  # Non-interactive: output default
  echo "OPTION:${OPTION_IDS[$DEFAULT_IDX]}"
}

# --- execute picker ---
RESULT=""
case "$DETECTED_BACKEND" in
  fzf) RESULT=$(pick_fzf) ;;
  whiptail) RESULT=$(pick_whiptail) ;;
  dialog) RESULT=$(pick_dialog) ;;
  bash) RESULT=$(pick_bash) ;;
  default) RESULT=$(pick_default) ;;
  *) echo "error: unknown backend $DETECTED_BACKEND" >&2; exit 2 ;;
esac

# --- handle result ---
if [[ "$RESULT" == "CANCELLED" ]]; then
  exit 1
elif [[ "$RESULT" == "FREE_TEXT" ]]; then
  # Prompt for free text
  echo -n "Enter your answer: " >&2
  local _read_fd=0
  if [[ ! -t 0 ]]; then
    _read_fd=3
    exec 3<>/dev/tty
  fi
  read -r free_text <&"$_read_fd"
  if [[ "$_read_fd" == "3" ]]; then
    exec 3<&-
  fi
  echo "" >&2

  if [[ -z "$free_text" ]]; then
    # User pressed Enter without typing - use default
    RESULT="OPTION:${OPTION_IDS[$DEFAULT_IDX]}"
  else
    # Output free text result
    case "$FORMAT" in
      json)
        printf '{"decision_id":"%s","selected_option_id":null,"selected_label":null,"free_text":"%s","method":"free_text"}\n' \
          "$CARD_ID" "$(escape_json_string "$free_text")"
        ;;
      text) echo "$free_text" ;;
      id) echo "$free_text" ;;
    esac
    exit 0
  fi
fi

# --- output option result ---
if [[ "$RESULT" =~ ^OPTION: ]]; then
  SELECTED_ID="${RESULT#OPTION:}"
  SELECTED_LABEL=""
  for i in "${!OPTION_IDS[@]}"; do
    if [[ "${OPTION_IDS[$i]}" == "$SELECTED_ID" ]]; then
      SELECTED_LABEL="${OPTION_LABELS[$i]}"
      break
    fi
  done

  case "$FORMAT" in
    json)
      printf '{"decision_id":"%s","selected_option_id":"%s","selected_label":"%s","free_text":null,"method":"picker"}\n' \
        "$CARD_ID" "$SELECTED_ID" "$(escape_json_string "$SELECTED_LABEL")"
      ;;
    text) echo "$SELECTED_LABEL" ;;
    id) echo "$SELECTED_ID" ;;
  esac
  exit 0
fi

# Should not reach here
echo "error: unexpected result: $RESULT" >&2
exit 2
