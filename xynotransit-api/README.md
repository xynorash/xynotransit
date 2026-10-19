# xynotransit-api

Rust backend (axum 0.8, tokio, sqlx) for the Xynotransit Logistics Report Builder. It is the only thing that talks to Postgres. Authorization lives here, not in row level security. Everything is under `/api`, JSON, snake_case.

See `../xynotransit_app/README.md` for the whole system and `../xynotransit-db/README.md` for the stack.

## Run

Needs a Postgres with the schema: every file of `xynotransit-db/initdb/` in name order (`01` to `11`; a database that lives on is brought up to date with `xynotransit-db/scripts/migrate.sh`). The catalog starts empty: the first manager comes from `BOOTSTRAP_CONTROLLER_EMAIL` and builds teams, people and seats in the app.

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
| `SMTP_TLS` | `none` | `none` (plain, for Mailpit), `starttls` (port 587) or `tls` (port 465). Use `starttls` or `tls` with a real provider; the certificate is checked. |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | none | Sign in to the mail server. Set both or neither. |
| `MAIL_FROM` | `Xynotransit <no-reply@xynotransit.local>` | Sender. |
| `BIND` | `0.0.0.0:8081` | Listen address. |
| `BOOTSTRAP_CONTROLLER_EMAIL` | none | At start, that person becomes an active manager (the stored role value is still `controller`). Created when missing, promoted and activated when present. |
| `BOOTSTRAP_CONTROLLER_NAME` | capitalised part of the email before the `@` | Name used only when the person is created. |
| `INTERNAL_EMAIL_DOMAINS` | `xynotransit.internal` | Comma separated. An address at one of these domains is internal: it never receives mail (see "Sign in without an email"). The first domain is used for addresses the server generates. |
| `PASSWORD_HASH_MEMORY_KIB`, `PASSWORD_HASH_ITERATIONS` | `19456`, `2` | Argon2id cost of NEW password hashes (parallelism is always 1). The defaults are the OWASP minimum; leave them alone. The test suite sets `64` and `1` so it stays fast; below the minimum the API logs a warning at start. A stored hash carries its own parameters, so changing these never locks anyone out: a hash made with other parameters is made again on the next good sign-in. |
| `LOG_MAGIC_LINKS` | `false` | Logs links at info level. Dev only. |
| `RUST_LOG` | `info,sqlx=warn` | Log filter. |
| `LOG_FORMAT` | text | `json` writes one JSON object per log line. |
| `SHUTDOWN_GRACE_SECS` | `8` | After SIGTERM, how long requests that are running get to finish (1 to 300). Keep it below the container stop timeout (the compose file sets `stop_grace_period: 15s`; Docker's default is 10 s). |

## Endpoints

All except `/api/health` and the two auth endpoints need `Authorization: Bearer <jwt>`. Errors are the HTTP status plus `{"error":"plain words"}`, always JSON, for every status: 400 (also JSON that does not parse), 401, 403, 404, 405 (with `Allow`), 408 (slower than 30 s), 409, 413 (body over 256 KB), 415 (not `application/json`), 429, 500, 503. Nothing from the database, no file path and no stack trace ever reaches a body.

| Method and path | Who | Purpose |
| --- | --- | --- |
| `GET /api/health` | anyone | 200 `{"ok":true,"db":"up"}` when a query reaches the database within 3 seconds; otherwise 503 `{"ok":false,"db":"down","error":"..."}`. |
| `POST /api/auth/magic-link` | anyone | `{email}`. Always 202 (no enumeration). 429 "Too many links requested. Try again later." after 5 requests per hour, counted per normalised email string in `login_attempt`, so known and unknown addresses behave the same. |
| `POST /api/auth/verify` | anyone | `{token}`. Returns `{access_token, expires_at, user, has_password, must_change_password}`. Single use. |
| `POST /api/auth/login` | anyone | `{username, password}`. 200 `{access_token, expires_at, user:{person_id, role, label}, must_change_password, has_password:true}`. A wrong or unknown username, a wrong password, a switched off person and a person without a password all answer 401 `{"error":"Username or password is wrong."}` after the same work (an unknown name is checked against a dummy hash). 429 "Too many sign-in attempts. Try again later." with `Retry-After` (see "Passwords"). 503 "Busy, try again in a moment." when too many hashes run. |
| `POST /api/auth/password` | signed in (also while a new password is required) | `{current_password?, new_password}`. A person who has a password must send `current_password` (400 "Enter your current password." when missing, 403 "Your current password is not right." when wrong, and a wrong one counts like a failed sign-in of that username); a person who has none (first password after a link) does not. The new password must pass the policy (400 with the plain message) and differ from the current one. Sets `must_change_password` to false, adds 1 to `session_epoch` and answers 200 `{access_token, expires_at}`: a fresh session; every older session of the person stops working. Audit kind `change`. |
| `GET /api/me` | signed in (also while a new password is required) | `{person_id, role, label, username, has_password, must_change_password}`. |
| `GET /api/catalog` | signed in | Teams, persons, assignments with metrics and KPIs. Every person and assignment has `active`. A contributor sees ONLY themselves: their own person, their own active seats and the teams of those seats (no other name, role or team), with active rows only. A manager can add `?include_inactive=true` to get inactive persons and seats too. Retired counts and targets are never listed. |
| `POST /api/teams` | manager | `{name}` (1 to 60). Returns 201 `{id, code, name, sort}`; the code is a slug of the name, sort is last plus one. 409 when the name is used. |
| `PATCH /api/teams/{id}` | manager | `{name?, sort?}`. |
| `DELETE /api/teams/{id}` | manager | 204. 409 "Move or remove the seats of this team first." while any seat (active or not) is in it. |
| `POST /api/persons` | manager | `{full_name, email?, app_role, username?}`. Email is trimmed and lowercased, 409 when used. When `email` is missing, null or blank the server makes a unique internal address from the name (`rosa.rakoto@xynotransit.internal`, then `rosa.rakoto2@...`). An address typed at an internal domain is kept as typed. `username` is optional: valid (lowercased) or 400 "Usernames use letters, digits, dots, dashes and underscores, 3 to 40 characters.", taken 409 "That username is already used."; without it the server uses the part of the email before the `@` (cleaned, numbered on conflict: `rosa.rakoto`, `rosa.rakoto2`). 201 with the person, including the address, `username` and `has_password`. |
| `POST /api/persons/{id}/sign-in-link` | manager | `{hours?}` (a whole number from 1 to 168, default 24; send `{}` for the default). 201 `{url, expires_at, person_id}`: `url` is `{PUBLIC_URL}/auth/verify?token=...`, `expires_at` is RFC 3339 UTC (`2026-10-20T08:30:00Z`). The link is single use and goes through `POST /api/auth/verify` like a magic link. 400 "Choose a validity from 1 hour to 168 hours.", 404 unknown person, 409 "This person is switched off.", 429 "Too many sign-in links created. Try again later." after 30 links per issuing manager per hour. Making another link does not cancel an earlier one. Every link adds a row to `sign_in_link_audit` (never the token). |
| `PATCH /api/persons/{id}` | manager | `{full_name?, email?, app_role?, active?, username?}` (username rules as above; the password stays). 409 "There must be at least one manager." when it would leave no active manager. An inactive person cannot sign in and every token of theirs stops working (401). |
| `POST /api/persons/{id}/password-reset` | manager | Body `{}`. 201 `{username, temporary_password, must_change_password:true}`: a random 16 character password from an alphabet without look-alikes (no `0 O 1 l I`), shown exactly once here and never stored in clear. The person has to choose their own at once (see "Passwords"), every older session of theirs ends, another reset replaces the first. Audit kind `reset` with `issued_by`. 404 unknown person, 409 "This person is switched off.", 429 "Too many temporary passwords created. Try again later." after 30 per manager per hour. |
| `DELETE /api/persons/{id}/password` | manager | 204. Removes the password (the person signs in with links only again), ends every older session. Audit kind `remove`. 404 unknown person. |
| `POST /api/assignments` | manager | `{person_id, team_id, role_title}`. 201 with the seat. 409 when that person already has that role in that team. |
| `PATCH /api/assignments/{id}` | manager | `{team_id?, role_title?, active?, sort?}`. Inactive seats are no longer expected in any period; their old reports stay. |
| `PUT /api/assignments/{id}/definitions` | manager | `{metrics:[{id?,label}], kpis:[{id?,text}]}` in one transaction. 0 to 8 counts (name 1 to 60, unique ignoring case; list order is the series order), 0 to 10 targets (text 1 to 200). An entry with an `id` keeps its row; entries without one are added; listed-out rows are retired, never deleted. A target with changed text is retired and replaced, so old reports keep their wording. Returns the seat as in the catalog. |
| `GET /api/summary?period_id=...&trend=6` | manager | Numbers for the manager dashboard: headline counts, teams, counts grouped by name (ignoring case), the trend over up to `trend` periods (1 to 24, default 6, oldest first) and people. Only submitted reports count. `expected` is the active seats of active people; `submitted`, `met`, `partly` and `missed` (headline, `teams[]`, `trend[]`) count only the reports of those expected seats, so `submitted <= expected`. `submitted_inactive` counts the reports of switched-off seats or people (never expected, never missing); their counts and volume still add into `metrics`, team volume and `volume_total`, and `people[]` lists them with `active: false`. |
| `POST /api/periods/ensure` | signed in | `{start_month}`. Creates the period if missing. |
| `PATCH /api/periods/{id}` | manager | `{meeting_date}`. |
| `GET /api/periods/{id}/reports` | manager | All reports of the period. |
| `GET /api/periods/{id}/reports/{assignment_id}` | owner of the seat, manager | One report or 404. Others get 403 "You can only see your own report." |
| `PUT /api/periods/{id}/reports/{assignment_id}` | owner of the seat, manager | Validate, replace and submit in one transaction. Others get 403 "You can only send your own report." Body adds `reporter:{name,country,role}` (required, each trimmed, 1 to 80 characters, plain text; 400 "Enter your name.", "Enter your country.", "Enter your role." first). Stored in `report.reporter_*`; report JSON returns `reporter` or null for reports sent before it existed. |
| `GET /api/periods/{id}/deck` | manager | Latest deck run or `null`. Has `texts`, the words frozen into that deck (old decks with none read as the defaults). |
| `POST /api/periods/{id}/deck` | manager | Build and freeze a deck from the submitted reports (any number, zero too: cover and suggestions page only), including the effective slide texts, in one transaction. 201. `expected_count` is the active seats of active people. `included_count` is every submitted report of the period, including those of switched-off seats or people; `switched_off_count` (also in the GET) says how many of those came from a switched-off seat or person (so the header reads "1 of 1 reports in, plus 1 from a switched-off person" as `included_count - switched_off_count` of `expected_count`). |
| `GET /api/periods/{id}/deck-text` | every active person (employees need it for the live preview) | `{settings, inherited_from, updated_at}`. `settings` has every key of `deck_text_defaults.json`. A period without its own words inherits the latest earlier period's (`inherited_from` is its label, such as "Feb to Apr 2026"), else the built-in defaults (`"defaults"`). `inherited_from` and `updated_at` are null when the period has its own. 404 for an unknown period. |
| `PUT /api/periods/{id}/deck-text` | manager | `{settings:{...}}`. Missing keys take the defaults, unknown keys are 400, values are trimmed. Per key: empty only where allowed, at most N characters, only the allowed `{placeholders}`, no control or invisible characters (line breaks only in `suggestionsBody`). Returns the same shape with `inherited_from` null. Editing never changes an existing deck. |
| `POST /api/events/ticket` | manager | `{ticket}`, 60 seconds, single use. |
| `GET /api/events?ticket=...&period_id=...` | manager (checked again when the ticket is used) | Server-Sent Events: `data: {"kind":"reports"|"deck","period_id":"..."}`, heartbeat `: ping` every 20 seconds. |

Roles: `contributor` (employee) and manager. The role value in JSON and in the database enum is still `controller`; every message says manager. A refused manager-only call answers 403 `{"error":"Only the manager can do this."}`. The role is read from the database on every request, so the UI split is not the security boundary; this table is.

## Sign in without an email

People may sign in without a real email address. An employee gets an internal address such as `name@xynotransit.internal` that never receives mail, and a manager gives them a one-time sign-in link instead (People screen, or the server command below).

- **Internal addresses.** `POST /api/auth/magic-link` answers an internal address exactly like any other: 202 `{}`, the same rate limit keyed by the email string. It never tries to send mail (no SMTP error), and logs the link only when `LOG_MAGIC_LINKS` is on. The address is still validated like any other.
- **Sign-in links.** `POST /api/persons/{id}/sign-in-link` (above). Same kind of token as a magic link: 32 random bytes, only the SHA-256 in `login_token`, used once by `/api/auth/verify`, only longer lived (1 to 168 hours). `sign_in_link_audit(id, person_id, issued_by, issued_at, expires_at)` records each one; `issued_by` is null when the server command made it. `login_token` itself is unchanged.
- **Server command**, for the first manager (no mail needed) or when no manager can sign in:

```bash
docker compose exec api xynotransit-api sign-in-link manager@xynotransit.internal --hours 24
```

  It reads `DATABASE_URL` and `PUBLIC_URL` from the environment, needs an ACTIVE person with that email, and prints only the URL on stdout. Exit 0 on success, 1 when no link could be made (unknown or switched off person, database not reachable; the message is on stderr), 2 for wrong usage (`--hours` outside 1 to 168, missing email). Create the first manager with `BOOTSTRAP_CONTROLLER_EMAIL=manager@xynotransit.internal`, then run the command.
- **Generated addresses.** Lowercase ASCII letters, digits and dots made from the full name: accents are folded (`é` to `e`, `ü` to `u`, `ß` to `ss`), apostrophes, hyphens and other characters are dropped, spaces and dots become single dots, at most 40 characters before the `@`. A name that leaves nothing (for example only CJK letters) gives `user`. On a clash a number is appended: `rosa.rakoto`, `rosa.rakoto2`, `rosa.rakoto3`. The code is `signin::internal_local_part` (pure, table tests in `src/signin.rs`).

## Passwords

Passwords sit next to the sign-in links; links stay the way to get started and to recover.

- **Username.** Lowercase letters, digits, `.`, `-`, `_`; 3 to 40 characters; unique ignoring case; stored lowercase. `person.username` is never null: the migration backfilled it for existing people, a trigger fills it for any insert that has none, and `POST /api/persons` chooses one itself. Pure rules and generation: `src/username.rs`.
- **Normalisation.** Every password is turned into Unicode NFKC before the policy, the length count and hashing, so the same typed password works whether a device sends an accented letter as one character or as letter plus accent. A session also ends when a person is switched off (the epoch goes up), so switching them on again does not revive old tokens.
- **Hashing.** Argon2id (`argon2` crate), PHC string in `person.password_hash`. Production parameters are the OWASP minimum m=19456 KiB, t=2, p=1. The target machine has 1 GB of RAM, so hashing runs in `spawn_blocking` behind a semaphore of 2 permits; a request that cannot get a place within 5 seconds answers 503 "Busy, try again in a moment." (and the try is not counted against the user). A good sign-in with an older hash stores a new one. A password is never logged, never in an error, never in `password_audit`. Code: `src/hashing.rs`.
- **Policy** (`src/password.rs`, NIST style, no composition rules). 10 to 128 characters counted in Unicode scalar values; spaces are allowed and kept exactly as typed (nothing is trimmed). In this order, the first failure gives its message: control characters ("Use letters, numbers, spaces and symbols only."), "Use at least 10 characters.", "Use at most 128 characters.", the same as the username, the email, the part of the email before the `@` or the full name, ignoring case ("Do not use your username, email address or name as a password."), one repeated character ("Do not repeat one character."), a simple run such as `1234567890` or `abcdefghij` ("Do not use a simple run such as 1234567890 or abcdefghij."), a common password ("That password is too common. Pick something only you would think of."). The common list is embedded (`src/common_passwords.txt`, 500+ entries of 10 characters or more, compared lowercase). The limits and every message are also in `tests/fixtures/rules.json` under `passwords`, which a test keeps equal to the code.
- **Sessions.** The JWT carries `ep`, the person's `session_epoch` when it was made (tokens from before this existed count as 0). Every request reads the person; a different epoch is 401 "Please sign in again." A password change, reset or removal adds 1, so all older sessions end at once; links and passwords make tokens of the same kind. A switched off person stays 401.
- **Choose a new password first.** While `must_change_password` is true (after a manager reset) EVERY authenticated route answers 403 `{"error":"Choose a new password first."}` except `GET /api/me`, `POST /api/auth/password` and signing out (the app just drops its token; there is no server call). Implemented as the `AuthUser` extractor itself; only `SessionUser` skips the check.
- **Rate limits** (rows of `login_failure`, windows of 15 minutes). 5 failures for one username key (what was typed, trimmed and lowercased, whether or not it exists) lock that name; 30 failures from one client address lock the address. 429 "Too many sign-in attempts. Try again later." with `Retry-After` = seconds until the failure that holds the last place leaves the window. While locked even the right password is refused and refused tries are not counted. A try is written down before the password is checked (under advisory locks) and removed when it was right or never a real guess (a 503), so parallel guesses cannot slip past. A success clears that name's rows only. A wrong `current_password` in `POST /api/auth/password` is a failure of that username. Old rows are removed by `xt_purge_expired()` and by the next try of the same name.
- **Client address.** The API sits behind nginx and Caddy. The address is the socket peer, unless the peer is a private network address (10/8, 172.16/12, 192.168/16, 100.64/10, loopback, link-local, IPv6 fc00::/7 and fe80::/10): then `X-Forwarded-For` is read from the right, our own private hops are skipped and the right-most address that is not private is the client. A public peer is the client itself and the header is ignored. An unusable header falls back to the peer. IPv6 clients count per /64. Code and table tests: `src/loginlimit.rs`.
- **Retention.** `login_failure.username_key` holds what was typed in the username box (up to 64 characters), which can by mistake be a password. Rows leave after the 15 minute window (purged by `xt_purge_expired()` and by the next try of the same name); do not copy that table into logs or exports.
- **Audit.** `password_audit(person_id, issued_by, kind, at)` with kind `change` (the person), `reset` and `remove` (a manager, `issued_by`) or `cli` (the server command, no issuer). No password or hash.
- **Server command**, to set a password without the app (first manager, or a locked out manager):

```bash
docker compose exec -it api xynotransit-api set-password manager
```

  The argument is a username or an email of an ACTIVE person. From a terminal it asks twice without echo; otherwise (pipes, scripts) it reads one line of standard input, e.g. `printf '%s\n' "$PW" | docker compose exec -T api xynotransit-api set-password manager` (that leaves the password in your shell history, so prefer the prompt). The same policy applies, the person is not asked to change it, older sessions end, audit kind `cli`. It prints only `Password set for <username>.` on stdout; problems go to stderr in plain words. Exit 0 on success, 1 when it could not be set (unknown or switched off person, a password that breaks the policy, the two typed passwords differ, database not reachable), 2 for wrong usage.

## How it works

- **Magic link:** a random 32 byte token; only its SHA-256 is stored in `login_token` (15 minute expiry, `used_at`). Verify is one atomic update, so only one use succeeds. The rate limit counts rows in `login_attempt` (keyed by the normalised email string, written for unknown addresses too) under a per email advisory lock. Mail is sent in a background task so response time does not reveal whether an address exists.
- **Auth:** the JWT (sub = person_id, 7 days) only proves who. Role and active flag are read from the database on every request.
- **Catalog:** managers build it through the admin endpoints. Counts keep their `series` (0 to 7) as list order; a reorder first parks rows at 1000 and up because of the partial unique index on `(assignment_id, series)`. Notes are free text only: the `note_suggestion` table is kept but no longer read.
- **Reports:** PUT runs in one transaction: authorise (own seat or manager), validate, upsert as draft, replace values, KPI results and notes, call `submit_report`.
- **Deck texts:** keys, defaults, placeholders and limits live in `deck_text_defaults.json` (copies in `src/` and `tests/fixtures/`, a test checks they match the app copy in `xynotransit_app/docs/reference/`). Texts are stored per period and frozen into each deck run. `coverPill` is `{team} · {count} {reports}` by default (`{reports}` is "report" or "reports"); decks and periods that already stored their words keep them.
- **Decks:** snapshots are built on the server from submitted reports. Name and role come from the report's reporter words, and the snapshot field `team` carries the reporter's country (legacy reports without reporter words use the catalog profile). The app groups slides by country (case-insensitive, whitespace collapsed, first spelling shown, first appearance order); `snapshot::country_key` is the reference. The dashboard summary still groups by catalog teams (assumption). `tests/fixtures/snapshot_case.json` is the shared contract proven by the Rust and Dart tests. Old decks stay frozen when a report is sent again.
- **Live updates:** triggers in `02-api.sql` send `NOTIFY xt_changes` with `{kind, period_id}`. One `PgListener` task (reconnects with backoff) fans out through a broadcast channel to SSE clients. Responses carry `X-Accel-Buffering: no`.
- **Single source of rules:** every limit and fixed message lives in `src/rules.rs` (constants and `rules::msg`). `tests/fixtures/rules.json` repeats them for the other side (the Flutter tests read `../xynotransit-api/tests/fixtures/rules.json`); `rules_json_matches_code` fails when the two drift apart. Add keys, never rename one. Deck text limits stay in `deck_text_defaults.json`.
- **Request id:** every response has `X-Request-Id` (a short plain id sent by the caller is kept, else a new one) and every log line of that request carries it. One log line per request: method, path (never the query, which holds event tickets), status, milliseconds. Bodies, tokens, emails and magic links are never logged; links appear only when `LOG_MAGIC_LINKS=true` (dev). Health checks log at debug.
- **Headers on every answer:** `X-Content-Type-Options: nosniff`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'`, `Cross-Origin-Resource-Policy: same-origin`. A panic in a handler becomes a plain 500 and is logged.
- **Limits:** body 256 KB (413), request 30 s until the answer starts (408; open event streams are not cut), database statements 20 s, a transaction idle for more than 30 s is ended by the database, 10 pooled connections. No CORS layer (same origin through nginx).
- **Shutdown:** on SIGTERM or Ctrl-C the server stops taking connections, ends the event streams at once, lets requests that are running finish (up to `SHUTDOWN_GRACE_SECS`), then exits. `tests/ops.rs` proves it with a request held by a table lock.
- **Deck content:** a slide shows the counts and targets the report was answered against, also when the manager changed or retired them since (the deck reads the definitions that the report has answers for). If a retired count and a renumbered live count share a series number, the slide renumbers them so no two bars share a colour.
- **Who is expected:** a seat is expected in a period when the seat and its person are both switched on (summary `expected`, deck `expected_count`, the views). Reports of a switched-off seat or person stay: they are not counted in `submitted` (so it never exceeds `expected`), they are listed apart (`submitted_inactive`, `people[].active=false`), their numbers still add into counts and volume, `GET /periods/{id}/reports` returns them, and a deck includes them (`included_count`, `switched_off_count`).
- **Too many requests:** every 429 carries `Retry-After` (whole seconds until the hourly window frees a place, 1 to 3600). The sign-in screen reads it.
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
| `tests/data_review.rs` | edge cases: fresh install, empty period, years 2000 and 2100, team without seats, a person with two seats in one team, a seat or person switched off after reporting (never counted above expected, still listed and in the deck), deck faithfulness after definition edits |
| `tests/passwords.rs` | sign in and its identical failures, timing of known against unknown names (production parameters), the username and address limits and their `Retry-After`, parallel guesses, change, reset and remove with epochs, the 403 gate on many routes, usernames in the people API, 503 when busy, rehash, no password in logs, audit or errors, the migration backfill on realistic data (run twice, SQL and Rust agree), the `set-password` command as a real binary |
| `tests/internal_signin.rs` | people without email, generated addresses, sign-in links (single use, expiry, roles, 404/409/429, audit without tokens), internal addresses get no mail and the same rate limit, the `sign-in-link` command run as a real binary (output, exit codes), the migration run twice |
| `tests/perf.rs` | 300 seats x 24 periods x 8 counts: every call must answer in under 300 ms (release; debug has 1500 ms) |

`cargo test --release --test perf -- --nocapture` prints the timings. The migration and backup scripts have their own tests in `../xynotransit-db/scripts` (`test-migrations.sh`, `test-backup.sh`).

Integration tests need Postgres. Each test creates a throwaway database and drops it afterwards. The default admin URL is `postgres://xynotransit:xynotransit@127.0.0.1:5432/postgres`; override it with `TEST_ADMIN_URL`. Start the db first: `docker compose up -d db` in `../xynotransit-db`. `TEST_TEMPLATE_DB=<database>` builds each test database from a copy of that database (emptied) instead of the initdb files; `test-migrations.sh` uses it to run the whole suite on a migrated copy of the live data.

## Layout

```
src/main.rs        start, logging, config, bootstrap manager, signals
src/http.rs        request id and logging, JSON errors for every status, security headers, panic to JSON
src/config.rs      env settings
src/auth.rs        JWT, current user loading
src/signin.rs      internal addresses, generated addresses, sign-in links, the sign-in-link command
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

The words of the slides are stored per period and frozen into each deck. Only a manager can call these endpoints (403 "Only the manager can do this.").

- Keys, defaults, allowed placeholders and limits come from `src/deck_text_defaults.json`, a copy of `../xynotransit_app/docs/reference/deck_text_defaults.json` (also kept as `tests/fixtures/deck_text_defaults.json`). A unit test asserts the copies are byte-identical; it is skipped with a message when the Flutter project is not next to this one.
- Messages match the app's: "<Label> cannot be empty.", "<Label> can be at most N characters.", "{x} cannot be used in <Label>. It allows {a}, {b}." (or "It allows no placeholders."), plus "Use plain text in <Label>." for control or invisible characters, "<key> is not a text setting." for unknown keys and "<Label> must be text." for non-strings.
- Effective words of a period: its own row in `deck_text`, else the latest earlier period's (by start month), else the defaults, always completed with defaults for missing keys.
- `POST /api/periods/{id}/deck` copies the effective words into `deck_run.texts` in the same transaction. `GET` deck returns them as `texts`; an old row with `{}` reads as the defaults.
- Tables: `deck_text(period_id, settings, updated_at, updated_by)` and the column `deck_run.texts`, from `xynotransit-db/initdb/04-deck-text.sql`.
- Tests: unit tests in `src/deck_text.rs`, integration tests in `tests/deck_text.rs`.
