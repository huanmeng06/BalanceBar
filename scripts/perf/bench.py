#!/usr/bin/env python3
"""BalanceBar background performance bench.

Launches a built BalanceBar app with an isolated temporary HOME, drives one
scenario, samples CPU / memory / disk bytes read, and writes a Markdown report.
Standard library only; no network access is needed. See scripts/perf/README.md.
"""

import argparse
import ctypes
import datetime
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

SCENARIOS = {
    "idle": (1800, "空闲：不产生任何 transcript 写入"),
    "single-writer": (300, "单会话持续写入 transcript"),
    "multi-writer": (300, "4 个并发写入方各写一个会话 transcript"),
    "sleep-wake": (300, "模拟休眠唤醒：SIGSTOP 暂停进程后 SIGCONT 恢复"),
}
WRITER_INTERVAL_SECONDS = 1.0
SLEEP_CYCLE_SECONDS = 60
SLEEP_PAUSE_SECONDS = 30


class RUsageInfoV2(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
    ]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_timebase = MachTimebase()
_libc.mach_timebase_info(ctypes.byref(_timebase))


def rusage(pid):
    info = RUsageInfoV2()
    if _libc.proc_pid_rusage(pid, 2, ctypes.byref(info)) != 0:
        return None
    to_ns = _timebase.numer / _timebase.denom
    return {
        "cpu_ns": (info.ri_user_time + info.ri_system_time) * to_ns,
        "footprint": info.ri_phys_footprint,
        "bytes_read": info.ri_diskio_bytesread,
        "wakeups": info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
    }


def fake_home(root):
    home = os.path.join(root, "home")
    for path in (".claude/projects", ".codex/sessions", ".grok"):
        os.makedirs(os.path.join(home, path), exist_ok=True)
    return home


def writer(home, index, stop):
    project = os.path.join(home, ".claude/projects", f"-tmp-perf-project-{index}")
    os.makedirs(project, exist_ok=True)
    session = str(uuid.uuid4())
    path = os.path.join(project, f"{session}.jsonl")
    seq = 0
    while not stop.is_set():
        seq += 1
        line = {
            "type": "assistant" if seq % 2 else "user",
            "sessionId": session,
            "uuid": str(uuid.uuid4()),
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "message": {"role": "assistant", "content": [{"type": "text", "text": "perf " * 40}]},
        }
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(line) + "\n")
        stop.wait(WRITER_INTERVAL_SECONDS)


def sleep_wake(pid, stop, events):
    while not stop.wait(SLEEP_CYCLE_SECONDS - SLEEP_PAUSE_SECONDS):
        os.kill(pid, signal.SIGSTOP)
        events.append(("stop", time.monotonic()))
        stopped = stop.wait(SLEEP_PAUSE_SECONDS)
        os.kill(pid, signal.SIGCONT)
        events.append(("cont", time.monotonic()))
        if stopped:
            return


def measure_menu_open(bundle_name):
    """Optional: click the status item via System Events (needs Accessibility)."""
    script = (
        f'tell application "System Events" to tell process "{bundle_name}" '
        "to click menu bar item 1 of menu bar 2"
    )
    started = time.monotonic()
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=30)
    elapsed = (time.monotonic() - started) * 1000
    subprocess.run(["osascript", "-e", 'tell application "System Events" to key code 53'],
                   capture_output=True, timeout=10)
    if result.returncode != 0:
        return None, result.stderr.strip()
    return elapsed, ""


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


def git_head():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def isolated_copy(app, root):
    """Copy the app with a `.perf` bundle id so it neither collides with another running
    instance (the app refuses duplicates) nor shares its UserDefaults domain."""
    copy = os.path.join(root, os.path.basename(app))
    subprocess.run(["ditto", app, copy], check=True)
    plist = os.path.join(copy, "Contents/Info.plist")
    identifier = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", plist],
                                capture_output=True, text=True, check=True).stdout.strip()
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {identifier}.perf", plist],
                   check=True)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", copy], check=True,
                   capture_output=True)
    executable_dir = os.path.join(copy, "Contents/MacOS")
    return os.path.join(executable_dir, sorted(os.listdir(executable_dir))[0])


