---
tags:
  - homelab
  - ansible
  - testing
  - infrastructure
created: 2026-03-21
status: pending
commit: ab61878
---

# Ansible Playbook Refactor — Test Plan

Validates the per-app individual playbooks, per-app vault structure, and thin `import_playbook` orchestrators introduced in commit `ab61878`.

> [!important] Deployment Order
> **srv6 must be deployed before srv1/3/4/5.** It is the NFS server all other servers mount their `/opt/stacks` from.

---

## Phase 0 — Pre-flight: Vault Setup

Before any playbook runs, every per-app vault file must exist and be encrypted.

```bash
cd ~/git/ansible

# Create vault files from templates
cp playbooks/vars/cloudflared_vault.yml.example   playbooks/vars/cloudflared_vault.yml
cp playbooks/vars/firefly_vault.yml.example       playbooks/vars/firefly_vault.yml
cp playbooks/vars/n8n_vault.yml.example           playbooks/vars/n8n_vault.yml
cp playbooks/vars/calcom_vault.yml.example        playbooks/vars/calcom_vault.yml
cp playbooks/vars/espocrm_vault.yml.example       playbooks/vars/espocrm_vault.yml
cp playbooks/vars/anythingllm_vault.yml.example   playbooks/vars/anythingllm_vault.yml
cp playbooks/vars/paperless_vault.yml.example     playbooks/vars/paperless_vault.yml
cp playbooks/vars/authentik_vault.yml.example     playbooks/vars/authentik_vault.yml
cp playbooks/vars/simple_office_vault.yml.example playbooks/vars/simple_office_vault.yml
cp playbooks/vars/omnimail_vault.yml.example      playbooks/vars/omnimail_vault.yml
```

Populate each file with real values, then encrypt with the **same password** as `group_vars/all/vault.yml`:

```bash
ansible-vault encrypt playbooks/vars/cloudflared_vault.yml
ansible-vault encrypt playbooks/vars/firefly_vault.yml
ansible-vault encrypt playbooks/vars/n8n_vault.yml
ansible-vault encrypt playbooks/vars/calcom_vault.yml
ansible-vault encrypt playbooks/vars/espocrm_vault.yml
ansible-vault encrypt playbooks/vars/anythingllm_vault.yml
ansible-vault encrypt playbooks/vars/paperless_vault.yml
ansible-vault encrypt playbooks/vars/authentik_vault.yml
ansible-vault encrypt playbooks/vars/simple_office_vault.yml
ansible-vault encrypt playbooks/vars/omnimail_vault.yml
```

### Verify

```bash
# Every file should start with $ANSIBLE_VAULT
head -1 playbooks/vars/*.yml

# Spot-check decryption
ansible-vault view playbooks/vars/cloudflared_vault.yml
ansible-vault view playbooks/vars/omnimail_vault.yml
```

**Pass:** All files start with `$ANSIBLE_VAULT`. Decrypted content shows correct variable names and values — no `CHANGE_ME` remaining.

---

## Phase 1 — Syntax Check

Validates YAML structure, `vars_files` paths, and `import_playbook` chains without connecting to any host.

```bash
# Individual playbooks
ansible-playbook playbooks/cloudflared.yml      --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/npm.yml              --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/whoogle.yml          --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/adguardhome.yml      --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/firefly.yml          --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/firefly-importer.yml --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/n8n.yml              --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/calcom.yml           --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/espocrm.yml          --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/ollama.yml           --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/anythingllm.yml      --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/paperless.yml        --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/authentik.yml        --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/simple-office.yml    --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/omnimail.yml         --syntax-check -i inventory.yml --ask-vault-pass

# Orchestrators (validates the import_playbook chains)
ansible-playbook playbooks/srv1_stacks.yml --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/srv3_stacks.yml --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/srv4_stacks.yml --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/srv5_stacks.yml --syntax-check -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/srv6_stacks.yml --syntax-check -i inventory.yml --ask-vault-pass
```

**Pass:** Every run prints the play/task tree and exits `0`. No errors.

---

## Phase 2 — List Tasks (verify ordering and tag filtering)

```bash
# Confirm orchestrator chain order
ansible-playbook playbooks/srv1_stacks.yml --list-tasks -i inventory.yml --ask-vault-pass
ansible-playbook playbooks/srv6_stacks.yml --list-tasks -i inventory.yml --ask-vault-pass

# Confirm two-pass tag filtering
ansible-playbook playbooks/paperless.yml     --list-tasks -i inventory.yml --ask-vault-pass --skip-tags ai,gpt
ansible-playbook playbooks/simple-office.yml --list-tasks -i inventory.yml --ask-vault-pass --tags infra
```

