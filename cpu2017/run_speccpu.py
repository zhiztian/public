#!/usr/bin/env python3
"""
SPEC CPU 2017 自动化测试脚本
用法：python3 run_speccpu.py
"""

import os
import re
import sys
import glob
import shutil
import subprocess
from datetime import datetime
from getpass import getpass

# ── 时间戳（本次运行唯一标识） ──────────────────────────────────────────────
RUN_TS = datetime.now().strftime("%Y%m%d_%H%M%S")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR    = os.path.join(SCRIPT_DIR, "logs")
RESULT_DIR = os.path.join(SCRIPT_DIR, "results", RUN_TS)

os.makedirs(LOG_DIR,    exist_ok=True)
os.makedirs(RESULT_DIR, exist_ok=True)

LOG_STEPS = os.path.join(LOG_DIR, f"steps_{RUN_TS}.log")
LOG_RUN   = os.path.join(LOG_DIR, f"run_{RUN_TS}.log")


# ── 工具函数 ────────────────────────────────────────────────────────────────

def log_step(msg: str):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    with open(LOG_STEPS, "a") as f:
        f.write(line + "\n")


def prompt(label: str, default: str, secret: bool = False) -> str:
    if secret:
        val = getpass(f"{label} [{default}]: ") or default
    else:
        val = input(f"{label} [{default}]: ").strip() or default
    return val


# ── 1. 用户输入 ─────────────────────────────────────────────────────────────

print("=" * 60)
print("  SPEC CPU 2017 自动化测试")
print("=" * 60)

SPEC_DIR    = prompt("SPEC CPU 2017 安装目录",
                     "/home/zz/performance-tools/speccpu/cpu2017")
GCC_PKG_DIR = prompt("AMD 组件包目录",
                     "/home/zz/performance-tools/speccpu/cpu2017_scripts_gcc")
SUDO_PASS   = prompt("sudo 密码", "1", secret=True)

print()
log_step(f"SPEC 目录: {SPEC_DIR}")
log_step(f"组件包目录: {GCC_PKG_DIR}")


# ── 2. CPU 自动检测 ─────────────────────────────────────────────────────────

log_step("检测 CPU 型号 ...")

try:
    lscpu_out = subprocess.check_output(["lscpu"], text=True)
except FileNotFoundError:
    log_step("[ERROR] lscpu 命令不可用，无法检测 CPU")
    sys.exit(1)

# 提取 Model name 行
cpu_model = ""
for line in lscpu_out.splitlines():
    if re.match(r"Model name", line, re.IGNORECASE):
        cpu_model = line.split(":", 1)[1].strip()
        break

log_step(f"CPU 型号: {cpu_model}")

cpu_lower = cpu_model.lower()


# ── 3. 配置文件选择 ─────────────────────────────────────────────────────────

log_step("扫描 ini_*.py 配置文件 ...")

ini_files = sorted(glob.glob(os.path.join(GCC_PKG_DIR, "ini_*.py")))

if not ini_files:
    log_step(f"[ERROR] 在 {GCC_PKG_DIR} 下未找到任何 ini_*.py 文件")
    sys.exit(1)

# 打分匹配：关键字越多越靠前
KEYWORD_GROUPS = [
    (["amd", "epyc"],              10),
    (["intel", "xeon"],            10),
    (["znver5", "zen5", "9005"],    8),
    (["znver4", "zen4", "9004"],    8),
    (["znver3", "zen3"],            8),
    (["rate"],                       3),
    (["gcc15", "gcc14", "gcc13"],   2),
]

def score_ini(path: str) -> int:
    name = os.path.basename(path).lower()
    total = 0
    for keywords, weight in KEYWORD_GROUPS:
        for kw in keywords:
            if kw in cpu_lower and kw in name:
                total += weight
    return total

scored = sorted(ini_files, key=score_ini, reverse=True)
best_score = score_ini(scored[0])

if best_score == 0:
    print("\n未能自动匹配配置文件，请手动选择：")
    for i, f in enumerate(scored):
        print(f"  [{i}] {os.path.basename(f)}")
    idx = int(input("输入编号: ").strip())
    selected_ini = scored[idx]
