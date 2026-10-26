#!/usr/bin/env python3
"""Reduce `xctrace export` XML tables of a Power Profiler trace (attached to one process) to one
JSON line.

Usage: python3 -I summarise_trace.py --dir <exports dir> --pid <pid> --label L --scenario S
                                     --duration 180 [--csv summary.csv]

Expects <dir>/ProcessSubsystemPowerImpact.xml, ProcessQOSExecution.xml, SystemPowerLevel.xml and
device-thermal-state-intervals.xml (see device_energy.sh). Metrics:

  cpu_pct            CPU time of the process / wall time of the recording (ProcessQOSExecution)
  cpu_instr_per_s    retired instructions per second (ProcessSubsystemPowerImpact)
  cpu/gpu/display/net_impact   duration-weighted mean of Instruments' 0-20 "power impact" score
                     (coarse: quantised to 0.1 and usually 0.0 for a quiet app)
  wifi_rx_kb / wifi_tx_kb      bytes transferred over Wi-Fi during the recording
  system_pct_per_hr  device battery drain model (0 while the device is charging)
  thermal_worst      worst device thermal state seen during the recording
"""
import argparse
import csv
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xctrace_xml import read_table  # noqa: E402

THERMAL_ORDER = ["Nominal", "Fair", "Serious", "Critical"]


def pid_of(label):
    m = re.search(r"\((\d+)\)\s*$", label or "")
    return int(m.group(1)) if m else None


def f(value):
    return float(value) if value not in (None, "") else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--csv")
    ap.add_argument("--stub-requests", type=int, help="HTTP requests seen by the stub server while recording")
    a = ap.parse_args()

    _, impact = read_table(os.path.join(a.dir, "ProcessSubsystemPowerImpact.xml"))
    impact = [r for r in impact if pid_of(r["process"]) == a.pid]
    # Wall time covered by the table (ns). Rows of different kinds overlap, so use the span.
    starts = [f(r["start"]) for r in impact]
    ends = [f(r["start"]) + f(r["duration"]) for r in impact]
    wall_ns = (max(ends) - min(starts)) if impact else a.duration * 1e9
    wall_s = wall_ns / 1e9

    def weighted(key):
        num = den = 0.0
        for r in impact:
            v = f(r[key])
            if v is None:
                continue
            d = f(r["duration"])
            num += v * d
            den += d
        return round(num / den, 4) if den else None

    def total(key):
        return sum(f(r[key]) or 0.0 for r in impact)

    _, qos = read_table(os.path.join(a.dir, "ProcessQOSExecution.xml"))
    cpu_ns = sum(f(r["qos-duration"]) or 0.0 for r in qos if pid_of(r["process"]) == a.pid)

    _, sysp = read_table(os.path.join(a.dir, "SystemPowerLevel.xml"))
    num = den = 0.0
    for r in sysp:
        v, d = f(r["power-usage"]), f(r["duration"])
        if v is not None and d:
            num += v * d
            den += d

    thermal = []
    try:
        _, th = read_table(os.path.join(a.dir, "device-thermal-state-intervals.xml"))
        thermal = [r["thermal-state"] for r in th if r["thermal-state"] in THERMAL_ORDER]
    except Exception:  # table is optional
        pass

    out = {
        "label": a.label,
        "scenario": a.scenario,
        "duration_s": a.duration,
        "pid": a.pid,
        "wall_s": round(wall_s, 1),
        "cpu_pct": round(cpu_ns / wall_ns * 100.0, 3) if wall_ns else None,
        "cpu_instr_per_s": round(total("cpu-instructions") / wall_s) if wall_s else None,
        "cpu_impact": weighted("cpu-impact"),
        "gpu_impact": weighted("gpu-impact"),
        "display_impact": weighted("display-impact"),
        "net_impact": weighted("networking-impact"),
        "wifi_rx_kb": round(total("wifi-received") / 1024, 1),
        "wifi_tx_kb": round(total("wifi-transmitted") / 1024, 1),
        "system_pct_per_hr": round(num / den, 3) if den else None,
        "stub_requests": a.stub_requests,
        "thermal_worst": max(thermal, key=THERMAL_ORDER.index) if thermal else None,
    }
    print(json.dumps(out, ensure_ascii=False))
    if a.csv:
        new = not os.path.exists(a.csv)
        with open(a.csv, "a", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(out))
            if new:
                w.writeheader()
            w.writerow(out)


if __name__ == "__main__":
    main()
