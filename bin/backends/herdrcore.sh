#!/usr/bin/env bash
# herdrcore.sh - experimental Herdr desktop spaces backed by hc terminals.
# Only explicit selection is supported; no core/app lifecycle command is issued.
# CLI contract: hc {ls --all,get,read,send,keys,interrupt,kill,rm,label};
# herdr-app ls; herdr-app 'do' space.new --name LABEL --folder CWD --argv JSON;
# herdr-app 'do' space.close --id SPACE --confirmed true.
# create_task prints SPACE TAB TERMINAL. Targets are SPACE:TERMINAL.
# A private creation receipt under state/herdrcore-endpoints plus nonce labels
# binds every operation to the creating home. IDs alone never authorize input
# or closing a space. Receipt retention makes partial cleanup retryable.
# API/GUI behavior still needs the live verification in docs/herdrcore-backend.md.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-agent-process-lib.sh"

fm_backend_herdrcore_tool_check() {
  local tool
  for tool in hc herdr-app jq; do
    command -v "$tool" >/dev/null 2>&1 || {
      echo "error: herdrcore requires $tool on PATH; see docs/herdrcore-backend.md" >&2
      return 1
    }
  done
}

fm_backend_herdrcore_home() {
  (cd "$FM_HOME" && pwd -P)
}

fm_backend_herdrcore_receipt_dir() {
  printf '%s/herdrcore-endpoints' "$FM_HOME/state"
}

