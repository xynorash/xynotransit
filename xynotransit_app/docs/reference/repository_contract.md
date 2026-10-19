# Repository contract

The app talks to a `Repository` (`lib/data/repository.dart`). There are two
implementations: `MemoryRepository` (demo mode and most tests) and
`ApiRepository` (the product, over HTTP to the axum API). They must behave the
same: same results, same refusals, same words.

`test/contract/` holds one suite of scenarios that runs against both.

```bash
# In memory only (always runs, also in plain `flutter test`)
flutter test test/contract

# Also against the real API on the live stack (docker compose up -d --build)
flutter test test/contract --dart-define=CONTRACT_API=http://127.0.0.1:8080
```

Without the define the API group is skipped, and the skip message says how to
turn it on. Mailpit is read at `http://127.0.0.1:8025`
(`--dart-define=CONTRACT_MAIL=...` changes it).

What the API run does:

- signs in as the dev manager (`CONTRACT_MANAGER`, default
  `shalini@xynotransit.example`) once, creates its own manager, and signs in
  as that one, through real magic links read from Mailpit;
- creates everything under a unique tag (`ct<hex>`), employees included, each
  signed in through its own link (a person can get 5 links an hour; the suite
  asks for one per person and clears the counter of an address that is limited);
- puts its periods in 2080 to 2099, far from real data;
- removes everything it made at the end. With docker access it deletes the rows
  (`docker exec xynotransit-db-db-1 psql`). Without it, it switches the people
  and seats off and leaves empty teams and periods.
  `tool/contract_cleanup.sh` does the deletion after a run that was killed.

Scenarios: teams, people, last manager, seats, counts and targets (1, 8, 9,
reorder, retire, 10 and 11 targets, foreign ids), catalog as employee and as
manager, send, replace and edit a report (every refusal, string for string),
periods and meeting dates, who may do what (every operation), a deactivated
person, a closed period, live reports, decks with 0, 1 and N reports, deck words
(inherit and freeze), the summary against the pure computation
(`computeSummary`) over the same data (also after a person is switched off), and
too many sign-in requests (the 429 carries `Retry-After`).

A scenario that passes on one side and fails on the other is a real difference.
Fix the wrong side. The in-memory side is `lib/data/memory_repository.dart` and
the shared rules in `lib/domain/` (`admin.dart`, `report.dart`,
`text_rules.dart`); the API side is `xynotransit-api`.

## Rules parity

`test/contract/rules_parity_test.dart` reads
`../xynotransit-api/tests/fixtures/rules.json` (every limit and fixed message of
the API) and compares each Dart constant and message with it. A message the app
never produces must be listed in `serverOnly` in that test, so a new key in
`rules.json` cannot slip in unseen.

## Rules both sides follow

- **Who is expected:** a seat is expected in a period when the seat and its
  person are both switched on (`Catalog.isExpected`, `Catalog.expectedCount`).
  In the summary, `submitted`, `met`, `partly` and `missed` (headline, teams,
  trend) count only the reports of expected seats, so `submitted` is never more
  than `expected`. Reports of switched off seats or people are counted apart in
  `submitted_inactive` (headline, teams, trend, and `switched_off_count` in a
  deck): never expected, never missing, but real. Their counts and volume stay
  in the volume and the counts, and the seat stays in the people list with
  `active: false` while it has a report. The deck holds every submitted report,
  also those: `included_count` counts them, `expected_count` does not.
- **What a slide shows:** the counts and targets the report was answered
  against, retired ones included, in series and sort order. A count added
  after the report was sent (no numbers) is not on the slide. If a retired
  count and a renumbered live one share a series, the series are renumbered in
  order.
- **Summary counts:** grouped by lower case label, only counts that have
  numbers in a report of the shown period; the shown name is the live one before
  the retired one, then the lower series.
- **Default catalog view** (a manager who does not ask for the inactive ones)
  leaves out switched off seats, switched off people, and the seats of switched
  off people.
- **Employee catalog view:** an employee gets only their own person (with
  their own email), their own switched on seats and the teams of those seats.
  No other name, role or team is sent, and asking for the inactive ones changes
  nothing. A deactivated person's session ends at once (401 "Please sign in.").
- The words for a manager only call are "Only the manager can do this." (the
  role value in the JSON stays `controller`).
- A 429 carries `Retry-After` in seconds. The client turns "Try again later."
  into "Try again in 5 minutes." (`ApiException.retryAfterSeconds`).
- A name with odd spaces (a non breaking space from a paste) is not refused:
  the app turns them into plain spaces before it sends, so the server and the
  demo see the same text. Control and invisible characters are refused with
  "Use plain text on one line." (names) or the "must be plain text on one line"
  words (reporter).

## Known differences

- The "last manager" guard is not run against the shared dev stack (it would
  need to switch off the real managers). The Rust integration tests cover it
  (`tests/dynamic.rs`).

## Time, numbers, scale

- `test/data/time_test.dart`: periods, labels and dates in any time zone. Run
  with `tool/test_zones.sh` (Kiritimati +14, Los Angeles, Antananarivo, UTC).
  A date from the server is a calendar date: the day it was written with.
- `test/data/numbers_test.dart`: counts up to 1,000,000,000, sums to
  24,000,000,000 and beyond, exact in JavaScript numbers; `parseCount` accepts
  digits only. Also passes with `--platform chrome`.
- `test/data/scale_test.dart`: 500 seats and 1,000 reports through the summary,
  the snapshots, the deck and the in-memory server, with generous limits.

## Failure classes of the HTTP client

| Situation | Exception | Retried |
| --- | --- | --- |
| offline, DNS, refused, reset, body cut short | `NetworkException` | GET and idempotent calls, 3 tries |
| no answer in 20 s | `RequestTimeout` (a `NetworkException`) | once |
| 408, 502, 503, 504 (nginx page or the API not ready) | `NetworkException` | as above |
| 401 with the current token | `UnauthorizedException`, the session is cleared once | never |
| other 4xx and 5xx | `ApiException` with the server words (429: plus the wait from `Retry-After`) | never |
| 2xx that is not the expected JSON | `RepositoryException` "cannot read" | never |

Idempotent writes (sent with `idempotent: true`): sending a report, saving deck
words, setting the meeting date, opening a period. Creating things (POST) is
never repeated blindly.
