# shellcheck shell=bash
# Tri-state path classification for guards that treat absence as permission.
# Usage: . bin/fm-path-state-lib.sh   (leaf library, no FM_* setup required)
#
# The shell's existence tests are two-state, and their "no" conflates two very
# different facts: the entry is not there, and the entry could not be looked up.
# `[ ! -e "$p" ] && [ ! -L "$p" ]` is false for a file whose PARENT directory is
# not searchable, and a bare `[ -f "$p" ]` has the same flaw. Any guard that
# reads absence as permission - an absent config/no-go-paths means unrestricted,
# an absent inherited item means delete the downstream copy - must never accept
# that answer, because "I could not look" is not "it is not there".
#
# So this library answers three ways, and absence is provable only when the
# directory holding the entry could itself be searched:
#   0  FM_PATH_STATE_EXISTS          the entry is there in some form
#   1  FM_PATH_STATE_ABSENT          provably not there
#   2  FM_PATH_STATE_UNDETERMINABLE  the state could not be established
#
# Callers must fail closed on UNDETERMINABLE. Only ABSENT may take an absence
# path. This is the single owner of that classification; do not reimplement it.

FM_PATH_STATE_EXISTS=0
FM_PATH_STATE_ABSENT=1
FM_PATH_STATE_UNDETERMINABLE=2

# Short human reason, set only alongside an UNDETERMINABLE answer. Read it
# through fm_path_state_reason rather than the variable.
FM_PATH_STATE_REASON=

fm_path_state_reason() {
  printf '%s' "$FM_PATH_STATE_REASON"
}

fm_path_state() {  # <path>
  local path=$1 parent parent_state=0
  FM_PATH_STATE_REASON=
  if [ -z "$path" ]; then
    FM_PATH_STATE_REASON="the path is empty"
    return "$FM_PATH_STATE_UNDETERMINABLE"
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    return "$FM_PATH_STATE_EXISTS"
  fi
  # Both tests answered "no". That is an absence only if the lookup could
  # actually happen, which means the parent is a directory this process can
  # search. Anything else is a failed lookup wearing absence's clothes.
  parent=${path%/*}
  if [ -z "$parent" ]; then
    parent=/
  elif [ "$parent" = "$path" ]; then
    parent=.
  fi
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    if [ ! -d "$parent" ]; then
      FM_PATH_STATE_REASON="its parent '$parent' is not a directory"
      return "$FM_PATH_STATE_UNDETERMINABLE"
    fi
    if [ ! -x "$parent" ]; then
      FM_PATH_STATE_REASON="its parent directory '$parent' is not searchable"
      return "$FM_PATH_STATE_UNDETERMINABLE"
    fi
    return "$FM_PATH_STATE_ABSENT"
  fi
  # The parent did not answer either, so ask the same question of it: a genuinely
  # missing ancestor chain is a genuine absence, an unsearchable one is not.
  fm_path_state "$parent" || parent_state=$?
  if [ "$parent_state" -eq "$FM_PATH_STATE_ABSENT" ]; then
    FM_PATH_STATE_REASON=
    return "$FM_PATH_STATE_ABSENT"
  fi
  return "$FM_PATH_STATE_UNDETERMINABLE"
}
