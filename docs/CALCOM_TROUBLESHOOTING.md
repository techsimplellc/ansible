---
tags:
  - homelab
  - troubleshooting
  - cal.com
  - nginx-proxy-manager
  - cloudflare
  - docker
  - srv4
created: 2026-03-18
status: active
---

# Cal.com 502 Troubleshooting — `cal.techsimple.dev`

## Google Credentials

| key: value |
|---|
| calcom_google_client_id: ** Look in secrets vault ** |
| calcom_google_client_secret: ** Look in secrets vault ** |
| redirect_uris: https://cal.techsimple.dev/api/integrations/googlecalendar/callback |

## Architecture Overview

```
Browser
  │
  ▼
Cloudflare Edge (TLS termination)
  │  tunnel: cal.techsimple.dev → http://npm:80
  ▼
cloudflared container (srv1)
  │
  ▼
NPM container (srv1, internal name: npm)
  │  proxy host: cal.techsimple.dev → http://192.168.68.14:3000
  ▼
Cal.com container (srv4, port 3000)
  │
  ▼
PostgreSQL container (srv4)
```

A 502 Bad Gateway can originate at **any hop** in this chain. Work from the inside out.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| SSH access | `ssh -p 2222 bpainter@192.168.68.11` (srv1), `ssh -p 2222 bpainter@192.168.68.14` (srv4) |
| Docker access | `docker-admin` group or `sudo` on relevant hosts |
| NPM UI | `http://192.168.68.11:81` |
| Cloudflare dashboard | `https://one.dash.cloudflare.com` |

---

## Variables

| Variable | Value |
|---|---|
| Cal.com host | `srv4` — `192.168.68.14` |
| Cal.com container port | `3000` |
| NPM host | `srv1` — `192.168.68.11` |
| NPM internal container name | `npm` |
| Cloudflare tunnel target | `http://npm:80` |
| NPM proxy target | `http://192.168.68.14:3000` |
| Public hostname | `cal.techsimple.dev` |

---

## Known Issues Encountered During Initial Deployment

> These issues were hit sequentially during the first deployment of Cal.com on srv4. Documented here as a fast-path reference for future redeploys.

### Issue 1 — `CALENDSO_ENCRYPTION_KEY` Not Set → App Crashes at Config Load

**Symptom:**
```
⨯ Failed to load next.config.ts
Error: Please set CALENDSO_ENCRYPTION_KEY
```

**Cause:** Cal.com's `next.config.ts` validates required env vars at startup. If `CALENDSO_ENCRYPTION_KEY` is absent, the process exits before Next.js server binds — container appears up, port never opens, NPM 502s immediately.

**Fix:** Generate the key and add it to vault, then add to the compose template.

```bash
# On Mac Mini — generate key
openssl rand -base64 32
```

```bash
# Add to vault
ansible-vault edit playbooks/vars/calcom_vault.yml
# Add: calendso_encryption_key: "<output>"
```

In `playbooks/templates/calcom/docker-compose.yml.j2`, ensure all required env vars are present:

| Variable | Value |
|---|---|
| `CALENDSO_ENCRYPTION_KEY` | `{{ calcom_encryption_key }}` — 32-byte base64, **unique** |
| `NEXTAUTH_SECRET` | `{{ calcom_nextauth_secret }}` — 32-byte base64, **different from above** |
| `NEXTAUTH_URL` | `https://cal.techsimple.dev` |
| `NEXT_PUBLIC_WEBAPP_URL` | `https://cal.techsimple.dev` |
| `DATABASE_URL` | `postgresql://calcom:{{ calcom_db_password }}@calcom-db:5432/calcom` |
| `DATABASE_DIRECT_URL` | `postgresql://calcom:{{ calcom_db_password }}@calcom-db:5432/calcom` |

> ⚠️ `NEXTAUTH_SECRET` and `CALENDSO_ENCRYPTION_KEY` must be **different values**. Do not reuse the same secret for both.

Redeploy after fixing:

```bash
ansible-playbook playbooks/calcom.yml -i inventory.yml --ask-vault-pass --become
```

---

### Issue 2 — Prisma Schema Requires `DATABASE_DIRECT_URL` → Migrations Fail

