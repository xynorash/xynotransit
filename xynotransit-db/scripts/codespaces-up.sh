#!/usr/bin/env bash
# Starts the full stack inside a GitHub Codespace and points the sign-in links at
# the forwarded address of the app.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${CODESPACE_NAME:-}" ]; then
  DOMAIN=${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}
  export PUBLIC_URL="https://${CODESPACE_NAME}-8080.${DOMAIN}"
  MAILPIT_URL="https://${CODESPACE_NAME}-8025.${DOMAIN}"
else
  export PUBLIC_URL=${PUBLIC_URL:-http://127.0.0.1:8080}
  MAILPIT_URL=http://127.0.0.1:8025
fi
export BOOTSTRAP_CONTROLLER_EMAIL=${BOOTSTRAP_CONTROLLER_EMAIL:-demo.manager@xynotransit.example}
export BOOTSTRAP_CONTROLLER_NAME=${BOOTSTRAP_CONTROLLER_NAME:-Demo Manager}

docker compose -f docker-compose.yml -f docker-compose.full.yml up -d --build

echo
echo "App:      $PUBLIC_URL"
echo "Mailpit:  $MAILPIT_URL"
echo "Sign in as the manager: $BOOTSTRAP_CONTROLLER_EMAIL"
echo "Then read the link in Mailpit, or run: xynotransit-db/scripts/login-link.sh $BOOTSTRAP_CONTROLLER_EMAIL"
