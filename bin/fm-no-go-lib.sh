# shellcheck shell=bash
# No-go path guard: the operator declares directories that agent work must never
# be dispatched into, and callers refuse before creating anything inside one.
# Usage: . bin/fm-no-go-lib.sh   (leaf library, no FM_* setup required)
#
# The prefixes live in a LOCAL, gitignored config/no-go-paths, one absolute path
# prefix per line. The operator's actual paths are private, so nothing tracked
# ever names them; only this mechanism ships. An ABSENT file means no
# restriction, which is what keeps every existing dispatch byte-identical.
# Absent is the ONLY unrestricted state: a path that exists in any other form -
# a directory, a dangling symlink, an unreadable file - is a boundary the
# operator declared and this library cannot read, so it refuses rather than
# silently reading it as "no restriction". Absence must also be provable: a
# config/ that cannot be searched leaves the file's state unknown, and that
# refuses too, naming the reason.
#
# Matching is on a path-component boundary, never a raw string prefix, so /a/b
# blocks /a/b and /a/b/c but never /a/bc. Both the literal and the physically
# resolved form of each side are compared, so a symlinked alias cannot route
# around a declared prefix - the guard errs toward refusing.
#
# A non-empty, non-comment line that is not an absolute path after ~ expansion is
# a hard error rather than a skipped line: a silently dropped line is a
# protection the operator believed was in force.
#
# docs/configuration.md "No-go paths" owns the operator-facing contract.

# config-dir-relative name of the declared prefix file.
FM_NO_GO_FILE="no-go-paths"

# Set by fm_no_go_match to the prefix that matched, cleared when nothing did.
FM_NO_GO_MATCH=

fm_no_go_config_path() {  # <config-dir>
  printf '%s/%s\n' "${1:-.}" "$FM_NO_GO_FILE"
}

# Strip leading and trailing whitespace, which also drops a CRLF carriage return.
fm_no_go_trim() {  # <string>
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# Normalise one already-trimmed configured line into a comparable absolute
# prefix: expand a leading ~, then drop trailing slashes while preserving a bare
# "/". Returns 1 when the result is not absolute.
fm_no_go_normalize_prefix() {  # <trimmed-line>
  local p=$1
  # The quoted ~ is config-file syntax being matched, not a path this script
  # wants the shell to expand - the expansion is the explicit ${HOME} below.
  # shellcheck disable=SC2088
  case "$p" in
    '~') p=${HOME:-} ;;
    '~/'*) p="${HOME:-}/${p#\~/}" ;;
  esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do
    p=${p%/}
  done
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *) return 1 ;;
  esac
}

# The physically resolved form of <path>, or <path> unchanged when it does not
# resolve. A configured prefix naming a directory that does not exist yet is
# legitimate, so an unresolvable path is compared literally rather than refused.
fm_no_go_canonical_dir() {  # <path>
  local real
  if real=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$1"
  fi
}

