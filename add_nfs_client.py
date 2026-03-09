#!/usr/bin/env python3
"""
Inserts the nfs_client.yml include task before the stacks_owner.yml include
in srv1, srv3, srv4, srv5 stack playbooks.

Run from ~/git/ansible:
    python3 add_nfs_client.py
"""

import os
import sys

PLAYBOOKS_DIR = os.path.join(os.path.dirname(__file__), "playbooks") \
    if os.path.isdir(os.path.join(os.path.dirname(__file__), "playbooks")) \
    else os.path.expanduser("~/git/ansible/playbooks")

TARGET_SERVERS = ["srv1", "srv3", "srv4", "srv5"]

INSERT_BLOCK = """\
    - name: Mount NFS storage from srv6 and replace /opt/stacks symlink
      ansible.builtin.include_tasks: "{{ playbook_dir }}/tasks/nfs_client.yml"

"""

MARKER = '      ansible.builtin.include_tasks: "{{ playbook_dir }}/tasks/stacks_owner.yml"'

for srv in TARGET_SERVERS:
    path = os.path.join(PLAYBOOKS_DIR, f"{srv}_stacks.yml")
    if not os.path.exists(path):
        print(f"SKIP  {path} — file not found")
        continue

    with open(path, "r") as f:
        content = f.read()

    if "nfs_client.yml" in content:
        print(f"SKIP  {path} — nfs_client.yml already present")
        continue

    if MARKER not in content:
        print(f"ERROR {path} — stacks_owner.yml marker not found, manual edit required")
        sys.exit(1)

    # Find the line with the marker and insert the NFS block before
    # the full task block (name line is one line above the marker)
    lines = content.splitlines(keepends=True)
    new_lines = []
    i = 0
    while i < len(lines):
        # Detect the "- name: Enforce /opt/stacks ownership" line
        if lines[i].strip() == "- name: Enforce /opt/stacks ownership":
            new_lines.append(INSERT_BLOCK)
        new_lines.append(lines[i])
        i += 1

    new_content = "".join(new_lines)

    with open(path, "w") as f:
        f.write(new_content)

    print(f"OK    {path}")

print("\nDone. Verify with:")
for srv in TARGET_SERVERS:
    print(f"  grep -A3 'nfs_client' playbooks/{srv}_stacks.yml")
