#!/usr/bin/env python3
"""A staged config file needs its directory to exist, and Ansible will not make one.

`copy:` and `template:` fail with "Destination directory ... does not exist" when the parent of
`dest:` is missing. Most staging tasks in `muffin_stack.yml` never meet this, because a `copy:`
whose `src:` is a DIRECTORY creates its destination — so the rule is invisible until someone
copies individual files somewhere new. That has now happened twice: `/home/ubuntu/proxy` (which
left a comment calling itself "the first task here that needs it spelled out") and
`/home/ubuntu/dagster`, which failed a deploy eighteen minutes in.

The check walks every task in the playbook and its roles, collects the directories the playbook
KNOWS exist, and fails on any `copy`/`template` writing a file into one that is not among them.

A directory is known to exist when:
  * a `file:` task creates it (`state: directory`), or
  * a directory-copy lands there (a `copy:` whose `src` ends in `/`), or
  * it is an ancestor of one of those, or of a known-existing root.

`--self-test` runs the whole rule over synthetic playbooks with no repo and no Ansible, so CI can
run it on every PR: one that stages a file into a created directory (must pass), one that stages
into a directory nothing creates (must fail), and one where only a directory-copy created it
(must pass — that is the case that makes the rule non-obvious).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

# Directories that exist before the playbook runs. `/home/ubuntu` is the ssh user's home and
# `/etc`, `/tmp`, `/var/lib` are the filesystem's. Anything BELOW these still has to be created.
PREEXISTING = {
    "/home/ubuntu",  # the ssh user's home
    "/etc",
    "/etc/systemd/system",  # exists on any systemd host; the egress unit is staged straight into it
    "/tmp",
    "/var",
    "/var/lib",
    "/opt",
    "/usr/local/bin",
    "/root",
}

FILE_MODULES = ("copy", "template")


def _tasks(node: object) -> list[dict]:
    """Every task dict in a playbook, including those nested in block/rescue/always."""
    out: list[dict] = []
    if isinstance(node, list):
        for item in node:
            out += _tasks(item)
    elif isinstance(node, dict):
        if any(k in node for k in ("tasks", "pre_tasks", "post_tasks", "handlers")):
            for key in ("tasks", "pre_tasks", "post_tasks", "handlers"):
                out += _tasks(node.get(key) or [])
        for key in ("block", "rescue", "always"):
            if key in node:
                out += _tasks(node[key] or [])
        if any(m in node for m in (*FILE_MODULES, "file", "ansible.builtin.file")):
            out.append(node)
    return out


def _module(task: dict, name: str) -> dict | None:
    for key in (name, f"ansible.builtin.{name}"):
        val = task.get(key)
        if isinstance(val, dict):
            return val
        if isinstance(val, str):  # free-form `copy: src=x dest=y`
            return dict(pair.split("=", 1) for pair in val.split() if "=" in pair)
    return None


def _norm(path: str) -> str:
    return str(path).rstrip("/") or "/"


def audit(docs: list[object]) -> list[str]:
    tasks = _tasks(docs)

    def remember(path: str, known: set[str]) -> None:
        """Creating a directory creates its parents, so they are known too.

        `file: state=directory` and a directory `copy:` both behave like `mkdir -p`. This is the
        ONE direction the implication runs: creating /home/ubuntu/supabase/db proves
        /home/ubuntu/supabase exists, while /home/ubuntu existing proves nothing about
        /home/ubuntu/dagster. Getting that backwards is what made the first draft accept the very
        bug it was written for.
        """
        node = Path(_norm(path))
        for ancestor in [node, *node.parents]:
            known.add(_norm(str(ancestor)))

    known: set[str] = set(PREEXISTING)
    for task in tasks:
        f = _module(task, "file")
        if f and f.get("state") == "directory" and f.get("path"):
            remember(str(f["path"]), known)
        for name in FILE_MODULES:
            m = _module(task, name)
            # A DIRECTORY copy creates its destination; a file copy does not. This asymmetry is
            # the entire reason the rule is easy to miss.
            if m and str(m.get("src", "")).endswith("/") and m.get("dest"):
                remember(str(m["dest"]), known)

    failures: list[str] = []
    for task in tasks:
        for name in FILE_MODULES:
            m = _module(task, name)
            if not m or not m.get("dest"):
                continue
            dest = str(m["dest"])
            if str(m.get("src", "")).endswith("/") or dest.endswith("/"):
                continue  # a directory copy, handled above
            # A TEMPLATED SEGMENT IS RESOLVED AT DEPLOY TIME, so judge the literal prefix of the
            # DEST — never of its parent. `Path("{{ item.path }}").parent` is `.`, which holds no
            # `{{` at all, so testing the parent lets a fully templated dest through as a literal
            # relative path and then reports it as writing into ".". That false positive is what
            # the real playbook produced. The common honest shape is `/home/ubuntu/dagster/{{ item
            # }}`, whose literal prefix already names the directory that has to exist.
            if "{{" in dest:
                literal = dest.split("{{")[0]
                # Entirely templated (`{{ item.path }}`): nothing to judge offline, and inventing a
                # verdict is how a guard starts crying wolf on correct code.
                if not literal.strip("/"):
                    continue
                parent = _norm(literal) if literal.endswith("/") else str(Path(literal).parent)
            else:
                parent = str(Path(dest).parent)
            # EXACT, NOT ANCESTRAL. `/home/ubuntu` existing says nothing about
            # `/home/ubuntu/dagster`: `copy` does not create parents, so an ancestor test accepts
            # precisely the case this exists to catch. The first version did, and its own self-test
            # said so.
            if _norm(parent) not in known:
                failures.append(
                    f"{task.get('name', '<unnamed task>')!r} writes {dest} but nothing in the "
                    f"playbook creates {parent} — copy/template do not create parent directories"
                )
    return failures


SELF_TESTS: list[tuple[str, str, bool]] = [
    (
        "a file staged into a directory the playbook creates",
        """
