#!/usr/bin/env python3
"""Per-hostname egress visibility, for EVERY container, with no per-service configuration.

WHY THIS EXISTS. `http-cache` sits in FRONT of openbb-api, so it sees requests *to* openbb — but
openbb-api's own calls to yfinance/finviz/FMP never traverse it, and that is the rate limit which
governs this whole pipeline. The same blind spot covers firecrawl's scraping, the agent's LLM calls
and opensandbox. Labelling openbb requests by their `?provider=` parameter (PR #253) is an
INFERENCE and works only because openbb happens to take that parameter; it does not generalise.

WHY SNI RATHER THAN conntrack + A DNS MAP. conntrack works at L3/L4, so by the time a packet leaves
the hostname is resolved and gone and names have to be rebuilt from a DNS-response map — which needs
a logging resolver, Docker DNS reconfiguration, and still guesses on shared CDN addresses. TLS puts
the hostname back in the packet: every HTTPS connection opens with a ClientHello carrying
`server_name` in PLAINTEXT. No decryption, no CA, no MITM. The client states exactly which host it
wants.

WHAT THIS COUNTS, AND WHAT IT DOES NOT. CONNECTIONS, not requests — HTTP keep-alive reuses one
connection for many requests, so this is an undercount of unknown factor. The metric is named
`connections` for that reason; a number that is not what its name says is the failure mode this
repository is mostly about.

COST. The BPF filter runs IN THE KERNEL — measured, it compiles to 25 instructions — so only TLS
ClientHello packets ever reach userspace. Everything else is dropped before a copy is made. On this
node that is a handful of packets a minute against 32 live conntrack entries.
"""

import json
import os
import re
import signal
import subprocess
import sys
import time
from collections import Counter

OUT = os.environ.get("EGRESS_PROM_PATH", "/var/lib/node-exporter/muffin-egress.prom")
FLUSH_SECONDS = int(os.environ.get("EGRESS_FLUSH_SECONDS", "30"))
CONTAINER_REFRESH_SECONDS = int(os.environ.get("EGRESS_CONTAINER_REFRESH", "120"))

# TLS record type 0x16 (handshake) AND handshake type 0x01 (ClientHello). The SECOND test is what
# excludes ServerHello and the rest of the handshake, which carry no SNI — without it the capture
# is 2.5x the packets for the same information (measured: 15 against 6 over the same 20 seconds).
BPF = "tcp[((tcp[12:1] & 0xf0) >> 2)] = 0x16 and tcp[((tcp[12:1] & 0xf0) >> 2) + 5] = 0x01"

HEADER_RE = re.compile(r"^\d\d:\d\d:\d\d\.\d+ ")


def is_ours(ip: str) -> bool:
    """RFC1918, i.e. a container or the host — as opposed to the internet talking to us.

    THE FILTER MATTERS BECAUSE THIS METRIC IS NAMED `egress`. A ClientHello arrives in BOTH
    directions: every visitor reaching Traefik through Cloudflare sends one too, and the first
    version of this collector dutifully counted `muffin-grafana.rafiki.guru` as an outbound
    connection to an external host. Counting inbound traffic under an egress name is the same
    class of error as the panel that claimed openbb requests "actually left the node".
    """
    try:
        a, b, *_ = (int(x) for x in ip.split("."))
    except ValueError:
        return False
    return a == 10 or a == 127 or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168)
HEX_RE = re.compile(r"^\s+0x[0-9a-f]+:\s+((?:[0-9a-f]{2,4}\s*)+)", re.I)