else:
    selected_ini = scored[0]

selected_run = os.path.join(
    GCC_PKG_DIR,
    os.path.basename(selected_ini).replace("ini_", "run_", 1)
)

if not os.path.isfile(selected_run):
    log_step(f"[ERROR] 对应 run 脚本不存在: {selected_run}")
    sys.exit(1)

log_step(f"选定 ini: {os.path.basename(selected_ini)}")
log_step(f"选定 run: {os.path.basename(selected_run)}")


# ── 4. 修改 ini：迭代次数 → 1 ───────────────────────────────────────────────

log_step("备份并修改 ini 配置（迭代次数 = 1）...")

backup_path = selected_ini + ".bak"
shutil.copy2(selected_ini, backup_path)
log_step(f"备份已写入: {backup_path}")

with open(selected_ini, "r") as f:
    ini_content = f.read()

# 支持 iterations = N 和 niter = N 两种写法（值为整数或字符串）
ini_modified = re.sub(
    r"^(\s*(?:iterations|niter)\s*=\s*)(\S+)",
    r"\g<1>1",
    ini_content,
    flags=re.MULTILINE | re.IGNORECASE,
)

if ini_modified == ini_content:
    log_step("[WARN] 未找到 iterations/niter 字段，请手动确认迭代次数")
else:
    with open(selected_ini, "w") as f:
        f.write(ini_modified)
    log_step("迭代次数已设为 1")


# ── 5. 启动测试 ─────────────────────────────────────────────────────────────

log_step("启动 SPEC CPU 2017 测试 ...")
log_step(f"运行日志: {LOG_RUN}")

cmd = ["sudo", "-S", "python3", selected_run]

log_step(f"执行命令: {' '.join(cmd)}")

with open(LOG_RUN, "w") as log_file:
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    # 发送 sudo 密码
    proc.stdin.write(SUDO_PASS + "\n")
    proc.stdin.flush()
    proc.stdin.close()

    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        log_file.write(line)

    proc.wait()

if proc.returncode != 0:
    log_step(f"[ERROR] run 脚本退出码: {proc.returncode}，请检查 {LOG_RUN}")
    sys.exit(proc.returncode)

log_step("测试运行完成")


# ── 6. 结果监视与归档 ────────────────────────────────────────────────────────

log_step("扫描 SPEC result/ 目录 ...")

spec_result_dir = os.path.join(SPEC_DIR, "result")
if not os.path.isdir(spec_result_dir):
    log_step(f"[WARN] result 目录不存在: {spec_result_dir}")
else:
    # 找最新的 .txt 摘要文件
    txt_files = glob.glob(os.path.join(spec_result_dir, "*.txt"))
    if not txt_files:
        log_step("[WARN] result/ 下未找到 .txt 结果文件")
    else:
        latest_txt = max(txt_files, key=os.path.getmtime)
        log_step(f"最新结果文件: {os.path.basename(latest_txt)}")

        # 提取分数
        with open(latest_txt, "r", errors="replace") as f:
            result_text = f.read()

        scores = {}
        for metric in ["SPECrate2017_int_base", "SPECrate2017_fp_base",
                        "SPECrate2017_int_peak", "SPECrate2017_fp_peak"]:
            m = re.search(rf"{re.escape(metric)}\s+([\d.]+)", result_text)
            if m:
                scores[metric] = m.group(1)

        print()
        print("=" * 60)
        print("  测试结果摘要")
        print("=" * 60)
        if scores:
            for k, v in scores.items():
                print(f"  {k}: {v}")
                log_step(f"分数 {k} = {v}")
        else:
            log_step("[WARN] 未能从结果文件中提取分数，请手动查看")
            print(f"  结果文件: {latest_txt}")
        print("=" * 60)

        # 归档到 results/<timestamp>/
        for f in glob.glob(os.path.join(spec_result_dir, "*")):
            shutil.copy2(f, RESULT_DIR)
        log_step(f"结果已归档至: {RESULT_DIR}")

log_step("全部完成")
