# PPF Homelab — Claude Code Context

## Identity & Role

This is the Ansible automation and homelab infrastructure repository for the PPF (Painter Precision Financial) homelab. The operator is `bpainter`. Claude Code is used as a technical advisor and automation assistant across DevOps, infrastructure, and full-stack development tasks.

---

## Repository Structure

```
~/git/ansible/
├── ansible.cfg
├── ansible.sh                          # Interactive playbook runner (macOS)
├── migrate_vault.sh                    # One-time: split master vault into per-app vaults
├── inventory.yml                       # Hosts: farm (srv1,srv3-6), dev (dev1)
├── group_vars/
│   └── all/
│       ├── vars.yml
│       └── vault.yml                  # Global vault — SSH pubkeys only; auto-loaded by hardening role
├── host_vars/
│   └── srv1.yml
├── playbooks/
│   ├── ubuntu_pro.yml
│   ├── harden.yml
│   ├── setup_nginx.yml
│   ├── ufw.yml
│   │
│   ├── # ── Orchestrators (import_playbook thin wrappers) ──────────────────
│   ├── srv1_stacks.yml                # → cloudflared, npm, whoogle, adguardhome
│   ├── srv3_stacks.yml                # → metube, firefly, firefly-importer
│   ├── srv4_stacks.yml                # → n8n, calcom, espocrm
│   ├── srv5_stacks.yml                # → ollama, anythingllm
│   ├── srv6_stacks.yml                # infra play + → paperless, authentik, simple-office, omnimail
│   │
│   ├── # ── Individual app playbooks (fully standalone) ────────────────────
│   ├── cloudflared.yml                # srv1 — Cloudflare tunnel
│   ├── npm.yml                        # srv1 — Nginx Proxy Manager
│   ├── whoogle.yml                    # srv1 — Whoogle search
│   ├── adguardhome.yml                # srv1 — AdGuard Home DNS
│   ├── metube.yml                     # srv3 — MeTube
│   ├── firefly.yml                    # srv3 — PostgreSQL + Firefly III
│   ├── firefly-importer.yml           # srv3 — Firefly Importer (two-pass)
│   ├── n8n.yml                        # srv4 — postgres-n8n + n8n
│   ├── calcom.yml                     # srv4 — postgres-calcom + cal.com
│   ├── espocrm.yml                    # srv4 — postgres-espocrm + EspoCRM
│   ├── ollama.yml                     # srv5 — Ollama + NVMe + NVIDIA toolkit
│   ├── anythingllm.yml                # srv5 — AnythingLLM
│   ├── paperless.yml                  # srv6 — postgres-paperless + Paperless-ngx + AI/GPT
│   ├── authentik.yml                  # srv6 — postgres-authentik + Authentik SSO
│   ├── simple-office.yml              # srv6 — SO suite (two-pass)
│   ├── omnimail.yml                   # srv6 — OmniMail (build-from-source)
│   │
│   ├── vars/                          # Per-app vault files (encrypted with same password)
│   │   ├── app_versions.yml           # Pinned image versions (plaintext, NOT encrypted)
│   │   ├── cloudflared_vault.yml.example
│   │   ├── firefly_vault.yml.example
│   │   ├── n8n_vault.yml.example
│   │   ├── calcom_vault.yml.example
│   │   ├── espocrm_vault.yml.example
│   │   ├── anythingllm_vault.yml.example
│   │   ├── paperless_vault.yml.example
│   │   ├── authentik_vault.yml.example
│   │   ├── simple_office_vault.yml.example
│   │   └── omnimail_vault.yml.example
│   ├── tasks/
│   │   ├── deploy_stack.yml           # Generic reusable — NEVER rename
│   │   ├── free_port53.yml
│   │   ├── nvidia_toolkit.yml
│   │   ├── rsyslog_server.yml         # srv6 only — central log receiver
│   │   ├── nfs_server.yml             # srv6 only — NFS export setup
│   │   ├── nfs_client.yml             # srv1,3,4,5 — NFS mount + /opt/stacks symlink
│   │   ├── cockpit.yml
│   │   └── stacks_owner.yml
│   └── templates/                     # Jinja2 docker-compose templates per stack
└── roles/
    └── hardening/
        ├── tasks/
        │   ├── main.yml
        │   ├── 01_update.yml
        │   ├── 02_users.yml
        │   ├── 03_ssh.yml
        │   ├── 04_ufw.yml
        │   ├── 05_fail2ban.yml
        │   ├── 06_unattended_upgrades.yml
        │   ├── 07_rsyslog.yml
        │   ├── 08_cis_hardening.yml
        │   ├── 09_opt_stack.yml
        │   ├── 10_docker.yml
        │   ├── 11_logrotate.yml
        │   └── 12_verify.yml
        └── files/                     # Static config files deployed by hardening role
```

