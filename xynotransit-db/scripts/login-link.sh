#!/usr/bin/env bash
# Prints the newest sign-in link that Mailpit received for an email address.
#   scripts/login-link.sh you@example.com [mailpit_url]
set -euo pipefail
EMAIL=${1:?email}
MAIL=${2:-http://127.0.0.1:8025}
id=$(curl -fsS "$MAIL/api/v1/search?query=to:$EMAIL" | python3 -c "import sys,json; print(json.load(sys.stdin)['messages'][0]['ID'])")
curl -fsS "$MAIL/api/v1/message/$id" | python3 -c "import sys,json,re; print(re.findall(r'http\S+', json.load(sys.stdin)['Text'])[0])"
