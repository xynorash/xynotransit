# xynotransit-db

The database and the local Docker stack for the Xynotransit Logistics Report Builder. Project name is `xynotransit-db`, so the database container is `xynotransit-db-db-1`.

## Services (docker-compose.yml)

| Service | What | Port |
| --- | --- | --- |
| `db` | Postgres 18 on Arch Linux (`Dockerfile`, `entrypoint.sh`). Database, user and password `xynotransit`. | 127.0.0.1:5432 |
| `api` | The axum backend, built from `../xynotransit-api`. | internal 8081 |
| `mailpit` | Catches dev mail. Open the UI to read magic links. | 127.0.0.1:8025 (SMTP 1025 internal) |
| `web` | nginx serving `../xynotransit_app/build/web`, proxying `/api/` to `api:8081`. | 127.0.0.1:8080 |

## Quick start

```bash
cd ../xynotransit_app
flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=/api   # build/web must exist first

cd ../xynotransit-db
cp .env.example .env     # first time; set BOOTSTRAP_CONTROLLER_EMAIL
./scripts/up.sh          # docker compose up -d --build
```

Open http://127.0.0.1:8080 and sign in with the manager email (`BOOTSTRAP_CONTROLLER_EMAIL`, role value `controller`). Read the link in Mailpit at http://127.0.0.1:8025. A manager lands on the dashboard (`/manager`); anyone else a manager has added lands on their own report form (`/report`) and cannot see slides, the reports table or exports. The API enforces this: the list of reports, the deck and live events are controller only.

Scripts (also `make up|down|reset|logs`):

