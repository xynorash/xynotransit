# xynotransit-api

Rust backend (axum 0.8, tokio, sqlx) for the Xynotransit Logistics Report Builder. It is the only thing that talks to Postgres. Authorization lives here, not in row level security. Everything is under `/api`, JSON, snake_case.

See `../xynotransit_app/README.md` for the whole system and `../xynotransit-db/README.md` for the stack.

## Run

Needs a Postgres with the schema: every file of `xynotransit-db/initdb/` in name order (`01` to `07`; a database that lives on is brought up to date with `xynotransit-db/scripts/migrate.sh`). The catalog starts empty: the first manager comes from `BOOTSTRAP_CONTROLLER_EMAIL` and builds teams, people and seats in the app.

```bash
cd ../xynotransit-db && docker compose up -d db      # database on 127.0.0.1:5432
cd ../xynotransit-api
export DATABASE_URL=postgres://xynotransit:xynotransit@127.0.0.1:5432/xynotransit
export JWT_SECRET=dev-only-secret-change-me-0123456789abcdef
export SMTP_HOST=127.0.0.1 LOG_MAGIC_LINKS=true
cargo run --release
```

Or use the full stack with `docker compose up -d --build` in `xynotransit-db`. The image is built from `Dockerfile` (multi stage, runs as a non-root user, health check via `xynotransit-api healthcheck`).

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `DATABASE_URL` | required | Postgres URL. |
| `JWT_SECRET` | required | HS256 secret, at least 32 characters. |
| `PUBLIC_URL` | `http://127.0.0.1:8080` | Origin in magic links: `{PUBLIC_URL}/auth/verify?token=...`. |
| `SMTP_HOST` | `mailpit` | SMTP host. |
| `SMTP_PORT` | `1025` | SMTP port. |
| `MAIL_FROM` | `Xynotransit <no-reply@xynotransit.local>` | Sender. |
| `BIND` | `0.0.0.0:8081` | Listen address. |
| `BOOTSTRAP_CONTROLLER_EMAIL` | none | At start, that person becomes an active controller. Created when missing, promoted and activated when present. |
| `BOOTSTRAP_CONTROLLER_NAME` | capitalised part of the email before the `@` | Name used only when the person is created. |
| `LOG_MAGIC_LINKS` | `false` | Logs links at info level. Dev only. |
| `RUST_LOG` | `info,sqlx=warn` | Log filter. |
| `LOG_FORMAT` | text | `json` writes one JSON object per log line. |
| `SHUTDOWN_GRACE_SECS` | `8` | After SIGTERM, how long requests that are running get to finish (1 to 300). Keep it below the container stop timeout (10 s by default in Docker). |

## Endpoints

All except `/api/health` and the two auth endpoints need `Authorization: Bearer <jwt>`. Errors are the HTTP status plus `{"error":"plain words"}`, always JSON, for every status: 400 (also JSON that does not parse), 401, 403, 404, 405 (with `Allow`), 408 (slower than 30 s), 409, 413 (body over 256 KB), 415 (not `application/json`), 429, 500, 503. Nothing from the database, no file path and no stack trace ever reaches a body.

