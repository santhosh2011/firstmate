#!/usr/bin/env bash
# Offline backend contract and spawn integration. All hc/herdr-app calls use
# strict fixture executables on PATH; never consult or alter the running app.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdrcore)
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

new_world() {
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/projects"
  export FM_HC_TEST_WORLD="$case_dir" FM_HOME="$case_dir/home"
  export FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config"
  FM_BACKEND_CONFIG_DIR=$FM_CONFIG_OVERRIDE
  printf '{"terminals":[],"spaces":[]}\n' > "$case_dir/world.json"
  : > "$case_dir/calls.jsonl"
}

mutate() { # jq expression over fixture state
  jq "$1" "$FM_HC_TEST_WORLD/world.json" > "$FM_HC_TEST_WORLD/world.next"
  mv "$FM_HC_TEST_WORLD/world.next" "$FM_HC_TEST_WORLD/world.json"
}

calls() { jq -s "$1" "$FM_HC_TEST_WORLD/calls.jsonl"; }

fb=$(make_spawn_fakebin "$TMP_ROOT/tools" claude codex)
cp "$ROOT/tests/fixtures/herdrcore-cli.py" "$fb/hc"
cp "$ROOT/tests/fixtures/herdrcore-cli.py" "$fb/herdr-app"
chmod +x "$fb/hc" "$fb/herdr-app"
fm_test_fake_sleep_noop "$fb"
export PATH="$fb:$PATH"
fm_backend_source herdrcore
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

new_world selection
[ "$(FM_BACKEND=herdrcore fm_backend_name)" = herdrcore ] || fail 'env selection'
printf 'herdrcore\n' > "$FM_HOME/config/backend"
[ "$(FM_BACKEND='' fm_backend_name)" = herdrcore ] || fail 'config selection'
fm_backend_validate_spawn herdrcore || fail 'spawn validation'
[ "$(fm_backend_required_tools herdrcore)" = 'hc herdr-app jq treehouse' ] || fail 'required tools'
pass 'herdrcore explicit selection and dependencies'

new_world endpoints
ids=$(fm_backend_herdrcore_create_task fm-example "$FM_HOME")
[ "$ids" = 's1 tab1 t1' ] || fail 'creation ids'
fm_backend_target_exists herdrcore s1:t1 fm-example || fail 'owned endpoint exists'
[ "$(fm_backend_herdrcore_current_path s1:t1 fm-example)" = "$FM_HOME" ] || fail 'foreground cwd'
[ "$(fm_backend_capture herdrcore s1:t1 2 fm-example)" = $'two\n❯' ] || fail 'bounded capture'
if fm_backend_herdrcore_create_task fm-example "$FM_HOME" >/dev/null 2>&1; then fail 'duplicate created'; fi
[ "$(calls '[.[] | select(.[1:3] == ["do","space.new"])] | length')" = 1 ] || fail 'duplicate mutated app'
pass 'create, duplicate refusal, capture and foreground path'

before=$(calls 'length')
if fm_backend_send_key herdrcore s1:t1 Enter fm-wrong; then fail 'wrong label accepted'; fi
if fm_backend_send_key herdrcore s2:t1 Enter fm-example; then fail 'wrong space accepted'; fi
if fm_backend_send_key herdrcore s1:other Enter fm-example; then fail 'invalid terminal accepted'; fi
[ "$(calls 'length')" = "$before" ] || fail 'invalid targets reached CLI'
mutate '.terminals[0].labels["fm.owner"] = "stranger"'
if fm_backend_send_key herdrcore s1:t1 Enter fm-example; then fail 'foreign nonce accepted'; fi
if fm_backend_kill herdrcore s1:t1 '' fm-example; then fail 'foreign nonce closed'; fi
[ "$(calls '[.[] | select(.[1] == "keys" or .[1] == "kill")] | length')" = 0 ] || fail 'identity mismatch mutated endpoint'
pass 'labels, addresses and creation nonce fail closed'

new_world homes
fm_backend_herdrcore_create_task fm-shared "$FM_HOME" >/dev/null
first_home=$FM_HOME
mkdir -p "$FM_HC_TEST_WORLD/other-home/state"
export FM_HOME="$FM_HC_TEST_WORLD/other-home"
if fm_backend_target_exists herdrcore s1:t1 fm-shared; then fail 'foreign home adopted endpoint'; fi
[ "$(fm_backend_herdrcore_create_task fm-shared "$FM_HOME")" = 's2 tab2 t2' ] || fail 'same task in second home collided'
export FM_HOME=$first_home
[ "$(fm_backend_herdrcore_list_live)" = $'s1:t1\tfm-shared' ] || fail 'list mixed home namespaces'
mutate '.terminals = null'
[ "$(fm_backend_agent_state herdrcore s1:t1)" = unreadable ] || fail 'malformed inventory became absence'
if fm_backend_herdrcore_create_task fm-new "$FM_HOME" >/dev/null 2>&1; then fail 'malformed inventory allowed create'; fi
pass 'home isolation, scoped listing and malformed-inventory refusal'

