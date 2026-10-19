#!/usr/bin/env bash
# Writes netlify.toml into a build folder, with the key taken from the
# environment. Usage:
#   PROXY_AUTH_KEY=... [API_ORIGIN=https://host] ./make_netlify_toml.sh <build-dir>
# The folder must be a copy of the build (not a folder tracked by git).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_dir="${1:-}"
[ -n "$out_dir" ] || { echo "usage: make_netlify_toml.sh <build-dir>" >&2; exit 2; }
[ -d "$out_dir" ] || { echo "not a folder: $out_dir" >&2; exit 2; }

key="${PROXY_AUTH_KEY:-}"
origin="${API_ORIGIN:-https://84-12-108-224.sslip.io}"
origin="${origin%/}"

if [ -z "$key" ]; then
  echo "PROXY_AUTH_KEY is not set (make one with: openssl rand -hex 32)" >&2; exit 1
fi
if [ "${#key}" -lt 32 ]; then
  echo "PROXY_AUTH_KEY is too short (needs at least 32 characters)" >&2; exit 1
fi
case "$key" in
  *[!A-Za-z0-9._~+/=-]*) echo "PROXY_AUTH_KEY may only use letters, digits and . _ ~ + / = -" >&2; exit 1;;
esac
case "$origin" in
  https://*) ;;
  *) echo "API_ORIGIN must start with https://" >&2; exit 1;;
esac
case "$origin" in
  *[!A-Za-z0-9.:/_-]*) echo "API_ORIGIN has odd characters" >&2; exit 1;;
esac

# Never write inside a git work tree's tracked area.
real="$(cd "$out_dir" && pwd)"
if top="$(git -C "$real" rev-parse --show-toplevel 2>/dev/null)"; then
  if ! git -C "$real" check-ignore -q "$real/netlify.toml" 2>/dev/null; then
    echo "refusing: $real is inside git and netlify.toml there is not ignored" >&2; exit 1
  fi
fi

tmp="$(mktemp "$real/.netlify.toml.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"
# Plain string replacement (no sed, so no special characters to escape).
content="$(cat "$here/netlify.toml.example")"
content="${content//__API_ORIGIN__/$origin}"
content="${content//__PROXY_AUTH_KEY__/$key}"
printf '%s\n' "$content" > "$tmp"
mv "$tmp" "$real/netlify.toml"
trap - EXIT
echo "wrote $real/netlify.toml (key not shown)"
