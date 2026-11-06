#!/usr/bin/env bash
# herdrcore.sh - experimental Herdr desktop spaces backed by hc terminals.
# Only explicit selection is supported; no core/app lifecycle command is issued.
# CLI contract: hc {ls --all,get,read,send,keys,interrupt,kill,rm,label};
# herdr-app ls; herdr-app 'do' space.new --name TASK_ID --folder CWD --argv JSON;
# herdr-app 'do' space.close --id SPACE --confirmed true.
# create_task prints space, tab and terminal IDs separated by spaces.
# Targets are SPACE:TERMINAL; refusals explain the failed guard on stderr.
# hc ls supplies summary addresses; hc get supplies verified ownership labels.
# A private creation receipt under state/herdrcore-endpoints plus nonce labels
# binds every operation to the creating home. IDs alone never authorize input
# or closing a space. Receipt retention makes partial cleanup retryable.
# Titles drop the fm- prefix; home hashes stay in fm.home-hash and home_hash
# receipt metadata. Full home paths, task labels and nonces remain authoritative.
# API/GUI behavior still needs the live verification in docs/herdrcore-backend.md.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-agent-process-lib.sh"

fm_backend_herdrcore_error() {
  printf 'error: herdrcore %s\n' "$*" >&2
  return 1
}

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
  (cd "$FM_HOME" && pwd -P) || {
    fm_backend_herdrcore_error "cannot resolve home $FM_HOME"
    return 1
  }
}

fm_backend_herdrcore_receipt_dir() {
  printf '%s/herdrcore-endpoints' "$FM_HOME/state"
}

fm_backend_herdrcore_parse_target() { # <space:terminal>
  FM_HC_SPACE=${1%%:*}
  FM_HC_TERMINAL=${1#*:}
  case "$FM_HC_SPACE" in ''|*[!A-Za-z0-9_-]*) fm_backend_herdrcore_error "invalid space in target '$1'"; return 1 ;; esac
  [[ "$FM_HC_TERMINAL" =~ ^t[0-9a-z]+$ ]] || {
    fm_backend_herdrcore_error "invalid terminal in target '$1'"
    return 1
  }
  [ "$FM_HC_TERMINAL" != "$1" ] || {
    fm_backend_herdrcore_error "expected space:terminal target, got '$1'"
    return 1
  }
}

fm_backend_herdrcore_receipt() { # <target> [expected-label]
  local file home
  fm_backend_herdrcore_parse_target "$1" || return 1
  file="$(fm_backend_herdrcore_receipt_dir)/$FM_HC_SPACE.json"
  [ -f "$file" ] && [ ! -L "$file" ] || {
    fm_backend_herdrcore_error "missing or unsafe ownership receipt $file"
    return 1
  }
  home=$(fm_backend_herdrcore_home) || return 1
  FM_HC_RECEIPT=$(jq -ce --arg s "$FM_HC_SPACE" --arg t "$FM_HC_TERMINAL" \
    --arg h "$home" --arg label "${2:-}" '
    select(.version == 1 and .space == $s and .terminal == $t and .home == $h)
    | select((.tab | type == "string" and test("^[A-Za-z0-9_-]+$"))
      and (.nonce | type == "string" and test("^[A-Za-z0-9-]+$"))
      and (.label | type == "string" and test("^fm-[A-Za-z0-9._-]+$")))
    | select($label == "" or .label == $label)' "$file") || {
      fm_backend_herdrcore_error "invalid or mismatched ownership receipt $file"
      return 1
    }
}

