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
import shutil
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
    "sleep-wake": (300, "模拟休眠唤醒：1 个写入方 + SIGSTOP 暂停进程后 SIGCONT 恢复"),
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


MENU_SCRIPT = r"""
function run(argv) {
  var name = argv[0], rounds = parseInt(argv[1], 10);
  var se = Application("System Events");
  var proc = se.processes.byName(name);
  var item = proc.menuBars[1].menuBarItems[0];
  item.name();                                   // warm-up: resolve process + AX path, untimed
  var results = [];
  for (var i = 0; i < rounds; i++) {
    if (proc.menus.length > 0) return JSON.stringify({error: "menu already open before click"});
    var t0 = Date.now();
    item.click();
    var tClick = Date.now(), t1 = null;
    if (proc.menus.length > 0 || item.menus.length > 0) {
      // click() did not return until tracking had begun; endpoint is not observable separately
      t1 = tClick;
    }
    while (t1 === null && Date.now() - t0 < 2000) {
      if (item.menus.length > 0 || proc.windows.length > 0) t1 = Date.now();
      else delay(0.005);
    }
    se.keyCode(53);
    delay(0.5);
    if (t1 === null) return JSON.stringify({error: "menu did not appear within 2 s"});
    results.push({open_ms: t1 - t0, click_ms: tClick - t0});
  }
  return JSON.stringify({results: results});
}
"""
MENU_ROUNDS = 5