def run(args):
    if not os.path.isdir(os.path.join(args.app, "Contents/MacOS")):
        sys.exit(f"app not found: {args.app} (build it with ./scripts/build.sh dev)")
    duration = args.duration or SCENARIOS[args.scenario][0]

    with tempfile.TemporaryDirectory(prefix="balancebar-perf-") as root:
        executable = isolated_copy(args.app, root)
        home = fake_home(root)
        env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home)
        process = subprocess.Popen([executable], env=env, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        stop = threading.Event()
        threads, events = [], []
        try:
            time.sleep(args.warmup)
            if args.scenario in ("single-writer", "multi-writer"):
                count = 1 if args.scenario == "single-writer" else 4
                threads = [threading.Thread(target=writer, args=(home, i, stop), daemon=True)
                           for i in range(count)]
            elif args.scenario == "sleep-wake":
                threads = [threading.Thread(target=sleep_wake, args=(process.pid, stop, events),
                                            daemon=True)]
            menu = None
            menu_error = "未测量（使用 --menu 启用，需要辅助功能权限）"
            if args.menu:
                menu, menu_error = measure_menu_open(os.path.basename(executable))
            first = rusage(process.pid)
            if first is None:
                sys.exit("app exited during warmup")
            for thread in threads:
                thread.start()
            samples, previous, start = [], first, time.monotonic()
            while time.monotonic() - start < duration and process.poll() is None:
                time.sleep(args.interval)
                current = rusage(process.pid)
                if current is None:
                    break
                wall = args.interval * 1e9
                samples.append({
                    "cpu_pct": (current["cpu_ns"] - previous["cpu_ns"]) / wall * 100,
                    "footprint": current["footprint"],
                })
                previous = current
            elapsed = time.monotonic() - start
            stop.set()
            for thread in threads:
                thread.join(timeout=SLEEP_PAUSE_SECONDS + 5)
            last = rusage(process.pid) or previous
        finally:
            stop.set()
            if process.poll() is None:
                os.kill(process.pid, signal.SIGCONT)
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()

    cpu = [s["cpu_pct"] for s in samples]
    mem = [s["footprint"] / 1048576 for s in samples]
    total_cpu_s = (last["cpu_ns"] - first["cpu_ns"]) / 1e9
    read_mb = (last["bytes_read"] - first["bytes_read"]) / 1048576
    rows = [
        ("实际采样时长", f"{elapsed:.0f} s（{len(samples)} 个样本，间隔 {args.interval:g} s）"),
        ("CPU 平均 / p95 / 峰值", f"{sum(cpu) / max(len(cpu), 1):.2f}% / {percentile(cpu, .95):.2f}% / {max(cpu, default=0):.2f}%"),
        ("CPU 总时间", f"{total_cpu_s:.2f} s"),
        ("内存 footprint 起始 / 结束 / 峰值", f"{mem[0] if mem else 0:.1f} / {mem[-1] if mem else 0:.1f} / {max(mem, default=0):.1f} MB"),
        ("磁盘读取量", f"{read_mb:.2f} MB"),
        ("唤醒次数", f"{last['wakeups'] - first['wakeups']}"),
        ("菜单打开耗时", f"{menu:.0f} ms" if menu is not None else menu_error),
    ]
    if args.scenario == "sleep-wake":
        rows.append(("休眠/唤醒周期", f"{sum(1 for e in events if e[0] == 'cont')} 次（每 {SLEEP_CYCLE_SECONDS} s 暂停 {SLEEP_PAUSE_SECONDS} s）"))
    report = [
        f"## BalanceBar 性能报告：`{args.scenario}`",
        "",
        f"- 场景：{SCENARIOS[args.scenario][1]}",
        f"- 提交：`{git_head()}`；App：`{os.path.basename(args.app)}`",
        f"- 时间：{datetime.datetime.now().astimezone().isoformat(timespec='seconds')}；macOS {subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip()}",
        f"- 环境：隔离的临时 HOME，预热 {args.warmup:g} s，无网络依赖",
        "",
        "| 指标 | 数值 |",
        "| --- | --- |",
    ] + [f"| {name} | {value} |" for name, value in rows]
    if elapsed < duration - args.interval:
        sys.exit(f"app exited after {elapsed:.0f}s of {duration:.0f}s; no report written")
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "a" if args.append else "w", encoding="utf-8") as handle:
        handle.write(("\n" if args.append and handle.tell() else "") + "\n".join(report) + "\n")
    print(f"report written: {args.output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("scenario", choices=sorted(SCENARIOS))
    parser.add_argument("--duration", type=float, help="采样秒数（默认 idle=1800，其他=300）")
    parser.add_argument("--output", default="build/perf/report.md", help="Markdown 报告路径")
    parser.add_argument("--append", action="store_true", help="追加到已有报告")
    parser.add_argument("--app", default="build/dev/BalanceBar-dev.app", help="要测量的 .app")
    parser.add_argument("--interval", type=float, default=5.0, help="采样间隔秒数")
    parser.add_argument("--warmup", type=float, default=15.0, help="启动后预热秒数")
    parser.add_argument("--menu", action="store_true", help="通过 System Events 测量菜单打开耗时")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
