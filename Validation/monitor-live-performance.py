#!/usr/bin/env python3
"""Read-only, five-minute resource sample of the installed ScreenRecall process.

Reads process counters and SQLite metadata only. It never opens screenshot files.
"""
import json
import pathlib
import psutil
import sqlite3
import statistics
import subprocess
import time
from datetime import datetime, timezone

APP_EXE = "/Applications/ScreenRecall.app/Contents/MacOS/ScreenRecall"
DB = pathlib.Path.home() / "Library/Application Support/ScreenRecall/history.sqlite"
OUT = pathlib.Path(__file__).resolve().parent / "live-five-minute-2026-10-10.json"
DURATION = 300.0
INTERVAL = 0.25


def find_app():
    candidates = []
    for process in psutil.process_iter(["pid", "exe"]):
        try:
            if process.info["exe"] == APP_EXE:
                candidates.append(process)
        except (psutil.AccessDenied, psutil.NoSuchProcess):
            pass
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one installed ScreenRecall process, found {len(candidates)}")
    return candidates[0]


def cpu_seconds(process):
    value = process.cpu_times()
    return value.user + value.system


def host_busy_seconds():
    value = psutil.cpu_times()
    return value.user + value.nice + value.system


def window_server_sample(pid):
    try:
        fields = subprocess.check_output(["ps", "-p", str(pid), "-o", "time=,rss="], text=True).split()
        clock = fields[0].split(":")
        seconds = float(clock[-1]) + 60 * int(clock[-2])
        if len(clock) == 3:
            seconds += 3600 * int(clock[0])
        return {"wallTime": time.time(), "cpuSeconds": seconds, "rssBytes": int(fields[1]) * 1024}
    except (IndexError, ValueError, subprocess.CalledProcessError):
        return None


def battery_state():
    try:
        return subprocess.check_output(["pmset", "-g", "batt"], text=True).strip()
    except subprocess.CalledProcessError:
        return "unavailable"


def batches_and_assets(start_wall, end_wall):
    with sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=2) as database:
        batches = database.execute("""
            SELECT id, started_at, ended_at, status, expected_count, success_count
            FROM batches WHERE started_at >= ? AND started_at < ? ORDER BY started_at
        """, (start_wall, end_wall)).fetchall()
        assets = database.execute("""
            SELECT batch_id, count(*), sum(byte_count)
            FROM assets WHERE created_at >= ? AND created_at < ?
            GROUP BY batch_id
        """, (start_wall, end_wall)).fetchall()
    asset_counts = {batch_id: {"count": count, "bytes": int(size)} for batch_id, count, size in assets}
    return [{"id": batch_id, "startedAt": started, "endedAt": ended,
             "status": status, "expectedCount": expected, "successCount": success,
             "assets": asset_counts.get(batch_id, {"count": 0, "bytes": 0})}
            for batch_id, started, ended, status, expected, success in batches]


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * fraction)]