---

## Infrastructure

### Network
- **LAN subnet:** `192.168.68.0/24`
- **Primary workstation:** Mac Mini M4 at `192.168.68.54`
- **SSH port:** `2222` (all servers)
- **Admin users:** `bpainter` (primary), `docker-admin` (Docker operations)

### Server Inventory

| Host | IP | Role | Key Services |
|---|---|---|---|
| srv1 | 192.168.68.11 | Gateway / Proxy | cloudflared, NPM, Whoogle, AdGuard Home |
| srv3 | 192.168.68.13 | Finance | Firefly III, Firefly Importer, MeTube, PostgreSQL |
| srv4 | 192.168.68.14 | Productivity | n8n, Cal.com, EspoCRM, PostgreSQL (x3) |
| srv5 | 192.168.68.15 | AI / GPU | Ollama, AnythingLLM, NVIDIA GPU, NVMe at /mnt/nvme1 |
| srv6 | 192.168.68.16 | Storage / Services | OnlyOffice, FileBrowser, Paperless-ngx, OmniMail, rsyslog, NFS server, Cockpit |
| dev1 | 192.168.68.21 | Development | PPF Client Portal (Node/React/PostgreSQL) |

### Storage Architecture (srv6)
- **OS disk:** Samsung SSD 850 (sda) — Ubuntu root
- **Data volume:** 3x 3TB HDD (sdb, sdc, sdd) — LVM XFS, volume group `storage`, logical volume `data`
- **Mount point:** `/mnt/storage`
- **NFS exports:** `/mnt/storage/{srv1,srv3,srv4,srv5}` → each client mounts at `/mnt/storage`
- **Symlink:** `/opt/stacks` → `/mnt/storage/<hostname>/stacks` on all servers
- **Syslog storage:** `/mnt/storage/syslog/<hostname>/` — central rsyslog receiver

### Cloudflare / External Access
- **Domain:** `techsimple.dev`
- **Tunnel:** Cloudflare Zero Trust tunnel running on srv1 (cloudflared container)
- **SSL:** Terminates at Cloudflare edge — NPM handles internal HTTP routing only
- **Public hostnames configured in:** Cloudflare Zero Trust dashboard → Networks → Tunnels
- **Traffic flow:** `Browser → Cloudflare Edge (SSL) → cloudflared → NPM (srv1) → backend`

### Exposed Services

| Service | Internal | External |
|---|---|---|
| OnlyOffice CE | http://192.168.68.16:8084 | https://office-dev.techsimple.dev |
| FileBrowser Quantum | http://192.168.68.16:8085 | https://drive-dev.techsimple.dev |
| Paperless-ngx | http://192.168.68.16:8086 | https://paperless.techsimple.dev |
| OmniMail | http://192.168.68.16:8025 | https://mail.techsimple.dev |

---

## Hard Rules — Never Violate

1. **`docker compose`** — always V2, no hyphen, never `docker-compose`
2. **No `version:` attribute** in any `docker-compose.yml` or `.j2` template
3. **Never declare work complete** without actual testing or verification
4. **Vault variables** — never use `vault_` prefix, use direct names (e.g. `paperless_db_password`)
5. **Vault edits** — always use `ansible-vault edit`, never `encrypt_string` to append
6. **Per-app vaults** — app secrets live in `playbooks/vars/<app>_vault.yml`; only SSH pubkeys remain in `group_vars/all/vault.yml`. Load app vaults via `vars_files:` in each playbook.
7. **`deploy_stack.yml`** — never rename this file, it is referenced by all server playbooks
8. **`playbook_dir`** — always use in template `src:` paths within included tasks
9. **`sed -i` on macOS** — always `sed -i ''` (BSD sed requires empty extension argument)
10. **NFS server (srv6) must run before NFS client playbooks** — execution order is critical
11. **Hardening playbook must run before stack playbooks** on any new server
12. **No `:latest` image tags** — all images must be pinned to a specific version; versions live in `playbooks/vars/app_versions.yml`
13. **No `depends_on` across separate compose projects** — `depends_on` only resolves within the same compose project; cross-stack startup ordering is handled by `wait_for` tasks in Ansible