def measure_menu_open(process_name):
    """Optional: open the status menu via System Events (needs Accessibility).

    Timing runs inside one JXA process after a warm-up, so osascript start-up and the
    System Events connection are excluded; t0 is taken just before the click and t1 when
    the menu is observed. If click() blocks until the menu is up, the value would include
    AX round-trip only, which is reported as-is; failures report 未测量 instead of a number.
    """
    try:
        result = subprocess.run(["osascript", "-l", "JavaScript", "-e", MENU_SCRIPT, process_name,
                                 str(MENU_ROUNDS)], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return None, "未测量（osascript 超时：click 可能阻塞到菜单关闭）"
    if result.returncode != 0:
        return None, f"未测量（{result.stderr.strip()[:120] or 'osascript 失败'}）"
    payload = json.loads(result.stdout.strip() or "{}")
    if "error" in payload:
        return None, f"未测量（{payload['error']}）"
    values = sorted(r["open_ms"] for r in payload["results"])
    return values, ""


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


SANDBOX_PROFILE = (
    "(version 1)(allow default)"
    # setuid binaries cannot exec inside a sandbox; ps (no networking) is how the app
    # detects CLI processes, so it alone runs unsandboxed.
    '(allow process-exec (literal "/bin/ps") (with no-sandbox))'
    "(deny network-outbound (remote ip))(deny network-inbound (remote ip))"
)
WRITER_COUNTS = {"single-writer": 1, "multi-writer": 4, "sleep-wake": 1}


def verify_network_sandbox():
    """The profile must block direct egress, otherwise isolation is not proven."""
    probe = subprocess.run(["/usr/bin/sandbox-exec", "-p", SANDBOX_PROFILE, "/usr/bin/curl",
                            "--noproxy", "*", "-sS", "-m", "5", "-o", "/dev/null",
                            "https://api.github.com"], capture_output=True, text=True)
    if probe.returncode == 0:
        sys.exit("网络隔离失效：sandbox-exec 下 curl 仍可访问 api.github.com；不写报告")


def inet_sockets(pid):
    out = subprocess.run(["lsof", "-nP", "-a", "-i", "-p", str(pid)], capture_output=True,
                         text=True).stdout
    return [line for line in out.splitlines()[1:] if line.strip()]


def verify_atime(root):
    """Read evidence relies on atime advancing when a file newer than its atime is read."""
    path = os.path.join(root, "atime-probe")
    with open(path, "w") as handle:
        handle.write("a")
    os.utime(path, (time.time() - 60, time.time() - 60))
    with open(path, "a") as handle:
        handle.write("b")
    before = os.stat(path).st_atime
    with open(path) as handle:
        handle.read()
    if os.stat(path).st_atime <= before:
        sys.exit("场景无效：此卷不更新 atime，无法验证 App 是否读取 transcript；不写报告")


def fake_claude_cli(root):
    """A `claude`-named process so ClaudeCodeActivityMonitor sees a running CLI."""
    bin_dir = os.path.join(root, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    path = os.path.join(bin_dir, "claude")
    shutil.copy("/bin/sleep", path)
    return subprocess.Popen([path, "100000"], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


TERMINAL_BUNDLE_ID = "com.apple.Terminal"
MIN_TERMINAL_FRONT_FRACTION = 0.75


def frontmost_bundle_id():
    front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(["lsappinfo", "info", "-only", "bundleid", front], capture_output=True,
                          text=True).stdout
    return info.split("=", 1)[1].strip().strip('"') if "=" in info else ""


def transcript_atimes(home):
    result = {}
    projects = os.path.join(home, ".claude/projects")
    for directory, _, files in os.walk(projects):
        for name in files:
            if name.endswith(".jsonl"):
                path = os.path.join(directory, name)
                try:
                    result[path] = os.stat(path).st_atime_ns
                except FileNotFoundError:
                    pass
    return result


def run(args):
    if not os.path.isdir(os.path.join(args.app, "Contents/MacOS")):
        sys.exit(f"app not found: {args.app} (build it with ./scripts/build.sh dev)")
    duration = args.duration or SCENARIOS[args.scenario][0]
    writers = WRITER_COUNTS.get(args.scenario, 0)
    verify_network_sandbox()

    with tempfile.TemporaryDirectory(prefix="balancebar-perf-") as root:
        verify_atime(root)
        executable = isolated_copy(args.app, root)
        home = fake_home(root)
        env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home)
        cli = fake_claude_cli(root) if writers and not args.no_fake_cli else None
        process = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", SANDBOX_PROFILE, executable],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stop = threading.Event()
        threads, events = [], []
        try:
            time.sleep(args.warmup)
            threads = [threading.Thread(target=writer, args=(home, i, stop), daemon=True)
                       for i in range(writers)]
            if args.scenario == "sleep-wake":
                threads.append(threading.Thread(target=sleep_wake,
                                                args=(process.pid, stop, events), daemon=True))
            menu = None
            menu_error = "未测量（使用 --menu 启用，需要辅助功能权限）"
            if args.menu:
                menu, menu_error = measure_menu_open(os.path.basename(executable))
            first = rusage(process.pid)
            if first is None:
                sys.exit("app exited during warmup; no report written")
            if writers:
                # ActivityCoordinator only samples Claude transcripts with a terminal frontmost.
                subprocess.run(["open", "-b", "com.apple.Terminal"], check=False)
            for thread in threads:
                thread.start()
            samples, previous, start = [], first, time.monotonic()
            reads, last_atimes, sockets, terminal_front = {}, {}, set(), 0
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
                for path, atime in transcript_atimes(home).items():
                    reads.setdefault(path, 0)
                    if path in last_atimes and atime > last_atimes[path]:
                        reads[path] += 1
                    last_atimes[path] = atime
                sockets.update(inet_sockets(process.pid))
                if writers and frontmost_bundle_id() == TERMINAL_BUNDLE_ID:
                    terminal_front += 1
            elapsed = time.monotonic() - start
            stop.set()
            for thread in threads:
                thread.join(timeout=SLEEP_PAUSE_SECONDS + 5)
            last = rusage(process.pid) or previous
            switch_log = ""
            for directory, _, files in os.walk(os.path.join(home, "Library")):
                for name in files:
                    if "switch" in name.lower() and name.endswith(".log"):
                        with open(os.path.join(directory, name), errors="replace") as handle:
                            switch_log += handle.read()
        finally:
            stop.set()
            if process.poll() is None:
                os.kill(process.pid, signal.SIGCONT)
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
            if cli is not None:
                cli.kill()

    if elapsed < duration - args.interval:
        sys.exit(f"app exited after {elapsed:.0f}s of {duration:.0f}s; no report written")
    if sockets:
        sys.exit("网络隔离失效：App 持有外部网络 socket；不写报告\n" + "\n".join(sorted(sockets)))
    # Once Terminal has been frontmost the app keeps sampling Claude even after focus moves
    # (ActivityCoordinator's `.other` branch follows the current client), so read evidence
    # alone cannot detect lost focus; the scenario defines Terminal as frontmost.
    front_fraction = terminal_front / max(len(samples), 1)
    if writers and front_fraction < MIN_TERMINAL_FRONT_FRACTION:
        sys.exit(f"场景无效：Terminal 只在 {terminal_front}/{len(samples)} 个样本中位于前台"
                 f"（要求 ≥ {MIN_TERMINAL_FRONT_FRACTION:.0%}）；不写报告。采样期间请保持 Terminal 在前台。")
    # The app reads only the newest main-session transcript, so require steady reads overall
    # rather than per file.
    if writers and sum(reads.values()) < max(1, len(samples) // 4):
        sys.exit("场景无效：App 未读取模拟 transcript（读取证据 "
                 f"{sorted(reads.values())}），监控路径未触发；不写报告。"
                 "采样期间请保持 Terminal 在前台。")

    cpu = [s["cpu_pct"] for s in samples]
    mem = [s["footprint"] / 1048576 for s in samples]
    total_cpu_s = (last["cpu_ns"] - first["cpu_ns"]) / 1e9
    read_mb = (last["bytes_read"] - first["bytes_read"]) / 1048576
    if menu is not None:
        menu_value = f"中位 {menu[len(menu) // 2]:.0f} ms / 最大 {menu[-1]:.0f} ms（{len(menu)} 次，点击→菜单出现）"
    else:
        menu_value = menu_error
    rows = [
        ("实际采样时长", f"{elapsed:.0f} s（{len(samples)} 个样本，间隔 {args.interval:g} s）"),
        ("CPU 平均 / p95 / 峰值", f"{sum(cpu) / max(len(cpu), 1):.2f}% / {percentile(cpu, .95):.2f}% / {max(cpu, default=0):.2f}%"),
        ("CPU 总时间", f"{total_cpu_s:.2f} s"),
        ("内存 footprint 起始 / 结束 / 峰值", f"{mem[0] if mem else 0:.1f} / {mem[-1] if mem else 0:.1f} / {max(mem, default=0):.1f} MB"),
        ("磁盘读取量", f"{read_mb:.2f} MB"),
        ("唤醒次数", f"{last['wakeups'] - first['wakeups']}"),
        ("菜单打开耗时", menu_value),
        ("外部网络 socket", "0（sandbox-exec 拒绝远程 IP，已验证）"),
    ]
    if writers:
        rows.append(("transcript 读取证据", f"{sum(reads.values())} 次 / {len(samples)} 个样本，按文件 {sorted(reads.values(), reverse=True)}（atime 前进）"))
        rows.append(("Terminal 前台样本", f"{terminal_front}/{len(samples)}（{front_fraction:.0%}）"))
        rows.append(("模拟 Claude CLI", "运行中（临时 `claude` 进程，Terminal 置前）"
                     + ("；client=claude 已切换" if "client=claude" in switch_log else "")))
    else:
        rows.append(("模拟 Claude CLI", "无（空闲场景不启动）"))
    if args.scenario == "sleep-wake":
        rows.append(("休眠/唤醒周期", f"{sum(1 for e in events if e[0] == 'cont')} 次（每 {SLEEP_CYCLE_SECONDS} s 暂停 {SLEEP_PAUSE_SECONDS} s）"))
    report = [
        f"## BalanceBar 性能报告：`{args.scenario}`",
        "",
        f"- 场景：{SCENARIOS[args.scenario][1]}",
        f"- 提交：`{git_head()}`；App：`{os.path.basename(args.app)}`",
        f"- 时间：{datetime.datetime.now().astimezone().isoformat(timespec='seconds')}；macOS {subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip()}",
        f"- 环境：隔离的临时 HOME，网络沙盒，预热 {args.warmup:g} s",
        "",
        "| 指标 | 数值 |",
        "| --- | --- |",
    ] + [f"| {name} | {value} |" for name, value in rows]
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
    parser.add_argument("--no-fake-cli", action="store_true", help="调试：不启动模拟 claude 进程")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
