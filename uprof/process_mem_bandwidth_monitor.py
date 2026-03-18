#!/usr/bin/env python3
"""
进程内存带宽监控工具 (基于 Linux resctrl / RDT MBM)

用法:
    sudo python3 process_mem_bandwidth_monitor.py <进程名或PID> [选项]

示例:
    sudo python3 process_mem_bandwidth_monitor.py stress
    sudo python3 process_mem_bandwidth_monitor.py 1234
    sudo python3 process_mem_bandwidth_monitor.py stress --interval 2 --count 10
    sudo python3 process_mem_bandwidth_monitor.py stress --metric total

    # 按进程名监控（自动创建 stress-ng_monitor 组）
    sudo python3 process_mem_bandwidth_monitor.py stress-ng
 
    # 按 PID, 监控 10 次, 间隔 2 秒
    sudo python3 process_mem_bandwidth_monitor.py 1234 --count 10 --interval 2

    # 监控总带宽（含跨 NUMA 流量）
    sudo python3 process_mem_bandwidth_monitor.py myapp --metric total
"""

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

RESCTRL_PATH = Path("/sys/fs/resctrl")
MON_GROUPS_PATH = RESCTRL_PATH / "mon_groups"


# ── 辅助函数 ──────────────────────────────────────────────────────────────────

def die(msg: str, code: int = 1) -> None:
    print(f"错误: {msg}", file=sys.stderr)
    sys.exit(code)


def run(cmd: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, check=check)


def is_root() -> bool:
    return os.geteuid() == 0


def resctrl_mounted() -> bool:
    """检查 resctrl 是否已挂载"""
    try:
        with open("/proc/mounts") as f:
            return any("resctrl" in line for line in f)
    except OSError:
        return False


def mount_resctrl() -> None:
    """尝试挂载 resctrl 文件系统"""
    print("resctrl 未挂载，尝试挂载...")
    result = run("mount -t resctrl resctrl /sys/fs/resctrl", check=False)
    if result.returncode != 0:
        die(f"挂载 resctrl 失败:\n{result.stderr.strip()}\n"
            "请确认内核支持 RDT MBM (检查 /sys/fs/resctrl 目录是否存在)")
    print("resctrl 挂载成功。")


def check_mbm_support() -> list[str]:
    """检查 MBM 监控功能是否可用，返回可用的 metric 列表"""
    features_file = RESCTRL_PATH / "info" / "L3_MON" / "mon_features"
    if not features_file.exists():
        die("系统不支持 RDT L3 监控 (未找到 info/L3_MON/mon_features)")
    features = features_file.read_text().split()
    mbm_features = [f for f in features if "mbm" in f]
    if not mbm_features:
        die("系统不支持 MBM 内存带宽监控")
    return mbm_features


def find_pids(process: str) -> list[int]:
    """根据进程名或 PID 查找所有匹配的 PID"""
    # 如果是纯数字，直接当作 PID
    if process.isdigit():
        pid = int(process)
        if not Path(f"/proc/{pid}").exists():
            die(f"PID {pid} 不存在")
        return [pid]

    # 按进程名搜索（精确匹配优先，fallback 宽松匹配）
    result = run(f"pgrep -x '{process}'", check=False)
    if result.returncode != 0 or not result.stdout.strip():
        result = run(f"pgrep '{process}'", check=False)
    if result.returncode != 0 or not result.stdout.strip():
        die(f"未找到进程: {process}\n"
            f"请用 'pgrep {process}' 或 'ps aux | grep {process}' 确认进程正在运行")
    return [int(p) for p in result.stdout.split()]


def build_process_tree() -> tuple[dict[int, int], dict[int, list[int]]]:
    """扫描 /proc，返回 (pid->ppid 映射, ppid->children 映射)"""
    pid2ppid: dict[int, int] = {}
    children: dict[int, list[int]] = {}
    for proc_dir in Path("/proc").iterdir():
        if not proc_dir.name.isdigit():
            continue
        try:
            status = (proc_dir / "status").read_text()
            pid = ppid = None
            for line in status.splitlines():
                if line.startswith("Pid:"):
                    pid = int(line.split()[1])
                elif line.startswith("PPid:"):
                    ppid = int(line.split()[1])
                if pid and ppid:
                    break
            if pid and ppid:
                pid2ppid[pid] = ppid
                children.setdefault(ppid, []).append(pid)
        except OSError:
            pass
    return pid2ppid, children