| Method and path | Who | Purpose |
| --- | --- | --- |
| `GET /api/health` | anyone | 200 `{"ok":true,"db":"up"}` when a query reaches the database within 3 seconds; otherwise 503 `{"ok":false,"db":"down","error":"..."}`. |
| `POST /api/auth/magic-link` | anyone | `{email}`. Always 202 (no enumeration). 429 "Too many links requested. Try again later." after 5 requests per hour, counted per normalised email string in `login_attempt`, so known and unknown addresses behave the same. |
| `POST /api/auth/verify` | anyone | `{token}`. Returns `{access_token, expires_at, user}`. Single use. |
| `GET /api/me` | signed in | `{person_id, role, label}`. |
| `GET /api/catalog` | signed in | Teams, persons, assignments with metrics and KPIs. Every person and assignment has `active`. A contributor sees active rows only, with `email` null for everyone but themselves. A controller can add `?include_inactive=true` to get inactive persons and seats too. Retired counts and targets are never listed. |
| `POST /api/teams` | controller | `{name}` (1 to 60). Returns 201 `{id, code, name, sort}`; the code is a slug of the name, sort is last plus one. 409 when the name is used. |
| `PATCH /api/teams/{id}` | controller | `{name?, sort?}`. |
| `DELETE /api/teams/{id}` | controller | 204. 409 "Move or remove the seats of this team first." while any seat (active or not) is in it. |
| `POST /api/persons` | controller | `{full_name, email, app_role}`. Email is trimmed and lowercased, 409 when used. 201. |
| `PATCH /api/persons/{id}` | controller | `{full_name?, email?, app_role?, active?}`. 409 "There must be at least one manager." when it would leave no active controller. An inactive person cannot sign in and every token of theirs stops working (401). |
| `POST /api/assignments` | controller | `{person_id, team_id, role_title}`. 201 with the seat. 409 when that person already has that role in that team. |
| `PATCH /api/assignments/{id}` | controller | `{team_id?, role_title?, active?, sort?}`. Inactive seats are no longer expected in any period; their old reports stay. |
| `PUT /api/assignments/{id}/definitions` | controller | `{metrics:[{id?,label}], kpis:[{id?,text}]}` in one transaction. 0 to 8 counts (name 1 to 60, unique ignoring case; list order is the series order), 0 to 10 targets (text 1 to 200). An entry with an `id` keeps its row; entries without one are added; listed-out rows are retired, never deleted. A target with changed text is retired and replaced, so old reports keep their wording. Returns the seat as in the catalog. |
| `GET /api/summary?period_id=...&trend=6` | controller | Numbers for the manager dashboard: headline counts, teams, counts grouped by name (ignoring case), the trend over up to `trend` periods (1 to 24, default 6, oldest first) and people. Only submitted reports count. |
| `POST /api/periods/ensure` | signed in | `{start_month}`. Creates the period if missing. |
| `PATCH /api/periods/{id}` | controller | `{meeting_date}`. |
| `GET /api/periods/{id}/reports` | controller | All reports of the period. |
| `GET /api/periods/{id}/reports/{assignment_id}` | owner of the seat, controller | One report or 404. Others get 403 "You can only see your own report." |
| `PUT /api/periods/{id}/reports/{assignment_id}` | owner of the seat, controller | Validate, replace and submit in one transaction. Others get 403 "You can only send your own report." Body adds `reporter:{name,country,role}` (required, each trimmed, 1 to 80 characters, plain text; 400 "Enter your name.", "Enter your country.", "Enter your role." first). Stored in `report.reporter_*`; report JSON returns `reporter` or null for reports sent before it existed. |
| `GET /api/periods/{id}/deck` | controller | Latest deck run or `null`. Has `texts`, the words frozen into that deck (old decks with none read as the defaults). |
| `POST /api/periods/{id}/deck` | controller | Build and freeze a deck from the submitted reports (any number, zero too: cover and suggestions page only), including the effective slide texts, in one transaction. 201. `expected_count` is the active seats, `included_count` the submitted reports. |
| `GET /api/periods/{id}/deck-text` | every active person (employees need it for the live preview) | `{settings, inherited_from, updated_at}`. `settings` has every key of `deck_text_defaults.json`. A period without its own words inherits the latest earlier period's (`inherited_from` is its label, such as "Feb to Apr 2026"), else the built-in defaults (`"defaults"`). `inherited_from` and `updated_at` are null when the period has its own. 404 for an unknown period. |
| `PUT /api/periods/{id}/deck-text` | controller | `{settings:{...}}`. Missing keys take the defaults, unknown keys are 400, values are trimmed. Per key: empty only where allowed, at most N characters, only the allowed `{placeholders}`, no control or invisible characters (line breaks only in `suggestionsBody`). Returns the same shape with `inherited_from` null. Editing never changes an existing deck. |
| `POST /api/events/ticket` | controller | `{ticket}`, 60 seconds, single use. |
| `GET /api/events?ticket=...&period_id=...` | controller (checked again when the ticket is used) | Server-Sent Events: `data: {"kind":"reports"|"deck","period_id":"..."}`, heartbeat `: ping` every 20 seconds. |

Roles: `contributor` (employee) and `controller` (manager). A refused controller-only call answers 403 `{"error":"Only the controller can do this."}`. The role is read from the database on every request, so the UI split is not the security boundary; this table is.

## How it works

