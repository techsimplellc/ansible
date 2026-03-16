#!/usr/bin/env bash
# Repo path: ~/git/ansible/ansible.sh
# =============================================================================
# ansible.sh — Interactive Ansible Playbook Runner
# Place in project root: ~/git/ansible/
# Usage: ./ansible.sh
# Requirements: ansible-playbook, python3 (standard on macOS)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_DIR="${SCRIPT_DIR}/playbooks"
INVENTORY="${SCRIPT_DIR}/inventory.yml"

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
print_header() {
  echo ""
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}   Ansible Playbook Runner                ${RESET}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════${RESET}"
  echo ""
}

print_section() {
  echo ""
  echo -e "${YELLOW}${BOLD}── $1 ${RESET}"
  echo ""
}

die() {
  echo -e "\n${RED}${BOLD}ERROR: $1${RESET}\n" >&2
  exit 1
}

# ── Preflight checks ──────────────────────────────────────────────────────────
command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook not found in PATH"
command -v python3          >/dev/null 2>&1 || die "python3 not found in PATH"
[[ -d "$PLAYBOOK_DIR" ]]                     || die "Playbook directory not found: $PLAYBOOK_DIR"
[[ -f "$INVENTORY"    ]]                     || die "Inventory not found: $INVENTORY"

# ── Select playbook ───────────────────────────────────────────────────────────
print_header
print_section "Available Playbooks"

mapfile -t PLAYBOOKS < <(find "$PLAYBOOK_DIR" -maxdepth 1 -name "*.yml" | sort | xargs -I{} basename {})