---

## Conventions & Patterns

### Docker Compose Templates
- Location: `playbooks/templates/<stack_name>/docker-compose.yml.j2`
- All use the `proxy` Docker network (external, bridge)
- Vault variables injected via Jinja2 `{{ var_name }}`
- No `version:` key — Docker Compose V2 spec

### PostgreSQL Pattern
- Separate container per app (consistent across srv3, srv4, srv6)
- Ports: srv3=5432, srv4=5433/5434/5435, srv6=5436(onlyoffice)/5437(paperless)
- Named volumes for data persistence
- `wait_for` task used between postgres and dependent app

### Stack Directory Ownership
- Owner: `root`, Group: `docker-admin`, Mode: `2775` (setgid)
- Enforced by `stacks_owner.yml` as a pre_task in every server playbook

### Two-Pass Deployment Pattern
Services requiring API tokens generated post-first-login (paperless-ai, paperless-gpt, firefly-importer):
1. Comment out dependent stacks, run playbook
2. Complete first-time setup, generate token, add to vault
3. Uncomment and re-run

### AppArmor
- rsyslogd on srv6 requires a local AppArmor override to write to `/mnt/storage/syslog`
- Override file: `/etc/apparmor.d/local/usr.sbin.rsyslogd`
- Managed by `rsyslog_server.yml`

---

## Hardening Role

CIS Ubuntu 24.04 L1 baseline. Key settings:
- SSH on port 2222, key auth only, no passwords
- UFW default deny inbound, allow all from `192.168.68.0/24`
- fail2ban with 3 retries, 86400s ban on SSH
- Unattended upgrades enabled, no auto-reboot
- AppArmor enabled
- SFTP subsystem enabled (required for Ansible file transfer)
- Unnecessary services disabled via `service_facts` check (not `ignore_errors`)
- AllowUsers: `bpainter docker-admin`

---

## Ansible Vault

Two vault layers, same password (`--ask-vault-pass` decrypts both):

| File | Type | Contents | Scope |
| --- | --- | --- | --- |
| `group_vars/all/vault.yml` | Encrypted | `bpainter_pubkey`, `docker_admin_pubkey` | Auto-loaded by hardening role |
| `playbooks/vars/<app>_vault.yml` | Encrypted | App-specific secrets | Loaded via `vars_files:` in each playbook |
| `playbooks/vars/app_versions.yml` | Plaintext | Pinned image versions for all stacks | Loaded via `vars_files:` in each playbook |

```bash
# Create a new per-app vault from template
cp playbooks/vars/cloudflared_vault.yml.example playbooks/vars/cloudflared_vault.yml
# Edit plaintext values, then encrypt
ansible-vault encrypt playbooks/vars/cloudflared_vault.yml

# Edit an existing vault
ansible-vault edit playbooks/vars/cloudflared_vault.yml

# Run playbook (decrypts both global and app vaults with one password)
ansible-playbook playbooks/<name>.yml -i inventory.yml --ask-vault-pass --become
```

Per-app vault files and their key variables:

| Vault file | Key variables |
|---|---|
| `cloudflared_vault.yml` | `cloudflared_tunnel_token` |
| `firefly_vault.yml` | `firefly_db_password`, `firefly_app_key`, `firefly_importer_token` |
| `n8n_vault.yml` | `n8n_db_password`, `n8n_encryption_key` |
| `calcom_vault.yml` | `calcom_db_password`, `calcom_nextauth_secret`, `calendso_encryption_key`, `calcom_google_client_id`, `calcom_google_client_secret` |
| `espocrm_vault.yml` | `espocrm_db_password`, `espocrm_admin_password` |
| `anythingllm_vault.yml` | `anythingllm_jwt_secret` |
| `paperless_vault.yml` | `paperless_db_password`, `paperless_secret_key`, `paperless_admin_password`, `paperless_api_token` |
| `authentik_vault.yml` | `authentik_db_password`, `authentik_secret_key` |
| `simple_office_vault.yml` | `so_db_password`, `so_jwt_secret`, `so_onlyoffice_jwt_secret`, `so_session_secret`, `so_oidc_client_id`, `so_oidc_client_secret`, `onlyoffice_db_password`, `onlyoffice_jwt_secret` |
| `omnimail_vault.yml` | `omnimail_db_password`, `omnimail_session_secret`, `omnimail_encryption_key`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_URI`, `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET`, `MICROSOFT_REDIRECT_URI`, `YAHOO_CLIENT_ID`, `YAHOO_CLIENT_SECRET`, `YAHOO_REDIRECT_URI` |

---

## Common Run Commands

```bash
# Interactive runner (recommended)
./ansible.sh