- **Magic link:** a random 32 byte token; only its SHA-256 is stored in `login_token` (15 minute expiry, `used_at`). Verify is one atomic update, so only one use succeeds. The rate limit counts rows in `login_attempt` (keyed by the normalised email string, written for unknown addresses too) under a per email advisory lock. Mail is sent in a background task so response time does not reveal whether an address exists.
- **Auth:** the JWT (sub = person_id, 7 days) only proves who. Role and active flag are read from the database on every request.
- **Catalog:** managers build it through the admin endpoints. Counts keep their `series` (0 to 7) as list order; a reorder first parks rows at 1000 and up because of the partial unique index on `(assignment_id, series)`. Notes are free text only: the `note_suggestion` table is kept but no longer read.
- **Reports:** PUT runs in one transaction: authorise (own seat or controller), validate, upsert as draft, replace values, KPI results and notes, call `submit_report`.
- **Deck texts:** keys, defaults, placeholders and limits live in `deck_text_defaults.json` (copies in `src/` and `tests/fixtures/`, a test checks they match the app copy in `xynotransit_app/docs/reference/`). Texts are stored per period and frozen into each deck run.
- **Decks:** snapshots are built on the server from submitted reports. Name and role come from the report's reporter words, and the snapshot field `team` carries the reporter's country (legacy reports without reporter words use the catalog profile). The app groups slides by country (case-insensitive, whitespace collapsed, first spelling shown, first appearance order); `snapshot::country_key` is the reference. The dashboard summary still groups by catalog teams (assumption). `tests/fixtures/snapshot_case.json` is the shared contract proven by the Rust and Dart tests. Old decks stay frozen when a report is sent again.
- **Live updates:** triggers in `02-api.sql` send `NOTIFY xt_changes` with `{kind, period_id}`. One `PgListener` task (reconnects with backoff) fans out through a broadcast channel to SSE clients. Responses carry `X-Accel-Buffering: no`.
- **Single source of rules:** every limit and fixed message lives in `src/rules.rs` (constants and `rules::msg`). `tests/fixtures/rules.json` repeats them for the other side (the Flutter tests read `../xynotransit-api/tests/fixtures/rules.json`); `rules_json_matches_code` fails when the two drift apart. Add keys, never rename one. Deck text limits stay in `deck_text_defaults.json`.
- **Request id:** every response has `X-Request-Id` (a short plain id sent by the caller is kept, else a new one) and every log line of that request carries it. One log line per request: method, path (never the query, which holds event tickets), status, milliseconds. Bodies, tokens, emails and magic links are never logged; links appear only when `LOG_MAGIC_LINKS=true` (dev). Health checks log at debug.
- **Headers on every answer:** `X-Content-Type-Options: nosniff`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'`, `Cross-Origin-Resource-Policy: same-origin`. A panic in a handler becomes a plain 500 and is logged.
- **Limits:** body 256 KB (413), request 30 s until the answer starts (408; open event streams are not cut), database statements 20 s, a transaction idle for more than 30 s is ended by the database, 10 pooled connections. No CORS layer (same origin through nginx).
- **Shutdown:** on SIGTERM or Ctrl-C the server stops taking connections, ends the event streams at once, lets requests that are running finish (up to `SHUTDOWN_GRACE_SECS`), then exits. `tests/ops.rs` proves it with a request held by a table lock.
- **Deck content:** a slide shows the counts and targets the report was answered against, also when the manager changed or retired them since (the deck reads the definitions that the report has answers for). If a retired count and a renumbered live count share a series number, the slide renumbers them so no two bars share a colour.
- **Who is expected:** a seat is expected in a period when the seat and its person are both switched on (summary `expected`, deck `expected_count`, the views). Old reports of a switched off seat or person stay, still count in the summary totals (so `submitted` can exceed `expected`) and still list the person, but the deck only holds active seats of active people.
- **Summary names:** the shown name of a count (counts with the same name ignoring case are added) is chosen by rule, not alphabet: a live name beats a retired one, then the lower series, then the id.
- Database errors are logged, never returned.

## Tests

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

