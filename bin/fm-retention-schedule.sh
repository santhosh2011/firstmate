#!/usr/bin/env bash
# Install, inspect, or remove the per-home macOS retention LaunchAgent.
#
# Usage: fm-retention-schedule.sh install|status|uninstall|print-plist
#
# The agent starts at login and receives an hourly opportunity.
# bin/fm-retention.sh --apply --scheduled owns the once-per-day gate, session-lock
# coordination, deletion policy, and durable audit, so the plist contains no
# second scheduling or safety contract.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
ACTION=${1:-status}

home_hash=$(printf '%s' "$FM_HOME" | shasum -a 256 | awk '{print substr($1, 1, 12)}')
LABEL="com.firstmate.retention.$home_hash"
LAUNCH_AGENTS=${FM_RETENTION_LAUNCH_AGENTS_OVERRIDE:-$HOME/Library/LaunchAgents}
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
AUDIT_ROOT="$FM_HOME/data/retention"
SCHEDULER_LOG="$AUDIT_ROOT/scheduler.log"

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

render_plist() {
  local script home log
  script=$(printf '%s' "$SCRIPT_DIR/fm-retention.sh" | xml_escape)
  home=$(printf '%s' "$FM_HOME" | xml_escape)
  log=$(printf '%s' "$SCHEDULER_LOG" | xml_escape)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$script</string>
    <string>--apply</string>
    <string>--scheduled</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>$home</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$log</string>
  <key>StandardErrorPath</key>
  <string>$log</string>
</dict>
</plist>
EOF
}

case "$ACTION" in
  print-plist)
    render_plist
    ;;
  install)
    [ "$(uname -s)" = Darwin ] || { echo "fm-retention-schedule: launchd scheduling requires macOS" >&2; exit 1; }
    command -v launchctl >/dev/null 2>&1 || { echo "fm-retention-schedule: launchctl not found" >&2; exit 1; }
    mkdir -p "$LAUNCH_AGENTS" "$AUDIT_ROOT"
    tmp=$(mktemp "$LAUNCH_AGENTS/.retention-plist.XXXXXX")
    trap 'rm -f "$tmp"' EXIT HUP INT TERM
    render_plist > "$tmp"
    plutil -lint "$tmp" >/dev/null
    mv "$tmp" "$PLIST"
    trap - EXIT HUP INT TERM
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$UID" "$PLIST"
    printf 'installed %s at %s\n' "$LABEL" "$PLIST"
    ;;
  status)
    if [ ! -f "$PLIST" ]; then
      printf 'not installed: %s\n' "$PLIST"
      exit 1
    fi
    if command -v launchctl >/dev/null 2>&1 && launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
      printf 'loaded: %s\n' "$LABEL"
    else
      printf 'installed but not loaded: %s\n' "$PLIST"
      exit 1
    fi
    ;;
  uninstall)
    [ "$(uname -s)" = Darwin ] || { echo "fm-retention-schedule: launchd scheduling requires macOS" >&2; exit 1; }
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
    if [ -f "$PLIST" ] && [ ! -L "$PLIST" ]; then
      rm -f "$PLIST"
    elif [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
      echo "fm-retention-schedule: refusing unsafe plist path $PLIST" >&2
      exit 1
    fi
    printf 'uninstalled %s\n' "$LABEL"
    ;;
  -h|--help|help)
    sed -n '2,8p' "$0" | sed 's/^# *//'
    ;;
  *)
    echo "usage: fm-retention-schedule.sh install|status|uninstall|print-plist" >&2
    exit 2
    ;;
esac
