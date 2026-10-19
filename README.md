# Xynotransit Logistics Report Builder

A quarterly reporting tool for a logistics team. Each person fills in one short report per
three-month period (their own counts, whether they met their targets, and a few notes in their
own words). A manager follows progress on a dashboard with charts and turns the submitted
reports into a meeting deck (PDF, PowerPoint or PNG slides) whose text they can customize.

| Folder | What it is |
|---|---|
| [`xynotransit_app/`](xynotransit_app) | Flutter web app: employee form, manager dashboard, People admin, deck text editor, slide preview and exports. |
| [`xynotransit-api/`](xynotransit-api) | Rust (axum) backend: magic-link sign-in, roles, reports, summary, decks, live updates. |
| [`xynotransit-db/`](xynotransit-db) | Docker stack: Postgres (Arch Linux), the API, Mailpit for sign-in emails, nginx for the web app. |

## Try it

**Always on: demo in the browser (GitHub Pages).** <https://xynorash.github.io/xynotransit/>
The web app in demo mode: made-up sample data held in the browser tab, no server, no sign-in.
Use the "Demo:" menu to act as the manager or as an employee. Nothing you type is saved anywhere
except that tab. It is published from `main` by [`pages.yml`](.github/workflows/pages.yml).

**Full stack in the cloud: GitHub Codespaces.**
[Open a codespace](https://codespaces.new/xynorash/xynotransit) (or *Code, Codespaces, Create
codespace on main*). The dev container starts the whole Docker stack (Postgres, API, Mailpit,
nginx with the web app) and forwards two ports: **8080** is the app, **8025** is Mailpit, where
the sign-in emails arrive. Sign in as `demo.manager@xynotransit.example`. The first start builds
every image and the Flutter app, which takes several minutes. A Codespace sleeps after it has been
idle (30 minutes by default) and is billed against your free monthly Codespaces hours, so it is
for working and demos, not for hosting.

**Full stack on your machine.** Only Docker is needed:

```bash
cd xynotransit-db
BOOTSTRAP_CONTROLLER_EMAIL=you@example.com \
  docker compose -f docker-compose.yml -f docker-compose.full.yml up -d --build
# app: http://127.0.0.1:8080   sign-in emails: http://127.0.0.1:8025
scripts/smoke.sh        # optional end to end check of the running stack
```

To work on the app with hot reload you also need Flutter 3.47 and Rust (stable); see
[`xynotransit_app/README.md`](xynotransit_app/README.md) and
[`xynotransit-api/README.md`](xynotransit-api/README.md).

## Tests

```bash
# Flutter app: format, analyze, unit, widget and slide golden-image tests
cd xynotransit_app && dart format --set-exit-if-changed lib test tool && flutter analyze && flutter test

# API: needs a Postgres (the local stack's db on 127.0.0.1:5432 works)
cd xynotransit-api && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test

# Database: migrations and backup/restore round trip against the running local db
cd xynotransit-db && scripts/test-migrations.sh && scripts/test-backup.sh

# The Flutter repository against the real API (stack running on :8080)
cd xynotransit_app && flutter test test/contract --dart-define=CONTRACT_API=http://127.0.0.1:8080

# End to end through nginx: sign in, build a team, send reports, make a deck, read the summary
cd xynotransit-db && scripts/smoke.sh
```

The contract scenarios always run against the in-memory backend; against the real API they run only
when `CONTRACT_API` is set (add `--dart-define=CONTRACT_MANAGER=<email of a manager>` if it is not
`shalini@xynotransit.example`). A few other tests are skipped on purpose and say why in their
description.

## Continuous integration

[`ci.yml`](.github/workflows/ci.yml) runs on every push and pull request:

1. **flutter**: format, analyze, tests (including slide golden images) and a web build.
2. **api**: `cargo fmt`, `clippy -D warnings` and the tests against a Postgres service.
3. **stack**: builds every image from scratch on the runner, starts the stack, runs
   [`scripts/smoke.sh`](xynotransit-db/scripts/smoke.sh), then the Flutter contract tests against it.
4. **images** (on `main` only): publishes the `api`, `db` and `web` images to
   `ghcr.io/xynorash/xynotransit/`.

## Running it for real

GitHub does not host running servers. [`docs/DEPLOY.md`](docs/DEPLOY.md) is a step by step guide for a
small VPS and for the free tiers of Oracle Cloud and Google Cloud, with their caveats. In short:
[`xynotransit-db/docker-compose.prod.yml`](xynotransit-db/docker-compose.prod.yml) runs the
published images behind Caddy, which gets the HTTPS certificate for your domain by itself. You
fill in [`.env.prod.example`](xynotransit-db/.env.prod.example): domain, `JWT_SECRET`, database
password, SMTP settings and the first manager's email.

**Backups.** `xynotransit-db/scripts/backup.sh` writes a compressed dump and keeps the newest 14;
put it in cron and copy the dumps off the machine. `scripts/restore.sh` brings one back. Both are
covered by `scripts/test-backup.sh`.

## Limits

- Sign-in is by emailed link only; there are no passwords. A mail server is required outside the
  demo and the local stack (the local stack catches mail in Mailpit).
- One team of reports per quarter is read at a time; the dashboard is made for up to a few hundred
  people, not for thousands.
- A seat has at most 8 counts and 10 targets; text lengths and number ranges are fixed
  (see `xynotransit_app/docs/ASSUMPTIONS.md`).
- The published images are for `amd64` only.
- The demo keeps its data in the browser tab; reloading starts it over.
- Names with letters outside the bundled font (for example Chinese, Arabic or Cyrillic) make the
  browser fetch a fallback font from `fonts.gstatic.com`; see `xynotransit-db/README.md`.
