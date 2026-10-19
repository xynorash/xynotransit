# Xynotransit Logistics Report Builder

A quarterly reporting tool for a logistics team. Each person fills in one short report per
three-month period (their own counts, whether they met their targets, and a few notes in their
own words). A manager follows progress on a dashboard with charts and turns the submitted
reports into a meeting deck (PDF, PowerPoint or PNG slides) whose text they can customize.

| Folder | What it is |
|---|---|
| [`xynotransit_app/`](xynotransit_app) | Flutter web app: employee form, manager dashboard, People admin, deck text editor, slide preview and exports. |
| [`xynotransit-api/`](xynotransit-api) | Rust (axum) backend: sign-in with username and password or by link, roles, reports, summary, decks, live updates. |
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

## What changed in the latest round

- Number fields keep exactly what is typed. Anything that is not a whole number (0 to 1,000,000,000) shows a lasting message, counts as missing and blocks Send.
- A switched-off person's reports stay in the Reports table, the CSV and new decks, tagged Inactive. They are never counted as missing, and "N of M" can no longer have N above M. The deck header says "plus K from a switched-off person".
- Where one person has two seats, lists show "Name · Seat title". The employee seat picker is "Choose a seat" and remembers the last seat on the device.
- The CSV has three new last columns: Reported name, Reported country, Reported role. The Reports table shows them under the name when they differ from the profile.
- Employees get only their own person, seats and teams from the catalog.
- The PDF has an invisible text layer (the slide's speaker notes), a language and a title.
- Slides: one common chart scale unless counts differ by more than 8 times (then each count has its own scale, said on the slide); no zero labels when there are more than 3 bars per month; larger text on short results slides; target cards aligned at the top; cover chips read "Team · 2 reports"; the comment an employee typed shows under a partly or missed target when there is room.
- The word "controller" is gone from everything users read: it says "manager". The stored role value `controller` is unchanged.
- "Reset all to defaults" on Deck text asks first. A too-many-requests answer carries a `Retry-After` header and the sign-in screen says when to try again.

## Signing in

- **Username and password** is the main form. Usernames are lower case letters, digits, dot, dash and underscore (3 to 40); a new person gets the start of their email address. Passwords are 10 to 128 characters, spaces allowed, with no composition rules; the only refusals are the person's own name, username or email, one repeated character, a simple run and a list of common passwords.
- **Links** stay as the way to start and to recover: an emailed link, a one-time link a manager makes for a person without an email, or `xynotransit-api sign-in-link <email>` on the server. After a link sign-in a person without a password is offered "Choose a password" (it can be skipped). Only an emailed link, or a manager or server link made with the recovery option (`"recovery": true`, `--recovery`), lets a person who has a password choose a new one without the old one.
- **First manager.** Either `sign-in-link` or `docker compose exec -it api xynotransit-api set-password <username-or-email>` (asks twice without echo).
- **Managers** can reset a password (People, "Reset password"): a temporary 16 character password is shown once and never stored. The person must choose their own before anything else works (every other route answers 403 "Choose a new password first."). "Remove password" makes the person link-only again.
- **Sessions end** when a password is changed, reset or removed, and when a person is switched off.
- **Lockout.** 5 wrong tries per username and 30 per client address in 15 minutes give 429 with `Retry-After`. A wrong current password while signed in is counted apart (10 per person in 15 minutes, from any address; the 10th ends the person's sessions). Wrong username, wrong password, switched-off person and no password all answer the same "Username or password is wrong." after the same work.
- **Security notes.** Passwords are hashed with Argon2id (m=19456 KiB, t=2, p=1, at most 2 hashes at a time for a 1 GB machine). A password, hash, temporary password or token is never logged or audited. The client address comes from `X-Forwarded-For` only when the connecting peer is a private address (nginx, Caddy), taking the right-most untrusted hop. Details: [`xynotransit-api/README.md`](xynotransit-api/README.md#passwords). The public demo keeps its "Demo:" menu and implements the same rules in memory.
- **Existing databases** need `xynotransit-db/scripts/migrate.sh` (every missing migration, up to `14-link-origin.sql`) before the new API starts.

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

**Behind a firewall that blocks the server name.** Some offices block free dynamic DNS names such as `sslip.io`. The web app can then be served from Netlify, which forwards `/api/` to the server so the browser only talks to `netlify.app`. Scripts and steps: [`xynotransit_app/docs/DEPLOY.md`](xynotransit_app/docs/DEPLOY.md) (section "Netlify front door").

## Limits

- Sign-in is by username and password, or by a one-time link. Links (emailed, or made by a manager
  for people without an email) are how a person gets started and how they recover. A mail server is
  needed outside the demo and the local stack only if people use emailed links (the local stack
  catches mail in Mailpit); the first manager can also be set up from the server with
  `sign-in-link` or `set-password`.
- One team of reports per quarter is read at a time; the dashboard is made for up to a few hundred
  people, not for thousands.
- A seat has at most 8 counts and 10 targets; text lengths and number ranges are fixed
  (see `xynotransit_app/docs/ASSUMPTIONS.md`).
- The published images are for `amd64` only.
- The demo keeps its data in the browser tab; reloading starts it over.
- Names with letters outside the bundled font (for example Chinese, Arabic or Cyrillic) make the
  browser fetch a fallback font from `fonts.gstatic.com`; see `xynotransit-db/README.md`.
