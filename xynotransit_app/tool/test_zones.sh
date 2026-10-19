#!/usr/bin/env bash
# Runs the date and period tests under the time zones that break naive code:
# +14 (Kiritimati), a zone with daylight saving (Los Angeles), +03 (Antananarivo), UTC.
#   tool/test_zones.sh [extra flutter test args or paths]
set -euo pipefail
export PATH="$HOME/projects/flutter/bin:$PATH"
cd "$(dirname "$0")/.."
TESTS=("$@")
if [ ${#TESTS[@]} -eq 0 ]; then
  TESTS=(test/data/time_test.dart test/domain_test.dart test/data/reconcile_test.dart test/summary_test.dart)
fi
for z in Pacific/Kiritimati America/Los_Angeles Indian/Antananarivo UTC; do
  echo "== TZ=$z"
  TZ=$z flutter test "${TESTS[@]}" --reporter failures-only
done