# 0 when <path> is <prefix> itself or sits beneath it on a component boundary.
fm_no_go_is_under() {  # <path> <prefix>
  local path=$1 prefix=$2
  [ -n "$path" ] && [ -n "$prefix" ] || return 1
  if [ "$prefix" = / ]; then
    case "$path" in
      /*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  [ "$path" != "$prefix" ] || return 0
  case "$path" in
    "$prefix"/*) return 0 ;;
  esac
  return 1
}

# The lstat probe that separates "absent" from "could not look". The shell's
# -e and -L tests answer "no" for both, and this guard reads absence as
# permission, so only a lookup that ran and answered ENOENT may count as absent.
# Prints 1 when <path> exists in some form and 0 when it is provably absent;
# fails with the errno text on stdout when the lookup itself could not happen,
# such as a config/ that cannot be searched. The same technique as
# fm_config_path_present in bin/fm-config-inherit-lib.sh, repeated here because
# this is a leaf library that callers source on its own.
fm_no_go_path_present() {  # <path>
  perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { print "$!"; exit 2 }
  ' -- "$1"
}

# 0 when <path> exists and is a readable regular file, 1 when it is PROVABLY
# absent, 2 with the reason on stderr when it exists but cannot be read as the
# declared prefix list, or when its state could not be established at all.
fm_no_go_config_readable() {  # <path>
  local file=$1 reason present status=0
  present=$(fm_no_go_path_present "$file") || status=$?
  if [ "$status" -ne 0 ]; then
    echo "error: $file could not be inspected (${present:-unknown error}), so the declared no-go paths cannot be read; refusing to dispatch" >&2
    return 2
  fi
  [ "$present" = 1 ] || return 1
  if [ -L "$file" ] && [ ! -e "$file" ]; then
    reason="is a dangling symlink"
  elif [ -d "$file" ]; then
    reason="is a directory"
  elif [ ! -f "$file" ]; then
    reason="is not a regular file"
  elif [ ! -r "$file" ]; then
    reason="is not readable"
  else
    return 0
  fi
  echo "error: $file $reason, so the declared no-go paths cannot be read; refusing to dispatch" >&2
  return 2
}

# Echo one normalised prefix per line. 0 with no output means unrestricted (the
# file is absent or holds only comments); 2 means malformed or unreadable,
# already reported.
fm_no_go_prefixes() {  # <config-dir>
  local file line trimmed prefix lineno=0 readable=0
  file=$(fm_no_go_config_path "$1")
  fm_no_go_config_readable "$file" || readable=$?
  case "$readable" in
    0) ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    trimmed=$(fm_no_go_trim "$line")
    [ -n "$trimmed" ] || continue
    # As above: the quoted ~ is matched literally, never expanded here.
    # shellcheck disable=SC2088
    case "$trimmed" in
      '#'*) continue ;;
      '~'|'~/'*)
        if [ -z "${HOME:-}" ]; then
          echo "error: $file line $lineno expands ~ but HOME is not set: $trimmed" >&2
          return 2
        fi
        ;;
    esac
    if ! prefix=$(fm_no_go_normalize_prefix "$trimmed"); then
      echo "error: $file line $lineno is not an absolute path prefix: $trimmed" >&2
      return 2
    fi
    printf '%s\n' "$prefix"
  done < "$file"
}

# 0 and FM_NO_GO_MATCH set when <path> is inside a declared prefix, 1 when it is
# allowed, 2 when the config is malformed. The matching prefix is also echoed so
# a caller can use this without reading the global.
fm_no_go_match() {  # <path> <config-dir>
  local path=$1 dir=$2 prefixes path_real prefix prefix_real
  FM_NO_GO_MATCH=
  if ! prefixes=$(fm_no_go_prefixes "$dir"); then
    return 2
  fi
  [ -n "$prefixes" ] || return 1
  path_real=$(fm_no_go_canonical_dir "$path")
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    prefix_real=$(fm_no_go_canonical_dir "$prefix")
    if fm_no_go_is_under "$path" "$prefix" \
      || fm_no_go_is_under "$path_real" "$prefix_real"; then
      FM_NO_GO_MATCH=$prefix
      printf '%s\n' "$prefix"
      return 0
    fi
  done <<EOF
$prefixes
EOF
  return 1
}

# 0 when <path> may be used, 1 with the refusal on stderr when it may not. <label>
# names the path in the operator's terms, e.g. "project directory".
fm_no_go_assert() {  # <label> <path> <config-dir>
  local label=$1 path=$2 dir=$3 status=0
  fm_no_go_match "$path" "$dir" >/dev/null || status=$?
  case "$status" in
    0)
      echo "error: $label '$path' is inside the no-go path '$FM_NO_GO_MATCH' declared in config/$FM_NO_GO_FILE; refusing to dispatch there" >&2
      return 1
      ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}