**Pass criteria:**

| Command | Expected output |
|---|---|
| `srv1_stacks.yml --list-tasks` | Tasks flow: cloudflared → npm → whoogle → adguardhome |
| `srv6_stacks.yml --list-tasks` | rsyslog + cockpit play first, then paperless → authentik → simple-office → omnimail |
| `paperless.yml --skip-tags ai,gpt` | Deploy paperless-ai and paperless-gpt tasks **not listed** |
| `simple-office.yml --tags infra` | Only postgres-simple-office, redis-simple-office, onlyoffice-so tasks listed |

---

## Phase 3 — Deploy (in server order)

### 3a. srv6 — Pass 1

```bash
ansible-playbook playbooks/paperless.yml     -i inventory.yml --ask-vault-pass --become --skip-tags ai,gpt
ansible-playbook playbooks/authentik.yml     -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/simple-office.yml -i inventory.yml --ask-vault-pass --become --tags infra
ansible-playbook playbooks/omnimail.yml      -i inventory.yml --ask-vault-pass --become
```

**Validate on srv6:**

```bash
# All expected containers running
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Port checks
curl -sf http://localhost:8086/accounts/login/ | grep -i "paperless" && echo "OK: Paperless"
curl -sf http://localhost:9000/if/flow/initial-setup/ | grep -i "authentik" && echo "OK: Authentik"
curl -sf http://localhost:8025 | grep -i "omnimail\|login" && echo "OK: OmniMail"
```

**Expected containers:**

| Container | Port |
|---|---|
| postgres-paperless | 5437 |
| paperless-ngx | 8086 |
| postgres-authentik | 5439 |
| authentik-server / authentik-worker | 9000 |
| postgres-simple-office | 5438 |
| redis-simple-office | — |
| onlyoffice-so | 8092 |
| omnimail-frontend, omnimail-backend, omnimail-db, omnimail-redis | 8025 |

**External access (from workstation):**

```bash
curl -sf https://paperless.techsimple.dev/accounts/login/ | grep -i "paperless" && echo "OK: Paperless external"
curl -sf https://auth.techsimple.dev/if/flow/initial-setup/ | grep -i "authentik" && echo "OK: Authentik external"
curl -sf https://omnimail.techsimple.dev | grep -i "omnimail\|login" && echo "OK: OmniMail external"
```

---

### 3b. srv1

```bash
ansible-playbook playbooks/cloudflared.yml  -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/npm.yml          -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/whoogle.yml      -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/adguardhome.yml  -i inventory.yml --ask-vault-pass --become
```

**Validate on srv1:**

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
# Expected: cloudflared, npm, whoogle, adguardhome all Up

# Tunnel health
docker logs cloudflared 2>&1 | grep -i "connected\|registered" | tail -5
```

---

### 3c. srv3

```bash
ansible-playbook playbooks/firefly.yml -i inventory.yml --ask-vault-pass --become
```

**Validate on srv3:**

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
# Expected: postgres (5432), firefly-core, firefly-cron all Up

curl -sf http://localhost:8080 | grep -i "firefly" && echo "OK: Firefly"
```

---

### 3d. srv4

```bash
ansible-playbook playbooks/n8n.yml     -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/calcom.yml  -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/espocrm.yml -i inventory.yml --ask-vault-pass --become
```

**Validate on srv4:**

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
# Expected: postgres-n8n (5433), n8n, postgres-calcom (5434), calcom,
#           postgres-espocrm (5435), espocrm all Up

# Verify EspoCRM PostgreSQL config injection worked
docker exec espocrm cat /var/www/html/data/config-internal.php | grep "pdo_pgsql" && echo "OK: EspoCRM PG config"
```

---

### 3e. srv5

```bash
# Ollama must be running before AnythingLLM
ansible-playbook playbooks/ollama.yml      -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/anythingllm.yml -i inventory.yml --ask-vault-pass --become
```

**Validate on srv5:**

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
# Expected: ollama (11434), anythingllm (3001) Up

curl -sf http://localhost:11434/api/tags | python3 -m json.tool | grep "models" && echo "OK: Ollama API"
```

---

## Phase 4 — Two-pass Deployments

