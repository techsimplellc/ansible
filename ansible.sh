#!/usr/bin/env bash
# Repo path: ~/git/ansible/ansible.sh
# =============================================================================
# ansible.sh — Interactive Ansible Playbook Runner
# Place in project root: ~/git/ansible/
# Usage: ./ansible.sh
# Requirements: ansible-playbook, python3 (standard on macOS)
# =============================================================================

set -uo pipefail

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

# ── State ─────────────────────────────────────────────────────────────────────
STEP="playbook"

SELECTED_PLAYBOOK=""
VAULT_PASS_FILE=""
TAG_ARG=""
TAG_LABEL=""
TAG_CACHE_FOR=""
declare -a ALL_TAGS=()
LIMIT_ARG=""
TARGET_LABEL=""

trap '[[ -n "${VAULT_PASS_FILE:-}" ]] && rm -f "$VAULT_PASS_FILE"' EXIT

# ── Main loop ─────────────────────────────────────────────────────────────────
print_header

while true; do
  case "$STEP" in

    # ── Select playbook ───────────────────────────────────────────────────────
    playbook)
      print_section "Available Playbooks"

      mapfile -t PLAYBOOKS < <(find "$PLAYBOOK_DIR" -maxdepth 1 -name "*.yml" | sort | xargs -I{} basename {})
      [[ ${#PLAYBOOKS[@]} -gt 0 ]] || die "No playbooks found in $PLAYBOOK_DIR"

      printf "  ${RED}%2d)${RESET} Quit\n" 0
      echo ""
      for i in "${!PLAYBOOKS[@]}"; do
        printf "  ${GREEN}%2d)${RESET} %s\n" "$((i+1))" "${PLAYBOOKS[$i]}"
      done

      echo ""
      read -rp "$(echo -e "${BOLD}Select playbook [0-${#PLAYBOOKS[@]}]: ${RESET}")" pb_choice

      if [[ "$pb_choice" == "0" ]]; then
        echo -e "\n${YELLOW}Goodbye.${RESET}\n"
        exit 0
      fi

      if ! [[ "$pb_choice" =~ ^[0-9]+$ ]] || (( pb_choice < 1 )) || (( pb_choice > ${#PLAYBOOKS[@]} )); then
        echo -e "  ${RED}Invalid selection.${RESET}"
        continue
      fi

      SELECTED_PLAYBOOK="${PLAYBOOKS[$((pb_choice-1))]}"
      TAG_CACHE_FOR=""  # invalidate tag cache on new playbook selection
      echo -e "  → ${GREEN}${SELECTED_PLAYBOOK}${RESET}"
      STEP="vault"
      ;;

    # ── Vault password ────────────────────────────────────────────────────────
    vault)
      echo ""
      echo -e "  ${YELLOW}Leave blank to go back to playbook selection.${RESET}"
      read -rsp "$(echo -e "${BOLD}Vault password: ${RESET}")" VAULT_PASS
      echo ""

      if [[ -z "$VAULT_PASS" ]]; then
        STEP="playbook"
        continue
      fi

      [[ -n "${VAULT_PASS_FILE:-}" ]] && rm -f "$VAULT_PASS_FILE"
      VAULT_PASS_FILE="$(mktemp)"
      echo "$VAULT_PASS" > "$VAULT_PASS_FILE"
      STEP="tag"
      ;;

    # ── Select tag ────────────────────────────────────────────────────────────
    tag)
      print_section "Available Tags"

      # Fetch tags only when playbook changes
      if [[ "$TAG_CACHE_FOR" != "$SELECTED_PLAYBOOK" ]]; then
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
        TAG_CACHE_FOR="$SELECTED_PLAYBOOK"
      fi

      if [[ ${#ALL_TAGS[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}No tags found — will run all tasks.${RESET}"
        TAG_ARG=""
        TAG_LABEL="all tasks"
        STEP="host"
        continue
      fi

      printf "  ${YELLOW}%2d)${RESET} Back\n" 0
      echo ""
      for i in "${!ALL_TAGS[@]}"; do
        printf "  ${GREEN}%2d)${RESET} %s\n" "$((i+1))" "${ALL_TAGS[$i]}"
      done

      ALL_TAGS_IDX=$(( ${#ALL_TAGS[@]} + 1 ))
      echo ""
      printf "  ${GREEN}%2d)${RESET} ${BOLD}all${RESET}  — run all tasks (no tag filter)\n" "$ALL_TAGS_IDX"

      echo ""
      read -rp "$(echo -e "${BOLD}Select tag [0-${ALL_TAGS_IDX}]: ${RESET}")" tag_choice

      if [[ "$tag_choice" == "0" ]]; then
        STEP="vault"
        continue
      fi

      if ! [[ "$tag_choice" =~ ^[0-9]+$ ]] || (( tag_choice < 1 )) || (( tag_choice > ALL_TAGS_IDX )); then
        echo -e "  ${RED}Invalid selection.${RESET}"
        continue
      fi

      if (( tag_choice == ALL_TAGS_IDX )); then
        TAG_ARG=""
        TAG_LABEL="all tasks"
      else
        TAG_ARG="--tags ${ALL_TAGS[$((tag_choice-1))]}"
        TAG_LABEL="${ALL_TAGS[$((tag_choice-1))]}"
      fi
      echo -e "  → ${GREEN}${TAG_LABEL}${RESET}"
      STEP="host"
      ;;

    # ── Select target host ────────────────────────────────────────────────────
    host)
      print_section "Available Hosts"

      declare -a HOST_LIST=()

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

      printf "  ${YELLOW}%2d)${RESET} Back\n" 0
      echo ""

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
      read -rp "$(echo -e "${BOLD}Select target [0-${ALL_IDX}]: ${RESET}")" host_choice

      if [[ "$host_choice" == "0" ]]; then
        STEP="tag"
        continue
      fi

      if ! [[ "$host_choice" =~ ^[0-9]+$ ]] || (( host_choice < 1 )) || (( host_choice > ALL_IDX )); then
        echo -e "  ${RED}Invalid selection.${RESET}"
        continue
      fi

      if (( host_choice == ALL_IDX )); then
        LIMIT_ARG=""
        TARGET_LABEL="all hosts"
      else
        LIMIT_ARG="--limit ${HOST_LIST[$((host_choice-1))]}"
        TARGET_LABEL="${HOST_LIST[$((host_choice-1))]}"
      fi
      STEP="confirm"
      ;;

    # ── Confirm and execute ───────────────────────────────────────────────────
    confirm)
      print_section "Confirm Execution"

      echo -e "  Playbook : ${GREEN}${SELECTED_PLAYBOOK}${RESET}"
      echo -e "  Tag      : ${GREEN}${TAG_LABEL}${RESET}"
      echo -e "  Target   : ${GREEN}${TARGET_LABEL}${RESET}"
      echo -e "  Inventory: ${GREEN}${INVENTORY}${RESET}"

      CMD_DISPLAY="ansible-playbook ${PLAYBOOK_DIR}/${SELECTED_PLAYBOOK} -i ${INVENTORY}"
      [[ -n "$LIMIT_ARG" ]] && CMD_DISPLAY+=" $LIMIT_ARG"
      [[ -n "$TAG_ARG"   ]] && CMD_DISPLAY+=" $TAG_ARG"
      CMD_DISPLAY+=" --ask-vault-pass --become"

      echo ""
      echo -e "  Command  : ${CYAN}${CMD_DISPLAY}${RESET}"
      echo ""
      read -rp "$(echo -e "${BOLD}Proceed? [y/N/b=back]: ${RESET}")" confirm

      case "$confirm" in
        [Yy]) STEP="run" ;;
        [Bb]) STEP="host"; continue ;;
        *)    echo -e "\n${YELLOW}Aborted.${RESET}\n"; exit 0 ;;
      esac
      ;;

    # ── Execute ───────────────────────────────────────────────────────────────
    run)
      print_section "Executing"

      # shellcheck disable=SC2086
      ansible-playbook \
        "${PLAYBOOK_DIR}/${SELECTED_PLAYBOOK}" \
        -i "${INVENTORY}" \
        ${LIMIT_ARG} \
        ${TAG_ARG} \
        --vault-password-file "${VAULT_PASS_FILE}" \
        --become
      break
      ;;

  esac
done
