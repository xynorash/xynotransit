#!/usr/bin/env bash
# Stops the stack and DELETES the database volume. initdb/*.sql re-run on next start.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down -v
docker compose up -d --build