# JSON shape checks deliberately refuse an unavailable/malformed inventory;
# an empty inventory is evidence of absence only after successful decoding.
fm_backend_herdrcore_inventory() {
  local raw addresses terminal info rows=''
  raw=$(hc ls --all --json) || {
    fm_backend_herdrcore_error 'hc ls --all --json failed; cannot read terminal inventory'
    return 1
  }
  addresses=$(printf '%s' "$raw" | jq -ce 'select(.terminals | type == "array") | .terminals
    | select(all(.[]; .address | type == "string" and test("^t[0-9a-z]+$")))
    | map(.address) | select(length == (unique | length))') || {
    fm_backend_herdrcore_error 'invalid hc ls --all --json response; expected unique terminal addresses'
    return 1
  }
  # ls emits summaries without labels. Read every terminal's details: treating
  # missing labels as empty could miss a duplicate or authorize unsafe cleanup.
  while IFS= read -r terminal; do
    [ -n "$terminal" ] || continue
    info=$(hc get "$terminal" --json) || {
      fm_backend_herdrcore_error "hc get $terminal --json failed; cannot verify terminal inventory"
      return 1
    }
    info=$(printf '%s' "$info" | jq -ce --arg t "$terminal" '
      select(.address == $t and (.labels | type == "object"))') || {
      fm_backend_herdrcore_error "invalid hc get $terminal --json response; expected matching address and labels object"
      return 1
    }
    rows="$rows$info
"
  done < <(printf '%s' "$addresses" | jq -r '.[]')
  printf '%s' "$rows" | jq -sc '.'
}

fm_backend_herdrcore_spaces() {
  local raw
  raw=$(herdr-app ls) || {
    fm_backend_herdrcore_error 'herdr-app ls failed; cannot read space inventory'
    return 1
  }
  printf '%s' "$raw" | jq -ce '(if type == "array" then . else .spaces end)
    | select(type == "array")
    | select(all(.[]; (.id | type == "string") and (.name | type == "string") and (.tabs | type == "array")))' || {
    fm_backend_herdrcore_error 'invalid herdr-app ls response; expected spaces with id, name and tabs'
    return 1
  }
}

fm_backend_herdrcore_bound() { # <terminal-json>; receipt already loaded
  printf '%s' "$1" | jq -e --argjson r "$FM_HC_RECEIPT" '
    .address == $r.terminal and .labels["herdr.space"] == $r.space
    and .labels["herdr.tab"] == $r.tab and .labels["fm.home"] == $r.home
    and .labels["fm.task"] == $r.label and .labels["fm.owner"] == $r.nonce' >/dev/null || {
    fm_backend_herdrcore_error "terminal ownership does not match receipt for $FM_HC_SPACE:$FM_HC_TERMINAL"
    return 1
  }
}

fm_backend_herdrcore_target_ready() { # <target> [expected-label]
  fm_backend_herdrcore_receipt "$1" "${2:-}" || return 1
  FM_HC_INFO=$(hc get "$FM_HC_TERMINAL" --json) || {
    fm_backend_herdrcore_error "hc get $FM_HC_TERMINAL --json failed"
    return 1
  }
  fm_backend_herdrcore_bound "$FM_HC_INFO" || return 1
  [ "$(printf '%s' "$FM_HC_INFO" | jq -r '.state')" = live ] || {
    fm_backend_herdrcore_error "terminal $FM_HC_TERMINAL is not live"
    return 1
  }
}