def filter_roots(pids: list[int], pid2ppid: dict[int, int]) -> list[int]:
    """从 pids 中筛选出真正的顶层进程：父进程不在 pids 集合内的那些"""
    pid_set = set(pids)
    return [p for p in pids if pid2ppid.get(p) not in pid_set]


def find_all_descendants(root_pids: list[int], children: dict[int, list[int]]) -> list[int]:
    """从 root_pids 出发 BFS，返回 root_pids 及其全部后代 PID"""
    all_pids: set[int] = set(root_pids)
    queue = list(root_pids)
    while queue:
        pid = queue.pop()
        for child in children.get(pid, []):
            if child not in all_pids:
                all_pids.add(child)
                queue.append(child)
    return list(all_pids)


def sanitize_name(name: str) -> str:
    """将进程名转为合法的目录名"""
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in name)


def get_or_create_group(group_name: str) -> Path:
    """创建 MON group，若已存在则直接使用"""
    group_path = MON_GROUPS_PATH / group_name
    if group_path.exists():
        print(f"监控组已存在: {group_path}")
    else:
        group_path.mkdir(parents=False, exist_ok=False)
        print(f"已创建监控组: {group_path}")
    return group_path


def get_tids(pids: list[int]) -> list[int]:
    """枚举每个 PID 下 /proc/<pid>/task/ 的所有线程 TID"""
    tids = []
    for pid in pids:
        task_dir = Path(f"/proc/{pid}/task")
        if task_dir.exists():
            for tid_path in task_dir.iterdir():
                try:
                    tids.append(int(tid_path.name))
                except ValueError:
                    pass
        else:
            # 进程已退出，跳过
            print(f"  警告: /proc/{pid}/task 不存在，进程可能已退出", file=sys.stderr)
    return tids


def assign_pids(group_path: Path, pids: list[int]) -> list[int]:
    """将所有线程 TID 写入监控组的 tasks 文件，返回成功分配的 TID 列表"""
    tasks_file = group_path / "tasks"
    tids = get_tids(pids)
    if not tids:
        return []
    assigned = []
    for tid in tids:
        try:
            tasks_file.write_text(str(tid))
            assigned.append(tid)
        except OSError as e:
            print(f"  警告: TID {tid} 分配失败 - {e}", file=sys.stderr)
    return assigned


def get_mon_domains(group_path: Path) -> list[Path]:
    """获取所有 mon_L3_* 目录（每个 L3 域/Socket 一个）"""
    mon_data = group_path / "mon_data"
    domains = sorted(mon_data.glob("mon_L3_*"))
    return domains


def read_bytes(domain: Path, metric: str) -> int | None:
    """读取指定 metric 的字节数，失败返回 None"""
    metric_file = domain / metric
    try:
        val = metric_file.read_text().strip()
        if val.lower() == "unavailable":
            return None
        return int(val)
    except (OSError, ValueError):
        return None


def cleanup_group(group_path: Path) -> None:
    """退出时删除监控组（将 tasks 迁回根组）"""
    tasks_file = group_path / "tasks"
    try:
        pids = tasks_file.read_text().split()
        root_tasks = RESCTRL_PATH / "tasks"
        for pid in pids:
            try:
                root_tasks.write_text(pid)
            except OSError:
                pass
        group_path.rmdir()
        print(f"\n已清理监控组: {group_path}")
    except OSError as e:
        print(f"\n清理监控组时出错: {e}", file=sys.stderr)


# ── 监控主逻辑 ────────────────────────────────────────────────────────────────

