# PPF Homelab — Claude Code Context

## Identity & Role

This is the Ansible automation and homelab infrastructure repository for the PPF (Painter Precision Financial) homelab. The operator is `bpainter`. Claude Code is used as a technical advisor and automation assistant across DevOps, infrastructure, and full-stack development tasks.

---

## Repository Structure

```
~/git/ansible/
├── ansible.cfg
├── ansible.sh                          # Interactive playbook runner (macOS)
├── inventory.yml                       # Hosts: farm (srv1,srv3-6), dev (dev1)
├── group_vars/
│   └── all/
│       ├── vars.yml
│       └── vault.yml                  # Ansible Vault — auto-loaded, never commit plaintext
├── host_vars/
│   └── srv1.yml
├── playbooks/
│   ├── ubuntu_pro.yml
│   ├── harden.yml
│   ├── srv1_stacks.yml
│   ├── srv3_stacks.yml
│   ├── srv4_stacks.yml
│   ├── srv5_stacks.yml
│   ├── srv6_stacks.yml
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

---

## Hard Rules — Never Violate

1. **`docker compose`** — always V2, no hyphen, never `docker-compose`
2. **No `version:` attribute** in any `docker-compose.yml` or `.j2` template
3. **Never declare work complete** without actual testing or verification
4. **Vault variables** — never use `vault_` prefix, use direct names (e.g. `paperless_db_password`)
5. **Vault edits** — always use `ansible-vault edit`, never `encrypt_string` to append
6. **`deploy_stack.yml`** — never rename this file, it is referenced by all server playbooks
7. **`playbook_dir`** — always use in template `src:` paths within included tasks
8. **`sed -i` on macOS** — always `sed -i ''` (BSD sed requires empty extension argument)
9. **NFS server (srv6) must run before NFS client playbooks** — execution order is critical
10. **Hardening playbook must run before stack playbooks** on any new server

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

```bash
# Edit vault
ansible-vault edit group_vars/all/vault.yml

# View vault
ansible-vault view group_vars/all/vault.yml

# Run playbook with vault
ansible-playbook playbooks/<name>.yml -i inventory.yml --limit <host> --ask-vault-pass --become
```

Key vault variables (never commit values):
```
cloudflared_tunnel_token
bpainter_pubkey / docker_admin_pubkey
onlyoffice_db_password / onlyoffice_jwt_secret
paperless_db_password / paperless_secret_key / paperless_admin_password / paperless_api_token
filebrowser_admin_password
firefly_db_password / firefly_app_key / firefly_importer_token
n8n_db_password / n8n_encryption_key
calcom_db_password / calcom_nextauth_secret
espocrm_db_password / espocrm_admin_password
anythingllm_jwt_secret
omnimail_db_password / omnimail_session_secret / omnimail_encryption_key
```

---

## Common Run Commands

```bash
# Interactive runner (recommended)
./ansible.sh

# Hardening (run before stack playbooks on new servers)
ansible-playbook playbooks/harden.yml -i inventory.yml --limit <host> --ask-vault-pass --become

# Individual server stacks
ansible-playbook playbooks/srv1_stacks.yml -i inventory.yml --limit srv1 --ask-vault-pass --become
ansible-playbook playbooks/srv3_stacks.yml -i inventory.yml --limit srv3 --ask-vault-pass --become
ansible-playbook playbooks/srv4_stacks.yml -i inventory.yml --limit srv4 --ask-vault-pass --become
ansible-playbook playbooks/srv5_stacks.yml -i inventory.yml --limit srv5 --ask-vault-pass --become
ansible-playbook playbooks/srv6_stacks.yml -i inventory.yml --limit srv6 --ask-vault-pass --become

# Tag-scoped runs
ansible-playbook playbooks/harden.yml -i inventory.yml --tags rsyslog --ask-vault-pass --become
ansible-playbook playbooks/harden.yml -i inventory.yml --tags cis --ask-vault-pass --become

# Ad-hoc ownership fix across all servers
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

- [ ] firefly-importer on srv3 — waiting for Firefly III first login to generate API token
- [ ] paperless-ai and paperless-gpt on srv6 — waiting for Paperless-ngx API token
- [ ] srv6 FileBrowser Quantum — admin password reset may be needed (env var ignored after DB init)
- [ ] srv6 OnlyOffice + FileBrowser integration — config.yaml not yet configured
- [ ] NFS client mounts on srv1, srv3, srv4, srv5 — verify all are active post-setup