fm_backend_herdrcore_create_task() { # <fm-label> <cwd>
  local label=$1 cwd=$2 home home_hash inv spaces title nonce out space tab terminal dir receipt file
  case "$label" in fm-*) ;; *) fm_backend_herdrcore_error "invalid task label '$label'; expected fm- prefix"; return 1 ;; esac
  case "$label" in *[!A-Za-z0-9._-]*) fm_backend_herdrcore_error "invalid task label '$label'"; return 1 ;; esac
  fm_backend_herdrcore_tool_check || return 1
  home=$(fm_backend_herdrcore_home) || return 1
  title=${label#fm-}
  home_hash=$(printf '%s' "$home" | shasum -a 256 | cut -c1-12)
  inv=$(fm_backend_herdrcore_inventory) || return 1
  spaces=$(fm_backend_herdrcore_spaces) || return 1
  if printf '%s' "$inv" | jq -e --arg h "$home" --arg l "$label" \
    'any(.[]; .labels["fm.home"] == $h and .labels["fm.task"] == $l)' >/dev/null; then
    echo "error: herdrcore endpoint already exists for $label; refusing duplicate launch" >&2
    return 1
  fi
  # Receipts also catch partial launches whose labels were never attached.
  # A foreign space with the same display title is not ours to adopt or block.
  dir=$(fm_backend_herdrcore_receipt_dir)
  for file in "$dir"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    if jq -e --arg h "$home" --arg l "$label" --argjson spaces "$spaces" '
      select(.home == $h and .label == $l) | .space as $s
      | any($spaces[]; .id == $s)' "$file" >/dev/null; then
      fm_backend_herdrcore_error "endpoint already exists for $label; refusing duplicate launch"
      return 1
    fi
  done
  # Bash is explicit: fm-spawn sends POSIX shell commands even when the app's
  # configured default shell is fish, nu, or another non-POSIX shell.
  out=$(herdr-app 'do' space.new --name "$title" --folder "$cwd" --argv '["/bin/bash","-l"]') || {
    fm_backend_herdrcore_error "herdr-app do space.new failed for $label; inspect the app before retrying"
    return 1
  }
  space=$(printf '%s' "$out" | jq -er '.space | strings') || {
    fm_backend_herdrcore_error "invalid space.new response: missing space; inspect the app before retrying"
    return 1
  }
  tab=$(printf '%s' "$out" | jq -er '.tab | strings') || {
    fm_backend_herdrcore_error "invalid space.new response: missing tab; inspect the app before retrying"
    return 1
  }
  terminal=$(printf '%s' "$out" | jq -er '.terminal | strings') || {
    fm_backend_herdrcore_error "invalid space.new response: missing terminal; inspect the app before retrying"
    return 1
  }
  fm_backend_herdrcore_parse_target "$space:$terminal" || return 1
  case "$tab" in ''|*[!A-Za-z0-9_-]*) fm_backend_herdrcore_error "invalid tab in space.new response; inspect $space before retrying"; return 1 ;; esac
  mkdir -p "$dir" || {
    fm_backend_herdrcore_error "cannot create receipt directory $dir for $space:$terminal"
    return 1
  }
  [ ! -e "$dir/$space.json" ] && [ ! -L "$dir/$space.json" ] || {
    fm_backend_herdrcore_error "receipt already exists at $dir/$space.json; refusing to overwrite"
    return 1
  }
  nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || {
    fm_backend_herdrcore_error "cannot generate ownership nonce for $space:$terminal"
    return 1
  }
  receipt=$(jq -n --arg s "$space" --arg t "$terminal" --arg tab "$tab" --arg h "$home" \
    --arg l "$label" --arg n "$nonce" --arg title "$title" --arg hash "$home_hash" \
    '{version:1,space:$s,terminal:$t,tab:$tab,home:$h,home_hash:$hash,label:$l,nonce:$n,title:$title}') || {
      fm_backend_herdrcore_error "cannot encode ownership receipt for $space:$terminal"
      return 1
    }
  # Publish without overwriting an earlier receipt, even under concurrent calls.
  (umask 077; set -C; printf '%s\n' "$receipt" > "$dir/$space.json") || {
    fm_backend_herdrcore_error "cannot publish receipt $dir/$space.json; inspect $space:$terminal before retrying"
    return 1
  }
  # Do not attach ownership labels to a contradictory creation response.
  FM_HC_INFO=$(hc get "$terminal" --json) || {
    fm_backend_herdrcore_error "hc get $terminal --json failed after space.new; retained $dir/$space.json for inspection"
    return 1
  }
  printf '%s' "$FM_HC_INFO" | jq -e --arg s "$space" --arg tab "$tab" --arg t "$terminal" '
    .address == $t and .state == "live" and .labels["herdr.space"] == $s
    and .labels["herdr.tab"] == $tab' >/dev/null || {
      fm_backend_herdrcore_error "space.new terminal does not match created live space/tab; retained $dir/$space.json for inspection"
      return 1
    }
  if ! hc label "$terminal" "fm.home=$home" "fm.task=$label" "fm.owner=$nonce" "fm.home-hash=$home_hash" >/dev/null \
    || ! fm_backend_herdrcore_target_ready "$space:$terminal" "$label"; then
    echo "error: herdrcore created $space:$terminal but could not verify ownership; retained $dir/$space.json for inspection" >&2
    return 1
  fi
  printf '%s %s %s\n' "$space" "$tab" "$terminal"
}