new_world input
fm_backend_herdrcore_create_task fm-input "$FM_HOME" >/dev/null
payload=$'--literal `echo nope` $(false) "quote"\nnext'
fm_backend_herdrcore_send_text_line s1:t1 "$payload" fm-input
fm_backend_send_key herdrcore s1:t1 Enter fm-input
fm_backend_send_key herdrcore s1:t1 Escape fm-input
fm_backend_send_key herdrcore s1:t1 C-u fm-input
fm_backend_send_key herdrcore s1:t1 C-c fm-input
fm_backend_send_key herdrcore s1:t1 Interrupt fm-input
[ "$(calls '.[-1][1]')" = '"interrupt"' ] || fail 'interrupt mapping'
fm_backend_send_text_submit herdrcore s1:t1 "$payload" 3 0 0 fm-input >/dev/null
[ "$(calls '[.[] | select(.[1] == "send")] | length')" = 2 ] || fail 'text retyped'
[ "$(calls '[.[] | select(.[1] == "keys" and .[3] == "enter")] | length')" = 1 ] || fail 'send appended Enter'
[ "$(jq -s --arg t "$payload" '[.[] | select(.[1]=="send") | .[3:] == ["--",$t]] | all' "$FM_HC_TEST_WORLD/calls.jsonl")" = true ] || fail 'payload changed'
pass 'literal payload, keys, interrupt and single-submit semantics'

mutate '.terminals[0].status = {status:"working"}'
[ "$(fm_backend_busy_state herdrcore s1:t1)" = busy ] || fail 'busy state'
[ "$(fm_busy_classify herdrcore s1:t1 claude input "$FM_HOME/state")" = 'busy herdrcore-native' ] || fail 'native busy fallback'
[ "$(fm_backend_agent_state herdrcore s1:t1)" = ambiguous ] || fail 'status alone proved agent'
mutate '.terminals[0].state = "finished"'
[ "$(fm_backend_agent_state herdrcore s1:t1)" = dead ] || fail 'finished endpoint'
mutate '.fail = ["hc","ls","--all","--json"]'
[ "$(fm_backend_agent_state herdrcore s1:t1)" = unreadable ] || fail 'inventory failure became absence'
mutate 'del(.fail) | .terminals = []'
[ "$(fm_backend_agent_state herdrcore s1:t1)" = missing ] || fail 'authoritative absence'
pass 'recovery distinguishes absent, finished, ambiguous and unavailable'

new_world cleanup
fm_backend_herdrcore_create_task fm-clean "$FM_HOME" >/dev/null
mutate '.spaces[0].tabs += [{id:"foreign-tab"}]'
if fm_backend_kill herdrcore s1:t1 '' fm-clean; then fail 'closed extra tab'; fi
mutate '.spaces[0].tabs = [.spaces[0].tabs[0]] | .terminals += [{address:"t9",state:"live",labels:{"herdr.space":"s1"}}]'
if fm_backend_kill herdrcore s1:t1 '' fm-clean; then fail 'closed foreign terminal'; fi
[ "$(calls '[.[] | select(.[1]=="kill" or .[1:3]==["do","space.close"])] | length')" = 0 ] || fail 'unsafe close attempted'
mutate '.terminals = [.terminals[0]] | .fail = ["herdr-app","do","space.close","--id","s1","--confirmed","true"]'
if fm_backend_kill herdrcore s1:t1 '' fm-clean; then fail 'close failure ignored'; fi
[ -f "$FM_HOME/state/herdrcore-endpoints/s1.json" ] || fail 'failure lost receipt'
mutate 'del(.fail)'
fm_backend_kill herdrcore s1:t1 '' fm-clean || fail 'cleanup retry failed'
[ "$(jq '.spaces|length' "$FM_HC_TEST_WORLD/world.json")" = 0 ] || fail 'owned space remained'
fm_backend_kill herdrcore s1:t1 '' fm-clean || fail 'cleanup not idempotent'
pass 'cleanup refuses unrelated work and retains provenance across close failure'

new_world metadata
meta="$FM_HOME/state/example.meta"
printf '%s\n' 'backend=herdrcore' 'endpoint_task_id=example' 'window=s1:t1' \
  'herdrcore_space_id=s1' 'herdrcore_tab_id=tab1' 'herdrcore_terminal_id=t1' \
  "worktree=$FM_HOME" "project=$FM_HOME" > "$meta"