fm_backend_herdrcore_parse_target() { # <space:terminal>
  FM_HC_SPACE=${1%%:*}
  FM_HC_TERMINAL=${1#*:}
  case "$FM_HC_SPACE" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [[ "$FM_HC_TERMINAL" =~ ^t[0-9a-z]+$ ]] || return 1
  [ "$FM_HC_TERMINAL" != "$1" ]
}

fm_backend_herdrcore_receipt() { # <target> [expected-label]
  local file home
  fm_backend_herdrcore_parse_target "$1" || return 1
  file="$(fm_backend_herdrcore_receipt_dir)/$FM_HC_SPACE.json"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  home=$(fm_backend_herdrcore_home) || return 1
  FM_HC_RECEIPT=$(jq -ce --arg s "$FM_HC_SPACE" --arg t "$FM_HC_TERMINAL" \
    --arg h "$home" --arg label "${2:-}" '
    select(.version == 1 and .space == $s and .terminal == $t and .home == $h)
    | select((.tab | type == "string" and test("^[A-Za-z0-9_-]+$"))
      and (.nonce | type == "string" and test("^[A-Za-z0-9-]+$"))
      and (.label | type == "string" and test("^fm-[A-Za-z0-9._-]+$")))
    | select($label == "" or .label == $label)' "$file") || return 1
}

# JSON shape checks deliberately refuse an unavailable/malformed inventory;
# an empty inventory is evidence of absence only after successful decoding.
fm_backend_herdrcore_inventory() {
  local raw
  raw=$(hc ls --all --json) || return 1
  printf '%s' "$raw" | jq -ce 'select(.terminals | type == "array") | .terminals
    | select(all(.[]; (.address | type == "string") and (.labels | type == "object")))'
}

fm_backend_herdrcore_spaces() {
  local raw
  raw=$(herdr-app ls) || return 1
  printf '%s' "$raw" | jq -ce '(if type == "array" then . else .spaces end)
    | select(type == "array")
    | select(all(.[]; (.id | type == "string") and (.name | type == "string") and (.tabs | type == "array")))'
}

fm_backend_herdrcore_bound() { # <terminal-json>; receipt already loaded
  printf '%s' "$1" | jq -e --argjson r "$FM_HC_RECEIPT" '
    .address == $r.terminal and .labels["herdr.space"] == $r.space
    and .labels["herdr.tab"] == $r.tab and .labels["fm.home"] == $r.home
    and .labels["fm.task"] == $r.label and .labels["fm.owner"] == $r.nonce' >/dev/null
}

fm_backend_herdrcore_target_ready() { # <target> [expected-label]
  fm_backend_herdrcore_receipt "$1" "${2:-}" || return 1
  FM_HC_INFO=$(hc get "$FM_HC_TERMINAL" --json) || return 1
  fm_backend_herdrcore_bound "$FM_HC_INFO" || return 1
  [ "$(printf '%s' "$FM_HC_INFO" | jq -r '.state')" = live ]
}

fm_backend_herdrcore_create_task() { # <fm-label> <cwd>
  local label=$1 cwd=$2 home inv spaces title nonce out space tab terminal dir receipt
  case "$label" in fm-*) ;; *) return 1 ;; esac
  case "$label" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  fm_backend_herdrcore_tool_check || return 1
  home=$(fm_backend_herdrcore_home) || return 1
  title="$label-$(printf '%s' "$home" | shasum -a 256 | cut -c1-12)"
  inv=$(fm_backend_herdrcore_inventory) || return 1
  spaces=$(fm_backend_herdrcore_spaces) || return 1
  if printf '%s' "$inv" | jq -e --arg h "$home" --arg l "$label" \
    'any(.[]; .labels["fm.home"] == $h and .labels["fm.task"] == $l)' >/dev/null \
    || printf '%s' "$spaces" | jq -e --arg n "$title" 'any(.[]; .name == $n)' >/dev/null; then
    echo "error: herdrcore endpoint already exists for $label; refusing duplicate launch" >&2
    return 1
  fi
  # Bash is explicit: fm-spawn sends POSIX shell commands even when the app's
  # configured default shell is fish, nu, or another non-POSIX shell.
  out=$(herdr-app 'do' space.new --name "$title" --folder "$cwd" --argv '["/bin/bash","-l"]') || return 1
  space=$(printf '%s' "$out" | jq -er '.space | strings') || return 1
  tab=$(printf '%s' "$out" | jq -er '.tab | strings') || return 1
  terminal=$(printf '%s' "$out" | jq -er '.terminal | strings') || return 1
  fm_backend_herdrcore_parse_target "$space:$terminal" || return 1
  case "$tab" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  dir=$(fm_backend_herdrcore_receipt_dir)
  mkdir -p "$dir" || return 1
  [ ! -e "$dir/$space.json" ] && [ ! -L "$dir/$space.json" ] || return 1
  nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  receipt=$(jq -n --arg s "$space" --arg t "$terminal" --arg tab "$tab" --arg h "$home" \
    --arg l "$label" --arg n "$nonce" --arg title "$title" \
    '{version:1,space:$s,terminal:$t,tab:$tab,home:$h,label:$l,nonce:$n,title:$title}') || return 1
  # Publish without overwriting an earlier receipt, even under concurrent calls.
  (umask 077; set -C; printf '%s\n' "$receipt" > "$dir/$space.json") || return 1
  # Do not attach ownership labels to a contradictory creation response.
  FM_HC_INFO=$(hc get "$terminal" --json) || return 1
  printf '%s' "$FM_HC_INFO" | jq -e --arg s "$space" --arg tab "$tab" --arg t "$terminal" '
    .address == $t and .state == "live" and .labels["herdr.space"] == $s
    and .labels["herdr.tab"] == $tab' >/dev/null || return 1
  if ! hc label "$terminal" "fm.home=$home" "fm.task=$label" "fm.owner=$nonce" >/dev/null \
    || ! fm_backend_herdrcore_target_ready "$space:$terminal" "$label"; then
    echo "error: herdrcore created $space:$terminal but could not verify ownership; retained $dir/$space.json for inspection" >&2
    return 1
  fi
  printf '%s %s %s\n' "$space" "$tab" "$terminal"
}

fm_backend_herdrcore_capture() { # <target> <lines> [expected-label]
  local text lines=${2:-200}
  case "$lines" in ''|*[!0-9]*) return 1 ;; esac
  fm_backend_herdrcore_target_ready "$1" "${3:-}" || return 1
  text=$(hc read "$FM_HC_TERMINAL" --lines "$lines") || return 1
  printf '%s\n' "$text" | tail -n "$lines"
}

