"""Summarize real WidgetKit callbacks and the age of the data they read."""
import json
import re
import statistics
import sys
from pathlib import Path

path = Path(sys.argv[1] if len(sys.argv) > 1 else "diagnostics/widget-refresh/probe.ndjson")
runs = []
for line in path.read_text().splitlines():
    try:
        event = json.loads(line)
    except ValueError:
        continue
    message = event.get("eventMessage", "")
    if message.startswith("PROBE phase=") or message.startswith("PROBE interval="):
        runs.append({"phase": message.split("=", 1)[1], "host": [], "widget": [], "configurations": []})
    if not runs:
        continue
    run = runs[-1]
    if "configurations" in message:
        run["configurations"].append(message)
    match = re.search(r"sample epoch=([\d.]+) request=(true|false)", message)
    if match:
        run["host"].append((float(match[1]), match[2] == "true"))
    match = re.search(r"timeline kind=(\S+) callback=([\d.]+) sampled=(-?[\d.]+)", message)
    if match:
        run["widget"].append((match[1], float(match[2]), float(match[3])))

def intervals(times):
    differences = [b - a for a, b in zip(times, times[1:])]
    if not differences:
        return {}
    return {"min": round(min(differences), 3), "median": round(statistics.median(differences), 3),
            "max": round(max(differences), 3)}

summary = []
for run in runs:
    host = run["host"]
    result = {"request_interval": run["phase"], "samples": len(host),
              "host_sample_intervals_seconds": intervals([t for t, _ in host]),
              "requests": sum(request for _, request in host), "widgets": {}}
    for kind in sorted({row[0] for row in run["widget"]}):
        rows = [row for row in run["widget"] if row[0] == kind]
        times = [row[1] for row in rows]
        seen_samples = set()
        updates = []
        for _, callback, sampled in rows:
            if sampled > 0 and sampled not in seen_samples:
                seen_samples.add(sampled)
                updates.append(callback)
        ages = [t - sampled for _, t, sampled in rows if sampled > 0]
        result["widgets"][kind] = {
            "callbacks": len(rows), "observed_seconds": round(times[-1] - times[0], 3),
            "callback_intervals_seconds": intervals(times),
            "distinct_samples_read": len(updates),
            "new_sample_intervals_seconds": intervals(updates),
            "missing_snapshots": sum(sampled < 0 for _, _, sampled in rows),
            "sample_age_median_seconds": round(statistics.median(ages), 3) if ages else None,
            "sample_age_max_seconds": round(max(ages), 3) if ages else None}
    summary.append(result)
print(json.dumps(summary, indent=2, ensure_ascii=False))