### 4a. Firefly Importer (srv3)

> Prerequisite: logged in to Firefly III and generated a Personal Access Token.

```bash
# 1. Get token: Firefly III → Profile → Personal Access Tokens → Create
# 2. Add to vault
ansible-vault edit playbooks/vars/firefly_vault.yml
#    Set: firefly_importer_token: "<token>"

# 3. Deploy
ansible-playbook playbooks/firefly-importer.yml -i inventory.yml --ask-vault-pass --become

# Validate on srv3
docker ps | grep firefly-importer
```

---

### 4b. Paperless AI + GPT (srv6)

> Prerequisite: logged in to Paperless-ngx and copied the API token.

```bash
# 1. Get token: Paperless-ngx → Profile → API Token
# 2. Add to vault
ansible-vault edit playbooks/vars/paperless_vault.yml
#    Set: paperless_api_token: "<token>"

# 3. Deploy (all tasks including ai and gpt)
ansible-playbook playbooks/paperless.yml -i inventory.yml --ask-vault-pass --become

# Validate on srv6
docker ps | grep -E "paperless-ai|paperless-gpt"
```

---

### 4c. Simple Office — Pass 2 (srv6)

> Prerequisite: Authentik OIDC provider created and client credentials noted.

```bash
# 1. Complete Authentik OIDC setup — see simple-office.yml header for full steps:
#    - Login to https://auth.techsimple.dev/if/flow/initial-setup/
#    - Admin → Applications → Providers → Create OAuth2/OpenID Provider
#      Name: simple-office
#      Redirect URI: https://app.techsimple.dev/api/v1/auth/callback
#    - Admin → Applications → Applications → Create (link to provider)
#    - Note the Client ID and Client Secret

# 2. Add OIDC credentials to vault
ansible-vault edit playbooks/vars/simple_office_vault.yml
#    Set: so_oidc_client_id, so_oidc_client_secret

# 3. Deploy full stack (no tag filter)
ansible-playbook playbooks/simple-office.yml -i inventory.yml --ask-vault-pass --become

# Validate on srv6
docker ps | grep -E "simple-office-api|simple-office-web"
curl -sf http://localhost:8090/health && echo "OK: SO API"
curl -sf http://localhost:8091 | grep -i "office" && echo "OK: SO Web"
```

---

## Phase 5 — Orchestrator Idempotency Test

After all individual deploys are validated, run the full orchestrators. All stacks are already up — tasks should report `ok` with `changed=0`.

```bash
ansible-playbook playbooks/srv1_stacks.yml -i inventory.yml --ask-vault-pass --become
ansible-playbook playbooks/srv6_stacks.yml -i inventory.yml --ask-vault-pass --become
```

**Pass:** No failures. Play recap shows `changed=0` for all hosts.

---

## Phase 6 — Interactive Runner (`ansible.sh`)

```bash
./ansible.sh
```

**Test steps:**
1. Confirm all 16+ individual playbooks appear in the numbered list alongside the orchestrators
2. Select `cloudflared.yml` → enter vault password → select a tag → select `srv1` → confirm → verify execution succeeds
3. Re-run and select an orchestrator (`srv1_stacks.yml`) → verify tag list shows tags from all chained playbooks

**Pass:** Full selection flow completes without errors.

---

## Pass/Fail Checklist

- [ ] All vault files encrypted (`head -1` shows `$ANSIBLE_VAULT`)
- [ ] All `--syntax-check` runs exit `0`
- [ ] Orchestrator task ordering matches expected sequence
- [ ] Two-pass tag filtering excludes correct tasks
- [ ] srv6 containers all `Up` after deploy
- [ ] srv1 containers all `Up`; tunnel shows connected in logs
- [ ] srv3 containers all `Up`; Firefly HTTP check passes
- [ ] srv4 containers all `Up`; EspoCRM `config-internal.php` contains `pdo_pgsql`
- [ ] srv5 containers all `Up`; Ollama `/api/tags` returns JSON
- [ ] External URLs (paperless, authentik, omnimail) respond through Cloudflare tunnel
- [ ] Firefly Importer deployed after token added
- [ ] Paperless AI + GPT deployed after API token added
- [ ] Simple Office pass 2 deployed after Authentik OIDC configured
- [ ] Orchestrator re-run is idempotent (`changed=0`)
- [ ] `ansible.sh` lists all 16+ playbooks and executes cleanly
