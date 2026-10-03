#!/usr/bin/env python3
"""THE DEFECT GAUGES ARE LISTED TWICE, AND THE TWO LISTS MUST AGREE.

`market.data_defect` counts invariants, and some of its rows are GAUGES: recorded, never asserted,
because they are non-zero on correct data. Two things decide which rows are gauges, independently:

  * `market-verify.yml`, the `GAUGES = {...}` set its anon check skips;
  * the Grafana rule "A data-correctness invariant is broken", whose query excludes the gauges
    with `metric not in ('defect.<name>', ...)`.

They have drifted before. `contradicted_negative_cache` was reclassified in the workflow on
2026-09-05 and not in the rule, so the alert fired against correct data from that day. This
fails when either list names a gauge the other does not.
"""
from __future__ import annotations

import re
import sys

import yaml

WORKFLOW = ".github/workflows/market-verify.yml"
RULES = "stack/observability/grafana/provisioning/alerting/rules.yml"
RULE_UID = "muffin-data-defect"


def workflow_gauges() -> set[str]:
    text = open(WORKFLOW).read()
    found = re.findall(r"GAUGES\s*=\s*\{([^}]*)\}", text)
    if len(found) != 1:
        sys.exit(f"::error::expected exactly one GAUGES set in {WORKFLOW}, found {len(found)}")
    return set(re.findall(r"'([a-z0-9_]+)'", found[0]))


def rule_gauges() -> set[str]:
    rules = yaml.safe_load(open(RULES))
    for group in rules.get("groups", []):
        for rule in group.get("rules", []):
            if rule.get("uid") != RULE_UID:
                continue
            sql = " ".join(
                (q.get("model") or {}).get("rawSql", "") for q in rule.get("data", [])
            )
            sql = re.sub(r"--[^\n]*", " ", sql)
            clause = re.search(r"metric\s+not\s+in\s*\(([^)]*)\)", sql, re.I)
            if not clause:
                sys.exit(f"::error::{RULE_UID} has no `metric not in (...)` clause")
            return set(re.findall(r"'defect\.([a-z0-9_]+)'", clause.group(1)))
    sys.exit(f"::error::no rule with uid {RULE_UID} in {RULES}")


def main() -> int:
    in_workflow, in_rule = workflow_gauges(), rule_gauges()
    if not in_workflow:
        print(f"::error::read no gauges from {WORKFLOW}; the parser is reading nothing")
        return 1
    problems = 0
    for name in sorted(in_workflow - in_rule):
        print(f"::error::{name} is a gauge in market-verify.yml and asserted by the Grafana rule")
        problems += 1
    for name in sorted(in_rule - in_workflow):
        print(f"::error::{name} is a gauge in the Grafana rule and asserted by market-verify.yml")
        problems += 1
    print(f"gauges: {', '.join(sorted(in_workflow))}; {problems} disagreement(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