fm_backend_herdrcore_current_path() { # <target> [expected-label]
  fm_backend_herdrcore_target_ready "$1" "${2:-}" || return 1
  # Launch cwd is not evidence of the foreground treehouse subshell's cwd.
  printf '%s' "$FM_HC_INFO" | jq -er '.foreground.cwd | strings | select(startswith("/"))'
}

fm_backend_herdrcore_send_text_line() { # <target> <text> [expected-label]
  fm_backend_herdrcore_target_ready "$1" "${3:-}" || return 1
  hc send "$FM_HC_TERMINAL" -- "$2" >/dev/null
}

fm_backend_herdrcore_send_key() { # <target> <key> [expected-label]
  local key
  fm_backend_herdrcore_target_ready "$1" "${3:-}" || return 1
  case "$2" in
    Enter|enter) key=enter ;;
    Escape|escape|Esc|esc) key=esc ;;
    C-c|ctrl-c|ctrl+c) key=ctrl+c ;;
    Interrupt|interrupt) hc interrupt "$FM_HC_TERMINAL" >/dev/null; return $? ;;
    C-u|ctrl-u|ctrl+u) key=ctrl+u ;;
    *) echo "error: unsupported herdrcore key '$2'" >&2; return 1 ;;
  esac
  hc keys "$FM_HC_TERMINAL" "$key" >/dev/null
}

fm_backend_herdrcore_composer_state() { # <target> [expected-label]
  local cap verdict
  cap=$(fm_backend_herdrcore_capture "$1" "$FM_COMPOSER_CAPTURE_LINES" "${2:-}") || { printf unknown; return 0; }
  verdict=$(fm_composer_classify_screen "styled=0
cursor=0
identity=0
rows=$FM_COMPOSER_CAPTURE_LINES" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_herdrcore_send_text_submit() { # <target> <text> <retries> <sleep> <settle> [expected-label]
  # hc send owns paste + submit. Never retype or add a speculative second Enter.
  fm_backend_herdrcore_send_text_line "$1" "$2" "${6:-}" || { printf send-failed; return 0; }
  sleep "$5"
  fm_backend_herdrcore_composer_state "$1" "${6:-}"
}

fm_backend_herdrcore_busy_state() { # <target>
  fm_backend_herdrcore_target_ready "$1" || { printf unknown; return 0; }
  case "$(printf '%s' "$FM_HC_INFO" | jq -r '.status | if type == "object" then .status else . end')" in
    working) printf busy ;;
    idle|done|blocked|error) printf idle ;;
    *) printf unknown ;;
  esac
}

fm_backend_herdrcore_agent_state() { # <target>
  local inventory rows info pid name args kind
  fm_backend_herdrcore_receipt "$1" || { printf unreadable; return 0; }
  inventory=$(fm_backend_herdrcore_inventory) || { printf unreadable; return 0; }
  rows=$(printf '%s' "$inventory" | jq -c --arg t "$FM_HC_TERMINAL" '[.[] | select(.address == $t)]')
  [ "$rows" != '[]' ] || { printf missing; return 0; }
  [ "$(printf '%s' "$rows" | jq length)" = 1 ] || { printf unreadable; return 0; }
  info=$(hc get "$FM_HC_TERMINAL" --json) || { printf unreadable; return 0; }
  fm_backend_herdrcore_bound "$info" || { printf unreadable; return 0; }
  case "$(printf '%s' "$info" | jq -r '.state')" in
    finished) printf dead; return 0 ;;
    live) ;;
    *) printf unreadable; return 0 ;;
  esac
  pid=$(printf '%s' "$info" | jq -r '.foreground.pid // empty')
  case "$pid" in ''|*[!0-9]*|0) printf ambiguous; return 0 ;; esac
  name=$(ps -p "$pid" -o comm= 2>/dev/null) || { printf ambiguous; return 0; }
  args=$(ps -p "$pid" -o args= 2>/dev/null) || { printf ambiguous; return 0; }
  kind=$(fm_agent_process_classify "$name" "${args%% *}" "$args" "$pid")
  # A shell leader alone cannot prove that none of its descendants is an agent.
  case "$kind" in agent) printf alive ;; *) printf ambiguous ;; esac
}