fm_backend_validate_task_endpoint "$meta" example || fail 'valid metadata rejected'
printf 'herdrcore_terminal_id=t2\n' >> "$meta"
if fm_backend_validate_task_endpoint "$meta" example 2>/dev/null; then fail 'ambiguous metadata accepted'; fi
pass 'durable metadata endpoint validation'

# Exercise the actual spawn script: no real agent or terminal starts.
for kind in crew secondmate; do
  new_world "spawn-$kind"
  proj="$FM_HC_TEST_WORLD/project"
  wt="$FM_HC_TEST_WORLD/worktree"
  fm_git_worktree "$proj" "$wt" "hc-$kind"
  printf 'claude\n' > "$FM_HOME/config/crew-harness"
  mkdir -p "$FM_HOME/data/worker"
  printf "# Task\n## Captain's intent\nOffline spawn test.\n\n## Firstmate spec\nUse the fixture only.\n" > "$FM_HOME/data/worker/brief.md"
  touch "$FM_HOME/state/.last-watcher-beat"
  args=(worker "$proj" --backend herdrcore)
  if [ "$kind" = secondmate ]; then
    printf 'worker\n' > "$proj/.fm-secondmate-home"
    printf '# Offline secondmate fixture\n' > "$proj/AGENTS.md"
    mkdir -p "$proj/bin"
    args+=(--secondmate)
  else
    args+=(--mode no-mistakes --yolo off)
  fi
  out=$(fm_test_run_spawn "$FM_HOME" "$wt" "$fb" "${args[@]}") || fail "$kind spawn: $out"
  meta="$FM_HOME/state/worker.meta"
  [ "$(fm_backend_of_meta "$meta")" = herdrcore ] || fail 'spawn backend metadata'
  fm_backend_validate_task_endpoint "$meta" worker || fail 'spawn endpoint metadata'
  [ "$(calls '[.[] | select(.[1:3]==["do","space.new"])] | length')" = 1 ] || fail 'spawn did not own one space'
  [ "$(calls '[.[] | select(.[1]=="keys" and .[3]=="enter")] | length')" = 0 ] || fail 'spawn double submitted'
  # Spawn submits a short source command; the generated file owns the launch.
  [ "$(calls '[.[] | select(.[1]=="send" and (.[-1] | startswith(". ")))] | length')" = 1 ] || fail 'launch missing or repeated'
  staged=$(jq -sr '[.[] | select(.[1]=="send" and (.[-1] | startswith(". ")))][0][-1]' "$FM_HC_TEST_WORLD/calls.jsonl")
  staged=${staged#". '"}
  staged=${staged%"'"}
  # Claude now receives a durable operational-inbox pointer rather than an
  # inline prompt. Check the delivered record as well as its staged pointer.
  launch_records=0
  launch_home=$FM_HOME
  [ "$kind" != secondmate ] || launch_home=$proj
  for launch_record in "$launch_home/state/operational-inbox/"*.msg; do
    [ -f "$launch_record" ] || continue
    assert_grep "$launch_record" "$staged" 'staged launch does not point at its record'
    assert_grep 'Offline spawn test.' "$launch_record" 'launch record lost the task'
    launch_records=$((launch_records + 1))
  done
  [ "$launch_records" -eq 1 ] || fail 'launch record missing or duplicated'
  FM_HOME="$FM_HOME" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" worker "offline steer payload" > "$FM_HC_TEST_WORLD/send.out" 2>&1 || fail "steer failed: $(cat "$FM_HC_TEST_WORLD/send.out")"
  [ -f "$FM_HOME/state/worker.inbox/001.msg" ] || fail 'durable steer missing'
  if [ "$kind" = secondmate ]; then
    corr=$(sed -n 's/.*corr=\([a-f0-9]\{16\}\).*/\1/p' "$FM_HOME/state/worker.inbox/001.msg" | head -1)
    [ -n "$corr" ] && [ -f "$FM_HOME/state/pending-replies/$corr" ] || fail 'secondmate pending reply missing'
    grep -q '^delivered_epoch=[0-9]' "$FM_HOME/state/pending-replies/$corr" || fail 'pending reply not delivered'
  fi
  [ "$(calls '[.[] | select(.[1]=="send" and (.[-1] | contains("offline steer payload")))] | length')" = 0 ] || fail 'steer payload typed'
  mutate '.fail = ["hc","get","t1","--json"]'
  crew_state=$(FM_HOME="$FM_HOME" "$ROOT/bin/fm-crew-state.sh" worker)
  assert_contains "$crew_state" 'backend unreachable' 'an unreadable endpoint became dead'
  mutate 'del(.fail)'
  pass "$kind spawn and steer retain inbox and pending-reply behavior"
done
