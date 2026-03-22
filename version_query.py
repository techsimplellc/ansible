#!/usr/bin/env python3
"""
version_query.py — Query GitHub for latest release info for all homelab app stacks.

Reads current pinned versions from playbooks/vars/app_versions.yml and compares
against latest GitHub releases. Flags releases <= 30 days old as potentially
unstable, and reports the previous stable release as the safer pin candidate.

Usage:
  python3 version_query.py                    # unauthenticated (60 req/hr)
  python3 version_query.py -t <github_token>  # authenticated  (5000 req/hr)
  python3 version_query.py --token <token>
"""

import sys
import os
import json
import re
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta

# ── Configuration ─────────────────────────────────────────────────────────────
VERSIONS_FILE = os.path.join(os.path.dirname(__file__), "playbooks/vars/app_versions.yml")
NEW_RELEASE_DAYS = 30     # Flag releases newer than this many days
API_BASE         = "https://api.github.com"
RELEASES_PER_REQ = 5      # Fetch this many releases per query (to find prev stable)

# ── App → GitHub repo mapping ─────────────────────────────────────────────────
# Format: var_name_in_app_versions_yml -> (display_name, owner/repo)
# Set repo to None for Docker Hub images that have no GitHub releases page.
APPS = [
    # var_key                     display name         github repo
    ("cloudflared_version",      "Cloudflared",        "cloudflare/cloudflared"),
    ("npm_version",              "Nginx Proxy Manager","NginxProxyManager/nginx-proxy-manager"),
    ("whoogle_version",          "Whoogle",            "benbusby/whoogle-search"),
    ("adguardhome_version",      "AdGuard Home",       "AdguardTeam/AdGuardHome"),
    ("metube_version",           "MeTube",             "alexta69/metube"),
    ("firefly_version",          "Firefly III",        "firefly-iii/firefly-iii"),
    ("firefly_importer_version", "Firefly Importer",   "firefly-iii/data-importer"),
    ("n8n_version",              "n8n",                "n8n-io/n8n"),
    ("calcom_version",           "Cal.com",            "calcom/cal.com"),
    ("espocrm_version",          "EspoCRM",            "espocrm/espocrm"),
    ("ollama_version",           "Ollama",             "ollama/ollama"),
    ("anythingllm_version",      "AnythingLLM",        "Mintplex-Labs/anything-llm"),
    ("paperless_version",        "Paperless-ngx",      "paperless-ngx/paperless-ngx"),
    ("paperless_ai_version",     "Paperless-AI",       "clusterzx/paperless-ai"),
    ("paperless_gpt_version",    "Paperless-GPT",      "icereed/paperless-gpt"),
    ("authentik_version",        "Authentik",          "goauthentik/authentik"),
    ("onlyoffice_version",       "OnlyOffice",         "ONLYOFFICE/DocumentServer"),
    ("simple_office_api_version","Simple Office API",  "techsimplellc/simple-office-api"),
    ("simple_office_web_version","Simple Office Web",  "techsimplellc/simple-office-web"),
    # Docker Hub images — no GitHub release query
    ("postgres_version",         "PostgreSQL",         None),
    ("redis_version",            "Redis",              None),
]

# ── Helpers ───────────────────────────────────────────────────────────────────
def parse_flat_yaml(filepath):
    """Parse a flat Ansible vars file (no nesting). Returns dict of key: value."""
    result = {}
    with open(filepath) as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped in ("---", "..."):
                continue
            if ":" not in line:
                continue
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip()
            if len(val) >= 2 and val[0] in ('"', "'") and val[-1] == val[0]:
                val = val[1:-1]
            result[key] = val
    return result


def normalize_tag(tag):
    """Strip leading 'v' for display comparison."""
    return tag.lstrip("v")