**Symptom:** Running `prisma migrate deploy` fails with:

```
Error: Environment variable not found: DATABASE_DIRECT_URL.
  -->  packages/prisma/schema.prisma:7
   |
 6 |   url       = env("DATABASE_URL")
 7 |   directUrl = env("DATABASE_DIRECT_URL")
```

**Cause:** Cal.com's Prisma schema declares `directUrl` for migration use. This var must be set even though it's the same value as `DATABASE_URL` in a non-pooled setup. Without it, `prisma migrate deploy` refuses to run and the schema is never applied.

**Fix — immediate (no redeploy):** Inject the var inline when running migrations:

```bash
docker exec -it \
  -e DATABASE_DIRECT_URL="postgresql://calcom:<calcom_db_password>@calcom-db:5432/calcom" \
  calcom \
  npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma
```

**Fix — permanent:** Add `DATABASE_DIRECT_URL` to the compose template (same value as `DATABASE_URL` — correct for direct Postgres without PgBouncer). See env var table in Issue 1 above.

---

### Issue 3 — `public.users` Table Does Not Exist → Prisma P2021 Error

**Symptom:** App starts (Next.js binds port 3000) but every request logs:

```
Error [PrismaClientKnownRequestError]:
Invalid `prisma.user.findFirst()` invocation:
The table `public.users` does not exist in the current database.
code: 'P2021'
```

**Cause:** The PostgreSQL database exists and is reachable, but Prisma migrations have never been applied. The schema is empty. This happened because the `CALENDSO_ENCRYPTION_KEY` crash on first boot prevented the entrypoint migration step from completing.

**Fix:** Run migrations manually inside the running container:

```bash
ssh -p 2222 bpainter@192.168.68.14

# If DATABASE_DIRECT_URL is now set in compose env:
docker exec -it calcom npx prisma migrate deploy \
  --schema /calcom/packages/prisma/schema.prisma

# If DATABASE_DIRECT_URL is NOT yet in compose env, inject it inline:
docker exec -it \
  -e DATABASE_DIRECT_URL="postgresql://calcom:<calcom_db_password>@calcom-db:5432/calcom" \
  calcom \
  npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma
```

Find the schema path if the above fails:

```bash
docker exec calcom find / -name "schema.prisma" 2>/dev/null | grep -v node_modules
```

**Verify migrations applied:**

```bash
docker exec -it calcom-db psql -U calcom -d calcom -c "\dt public.*" | head -30
```

Expected: full table list including `users`, `bookings`, `event_types`, `workflows`, etc. (~50+ tables).

**Prevent recurrence:** Add a `depends_on` healthcheck to the compose template so Cal.com waits for Postgres to be fully ready before starting — preventing the race that causes the entrypoint migration to be skipped:

```yaml
# On the calcom service
depends_on:
  calcom-db:
    condition: service_healthy

# On the calcom-db service
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U calcom -d calcom"]
  interval: 10s
  timeout: 5s
  retries: 5
```

---

## Step 1 — Verify the Cal.com Container Is Running (srv4)

SSH into srv4 and confirm the container is up and the port is bound.

```bash
ssh -p 2222 bpainter@192.168.68.14

# Check container status
docker ps --filter "name=cal" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

**Expected output:** Container shows `Up X hours` and port `3000/tcp` is listed.

If the container is restarting or exited:

```bash
# Check logs for startup errors
docker logs --tail 50 <cal_container_name>

# Check for database connection errors specifically
docker logs <cal_container_name> 2>&1 | grep -iE "error|fatal|postgres|connect"
```

> **Common cause:** Cal.com fails to start if `DATABASE_URL` is wrong, the PostgreSQL container isn't ready, or required env vars (`NEXTAUTH_SECRET`, `NEXTAUTH_URL`, `NEXT_PUBLIC_WEBAPP_URL`) are missing or incorrect.

---

## Step 2 — Verify Cal.com Responds Locally (srv4)

Confirm the app is actually serving HTTP — not just that the container is up.

```bash
# On srv4
curl -sv http://127.0.0.1:3000 2>&1 | head -30
```

**Expected:** HTTP 200 or 302 redirect. Any response (even a redirect) means the app is alive.

If `curl` hangs or returns `Connection refused`:

- The container is up but the Next.js server hasn't finished booting. Cal.com can take **60–120 seconds** on first start.
- Check logs for `Ready` or `started server` message:

```bash
docker logs <cal_container_name> 2>&1 | grep -iE "ready|started|listening|port"
```

Wait for the ready message, then retry `curl`.

---

## Step 3 — Verify Port Is Reachable from srv1 (Cross-Host)

From srv1, verify srv4:3000 is reachable across the LAN.

```bash
ssh -p 2222 bpainter@192.168.68.11

