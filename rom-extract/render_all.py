#!/usr/bin/env python3
"""Render all effect.bin entries with a hard external memory watchdog.

macOS does not enforce setrlimit(RLIMIT_DATA), so each entry runs in its own
subprocess whose real RSS is polled every 0.5 s; exceeding --mem-mb (default
1200) or --timeout (default 180 s) kills that entry and marks it failed,
instead of taking the whole machine down.

Resumable: finished entries have a marker in out/effects/_status/ and are
skipped on re-run.

Usage: render_all.py [--rom rom.nds] [--out out] [--mem-mb 1200] [--timeout 180]
"""

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PYTHON = sys.executable
RENDER_ONE = os.path.join(HERE, "render_one.py")


def log(msg):
    print(msg, flush=True)


def rss_mb(pid):
    """Real resident memory of a child, in MB (Unix: ps; Windows: psapi)."""
    if sys.platform == "win32":
        import ctypes
        import ctypes.wintypes as wt

        class PMC(ctypes.Structure):
            _fields_ = [
                ("cb", wt.DWORD), ("PageFaultCount", wt.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        h = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return 0
        try:
            pmc = PMC()
            pmc.cb = ctypes.sizeof(PMC)
            if ctypes.windll.psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb):
                return pmc.WorkingSetSize / (1024 * 1024)
            return 0
        finally:
            ctypes.windll.kernel32.CloseHandle(h)
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True)
        return int(out.stdout.strip() or 0) / 1024
    except (ValueError, OSError):
        return 0


def dump_raws(rom_path, out):
    """Write every effect.bin entry as effects/effect_NNNN.bin (cheap, main process)."""
    from ndspy.rom import NintendoDSRom
    from skytemple_files.common.types.file_types import FileType

    rom = NintendoDSRom.fromFile(rom_path)
    bin_pack = FileType.BIN_PACK.deserialize(rom.getFileByName("EFFECT/effect.bin"))
    for i, data in enumerate(bin_pack):
        path = os.path.join(out, f"effect_{i:04d}.bin")
        if not os.path.isfile(path):
            with open(path, "wb") as f:
                f.write(bytes(data))
    return len(bin_pack)


def load_usage(out_root):
    """Effect file index -> set of AnimType names, from the extracted general table."""
    usage = {}
    ga_path = os.path.join(out_root, "anim", "general_animations.json")
    if os.path.isfile(ga_path):
        with open(ga_path, encoding="utf-8") as f:
            for entry in json.load(f):
                usage.setdefault(entry["anim_file"], set()).add(entry["anim_type"])
    return usage


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rom", default=os.path.join(HERE, "rom.nds"))
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    ap.add_argument("--mem-mb", type=int, default=1200)
    ap.add_argument("--timeout", type=int, default=180)
    args = ap.parse_args()

    effects_dir = os.path.join(args.out, "effects")
    status_dir = os.path.join(effects_dir, "_status")
    os.makedirs(status_dir, exist_ok=True)

    log("dumping raw effect entries from ROM...")
    total = dump_raws(args.rom, effects_dir)
    usage = load_usage(args.out)
    log(f"{total} entries; watchdog: {args.mem_mb} MB RSS / {args.timeout} s per entry")

    stats = {"done_before": 0, "exported": 0, "raw_only": 0, "killed_mem": 0, "killed_time": 0}
    for i in range(total):
        status_path = os.path.join(status_dir, f"effect_{i:04d}.json")
        if os.path.isfile(status_path):
            stats["done_before"] += 1
            continue

        types = sorted(usage.get(i, set()))
        screen_first = "1" if types and set(types) <= {"SCREEN", "WBA"} else "0"
        proc = subprocess.Popen(
            [
                PYTHON,
                RENDER_ONE,
                os.path.join(effects_dir, f"effect_{i:04d}.bin"),
                os.path.join(effects_dir, f"effect_{i:04d}"),
                status_path,
                ",".join(types),
                screen_first,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        started = time.time()
        verdict = None
        while proc.poll() is None:
            time.sleep(0.5)
            mem = rss_mb(proc.pid)
            if mem > args.mem_mb:
                verdict = "killed_mem"
            elif time.time() - started > args.timeout:
                verdict = "killed_time"
            if verdict:
                proc.kill()   # SIGKILL equivalent; also exists on Windows
                proc.wait()
                break

        if verdict:
            stats[verdict] += 1
            with open(status_path, "w", encoding="utf-8") as f:
                json.dump(
                    {"index": i, "used_as": types, "exported": "failed", "error": verdict}, f
                )
            log(f"  ! effect {i:04d} {verdict} ({types})")
        elif proc.returncode == 0:
            stats["exported"] += 1
        else:
            stats["raw_only"] += 1
            log(f"  . effect {i:04d} raw_only ({types})")

        done = sum(stats.values())
        if done % 20 == 0:
            log(f"  {done}/{total} processed")

    # Rebuild the final index from the status markers
    index = []
    for i in range(total):
        status_path = os.path.join(status_dir, f"effect_{i:04d}.json")
        if os.path.isfile(status_path):
            with open(status_path, encoding="utf-8") as f:
                index.append(json.load(f))
    with open(os.path.join(effects_dir, "effects_index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)

    log(f"finished: {stats}")
    ok = sum(1 for e in index if e.get("exported") in ("wan", "screen"))
    log(f"exported sheets for {ok}/{total} effect files")


if __name__ == "__main__":
    main()