fm_backend_herdrcore_kill() { # <target> [unused] [expected-label]
  local inventory spaces info current file tmp
  fm_backend_herdrcore_receipt "$1" "${3:-}" || return 1
  inventory=$(fm_backend_herdrcore_inventory) || return 1
  spaces=$(fm_backend_herdrcore_spaces) || return 1
  info=$(printf '%s' "$inventory" | jq -c --arg t "$FM_HC_TERMINAL" '[.[] | select(.address == $t)]') || return 1
  current=$(printf '%s' "$spaces" | jq -c --arg s "$FM_HC_SPACE" '[.[] | select(.id == $s)]') || return 1
  file="$(fm_backend_herdrcore_receipt_dir)/$FM_HC_SPACE.json"
  if [ "$info" = '[]' ] && [ "$current" = '[]' ]; then
    return 0
  fi
  # Refuse a renamed/repopulated space, a moved terminal, or any extra tab.
  if [ "$current" != '[]' ]; then
    printf '%s' "$current" | jq -e --argjson r "$FM_HC_RECEIPT" '
      length == 1 and .[0].name == $r.title and (.[0].tabs | length == 1)
      and .[0].tabs[0].id == $r.tab' >/dev/null || return 1
  fi
  printf '%s' "$inventory" | jq -e --argjson r "$FM_HC_RECEIPT" '
    all(.[]; .labels["herdr.space"] != $r.space or .address == $r.terminal)' >/dev/null || return 1
  if [ "$info" != '[]' ]; then
    [ "$(printf '%s' "$info" | jq length)" = 1 ] || return 1
    fm_backend_herdrcore_bound "$(printf '%s' "$info" | jq '.[0]')" || return 1
    tmp=$(mktemp "$file.XXXXXX") || return 1
    printf '%s' "$FM_HC_RECEIPT" | jq '.closing = true' > "$tmp" && mv "$tmp" "$file" || return 1
    if [ "$(printf '%s' "$info" | jq -r '.[0].state')" = live ]; then
      hc kill "$FM_HC_TERMINAL" >/dev/null || return 1
    fi
    hc rm "$FM_HC_TERMINAL" >/dev/null || return 1
  else
    printf '%s' "$FM_HC_RECEIPT" | jq -e '.closing == true' >/dev/null || return 1
  fi
  # Re-read after kill: Herdr may already have removed the last tab/space.
  spaces=$(fm_backend_herdrcore_spaces) || return 1
  current=$(printf '%s' "$spaces" | jq -c --arg s "$FM_HC_SPACE" '[.[] | select(.id == $s)]') || return 1
  if [ "$current" != '[]' ]; then
    printf '%s' "$current" | jq -e --argjson r "$FM_HC_RECEIPT" '
      length == 1 and .[0].name == $r.title and (.[0].tabs | length == 1)
      and .[0].tabs[0].id == $r.tab' >/dev/null || return 1
    inventory=$(fm_backend_herdrcore_inventory) || return 1
    printf '%s' "$inventory" | jq -e --arg s "$FM_HC_SPACE" 'all(.[]; .labels["herdr.space"] != $s)' >/dev/null || return 1
    herdr-app 'do' space.close --id "$FM_HC_SPACE" --confirmed true >/dev/null || return 1
  fi
  spaces=$(fm_backend_herdrcore_spaces) || return 1
  printf '%s' "$spaces" | jq -e --arg s "$FM_HC_SPACE" 'all(.[]; .id != $s)' >/dev/null || return 1
  # Keep the receipt as a tombstone so cleanup remains idempotent if later
  # teardown stages fail; it never authorizes another terminal or space.
  return 0
}

fm_backend_herdrcore_list_live() {
  local receipt target label
  for receipt in "$(fm_backend_herdrcore_receipt_dir)"/*.json; do
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || continue
    target=$(jq -er '.space + ":" + .terminal' "$receipt") || continue
    label=$(jq -er '.label' "$receipt") || continue
    fm_backend_herdrcore_target_ready "$target" "$label" || continue
    printf '%s\t%s\n' "$target" "$label"
  done
}
