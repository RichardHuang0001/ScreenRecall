#!/usr/bin/env python3
"""Low rate host/process sampler for explicit Phase 5 runs; no screenshot content is read."""
import json
import os
import pathlib
import psutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / ".build/DerivedData/Build/Products/Release/ScreenRecall.app/Contents/MacOS/ScreenRecall"
OUT = ROOT / "Validation/phase5-measurements-2026-10-09.json"
CASES = [
    ("A_idle", None, None),
    ("B_one_jpeg", 1, "jpeg"),
    ("C_two_jpeg", 2, "jpeg"),
    ("C_two_heic", 2, "heic"),
    ("D_two_jpeg_competing_cpu", 2, "jpeg"),
]


def cpu_sum(value):
    return value.user + value.system


def sample_process(proc):
    try:
        return {"cpu_seconds": cpu_sum(proc.cpu_times()), "rss_bytes": proc.memory_info().rss}
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return None


def sample_window_server(pid):
    """ps can read WindowServer where libproc denies process task information."""
    try:
        fields = subprocess.check_output(["ps", "-p", str(pid), "-o", "time=,rss="], text=True).split()
        clock = fields[0].split(":")
        seconds = float(clock[-1]) + 60 * int(clock[-2])
        if len(clock) == 3:
            seconds += 3600 * int(clock[0])
        return {"cpu_seconds": seconds, "rss_bytes": int(fields[1]) * 1024}
    except (IndexError, ValueError, subprocess.CalledProcessError):
        return None


def run_case(name, screens, fmt):
    output = ROOT / "Validation" / f"phase5-{name}.json"
    app = None
    load = None
    if screens is not None:
        app = subprocess.Popen([str(APP), "--phase5-benchmark", "--screens", str(screens),
                                "--format", fmt, "--batches", "3", "--interval", "30"],
                               stdout=output.open("w"), stderr=subprocess.PIPE)
    if name.startswith("D_"):
        load = subprocess.Popen([sys.executable, "-c", "import time\nwhile True:\n s=time.monotonic()\n while time.monotonic()-s<.85: pass\n time.sleep(.15)\n"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    window_pids = psutil.pids()
    window = next((psutil.Process(pid) for pid in window_pids if psutil.Process(pid).name() == "WindowServer"), None)
    app_proc = psutil.Process(app.pid) if app else None
    start = time.monotonic()
    host_start = cpu_sum(psutil.cpu_times())
    window_start = sample_window_server(window.pid) if window else None
    app_start = sample_process(app_proc) if app_proc else None
    samples = []
    while time.monotonic() - start < 64:
        samples.append({"elapsed": round(time.monotonic() - start, 3),
                        "app": sample_process(app_proc) if app_proc else None,
                        "windowServer": sample_window_server(window.pid) if window else None,
                        "hostCpuPercent": psutil.cpu_percent(interval=None)})
        time.sleep(1)
    elapsed = time.monotonic() - start
    host_delta = cpu_sum(psutil.cpu_times()) - host_start
    window_end = sample_window_server(window.pid) if window else None
    if app:
        try:
            app.wait(timeout=3)
        except subprocess.TimeoutExpired:
            app.terminate()
            app.wait(timeout=3)
    if load:
        load.terminate()
        load.wait(timeout=3)
    app_samples = [item["app"] for item in samples if item["app"]]
    window_samples = [item["windowServer"] for item in samples if item["windowServer"]]
    last_app = app_samples[-1] if app_samples else None
    return {"name": name, "elapsed_seconds": elapsed, "host_cpu_core_equivalents": host_delta / elapsed,
            "host_cpu_percent_all_cores": host_delta / elapsed / psutil.cpu_count() * 100,
            "app_cpu_seconds": (last_app["cpu_seconds"] - app_start["cpu_seconds"]) if app_start and last_app else None,
            "app_peak_rss_bytes": max((s["rss_bytes"] for s in app_samples), default=None),
            "window_cpu_seconds": (window_end["cpu_seconds"] - window_start["cpu_seconds"])
                                  if window_start and window_end else None,
            "window_peak_rss_bytes": max((s["rss_bytes"] for s in window_samples), default=None),
            "exit_code": app.returncode if app else None,
            "benchmark": json.loads(output.read_text()) if app and output.stat().st_size else None,
            "samples": samples}


def main():
    results = {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               "logical_cpus": psutil.cpu_count(), "cases": []}
    for name, screens, fmt in CASES:
        print(f"Running {name}", flush=True)
        results["cases"].append(run_case(name, screens, fmt))
        OUT.write_text(json.dumps(results, indent=2))
    print(str(OUT), flush=True)


if __name__ == "__main__":
    main()
