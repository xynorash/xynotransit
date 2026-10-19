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
| `POST /api/auth/password` | signed in (also while a new password is required) | `{current_password?, new_password}`. A person who has a password must send `current_password` unless the session began at most 15 minutes ago with a sign-in link that allows recovery (see "Recovery by link"); the rule: (400 "Enter your current password." when missing, 403 "Your current password is not right." when wrong; a wrong one is counted per pair, per address and per person, apart from sign-in failures: after 10 wrong ones in 15 minutes from any addresses it answers 429 "Too many password attempts. Try again later." with `Retry-After`, and the 10th ends all the person's sessions, answering 401 "You were signed out for safety after too many wrong passwords. Sign in again."; see "Rate limits"); a person who has none (first password after a link) does not. The new password must pass the policy (400 with the plain message) and differ from the current one. Sets `must_change_password` to false, adds 1 to `session_epoch` and answers 200 `{access_token, expires_at}`: a fresh session; every older session of the person stops working. Audit kind `change` (`change-via-link` for the recovery). The new token has `via` `password`. A link session without recovery (`via` `link-plain`) must give the current password like any other session; a person who has no password needs none whatever the link. |
| `GET /api/me` | signed in (also while a new password is required) | `{person_id, role, label, username, has_password, must_change_password, recent_link_session}`. `recent_link_session` is true for a person who has a password and whose session began at most 15 minutes ago with a sign-in link that allows recovery (`via` `link`, never `link-plain`): the change-password form may leave out the current password. |
| `GET /api/catalog` | signed in | Teams, persons, assignments with metrics and KPIs. Every person and assignment has `active`. A contributor sees ONLY themselves: their own person, their own active seats and the teams of those seats (no other name, role or team), with active rows only. A manager can add `?include_inactive=true` to get inactive persons and seats too. Retired counts and targets are never listed. |
| `POST /api/teams` | manager | `{name}` (1 to 60). Returns 201 `{id, code, name, sort}`; the code is a slug of the name, sort is last plus one. 409 when the name is used. |
| `PATCH /api/teams/{id}` | manager | `{name?, sort?}`. |
| `DELETE /api/teams/{id}` | manager | 204. 409 "Move or remove the seats of this team first." while any seat (active or not) is in it. |
| `POST /api/persons` | manager | `{full_name, email?, app_role, username?}`. Email is trimmed and lowercased, 409 when used. When `email` is missing, null or blank the server makes a unique internal address from the name (`rosa.rakoto@xynotransit.internal`, then `rosa.rakoto2@...`). An address typed at an internal domain is kept as typed. `username` is optional: valid (lowercased) or 400 "Usernames use letters, digits, dots, dashes and underscores, 3 to 40 characters.", taken 409 "That username is already used."; without it the server uses the part of the email before the `@` (cleaned, numbered on conflict: `rosa.rakoto`, `rosa.rakoto2`). 201 with the person, including the address, `username` and `has_password`. |
| `POST /api/persons/{id}/sign-in-link` | manager | `{hours?, recovery?}` (`hours`: a whole number from 1 to 168, default 24; send `{}` for the defaults; `recovery`: true or false, default false, 400 "Recovery must be true or false." for anything else). 201 `{url, expires_at, person_id, recovery}`: `recovery` is true only when asked for AND the person has a password (otherwise false: someone without a password needs no recovery); with it the person may choose a new password without the old one (see "Recovery by link"). `url`: `url` is `{PUBLIC_URL}/auth/verify?token=...`, `expires_at` is RFC 3339 UTC (`2026-10-20T08:30:00Z`). The link is single use and goes through `POST /api/auth/verify` like a magic link. 400 "Choose a validity from 1 hour to 168 hours.", 404 unknown person, 409 "This person is switched off.", 429 "Too many sign-in links created. Try again later." after 30 links per issuing manager per hour. Making another link does not cancel an earlier one. Every link adds a row to `sign_in_link_audit` (never the token). |
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
| `POST /api/events/ticket` | manager | `{ticket}`, 60 seconds, single use. The ticket remembers the person's `session_epoch` at issue. |
| `GET /api/events?ticket=...&period_id=...` | manager (checked again when the ticket is used, and every 30 seconds while the stream is open) | Server-Sent Events: `data: {"kind":"reports"|"deck","period_id":"..."}`, heartbeat `: ping` every 20 seconds. 401 "Please sign in." when the ticket is unknown, used, older than 60 seconds, or made under an older `session_epoch` (a password change, reset, removal or switch-off since), or when the person is switched off or must choose a new password. The stream ends by itself within 30 seconds when the person's epoch changed, they were switched off, must choose a new password, or are no longer a manager (see "Event tickets"). |

Roles: `contributor` (employee) and manager. The role value in JSON and in the database enum is still `controller`; every message says manager. A refused manager-only call answers 403 `{"error":"Only the manager can do this."}`. The role is read from the database on every request, so the UI split is not the security boundary; this table is.

## Sign in without an email

People may sign in without a real email address. An employee gets an internal address such as `name@xynotransit.internal` that never receives mail, and a manager gives them a one-time sign-in link instead (People screen, or the server command below).

- **Internal addresses.** `POST /api/auth/magic-link` answers an internal address exactly like any other: 202 `{}`, the same rate limit keyed by the email string. It never tries to send mail (no SMTP error), and logs the link only when `LOG_MAGIC_LINKS` is on. The address is still validated like any other.
- **Sign-in links.** `POST /api/persons/{id}/sign-in-link` (above). Same kind of token as a magic link: 32 random bytes, only the SHA-256 in `login_token`, used once by `/api/auth/verify`, only longer lived (1 to 168 hours). `sign_in_link_audit(id, person_id, issued_by, issued_at, expires_at, origin, recovery)` records each one; `issued_by` is null when the server command made it. `login_token` has two more columns, see the table below.

  | Link | `login_token.origin` | `allow_recovery` | Session `via` |
  | --- | --- | --- | --- |
  | Asked for on the sign-in page (mailed) | `email` | true (it proves control of the mailbox) | `link` |
  | Made by a manager | `admin` | false, true only with `"recovery": true` for a person who has a password | `link-plain` or `link` |
  | Made by the server command | `cli` | false, true only with `--recovery` for a person who has a password | `link-plain` or `link` |

  Migration `14-link-origin.sql` added the columns; old rows that match an audit row became `admin` (issuer known) or `cli`, all others `email`.
- **Server command**, for the first manager (no mail needed) or when no manager can sign in:

```bash
docker compose exec api xynotransit-api sign-in-link manager@xynotransit.internal --hours 24 [--recovery]
```

  It reads `DATABASE_URL` and `PUBLIC_URL` from the environment, needs an ACTIVE person with that email, and prints only the URL on stdout. Exit 0 on success, 1 when no link could be made (unknown or switched off person, database not reachable; the message is on stderr), 2 for wrong usage (`--hours` outside 1 to 168, missing email, unknown option). `--recovery` makes a recovery link for a person who has a password (they may choose a new password without the old one); for anyone else it changes nothing. Use it only when you are sure whom the link goes to: whoever opens it gets lasting control of the account. Create the first manager with `BOOTSTRAP_CONTROLLER_EMAIL=manager@xynotransit.internal`, then run the command.
- **Generated addresses.** Lowercase ASCII letters, digits and dots made from the full name: accents are folded (`é` to `e`, `ü` to `u`, `ß` to `ss`), apostrophes, hyphens and other characters are dropped, spaces and dots become single dots, at most 40 characters before the `@`. A name that leaves nothing (for example only CJK letters) gives `user`. On a clash a number is appended: `rosa.rakoto`, `rosa.rakoto2`, `rosa.rakoto3`. The code is `signin::internal_local_part` (pure, table tests in `src/signin.rs`).

## Passwords

Passwords sit next to the sign-in links; links stay the way to get started and to recover.

- **Username.** Lowercase letters, digits, `.`, `-`, `_`; 3 to 40 characters; unique ignoring case; stored lowercase. `person.username` is never null: the migration backfilled it for existing people, a trigger fills it for any insert that has none, and `POST /api/persons` chooses one itself. Pure rules and generation: `src/username.rs`.
- **Normalisation.** Every password is turned into Unicode NFKC before the policy, the length count and hashing, so the same typed password works whether a device sends an accented letter as one character or as letter plus accent. A session also ends when a person is switched off (the epoch goes up), so switching them on again does not revive old tokens.
- **Hashing.** Argon2id (`argon2` crate), PHC string in `person.password_hash`. Production parameters are the OWASP minimum m=19456 KiB, t=2, p=1. The target machine has 1 GB of RAM, so hashing runs in `spawn_blocking` behind a semaphore of 2 permits; a request that cannot get a place within 5 seconds answers 503 "Busy, try again in a moment." (and the try is not counted against the user). A good sign-in with an older hash stores a new one. A password is never logged, never in an error, never in `password_audit`. Code: `src/hashing.rs`.
- **Policy** (`src/password.rs`, NIST style, no composition rules). 10 to 128 characters counted in Unicode scalar values; spaces are allowed and kept exactly as typed (nothing is trimmed). In this order, the first failure gives its message: control characters ("Use letters, numbers, spaces and symbols only."), "Use at least 10 characters.", "Use at most 128 characters.", the same as the username, the email, the part of the email before the `@` or the full name, ignoring case ("Do not use your username, email address or name as a password."), one repeated character ("Do not repeat one character."), a simple run such as `1234567890` or `abcdefghij` ("Do not use a simple run such as 1234567890 or abcdefghij."), a common password ("That password is too common. Pick something only you would think of."). The common list is embedded (`src/common_passwords.txt`, 500+ entries of 10 characters or more, compared lowercase). The limits and every message are also in `tests/fixtures/rules.json` under `passwords`, which a test keeps equal to the code.
- **Sessions.** The JWT carries `ep`, the person's `session_epoch` when it was made (tokens from before this existed count as 0). Every request reads the person; a different epoch is 401 "Please sign in again." A password change, reset or removal adds 1, so all older sessions end at once; links and passwords make tokens of the same kind. A switched off person stays 401. The JWT also carries `via`, `link` (opened a sign-in link) or `password` (signed in with a password, or a token from before the claim existed), and the usual `iat`; see "Recovery by link".
- **Choose a new password first.** While `must_change_password` is true (after a manager reset) EVERY authenticated route answers 403 `{"error":"Choose a new password first."}` except `GET /api/me`, `POST /api/auth/password` and signing out (the app just drops its token; there is no server call). Implemented as the `AuthUser` extractor itself; only `SessionUser` skips the check.
- **Rate limits** (rows of `login_failure`, windows of 15 minutes). All answer 429 "Too many sign-in attempts. Try again later." with `Retry-After` = seconds until the failure that holds the last place leaves the window (the longest wait when several limits apply). While locked even the right password is refused and refused tries are not counted. A try is written down before the password is checked (under advisory locks per address and per username) and removed when it was right or never a real guess (a 503), so parallel guesses cannot slip past.

| Limit | Counts | Locks | Applies to |
| --- | --- | --- | --- |
| Pair | 5 failures per (username, client address) per 15 minutes | that pair only: the same name from other addresses, other names from this address stay open | every sign-in (a wrong `current_password` is counted apart, see "Change limit") |
| Backstop | 100 failures per username from all addresses per 15 minutes | the name, for everybody EXCEPT addresses that signed in successfully for that name (password or link) within the last 30 days (`login_success`) | sign-ins only |
| Address | 30 failures per client address per 15 minutes | that address, for every name | only a determinable public address (see "Client address") |

  The username key is what was typed, trimmed and lowercased, whether or not the name exists, so an unknown name behaves exactly like a known one (same statuses, bodies, `Retry-After` and work). A correct password from an address with no failures always passes, unless the backstop applies and the address is not trusted. A success (password or link) clears that PAIR's failures and remembers the address for the name for 30 days (one `login_success` row per pair, refreshed on each success); an unknown address is never remembered. A success of a password change clears that person's change failures for the pair but does not make the address trusted. Old rows are removed by `xt_purge_expired()` (failures after a day, trusted addresses after 30 days) and by the next try of the same name. The numbers are in `tests/fixtures/rules.json` (`passwords.limits`).
- **Change limit.** A wrong `current_password` in `POST /api/auth/password` is counted in `login_failure` under keys of its own (HMAC domains `change-person` and `change-address`), so it never counts toward a sign-in lock and sign-in failures never block a signed-in person's change. Per pair (person, address) 5 and per address 30 as above, and across ALL addresses 10 per person per 15 minutes: the 11th try is 429 "Too many password attempts. Try again later." with `Retry-After`, even with the right password. The 10th wrong one ends the person's sessions (`session_epoch` plus 1, audit kind `change-lock`, answer 401 "You were signed out for safety after too many wrong passwords. Sign in again."), so a thief holding a token cannot guess on; the real person signs in again with the password, a link or the command and is held back from changing the password until the window passes. Tries are written down before the check, so parallel guesses never allow an 11th check. Numbers: `passwords.limits.change_failures_per_person` and `change_failures_window_minutes` in `rules.json`.
- **Client address.** Only a PUBLIC address is a client address. The API sits behind Caddy (TLS, the only public entry) and nginx (the `web` container). If the socket peer is public it is the client and `X-Forwarded-For` is ignored. If the peer is a private network address (10/8, 172.16/12, 192.168/16, 100.64/10, loopback, link-local, IPv6 fc00::/7 and fe80::/10, also as IPv4-mapped IPv6), `X-Forwarded-For` (all its lines joined) is read from the right: private hops are our own proxies and are skipped, and the right-most hop that is not private is the client. Hops further left are whatever the caller wrote and are never read. IPv6 clients count per /64, IPv4-mapped IPv6 as the IPv4 address. When no public hop is found (everything private: a client on the same LAN, Docker NAT, IPv6 through docker-proxy), the header is empty or garbage on the right, or there is no socket, the address is UNKNOWN: the per-address limit is skipped (the API logs `client address unknown, per-address limit skipped` at warn, at most once a minute), the pair uses the constant address `unknown`, and no address is remembered as trusted. So five wrong tries for a name from unknown addresses lock that name for all unknown addresses, and nothing else. Code and table tests: `src/loginlimit.rs`.

  **Caddy must be the only public entry.** The production compose publishes only Caddy; `web` and `api` have no `ports:`. The chain, and what each hop sends:

  ```
  browser (203.0.113.9) -> Caddy -> nginx (web) -> api
  Caddy:  reverse_proxy replaces any X-Forwarded-For the browser sent with the browser's address:  X-Forwarded-For: 203.0.113.9
  nginx:  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;   -> 203.0.113.9, 172.18.0.5   (Caddy's address appended)
  api:    peer 172.18.0.4 (nginx, private) -> skip 172.18.0.5 (Caddy, private) -> client 203.0.113.9
  ```

  Caddy's `reverse_proxy` does not trust incoming `X-Forwarded-*` headers unless `trusted_proxies` is set, so do not set it unless Caddy sits behind another proxy you trust (then that proxy's address is private and still skipped, and its own client address is the one that counts). With nginx alone in front (no Caddy) use `proxy_set_header X-Forwarded-For $remote_addr;` so a browser cannot add hops, or keep `$proxy_add_x_forwarded_for`: a made-up hop sits left of the real one and is never read. If the API or nginx is ever reachable directly from the internet, the peer is public, is used as the client and the header is ignored, which is safe too. What is NOT safe is a public proxy that is not on a private address; do not put one in front.
