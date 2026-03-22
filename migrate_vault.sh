#!/usr/bin/env bash
# =============================================================================
# migrate_vault.sh — Split master vault into per-app vault files
#
# Reads group_vars/all/vault.yml, extracts variables by name, writes and
# encrypts individual playbooks/vars/<app>_vault.yml files.
#
# Secrets are never printed to the terminal or stored in plaintext beyond
# a chmod-600 temp file that is wiped on exit.
#
# Usage:
#   ./migrate_vault.sh            # live run
#   ./migrate_vault.sh --dry-run  # preview only — no files written or encrypted
#
# After running:
#   - Verify each vault:  ansible-vault view playbooks/vars/<app>_vault.yml
#   - Remove app secrets from the master vault (keep only bpainter_pubkey,
#     docker_admin_pubkey):  ansible-vault edit group_vars/all/vault.yml
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER_VAULT="${SCRIPT_DIR}/group_vars/all/vault.yml"
VARS_DIR="${SCRIPT_DIR}/playbooks/vars"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
  DRY_RUN=1
fi

VAULT_PASS_FILE=""
PLAINTEXT_FILE=""

cleanup() {
  [[ -n "${VAULT_PASS_FILE:-}" ]] && rm -f "$VAULT_PASS_FILE"
  [[ -n "${PLAINTEXT_FILE:-}" ]] && rm -f "$PLAINTEXT_FILE"
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v ansible-vault >/dev/null 2>&1 || { echo "ERROR: ansible-vault not found in PATH" >&2; exit 1; }
command -v python3       >/dev/null 2>&1 || { echo "ERROR: python3 not found in PATH" >&2; exit 1; }
[[ -f "$MASTER_VAULT" ]]                 || { echo "ERROR: master vault not found: $MASTER_VAULT" >&2; exit 1; }
[[ -d "$VARS_DIR" ]]                     || { echo "ERROR: vars directory not found: $VARS_DIR" >&2; exit 1; }

if [[ $DRY_RUN -eq 1 ]]; then
  echo "DRY RUN — no files will be written or encrypted"
  echo ""
fi

# ── Vault password ────────────────────────────────────────────────────────────
read -rsp "Vault password: " VAULT_PASS
echo ""

VAULT_PASS_FILE="$(mktemp)"
chmod 600 "$VAULT_PASS_FILE"
printf '%s' "$VAULT_PASS" > "$VAULT_PASS_FILE"
unset VAULT_PASS

# ── Decrypt master vault to temp file ─────────────────────────────────────────
PLAINTEXT_FILE="$(mktemp)"
chmod 600 "$PLAINTEXT_FILE"

ansible-vault decrypt \
  --vault-password-file "$VAULT_PASS_FILE" \
  --output "$PLAINTEXT_FILE" \
  "$MASTER_VAULT" 2>/dev/null \
  || { echo "ERROR: Failed to decrypt master vault — wrong password?" >&2; exit 1; }

echo "Master vault decrypted. Analysing per-app vaults..."
echo ""

# ── Extract and (optionally) encrypt per-app vault files ──────────────────────
python3 - "$PLAINTEXT_FILE" "$VARS_DIR" "$VAULT_PASS_FILE" "$DRY_RUN" << 'PYEOF'
import sys
import os
import re
import subprocess

plaintext_file = sys.argv[1]
vars_dir        = sys.argv[2]
vault_pass_file = sys.argv[3]
dry_run         = sys.argv[4] == "1"

# ── Stdlib YAML parser (flat key: value only — sufficient for vault files) ────
def parse_flat_yaml(filepath):
    """
    Parse a flat Ansible vault file (no nesting, no lists).
    Handles: plain scalars, "double quoted", 'single quoted', multiline ignored.
    """
    result = {}
    with open(filepath) as f:
        for line in f:
            line = line.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped in ("---", "..."):
                continue
            if ":" not in line:
                continue
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip()
            # Strip surrounding quotes
            if len(val) >= 2 and val[0] in ('"', "'") and val[-1] == val[0]:
                val = val[1:-1]
            result[key] = val
    return result

master = parse_flat_yaml(plaintext_file)

# ── Variable mapping ──────────────────────────────────────────────────────────
VAULT_MAP = {
    "cloudflared_vault.yml": [
        "cloudflared_tunnel_token",
    ],
    "firefly_vault.yml": [
        "firefly_db_password",
        "firefly_app_key",
        "firefly_importer_token",
    ],
    "n8n_vault.yml": [
        "n8n_db_password",
        "n8n_encryption_key",
    ],
    "calcom_vault.yml": [
        "calcom_db_password",
        "calcom_nextauth_secret",
        "calendso_encryption_key",
        "calcom_google_client_id",
        "calcom_google_client_secret",
    ],
    "espocrm_vault.yml": [
        "espocrm_db_password",
        "espocrm_admin_password",
    ],
    "anythingllm_vault.yml": [
        "anythingllm_jwt_secret",
    ],
    "paperless_vault.yml": [
        "paperless_db_password",
        "paperless_secret_key",
        "paperless_admin_password",
        "paperless_api_token",
    ],
    "authentik_vault.yml": [
        "authentik_db_password",
        "authentik_secret_key",
    ],
    "simple_office_vault.yml": [
        "so_db_password",
        "so_jwt_secret",
        "so_onlyoffice_jwt_secret",
        "so_session_secret",
        "so_oidc_client_id",
        "so_oidc_client_secret",
        "onlyoffice_db_password",
        "onlyoffice_jwt_secret",
    ],
    "omnimail_vault.yml": [
        "omnimail_db_password",
        "omnimail_session_secret",
        "omnimail_encryption_key",
        "GOOGLE_CLIENT_ID",
        "GOOGLE_CLIENT_SECRET",
        "GOOGLE_REDIRECT_URI",
        "MICROSOFT_CLIENT_ID",
        "MICROSOFT_CLIENT_SECRET",
        "MICROSOFT_REDIRECT_URI",
        "YAHOO_CLIENT_ID",
        "YAHOO_CLIENT_SECRET",
        "YAHOO_REDIRECT_URI",
    ],
}

exit_code  = 0
total_ok   = 0
total_warn = 0
total_skip = 0
total_err  = 0

for vault_file, var_names in VAULT_MAP.items():
    out_path = os.path.join(vars_dir, vault_file)
    tmp_path = out_path + ".plaintext.tmp"

    if os.path.exists(out_path):
        print(f"  SKIP   {vault_file}  (already exists — delete to re-generate)")
        total_skip += 1
        continue

    missing = [v for v in var_names if v not in master]

    if dry_run:
        found   = [v for v in var_names if v in master]
        label   = "WOULD CREATE" if not missing else "WOULD CREATE (with REPLACE_ME)"
        print(f"  {label:28s} {vault_file}")
        for v in found:
            print(f"      found:   {v}")
        for v in missing:
            print(f"      MISSING: {v}")
        if missing:
            total_warn += 1
        else:
            total_ok += 1
        continue

    # ── Live run ──────────────────────────────────────────────────────────────
    app_vars = {v: (master[v] if v in master else "REPLACE_ME") for v in var_names}

    # Write plaintext YAML — quote values containing special chars
    def yaml_scalar(v):
        # Use double-quote if value contains colon, hash, or leading/trailing space
        if re.search(r'[:#\[\]{}|>&*!,]', v) or v != v.strip() or v == "":
            escaped = v.replace('\\', '\\\\').replace('"', '\\"')
            return f'"{escaped}"'
        return v

    try:
        with open(tmp_path, "w") as f:
            f.write("---\n")
            for k, v in app_vars.items():
                f.write(f"{k}: {yaml_scalar(str(v))}\n")
        os.chmod(tmp_path, 0o600)
    except Exception as e:
        print(f"  ERROR  {vault_file}  write failed: {e}")
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        exit_code = 1
        total_err += 1
        continue

    # Encrypt in place
    result = subprocess.run(
        ["ansible-vault", "encrypt", "--vault-password-file", vault_pass_file, tmp_path],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(f"  ERROR  {vault_file}  encrypt failed: {result.stderr.strip()}")
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        exit_code = 1
        total_err += 1
        continue

    os.rename(tmp_path, out_path)

    if missing:
        print(f"  WARN   {vault_file}  created — REPLACE_ME set for: {', '.join(missing)}")
        total_warn += 1
    else:
        print(f"  OK     {vault_file}")
        total_ok += 1

# ── Summary ───────────────────────────────────────────────────────────────────
mode = "DRY RUN " if dry_run else ""
print("")
print(f"  {mode}Summary: {total_ok} ok  {total_warn} warn  {total_skip} skipped  {total_err} errors")

if exit_code != 0:
    sys.exit(exit_code)
PYEOF

echo ""
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run complete. Run without --dry-run to perform the migration."
else
  echo "Migration complete."
  echo ""
  echo "Next steps:"
  echo "  1. Verify a vault:      ansible-vault view playbooks/vars/<app>_vault.yml"
  echo "  2. Fix any REPLACE_ME:  ansible-vault edit playbooks/vars/<app>_vault.yml"
  echo "  3. Clean master vault:  ansible-vault edit group_vars/all/vault.yml"
  echo "     (keep only bpainter_pubkey and docker_admin_pubkey)"
fi
