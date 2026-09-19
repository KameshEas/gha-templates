#!/usr/bin/env bash
# Writes a chosen list of environment variables into the app's .env file.
#
# Why: decrypt-sops-secrets only *exports* secrets to the job's environment, and
# setup-flutter's ensure-env-file only copies .env.example to .env. A Flutter app
# reading flutter_dotenv can see neither the environment nor a build flag, so a
# value that lives only in the secrets file never reaches the app.
#
# Only the variables named in ENV_FILE_KEYS are written: the same environment also
# holds signing keys and service-account credentials, which must never be bundled
# into an app.
#
# Inputs (environment):
#   ENV_FILE_KEYS  comma-separated variable names, e.g. "ONESIGNAL_APP_ID,SENTRY_DSN"
#   ENV_FILE       file to write (default: .env)
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
keys="${ENV_FILE_KEYS:-}"

# Nothing requested: do nothing (and don't create a .env).
if [ -z "${keys//[[:space:]]/}" ]; then
  exit 0
fi

touch "$ENV_FILE"
# An appended line must start on its own line even if the file lacks a final newline.
if [ -s "$ENV_FILE" ] && [ -n "$(tail -c1 "$ENV_FILE")" ]; then
  printf '\n' >> "$ENV_FILE"
fi

IFS=',' read -ra names <<< "$keys"
for raw in "${names[@]}"; do
  name="${raw//[[:space:]]/}"
  [ -z "$name" ] && continue

  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "❌ env-file-keys: '${name}' is not a valid variable name"
    exit 1
  fi

  value="${!name-}"
  if [ -z "$value" ]; then
    echo "::warning::env-file-keys lists ${name}, but it is empty or not set in this job's environment (is it in the decrypted secrets file?). Leaving ${ENV_FILE} unchanged for it."
    continue
  fi

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "❌ ${name} contains a line break; ${ENV_FILE} can only hold single-line values"
    exit 1
  fi

  echo "::add-mask::${value}"

  # Replace an existing line (e.g. an empty placeholder copied from .env.example),
  # otherwise append. Never leaves two lines for the same key.
  grep -v "^${name}=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  printf '%s=%s\n' "$name" "$value" >> "$ENV_FILE"

  # Diagnostic only: the name and length, never the value.
  echo "  · wrote ${name} (${#value} chars) to ${ENV_FILE}"
done