def github_request(path, token=None):
    """Make a GitHub API request. Returns parsed JSON or raises."""
    url = f"{API_BASE}{path}"
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "ppf-homelab-version-query")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            remaining = resp.headers.get("X-RateLimit-Remaining", "?")
            data = json.loads(resp.read())
            return data, int(remaining) if remaining != "?" else None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, None
        if e.code == 403:
            raise RuntimeError(
                f"GitHub API rate limit hit or forbidden ({url}). "
                "Pass a token with -t to raise the limit."
            )
        raise RuntimeError(f"HTTP {e.code} fetching {url}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"Network error fetching {url}: {e.reason}")


def get_stable_releases(repo, token=None):
    """
    Return the last RELEASES_PER_REQ stable (non-draft, non-prerelease) releases
    as a list of (tag, published_at datetime) tuples, newest first.
    """
    data, remaining = github_request(
        f"/repos/{repo}/releases?per_page={RELEASES_PER_REQ}", token
    )
    if data is None:
        return [], remaining
    stable = []
    for r in data:
        if r.get("draft") or r.get("prerelease"):
            continue
        tag = r["tag_name"]
        published = datetime.fromisoformat(r["published_at"].replace("Z", "+00:00"))
        stable.append((tag, published))
    return stable, remaining


def age_str(dt):
    """Human-readable age string from a datetime."""
    delta = datetime.now(timezone.utc) - dt
    days  = delta.days
    if days == 0:
        return "today"
    if days == 1:
        return "1 day ago"
    return f"{days}d ago"


def format_date(dt):
    return dt.strftime("%Y-%m-%d")


# ── Output formatting ─────────────────────────────────────────────────────────
RESET  = "\033[0m"
BOLD   = "\033[1m"
CYAN   = "\033[0;36m"
GREEN  = "\033[0;32m"
YELLOW = "\033[0;33m"
RED    = "\033[0;31m"
DIM    = "\033[2m"

COL_APP     = 22
COL_PINNED  = 20
COL_LATEST  = 16
COL_DATE    = 13
COL_AGE     = 10


def print_header():
    print()
    print(f"{CYAN}{BOLD}{'─' * 90}{RESET}")
    print(f"{CYAN}{BOLD}  PPF Homelab — App Version Report{RESET}")
    print(f"{CYAN}{BOLD}  {datetime.now().strftime('%Y-%m-%d %H:%M')}  "
          f"(flags releases ≤ {NEW_RELEASE_DAYS} days old){RESET}")
    print(f"{CYAN}{BOLD}{'─' * 90}{RESET}")
    print(
        f"  {BOLD}{'App':<{COL_APP}}{'Pinned':<{COL_PINNED}}"
        f"{'Latest':<{COL_LATEST}}{'Released':<{COL_DATE}}{'Age':<{COL_AGE}}"
        f"Notes{RESET}"
    )
    print(f"  {'─' * 88}")


def print_row(app_name, pinned, latest_tag, latest_dt, prev_tag, prev_dt, error=None):
    now = datetime.now(timezone.utc)

    if error:
        print(
            f"  {app_name:<{COL_APP}}{pinned:<{COL_PINNED}}"
            f"{DIM}{'N/A':<{COL_LATEST}}{'—':<{COL_DATE}}{'—':<{COL_AGE}}"
            f"{error}{RESET}"
        )
        return

    if latest_tag is None:
        print(
            f"  {app_name:<{COL_APP}}{pinned:<{COL_PINNED}}"
            f"{DIM}{'no releases':<{COL_LATEST}}{'—':<{COL_DATE}}{'—':<{COL_AGE}}{RESET}"
        )
        return

    # Docker Hub images (no GitHub query)
    if latest_tag == "DOCKER_HUB":
        print(
            f"  {app_name:<{COL_APP}}{pinned:<{COL_PINNED}}"
            f"{DIM}{'Docker Hub':<{COL_LATEST}}{'—':<{COL_DATE}}{'—':<{COL_AGE}}"
            f"Not tracked via GitHub{RESET}"
        )
        return

    age_days  = (now - latest_dt).days
    is_new    = age_days <= NEW_RELEASE_DAYS
    date_str  = format_date(latest_dt)
    age_label = age_str(latest_dt)

    pin_norm    = normalize_tag(pinned)
    latest_norm = normalize_tag(latest_tag)
    is_current  = pin_norm == latest_norm
    is_unpinned = pinned == "REPLACE_ME"

    # Colour the pinned version
    if is_unpinned:
        pinned_col = f"{RED}{pinned:<{COL_PINNED}}{RESET}"
    elif is_current:
        pinned_col = f"{GREEN}{pinned:<{COL_PINNED}}{RESET}"
    else:
        pinned_col = f"{YELLOW}{pinned:<{COL_PINNED}}{RESET}"

    # Colour the latest tag
    if is_new:
        latest_col  = f"{YELLOW}{latest_tag:<{COL_LATEST}}{RESET}"
        date_col    = f"{YELLOW}{date_str:<{COL_DATE}}{RESET}"
        age_col     = f"{YELLOW}{age_label:<{COL_AGE}}{RESET}"
    else:
        latest_col  = f"{latest_tag:<{COL_LATEST}}"
        date_col    = f"{date_str:<{COL_DATE}}"
        age_col     = f"{age_label:<{COL_AGE}}"

    # Build notes
    notes_parts = []
    if is_unpinned:
        notes_parts.append(f"{RED}not pinned{RESET}")
    elif not is_current:
        notes_parts.append(f"{YELLOW}update available{RESET}")

    if is_new:
        flag = f"{YELLOW}⚠ released {age_days}d ago{RESET}"
        if prev_tag and prev_dt:
            flag += (
                f"{YELLOW} — consider: {normalize_tag(prev_tag)}"
                f" ({format_date(prev_dt)}, {age_str(prev_dt)}){RESET}"
            )
        notes_parts.append(flag)

    notes = "  ".join(notes_parts)

    print(
        f"  {app_name:<{COL_APP}}"
        f"{pinned_col}"
        f"{latest_col}"
        f"{date_col}"
        f"{age_col}"
        f"{notes}"
    )


def print_legend():
    print()
    print(f"  {BOLD}Legend:{RESET}")
    print(f"    {GREEN}green pinned{RESET}   — up to date")
    print(f"    {YELLOW}yellow pinned{RESET}  — update available")
    print(f"    {RED}red pinned{RESET}     — not pinned (REPLACE_ME)")
    print(f"    {YELLOW}⚠{RESET}              — released within {NEW_RELEASE_DAYS} days; "
          f"previous stable version shown as safer pin candidate")
    print()


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    # Parse args
    token = None
    args  = sys.argv[1:]
    i     = 0
    while i < len(args):
        if args[i] in ("-t", "--token") and i + 1 < len(args):
            token = args[i + 1]
            i += 2
        else:
            print(f"Unknown argument: {args[i]}", file=sys.stderr)
            print(__doc__)
            sys.exit(1)

    # Load current pinned versions
    if not os.path.exists(VERSIONS_FILE):
        print(f"ERROR: {VERSIONS_FILE} not found", file=sys.stderr)
        sys.exit(1)
    pinned_versions = parse_flat_yaml(VERSIONS_FILE)

    print_header()

    rate_remaining = None
    last_server = None

    for var_key, display_name, repo in APPS:
        pinned = pinned_versions.get(var_key, "NOT IN FILE")

        # Section divider when server group changes
        server_map = {
            "cloudflared_version": None,   # infra
            "npm_version": "srv1", "whoogle_version": "srv1", "adguardhome_version": "srv1",
            "metube_version": "srv3", "firefly_version": "srv3", "firefly_importer_version": "srv3",
            "n8n_version": "srv4", "calcom_version": "srv4", "espocrm_version": "srv4",
            "ollama_version": "srv5", "anythingllm_version": "srv5",
            "paperless_version": "srv6", "paperless_ai_version": "srv6",
            "paperless_gpt_version": "srv6", "authentik_version": "srv6",
            "onlyoffice_version": "srv6", "simple_office_api_version": "srv6",
            "simple_office_web_version": "srv6",
            "postgres_version": None, "redis_version": None,
        }
        server = server_map.get(var_key)
        if server != last_server:
            label = server if server else ("infra" if var_key == "cloudflared_version" else "shared")
            print(f"\n  {DIM}── {label} ──{RESET}")
            last_server = server

        # Docker Hub images — skip GitHub query
        if repo is None:
            print_row(display_name, pinned, "DOCKER_HUB", None, None, None)
            continue

        # Query GitHub
        try:
            releases, remaining = get_stable_releases(repo, token)
            if remaining is not None:
                rate_remaining = remaining
        except RuntimeError as e:
            print_row(display_name, pinned, None, None, None, None, error=str(e))
            continue

        if not releases:
            print_row(display_name, pinned, None, None, None, None)
            continue

        latest_tag, latest_dt = releases[0]
        prev_tag, prev_dt     = releases[1] if len(releases) > 1 else (None, None)

        print_row(display_name, pinned, latest_tag, latest_dt, prev_tag, prev_dt)

    # Footer
    print(f"\n  {'─' * 88}")
    if rate_remaining is not None:
        auth_note = "authenticated" if token else "unauthenticated — pass -t <token> for 5000/hr"
        color = RED if rate_remaining < 10 else (YELLOW if rate_remaining < 20 else DIM)
        print(f"  {color}GitHub API requests remaining: {rate_remaining}  ({auth_note}){RESET}")

    print_legend()


if __name__ == "__main__":
    main()
