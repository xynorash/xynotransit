# xynotransit-api

Rust backend (axum 0.8, tokio, sqlx) for the Xynotransit Logistics Report Builder. It is the only thing that talks to Postgres. Authorization lives here, not in row level security. Everything is under `/api`, JSON, snake_case.

See `../xynotransit_app/README.md` for the whole system and `../xynotransit-db/README.md` for the stack.

## Run

Needs a Postgres with the schema (`xynotransit-db/initdb/01-schema.sql`, `02-api.sql` and `03-dynamic.sql`). The catalog starts empty: the first manager comes from `BOOTSTRAP_CONTROLLER_EMAIL` and builds teams, people and seats in the app.

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
| `RUST_LOG` | `info` | Log filter. |

## Endpoints

All except `/api/health` and the two auth endpoints need `Authorization: Bearer <jwt>`. Errors are the HTTP status plus `{"error":"plain words"}`: 400, 401, 403, 404, 409, 429, 500.

| Method and path | Who | Purpose |
| --- | --- | --- |
| `GET /api/health` | anyone | `{"ok":true}`, checks the database. |
| `POST /api/auth/magic-link` | anyone | `{email}`. Always 202 (no enumeration). 429 after 5 links per hour. |
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
| `PUT /api/assignments/{id}/definitions` | controller | `{metrics:[{id?,label}], kpis:[{id?,text}]}` in one transaction. 0 to 8 counts (name 1 to 60, unique ignoring case; list order is the series order), 0 to 20 targets (text 1 to 200). An entry with an `id` keeps its row; entries without one are added; listed-out rows are retired, never deleted. A target with changed text is retired and replaced, so old reports keep their wording. Returns the seat as in the catalog. |
| `GET /api/summary?period_id=...&trend=6` | controller | Numbers for the manager dashboard: headline counts, teams, counts grouped by name (ignoring case), the trend over up to `trend` periods (1 to 24, default 6, oldest first) and people. Only submitted reports count. |
| `POST /api/periods/ensure` | signed in | `{start_month}`. Creates the period if missing. |
| `PATCH /api/periods/{id}` | controller | `{meeting_date}`. |
| `GET /api/periods/{id}/reports` | controller | All reports of the period. |
| `GET /api/periods/{id}/reports/{assignment_id}` | owner of the seat, controller | One report or 404. Others get 403 "You can only see your own report." |
| `PUT /api/periods/{id}/reports/{assignment_id}` | owner of the seat, controller | Validate, replace and submit in one transaction. Others get 403 "You can only send your own report." |
| `GET /api/periods/{id}/deck` | controller | Latest deck run or `null`. Has `texts`, the words frozen into that deck (old decks with none read as the defaults). |
| `POST /api/periods/{id}/deck` | controller | Build and freeze a deck, including the effective slide texts, in one transaction. 201. |
| `GET /api/periods/{id}/deck-text` | controller | `{settings, inherited_from, updated_at}`. `settings` has every key of `deck_text_defaults.json`. A period without its own words inherits the latest earlier period's (`inherited_from` is its label, such as "Feb to Apr 2026"), else the built-in defaults (`"defaults"`). `inherited_from` and `updated_at` are null when the period has its own. 404 for an unknown period. |
| `PUT /api/periods/{id}/deck-text` | controller | `{settings:{...}}`. Missing keys take the defaults, unknown keys are 400, values are trimmed. Per key: empty only where allowed, at most N characters, only the allowed `{placeholders}`, no control or invisible characters (line breaks only in `suggestionsBody`). Returns the same shape with `inherited_from` null. Editing never changes an existing deck. |
| `POST /api/events/ticket` | controller | `{ticket}`, 60 seconds, single use. |
| `GET /api/events?ticket=...&period_id=...` | controller (checked again when the ticket is used) | Server-Sent Events: `data: {"kind":"reports"|"deck","period_id":"..."}`, heartbeat `: ping` every 20 seconds. |

Roles: `contributor` (employee) and `controller` (manager). A refused controller-only call answers 403 `{"error":"Only the controller can do this."}`. The role is read from the database on every request, so the UI split is not the security boundary; this table is.