fm_backend_herdrcore_capture() { # <target> <lines> [expected-label]
  local text lines=${2:-200}
  case "$lines" in ''|*[!0-9]*) fm_backend_herdrcore_error "invalid capture line count '$lines'"; return 1 ;; esac
  fm_backend_herdrcore_target_ready "$1" "${3:-}" || return 1
  text=$(hc read "$FM_HC_TERMINAL" --lines "$lines") || {
    fm_backend_herdrcore_error "hc read $FM_HC_TERMINAL failed"
    return 1
  }
  printf '%s\n' "$text" | tail -n "$lines"
}

fm_backend_herdrcore_current_path() { # <target> [expected-label]
  fm_backend_herdrcore_target_ready "$1" "${2:-}" || return 1
  # Launch cwd is not evidence of the foreground treehouse subshell's cwd.
  printf '%s' "$FM_HC_INFO" | jq -er '.foreground.cwd | strings | select(startswith("/"))' || {
    fm_backend_herdrcore_error "hc get $FM_HC_TERMINAL has no absolute foreground cwd"
    return 1
  }
}

fm_backend_herdrcore_send_text_line() { # <target> <text> [expected-label]
  fm_backend_herdrcore_target_ready "$1" "${3:-}" || return 1
  hc send "$FM_HC_TERMINAL" -- "$2" >/dev/null || {
    fm_backend_herdrcore_error "hc send $FM_HC_TERMINAL failed"
    return 1
  }
}