- hosts: all
  tasks:
    - name: make it
      file: {path: /home/ubuntu/dagster, state: directory}
    - name: stage it
      copy: {src: dagster/dagster.yaml, dest: /home/ubuntu/dagster/dagster.yaml}
""",
        True,
    ),
    (
        "a file staged into a directory nothing creates",
        """
- hosts: all
  tasks:
    - name: stage it
      copy: {src: dagster/dagster.yaml, dest: /home/ubuntu/dagster/dagster.yaml}
""",
        False,
    ),
    (
        "a parent implied by a deeper directory-copy",
        """
- hosts: all
  tasks:
    - name: bulk stage a subdirectory
      copy: {src: supabase/db/, dest: /home/ubuntu/supabase/db/}
    - name: stage a file in its PARENT
      template: {src: kong.yml, dest: /home/ubuntu/supabase/kong.yml}
""",
        True,
    ),
    (
        "a file staged one level BELOW a created directory",
        """
- hosts: all
  tasks:
    - name: make it
      file: {path: /home/ubuntu/dagster, state: directory}
    - name: stage deeper
      copy: {src: a.yaml, dest: /home/ubuntu/dagster/sub/a.yaml}
""",
        False,
    ),
    (
        "a fully templated dest cannot be judged offline",
        """
- hosts: all
  tasks:
    - name: stage secrets
      copy: {content: x, dest: "{{ item.path }}"}
""",
        True,
    ),
    (
        "a templated FILENAME under a directory nothing creates",
        """
- hosts: all
  tasks:
    - name: stage it
      copy: {src: "dagster/{{ item }}", dest: "/home/ubuntu/dagster/{{ item }}"}
""",
        False,
    ),
    (
        "a directory-copy is what created the directory",
        """
- hosts: all
  tasks:
    - name: bulk stage
      copy: {src: supabase/migrations/, dest: /home/ubuntu/supabase/migrations/}
    - name: stage one more
      template: {src: kong.yml, dest: /home/ubuntu/supabase/migrations/kong.yml}
""",
        True,
    ),
]


def self_test() -> int:
    bad = 0
    for label, text, should_pass in SELF_TESTS:
        failures = audit(yaml.safe_load(text))
        passed = not failures
        if passed != should_pass:
            bad += 1
            print(f"SELF-TEST FAILED: {label} — expected {'pass' if should_pass else 'fail'}")
            for f in failures:
                print(f"    {f}")
        else:
            print(f"ok: {label}")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("playbooks", nargs="*", default=["ansible/muffin_stack.yml"])
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return 1 if self_test() else 0

    failures: list[str] = []
    for name in args.playbooks:
        path = Path(name)
        if not path.exists():
            print(f"no such playbook: {path}")
            return 1
        failures += [f"{path}: {f}" for f in audit(yaml.safe_load(path.read_text()))]

    for f in failures:
        print(f"::error::{f}")
    print(f"{len(failures)} staged file(s) without a directory")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