| File | What it proves |
| --- | --- |
| `src/*` unit tests | rules, validation, summary and snapshot math, config, `rules.json` matches the code |
| `tests/api.rs`, `security.rs`, `dynamic.rs`, `reporter.rs`, `review.rs`, `deck_text*.rs` | the behaviour the READMEs describe |
| `tests/integrity.rs` | the database refuses bad rows by itself (06-integrity.sql), frozen decks, `updated_at`, migrations run twice |
| `tests/property.rs` | hundreds of seeded random catalogs, reports and decks: `/api/summary` and the deck compared with plain brute force loops (`tests/common/model.rs`). `PROPTEST_CASES`, `PROPTEST_SEED`; a failure prints its seed |
| `tests/fuzz.rs` | malformed and random input (wrong types, huge numbers, unicode, NUL, deep nesting, huge arrays, duplicate ids, hostile paths and queries) to every endpoint as nobody, a bad token, an employee, a manager and a switched off person: never a 5xx, always `{"error"}` on 4xx, no SQL or paths in a body. `FUZZ_ITERS`, `FUZZ_SEED` |
| `tests/concurrency.rs` | the same report sent 16 times at once, definitions edited at once, decks made while people send, a double click on the magic link, the sign-in limit under parallel requests, two managers demoting each other |
| `tests/ops.rs` | request ids, headers, JSON for 404/405/408/413/415/400, 503 health, panic to JSON, logs without secrets, graceful shutdown |
| `tests/data_review.rs` | edge cases: fresh install, empty period, years 2000 and 2100, team without seats, a person with two seats in one team, a seat or person switched off after reporting, deck faithfulness after definition edits |
| `tests/perf.rs` | 300 seats x 24 periods x 8 counts: every call must answer in under 300 ms (release; debug has 1500 ms) |

`cargo test --release --test perf -- --nocapture` prints the timings. The migration and backup scripts have their own tests in `../xynotransit-db/scripts` (`test-migrations.sh`, `test-backup.sh`).

Integration tests need Postgres. Each test creates a throwaway database and drops it afterwards. The default admin URL is `postgres://xynotransit:xynotransit@127.0.0.1:5432/postgres`; override it with `TEST_ADMIN_URL`. Start the db first: `docker compose up -d db` in `../xynotransit-db`. `TEST_TEMPLATE_DB=<database>` builds each test database from a copy of that database (emptied) instead of the initdb files; `test-migrations.sh` uses it to run the whole suite on a migrated copy of the live data.

## Layout

```
src/main.rs        start, logging, config, bootstrap controller, signals
src/http.rs        request id and logging, JSON errors for every status, security headers, panic to JSON
src/config.rs      env settings
src/auth.rs        JWT, current user loading
src/mail.rs        SMTP (lettre) and a capture mailer for tests
src/validate.rs    plain word validation of a report
src/rules.rs       every limit and message (the single source), slugs and rules for names, emails, counts and targets
src/summary.rs     pure aggregation behind /api/summary
src/snapshot.rs    deck snapshot builder
src/deck_text.rs   slide text rules and defaults (pure)
src/listener.rs    Postgres LISTEN fan out
src/routes/        auth, catalog, admin (teams, persons, seats, definitions), summary, periods, reports, decks, events, health
tests/             integration, security, property, fuzz, concurrency, operations and performance tests
tests/fixtures/rules.json   the limits and messages for other test suites (see above)
```

## Slide texts (deck-text)

The words of the slides are stored per period and frozen into each deck. Only a controller can call these endpoints (403 "Only the controller can do this.").

- Keys, defaults, allowed placeholders and limits come from `src/deck_text_defaults.json`, a copy of `../xynotransit_app/docs/reference/deck_text_defaults.json` (also kept as `tests/fixtures/deck_text_defaults.json`). A unit test asserts the copies are byte-identical; it is skipped with a message when the Flutter project is not next to this one.
- Messages match the app's: "<Label> cannot be empty.", "<Label> can be at most N characters.", "{x} cannot be used in <Label>. It allows {a}, {b}." (or "It allows no placeholders."), plus "Use plain text in <Label>." for control or invisible characters, "<key> is not a text setting." for unknown keys and "<Label> must be text." for non-strings.
- Effective words of a period: its own row in `deck_text`, else the latest earlier period's (by start month), else the defaults, always completed with defaults for missing keys.
- `POST /api/periods/{id}/deck` copies the effective words into `deck_run.texts` in the same transaction. `GET` deck returns them as `texts`; an old row with `{}` reads as the defaults.
- Tables: `deck_text(period_id, settings, updated_at, updated_by)` and the column `deck_run.texts`, from `xynotransit-db/initdb/04-deck-text.sql`.
- Tests: unit tests in `src/deck_text.rs`, integration tests in `tests/deck_text.rs`.