# Hardening (run before stack playbooks on new servers)
ansible-playbook playbooks/harden.yml -i inventory.yml --limit <host> --ask-vault-pass --become

# ── Orchestrators (deploy all stacks on a server) ─────────────────────────────
# Note: srv6 must be deployed before srv1/3/4/5 (NFS server dependency)
ansible-playbook playbooks/srv6_stacks.yml -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/srv1_stacks.yml -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/srv3_stacks.yml -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/srv4_stacks.yml -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/srv5_stacks.yml -i inventory.yml --ask-vault-pass --become

# ── Individual app playbooks (deploy one app) ─────────────────────────────────
ansible-playbook playbooks/cloudflared.yml   -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/npm.yml           -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/whoogle.yml       -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/adguardhome.yml   -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/metube.yml        -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/firefly.yml       -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/firefly-importer.yml -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/n8n.yml           -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/calcom.yml        -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/espocrm.yml       -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/ollama.yml        -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/anythingllm.yml   -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/paperless.yml     -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/authentik.yml     -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/simple-office.yml -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/omnimail.yml      -i inventory.yml --ask-vault-pass --become

# ── Tag-scoped runs ───────────────────────────────────────────────────────────
# Harden only specific tasks
ansible-playbook playbooks/harden.yml -i inventory.yml --tags rsyslog --ask-vault-pass --become
ansible-playbook playbooks/harden.yml -i inventory.yml --tags cis --ask-vault-pass --become
# Paperless pass 1 (skip AI/GPT requiring API token)
ansible-playbook playbooks/paperless.yml -i inventory.yml --ask-vault-pass --become --skip-tags ai,gpt
# Simple Office pass 1 (infrastructure only, before Authentik OIDC setup)
ansible-playbook playbooks/simple-office.yml -i inventory.yml --ask-vault-pass --become --tags infra

# ── Ad-hoc ────────────────────────────────────────────────────────────────────
# Fix ownership across all servers
ansible all -i inventory.yml -m shell \
  -a "chown -R root:docker-admin /opt/stacks && chmod -R 775 /opt/stacks" \
  --ask-vault-pass --become
```

---

## Ollama / AI

- **Ollama server:** srv5 at `192.168.68.15:11434`
- **Models stored:** `/mnt/nvme1/models`
- **Installed models:** `llama3.2`, `nomic-embed-text`
- **Point CLI at srv5:** `OLLAMA_HOST=http://192.168.68.15:11434 ollama <command>`
- **Claude Code via Ollama:** `OLLAMA_HOST=http://192.168.68.15:11434 ollama launch claude`
- **Requires Ollama v0.15+** for `ollama launch` command
- **Minimum context for Claude Code:** 64k tokens

---

## Pending / Known Issues

- [ ] firefly-importer on srv3 — waiting for Firefly III first login to generate API token; run `firefly-importer.yml` after token is added to `firefly_vault.yml`
- [ ] paperless-ai and paperless-gpt on srv6 — waiting for Paperless-ngx API token; run `paperless.yml` without `--skip-tags ai,gpt` after token added to `paperless_vault.yml`
- [ ] simple-office.yml pass 2 — waiting for Authentik OIDC client setup; add `so_oidc_client_id` / `so_oidc_client_secret` to `simple_office_vault.yml` then re-run
- [ ] Per-app vault files need to be created from `.example` templates and encrypted for each server
- [ ] srv6 FileBrowser Quantum — admin password reset may be needed (env var ignored after DB init)
- [ ] srv6 OnlyOffice + FileBrowser integration — config.yaml not yet configured
- [ ] NFS client mounts on srv1, srv3, srv4, srv5 — verify all are active post-setup
