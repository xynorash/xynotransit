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

**Always on: demo in the browser (GitHub Pages).** The web app in demo mode: sample data held in
the browser, no server, no sign-in. Use the "Demo:" menu to act as the manager or as an employee.
It is published from `main` by [`pages.yml`](.github/workflows/pages.yml):
`https://<owner>.github.io/<repository>/`.

**Full stack in the cloud: GitHub Codespaces.** Open the repository, choose
*Code, Codespaces, Create codespace on main*. The dev container starts the whole Docker stack
(Postgres, API, Mailpit, nginx with the web app) and forwards two ports: **8080** is the app,
**8025** is Mailpit, where the sign-in emails arrive. Sign in as `demo.manager@xynotransit.example`.
A Codespace sleeps after it has been idle (30 minutes by default, up to 4 hours in your Codespaces
settings), so it is for working and demos, not for hosting.

**Full stack on your machine.** Only Docker is needed:

```bash
cd xynotransit-db
BOOTSTRAP_CONTROLLER_EMAIL=you@example.com \
  docker compose -f docker-compose.yml -f docker-compose.full.yml up -d --build
# app: http://127.0.0.1:8080   sign-in emails: http://127.0.0.1:8025
scripts/smoke.sh        # optional end to end check of the running stack
```

## Continuous integration

[`ci.yml`](.github/workflows/ci.yml) runs on every push and pull request:

1. Flutter: format, analyze, tests (including slide golden images) and a web build.
2. API: `cargo fmt`, `clippy -D warnings` and the tests against a Postgres service.
3. Full stack: builds every image from scratch on the runner, starts the stack and runs
   [`scripts/smoke.sh`](xynotransit-db/scripts/smoke.sh) (sign in through Mailpit, build a team,
   send a report, generate a deck, read the summary).
4. On `main`, publishes the `api`, `db` and `web` images to `ghcr.io/<owner>/<repository>/`.

## Running it for real

GitHub does not host running servers. For a deployment that stays up, run the three published
images on a host of your choice (a small VPS, Fly.io, Render, ...) with a strong `JWT_SECRET`, real
SMTP (`SMTP_HOST`, `SMTP_PORT`, `MAIL_FROM`), `PUBLIC_URL` set to your address, TLS in front, and
`BOOTSTRAP_CONTROLLER_EMAIL` for the first manager. See [`xynotransit-api/README.md`](xynotransit-api/README.md)
for every setting.
