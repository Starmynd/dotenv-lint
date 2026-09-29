#!/usr/bin/env bash
# dotenv-lint - lint .env files: duplicates, syntax errors, missing keys, weak secrets
set -u
# Deterministic character ranges ([A-Z] must not match lowercase in exotic locales)
LC_ALL=C
export LC_ALL

PROG="dotenv-lint"
VERSION="1.0.0"

usage() {
  cat <<EOF
$PROG $VERSION - lint .env files

Usage:
  $PROG [options] FILE [FILE...]

Options:
  -e FILE   Compare keys against a reference .env/.env.example file;
            keys present in the reference but missing from the target
            are reported as errors.
  -q        Quiet: print nothing on success.
  -h        Show this help.

Checks:
  - duplicate KEY definitions
  - lines that are not KEY=VALUE (comments and blanks are fine)
  - keys that are not UPPER_SNAKE_CASE (warning)
  - empty value for keys like TOKEN / SECRET / PASSWORD / API_KEY (error)
  - unquoted values containing spaces (error)
  - keys referenced in the example file but absent (error with -e)

Exit codes: 0 clean, 1 errors found, 2 usage error.
EOF
}

ERRORS=0
WARNINGS=0
QUIET=0
EXAMPLE_FILE=""

err() { ERRORS=$((ERRORS + 1)); printf '%s:%s: error: %s\n' "$1" "$2" "$3"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '%s:%s: warning: %s\n' "$1" "$2" "$3"; }

strip_inline_comment() {
  # Remove an unquoted trailing comment: VALUE  # comment -> VALUE
  # A '#' is a comment start only when preceded by whitespace.
  local v="$1"
  case "$v" in
    \#*) echo "" ;;
    \"*|\'*) echo "$v" ;;
    *" #"*)
      echo "$v" | sed 's/[[:space:]]*#.*$//' ;;
    *) echo "$v" ;;
  esac
}

lint_file() {
  local file="$1"
  local lineno=0 line key value
  local keys_tmp
  keys_tmp=$(mktemp)

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Trim surrounding whitespace
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$line" in
      ""|\#*) continue ;;
    esac
    line=${line#export }
    case "$line" in
      *=*) ;;
      *)
        err "$file" "$lineno" "not a KEY=VALUE line: '$line'"
        continue
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      *[!A-Za-z0-9_]*|[0-9]*)
        err "$file" "$lineno" "invalid key '$key'"
        continue
        ;;
    esac
    case "$key" in
      [A-Z_]*)
        : ;;
      *)
        warn "$file" "$lineno" "key '$key' is not UPPER_SNAKE_CASE"
        ;;
    esac
    if grep -qx "$key" "$keys_tmp"; then
      err "$file" "$lineno" "duplicate key '$key'"
    fi
    printf '%s\n' "$key" >> "$keys_tmp"

    value=$(strip_inline_comment "$value")
    case "$value" in
      "") ;;
      \"*\") ;;
      \'*\') ;;
      *" "*)
        err "$file" "$lineno" "unquoted value of '$key' contains spaces"
        ;;
    esac
    if [ -z "$value" ]; then
      case "$key" in
        *PASSWORD*|*PASSWD*|*SECRET*|*TOKEN*|*API_KEY*|*_KEY)
          err "$file" "$lineno" "secret key '$key' has an empty value"
          ;;
      esac
    fi
  done < "$file"

  if [ -n "$EXAMPLE_FILE" ] && [ -f "$EXAMPLE_FILE" ]; then
    local ekey
    while IFS= read -r ekey; do
      [ -n "$ekey" ] || continue
      if ! grep -qx "$ekey" "$keys_tmp"; then
        err "$file" "-" "key '$ekey' from $EXAMPLE_FILE is missing"
      fi
    done < <(sed -n 's/^[[:space:]]*\(export \)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*$/\2/p' "$EXAMPLE_FILE")
  fi

  rm -f "$keys_tmp"
}

