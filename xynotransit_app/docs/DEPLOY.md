# Deploying the web app

The main server guide is [`docs/DEPLOY.md`](../../docs/DEPLOY.md) at the root of the repository. This page is about the web app only.

## Netlify front door

### Why

Some company firewalls block free "dynamic DNS" host names such as `84-12-108-224.sslip.io`. People behind such a firewall cannot open the app at all. The fix is to let them open a normal address on `netlify.app` instead. Netlify serves the app and passes every `/api/` request on to the server. The browser only ever talks to `netlify.app`.

```
browser  ->  https://<site>.netlify.app          (the app files)
browser  ->  https://<site>.netlify.app/api/...  ->  Netlify  ->  https://84-12-108-224.sslip.io/api/...
```

The second path is a rewrite with status 200 (a proxy, not a redirect). Because the call to the server is made by Netlify, the firewall never sees the blocked name. The app is built with `API_BASE_URL=/api`, so it calls the same site it was loaded from.

### How

Files are in `xynotransit_app/deploy/netlify/`:

| File | What it does |
| --- | --- |
| `netlify.toml.example` | Template with the redirects, security headers and cache rules. Holds placeholders only. |
| `make_netlify_toml.sh` | Fills in the server address and the key and writes `netlify.toml` into a build folder. |
| `deploy.sh` | Builds the app, writes `netlify.toml`, deploys with the Netlify CLI. |

Steps:

1. Make a key once: `openssl rand -hex 32`. Keep it in your password manager.
2. Put the same value on the server as `PROXY_AUTH_KEY` (in `.env.prod`) and restart the `api` container. The API then trusts the visitor address that Netlify sends (`X-Nf-Client-Connection-Ip`) only on requests that carry the key.
3. Log in once: `netlify login`. Create the site once (`netlify sites:create`) and note its name or id.
4. Deploy:

   ```bash
   export PROXY_AUTH_KEY=...            # the key from step 1
   export NETLIFY_SITE=my-site-name     # site name or id
   xynotransit_app/deploy/netlify/deploy.sh          # production
   xynotransit_app/deploy/netlify/deploy.sh --draft  # a preview address first
   ```

   Set `API_ORIGIN` if the server is not at `https://84-12-108-224.sslip.io`.

The script builds into a fresh temporary folder outside git and deletes it afterwards. `make_netlify_toml.sh` refuses a missing key or one shorter than 32 characters, and refuses to write inside a git folder unless the file is ignored.

### The key

The key is a shared secret between Netlify and the server. Netlify adds it as the request header `X-Xt-Proxy-Key` on every proxied `/api/` call. It lives in the generated `netlify.toml`, which stays next to the build (the Netlify CLI reads it from the folder it runs in) and is never published as a file. The rule itself is stored by Netlify, so people with access to the site settings can see the key. Do not commit it. `.gitignore` ignores every `netlify.toml` under the app. To change it: new key, set it on the server, restart the api, deploy again.

### The 26 second cut

Netlify ends a proxied request after about 26 seconds. The live updates stream (`/api/events`) is one long request, so it is cut about every 26 seconds. The app expects this:

- it reconnects at once with a new single-use ticket and refreshes the data once, so nothing is missed;
- a cut that comes after a connection held for a few seconds is normal and shows nothing;
- if reconnecting fails, it waits 1, 2, 4, 8, then at most 15 seconds (with random jitter);
- after 3 failed tries in a row it shows "Live updates paused, retrying" and keeps polling; the notice goes away when a connection holds again;
- when signed out, it stops; when the tab has been hidden for more than 2 minutes it stops, and it resumes with a refresh when the tab is shown.

### Limits

- Any single API call must finish in under about 26 seconds (normal calls take milliseconds).
- Netlify bandwidth and build limits of your plan apply. API traffic counts as bandwidth.
- The server sees Netlify as the caller. Only the key makes the visitor address (for sign-in rate limits) trustworthy; without a valid key the API ignores the address header.
- The server name `sslip.io` is still used between Netlify and the server. If you later get a real domain, change `API_ORIGIN` and deploy again.
- Sign-in sessions work as before, since the app and the API now share one origin.