## How it works

- **Magic link:** a random 32 byte token; only its SHA-256 is stored in `login_token` (15 minute expiry, `used_at`). Verify is one atomic update, so only one use succeeds. The rate limit counts rows in `login_token` under a per person advisory lock. Mail is sent in a background task so response time does not reveal whether an address exists.
- **Auth:** the JWT (sub = person_id, 7 days) only proves who. Role and active flag are read from the database on every request.
- **Catalog:** managers build it through the admin endpoints. Counts keep their `series` (0 to 7) as list order; a reorder first parks rows at 1000 and up because of the partial unique index on `(assignment_id, series)`. Notes are free text only: the `note_suggestion` table is kept but no longer read.
- **Reports:** PUT runs in one transaction: authorise (own seat or controller), validate, upsert as draft, replace values, KPI results and notes, call `submit_report`.
- **Deck texts:** keys, defaults, placeholders and limits live in `deck_text_defaults.json` (copies in `src/` and `tests/fixtures/`, a test checks they match the app copy in `xynotransit_app/docs/reference/`). Texts are stored per period and frozen into each deck run.
- **Decks:** snapshots are built on the server from submitted reports. Old decks stay frozen when a report is sent again.
- **Live updates:** triggers in `02-api.sql` send `NOTIFY xt_changes` with `{kind, period_id}`. One `PgListener` task (reconnects with backoff) fans out through a broadcast channel to SSE clients. Responses carry `X-Accel-Buffering: no`.
- Body limit 256 KB, response timeout 30 s, no CORS layer (same origin through nginx). Database errors are logged, never returned.

## Tests

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

Integration tests (`tests/api.rs`, `tests/security.rs`, `tests/dynamic.rs`) need Postgres. Each test creates a throwaway database and drops it afterwards. The default admin URL is `postgres://xynotransit:xynotransit@127.0.0.1:5432/postgres`; override it with `TEST_ADMIN_URL`. Start the db first: `docker compose up -d db` in `../xynotransit-db`.

## Layout

```
src/main.rs        start, config, bootstrap controller
src/config.rs      env settings
src/auth.rs        JWT, current user loading
src/mail.rs        SMTP (lettre) and a capture mailer for tests
src/validate.rs    plain word validation of a report
src/rules.rs       slugs and rules for names, emails, counts and targets
src/summary.rs     pure aggregation behind /api/summary
src/snapshot.rs    deck snapshot builder
src/deck_text.rs   slide text rules and defaults (pure)
src/listener.rs    Postgres LISTEN fan out
src/routes/        auth, catalog, admin (teams, persons, seats, definitions), summary, periods, reports, decks, events, health
tests/             integration and security tests
```

## Slide texts (deck-text)

The words of the slides are stored per period and frozen into each deck. Only a controller can call these endpoints (403 "Only the controller can do this.").

- Keys, defaults, allowed placeholders and limits come from `src/deck_text_defaults.json`, a copy of `../xynotransit_app/docs/reference/deck_text_defaults.json` (also kept as `tests/fixtures/deck_text_defaults.json`). A unit test asserts the copies are byte-identical; it is skipped with a message when the Flutter project is not next to this one.
- Messages match the app's: "<Label> cannot be empty.", "<Label> can be at most N characters.", "{x} cannot be used in <Label>. It allows {a}, {b}." (or "It allows no placeholders."), plus "Use plain text in <Label>." for control or invisible characters, "<key> is not a text setting." for unknown keys and "<Label> must be text." for non-strings.
- Effective words of a period: its own row in `deck_text`, else the latest earlier period's (by start month), else the defaults, always completed with defaults for missing keys.
- `POST /api/periods/{id}/deck` copies the effective words into `deck_run.texts` in the same transaction. `GET` deck returns them as `texts`; an old row with `{}` reads as the defaults.
- Tables: `deck_text(period_id, settings, updated_at, updated_by)` and the column `deck_run.texts`, from `xynotransit-db/initdb/04-deck-text.sql`.
- Tests: unit tests in `src/deck_text.rs`, integration tests in `tests/deck_text.rs`.