- **Retention.** `login_failure` and `login_success` keep no readable names or addresses (people type their password in the username box). Both columns hold HMAC-SHA256 as 64 hex characters (`username_key`, `address_key`), made with a key derived from `JWT_SECRET` by HKDF-SHA256 with the label `xt-ratelimit-v1` and a separate prefix for names and addresses; the database refuses anything else. Changing `JWT_SECRET` therefore also resets the counters and the trusted addresses (everybody is signed out then anyway). Failures leave after the 15 minute window (purged by `xt_purge_expired()` and by the next try of the same name), trusted addresses after 30 days. Migration `xynotransit-db/initdb/13-hashed-keys.sql` emptied the old readable rows.
- **Recovery by link.** A person who HAS a password and forgot it signs in with a sign-in link that allows recovery and chooses a new password without the old one. Which links allow it: the ones asked for on the sign-in page (they prove control of the mailbox), and a manager's or the server command's only when made with `recovery` (a link handed over in a chat may leak, and then it would give lasting control; for a forgotten password the manager can also use Reset password). The JWT has the claim `via`: `link` after `POST /api/auth/verify` of a link with `allow_recovery`, `link-plain` after any other link (no bypass: it needs the current password like a password session, and a wrong one counts as a change failure), `password` after `POST /api/auth/login` and after a password change (tokens without the claim count as `password`). `POST /api/auth/password` does not need `current_password` when the person has a password AND `via` is `link` (not `link-plain`) AND the token's `iat` is at most 15 minutes old; `GET /api/me` says so with `recent_link_session: true`. Any other session still needs the current password. In that case a `current_password` that is sent is neither looked at nor counted (so a stolen link session cannot be used to test guesses), the "same as the current password" check is skipped, the new password must still pass the policy, and the audit kind is `change-via-link`. The change ends every older session, the link session included, and returns a `password` session. 15 minutes is `rules::LINK_RECOVERY_MINUTES` (`passwords.limits.link_recovery_minutes`).
- **Event tickets.** `POST /api/events/ticket` stores the person's `session_epoch`. `GET /api/events` redeems the ticket (single use, 60 seconds) and refuses it with 401 when the epoch is not the current one, the person is switched off, or must choose a new password; it is 403 when the person is no longer a manager. An open stream looks the person up again every 30 seconds (`state::STREAM_RECHECK_SECS`) and ends when the epoch changed, the person was switched off, must choose a new password or is no longer a manager. So after a password change, reset, removal, switch-off or demotion nothing that was made before keeps listening for longer than 30 seconds. A failed look-up (database trouble) keeps the stream and tries again at the next tick.
- **Audit.** `password_audit(person_id, issued_by, kind, at)` with kind `change` (the person), `change-via-link` (the person, with a fresh recovery link session and no current password), `change-lock` (sessions ended after 10 wrong current passwords; no issuer), `reset` and `remove` (a manager, `issued_by`) or `cli` (the server command, no issuer). No password or hash.
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
| `tests/passwords.rs` | sign in and its identical failures, timing of known against unknown names (production parameters), the pair, backstop and address limits and their `Retry-After`, trusted addresses, unknown addresses, hashed keys, parallel guesses, change, reset and remove with epochs, the 403 gate on many routes, usernames in the people API, 503 when busy, rehash, no password in logs, audit or errors, the migration backfill on realistic data (run twice, SQL and Rust agree), the `set-password` command as a real binary |
| `tests/recovery.rs` | event tickets made before a password change, reset, removal or switch-off open nothing, an open stream ends after a reset (checked every 150 ms in the test), recovery by link (15 minute edge, legacy tokens, policy, no oracle, audit kind) |
| `tests/change_cap.rs` | the per-person cap on wrong current passwords: 10 addresses, dead token, sign-in still works, outsiders' login failures do not block, change failures do not lock sign-in, `Retry-After`, parallel guesses, hashed keys |
| `tests/link_origin.rs` | link origin and recovery: manager and server links with and without it, email links, first password after any link, `link-plain`, `/api/me`, audit rows, wrong types |
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
