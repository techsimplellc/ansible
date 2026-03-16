#!/usr/bin/env python3
"""
update_cloudflare_ips.py — Refresh Cloudflare IP ranges in Ansible repo files.

Fetches the current IPv4/IPv6 ranges from Cloudflare's official endpoints,
diffs against the repo, commits if changed, and optionally re-runs the
affected playbooks.

Files updated:
  group_vars/webservers/vars.yml       cloudflare_ipv4_ranges + cloudflare_ipv6_ranges
  roles/hardening/tasks/04_ufw.yml     srv1 Cloudflare allowlist loop (IPv4 only)

Usage:
  python3 scripts/update_cloudflare_ips.py
  python3 scripts/update_cloudflare_ips.py --vault-password-file ~/.ansible-vault-pass
  python3 scripts/update_cloudflare_ips.py --dry-run
"""

import argparse
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────

REPO_ROOT   = Path(__file__).resolve().parent.parent
CF_IPV4_URL = "https://www.cloudflare.com/ips-v4"
CF_IPV6_URL = "https://www.cloudflare.com/ips-v6"

WEBSERVERS_VARS  = REPO_ROOT / "group_vars/webservers/vars.yml"
HARDENING_UFW    = REPO_ROOT / "roles/hardening/tasks/04_ufw.yml"

# Playbooks to re-run after a change, if a vault password file is provided.
# Each entry: (description, ansible-playbook args list)
PLAYBOOKS = [
    (
        "painterprecision — firewall (webserver_hardening)",
        [
            "ansible-playbook", "playbooks/harden_webserver.yml",
            "-i", "inventory.yml",
            "--limit", "painterprecision",
            "--tags", "firewall",
            "--become",
        ],
    ),
    (
        "srv1 — UFW (hardening)",
        [
            "ansible-playbook", "playbooks/harden.yml",
            "-i", "inventory.yml",
            "--limit", "srv1",
            "--tags", "ufw",
            "--become",
        ],
    ),
]

# ── Helpers ───────────────────────────────────────────────────────────────────

def fetch_ips(url: str) -> list:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ansible-cf-ip-refresh/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            return [ln.strip() for ln in resp.read().decode().splitlines() if ln.strip()]
    except Exception as exc:
        print(f"ERROR: could not fetch {url}: {exc}", file=sys.stderr)
        sys.exit(1)


def yaml_list(ips: list, indent: int) -> str:
    """Return a YAML list block (no trailing newline)."""
    pad = " " * indent
    return "\n".join(f"{pad}- {ip}" for ip in ips)


def update_webservers_vars(content: str, ipv4: list, ipv6: list) -> str:
    """Replace cloudflare_ipv4_ranges and cloudflare_ipv6_ranges lists."""
    for key, ips in (("cloudflare_ipv4_ranges", ipv4), ("cloudflare_ipv6_ranges", ipv6)):
        pattern = rf"({re.escape(key)}:\n)((?:  - \S+\n)+)"
        if not re.search(pattern, content):
            print(f"  WARNING: could not locate '{key}' block in {WEBSERVERS_VARS.name}",
                  file=sys.stderr)
            continue
        replacement = f"{key}:\n{yaml_list(ips, indent=2)}\n"
        content = re.sub(pattern, replacement, content)
    return content


def update_hardening_ufw(content: str, ipv4: list) -> str:
    """Replace the Cloudflare IPv4 loop under 'Allow Cloudflare IPs to port 443'."""
    pattern = (
        r"(  loop:\n)"
        r"((?:    - \S+\n)+)"
        r"(  when: inventory_hostname == 'srv1')"
    )
    if not re.search(pattern, content):
        print(f"  WARNING: could not locate Cloudflare loop block in {HARDENING_UFW.name}",
              file=sys.stderr)
        return content
    replacement = (
        f"  loop:\n{yaml_list(ipv4, indent=4)}\n"
        f"  when: inventory_hostname == 'srv1'"
    )
    return re.sub(pattern, replacement, content)


def git(args: list, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git"] + args, cwd=REPO_ROOT, capture_output=True,
                          text=True, check=check)

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Refresh Cloudflare IP ranges in Ansible repo files."
    )
    ap.add_argument(
        "--vault-password-file", metavar="FILE",
        help="Path to Ansible vault password file. Required to re-run playbooks.",
    )
    ap.add_argument(
        "--dry-run", action="store_true",
        help="Fetch and diff only — do not write, commit, or run playbooks.",
    )
    args = ap.parse_args()

    # ── Fetch ────────────────────────────────────────────────────────────────
    print("Fetching Cloudflare IP ranges...")
    ipv4 = fetch_ips(CF_IPV4_URL)
    ipv6 = fetch_ips(CF_IPV6_URL)
    print(f"  IPv4: {len(ipv4)} ranges")
    print(f"  IPv6: {len(ipv6)} ranges")

    # ── Update files ─────────────────────────────────────────────────────────
    updates = [
        (WEBSERVERS_VARS, lambda c: update_webservers_vars(c, ipv4, ipv6)),
        (HARDENING_UFW,   lambda c: update_hardening_ufw(c, ipv4)),
    ]

    changed = []
    for path, updater in updates:
        original = path.read_text()
        updated  = updater(original)
        rel      = path.relative_to(REPO_ROOT)
        if updated == original:
            print(f"  {rel}: no change")
        else:
            print(f"  {rel}: UPDATED")
            if not args.dry_run:
                path.write_text(updated)
            changed.append(str(rel))

    if not changed:
        print("\nCloudflare IP ranges are already current — nothing to do.")
        sys.exit(0)

    if args.dry_run:
        print("\nDry run — no files written.")
        sys.exit(0)

    # ── Git commit ────────────────────────────────────────────────────────────
    print("\nCommitting changes...")
    git(["add"] + changed)
    result = git(
        ["commit", "-m", "chore(cloudflare): refresh Cloudflare IP ranges",
         "-m", f"Updated files:\n" + "\n".join(f"  - {f}" for f in changed)],
        check=False,
    )
    if result.returncode != 0:
        print(f"ERROR: git commit failed\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"  {result.stdout.splitlines()[0]}")

    # ── Playbook re-run ───────────────────────────────────────────────────────
    if not args.vault_password_file:
        print("\nSkipping playbook re-run (no --vault-password-file provided).")
        print("Apply changes manually:")
        print("  ansible-playbook playbooks/harden_webserver.yml -i inventory.yml "
              "--limit painterprecision --tags firewall --ask-vault-pass --become")
        print("  ansible-playbook playbooks/harden.yml -i inventory.yml "
              "--limit srv1 --tags ufw --ask-vault-pass --become")
        sys.exit(0)

    vault_file = Path(args.vault_password_file).expanduser()
    if not vault_file.exists():
        print(f"ERROR: vault password file not found: {vault_file}", file=sys.stderr)
        sys.exit(1)

    for description, cmd in PLAYBOOKS:
        print(f"\nRunning: {description}")
        full_cmd = cmd + ["--vault-password-file", str(vault_file)]
        result = subprocess.run(full_cmd, cwd=REPO_ROOT)
        if result.returncode != 0:
            print(f"ERROR: playbook failed — {description}", file=sys.stderr)
            sys.exit(1)

    print("\nDone — Cloudflare IP ranges refreshed and applied to all hosts.")


if __name__ == "__main__":
    main()
