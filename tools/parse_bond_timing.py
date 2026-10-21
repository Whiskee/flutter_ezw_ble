#!/usr/bin/env python3
"""Summarize native BleBondTiming JSON using event monotonic time, never logcat time."""
import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path


def read_events(paths):
    """Keep input provenance and reject damaged probe records visibly."""
    events = []
    for path in paths:
        for line_number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if "BleBondTiming" not in line:
                continue
            payload = line.split("BleBondTiming", 1)[1]
            start = payload.find("{")
            if start < 0:
                continue
            try:
                event, _ = json.JSONDecoder().raw_decode(payload[start:])
                if (not event.get("probeId") or not isinstance(event.get("monoNs"), int)
                        or not isinstance(event.get("stage"), str)):
                    raise ValueError("missing probeId/monoNs/stage")
            except (ValueError, AttributeError) as error:
                print(f"{path}:{line_number}: invalid probe record: {error}", file=sys.stderr)
                continue
            event["source"] = str(path)
            event["line"] = line_number
            events.append(event)
    return events


def summarize(events):
    """Missing observations stay empty; a public getter does not prove internal Bond time."""
    groups = defaultdict(list)
    # Include anchor and endpoint so concatenated captures never join a reused ID.
    for event in events:
        groups[(event.get("anchorMonoNs"), event.get("anchorWallMs"),
                event.get("endpoint"), event["probeId"])].append(event)
    rows = []
    for records in groups.values():
        records.sort(key=lambda e: e["monoNs"])
        first = records[0]
        row = {key: first.get(key, "") for key in (
            "probeId", "endpoint", "config", "sessionGeneration", "attemptGeneration", "sessionId")}

        def find(stage, bonded=False):
            return next((e for e in records if e["stage"] == stage and
                         (not bonded or e.get("bondState") == 12)), None)

        def delta(label, begin, end):
            row[label] = round((end["monoNs"] - begin["monoNs"]) / 1_000_000, 3) if begin and end else ""

        public = find("public_bond_state", True)
        background = find("receiver_background", True)
        main = find("receiver_main", True)
        manager = find("manager_entry", True)
        for stage, event in (("public_bonded", public), ("background_bonded", background),
                             ("main_bonded", main), ("manager_bonded", manager)):
            row[f"{stage}_evidence"] = f'{event["source"]}:{event["line"]}' if event else ""
        delta("public_to_background_ms", public, background)
        delta("background_to_main_ms", background, main)
        delta("main_to_manager_ms", main, manager)
        # Choose lock events from the BONDED callback, not its earlier BONDING callback.
        delta("device_monitor_wait_ms", find("device_monitor_wait", True), find("device_monitor_acquired", True))
        delta("discovery_manager_wait_ms", find("discover_manager_wait"), find("discover_manager_acquired"))
        delta("public_to_discover_ms", public, find("discover_call_before"))
        delta("discover_call_ms", find("discover_call_before"), find("discover_call_after"))
        delta("create_bond_call_ms", find("create_bond_before"), find("create_bond_after"))
        after = find("discover_call_after")
        row["discover_started"] = after.get("success", "") if after else ""
        stop = find("probe_stop")
        row["stop_reason"] = stop.get("reason", "") if stop else "missing_stop_record"
        row["errors"] = " | ".join(str(e["error"]) for e in records if e.get("error"))
        row["record_count"] = len(records)
        rows.append(row)
    return rows


def main():
    """Write auditable CSV/JSON reports without contacting or controlling a BLE device."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--out", required=True, type=Path, help="Output directory outside the source tree")
    args = parser.parse_args()
    events = read_events(args.logs)
    if not events:
        parser.error("No valid BleBondTiming records. Check Debug Mode, build source and full logcat capture.")
    rows = summarize(events)
    args.out.mkdir(parents=True, exist_ok=True)
    with (args.out / "bond_timing.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (args.out / "bond_events.json").write_text(json.dumps(events, ensure_ascii=False, indent=2) + "\n")
    print(f"{len(events)} events, {len(rows)} probe windows: {args.out / 'bond_timing.csv'}")
    print("Blank = missing evidence. Negative receiver delta = independent delivery order; not an error.")


if __name__ == "__main__":
    main()
