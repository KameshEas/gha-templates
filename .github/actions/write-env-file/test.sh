#!/usr/bin/env bash
# Tests for the write-env-file action. Run from anywhere:  bash test.sh
#
# The action's script is inline in action.yml, so this extracts the `run:` block and
# tests exactly what the workflow executes.
set -uo pipefail

ACTION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/action.yml"
SCRIPT="$(mktemp)"
sed -n '/^      run: |$/,$p' "$ACTION" | tail -n +2 | sed 's/^        //' > "$SCRIPT"
if [ ! -s "$SCRIPT" ]; then echo "could not extract the script from action.yml"; exit 1; fi
pass=0
fail=0

check() { # check "description" <exit-code-of-a-test-command>
  if [ "$2" -eq 0 ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1"; fi
}

# Runs the script in a fresh temp dir. Args after the first are VAR=value pairs.
# Leaves the temp dir in $DIR and the script's output in $OUT, its exit code in $RC.
run() {
  local keys="$1"; shift
  DIR="$(mktemp -d)"
  [ -n "${SEED:-}" ] && printf '%b' "$SEED" > "$DIR/.env"
  OUT="$(cd "$DIR" && env -i PATH="$PATH" ENV_FILE_KEYS="$keys" "$@" bash "$SCRIPT" 2>&1)"
  RC=$?
}

echo "writes a value into a new .env"
SEED="" run "ONESIGNAL_APP_ID" ONESIGNAL_APP_ID=abc-123
check "exit 0" $RC
check "line written" "$(grep -qx 'ONESIGNAL_APP_ID=abc-123' "$DIR/.env"; echo $?)"

echo "replaces an empty placeholder copied from .env.example, keeping other lines"
SEED="FIREBASE_APP_ID=x\nONESIGNAL_APP_ID=\nENCRYPTION_KEY=k\n" run "ONESIGNAL_APP_ID" ONESIGNAL_APP_ID=real-id
check "new value present" "$(grep -qx 'ONESIGNAL_APP_ID=real-id' "$DIR/.env"; echo $?)"
check "no empty duplicate left" "$([ "$(grep -c '^ONESIGNAL_APP_ID=' "$DIR/.env")" -eq 1 ]; echo $?)"
check "other lines untouched" "$(grep -qx 'FIREBASE_APP_ID=x' "$DIR/.env" && grep -qx 'ENCRYPTION_KEY=k' "$DIR/.env"; echo $?)"

echo "appends on its own line when the file has no trailing newline"
SEED="A=1" run "B" B=2
check "A intact" "$(grep -qx 'A=1' "$DIR/.env"; echo $?)"
check "B on its own line" "$(grep -qx 'B=2' "$DIR/.env"; echo $?)"

echo "several keys, with spaces in the list"
SEED="" run " ONESIGNAL_APP_ID , SENTRY_DSN " ONESIGNAL_APP_ID=one SENTRY_DSN=https://k@o.ingest.sentry.io/1
check "both written" "$(grep -qx 'ONESIGNAL_APP_ID=one' "$DIR/.env" && grep -qx 'SENTRY_DSN=https://k@o.ingest.sentry.io/1' "$DIR/.env"; echo $?)"

echo "keeps characters that appear in real values literally"
SEED="" run "K" 'K=a=b#c"d$e'
check "value preserved" "$(grep -qxF 'K=a=b#c"d$e' "$DIR/.env"; echo $?)"

echo "does NOT write variables that were not listed (signing keys stay out of the app)"
SEED="" run "ONESIGNAL_APP_ID" ONESIGNAL_APP_ID=one ANDROID_KEY_PASSWORD=secret ANDROID_KEYSTORE_BASE64=zzz
check "only the listed key is in .env" "$([ "$(wc -l < "$DIR/.env")" -eq 1 ] && ! grep -q 'ANDROID' "$DIR/.env"; echo $?)"

echo "a listed variable that is unset warns but does not fail or invent a value"
SEED="ONESIGNAL_APP_ID=\n" run "ONESIGNAL_APP_ID"
check "exit 0" $RC
check "workflow warning emitted" "$(echo "$OUT" | grep -q '::warning::.*ONESIGNAL_APP_ID'; echo $?)"
check ".env left unchanged" "$(grep -qx 'ONESIGNAL_APP_ID=' "$DIR/.env"; echo $?)"

echo "the log never contains the value"
SEED="" run "ONESIGNAL_APP_ID" ONESIGNAL_APP_ID=super-secret-value
check "value only appears in the ::add-mask:: line" "$(echo "$OUT" | grep -v '^::add-mask::' | grep -q 'super-secret-value'; [ $? -ne 0 ]; echo $?)"
check "length is reported" "$(echo "$OUT" | grep -q 'wrote ONESIGNAL_APP_ID (18 chars)'; echo $?)"

echo "rejects an invalid variable name"
SEED="" run "GOOD,bad name;rm" GOOD=1
check "exit 1" "$([ $RC -eq 1 ]; echo $?)"

echo "rejects a multi-line value"
SEED="" run "CREDS" "CREDS=$(printf 'line1\nline2')"
check "exit 1" "$([ $RC -eq 1 ]; echo $?)"

echo "no keys requested: does nothing and creates no .env"
SEED="" run "   "
check "exit 0" $RC
check "no .env created" "$([ ! -e "$DIR/.env" ]; echo $?)"

echo "running twice is idempotent"
SEED="" run "K" K=v
( cd "$DIR" && env -i PATH="$PATH" ENV_FILE_KEYS=K K=v bash "$SCRIPT" >/dev/null 2>&1 )
check "still exactly one K line" "$([ "$(grep -c '^K=' "$DIR/.env")" -eq 1 ]; echo $?)"

echo "the action does not depend on a script file or github.action_path (breaks in container jobs)"
CODE="$(grep -v '^[[:space:]]*#' "$ACTION")"   # ignore comments, which explain why
check "no github.action_path" "$(! echo "$CODE" | grep -q 'github.action_path'; echo $?)"
check "no reference to an external .sh file" "$(! echo "$CODE" | grep -Eq '\.sh( |$|")'; echo $?)"
check "no GitHub expression inside the script body" "$(! grep -q '\${{' "$SCRIPT"; echo $?)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