[[ ${#PLAYBOOKS[@]} -gt 0 ]] || die "No playbooks found in $PLAYBOOK_DIR"

for i in "${!PLAYBOOKS[@]}"; do
  printf "  ${GREEN}%2d)${RESET} %s\n" "$((i+1))" "${PLAYBOOKS[$i]}"
done

echo ""
read -rp "$(echo -e "${BOLD}Select playbook [1-${#PLAYBOOKS[@]}]: ${RESET}")" pb_choice

[[ "$pb_choice" =~ ^[0-9]+$ ]]          || die "Invalid selection: $pb_choice"
(( pb_choice >= 1 ))                    || die "Invalid selection: $pb_choice"
(( pb_choice <= ${#PLAYBOOKS[@]} ))     || die "Invalid selection: $pb_choice"

SELECTED_PLAYBOOK="${PLAYBOOKS[$((pb_choice-1))]}"
echo -e "  → ${GREEN}${SELECTED_PLAYBOOK}${RESET}"

# ── Vault password (prompted once, used for tags, inventory, and playbook) ────
echo ""
read -rsp "$(echo -e "${BOLD}Vault password: ${RESET}")" VAULT_PASS
echo ""

VAULT_PASS_FILE="$(mktemp)"
trap 'rm -f "${VAULT_PASS_FILE}"' EXIT
echo "${VAULT_PASS}" > "${VAULT_PASS_FILE}"

# ── Select tag (optional) ─────────────────────────────────────────────────────
print_section "Available Tags"

# Collect all unique tags via ansible-playbook --list-tags (macOS sed, no grep -P)
mapfile -t ALL_TAGS < <(
  ansible-playbook \
    "${PLAYBOOK_DIR}/${SELECTED_PLAYBOOK}" \
    -i "${INVENTORY}" \
    --list-tags \
    --vault-password-file "${VAULT_PASS_FILE}" \
    2>/dev/null \
  | grep "TASK TAGS" \
  | sed 's/.*\[\(.*\)\]/\1/' \
  | tr ',' '\n' \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
  | sort -u \
  | grep -v '^$'
)

if [[ ${#ALL_TAGS[@]} -eq 0 ]]; then
  echo -e "  ${YELLOW}No tags found — running all tasks.${RESET}"
  TAG_ARG=""
  TAG_LABEL="all tasks"
else
  for i in "${!ALL_TAGS[@]}"; do
    printf "  ${GREEN}%2d)${RESET} %s\n" "$((i+1))" "${ALL_TAGS[$i]}"
  done

  ALL_TAGS_IDX=$(( ${#ALL_TAGS[@]} + 1 ))
  echo ""
  printf "  ${GREEN}%2d)${RESET} ${BOLD}all${RESET}  — run all tasks (no tag filter)\n" "$ALL_TAGS_IDX"

  echo ""
  read -rp "$(echo -e "${BOLD}Select tag [1-${ALL_TAGS_IDX}]: ${RESET}")" tag_choice

  [[ "$tag_choice" =~ ^[0-9]+$ ]]      || die "Invalid selection: $tag_choice"
  (( tag_choice >= 1 ))                || die "Invalid selection: $tag_choice"
  (( tag_choice <= ALL_TAGS_IDX ))     || die "Invalid selection: $tag_choice"

  if (( tag_choice == ALL_TAGS_IDX )); then
    TAG_ARG=""
    TAG_LABEL="all tasks"
  else
    SELECTED_TAG="${ALL_TAGS[$((tag_choice-1))]}"
    TAG_ARG="--tags ${SELECTED_TAG}"
    TAG_LABEL="${SELECTED_TAG}"
  fi
  echo -e "  → ${GREEN}${TAG_LABEL}${RESET}"
fi


# ── Select target host ────────────────────────────────────────────────────────
print_section "Available Hosts"

declare -a HOST_LIST=()

# Parse inventory via ansible-inventory — no external dependencies
# Outputs "group:host:ip" per line, skipping meta groups
mapfile -t RAW_HOSTS < <(
  ansible-inventory -i "${INVENTORY}" --list --vault-password-file "${VAULT_PASS_FILE}" 2>/dev/null | \
  python3 -c "
import json, sys
inv = json.load(sys.stdin)
for group, data in inv.items():
    if group in ('_meta', 'all', 'ungrouped'):
        continue
    for host in data.get('hosts', []):
        ip = inv.get('_meta', {}).get('hostvars', {}).get(host, {}).get('ansible_host', 'N/A')
        print(f'{group}:{host}:{ip}')
"
)

[[ ${#RAW_HOSTS[@]} -gt 0 ]] || die "No hosts found in $INVENTORY"

current_group=""
for entry in "${RAW_HOSTS[@]}"; do
  group="${entry%%:*}"
  rest="${entry#*:}"
  host="${rest%%:*}"
  ip="${rest#*:}"

  if [[ "$group" != "$current_group" ]]; then
    [[ -n "$current_group" ]] && echo ""
    echo -e "  ${CYAN}${BOLD}[${group}]${RESET}"
    current_group="$group"
  fi

  idx=${#HOST_LIST[@]}
  HOST_LIST+=("$host")
  printf "  ${GREEN}%2d)${RESET} %-10s %s\n" "$((idx+1))" "$host" "$ip"
done

echo ""
ALL_IDX=$(( ${#HOST_LIST[@]} + 1 ))
printf "  ${GREEN}%2d)${RESET} ${BOLD}all${RESET}  — every host in inventory\n" "$ALL_IDX"

echo ""
read -rp "$(echo -e "${BOLD}Select target [1-${ALL_IDX}]: ${RESET}")" host_choice

[[ "$host_choice" =~ ^[0-9]+$ ]]    || die "Invalid selection: $host_choice"
(( host_choice >= 1 ))              || die "Invalid selection: $host_choice"
(( host_choice <= ALL_IDX ))        || die "Invalid selection: $host_choice"

if (( host_choice == ALL_IDX )); then
  LIMIT_ARG=""
  TARGET_LABEL="all hosts"
else
  SELECTED_HOST="${HOST_LIST[$((host_choice-1))]}"
  LIMIT_ARG="--limit ${SELECTED_HOST}"
  TARGET_LABEL="${SELECTED_HOST}"
fi

# ── Confirm and execute ───────────────────────────────────────────────────────
print_section "Confirm Execution"

echo -e "  Playbook : ${GREEN}${SELECTED_PLAYBOOK}${RESET}"
echo -e "  Tag      : ${GREEN}${TAG_LABEL}${RESET}"
echo -e "  Target   : ${GREEN}${TARGET_LABEL}${RESET}"
echo -e "  Inventory: ${GREEN}${INVENTORY}${RESET}"

CMD_DISPLAY="ansible-playbook ${PLAYBOOK_DIR}/${SELECTED_PLAYBOOK} -i ${INVENTORY}"
[[ -n "$LIMIT_ARG" ]] && CMD_DISPLAY+=" $LIMIT_ARG"
[[ -n "$TAG_ARG"   ]] && CMD_DISPLAY+=" $TAG_ARG"
CMD_DISPLAY+=" --vault-password-file <vault-tmp> --become"

echo ""
echo -e "  Command  : ${CYAN}${CMD_DISPLAY}${RESET}"
echo ""
read -rp "$(echo -e "${BOLD}Proceed? [y/N]: ${RESET}")" confirm

[[ "$confirm" =~ ^[Yy]$ ]] || { echo -e "\n${YELLOW}Aborted.${RESET}\n"; exit 0; }

print_section "Executing"

# shellcheck disable=SC2086
ansible-playbook \
  "${PLAYBOOK_DIR}/${SELECTED_PLAYBOOK}" \
  -i "${INVENTORY}" \
  ${LIMIT_ARG} \
  ${TAG_ARG} \
  --vault-password-file "${VAULT_PASS_FILE}" \
  --become
