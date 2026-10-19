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

The API variables `SMTP_HOST` (`mailpit`), `SMTP_PORT` (`1025`) and `BIND` (`0.0.0.0:8081`) are fixed in the compose file. See `../xynotransit-api/README.md` for all of them.

## Init SQL (initdb/)

`entrypoint.sh` runs every `/initdb/*.sql` in name order, but only on the first start of an empty volume.

| File | Content |
| --- | --- |
| `01-schema.sql` | Core schema (same as `xynotransit_app/docs/reference/schema.sql`). Do not redesign. |
| `02-api.sql` | `login_token` table and the NOTIFY triggers for live updates. |
| `03-dynamic.sql` | Widens the `metric_def.series` check to 0..9999 so a seat can have up to 8 counts and the API can reorder them. Safe to run again. |
| `04-deck-text.sql` | `deck_text` (the slide words of a period) and `deck_run.texts` (the words frozen into each deck). Safe to run again. |
| `05-reporter.sql` | `report.reporter_name/country/role` (null on old rows) and `login_attempt` (magic link rate limit by email string). Safe to run again. |

A fresh database has an empty catalog. The first manager comes from `BOOTSTRAP_CONTROLLER_EMAIL` and builds teams, people and seats in the app. The old seed (`10-seed.sql`, `20-seed-demo.sql`) lives in `examples/` and is not loaded automatically; see `examples/README.md` to load it by hand.

To apply a new file to an existing volume, run it by hand:

```bash
docker compose exec -T db psql -U xynotransit -d xynotransit < initdb/02-api.sql
```

For the slide words, run `initdb/04-deck-text.sql` the same way on a volume made before it existed. Existing data is kept and decks made earlier read as the default words. Likewise run `initdb/05-reporter.sql` on a volume made before it existed.

## Useful commands

```bash
docker compose exec db psql -U xynotransit        # SQL shell
docker compose config                             # check the compose file
docker compose logs -f api                        # API logs (magic links when LOG_MAGIC_LINKS=true)
```

## nginx (web/)

- `web/nginx.conf`: SPA fallback to `index.html`, `/api/` proxied to `api:8081`, `/api/events` with `proxy_buffering off` and a 1 hour read timeout, `index.html` and the service worker files not cached, hashed files cached long.
- `web/security-headers.conf`: security headers including the content security policy.
- `web/Dockerfile.web`: the image. The Flutter build is mounted, not copied, so rebuilding Flutter needs no image rebuild.

## Production notes

Remove `mailpit`, set real SMTP variables on the API, use a strong `JWT_SECRET` and `POSTGRES_PASSWORD`, put TLS in front and set `PUBLIC_URL`, never load `examples/`, and do not publish the db port.