def main():
    process = find_app()
    window_pid = next((p.pid for p in psutil.process_iter(["pid", "name"])
                       if p.info["name"] == "WindowServer"), None)
    start_wall = time.time()
    start_mono = time.monotonic()
    initial_cpu = cpu_seconds(process)
    initial_host = host_busy_seconds()
    initial_window = window_server_sample(window_pid) if window_pid else None
    start_battery = battery_state()
    samples = []
    window_samples = [initial_window] if initial_window else []
    last_cpu = initial_cpu
    last_mono = start_mono
    tick = 0
    next_window = start_mono + 2
    print(f"Monitoring PID {process.pid} for {DURATION:.0f} seconds; no screenshot files are read", flush=True)
    while True:
        target = start_mono + tick * INTERVAL
        now = time.monotonic()
        if now < target:
            time.sleep(target - now)
        now = time.monotonic()
        if now - start_mono >= DURATION:
            break
        if not process.is_running() or process.status() == psutil.STATUS_ZOMBIE:
            raise RuntimeError("Installed app exited during measurement")
        current_cpu = cpu_seconds(process)
        rss = process.memory_info().rss
        delta = max(0.0, current_cpu - last_cpu)
        elapsed = max(0.001, now - last_mono)
        samples.append({"wallTime": time.time(), "elapsedSeconds": now - start_mono,
                        "appCpuSeconds": current_cpu, "cpuDeltaSeconds": delta,
                        "cpuPercentOneCore": 100 * delta / elapsed, "rssBytes": rss})
        last_cpu = current_cpu
        last_mono = now
        if now >= next_window and window_pid:
            value = window_server_sample(window_pid)
            if value:
                window_samples.append(value)
            next_window += 2
        tick += 1
        if tick % 240 == 0:
            print(f"{min(300, round(now - start_mono))}/300 seconds sampled", flush=True)
    end_wall = time.time()
    end_mono = time.monotonic()
    final_cpu = cpu_seconds(process)
    final_host = host_busy_seconds()
    final_window = window_server_sample(window_pid) if window_pid else None
    if final_window:
        window_samples.append(final_window)
    batches = batches_and_assets(start_wall, end_wall)
    for batch in batches:
        if batch["endedAt"] is None:
            batch["appCpuSecondsNearBatch"] = None
            continue
        near = [s for s in samples if batch["startedAt"] - 0.25 <= s["wallTime"] <= batch["endedAt"] + 1.5]
        batch["appCpuSecondsNearBatch"] = round(sum(s["cpuDeltaSeconds"] for s in near), 4)
        batch["peakCpuPercentQuarterSecond"] = round(max((s["cpuPercentOneCore"] for s in near), default=0), 2)
        batch["peakRssBytes"] = max((s["rssBytes"] for s in near), default=None)
    wall_duration = end_mono - start_mono
    cpu_delta = final_cpu - initial_cpu
    rss_values = [s["rssBytes"] for s in samples]
    cpu_values = [s["cpuPercentOneCore"] for s in samples]
    summary = {
        "durationSeconds": wall_duration,
        "sampleIntervalSeconds": INTERVAL,
        "sampleCount": len(samples),
        "appCpuSeconds": cpu_delta,
        "appAverageCpuPercentOneCore": 100 * cpu_delta / wall_duration,
        "appPeakCpuPercentQuarterSecond": max(cpu_values),
        "appP95CpuPercentQuarterSecond": percentile(cpu_values, .95),
        "appMedianRssBytes": int(statistics.median(rss_values)),
        "appP95RssBytes": percentile(rss_values, .95),
        "appPeakRssBytes": max(rss_values),
        "hostBusyCoreEquivalents": (final_host - initial_host) / wall_duration,
        "windowServerCpuSeconds": (final_window["cpuSeconds"] - initial_window["cpuSeconds"])
                                  if initial_window and final_window else None,
        "completeBatches": sum(b["status"] == "complete" for b in batches),
        "batchCount": len(batches),
        "successfulFrames": sum(b["successCount"] for b in batches),
        "expectedFrames": sum(b["expectedCount"] for b in batches),
        "newImageBytes": sum(b["assets"]["bytes"] for b in batches),
    }
    report = {"startedAt": datetime.fromtimestamp(start_wall, timezone.utc).isoformat(),
              "endedAt": datetime.fromtimestamp(end_wall, timezone.utc).isoformat(),
              "pid": process.pid, "processPath": APP_EXE, "batteryStart": start_battery,
              "batteryEnd": battery_state(), "summary": summary,
              "batches": batches, "samples": samples, "windowServerSamples": window_samples,
              "samplerCpuSeconds": time.process_time()}
    OUT.write_text(json.dumps(report, indent=2))
    print(json.dumps({"output": str(OUT), "summary": summary}, indent=2), flush=True)


if __name__ == "__main__":
    main()
