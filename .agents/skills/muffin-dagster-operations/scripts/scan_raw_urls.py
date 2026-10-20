"""Check every request URL stored in raw Parquet for a credential. Read-only.

    ssh muffin 'docker exec -i $(docker ps -qf name=muffin_muffin-ingest) python -' < scan_raw_urls.py

Stage 1 stores each document's `url` beside its body, and raw files are kept for good, so a key
that travels in a query string would be written to disk for ever. Each keyed provider redacts its
credential parameter in its adapter, as `yahoo_summary.fetch` does with `crumb=redacted`. This
script checks the result on the node: it reads only the `url` column of every file under the raw
root and reports
- every `crumb` value other than `redacted`;
- any credential-named query parameter (`apikey`, `api_key`, `token`, `crtfc_key`, `key`,
  `access_token`);
- any URL containing the value of a credential-named variable in the container's environment
  (`*KEY*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`).

It prints variable NAMES and COUNTS only, never a value. Run it in the code-location container,
whose environment holds the keys, and outside the run windows: it shares that container's memory
limit with every run. Measured 2026-10-20: 61,588 files and 62,959 URLs in 120 s, at a 132 MB peak.
"""

import os
import re
import resource
import time
from urllib.parse import parse_qsl, urlsplit

import pyarrow.parquet as pq

ROOT = "/var/lib/muffin-ingest/raw"
CREDENTIAL_PARAMS = {"apikey", "api_key", "token", "crtfc_key", "key", "access_token"}

creds = [
    (name, value)
    for name, value in sorted(os.environ.items())
    if re.search(r"(KEY|TOKEN|SECRET|PASSWORD)", name) and len(value) >= 8
]

started = time.time()
files = no_url = unreadable = urls = 0
crumb_redacted = crumb_other = crumb_elsewhere = 0
param_hits: dict[str, int] = {}
value_hits: dict[str, int] = {}
per_asset: dict[str, list[int]] = {}

for dirpath, _, filenames in os.walk(ROOT):
    for filename in filenames:
        if not filename.endswith(".parquet"):
            continue
        path = os.path.join(dirpath, filename)
        asset = os.path.relpath(path, ROOT).split(os.sep)[0]
        files += 1
        try:
            if "url" not in pq.read_schema(path).names:
                no_url += 1
                continue
            column = pq.read_table(path, columns=["url"]).column("url").to_pylist()
        except Exception:
            unreadable += 1
            continue
        counts = per_asset.setdefault(asset, [0, 0])
        counts[0] += 1
        for url in column:
            if not url:
                continue
            urls += 1
            counts[1] += 1
            parts = urlsplit(url)
            for key, value in parse_qsl(parts.query, keep_blank_values=True):
                key = key.lower()
                if key == "crumb":
                    if value == "redacted":
                        crumb_redacted += 1
                    else:
                        crumb_other += 1
                elif key in CREDENTIAL_PARAMS:
                    param_hits[key] = param_hits.get(key, 0) + 1
            if "crumb" in (parts.netloc + parts.path).lower():
                crumb_elsewhere += 1
            for name, value in creds:
                if value in url:
                    value_hits[name] = value_hits.get(name, 0) + 1

print(f"files {files}: with a url column {sum(c[0] for c in per_asset.values())}, "
      f"without {no_url}, unreadable {unreadable}")
print(f"stored urls {urls}")
for asset in sorted(per_asset):
    print(f"  {asset}: files {per_asset[asset][0]}, urls {per_asset[asset][1]}")
print(f"crumb=redacted {crumb_redacted}; any other crumb value {crumb_other}; "
      f"'crumb' outside the query {crumb_elsewhere}")
print(f"credential-named parameters: {param_hits or 'none'}")
print(f"compared against {len(creds)} variables: {', '.join(name for name, _ in creds)}")
print(f"urls containing one of their values: {value_hits or 'none'}")
print(f"{time.time() - started:.0f} s, peak rss {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024} MB")
