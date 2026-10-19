# Deploy notes (Oracle)

Docs only. The compose files of the stack are `../../docker-compose.yml` and `../../docker-compose.prod.yml`.

## Settings for internal addresses

| Variable | Default | Meaning |
| --- | --- | --- |
| `INTERNAL_EMAIL_DOMAINS` | `xynotransit.internal` | Comma separated. Addresses at these domains never receive mail. Add `INTERNAL_EMAIL_DOMAINS: ${INTERNAL_EMAIL_DOMAINS:-}` to the `api` environment of your compose file to change it; leaving it out keeps the default. |

`PUBLIC_URL` must be the address people open in their browser (for example `https://reports.example.org`), because sign-in links are built from it.

## First manager without email

No mail server is needed for the first sign-in.

1. In `.env.prod` set `BOOTSTRAP_CONTROLLER_EMAIL=manager@xynotransit.internal` and `PUBLIC_URL`.
2. Start the stack. The API creates that person as a manager.
3. Create a one-time sign-in link on the server:

```bash
docker compose --env-file .env.prod -f docker-compose.prod.yml exec api \
  xynotransit-api sign-in-link manager@xynotransit.internal --hours 24
```

In short: `docker compose exec api xynotransit-api sign-in-link <email> --hours 24`.

It prints only the link. Open it in a browser within 24 hours; it works once. The command needs an active person with that email (exit 1 with a plain message otherwise).
4. From then on the manager makes links for other people in the app (People, "Sign-in link"). Share them privately: anyone who has a link can sign in as that person until it is used or expires.

Apply `initdb/10-internal-signin.sql` to a database that already lives (`scripts/migrate.sh`) before starting the new API.

## Passwords

Passwords are added next to the sign-in links; links stay the way to get started and to recover.

1. Before starting the new API image, bring the database up to date: `scripts/migrate.sh` (it applies every missing file, in particular `initdb/12-passwords.sql`, `13-hashed-keys.sql` and `14-link-origin.sql`; existing people get a username from their email, for example `rosa.rakoto`). Take a backup first (`scripts/backup.sh`).
2. Hashing uses Argon2id with the OWASP minimum (19 MiB per hash, at most 2 at a time), which fits the 1 GB machine. Do not set `PASSWORD_HASH_MEMORY_KIB` or `PASSWORD_HASH_ITERATIONS` in production; they exist for the test suite.
3. Set or reset a password from the app (People, "Reset password": the manager sees a temporary password once) or from the server:

```bash
docker compose --env-file .env.prod -f docker-compose.prod.yml exec -it api \
  xynotransit-api set-password manager
```

   It asks for the new password twice without echo and prints `Password set for manager.`.
4. Sign-in tries are limited (5 wrong tries per username and 30 per address in 15 minutes). The API takes the client address from `X-Forwarded-For` only when the connection comes from a private address (nginx, Caddy); keep both proxies setting that header and keep the API port off the internet.
