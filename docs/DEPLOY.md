# Deploying Xynotransit

This guide puts the whole app on one small Linux server with HTTPS. You need:

- a server you can reach over SSH (1 GB of memory is enough for a team of a few hundred people; 2 GB is comfortable),
- a domain name (or a subdomain) whose DNS you can edit,
- an email account or service that can send mail by SMTP, because people can sign in with a link sent by email (links are how a person gets started and how they recover; day to day they can use a username and password).

Nothing is built on the server. The images come from `ghcr.io/xynorash/xynotransit/{api,db,web}`, which the CI of this repository publishes after every green build on `main`.

What runs, all in Docker:

| Container | Job | Reachable from outside? |
| --- | --- | --- |
| `caddy` | HTTPS certificate (automatic, Let's Encrypt) and the front door | yes, ports 80 and 443 |
| `web` | nginx with the app, passes `/api/` on | no |
| `api` | the Rust backend, sends the sign-in emails | no |
| `db` | Postgres 18, the data | no |

## 1. A small VPS (any provider)

### 1.1 Server

1. Create a server with Ubuntu 24.04 or Debian 12. Any provider works. Open ports **80** and **443** (and 22 for SSH) in its firewall.
2. In your DNS, add an `A` record (and an `AAAA` record if the server has IPv6) for the name you want, for example `reports.example.org`, pointing at the server's address. Wait until `dig +short reports.example.org` shows it.
3. Install Docker (includes the `docker compose` plugin):

   ```bash
   curl -fsSL https://get.docker.com | sudo sh
   sudo usermod -aG docker $USER      # then log out and in again
   ```

### 1.2 Get the files

You only need the two compose files, not the whole repository:

```bash
git clone --depth 1 https://github.com/xynorash/xynotransit.git
cd xynotransit/xynotransit-db
cp .env.prod.example .env.prod
chmod 600 .env.prod
```

### 1.3 Fill in `.env.prod`

Edit `.env.prod` and set every line that has no value:

| Setting | What to put |
| --- | --- |
| `DOMAIN` | `reports.example.org` (no `https://`) |
| `PUBLIC_URL` | `https://reports.example.org` |
| `POSTGRES_PASSWORD` | `openssl rand -hex 24` |
| `JWT_SECRET` | `openssl rand -hex 32` (at least 32 characters; changing it later signs everyone out) |
| `BOOTSTRAP_CONTROLLER_EMAIL` | your own address. You become the first manager. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_TLS`, `SMTP_USERNAME`, `SMTP_PASSWORD` | from your mail provider. Port 587 with `starttls`, or port 465 with `tls`. |
| `MAIL_FROM` | an address your provider allows, for example `Xynotransit <no-reply@example.org>` |

The API checks the mail server's certificate. `SMTP_TLS=none` sends mail in plain text and exists only for a local catcher such as Mailpit.

Mail is the part that most often goes wrong, and it is only needed for emailed links; passwords work without it. Use a provider that gives you SMTP credentials (your own mailbox, or a transactional service with a free tier) and set up its SPF and DKIM records for the sending domain, or the sign-in links land in spam.

### People without a real email

If some people have no mailbox, you do not need mail for them. Add them in People with the email left empty: they get an address like `name@xynotransit.internal`. A manager then makes a one-time sign-in link for each person and shares it privately. To start with no working mail at all, set `BOOTSTRAP_CONTROLLER_EMAIL` to an internal address, start the stack (step 1.4), and make the first sign-in link on the server:

```bash
docker compose exec api xynotransit-api sign-in-link manager@xynotransit.internal --hours 24
```

It prints only the link. Anyone who has a link can sign in as that person until it is used or it expires, so send it privately. `INTERNAL_EMAIL_DOMAINS` in the API settings lists the domains that never get mail.

### 1.4 Start

```bash
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d
docker compose --env-file .env.prod -f docker-compose.prod.yml ps     # wait until db, api, web and caddy are healthy
```

The first start pulls the images and Caddy asks Let's Encrypt for a certificate; that takes under a minute once DNS is right. Then open `https://reports.example.org`, type the `BOOTSTRAP_CONTROLLER_EMAIL` address and click the link in the email. You land on the manager overview, where you create teams, people and seats on the **People** page.

If a start fails, `docker compose --env-file .env.prod -f docker-compose.prod.yml logs --tail 100 caddy api` says why (wrong DNS, closed port 80, bad SMTP settings).

If the pull says `denied` or `unauthorized`, the image packages are private. On GitHub, open the repository, **Packages**, each of `api`, `db` and `web`, **Package settings**, **Change visibility**, Public (or `docker login ghcr.io` with a token that can read packages).

### 1.5 Backups (do this on day one)

The data lives in the Docker volume `pgdata`. Back it up with the script, not by copying files:

```bash
cd ~/xynotransit/xynotransit-db
./scripts/backup.sh          # writes backups/xynotransit-<date>.dump, keeps the newest 14
```

Every night at 02:00 (run `crontab -e`, one line, fix the path):

```
0 2 * * * cd /home/YOU/xynotransit/xynotransit-db && ./scripts/backup.sh >> backups/backup.log 2>&1
```

The scripts run `pg_dump` inside the database container (`xynotransit-db-db-1`, which is what the prod compose file produces), so the server needs nothing but Docker. Also copy `backups/` off the machine, for example with `rclone` or `rsync` to another provider: a backup on the same disk does not survive the disk. To restore, see `xynotransit-db/README.md` ("Backup and restore"). Try a restore once into a scratch database (`./scripts/restore.sh backups/FILE.dump scratch`) before you need it for real.

### 1.6 Updating

```bash
cd ~/xynotransit && git pull
cd xynotransit-db
./scripts/backup.sh                                                           # always first
docker compose --env-file .env.prod -f docker-compose.prod.yml pull
./scripts/migrate.sh                                                          # adds new database changes, safe to repeat
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d
```

`migrate.sh` applies the files in `xynotransit-db/initdb/` that your database does not have yet. To stay on a known version, set `IMAGE_TAG` in `.env.prod` to a commit sha shown on the Packages page. To go back, restore the backup you took first.

### 1.7 Where the free ones differ

Everything above is the same on any host. The sections below only cover creating the free server. After that, continue at 1.1 step 2.

## 2. Free option: Oracle Cloud Always Free VM

Oracle's Always Free tier includes small VMs that do not expire after a trial. Create one with Ubuntu, open ports 80 and 443 (both in the VCN **security list** and in the VM's own firewall, because Oracle's Ubuntu images block them with `iptables`), attach a public IP, and follow section 1.

Honest caveats:

- The free allowance changes. We have seen reports that the Arm (Ampere A1) allowance was cut to 2 OCPU and 12 GB of memory in June 2026; check the current Always Free page before you plan around any number.
- Oracle can reclaim Always Free instances that sit idle for a long time. A server that handles a few sign-ins a week may count as idle. Keep the backups off the VM.
- Capacity in popular regions is often "out of host capacity" for the Arm shape; people retry for days or pick another region. The images here are built for `amd64` only, so choose an x86 shape (the tiny `VM.Standard.E2.1.Micro`, 1 GB of memory, is enough for a small team). To run on an Arm VM, the images would first need an `arm64` build.
- Signing up needs a card for identity checks, and accounts are sometimes refused.
- Mail: Oracle blocks outgoing port 25 by default. Ports 587 and 465 to a mail provider work.

## 3. Free option: Google Cloud e2-micro

Google Cloud's Always Free tier includes one `e2-micro` VM per month in some US regions (Oregon `us-west1`, Iowa `us-central1`, South Carolina `us-east1`).

1. Create a project, enable Compute Engine, create an `e2-micro` VM in one of those regions with a **Standard persistent disk** (up to 30 GB is free) and Debian 12 or Ubuntu 24.04.
2. Tick "Allow HTTP traffic" and "Allow HTTPS traffic", or add a firewall rule for ports 80 and 443.
3. Reserve a static external IP and point your DNS at it (an unused reserved address is billed; one attached to a running VM in the free tier is not, but read the page).
4. Follow section 1.

Honest caveats:

- The e2-micro has **1 GB of memory** (0.25 vCPU burst to 2) and 30 GB of disk. Postgres, the API, nginx and Caddy fit, but add 2 GB of swap (`sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`, and add it to `/etc/fstab`) so a spike does not kill a container.
- The free allowance is only for those US regions, so the server is far from users elsewhere. The app is light, but expect 150 ms or more of latency from Europe or Africa.
- Network egress above the free amount is billed, and a billing account with a card is required.
- Google can change the terms. There is no free tier anywhere that is guaranteed forever.

## 4. If a free tier goes away

Because everything is Docker plus one backup script, moving is simple: `./scripts/backup.sh` on the old server, copy the `.dump` file and `.env.prod` to the new one, start the stack (section 1.4), then `./scripts/restore.sh backups/FILE.dump xynotransit --force` after `docker compose stop api`, and `docker compose start api`. Change the DNS record last.

A paid VPS with 1 to 2 GB of memory costs a few euros or dollars a month and does not have the caveats above.

## 5. Checks after the first start

- `curl -s https://reports.example.org/api/health` prints `{"ok":true,"db":"up"}`.
- Signing in by link sends an email (check your spam folder the first time). Username and password sign-in needs no mail: after the migration, set the first manager's password with `docker compose --env-file .env.prod -f docker-compose.prod.yml exec -it api xynotransit-api set-password <username>` (see `xynotransit-db/deploy/oracle/README.md`, section Passwords). Keep nginx and Caddy setting `X-Forwarded-For` so the 30 per address limit sees real clients.
- `docker compose --env-file .env.prod -f docker-compose.prod.yml ps` shows every container as `healthy`.
- Port 5432 is not reachable from outside: `nc -zv YOUR_IP 5432` fails.
- A reboot of the server brings everything back by itself (`restart: unless-stopped`).

## 6. Without a domain

A quick look without a domain or certificate: use the GitHub Codespaces setup or the local stack described in the root `README.md`. The prod stack needs a real domain for HTTPS. For a trial on a laptop, set `DOMAIN=localhost`; Caddy then makes its own local certificate, which the browser will warn about.
