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