def monitor(group_path: Path, pids: list[int], interval: float,
            count: int | None, metric_key: str) -> None:
    """主监控循环"""
    domains = get_mon_domains(group_path)
    if not domains:
        die("未找到 mon_data/mon_L3_* 目录，请确认 MBM 硬件支持")

    metric_file = "mbm_local_bytes" if metric_key == "local" else "mbm_total_bytes"

    # 读取初始基准值
    prev: dict[str, int | None] = {
        d.name: read_bytes(d, metric_file) for d in domains
    }

    # 预热一个周期，找出有流量的域
    print("正在采集基准值...")
    time.sleep(interval)

    active_domains: list[Path] = []
    for d in domains:
        curr = read_bytes(d, metric_file)
        if curr is not None:
            active_domains.append(d)
        prev[d.name] = curr

    if not active_domains:
        die("所有 L3 域均返回 Unavailable，请确认进程已产生内存访问")

    # 列标题：用 L3域#XX 替代 Socket XX
    col_labels = [f"L3域#{d.name.split('_')[-1]}" for d in active_domains]
    col_w = 12  # 每列宽度
    sep = "=" * (10 + col_w * len(active_domains) + col_w)

    print(f"\n进程: {pids}  |  监控组: {group_path.name}")
    print(f"Metric: {metric_file}  |  间隔: {interval}s  |  活跃L3域: {len(active_domains)}/{len(domains)}")
    print(sep)
    header = f"{'时间':^10}" + "".join(f"{lbl:>{col_w}}" for lbl in col_labels) + f"{'合计(MB/s)':>{col_w}}"
    print(header)
    print("-" * len(sep))

    iteration = 0
    try:
        while True:
            time.sleep(interval)
            timestamp = time.strftime("%H:%M:%S")
            total_bw = 0.0
            parts = [f"{timestamp:^10}"]

            for domain in active_domains:
                curr = read_bytes(domain, metric_file)
                prev_val = prev[domain.name]
                prev[domain.name] = curr

                if curr is None or prev_val is None:
                    parts.append(f"{'N/A':>{col_w}}")
                else:
                    delta = max(0, curr - prev_val)
                    mb_sec = delta / interval / 1_048_576
                    total_bw += mb_sec
                    parts.append(f"{mb_sec:>{col_w}.2f}")

            parts.append(f"{total_bw:>{col_w}.2f}")
            print("".join(parts))

            iteration += 1
            if count is not None and iteration >= count:
                break

    except KeyboardInterrupt:
        pass

    print("-" * len(sep))
    print("监控结束。")


# ── 入口 ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="基于 Linux RDT/resctrl 的进程内存带宽监控工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("process", help="进程名或 PID")
    parser.add_argument("-i", "--interval", type=float, default=1.0,
                        help="采样间隔（秒），默认 1")
    parser.add_argument("-n", "--count", type=int, default=None,
                        help="采样次数，默认无限循环 (Ctrl+C 停止)")
    parser.add_argument("-m", "--metric", choices=["local", "total"], default="local",
                        help="监控 metric: local=本地NUMA带宽(默认), total=全部带宽")
    parser.add_argument("--group", default=None,
                        help="自定义监控组名称（默认: <进程名>_monitor）")
    parser.add_argument("--no-cleanup", action="store_true",
                        help="退出时不删除监控组")
    args = parser.parse_args()

    # 权限检查
    if not is_root():
        die("此脚本需要 root 权限，请用 sudo 运行")

    # 挂载检查
    if not resctrl_mounted():
        mount_resctrl()

    # MBM 支持检查
    available_features = check_mbm_support()
    metric_file = "mbm_local_bytes" if args.metric == "local" else "mbm_total_bytes"
    if metric_file not in available_features:
        die(f"硬件不支持 {metric_file}，可用 features: {available_features}")

    # 查找匹配 PID，筛选真正的顶层根进程，再递归展开全部子进程
    matched_pids = find_pids(args.process)
    pid2ppid, children_map = build_process_tree()
    root_pids = filter_roots(matched_pids, pid2ppid)
    pids = find_all_descendants(root_pids, children_map)
    print(f"找到进程 '{args.process}': 匹配={matched_pids}，根={root_pids}，含子进程共 {len(pids)} 个")

    # 生成组名
    if args.group:
        group_name = args.group
    else:
        base = args.process if not args.process.isdigit() else f"pid{args.process}"
        group_name = f"{sanitize_name(base)}_monitor"

    # 创建监控组
    group_path = get_or_create_group(group_name)

    # 注册清理函数
    def _cleanup(sig=None, frame=None):
        if not args.no_cleanup:
            cleanup_group(group_path)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT, _cleanup)

    # 分配所有线程 TID
    assigned = assign_pids(group_path, pids)
    if not assigned:
        if not args.no_cleanup:
            cleanup_group(group_path)
        die("没有成功分配任何 TID，请确认进程仍在运行")
    print(f"已分配 TID: {len(assigned)} 个（来自 {len(pids)} 个进程）")

    # 开始监控
    try:
        monitor(group_path, assigned, args.interval, args.count, args.metric)
    finally:
        if not args.no_cleanup:
            cleanup_group(group_path)


if __name__ == "__main__":
    main()
