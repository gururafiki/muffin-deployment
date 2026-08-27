#!/usr/bin/env python3
"""Per-service memory and CPU for node-exporter's textfile collector.

WHY THIS EXISTS. cAdvisor cannot identify a container on this node: Docker uses the containerd
image store (`driver-type: io.containerd.snapshotter.v1`), so the classic graph-driver layout it
reads is absent and it reports only systemd slices — with a green Prometheus target throughout.
`docker stats` asks Docker, which knows both the service name and the limit, so nothing has to be
inferred from a cgroup path.

WHY IT IS A FILE AND NOT `copy: content:`. Ansible renders inline `content:` through JINJA, and
this script is full of braces — `{{json .}}` for docker's format string and `{{service="..."}}`
for the Prometheus label. The deploy failed with `template error while templating string: expected
name or number`. `copy:` with a `src:` does not template, which is also why this can be linted and
syntax-checked like ordinary code.

Staged to /usr/local/bin by ansible/muffin_stack.yml and run once a minute by cron.
"""
import json
import os
import re
import subprocess

OUT = "/var/lib/node-exporter/muffin_services.prom"

MULT = {
    "B": 1, "KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3, "TiB": 1024 ** 4,
    "kB": 1000, "MB": 1000 ** 2, "GB": 1000 ** 3, "TB": 1000 ** 4,
}


def to_bytes(s: str) -> float | None:
    m = re.match(r"([\d.]+)\s*([KMGT]?i?B)", s.strip())
    return float(m.group(1)) * MULT.get(m.group(2), 1) if m else None


def main() -> int:
    try:
        raw = subprocess.run(
            ["docker", "stats", "--no-stream", "--format", "{{json .}}"],
            capture_output=True, text=True, timeout=90,
        ).stdout
    except Exception:
        # A docker hiccup must leave the PREVIOUS file in place rather than a truncated one.
        return 0

    lines = [
        "# HELP muffin_service_memory_bytes Memory in use by a swarm service.",
        "# TYPE muffin_service_memory_bytes gauge",
        "# HELP muffin_service_memory_limit_bytes The service's own memory limit.",
        "# TYPE muffin_service_memory_limit_bytes gauge",
        "# HELP muffin_service_cpu_percent CPU percent of one core.",
        "# TYPE muffin_service_cpu_percent gauge",
    ]

    for line in raw.strip().split("\n"):
        if not line:
            continue
        try:
            d = json.loads(line)
            name = d["Name"]
            # STRIPPED TO THE SERVICE. `muffin_openbb-api.1.abc123` -> `muffin_openbb-api`: the
            # slot and task id change on every redeploy, so keeping them would start a brand-new
            # series each deploy and a memory graph would reset to zero instead of showing a leak.
            svc = name.split(".")[0] if name.startswith("muffin_") else name
            used, _, limit = d["MemUsage"].partition("/")
            u, l = to_bytes(used), to_bytes(limit)
            cpu = float(d["CPUPerc"].rstrip("%"))
        except Exception:
            continue
        if u is None or l is None:
            continue
        lines.append(f'muffin_service_memory_bytes{{service="{svc}"}} {u:.0f}')
        lines.append(f'muffin_service_memory_limit_bytes{{service="{svc}"}} {l:.0f}')
        lines.append(f'muffin_service_cpu_percent{{service="{svc}"}} {cpu}')

    # ATOMIC. node-exporter reads on ITS schedule, and a half-written file makes it drop the WHOLE
    # scrape with a parse error rather than skip one metric.
    with open(OUT + ".tmp", "w") as f:
        f.write("\n".join(lines) + "\n")
    os.rename(OUT + ".tmp", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