- `scripts/up.sh` builds and starts everything.
- `scripts/down.sh` stops it, keeps data.
- `scripts/reset.sh` stops it and deletes the database volume, then starts again. initdb runs again.
- `scripts/logs.sh` follows the logs.
- `scripts/migrate.sh [database]` brings a database that lives on up to date (see "Init SQL").
- `scripts/backup.sh`, `scripts/restore.sh` (see "Backup and restore").
- `scripts/test-migrations.sh`, `scripts/test-backup.sh` print PASS or FAIL (see "Tests of the database").
- `scripts/smoke.sh [base_url] [mailpit_url]` is an end to end check of a RUNNING stack (links, a catalog, a report, a deck, and the password flow: manager reset, temporary password, "Choose a new password first.", change, old token refused, removal). Repeatable and self-cleaning: it deactivates and deletes what it made, including the sign-in limit rows created during the run (`SMOKE_PURGE=0` skips the database part). CI runs it against the full Docker stack.
- `scripts/seed-perf.sql` fills a scratch database with 300 seats x 24 periods x 8 counts for timing.
- `scripts/lib.sh` is shared by the scripts above. They run `psql`, `pg_dump` and `pg_restore` inside the database container (`DB_CONTAINER`, default `xynotransit-db-db-1`), so the host needs only Docker. `XT_HOST_TOOLS=1` uses the tools on the host instead (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`).

## Environment (.env)

`.env` is git ignored; `.env.example` holds the dev values.

| Variable | Default | Meaning |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | `xynotransit` | Database password, also used in the API URL. |
| `JWT_SECRET` | dev value | At least 32 characters. Change it outside dev. |
| `PUBLIC_URL` | `http://127.0.0.1:8080` | Origin used in magic links. |
| `MAIL_FROM` | `Xynotransit <no-reply@xynotransit.local>` | Sender. |
| `BOOTSTRAP_CONTROLLER_EMAIL` | empty | This person is created (or promoted and activated) as manager (role value `controller`) at API start. |
| `BOOTSTRAP_CONTROLLER_NAME` | empty | Name used when that person is created. Default: the part of the email before the `@`, capitalised. |
| `INTERNAL_EMAIL_DOMAINS` | `xynotransit.internal` | Comma separated. Addresses at these domains never receive mail; people sign in with a one-time link from a manager. Read by the API; the compose files do not pass it on yet, so the default applies until the line `INTERNAL_EMAIL_DOMAINS: ${INTERNAL_EMAIL_DOMAINS:-}` is added to the `api` environment. |
| `LOG_MAGIC_LINKS` | `true` | Log links. Dev only. |
| `RUST_LOG` | `info` | Log level. |
| `LOG_FORMAT` | text | `json` for one JSON object per log line. |
| `SHUTDOWN_GRACE_SECS` | `8` | Seconds that running requests get to finish after SIGTERM (the compose file gives the api `stop_grace_period: 15s`). |

The API variables `SMTP_HOST` (`mailpit`), `SMTP_PORT` (`1025`), plain SMTP and `BIND` (`0.0.0.0:8081`) are fixed in the dev compose file; `docker-compose.prod.yml` makes them settable. See `../xynotransit-api/README.md` for all of them.

## Init SQL (initdb/) and migrations

**Order.** `entrypoint.sh` runs every `/initdb/*.sql` in name order, but only on the first start of an empty volume. The API test suite builds its databases the same way (all files, name order), and `scripts/migrate.sh` follows the same order for a database that lives on. Name a new file with the next number (`11-...sql`); never edit a file that has been applied somewhere.

| File | Content | Runs twice? |
| --- | --- | --- |
| `01-schema.sql` | Core schema (same as `xynotransit_app/docs/reference/schema.sql`). Do not redesign. | no |
| `02-api.sql` | `login_token` table and the NOTIFY triggers for live updates. | no |
| `03-dynamic.sql` | Widens the `metric_def.series` check to 0..9999 so a seat can have up to 8 counts and the API can reorder them. | yes |
| `04-deck-text.sql` | `deck_text` (the slide words of a period) and `deck_run.texts` (the words frozen into each deck). | yes |
| `05-reporter.sql` | `report.reporter_name/country/role` (null on old rows) and `login_attempt` (magic link rate limit by email string). | yes |
| `06-integrity.sql` | The database refuses bad data by itself: CHECK constraints, case-insensitive unique indexes, frozen decks, `updated_at`, indexes, views that match the API. See below. | yes |
| `07-ledger.sql` | `schema_migration` (which files this database has had) and `xt_purge_expired()`. | yes |
| `08-role-title-unique.sql` | One seat per person, team and role title, ignoring case and outer spaces (unique index on `lower(btrim(role_title))`). Skipped with a warning if old rows already repeat a title. | yes |

| `10-internal-signin.sql` | `sign_in_link_audit` (who got a one-time sign-in link, who issued it, when, until when; never the token). `login_token` is unchanged. | yes |
| `11-deck-switched-off.sql` | `deck_run.switched_off_count`: how many reports of a deck came from a switched-off seat or person (0 for old decks). | yes |
| `12-passwords.sql` | Usernames and passwords. `person.username` (unique ignoring case, lowercase, 3 to 40 of `a-z 0-9 . _ -`, never null; backfilled from the part of the email before the `@`, numbered on conflict, by the functions `xt_username_base` / `xt_make_username`, and filled by a trigger for inserts that have none), `password_hash` (Argon2id PHC string), `must_change_password`, `session_epoch`, `password_changed_at`; `login_failure` (rows behind the sign-in rate limits, no passwords) and `password_audit` (who set, reset or removed a password; never a password or hash); `xt_purge_expired()` also drops old `login_failure` rows. Existing passwords-free people keep working with links. Apply it (`scripts/migrate.sh`) BEFORE starting an API built with passwords: that API reads these columns. | yes |
| `13-hashed-keys.sql` | Sign-in limits without readable data. `login_failure` is recreated (its old rows were only 15 minute counters and held what was typed in the username box and the client address, so they are dropped, not converted) with `username_key` and `address_key` as HMAC-SHA256 hex (64 lowercase hex characters, enforced by a check; the API makes them with a key derived from `JWT_SECRET`, HKDF label `xt-ratelimit-v1`, so changing the secret also resets the counters). New `login_success(id, username_key, address_key, at)`, one row per pair, refreshed on each success: the addresses that signed in (password or link) for a name within 30 days, which are let through when a name is under attack from many addresses. `password_audit.kind` also accepts `change-via-link`. `xt_purge_expired()` drops failures older than a day and trusted addresses older than 30 days. Retention: nothing in these tables can be read back as a name or an address; do not expect to find a person's failures by name in SQL. Run twice it keeps its rows (the old shape is only replaced while the column `ip` exists). `12-passwords.sql` now creates its three `login_failure` indexes only while that column exists, so it still runs twice after 13. Apply it (`scripts/migrate.sh`) together with the API that matches: the older API writes the old columns. `scripts/test-migrations.sh` does not compare the row count of `login_failure`, which this file empties on purpose. | yes |

A fresh database has an empty catalog. The first manager comes from `BOOTSTRAP_CONTROLLER_EMAIL` and builds teams, people and seats in the app. The old seed (`10-seed.sql`, `20-seed-demo.sql`) lives in `examples/` and is not loaded automatically; see `examples/README.md` to load it by hand.

### First manager without email

No mail server is needed to start. Set `BOOTSTRAP_CONTROLLER_EMAIL=manager@xynotransit.internal`, start the stack, then ask the API for a one-time sign-in link on the server:

```bash
docker compose exec api xynotransit-api sign-in-link manager@xynotransit.internal --hours 24
```

It prints only the link. Open it in a browser (once, within 24 hours). After that the manager makes links for everyone else in the app: People, then "Sign-in link" (copy it or show the QR code). Exit code 1 means no active person has that email or the database is not reachable (the reason is printed); 2 means wrong usage.

### Updating a database that already has data

```bash
./scripts/backup.sh                 # always first
./scripts/migrate.sh                # applies what is missing, prints what it did, safe to repeat
docker compose up -d --build api    # the API that matches
```

`migrate.sh` reads the `schema_migration` ledger. A database from before the ledger existed (no table `schema_migration`) is treated as having 01 and 02 and gets 03 onward, which are all written to run twice. The db image bakes `initdb/` in at build time, so after adding a file rebuild it only if you want a fresh volume to get it (`docker compose build db`).

### What 06-integrity.sql enforces

- **Text:** names, role titles, count names, targets, reporter words: 1 to N characters, no padding spaces (people 80, team 60, count 60, target 200, reporter 80, role title 80); notes 1 to 70; comments at most 200 and not blank; email 3 to 254 with no spaces and an `@` after the first character. The numbers match `xynotransit-api/tests/fixtures/rules.json`.
- **Reporter words** on a report are all there or all missing (reports from before they existed), never blank.
- **Numbers:** a monthly value from 0 to 1,000,000,000. Sort orders are not negative.
- **Dates:** a period starts in 2000 to 2100, a meeting date too.
- **Unique ignoring case:** person email, team name, and the live count names of one seat.
- **Frozen decks (decision):** `deck_run` and `deck_run_item` rows can never be updated. They can only be deleted by a deliberate act: `begin; set local xt.allow_deck_delete = 'on'; delete from deck_run where ...; commit;` (the items follow by cascade). Without the switch, DELETE and TRUNCATE are refused. A period or report that a deck refers to cannot be deleted either (foreign keys). The API never updates or deletes decks, it only adds new ones; the latest one is shown.
- **`updated_at`** on person, team, assignment, count, target and period, set by trigger only when a real column changed (an UPDATE that writes the same values leaves it). An `updated_at` written on purpose, for example by a restore, is kept.
- **Indexes** for what the API runs (checked with EXPLAIN on 300 seats x 24 periods): reports by assignment, seats by person and team, the latest deck of a period, deck items by report, values by count, expired sign-in rows.
- **Existing data:** on a database that holds rows, each check is added `NOT VALID` (new and changed rows are checked at once) and then validated. If old rows break it, the migration prints a WARNING and keeps going; fix the rows and run `alter table ... validate constraint ...`. Unique indexes that old data would break are skipped with a WARNING the same way.

## Backup and restore

```bash
./scripts/backup.sh                                        # backups/xynotransit-20260131-020000.dump, keeps the newest 14
./scripts/restore.sh backups/xynotransit-....dump scratch  # into a database you name (created if missing)
./scripts/restore.sh backups/xynotransit-....dump xynotransit --force   # replace a database that has tables
```

- `backup.sh` writes `pg_dump -Fc` (compressed) to a `.part` file and renames it only after `pg_restore --list` can read it. `BACKUP_DIR` (default `backups/`, which ignores itself in git) and `BACKUP_KEEP` (default 14) change where and how many.
- `restore.sh` has **no default target**, refuses a database that already has tables unless `--force`, and checks the file is a readable backup before it touches anything. To restore over the live database: `docker compose stop api`, restore with `--force`, `docker compose start api`. It prints every table's row count at the end.
- A dump holds the data, the schema, the triggers and the migration ledger, so a restored database needs nothing else.
- Cron, every night at 02:00 (one line, set the path):

```
0 2 * * * cd /path/to/xynotransit/xynotransit-db && ./scripts/backup.sh >> backups/backup.log 2>&1
```

Copy `backups/` off the machine too: a backup on the same disk is not a backup of the disk.

## Tests of the database

```bash
./scripts/test-migrations.sh    # PASS or FAIL
./scripts/test-backup.sh        # PASS or FAIL
```

- `test-migrations.sh`: (a) all files into an empty scratch database, then 03 onward again, schema identical, `migrate.sh` finds nothing left, all constraints valid; (b) a `pg_dump` copy of the live database is migrated, every table keeps its row count, and the whole API test suite runs on a database built from that copy (`TEST_TEMPLATE_DB`; `SKIP_API_TESTS=1` skips this part). Scratch databases are removed; the live one is only read.
- `test-backup.sh`: dumps the live database, restores into a scratch one, compares row counts and schema, checks the refusal without `--force`, the replacement with it, bad files, and the rotation to 14.
- `../xynotransit-api/tests/integrity.rs` proves each constraint, the frozen decks and `updated_at`.

## Useful commands

```bash
docker compose exec db psql -U xynotransit        # SQL shell
docker compose config                             # check the compose file
docker compose logs -f api                        # API logs (magic links when LOG_MAGIC_LINKS=true); every line has its request_id
curl -s localhost:8080/api/health                 # {"ok":true,"db":"up"}, or 503 when the database is down
```

## nginx (web/)

- `web/nginx.conf`: SPA fallback to `index.html`, `/api/` proxied to `api:8081`, `/api/events` with `proxy_buffering off` and a 1 hour read timeout, `index.html` and the service worker files not cached, hashed files cached long.
- `web/security-headers.conf`: security headers including the content security policy. `https://fonts.gstatic.com` is allowed in `connect-src` and `font-src` on purpose: the Flutter engine loads a fallback font at runtime for glyphs the bundled font lacks (names in CJK, Arabic, Cyrillic). The browser asks Google only when such glyphs appear. Remove it if you accept boxes instead of those letters.
- `/api/` passes `X-Request-Id` (nginx `$request_id`) to the API, and hides the security and cache headers the API sets itself, so the browser gets exactly one of each.
- `web/Dockerfile.web`: the image. The Flutter build is mounted, not copied, so rebuilding Flutter needs no image rebuild.

## Production notes

The ready made production setup is [`docker-compose.prod.yml`](docker-compose.prod.yml) with
[`.env.prod.example`](.env.prod.example) and a [`Caddyfile`](Caddyfile). The full walk-through,
including free servers, is in [`../docs/DEPLOY.md`](../docs/DEPLOY.md). What it does differently
from the dev stack, and what you must set:

- **Images, not builds.** It pulls `ghcr.io/xynorash/xynotransit/{api,db,web}` (`IMAGE_TAG`, default `latest`; pin a commit sha to control upgrades). Nothing is built on the server.
- **TLS.** Caddy is the only container with published ports (80 and 443). It gets and renews a Let's Encrypt certificate for `DOMAIN` by itself and sends an HSTS header. The DNS record must point at the server first.
- **No database port.** `db` and `api` are reachable only inside the Docker network. Do not add a `ports:` entry for the database.
- **Real SMTP.** There is no Mailpit. Set `SMTP_HOST`, `SMTP_PORT`, `SMTP_TLS` (`starttls` for 587, `tls` for 465), `SMTP_USERNAME`, `SMTP_PASSWORD` and `MAIL_FROM`. The API checks the server certificate. `LOG_MAGIC_LINKS` is forced to `false`, so a link is never written to the logs.
- **Secrets.** `JWT_SECRET` (`openssl rand -hex 32`, at least 32 characters; changing it signs everyone out) and `POSTGRES_PASSWORD` (`openssl rand -hex 24`, letters and digits only because it goes into a URL). Keep `.env.prod` at mode 600 and out of git (it is ignored).
- **First manager.** `BOOTSTRAP_CONTROLLER_EMAIL` (and `_NAME`) creates or promotes that person every time the API starts. Everyone else is added in the app, on the People page.
- **Restart and health.** Every service has `restart: unless-stopped` and a health check; Caddy waits for `web`, which waits for `api`, which waits for a healthy `db`. Logs rotate (3 files of 10 MB each).
- **Data.** Named volume `pgdata`. Back it up with `scripts/backup.sh` on a schedule (cron line in the Backup section) and copy the dumps off the machine. Keep `caddy_data` too (certificates).
- **Upgrade.** `scripts/backup.sh`, `docker compose ... pull`, `scripts/migrate.sh`, `docker compose ... up -d`. Never edit an `initdb/` file that has been applied; add the next number.
- **Keep** `stop_grace_period` of the api (15s) above `SHUTDOWN_GRACE_SECS` (8), never load `examples/`, and keep the `web` container's security headers (they are in the image).

Check the file before using it: `docker compose --env-file .env.prod -f docker-compose.prod.yml config`.
