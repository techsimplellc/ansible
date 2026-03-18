# UFW Firewall — Architecture and Change Guide

## How it is structured

UFW rules are co-located with the tasks that own them. Each service opens its
own port when it is installed. There is no single consolidated ruleset — that
is intentional, so that removing a service automatically removes its firewall
rule.

### Baseline policy

Applied by two places that serve different purposes but produce the same rules:

| File | When it runs |
|---|---|
| `roles/hardening/tasks/04_ufw.yml` | During initial hardening (`harden.yml`) |
| `playbooks/ufw.yml` | Standalone re-apply / day-2 changes |

Rules set by the baseline:

- Default incoming: **deny**
- Default outgoing: **allow**
- Default routed: **deny**
- `192.168.68.0/24` → all ports: **allow** (LAN trusted subnet)
- srv1 only: Cloudflare IPv4 ranges → 443/tcp: **allow** (NPM ingress)

### SSH rule

Defined in `roles/hardening/tasks/03_ssh.yml` (line 44). It must live here
because it has to be in place *before* sshd restarts on port 2222 — ordering
enforced by the hardening role sequence.

- `192.168.68.0/24` → 2222/tcp: **allow**

### Service-specific rules

Each rule is opened by the task file that installs the service:

| Port | Protocol | Service | Task file |
|---|---|---|---|
| 2049 | tcp | NFS | `playbooks/tasks/nfs_server.yml` |
| 514 | tcp + udp | rsyslog (central receiver) | `playbooks/tasks/rsyslog_server.yml` |
| 9090 | tcp | Cockpit | `playbooks/tasks/cockpit.yml` |

> **Note:** Because the LAN subnet is fully trusted at the baseline level, all
> of the service-specific rules above are belt-and-suspenders. They document
> intent and would become load-bearing if the LAN allow-all rule were ever
> narrowed.

---

## Where to make changes

### Add or remove a rule for an internal service

Edit the task file for that service. Add or remove the `community.general.ufw`
task alongside the rest of the service setup. Example from
`playbooks/tasks/cockpit.yml`:

```yaml
- name: Allow Cockpit port from LAN
  community.general.ufw:
    rule: allow
    from_ip: "{{ lan_subnet }}"
    to_port: "9090"
    proto: tcp
    comment: "Cockpit"
```

### Change the baseline policy or LAN subnet

Edit both files so they stay in sync:

- `roles/hardening/tasks/04_ufw.yml`
- `playbooks/ufw.yml`

### Add or remove Cloudflare subnet entries (srv1 port 443)

The Cloudflare IPv4 list is defined in `group_vars/all/vars.yml` under
`cloudflare_ipv4_ranges`. Edit it there — both `04_ufw.yml` and `ufw.yml`
loop over that variable.

To remove all Cloudflare allowlist entries from srv1, remove the task block
from both files:

```yaml
# Delete this block from roles/hardening/tasks/04_ufw.yml
# and from playbooks/ufw.yml
- name: Allow Cloudflare IPs to port 443
  community.general.ufw:
    ...
  loop: "{{ cloudflare_ipv4_ranges }}"
  when: inventory_hostname == 'srv1'
```

Then delete `cloudflare_ipv4_ranges` from `group_vars/all/vars.yml`. The
`scripts/update_cloudflare_ips.py` cron script should also be removed or
updated to stop targeting that variable.

> UFW does not automatically remove rules when you delete the Ansible task.
> Run `ufw delete <rule>` on srv1 or `ufw reset` followed by a full re-apply
> to clean up stale rules.

### Refresh Cloudflare IP ranges

The IP list is kept current by `scripts/update_cloudflare_ips.py`. Run it
manually or via cron (recommended monthly):

```bash
python3 scripts/update_cloudflare_ips.py --vault-password-file ~/.ansible-vault-pass
```

This fetches current ranges from `https://www.cloudflare.com/ips-v4`, updates
`group_vars/all/vars.yml`, commits the change, and re-runs `playbooks/ufw.yml`
against srv1.

---

## Re-applying UFW rules

```bash
# All homelab servers
ansible-playbook playbooks/ufw.yml -i inventory.yml --ask-vault-pass --become

# Single server
ansible-playbook playbooks/ufw.yml -i inventory.yml --limit srv1 --ask-vault-pass --become

# Via the interactive runner
./ansible.sh
```

> Running `ufw.yml` is idempotent. It will not disrupt existing connections or
> remove rules that were added by service task files (e.g. NFS, rsyslog).