PASS=0
FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $3 (got '$1', want '$2')"; fi
}
assert_match() {
  if printf '%s\n' "$1" | grep -q -- "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $3"; fi
}

cmd_selftest() {
  local d out rc
  d=$(mktemp -d)

  printf 'DB_HOST=localhost\nDB_PORT=5432\nAPI_TOKEN=abcdef123\nMSG="two words"\n' > "$d/clean.env"
  out=$(lint_one "$d/clean.env"); rc=$?
  assert_eq "$rc" "0" "clean file passes"
  assert_eq "$out" "" "clean file has no output"

  printf 'A=1\nA=2\n' > "$d/dup.env"
  out=$(lint_one "$d/dup.env"); rc=$?
  assert_match "$out" "duplicate key 'A'" "duplicate detected"
  assert_eq "$rc" "1" "duplicate is an error"

  printf 'this is not kv\nGOOD=1\n' > "$d/badline.env"
  out=$(lint_one "$d/badline.env"); rc=$?
  assert_match "$out" "not a KEY=VALUE line" "bad line detected"
  assert_eq "$rc" "1" "bad line is an error"

  printf 'foo=1\n' > "$d/lower.env"
  out=$(lint_one "$d/lower.env"); rc=$?
  assert_match "$out" "not UPPER_SNAKE_CASE" "lowercase key warned"
  assert_eq "$rc" "0" "warning does not fail"

  printf 'API_TOKEN=\nOK=1\n' > "$d/empty_secret.env"
  out=$(lint_one "$d/empty_secret.env"); rc=$?
  assert_match "$out" "empty value" "empty secret detected"
  assert_eq "$rc" "1" "empty secret is an error"

  printf 'MSG=hello world\n' > "$d/spaces.env"
  out=$(lint_one "$d/spaces.env"); rc=$?
  assert_match "$out" "contains spaces" "unquoted spaces detected"
  assert_eq "$rc" "1" "unquoted spaces is an error"

  printf 'A=1\nB=2\nC=3\n' > "$d/example.env"
  printf 'A=1\n' > "$d/target.env"
  out=$(lint_pair "$d/target.env" "$d/example.env"); rc=$?
  assert_match "$out" "key 'B' from .* is missing" "missing key B detected"
  assert_match "$out" "key 'C' from .* is missing" "missing key C detected"
  assert_eq "$rc" "1" "missing keys are errors"

  printf '# comment\n\nexport EXPORTED=1\n' > "$d/ok.env"
  out=$(lint_one "$d/ok.env"); rc=$?
  assert_eq "$rc" "0" "comments/blank/export accepted"

  rm -rf "$d"
  echo "selftest: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ] || exit 2
}

lint_one() { ERRORS=0; WARNINGS=0; lint_file "$1"; if [ "$ERRORS" -gt 0 ]; then return 1; fi; return 0; }
lint_pair() { ERRORS=0; WARNINGS=0; EXAMPLE_FILE="$2"; lint_file "$1"; EXAMPLE_FILE=""; if [ "$ERRORS" -gt 0 ]; then return 1; fi; return 0; }

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -e) EXAMPLE_FILE="$2"; shift 2 ;;
    -q) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --selftest) cmd_selftest; exit $? ;;
    -*) usage; exit 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ "${#ARGS[@]}" -eq 0 ]; then
  usage
  exit 2
fi

for f in "${ARGS[@]}"; do
  if [ ! -f "$f" ]; then
    echo "$f: error: file not found"
    ERRORS=$((ERRORS + 1))
    continue
  fi
  lint_file "$f"
done

if [ "$ERRORS" -gt 0 ]; then
  [ "$QUIET" -eq 1 ] || echo "dotenv-lint: $ERRORS error(s), $WARNINGS warning(s)"
  exit 1
fi
[ "$QUIET" -eq 1 ] || echo "dotenv-lint: clean ($WARNINGS warning(s))"
exit 0
