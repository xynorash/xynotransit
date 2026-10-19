#!/usr/bin/env bash
# Builds the web app, adds netlify.toml with the key, deploys to Netlify.
#   PROXY_AUTH_KEY=... NETLIFY_SITE=<site id or name> ./deploy.sh [--draft]
# You must already be logged in (netlify login). No credentials are handled
# here. Without --draft this is a production deploy.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$(cd "$here/../.." && pwd)"
site="${NETLIFY_SITE:-}"
prod=(--prod)
[ "${1:-}" = "--draft" ] && prod=()

[ -n "$site" ] || { echo "set NETLIFY_SITE to the site id or name" >&2; exit 1; }
[ -n "${PROXY_AUTH_KEY:-}" ] || { echo "set PROXY_AUTH_KEY (same value as on the server)" >&2; exit 1; }
[ "${#PROXY_AUTH_KEY}" -ge 32 ] || { echo "PROXY_AUTH_KEY is too short (32 characters at least)" >&2; exit 1; }

export PATH="$HOME/.local/bin:$HOME/projects/flutter/bin:$PATH"
command -v flutter >/dev/null || { echo "flutter not found" >&2; exit 1; }
command -v netlify >/dev/null || { echo "netlify CLI not found" >&2; exit 1; }

# A fresh folder outside git, so no old file or key can be left behind.
work="$(mktemp -d "${TMPDIR:-/tmp}/xynotransit-netlify.XXXXXX")"
trap 'rm -rf "$work"' EXIT
build="$work/site"

( cd "$app" && flutter build web --release --no-web-resources-cdn \
    --dart-define=API_BASE_URL=/api --output "$build" )

# The Netlify CLI reads netlify.toml from the folder it runs in, not from the
# published folder. So the file sits next to the build, never inside it, and
# the key is never published as a static file.
"$here/make_netlify_toml.sh" "$work"

# --no-build: the site is already built; deploy the folder as it is.
out="$(cd "$work" && netlify deploy "${prod[@]}" --no-build --dir site --site "$site" --json)"
if command -v jq >/dev/null; then
  echo "$out" | jq -r '.url // .deploy_url // empty, .logs // empty' | grep -v '^$' || true
else
  echo "$out" | grep -Eo '"(url|deploy_url)": *"[^"]+"' || echo "$out"
fi