# TCP connectivity test
curl -sv http://192.168.68.14:3000 2>&1 | head -30

# Alternative if curl not available
nc -zv 192.168.68.14 3000
```

**Expected:** HTTP response or successful TCP connect.

If this fails but Step 2 passed, the issue is **network/firewall between srv1 and srv4**:

```bash
# On srv4 — check UFW rules
sudo ufw status numbered

# The hardening role should have allowed all LAN traffic, verify:
sudo ufw status | grep "192.168.68.0/24"
```

If the LAN allow-all rule is missing:

```bash
sudo ufw allow from 192.168.68.0/24 to any
sudo ufw reload
```

---

## Step 4 — Verify NPM Proxy Host Configuration (srv1 NPM UI)

Open the NPM admin UI at `http://192.168.68.11:81`.

1. Navigate to **Proxy Hosts**
2. Find the entry for `cal.techsimple.dev`
3. Verify:

| Field | Expected Value |
|---|---|
| Domain Names | `cal.techsimple.dev` |
| Scheme | `http` |
| Forward Hostname / IP | `192.168.68.14` |
| Forward Port | `3000` |
| SSL | **None** (Cloudflare terminates TLS, NPM handles HTTP only) |
| Websockets Support | **Enabled** (Cal.com requires WebSocket for real-time features) |
| Cache Assets | Disabled (for debugging) |

> **Critical:** If SSL is configured in NPM for this host, it will conflict with Cloudflare's tunnel (which sends plain HTTP to NPM). The tunnel target is `http://npm:80` — NPM must serve HTTP, not HTTPS.

Also verify NPM itself is healthy:

```bash
# On srv1
docker ps --filter "name=npm" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
docker logs npm --tail 30
```

---

## Step 5 — Verify Cloudflare Tunnel Is Active (srv1)

```bash
# On srv1 — check cloudflared container
docker ps --filter "name=cloudflared" --format "table {{.Names}}\t{{.Status}}"
docker logs cloudflared --tail 30 2>&1 | grep -iE "error|tunnel|connected|registered"
```

**Expected:** Logs show `Registered tunnel connection` or `Connected to Cloudflare edge`.

In the Cloudflare dashboard:
1. Go to **Zero Trust → Networks → Tunnels**
2. Find your tunnel — status should be **Healthy** (green)
3. Click the tunnel → **Public Hostname** tab
4. Verify the `cal.techsimple.dev` entry:

| Field | Expected Value |
|---|---|
| Subdomain | `cal` |
| Domain | `techsimple.dev` |
| Service | `http://npm:80` |
| Path | *(empty)* |

> **Note:** `npm` must resolve inside the cloudflared container's Docker network. Verify `cloudflared` and `npm` share the same Docker network on srv1.

```bash
# On srv1 — confirm both containers share a network
docker inspect cloudflared | grep -A 20 '"Networks"'
docker inspect npm | grep -A 20 '"Networks"'
```

Both must show the same network name (e.g., `proxy`). If they don't:

```bash
# Add cloudflared to the proxy network if missing
docker network connect proxy cloudflared
```

---

## Step 6 — Check NEXTAUTH_URL and NEXT_PUBLIC_WEBAPP_URL (srv4)

Cal.com uses Next.js authentication. If `NEXTAUTH_URL` doesn't match the public URL, auth redirects break and the app may return 500/502 errors.

```bash
# On srv4 — inspect running container env
docker inspect <cal_container_name> | grep -A 5 "NEXTAUTH_URL\|NEXT_PUBLIC_WEBAPP_URL\|DATABASE_URL"
```