fm_backend_herdrcore_send_key() { # <target> <key> [expected-label]
  local key
  fm_backend_herdrcore_target_ready "$1" "${3:-}" || return 1
  case "$2" in
    Enter|enter) key=enter ;;
    Escape|escape|Esc|esc) key=esc ;;
    C-c|ctrl-c|ctrl+c) key=ctrl+c ;;
    Interrupt|interrupt) hc interrupt "$FM_HC_TERMINAL" >/dev/null || { fm_backend_herdrcore_error "hc interrupt $FM_HC_TERMINAL failed"; return 1; }; return 0 ;;
    C-u|ctrl-u|ctrl+u) key=ctrl+u ;;
    *) echo "error: unsupported herdrcore key '$2'" >&2; return 1 ;;
  esac
  hc keys "$FM_HC_TERMINAL" "$key" >/dev/null || {
    fm_backend_herdrcore_error "hc keys $FM_HC_TERMINAL $key failed"
    return 1
  }
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
  info=$(printf '%s' "$inventory" | jq -c --arg t "$FM_HC_TERMINAL" '[.[] | select(.address == $t)]') || {
    fm_backend_herdrcore_error "cannot select terminal from inventory"
    return 1
  }
  current=$(printf '%s' "$spaces" | jq -c --arg s "$FM_HC_SPACE" '[.[] | select(.id == $s)]') || {
    fm_backend_herdrcore_error "cannot select space from inventory"
    return 1
  }
  file="$(fm_backend_herdrcore_receipt_dir)/$FM_HC_SPACE.json"
  if [ "$info" = '[]' ] && [ "$current" = '[]' ]; then
    return 0
  fi
  # Refuse a renamed/repopulated space, a moved terminal, or any extra tab.
  if [ "$current" != '[]' ]; then
    printf '%s' "$current" | jq -e --argjson r "$FM_HC_RECEIPT" '
      length == 1 and .[0].name == $r.title and (.[0].tabs | length == 1)
      and .[0].tabs[0].id == $r.tab' >/dev/null || {
        fm_backend_herdrcore_error "space $FM_HC_SPACE was renamed or its tabs changed; refusing close"
        return 1
      }
  fi
  printf '%s' "$inventory" | jq -e --argjson r "$FM_HC_RECEIPT" '
    all(.[]; .labels["herdr.space"] != $r.space or .address == $r.terminal)' >/dev/null || {
      fm_backend_herdrcore_error "space $FM_HC_SPACE contains another terminal; refusing close"
      return 1
    }
  if [ "$info" != '[]' ]; then
    [ "$(printf '%s' "$info" | jq length)" = 1 ] || {
      fm_backend_herdrcore_error "ambiguous terminal $FM_HC_TERMINAL; refusing close"
      return 1
    }
    fm_backend_herdrcore_bound "$(printf '%s' "$info" | jq '.[0]')" || return 1
    tmp=$(mktemp "$file.XXXXXX") || {
      fm_backend_herdrcore_error "cannot stage closing receipt $file"
      return 1
    }
    if ! printf '%s' "$FM_HC_RECEIPT" | jq '.closing = true' > "$tmp" || ! mv "$tmp" "$file"; then
      fm_backend_herdrcore_error "cannot mark receipt $file closing"
      return 1
    fi
    if [ "$(printf '%s' "$info" | jq -r '.[0].state')" = live ]; then
      hc kill "$FM_HC_TERMINAL" >/dev/null || {
        fm_backend_herdrcore_error "hc kill $FM_HC_TERMINAL failed; retained $file"
        return 1
      }
    fi
    hc rm "$FM_HC_TERMINAL" >/dev/null || {
      fm_backend_herdrcore_error "hc rm $FM_HC_TERMINAL failed; retained $file"
      return 1
    }
  else
    printf '%s' "$FM_HC_RECEIPT" | jq -e '.closing == true' >/dev/null || {
      fm_backend_herdrcore_error "terminal disappeared without a closing receipt; refusing close of $FM_HC_SPACE"
      return 1
    }
  fi
  # Re-read after kill: Herdr may already have removed the last tab/space.
  spaces=$(fm_backend_herdrcore_spaces) || return 1
  current=$(printf '%s' "$spaces" | jq -c --arg s "$FM_HC_SPACE" '[.[] | select(.id == $s)]') || {
    fm_backend_herdrcore_error "cannot select space from inventory"
    return 1
  }
  if [ "$current" != '[]' ]; then
    printf '%s' "$current" | jq -e --argjson r "$FM_HC_RECEIPT" '
      length == 1 and .[0].name == $r.title and (.[0].tabs | length == 1)
      and .[0].tabs[0].id == $r.tab' >/dev/null || {
        fm_backend_herdrcore_error "space $FM_HC_SPACE was renamed or its tabs changed; refusing close"
        return 1
      }
    inventory=$(fm_backend_herdrcore_inventory) || return 1
    printf '%s' "$inventory" | jq -e --arg s "$FM_HC_SPACE" 'all(.[]; .labels["herdr.space"] != $s)' >/dev/null || {
      fm_backend_herdrcore_error "space $FM_HC_SPACE still contains terminals; refusing close"
      return 1
    }
    herdr-app 'do' space.close --id "$FM_HC_SPACE" --confirmed true >/dev/null || {
      fm_backend_herdrcore_error "herdr-app do space.close failed for $FM_HC_SPACE; retained $file"
      return 1
    }
  fi
  spaces=$(fm_backend_herdrcore_spaces) || return 1
  printf '%s' "$spaces" | jq -e --arg s "$FM_HC_SPACE" 'all(.[]; .id != $s)' >/dev/null || {
    fm_backend_herdrcore_error "space $FM_HC_SPACE remains after close; retained $file"
    return 1
  }
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
