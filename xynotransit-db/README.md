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

Open http://127.0.0.1:8080 and sign in with the manager email (`BOOTSTRAP_CONTROLLER_EMAIL`, role controller). Read the link in Mailpit at http://127.0.0.1:8025. A manager lands on the dashboard (`/manager`); anyone else a manager has added lands on their own report form (`/report`) and cannot see slides, the reports table or exports. The API enforces this: the list of reports, the deck and live events are controller only.

Scripts (also `make up|down|reset|logs`):

- `scripts/up.sh` builds and starts everything.
- `scripts/down.sh` stops it, keeps data.
- `scripts/reset.sh` stops it and deletes the database volume, then starts again. initdb runs again.
- `scripts/logs.sh` follows the logs.
- `scripts/migrate.sh [database]` brings a database that lives on up to date (see "Init SQL").
- `scripts/backup.sh`, `scripts/restore.sh` (see "Backup and restore").
- `scripts/test-migrations.sh`, `scripts/test-backup.sh` print PASS or FAIL (see "Tests of the database").
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
| `BOOTSTRAP_CONTROLLER_EMAIL` | empty | This person is created (or promoted and activated) as controller at API start. |
| `BOOTSTRAP_CONTROLLER_NAME` | empty | Name used when that person is created. Default: the part of the email before the `@`, capitalised. |
| `LOG_MAGIC_LINKS` | `true` | Log links. Dev only. |
| `RUST_LOG` | `info` | Log level. |
| `LOG_FORMAT` | text | `json` for one JSON object per log line. |
| `SHUTDOWN_GRACE_SECS` | `8` | Seconds that running requests get to finish after SIGTERM (Docker stops after 10 by default). |

The API variables `SMTP_HOST` (`mailpit`), `SMTP_PORT` (`1025`) and `BIND` (`0.0.0.0:8081`) are fixed in the compose file. See `../xynotransit-api/README.md` for all of them.

## Init SQL (initdb/) and migrations

**Order.** `entrypoint.sh` runs every `/initdb/*.sql` in name order, but only on the first start of an empty volume. The API test suite builds its databases the same way (all files, name order), and `scripts/migrate.sh` follows the same order for a database that lives on. Name a new file with the next number (`08-...sql`); never edit a file that has been applied somewhere.

| File | Content | Runs twice? |
| --- | --- | --- |
| `01-schema.sql` | Core schema (same as `xynotransit_app/docs/reference/schema.sql`). Do not redesign. | no |
| `02-api.sql` | `login_token` table and the NOTIFY triggers for live updates. | no |
| `03-dynamic.sql` | Widens the `metric_def.series` check to 0..9999 so a seat can have up to 8 counts and the API can reorder them. | yes |
| `04-deck-text.sql` | `deck_text` (the slide words of a period) and `deck_run.texts` (the words frozen into each deck). | yes |
| `05-reporter.sql` | `report.reporter_name/country/role` (null on old rows) and `login_attempt` (magic link rate limit by email string). | yes |
| `06-integrity.sql` | The database refuses bad data by itself: CHECK constraints, case-insensitive unique indexes, frozen decks, `updated_at`, indexes, views that match the API. See below. | yes |
| `07-ledger.sql` | `schema_migration` (which files this database has had) and `xt_purge_expired()`. | yes |

A fresh database has an empty catalog. The first manager comes from `BOOTSTRAP_CONTROLLER_EMAIL` and builds teams, people and seats in the app. The old seed (`10-seed.sql`, `20-seed-demo.sql`) lives in `examples/` and is not loaded automatically; see `examples/README.md` to load it by hand.

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
- `web/security-headers.conf`: security headers including the content security policy.
- `web/Dockerfile.web`: the image. The Flutter build is mounted, not copied, so rebuilding Flutter needs no image rebuild.

## Production notes

Remove `mailpit`, set real SMTP variables on the API, `LOG_MAGIC_LINKS=false`, schedule `scripts/backup.sh`, set `stop_grace_period` of the api above `SHUTDOWN_GRACE_SECS`, use a strong `JWT_SECRET` and `POSTGRES_PASSWORD`, put TLS in front and set `PUBLIC_URL`, never load `examples/`, and do not publish the db port.
