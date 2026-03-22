# PPF Homelab — Ansible Infrastructure

Self-hosted homelab automation for Painter Precision Financial (PPF). This repository contains all Ansible playbooks, templates, and tooling needed to provision, configure, and maintain the full server fleet from a macOS control machine.

> **Rebuild guarantee:** Following this document top to bottom will produce a fully functional environment from bare metal.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Initial Setup — Full Rebuild](#initial-setup--full-rebuild)
4. [Deployment Sequence](#deployment-sequence)
5. [Administration](#administration)
6. [Scheduled Maintenance](#scheduled-maintenance)
7. [Configuration](#configuration)
8. [Exposed Services](#exposed-services)
9. [Troubleshooting](#troubleshooting)

---

## Architecture

### Network

| Item | Value |
|---|---|
| LAN subnet | `192.168.68.0/24` |
| Control machine | Mac Mini M4 — `192.168.68.54` |
| SSH port | `2222` (all servers) |
| Domain | `techsimple.dev` |
| External access | Cloudflare Zero Trust tunnel → NPM (srv1) → backend |

### Server Inventory

| Host | IP | Role | Key Services |
|---|---|---|---|
| srv1 | 192.168.68.11 | Gateway / Proxy | Cloudflared tunnel, Nginx Proxy Manager, Whoogle, AdGuard Home |
| srv3 | 192.168.68.13 | Finance | Firefly III, Firefly Importer, MeTube |
| srv4 | 192.168.68.14 | Productivity | n8n, Cal.com, EspoCRM |
| srv5 | 192.168.68.15 | AI / GPU | Ollama, AnythingLLM, NVIDIA GPU |
| srv6 | 192.168.68.16 | Storage / Services | Paperless-ngx, Authentik, Simple Office, OmniMail, NFS server, rsyslog, Cockpit |
| dev1 | 192.168.68.21 | Development | PPF Client Portal |

### Storage Architecture (srv6)

| Item | Detail |
|---|---|
| OS disk | Samsung SSD 850 (sda) — Ubuntu root |
| Data volume | 3× 3TB HDD (sdb, sdc, sdd) — LVM XFS, VG `storage`, LV `data` |
| Mount point | `/mnt/storage` |
| NFS exports | `/mnt/storage/{srv1,srv3,srv4,srv5}` → each client mounts at `/mnt/storage` |
| Stack symlink | `/opt/stacks` → `/mnt/storage/<hostname>/stacks` on all servers |
| Syslog storage | `/mnt/storage/syslog/<hostname>/` — central rsyslog receiver |

### Traffic Flow

```
Browser
  ↓
Cloudflare Edge  (TLS termination)
  ↓  Zero Trust tunnel
cloudflared container  (srv1)
  ↓  Docker proxy network
NPM container  (srv1)
  ↓  HTTP proxy host rules
Backend service  (srv1–6)
```

All tunnel public hostnames point to `http://npm:80`. NPM routes by hostname to the correct backend IP and port. SSL terminates at Cloudflare — NPM handles plain HTTP internally.

---

## Prerequisites

### Control Machine (Mac Mini M4)

```bash
# Ansible
pip3 install ansible

# Required collections
ansible-galaxy collection install community.docker ansible.posix community.general

# Verify
ansible --version
ansible-galaxy collection list | grep -E "community.docker|ansible.posix|community.general"
```

### External Accounts Required

| Account | Used For |
|---|---|
| Cloudflare (Zero Trust) | Tunnel token and public hostname routing |
| Google Cloud Console | Cal.com Google Calendar OAuth, OmniMail Gmail OAuth |
| Microsoft Azure AD | OmniMail Outlook/Exchange OAuth |
| Yahoo Developer | OmniMail Yahoo Mail OAuth |

### SSH Access

All servers must be reachable from the control machine on port 22 (pre-hardening) or 2222 (post-hardening) with key-based authentication as `bpainter`.

```bash
# Test connectivity before running any playbook
ansible all -i inventory.yml -m ping --ask-vault-pass
```

---

## Initial Setup — Full Rebuild

Follow these steps in order. **Do not skip phases.**

---

### Phase 1 — Vault Setup

All secrets are stored in Ansible Vault. Two layers exist:

| File | Type | Contents |
|---|---|---|
| `group_vars/all/vault.yml` | Encrypted | SSH public keys for `bpainter` and `docker-admin` |
| `playbooks/vars/<app>_vault.yml` | Encrypted | App-specific secrets |
| `playbooks/vars/app_versions.yml` | Plaintext | Pinned image versions |

#### 1a. Create or restore the global vault

The global vault contains only SSH public keys and is auto-loaded by the hardening role.

```bash
# If rebuilding from backup, restore group_vars/all/vault.yml as-is.
# If creating from scratch:
ansible-vault create group_vars/all/vault.yml
# Add:
#   bpainter_pubkey: "<contents of ~/.ssh/id_ed25519.pub>"
#   docker_admin_pubkey: "<contents of docker-admin public key>"
```

#### 1b. Create per-app vault files

Use the migration script if the master vault already contains all secrets:

```bash
./migrate_vault.sh --dry-run   # preview — verify all vars found, no REPLACE_ME
./migrate_vault.sh             # execute — creates and encrypts all per-app vaults
```

To create manually from scratch, copy each example and populate with real values:

```bash
cp playbooks/vars/cloudflared_vault.yml.example playbooks/vars/cloudflared_vault.yml
# ... repeat for each app ...
# Then encrypt:
ansible-vault encrypt playbooks/vars/cloudflared_vault.yml
# ... repeat for each vault file ...
```

Required secrets per vault:

| Vault file | Variables |
|---|---|
| `cloudflared_vault.yml` | `cloudflared_tunnel_token` — from Cloudflare Zero Trust dashboard |
| `firefly_vault.yml` | `firefly_db_password`, `firefly_app_key` (32 chars), `firefly_importer_token` (pass 2) |
| `n8n_vault.yml` | `n8n_db_password`, `n8n_encryption_key` |
| `calcom_vault.yml` | `calcom_db_password`, `calcom_nextauth_secret`, `calendso_encryption_key`, `calcom_google_client_id`, `calcom_google_client_secret` |
| `espocrm_vault.yml` | `espocrm_db_password`, `espocrm_admin_password` |
| `anythingllm_vault.yml` | `anythingllm_jwt_secret` |
| `paperless_vault.yml` | `paperless_db_password`, `paperless_secret_key`, `paperless_admin_password`, `paperless_api_token` (pass 2) |
| `authentik_vault.yml` | `authentik_db_password`, `authentik_secret_key` |
| `simple_office_vault.yml` | `so_db_password`, `so_jwt_secret`, `so_onlyoffice_jwt_secret`, `so_session_secret`, `onlyoffice_db_password`, `onlyoffice_jwt_secret`, `so_oidc_client_id` (pass 2), `so_oidc_client_secret` (pass 2) |
| `omnimail_vault.yml` | `omnimail_db_password`, `omnimail_session_secret`, `omnimail_encryption_key`, OAuth client IDs and secrets for Google/Microsoft/Yahoo |

Generate secrets where needed:

```bash
openssl rand -hex 32    # for passwords, secret keys, encryption keys
openssl rand -base64 32 # for nextauth secrets, app keys
```

#### 1c. Pin image versions

```bash
# Check current stable releases for all apps
python3 version_query.py -t <github_token>

# Edit and fill in all versions
vi playbooks/vars/app_versions.yml

# Verify no REPLACE_ME remains
grep REPLACE_ME playbooks/vars/app_versions.yml
```

---

### Phase 2 — Server Hardening

The hardening role applies a CIS Ubuntu 24.04 L1 baseline: SSH on port 2222, key auth only, UFW default deny, fail2ban, AppArmor, unattended upgrades.

Run hardening on each server before any stack playbook. **srv6 first** — all other servers depend on its NFS exports.

```bash
# srv6 first
ansible-playbook playbooks/harden.yml -i inventory.yml --limit srv6 --ask-vault-pass --become

# Then the rest (order within this group does not matter)
ansible-playbook playbooks/harden.yml -i inventory.yml --limit srv1 --ask-vault-pass --become
ansible-playbook playbooks/harden.yml -i inventory.yml --limit srv3 --ask-vault-pass --become
ansible-playbook playbooks/harden.yml -i inventory.yml --limit srv4 --ask-vault-pass --become
ansible-playbook playbooks/harden.yml -i inventory.yml --limit srv5 --ask-vault-pass --become
```

> Hardening moves SSH from port 22 to 2222. After the first run completes, all subsequent connections use port 2222 (already configured in `inventory.yml`).

---

### Phase 3 — Ubuntu Pro (optional)

Attaches Ubuntu Pro for ESM security updates:

```bash
ansible-playbook playbooks/ubuntu_pro.yml -i inventory.yml --ask-vault-pass --become
```

---

## Deployment Sequence

> **Critical:** srv6 must be deployed before srv1, srv3, srv4, and srv5. It is the NFS server that all other servers mount `/opt/stacks` from. Deploying clients before the server will fail.

### Pass 1 — Core stacks

```bash
# 1. srv6 — NFS server + core apps (skip AI/GPT and Simple Office API/Web until pass 2)
ansible-playbook playbooks/srv6_stacks.yml -i inventory.yml --ask-vault-pass --become \
  --skip-tags ai,gpt   # skip paperless-ai/gpt until API token is generated
# Note: simple-office.yml will deploy infra only (pass 1) — so_oidc vars not required yet

# 2. srv1 — Tunnel + reverse proxy + utilities
ansible-playbook playbooks/srv1_stacks.yml -i inventory.yml --ask-vault-pass --become

# 3. srv3 — Finance apps (firefly-importer skipped until API token generated)
ansible-playbook playbooks/firefly.yml   -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/metube.yml    -i inventory.yml --ask-vault-pass --become

# 4. srv4 — Productivity apps
ansible-playbook playbooks/srv4_stacks.yml -i inventory.yml --ask-vault-pass --become

# 5. srv5 — AI / GPU (ollama must deploy before anythingllm)
ansible-playbook playbooks/srv5_stacks.yml -i inventory.yml --ask-vault-pass --become
```

### Pass 2 — Token-dependent deployments

These require manual steps between passes to generate API tokens or OAuth credentials from running services.

#### 2a. Firefly Importer (srv3)

```bash
# 1. Log in to Firefly III — see Configuration > Firefly III
# 2. Generate a Personal Access Token:
#    Profile → OAuth → Personal Access Tokens → Create New Token
# 3. Add the token to the vault:
ansible-vault edit playbooks/vars/firefly_vault.yml
#    Set: firefly_importer_token: "<token>"
# 4. Deploy:
ansible-playbook playbooks/firefly-importer.yml -i inventory.yml --ask-vault-pass --become
```

#### 2b. Paperless AI + GPT (srv6)

```bash
# 1. Log in to Paperless-ngx — see Configuration > Paperless-ngx
# 2. Copy the API token:
#    Profile icon (top right) → My Profile → API Token
# 3. Add to vault:
ansible-vault edit playbooks/vars/paperless_vault.yml
#    Set: paperless_api_token: "<token>"
# 4. Deploy all tasks including AI/GPT:
ansible-playbook playbooks/paperless.yml -i inventory.yml --ask-vault-pass --become
```

#### 2c. Simple Office — full stack (srv6)

```bash
# 1. Complete Authentik initial setup — see Configuration > Authentik
# 2. Create the OIDC provider in Authentik — see Configuration > Simple Office
# 3. Add OIDC credentials to vault:
ansible-vault edit playbooks/vars/simple_office_vault.yml
#    Set: so_oidc_client_id: "<client id>"
#         so_oidc_client_secret: "<client secret>"
# 4. Deploy full stack (no tag filter):
ansible-playbook playbooks/simple-office.yml -i inventory.yml --ask-vault-pass --become
```

---

## Administration

### Interactive Playbook Runner

The recommended way to run playbooks interactively. Presents a menu of available playbooks, prompts for vault password, tag selection, and target host.

```bash
./ansible.sh
```

Walks through:
1. Playbook selection
2. Vault password (stored securely in a temp file, wiped on exit)
3. Tag selection (populated from the chosen playbook)
4. Target host selection
5. Confirmation before execution

### Vault Management

```bash
# View a vault file
ansible-vault view playbooks/vars/<app>_vault.yml

# Edit a vault file (always use edit — never decrypt + re-encrypt manually)
ansible-vault edit playbooks/vars/<app>_vault.yml

# Verify all per-app vaults exist and are encrypted
head -1 playbooks/vars/*.yml
# Every file should start with: $ANSIBLE_VAULT;1.1;AES256
```

> **Rule:** Never use `ansible-vault encrypt_string` to add individual variables. Always use `ansible-vault edit` to open and modify the full file.

### Upgrading App Versions

```bash
# 1. Check for available updates
python3 version_query.py -t <github_token>

# The Pinned column shows the recommended version to set:
#   GREEN  — app_versions.yml already matches recommendation
#   RED    — app_versions.yml needs to be updated to this value
#   ⚠      — latest release is ≤ 30 days old; Pinned shows previous stable as safer pin

# 2. Update versions in app_versions.yml
ansible-vault edit playbooks/vars/app_versions.yml   # not a vault but follows same pattern
vi playbooks/vars/app_versions.yml

# 3. Re-run the affected playbook — Docker will pull the new image and recreate the container
ansible-playbook playbooks/<app>.yml -i inventory.yml --ask-vault-pass --become
```

The `deploy_stack.yml` task handles the full upgrade cycle automatically:
1. Renders the updated `docker-compose.yml` with the new version tag
2. Runs `docker compose pull` (only when compose file changed)
3. Runs `docker compose up --detach --remove-orphans` — Docker recreates the container if the image changed

### Migrating the Master Vault to Per-App Vaults

If all secrets are consolidated in `group_vars/all/vault.yml` and need to be split into per-app files:

```bash
./migrate_vault.sh --dry-run   # preview — shows what will be created, flags missing vars
./migrate_vault.sh             # execute — creates and encrypts all per-app vault files
```

After migration, edit `group_vars/all/vault.yml` and remove all app secrets. Only `bpainter_pubkey` and `docker_admin_pubkey` should remain.

### Re-running UFW Rules

```bash
# All servers
ansible-playbook playbooks/ufw.yml -i inventory.yml --ask-vault-pass --become

# Single server
ansible-playbook playbooks/ufw.yml -i inventory.yml --limit srv1 --ask-vault-pass --become
```

### Hardening Tag-Scoped Runs

```bash
# Re-apply only SSH config
ansible-playbook playbooks/harden.yml -i inventory.yml --tags ssh --ask-vault-pass --become

# Re-apply only CIS hardening
ansible-playbook playbooks/harden.yml -i inventory.yml --tags cis --ask-vault-pass --become

# Re-apply only rsyslog
ansible-playbook playbooks/harden.yml -i inventory.yml --tags rsyslog --ask-vault-pass --become
```

### Verifying Stack Health

```bash
# Check all running containers on a server
ansible srv6 -i inventory.yml -m shell \
  -a "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" \
  --ask-vault-pass --become

# Check across all servers
ansible farm -i inventory.yml -m shell \
  -a "docker ps --format '{{.Names}}\t{{.Image}}'" \
  --ask-vault-pass --become

# Fix stack ownership if permissions drift
ansible all -i inventory.yml -m shell \
  -a "chown -R root:docker-admin /opt/stacks && chmod -R 775 /opt/stacks" \
  --ask-vault-pass --become
```

---

## Scheduled Maintenance

| Task | Frequency | Command |
|---|---|---|
| Version check | Weekly | `python3 version_query.py -t <token>` |
| Cloudflare IP range update | Monthly | `python3 scripts/update_cloudflare_ips.py --vault-password-file ~/.ansible-vault-pass` |
| Unattended security upgrades | Daily (automatic) | Handled by `unattended-upgrades` service on all servers |
| Log rotation | Daily (automatic) | Handled by `logrotate` on all servers |

### Cloudflare IP Range Update

Cloudflare periodically changes its published IPv4 ranges. The UFW allowlist on srv1 (port 443) must stay current. The update script fetches the current list from Cloudflare, updates `group_vars/all/vars.yml`, commits the change, and re-runs the UFW playbook against srv1.

```bash
# Run manually
python3 scripts/update_cloudflare_ips.py --vault-password-file ~/.ansible-vault-pass

# Recommended cron entry (on the control machine — Mac Mini M4)
# Run at 09:00 on the first day of each month
0 9 1 * * cd ~/git/ansible && python3 scripts/update_cloudflare_ips.py \
  --vault-password-file ~/.ansible-vault-pass >> ~/logs/cloudflare-ip-update.log 2>&1
```

### Idempotency Check

After any version upgrades or config changes, verify all orchestrators are idempotent (no unintended drift):

```bash
ansible-playbook playbooks/srv6_stacks.yml -i inventory.yml --ask-vault-pass --become
# All tasks should report ok or changed only for the intended update. changed=0 means no drift.
```

---

## Configuration

Post-deploy manual configuration steps required to make each application fully functional. These steps are one-time unless the environment is rebuilt.

---

### Cloudflare Zero Trust Tunnel

The tunnel connects the homelab to the internet. All external traffic flows through it.

**Create the tunnel:**
1. Log in to [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com)
2. **Networks → Tunnels → Create a tunnel**
3. Name: `ppf-homelab`
4. Copy the tunnel token — add it to vault:
   ```bash
   ansible-vault edit playbooks/vars/cloudflared_vault.yml
   # Set: cloudflared_tunnel_token: "<token>"
   ```
5. Deploy: `ansible-playbook playbooks/cloudflared.yml -i inventory.yml --ask-vault-pass --become`

**Configure public hostnames** (after NPM is running):

Navigate to **Networks → Tunnels → ppf-homelab → Public Hostnames** and add one entry per exposed service. All entries use the same service target: `http://npm:80` — NPM routes internally by hostname.

| Subdomain | Domain | Service |
|---|---|---|
| `paperless` | `techsimple.dev` | `http://npm:80` |
| `auth` | `techsimple.dev` | `http://npm:80` |
| `mail` | `techsimple.dev` | `http://npm:80` |
| `app` | `techsimple.dev` | `http://npm:80` |
| `cal` | `techsimple.dev` | `http://npm:80` |
| `crm` | `techsimple.dev` | `http://npm:80` |
| `office-dev` | `techsimple.dev` | `http://npm:80` |
| `drive-dev` | `techsimple.dev` | `http://npm:80` |

> `npm` resolves because cloudflared and NPM share the `proxy` Docker network on srv1.

---

### Nginx Proxy Manager (NPM)

NPM handles internal routing from the tunnel to backend services.

**First login:**
- URL: `http://192.168.68.11:81`
- Default credentials: `admin@example.com` / `changeme`
- **Change the password immediately** after first login

**Add a proxy host** (repeat for each service below):
1. **Hosts → Proxy Hosts → Add Proxy Host**
2. **Domain Names:** `<subdomain>.techsimple.dev`
3. **Scheme:** `http`
4. **Forward Hostname/IP:** backend IP (see table)
5. **Forward Port:** backend port (see table)
6. **SSL:** None (Cloudflare terminates TLS)
7. **Websockets Support:** Enable for Cal.com, n8n, AnythingLLM

| Domain | Forward IP | Forward Port | Websockets |
|---|---|---|---|
| `paperless.techsimple.dev` | `192.168.68.16` | `8086` | No |
| `auth.techsimple.dev` | `192.168.68.16` | `9000` | No |
| `mail.techsimple.dev` | `192.168.68.16` | `8025` | No |
| `app.techsimple.dev` | `192.168.68.16` | `8091` | Yes |
| `cal.techsimple.dev` | `192.168.68.14` | `3000` | Yes |
| `crm.techsimple.dev` | `192.168.68.14` | `8083` | No |
| `office-dev.techsimple.dev` | `192.168.68.16` | `8084` | No |
| `drive-dev.techsimple.dev` | `192.168.68.16` | `8085` | No |

---

### AdGuard Home

Runs on srv1 and acts as the LAN DNS resolver. Port 53 is freed from `systemd-resolved` automatically by the playbook.

**First-time setup:**
1. Navigate to `http://192.168.68.11:3000` — the setup wizard starts automatically
2. Set the admin interface to port `3001` (port `3000` may conflict)
3. Set DNS listen address to `0.0.0.0:53`
4. Create admin credentials

**Configure LAN DNS:**
- Set your router's DHCP DNS server to `192.168.68.11`
- All LAN clients will now use AdGuard Home for DNS with ad/tracker blocking

**Recommended upstream DNS:**
- `https://dns.quad9.net/dns-query` (DoH)
- `https://dns.cloudflare.com/dns-query` (DoH fallback)

---

### Whoogle

Private Google search proxy. No configuration required — accessible immediately after deploy.

- LAN: `http://192.168.68.11:5000`

---

### Firefly III

Personal finance manager on srv3.

**First login:**
1. Navigate to `http://192.168.68.13:8080` (or via NPM proxy if configured)
2. Create the initial admin account

**Generate API token for Firefly Importer:**
1. Top-right profile menu → **Profile**
2. **OAuth** tab → **Personal Access Tokens** → **Create New Token**
3. Name: `firefly-importer`
4. Copy the token — it is shown only once
5. Add to vault and run pass 2 (see [Deployment Sequence — Pass 2a](#2a-firefly-importer-srv3))

---

### Firefly Importer

Imports bank transactions into Firefly III via CSV/CAMT/OFX.

- Requires `firefly_importer_token` in vault (generated after Firefly III first login)
- Access: `http://192.168.68.13:8082`
- On first use, configure the import profile pointing to your Firefly III instance

---

### n8n

Workflow automation platform on srv4. LAN access only — not exposed externally.

**First login:**
1. Navigate to `http://192.168.68.14:5678`
2. Create the admin account (email + password)

---

### Cal.com

Open-source scheduling platform on srv4.

**First login:**
1. Navigate to `https://cal.techsimple.dev`
2. Complete the initial setup wizard (name, email, password, timezone)

**Google Calendar OAuth (optional):**

Cal.com requires a Google Cloud OAuth app to sync with Google Calendar.

1. [Google Cloud Console](https://console.cloud.google.com) → **APIs & Services → Credentials → Create OAuth Client ID**
2. Type: **Web application**
3. Authorized redirect URI: `https://cal.techsimple.dev/api/integrations/googlecalendar/callback`
4. Copy **Client ID** and **Client Secret** into vault:
   ```bash
   ansible-vault edit playbooks/vars/calcom_vault.yml
   # Set: calcom_google_client_id: "<id>"
   #      calcom_google_client_secret: "<secret>"
   ```
5. Redeploy: `ansible-playbook playbooks/calcom.yml -i inventory.yml --ask-vault-pass --become`
6. In Cal.com: **Settings → Integrations → Google Calendar → Connect**

> See `docs/CALCOM_TROUBLESHOOTING.md` for known deployment issues and fixes.

---

### EspoCRM

Open-source CRM on srv4.

**First login:**
1. Navigate to `https://crm.techsimple.dev`
2. Login with credentials from `espocrm_vault.yml` → `espocrm_admin_password`
3. Complete the setup wizard (company name, timezone, currency)

The PostgreSQL `config-internal.php` injection is handled automatically by the playbook — no manual DB configuration required.

---

### Ollama

LLM inference server on srv5, backed by an NVMe drive.

**Pull required models after deploy:**

```bash
# From the control machine, point the CLI at srv5
export OLLAMA_HOST=http://192.168.68.15:11434

# Pull models used by Paperless AI and AnythingLLM
ollama pull llama3.2
ollama pull nomic-embed-text

# Verify
ollama list
```

**Models are stored at** `/mnt/nvme1/models` on srv5 (NVMe partition, not the OS disk).

---

### AnythingLLM

Document chat and AI workspace on srv5.

**First-time setup:**
1. Navigate to `http://192.168.68.15:3001` (or via NPM if exposed)
2. Complete the initial setup wizard
3. **LLM Provider:** Ollama
4. **Ollama Base URL:** `http://192.168.68.15:11434`
5. **Default Model:** `llama3.2`
6. **Embedding Model:** `nomic-embed-text`

---

### Paperless-ngx

Document management system on srv6.

**First login:**
1. Navigate to `https://paperless.techsimple.dev`
2. Login: username `admin`, password from `paperless_vault.yml` → `paperless_admin_password`

**Generate API token (required for Paperless-AI and Paperless-GPT):**
1. Top-right profile icon → **My Profile**
2. Copy the **API Token** (generated automatically on first login)
3. Add to vault and run pass 2 (see [Deployment Sequence — Pass 2b](#2b-paperless-ai--gpt-srv6))

**Document ingestion:**
- Drop files into `/opt/stacks/paperless/consume` on srv6 — Paperless picks them up automatically
- Or use the web UI upload

---

### Authentik

SSO Identity Provider on srv6. Required before Simple Office can complete its full deployment.

**Initial setup:**
1. Navigate to `https://auth.techsimple.dev/if/flow/initial-setup/`
2. Create the initial admin account (email + password)
3. Log in to the Admin Interface: `https://auth.techsimple.dev/if/admin/`

**Create OIDC provider for Simple Office:**
1. **Admin → Applications → Providers → Create**
2. Type: **OAuth2/OpenID Provider**
3. Name: `simple-office`
4. **Authorization flow:** `default-provider-authorization-implicit-consent`
5. **Redirect URI:** `https://app.techsimple.dev/api/v1/auth/callback`
6. Note the **Client ID** and **Client Secret** shown after saving
7. **Admin → Applications → Applications → Create**
   - Name: `Simple Office`
   - Slug: `simple-office`
   - Provider: `simple-office`

Then add the credentials to vault and run Simple Office pass 2 (see [Deployment Sequence — Pass 2c](#2c-simple-office--full-stack-srv6)).

---

### Simple Office

Internal office suite combining OnlyOffice document editing with a custom React frontend, backed by Authentik SSO.

**Pass 1** deploys the infrastructure (PostgreSQL, Redis, OnlyOffice) without the API and web containers.

**Pass 2** completes the deployment after Authentik OIDC credentials are in the vault.

**Post-deploy verification:**
- SO Web: `https://app.techsimple.dev`
- SO API: `http://192.168.68.16:8090/health`
- OnlyOffice (LAN only): `http://192.168.68.16:8092`

---

### OmniMail

Self-hosted webmail client on srv6. Built from source via `docker compose up --build`.

**Source sync:** The `omnimail` repository must exist as a sibling of this repo on the control machine at `~/git/omnimail`. The playbook rsyncs it to srv6 — no internet access required on srv6 at deploy time.

```
~/git/
├── ansible/          ← this repo
└── omnimail/         ← must exist on control machine
```

**OAuth provider setup:**

OmniMail supports Google, Microsoft, and Yahoo mail accounts via OAuth. Create an OAuth app in each provider's developer console and add the credentials to `omnimail_vault.yml`.

*Google:*
1. [Google Cloud Console](https://console.cloud.google.com) → **APIs & Services → Credentials → Create OAuth Client ID**
2. Type: **Web application**
3. Authorized redirect URI: value of `GOOGLE_REDIRECT_URI` in vault
4. Copy **Client ID** and **Client Secret** → `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` in vault

*Microsoft:*
1. [Azure Portal](https://portal.azure.com) → **Azure Active Directory → App Registrations → New Registration**
2. Redirect URI: value of `MICROSOFT_REDIRECT_URI` in vault
3. Copy **Application (client) ID** and create a **Client Secret** → `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET`

*Yahoo:*
1. [Yahoo Developer Console](https://developer.yahoo.com/apps/) → **Create an App**
2. Redirect URI: value of `YAHOO_REDIRECT_URI` in vault
3. Copy **Client ID** and **Client Secret** → `YAHOO_CLIENT_ID`, `YAHOO_CLIENT_SECRET`

After all credentials are in the vault, redeploy:
```bash
ansible-playbook playbooks/omnimail.yml -i inventory.yml --ask-vault-pass --become
```

Access: `https://mail.techsimple.dev`

---

## Exposed Services

| Service | Internal URL | External URL |
|---|---|---|
| Nginx Proxy Manager | `http://192.168.68.11:81` | LAN only |
| AdGuard Home | `http://192.168.68.11:3001` | LAN only |
| Whoogle | `http://192.168.68.11:5000` | LAN only |
| Firefly III | `http://192.168.68.13:8080` | LAN only |
| Firefly Importer | `http://192.168.68.13:8082` | LAN only |
| n8n | `http://192.168.68.14:5678` | LAN only |
| Cal.com | `http://192.168.68.14:3000` | `https://cal.techsimple.dev` |
| EspoCRM | `http://192.168.68.14:8083` | `https://crm.techsimple.dev` |
| Ollama API | `http://192.168.68.15:11434` | LAN only |
| AnythingLLM | `http://192.168.68.15:3001` | LAN only |
| Paperless-ngx | `http://192.168.68.16:8086` | `https://paperless.techsimple.dev` |
| Authentik | `http://192.168.68.16:9000` | `https://auth.techsimple.dev` |
| Simple Office Web | `http://192.168.68.16:8091` | `https://app.techsimple.dev` |
| OnlyOffice (LAN only) | `http://192.168.68.16:8092` | LAN only |
| OmniMail | `http://192.168.68.16:8025` | `https://mail.techsimple.dev` |
| OnlyOffice CE | `http://192.168.68.16:8084` | `https://office-dev.techsimple.dev` |
| FileBrowser Quantum | `http://192.168.68.16:8085` | `https://drive-dev.techsimple.dev` |
| Cockpit | `http://192.168.68.16:9090` | LAN only |

---

## Troubleshooting

| Document | Contents |
|---|---|
| `docs/CALCOM_TROUBLESHOOTING.md` | Cal.com 502 diagnosis, Prisma migration issues, Google OAuth setup |
| `docs/UFW.md` | Firewall architecture, how to add/remove rules, Cloudflare IP management |

**Common checks:**

```bash
# Is a container running and healthy?
ssh -p 2222 bpainter@<server_ip>
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Container logs
docker logs --tail 50 <container_name>
docker logs -f <container_name>   # follow

# Is an NFS mount active?
mountpoint -q /mnt/storage && echo "mounted" || echo "NOT mounted"

# Cloudflare tunnel status
docker logs cloudflared 2>&1 | grep -iE "connected|registered|error" | tail -10

# Syntax-check all playbooks
for pb in playbooks/*.yml; do
  ansible-playbook "${pb}" --syntax-check -i inventory.yml --ask-vault-pass
done
```