def parse_client_hello(raw: bytes):
    """Return (src_ip, server_name) from an IPv4/TCP/TLS ClientHello, or None.

    PARSED, NOT PATTERN-MATCHED. Scanning the payload for something host-shaped finds the right
    answer most of the time and also finds ALPN entries and anything else printable — the SNI
    extension has a defined position, so it is read rather than guessed.
    """
    try:
        if len(raw) < 40 or (raw[0] >> 4) != 4:      # IPv4 only; the node has no IPv6 egress
            return None
        ihl = (raw[0] & 0x0F) * 4
        if raw[9] != 6:                              # TCP
            return None
        src = ".".join(str(b) for b in raw[12:16])
        tcp = raw[ihl:]
        sport = int.from_bytes(tcp[0:2], "big")
        doff = (tcp[12] >> 4) * 4
        payload = tcp[doff:]
        if len(payload) < 6 or payload[0] != 0x16:
            return None
        hs = payload[5:]
        if not hs or hs[0] != 0x01:
            return None

        p = 4 + 2 + 32                               # handshake header + client_version + random
        if p >= len(hs):
            return None
        p += 1 + hs[p]                               # legacy_session_id
        if p + 2 > len(hs):
            return None
        p += 2 + int.from_bytes(hs[p:p + 2], "big")  # cipher_suites
        if p >= len(hs):
            return None
        p += 1 + hs[p]                               # compression_methods
        if p + 2 > len(hs):
            return None
        ext_total = int.from_bytes(hs[p:p + 2], "big")
        p += 2
        end = min(p + ext_total, len(hs))

        while p + 4 <= end:
            etype = int.from_bytes(hs[p:p + 2], "big")
            elen = int.from_bytes(hs[p + 2:p + 4], "big")
            if etype == 0x0000:                      # server_name
                q = p + 4 + 2 + 1                    # list length + name type
                if q + 2 > len(hs):
                    return None
                nlen = int.from_bytes(hs[q:q + 2], "big")
                name = hs[q + 2:q + 2 + nlen].decode("ascii", "ignore")
                # A ClientHello is TRUNCATED when it spans segments, so a short read yields a
                # partial name. Reporting `query2.finance.ya` as a host would be worse than
                # reporting nothing, because it looks like a real and different destination.
                if len(name) == nlen and "." in name:
                    return src, sport, name
                return None
            p += 4 + elen
    except (IndexError, ValueError):
        return None
    return None


def container_map():
    """IP -> swarm service name, for BOTH the overlay and docker_gwbridge.

    THE GWBRIDGE ADDRESS IS THE ONE THAT MATTERS, and `docker inspect` does not expose it.
    A container on an overlay network reaches the internet through `docker_gwbridge`, so its
    ClientHello carries a 172.18.x source — while `.NetworkSettings.Networks` lists only the
    overlay 10.0.x address. Mapping the overlay alone leaves every external connection labelled
    with a bare IP, which is the difference between "openbb-api called yfinance" and "something
    called yfinance".

    `docker network inspect docker_gwbridge` names its endpoints `gateway_<sandboxid>` rather than
    by container, so the two are joined on the container's SandboxID prefix. Measured 2026-08-28:
    31 of 32 endpoints resolve; the odd one out is a container that had already exited.
    """
    out = {}
    try:
        ids = subprocess.run(["docker", "ps", "-q"], capture_output=True, text=True,
                             timeout=20).stdout.split()
        if not ids:
            return out
        insp = json.loads(subprocess.run(["docker", "inspect"] + ids, capture_output=True,
                                         text=True, timeout=30).stdout or "[]")
        by_sandbox = {}
        for c in insp:
            label = ((c.get("Config", {}).get("Labels") or {}).get("com.docker.swarm.service.name")
                     or c.get("Name", "").lstrip("/"))
            sid = (c.get("NetworkSettings", {}).get("SandboxID") or "")[:12]
            if sid:
                by_sandbox[sid] = label
            for net in (c.get("NetworkSettings", {}).get("Networks") or {}).values():
                ip = net.get("IPAddress")
                if ip:
                    out[ip] = label

        gw = json.loads(subprocess.run(["docker", "network", "inspect", "docker_gwbridge"],
                                       capture_output=True, text=True, timeout=20).stdout or "[]")
        for entry in (gw[0].get("Containers") if gw else {}) or {}:
            c = gw[0]["Containers"][entry]
            ip = (c.get("IPv4Address") or "").split("/")[0]
            label = by_sandbox.get(c.get("Name", "").replace("gateway_", "")[:12])
            if ip and label:
                out[ip] = label
    except Exception:
        pass
    return out


