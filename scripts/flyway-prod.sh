#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      export "$line"
    fi
  done < .env
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Error: required environment variable is not set: $var_name" >&2
    exit 1
  fi
}

configure_sp_auth_env() {
  require_env DATABRICKS_HOST
  require_env DATABRICKS_CLIENT_ID
  require_env DATABRICKS_CLIENT_SECRET

  # Force service-principal OAuth for this script run and avoid accidental
  # fallback to user/PAT/profile auth from the shell session.
  export DATABRICKS_AUTH_TYPE="oauth-m2m"
  unset DATABRICKS_TOKEN
  unset DATABRICKS_USERNAME
  unset DATABRICKS_PASSWORD
}

generate_prod_credential_from_instance() {
  require_cmd databricks
  require_cmd jq
  require_env PROD_INSTANCE_NAME
  require_env PROD_DATABASE_URL
  require_env DATABRICKS_HOST
  require_env DATABRICKS_CLIENT_ID
  require_env DATABRICKS_CLIENT_SECRET

  configure_sp_auth_env

  local response
  if ! response="$(databricks postgres generate-database-credential "${PROD_INSTANCE_NAME}" -o json 2>&1)"; then
    echo "Error: failed generating PROD database credential from PROD_INSTANCE_NAME using Databricks CLI." >&2
    echo "Hint: ensure Databricks OAuth M2M env is valid (DATABRICKS_HOST, DATABRICKS_CLIENT_ID, DATABRICKS_CLIENT_SECRET, optional DATABRICKS_AUTH_TYPE=oauth-m2m)." >&2
    echo "Databricks CLI output:" >&2
    echo "$response" >&2
    exit 1
  fi

  PROD_DATABASE_USER="$(printf '%s' "$response" | jq -r '.username // .user // empty')"
  if [[ -z "$PROD_DATABASE_USER" || "$PROD_DATABASE_USER" == "null" ]]; then
    PROD_DATABASE_USER="${DATABRICKS_CLIENT_ID}"
  fi
  export PROD_DATABASE_USER

  PROD_DATABASE_PASSWORD="$(printf '%s' "$response" | jq -r '.token // empty')"
  if [[ -z "$PROD_DATABASE_PASSWORD" || "$PROD_DATABASE_PASSWORD" == "null" ]]; then
    echo "Error: generated PROD database credential did not include token." >&2
    exit 1
  fi

  export PROD_DATABASE_PASSWORD
}

generate_prod_credential_from_instance

COMMAND="${1:-migrate}"
if [[ $# -gt 0 ]]; then
  shift
fi

FLYWAY_BIN="${FLYWAY_BIN:-$(command -v flyway || true)}"
if [[ -z "$FLYWAY_BIN" && -x "$HOME/tools/flyway-13.10.0/flyway" ]]; then
  FLYWAY_BIN="$HOME/tools/flyway-13.10.0/flyway"
fi

if [[ -z "$FLYWAY_BIN" ]]; then
  echo "Error: flyway binary not found. Add it to PATH or set FLYWAY_BIN." >&2
  exit 1
fi

exec "$FLYWAY_BIN" -environment=prod "$COMMAND" "$@"
