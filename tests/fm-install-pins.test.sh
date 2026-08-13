#!/usr/bin/env bash
# Download resilience of the required real-Herdr lane's pin installers.
#
# Regression origin: the "Behavior tests (Herdr)" lane failed at its very first
# step with `curl: (56) Connection died, tried 5 times before giving up` after
# 166 ms. Those five tries are curl's own same-connection retries, which all
# fire in the same instant, so a single reset from the release CDN decided the
# whole required lane. bin/fm-install-shellcheck.sh already owned the answer -
# bounded attempts with a growing pause - and the Herdr and Treehouse pins now
# do the same. These tests drive the real installers with a scripted curl, so
# they assert recovery and the give-up boundary, not the shape of the code.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERDR_INSTALLER="$ROOT/bin/fm-install-herdr.sh"
TREEHOUSE_INSTALLER="$ROOT/bin/fm-install-treehouse.sh"

# A curl that fails with the observed CI transport error (56) for its first
# FM_FAKE_CURL_FAILURES calls and then writes an empty file to the -o path.
# Every call is counted, so a test can prove exactly how many attempts ran.
write_scripted_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
[ "$count" -gt "$FM_FAKE_CURL_FAILURES" ] || exit 56
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SLEEP_LOG"
exit 0
SH
  chmod +x "$fakebin/curl" "$fakebin/sleep"
}

# Runs an installer under the scripted curl and echoes "<rc>" on the first line
# with the combined output after it.
run_installer() {
  local installer=$1 tmp=$2 failures=$3 destination=$4 fakebin out rc=0
  fakebin=$(fm_fakebin "$tmp")
  write_scripted_curl "$fakebin"
  out=$(CURL_COUNT="$tmp/curl-count" SLEEP_LOG="$tmp/sleep-log" \
    FM_FAKE_CURL_FAILURES="$failures" PATH="$fakebin:$PATH" \
    "$installer" "$destination" 2>&1) || rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}

test_herdr_pin_recovers_from_a_transient_download_failure() {
  local tmp destination result rc out
  tmp=$(fm_test_tmproot fm-herdr-pin-download)
  destination="$tmp/bin"

  result=$(run_installer "$HERDR_INSTALLER" "$tmp" 1 "$destination")
  rc=$(printf '%s\n' "$result" | head -n 1)
  out=$(printf '%s\n' "$result" | tail -n +2)

  [ "$(cat "$tmp/curl-count")" -eq 2 ] \
    || fail "Herdr pin did not retry exactly once after a transient failure"$'\n'"$out"
  assert_contains "$out" "download attempt 1 failed; retrying" \
    "Herdr pin did not disclose its retry"
  # Reaching the checksum verdict is only possible once a download attempt
  # succeeded, so this is the proof that attempt 2 was consumed and trusted.
  assert_contains "$out" "checksum mismatch" \
    "Herdr pin did not reach verification after recovering the download"
  assert_not_contains "$out" "download failed for" \
    "Herdr pin still treated a recovered download as a download failure"
  [ "$rc" -ne 0 ] || fail "Herdr pin installed an asset that failed its checksum"
  pass "Herdr pin recovers from a transient download failure and still verifies"
}

test_herdr_pin_gives_up_after_the_bounded_attempts() {
  local tmp destination result rc out
  tmp=$(fm_test_tmproot fm-herdr-pin-exhaust)
  destination="$tmp/bin"

  result=$(run_installer "$HERDR_INSTALLER" "$tmp" 99 "$destination")
  rc=$(printf '%s\n' "$result" | head -n 1)
  out=$(printf '%s\n' "$result" | tail -n +2)

  [ "$rc" -ne 0 ] || fail "Herdr pin reported success with every download failing"
  [ "$(cat "$tmp/curl-count")" -eq 5 ] \
    || fail "Herdr pin did not stop at its bounded attempt count"$'\n'"$out"
  assert_contains "$out" "after 5 attempts" \
    "Herdr pin did not name the exhausted attempt count"
  # A doubling pause spanning ~30s, not an instant re-fire: the release CDN
  # answered 503 across the whole window a linear 1s/2s backoff could cover.
  [ "$(printf '%s\n' "$(cat "$tmp/sleep-log")")" = "$(printf '2\n4\n8\n16')" ] \
    || fail "Herdr pin did not back off between attempts"$'\n'"$(cat "$tmp/sleep-log")"
  [ ! -e "$destination/herdr" ] \
    || fail "Herdr pin left a binary behind after giving up"
  pass "Herdr pin gives up after bounded, backed-off attempts and installs nothing"
}

test_treehouse_pin_recovers_from_a_transient_download_failure() {
  local tmp destination result rc out
  tmp=$(fm_test_tmproot fm-treehouse-pin-download)
  destination="$tmp/bin"

  result=$(run_installer "$TREEHOUSE_INSTALLER" "$tmp" 1 "$destination")
  rc=$(printf '%s\n' "$result" | head -n 1)
  out=$(printf '%s\n' "$result" | tail -n +2)

  [ "$(cat "$tmp/curl-count")" -eq 2 ] \
    || fail "Treehouse pin did not retry exactly once after a transient failure"$'\n'"$out"
  assert_contains "$out" "download attempt 1 failed; retrying" \
    "Treehouse pin did not disclose its retry"
  assert_contains "$out" "checksum mismatch" \
    "Treehouse pin did not reach verification after recovering the download"
  assert_not_contains "$out" "download failed for" \
    "Treehouse pin still treated a recovered download as a download failure"
  [ "$rc" -ne 0 ] || fail "Treehouse pin installed an archive that failed its checksum"
  pass "Treehouse pin recovers from a transient download failure and still verifies"
}

test_treehouse_pin_gives_up_after_the_bounded_attempts() {
  local tmp destination result rc out
  tmp=$(fm_test_tmproot fm-treehouse-pin-exhaust)
  destination="$tmp/bin"

  result=$(run_installer "$TREEHOUSE_INSTALLER" "$tmp" 99 "$destination")
  rc=$(printf '%s\n' "$result" | head -n 1)
  out=$(printf '%s\n' "$result" | tail -n +2)

  [ "$rc" -ne 0 ] || fail "Treehouse pin reported success with every download failing"
  [ "$(cat "$tmp/curl-count")" -eq 5 ] \
    || fail "Treehouse pin did not stop at its bounded attempt count"$'\n'"$out"
  assert_contains "$out" "after 5 attempts" \
    "Treehouse pin did not name the exhausted attempt count"
  [ "$(printf '%s\n' "$(cat "$tmp/sleep-log")")" = "$(printf '2\n4\n8\n16')" ] \
    || fail "Treehouse pin did not back off between attempts"$'\n'"$(cat "$tmp/sleep-log")"
  [ ! -e "$destination/treehouse" ] \
    || fail "Treehouse pin left a binary behind after giving up"
  pass "Treehouse pin gives up after bounded, backed-off attempts and installs nothing"
}

test_herdr_pin_recovers_from_a_transient_download_failure
test_herdr_pin_gives_up_after_the_bounded_attempts
test_treehouse_pin_recovers_from_a_transient_download_failure
test_treehouse_pin_gives_up_after_the_bounded_attempts
