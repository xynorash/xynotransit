#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose up -d --build "$@"
echo "App:     http://127.0.0.1:8080"
echo "Mailpit: http://127.0.0.1:8025"
