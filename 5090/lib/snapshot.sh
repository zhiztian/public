#!/bin/bash
# snapshot.sh — diagnostic bundle, makes every run self-contained
# usage: bash snapshot.sh <out_dir> [global|run]

set -uo pipefail
OUT_DIR="${1:?out_dir required}"
SCOPE="${2:-run}"   # "global" = full system; "run" = lightweight per-run delta
mkdir -p "$OUT_DIR"

# ---- always: timestamp + identity ----
{
    date -Is
    hostname
    uname -a
    whoami
    id
    uptime
} > "$OUT_DIR/identity.txt" 2>&1

# ---- always: GPU current state ----
nvidia-smi > "$OUT_DIR/nvidia_smi.txt" 2>&1
nvidia-smi --query-gpu=timestamp,index,name,pci.bus_id,pcie.link.gen.current,pcie.link.width.current,pstate,clocks.sm,clocks.mem,power.draw,power.limit,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv > "$OUT_DIR/gpu_state.csv" 2>&1
nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv > "$OUT_DIR/gpu_apps.csv" 2>&1

# ---- always: dmesg tail (NVIDIA/PCIe/IOMMU only) ----
dmesg -T 2>/dev/null | grep -Ei 'nvidia|xid|pcie|aer|acs|iommu|amd-vi' | tail -200 > "$OUT_DIR/dmesg_relevant.txt" 2>&1 || true

# ---- always: filesystem check (vLLM/SGLang need /dev/shm) ----
df -h > "$OUT_DIR/df.txt" 2>&1
df -h /dev/shm >> "$OUT_DIR/df.txt" 2>&1

if [[ "$SCOPE" == "global" ]]; then
    # ---- system topology (only on global snapshot, expensive) ----
    nvidia-smi -q > "$OUT_DIR/nvidia_smi_q.txt" 2>&1
    nvidia-smi topo -m > "$OUT_DIR/nvidia_topo_m.txt" 2>&1
    nvidia-smi topo -p2p w > "$OUT_DIR/nvidia_topo_p2p_w.txt" 2>&1 || true
    nvidia-smi topo -p2p r > "$OUT_DIR/nvidia_topo_p2p_r.txt" 2>&1 || true

    lscpu > "$OUT_DIR/lscpu.txt" 2>&1
    lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE,MAXMHZ,MINMHZ > "$OUT_DIR/lscpu_topo.txt" 2>&1
    numactl --hardware > "$OUT_DIR/numactl.txt" 2>&1
    numastat > "$OUT_DIR/numastat.txt" 2>&1
    free -h > "$OUT_DIR/free.txt" 2>&1
    sudo dmidecode -t bios -t processor -t memory > "$OUT_DIR/dmidecode.txt" 2>&1 || \
        dmidecode -t bios -t processor -t memory > "$OUT_DIR/dmidecode.txt" 2>&1 || \
        echo "dmidecode requires sudo" > "$OUT_DIR/dmidecode.txt"

    # PCIe ACS audit (per GPT §2.5 — ACS regression silently kills P2P)
    {
        for d in /sys/bus/pci/devices/*; do
            bdf=$(basename "$d")
            lspci -s "$bdf" -vvv 2>/dev/null | grep -E "^[0-9a-fA-F:.]+|ACSCtl|LnkSta|LnkCap" || true
        done
    } > "$OUT_DIR/lspci_acs_links.txt" 2>&1
    cat /proc/cmdline > "$OUT_DIR/cmdline.txt"

    # NVIDIA driver/kernel module
    modinfo nvidia > "$OUT_DIR/modinfo_nvidia.txt" 2>&1 || true
    lsmod | grep -i nvidia > "$OUT_DIR/lsmod_nvidia.txt" 2>&1 || true
    cat /proc/driver/nvidia/version > "$OUT_DIR/proc_driver_nvidia_version.txt" 2>&1 || true

    # OS / env
    cat /etc/os-release > "$OUT_DIR/os_release.txt" 2>&1
    env | sort > "$OUT_DIR/env.txt" 2>&1
    ulimit -a > "$OUT_DIR/ulimit.txt" 2>&1

    # Python / framework versions
    python3 - > "$OUT_DIR/python_stack.txt" 2>&1 <<'PY'
import sys, importlib
print(f"python: {sys.version}")
print(f"executable: {sys.executable}")
mods = ["torch", "triton", "vllm", "sglang", "flash_attn", "flashinfer",
        "xformers", "transformers", "tokenizers", "ray"]
for m in mods:
    try:
        mod = importlib.import_module(m)
        print(f"{m}: {getattr(mod, '__version__', 'unknown')}  @  {getattr(mod, '__file__', '?')}")
    except Exception as e:
        print(f"{m}: IMPORT_FAIL {type(e).__name__}: {e}")

try:
    import torch
    print(f"torch.cuda.is_available: {torch.cuda.is_available()}")
    print(f"torch.cuda.device_count: {torch.cuda.device_count()}")
    print(f"torch.version.cuda: {torch.version.cuda}")
    print(f"torch.cuda.get_arch_list: {torch.cuda.get_arch_list()}")
    for i in range(torch.cuda.device_count()):
        print(f"  gpu[{i}]: {torch.cuda.get_device_name(i)}  cap={torch.cuda.get_device_capability(i)}")
except Exception as e:
    print(f"torch probe failed: {e}")
PY

    # Compiler versions (for SPEC)
    {
        which gcc; gcc --version 2>&1 | head -2
        which clang 2>/dev/null && clang --version 2>&1 | head -2
        which nvcc 2>/dev/null && nvcc --version 2>&1
        # AOCC clang location varies
        for c in /opt/AMD/aocc-compiler-*/bin/clang ~/aocc/bin/clang; do
            [[ -x "$c" ]] && { echo "AOCC clang: $c"; "$c" --version 2>&1 | head -2; }
        done
    } > "$OUT_DIR/compilers.txt" 2>&1
fi

echo "snapshot done: $OUT_DIR (scope=$SCOPE)"