**Expected values:**

| Variable | Expected |
|---|---|
| `NEXTAUTH_URL` | `https://cal.techsimple.dev` |
| `NEXT_PUBLIC_WEBAPP_URL` | `https://cal.techsimple.dev` |
| `DATABASE_URL` | `postgresql://calcom:<password>@<db_container>:5432/calcom` |

If any of these are wrong, correct them in your `docker-compose.yml.j2` template and redeploy:

```bash
# On Mac Mini
ansible-playbook playbooks/calcom.yml -i inventory.yml --ask-vault-pass --become
```

---

## Step 7 — End-to-End Test with Verbose curl (srv1)

Simulate the full tunnel path from srv1 to NPM to Cal.com:

```bash
# On srv1 — test with Host header matching what NPM expects
curl -sv -H "Host: cal.techsimple.dev" http://192.168.68.11:80 2>&1 | head -50
```

- **200/302** → NPM and Cal.com are working; issue is in Cloudflare tunnel routing
- **502** → NPM can't reach srv4:3000 (back to Steps 2–3)
- **503/404** → NPM host config mismatch (back to Step 4)

---

## Troubleshooting Table

| Symptom | Likely Cause | Fix |
|---|---|---|
| Cal.com container keeps restarting | Missing/wrong env vars, DB not ready | Check `docker logs`, fix env, add `depends_on` with healthcheck |
| `curl 127.0.0.1:3000` hangs on srv4 | App still booting | Wait 2 min, watch logs for "Ready" |
| `curl 192.168.68.14:3000` fails from srv1 | UFW blocking or port not bound to `0.0.0.0` | Check UFW LAN rule, check docker port binding |
| NPM shows 502 in its own logs | Can't reach `192.168.68.14:3000` | Repeat Steps 2–3 |
| NPM shows SSL handshake error | NPM SSL enabled when it shouldn't be | Disable SSL on NPM proxy host |
| Cloudflare tunnel shows unhealthy | cloudflared container down or token invalid | Restart container, verify token in vault |
| `cloudflared` can't reach `npm:80` | Not on same Docker network | `docker network connect proxy cloudflared` |
| Login loop / auth errors | `NEXTAUTH_URL` mismatch | Set to `https://cal.techsimple.dev` |
| Database connection refused | Wrong `DATABASE_URL` or PostgreSQL not running | Check DB container, verify connection string |
| `Error: Please set CALENDSO_ENCRYPTION_KEY` | Env var missing from compose | Generate with `openssl rand -base64 32`, vault it, add to template — see Known Issues §1 |
| `Environment variable not found: DATABASE_DIRECT_URL` | Missing from compose env | Add `DATABASE_DIRECT_URL` = same value as `DATABASE_URL` — see Known Issues §2 |
| `The table 'public.users' does not exist` (P2021) | Prisma migrations never ran | Run `docker exec ... prisma migrate deploy` manually — see Known Issues §3 |

---

## Rollback

If Cal.com is broken and you need to pull it from the tunnel quickly:

1. In Cloudflare Zero Trust dashboard → **Tunnels → Public Hostnames**
2. Delete or disable the `cal.techsimple.dev` entry
3. This immediately stops routing traffic to the broken service

To redeploy from scratch after fixing env vars:

```bash
# On srv4
cd /opt/stacks/cal
docker compose down -v   # WARNING: -v removes volumes including DB data unless using external volume
docker compose up -d

# Or via Ansible (preferred — preserves vault-injected config)
ansible-playbook playbooks/calcom.yml -i inventory.yml --ask-vault-pass --become
```

> ⚠️ Do **not** use `docker compose down -v` unless you intend to wipe the database. Omit `-v` for a soft restart.

---

## Maintenance Commands

```bash
# Tail Cal.com logs live
docker logs -f <cal_container_name>

# Restart Cal.com without destroying data
docker compose -f /opt/stacks/cal/docker-compose.yml restart

# Check all srv4 stack health
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -v "^NAMES"

# NPM access log (srv1)
docker exec npm cat /data/logs/proxy-host-*.log 2>/dev/null | tail -50

# Test DNS resolution for cal.techsimple.dev
dig cal.techsimple.dev +short
```