def write_metrics(counts, unresolved):
    tmp = OUT + ".tmp"
    lines = [
        "# HELP muffin_egress_connections_total TLS connections opened to an external host, by SNI.",
        "# TYPE muffin_egress_connections_total counter",
    ]
    for (host, container), n in sorted(counts.items()):
        h = host.replace("\\", "\\\\").replace('"', '\\"')
        c = container.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'muffin_egress_connections_total{{host="{h}",container="{c}"}} {n}')
    lines.append("# HELP muffin_egress_unparsed_total ClientHello packets whose SNI could not be read.")
    lines.append("# TYPE muffin_egress_unparsed_total counter")
    lines.append(f"muffin_egress_unparsed_total {unresolved}")
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT)          # atomic: node-exporter must never read a half-written file


def main():
    counts = Counter()
    unresolved = 0
    # `-i any` CAPTURES THE SAME PACKET AT EVERY LAYER IT CROSSES. Measured: one outbound
    # connection appeared three times — on the veth, on docker_gwbridge and on enp0s6 — with the
    # source address rewritten by NAT along the way (172.18.0.32 becoming 10.0.1.111). Counting
    # them all would inflate every figure threefold AND attribute one connection to two different
    # "containers". A connection is identified by its SOURCE PORT and destination name, which
    # survive NAT; the FIRST sighting wins, because that is the one still carrying the container's
    # own address.
    seen = {}
    SEEN_TTL = 30.0
    ips = container_map()
    last_flush = last_refresh = time.time()

    # STDERR IS KEPT, NOT DISCARDED. A tcpdump that cannot parse its filter exits immediately and
    # says so there; with stderr on /dev/null the collector runs happily for ever and writes an
    # empty file, which reads as "no egress" rather than as a broken capture. That is the exact
    # silent-failure shape this repository keeps paying for, and it cost a debugging cycle here.
    proc = subprocess.Popen(
        ["tcpdump", "-i", "any", "-l", "-n", "-s", "0", "-x", BPF],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
    )

    def stop(*_):
        try:
            proc.terminate()
        except Exception:
            pass
        write_metrics(counts, unresolved)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    hexbuf = []

    def flush_packet():
        nonlocal unresolved
        if not hexbuf:
            return
        try:
            raw = bytes.fromhex("".join(hexbuf))
        except ValueError:
            hexbuf.clear()
            return
        hexbuf.clear()
        got = parse_client_hello(raw)
        if not got:
            unresolved += 1
            return
        src, sport, host = got
        # Outbound only. An inbound ClientHello is a visitor arriving, not a call we made.
        if not is_ours(src):
            return
        key = (sport, host)
        now = time.time()
        if key in seen and now - seen[key] < SEEN_TTL:
            return
        # Prune opportunistically; the table is tiny and bounded by the connection rate.
        if len(seen) > 4096:
            for k, t in list(seen.items()):
                if now - t > SEEN_TTL:
                    del seen[k]
        seen[key] = now
        counts[(host, ips.get(src, src))] += 1

    # `for line in proc.stdout` READS AHEAD and will not yield until its internal buffer fills, so
    # on a low-rate stream — which this is, a handful of ClientHellos a minute — the loop body never
    # runs and nothing is ever written. Measured: nineteen seconds of real traffic produced an empty
    # metrics file. `iter(readline, "")` yields each line as it arrives.
    for line in iter(proc.stdout.readline, ""):
        # THE CLOCK IS CHECKED ON EVERY LINE, and that is not cosmetic. With the timing block after
        # the header/hex branches it only ran on lines that were NEITHER — and under continuous
        # capture every line is one or the other, so the metrics file would never have been
        # written at all. The failure mode is a collector that runs perfectly and produces an
        # empty file for ever, which reads as "no egress".
        now = time.time()
        if now - last_refresh > CONTAINER_REFRESH_SECONDS:
            ips = container_map()
            last_refresh = now
        if now - last_flush > FLUSH_SECONDS:
            write_metrics(counts, unresolved)
            last_flush = now

        if HEADER_RE.match(line):
            flush_packet()
            continue
        m = HEX_RE.match(line)
        if m:
            hexbuf.append(m.group(1).replace(" ", ""))

    flush_packet()
    write_metrics(counts, unresolved)
    # If tcpdump died, say why on the way out — systemd will capture it.
    rc = proc.poll()
    if rc not in (0, None):
        sys.stderr.write(f"tcpdump exited {rc}: {proc.stderr.read()[:400]}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
