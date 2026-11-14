#!/usr/bin/env bash

# Resolve paths relative to the location of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"

# List all .env files you want to load
ENV_FILES=(
  "$SCRIPT_DIR/.env.confluent"
  "$SCRIPT_DIR/.env.cloudflare"
)

# Enable automatic export of all sourced variables
set -a

for env_file in "${ENV_FILES[@]}"; do
  if [[ -f "$env_file" ]]; then
    source "$env_file"
    echo "Loaded: $env_file"
  else
    echo "Skipped (not found): $env_file"
  fi
done

# Disable automatic export
set +a

echo "Environment variables loaded into current session."
