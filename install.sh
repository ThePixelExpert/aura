#!/bin/sh
# Aura self-host installer.
#
# Generates the three required secrets (api_token, master_key, broker_token) into
# compose.yaml if they're still the CHANGE_ME placeholder, then starts the stack.
# Safe to re-run: if secrets are already set, it skips straight to `docker compose up -d`.
#
# Usage:
#   mkdir aura && cd aura
#   curl -fsSL https://raw.githubusercontent.com/ThePixelExpert/aura/main/install.sh | sh
#
# Or, if you already have compose.yaml in the current directory:
#   ./install.sh

set -eu

COMPOSE_FILE="compose.yaml"
COMPOSE_URL="https://raw.githubusercontent.com/ThePixelExpert/aura/main/compose.yaml"

command -v docker >/dev/null 2>&1 || { echo "docker is not installed. Install Docker Engine 24+ (or Docker Desktop) first." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required to generate secrets." >&2; exit 1; }

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "No $COMPOSE_FILE here yet, fetching it..."
  curl -fsSLo "$COMPOSE_FILE" "$COMPOSE_URL"
fi

gen_hex() { openssl rand -hex 32; }
gen_master_key() { head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '='; }

if grep -q '"CHANGE_ME"' "$COMPOSE_FILE"; then
  echo "First run: generating the three secrets..."
  API_TOKEN=$(gen_hex)
  BROKER_TOKEN=$(gen_hex)
  MASTER_KEY=$(gen_master_key)

  tmp=$(mktemp)
  awk -v api="$API_TOKEN" -v broker="$BROKER_TOKEN" -v master="$MASTER_KEY" '
    /api_token: &api_token "CHANGE_ME"/      { sub(/"CHANGE_ME"/, "\"" api "\"") }
    /master_key: &master_key "CHANGE_ME"/    { sub(/"CHANGE_ME"/, "\"" master "\"") }
    /broker_token: &broker_token "CHANGE_ME"/{ sub(/"CHANGE_ME"/, "\"" broker "\"") }
    { print }
  ' "$COMPOSE_FILE" > "$tmp" && mv "$tmp" "$COMPOSE_FILE"

  if grep -q '"CHANGE_ME"' "$COMPOSE_FILE"; then
    echo "Could not find the expected CHANGE_ME lines to replace - compose.yaml may have been edited." >&2
    echo "Open it and set api_token, master_key and broker_token by hand (see the comments at the top of the file)." >&2
    exit 1
  fi

  echo
  echo "=============================================================================="
  echo " Secrets generated and written into $COMPOSE_FILE."
  echo
  echo " BACK UP this master_key now. It seals the credential files in the data"
  echo " volume - lose it and anything already sealed with it cannot be read back."
  echo
  echo "   master_key: $MASTER_KEY"
  echo "=============================================================================="
  echo
else
  echo "Secrets already set in $COMPOSE_FILE - skipping generation."
fi

# ---- GPU auto-enable (only affects the optional local-models ollama service) --------------
# Ollama itself already splits a model's layers between GPU VRAM and system RAM/CPU on its
# own at runtime - there is nothing to configure for that "spill over" behaviour. The only
# manual step compose.yaml used to require was telling Docker it may hand the GPU to the
# container at all. If a usable NVIDIA GPU is detected, enable that automatically; otherwise
# leave it alone (CPU-only, which still works, just slower). AMD/Intel GPUs need a different
# Ollama image/device setup and are not auto-detected here - see the README if that's you.
if grep -q '^    # deploy:$' "$COMPOSE_FILE"; then
  gpu_usable=0
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
      gpu_usable=1
    fi
  fi

  if [ "$gpu_usable" = "1" ]; then
    tmp2=$(mktemp)
    sed \
      -e 's/^    # deploy:$/    deploy:/' \
      -e 's/^    #   resources:$/      resources:/' \
      -e 's/^    #     reservations:$/        reservations:/' \
      -e 's/^    #       devices:$/          devices:/' \
      -e 's/^    #         - driver: nvidia$/            - driver: nvidia/' \
      -e 's/^    #           count: all$/              count: all/' \
      -e 's/^    #           capabilities: \[gpu\]$/              capabilities: [gpu]/' \
      "$COMPOSE_FILE" > "$tmp2" && mv "$tmp2" "$COMPOSE_FILE"
    echo "NVIDIA GPU detected and usable by Docker - enabled GPU acceleration for local models."
  else
    echo "No usable NVIDIA GPU detected - local models (if you turn them on) will run on CPU."
    echo "(Have an NVIDIA GPU but see this? Install the NVIDIA Container Toolkit, then re-run this script.)"
  fi
fi

echo "Starting Aura..."
docker compose up -d

echo
echo "Aura is starting. Open http://localhost:3010 (or whatever address you set via"
echo "x-address in compose.yaml), then go to Settings -> AI Providers to add your key."
